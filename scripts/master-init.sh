#!/bin/bash
set -euo pipefail
exec > /var/log/master-init.log 2>&1

META="http://metadata.google.internal/computeMetadata/v1/instance/attributes"
H="Metadata-Flavor: Google"
PROJECT_ID=$(curl -sf "$META/tf_project_id" -H "$H")
JOIN_BUCKET=$(curl -sf "$META/tf_join_bucket" -H "$H")
DAG_BUCKET=$(curl -sf  "$META/tf_dag_bucket"  -H "$H")
ANALITYCY=$(curl -sf    "$META/tf_analitycy"     -H "$H")

K8S_VERSION="1.29"
AIRFLOW_VERSION="2.9.1"
POD_CIDR="192.168.0.0/16"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ── 1. System deps ─────────────────────────────────────────────────────────────
log "Aktualizacja systemu..."
apt-get update -qq
apt-get install -y -qq curl wget gnupg2 apt-transport-https ca-certificates \
  software-properties-common python3-pip python3-venv \
  git nfs-common

# ── 2. containerd ──────────────────────────────────────────────────────────────
log "Instalacja containerd..."
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter
cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -qq
apt-get install -y -qq containerd.io

containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd

# ── 3. kubeadm / kubelet / kubectl ────────────────────────────────────────────
log "Instalacja kubeadm..."
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
  https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update -qq
apt-get install -y -qq kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

# ── 4. kubeadm init ────────────────────────────────────────────────────────────
log "Inicjalizacja klastra K8s..."
INTERNAL_IP=$(curl -sf "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip" \
  -H "Metadata-Flavor: Google")
EXTERNAL_IP=$(curl -sf "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip" \
  -H "Metadata-Flavor: Google" || echo "")

kubeadm init \
  --apiserver-advertise-address="$INTERNAL_IP" \
  --apiserver-cert-extra-sans="$EXTERNAL_IP,$INTERNAL_IP" \
  --pod-network-cidr="$POD_CIDR" \
  --kubernetes-version="v${K8S_VERSION}.0"

mkdir -p /root/.kube /home/ubuntu/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config
cp /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
chown ubuntu:ubuntu /home/ubuntu/.kube/config

export KUBECONFIG=/root/.kube/config

# ── 5. CNI: Calico ─────────────────────────────────────────────────────────────
log "Instalacja Calico CNI..."
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml

# ── 6. Zapisz join-command do GCS ─────────────────────────────────────────────
log "Zapis join-command do GCS..."
JOIN_CMD=$(kubeadm token create --print-join-command)
echo "$JOIN_CMD" | gsutil cp - "gs://$JOIN_BUCKET/join-command.sh"
gsutil cp /etc/kubernetes/admin.conf "gs://$JOIN_BUCKET/admin.conf"

# ── 7. Helm ────────────────────────────────────────────────────────────────────
log "Instalacja Helm..."
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# ── 8. StorageClass (local-path-provisioner) ──────────────────────────────────
log "Instalacja local-path-provisioner (StorageClass)..."
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.28/deploy/local-path-storage.yaml
kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
kubectl rollout status deployment/local-path-provisioner -n local-path-storage --timeout=60s

# ── 10. Postgres (oficjalny obraz, bundled bitnami ma broken tagi) ─────────────
log "Stawianie Postgres..."
kubectl create namespace airflow

kubectl apply -n airflow -f - <<'EOF'
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
spec:
  selector:
    matchLabels:
      app: postgres
  serviceName: postgres
  replicas: 1
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
      - name: postgres
        image: postgres:15-alpine
        env:
        - name: POSTGRES_USER
          value: airflow
        - name: POSTGRES_PASSWORD
          value: airflow
        - name: POSTGRES_DB
          value: airflow
        ports:
        - containerPort: 5432
        volumeMounts:
        - name: data
          mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: [ReadWriteOnce]
      resources:
        requests:
          storage: 5Gi
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
spec:
  selector:
    app: postgres
  ports:
  - port: 5432
EOF

log "Czekam na Postgres..."
until kubectl wait pod -n airflow -l app=postgres --for=condition=Ready --timeout=120s 2>/dev/null; do sleep 5; done
POSTGRES_IP=$(kubectl get svc postgres -n airflow -o jsonpath='{.spec.clusterIP}')
log "Postgres gotowy: $POSTGRES_IP"

# ── 10. Katalog DAGów + NFS server na masterze ────────────────────────────────
log "Tworzenie struktury katalogów DAGów i konfiguracja NFS..."
mkdir -p /mnt/airflow-dags/admin
ANALITYCY_LIST=$(echo "$ANALITYCY" | python3 -c "import sys,json; [print(s) for s in json.load(sys.stdin)]")
for analityk in $ANALITYCY_LIST; do
  mkdir -p "/mnt/airflow-dags/$analityk"
done
chmod -R 777 /mnt/airflow-dags

cat <<'EOF' > /mnt/airflow-dags/.airflowignore
\.ipynb_checkpoints
__pycache__
.*\.pyc$
EOF

apt-get install -y -qq nfs-kernel-server
echo "/mnt/airflow-dags 10.0.0.0/8(rw,sync,no_subtree_check,no_root_squash)" > /etc/exports
exportfs -ra
systemctl enable nfs-server
systemctl start nfs-server

# ── 11. NFS PV/PVC (przed Helm — scheduler/webserver muszą je widzieć przy starcie) ──
log "Tworzenie NFS PersistentVolume dla DAGów..."
MASTER_IP=$(hostname -I | awk '{print $1}')

kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: airflow-dags-pv
spec:
  capacity:
    storage: 5Gi
  accessModes:
    - ReadWriteMany
  nfs:
    server: $MASTER_IP
    path: /mnt/airflow-dags
  mountOptions:
    - nfsvers=4.1
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: airflow-dags-pvc
  namespace: airflow
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 5Gi
  volumeName: airflow-dags-pv
  storageClassName: ""
EOF

# ── 11a. Airflow via Helm (1.15.0 + zewnętrzny postgres) ──────────────────────
log "Instalacja Apache Airflow via Helm..."
helm repo add apache-airflow https://airflow.apache.org
helm repo update

ADMIN_PASSWORD="Spark@Adm1n2024!"

cat <<'EOF' > /tmp/airflow-values.yaml
dags:
  persistence:
    enabled: false
  gitSync:
    enabled: false

scheduler:
  extraVolumes:
    - name: dags-nfs
      persistentVolumeClaim:
        claimName: airflow-dags-pvc
  extraVolumeMounts:
    - name: dags-nfs
      mountPath: /opt/airflow/dags

webserver:
  extraVolumes:
    - name: dags-nfs
      persistentVolumeClaim:
        claimName: airflow-dags-pvc
  extraVolumeMounts:
    - name: dags-nfs
      mountPath: /opt/airflow/dags

triggerer:
  extraVolumes:
    - name: dags-nfs
      persistentVolumeClaim:
        claimName: airflow-dags-pvc
  extraVolumeMounts:
    - name: dags-nfs
      mountPath: /opt/airflow/dags

workers:
  extraVolumes:
    - name: dags-nfs
      persistentVolumeClaim:
        claimName: airflow-dags-pvc
  extraVolumeMounts:
    - name: dags-nfs
      mountPath: /opt/airflow/dags
EOF

helm install airflow apache-airflow/airflow \
  --namespace airflow \
  --version "1.15.0" \
  --values /tmp/airflow-values.yaml \
  --set "executor=KubernetesExecutor" \
  --set "postgresql.enabled=false" \
  --set "redis.enabled=false" \
  --set "data.metadataConnection.user=airflow" \
  --set "data.metadataConnection.pass=airflow" \
  --set "data.metadataConnection.host=$POSTGRES_IP" \
  --set "data.metadataConnection.port=5432" \
  --set "data.metadataConnection.db=airflow" \
  --set "data.metadataConnection.protocol=postgresql" \
  --set "env[0].name=AIRFLOW__CORE__LOAD_EXAMPLES" \
  --set-string "env[0].value=False" \
  --set "webserver.service.type=ClusterIP" \
  --set "webserver.defaultUser.enabled=true" \
  --set "webserver.defaultUser.role=Admin" \
  --set "webserver.defaultUser.username=admin" \
  --set "webserver.defaultUser.password=${ADMIN_PASSWORD}" \
  --set "webserver.defaultUser.email=admin@course.local" \
  --set "webserver.defaultUser.firstName=Admin" \
  --set "webserver.defaultUser.lastName=Instructor" \
  --timeout 12m \
  --wait

# ── 11. NodePort — Airflow UI na porcie 30080 ──────────────────────────────────
log "Wystawianie Airflow UI przez NodePort :30080..."
kubectl apply -n airflow -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: airflow-webserver-nodeport
spec:
  type: NodePort
  selector:
    component: webserver
    release: airflow
  ports:
  - port: 8080
    targetPort: 8080
    nodePort: 30080
EOF

# ── 12. Konta analityków + izolacja DAGów przez RBAC ──────────────────────────
log "Tworzenie kont analityków i izolowanych DAGów w Airflow..."
AIRFLOW_POD=$(kubectl get pod -n airflow -l component=webserver -o jsonpath='{.items[0].metadata.name}')

cat <<'PYEOF' > /tmp/setup_analitycy.py
import json, os, subprocess

analitycy = json.loads(os.environ["ANALITYCY"])
airflow_pod = os.environ["AIRFLOW_POD"]

def kexec(*cmd):
    return subprocess.run(
        ["kubectl", "exec", "-n", "airflow", airflow_pod, "--"] + list(cmd),
        check=False
    )

# Używamy __ANALITYK__ jako placeholder żeby uniknąć konfliktów z {} w f-stringach
DAG_TEMPLATE = """\
from airflow import DAG
from airflow.operators.bash import BashOperator
from airflow.operators.python import PythonOperator
from airflow.models.param import Param
from datetime import datetime
import json, os, urllib.request

ANALITYK = "__ANALITYK__"


def _download_from_gcs(bucket, script_name, run_dir):
    os.makedirs(run_dir, exist_ok=True)
    req = urllib.request.Request(
        "http://metadata.google.internal/computeMetadata/v1"
        "/instance/service-accounts/default/token",
        headers={"Metadata-Flavor": "Google"},
    )
    token = json.loads(urllib.request.urlopen(req).read())["access_token"]
    blob = f"dags/{ANALITYK}/{script_name}".replace("/", "%2F")
    url = f"https://storage.googleapis.com/download/storage/v1/b/{bucket}/o/{blob}?alt=media"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    data = urllib.request.urlopen(req).read()
    open(f"{run_dir}/{script_name}", "wb").write(data)
    print(f"Pobrano {len(data):,} B")


with DAG(
    dag_id="run_script___ANALITYK__",
    schedule=None,
    start_date=datetime(2024, 1, 1),
    catchup=False,
    params={
        "script_name": Param("script.py", type="string", description="Nazwa pliku w GCS"),
    },
    tags=["analitycy", "__ANALITYK__"],
    access_control={
        "__ANALITYK__": {"can_read", "can_edit", "can_delete"},
    },
) as dag:

    download = PythonOperator(
        task_id="download_from_gcs",
        python_callable=_download_from_gcs,
        op_kwargs={
            "bucket": "{{ var.value.get('dag_bucket', '') }}",
            "script_name": "{{ params.script_name }}",
            "run_dir": "/tmp/__ANALITYK___run_{{ ts_nodash }}",
        },
    )

    run = BashOperator(
        task_id="run_script",
        env={
            "SCRIPT": "{{ params.script_name }}",
            "RUN_DIR": "/tmp/__ANALITYK___run_{{ ts_nodash }}",
        },
        append_env=True,
        bash_command="cd $RUN_DIR && python3 $SCRIPT",
    )

    cleanup = BashOperator(
        task_id="cleanup",
        env={"RUN_DIR": "/tmp/__ANALITYK___run_{{ ts_nodash }}"},
        append_env=True,
        bash_command="rm -rf $RUN_DIR",
        trigger_rule="all_done",
    )

    download >> run >> cleanup
"""

for s in analitycy:
    # Konto użytkownika (rola User = dostęp do UI)
    kexec("airflow", "users", "create",
          "--username", s, "--password", s + "Pass123!",
          "--role", "User",
          "--email", s + "@course.local",
          "--firstname", s, "--lastname", "Analityk")

    # Dedykowana rola analityka (wymagana przez access_control na DAGu)
    kexec("airflow", "roles", "create", s)
    kexec("airflow", "users", "add-role", "--username", s, "--role", s)

    # Plik DAG ze scope'owanym access_control
    dag_path = f"/mnt/airflow-dags/{s}/run_script_{s}.py"
    with open(dag_path, "w") as f:
        f.write(DAG_TEMPLATE.replace("__ANALITYK__", s))
    print(f"[OK] {s}: rola + DAG run_script_{s}")

print(f"Skonfigurowano {len(analitycy)} analityków z izolowanymi DAGami")
PYEOF

ANALITYCY="$ANALITYCY" AIRFLOW_POD="$AIRFLOW_POD" python3 /tmp/setup_analitycy.py

# ── 13. JupyterHub via Helm ───────────────────────────────────────────────────
log "Instalacja JupyterHub..."
helm repo add jupyterhub https://hub.jupyter.org/helm-chart/
helm repo update

kubectl create namespace jupyterhub

kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: airflow-dags-pv-jh
spec:
  capacity:
    storage: 5Gi
  accessModes:
    - ReadWriteMany
  nfs:
    server: $MASTER_IP
    path: /mnt/airflow-dags
  mountOptions:
    - nfsvers=4.1
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: airflow-dags-pvc
  namespace: jupyterhub
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 5Gi
  volumeName: airflow-dags-pv-jh
  storageClassName: ""
EOF

JUPYTERHUB_VALUES=$(cat <<'JHVALUES'
hub:
  config:
    DummyAuthenticator:
      password: "JupyterCourse2024!"
    JupyterHub:
      authenticator_class: dummy
  extraConfig:
    allowlist: |
      c.Authenticator.allowed_users = {
        'analityk01','analityk02','analityk03','analityk04',
        'analityk05','analityk06','analityk07','analityk08',
        'analityk09','analityk10','analityk11','analityk12',
        'analityk13','analityk14','analityk15','analityk16',
        'admin'
      }

proxy:
  service:
    type: NodePort
    nodePorts:
      http: 30088

singleuser:
  image:
    name: quay.io/jupyter/scipy-notebook
    tag: "latest"
    pullPolicy: IfNotPresent
  extraEnv:
    AIRFLOW_HOST: "http://airflow-webserver.airflow.svc.cluster.local:8080"
    AIRFLOW_USER: "admin"
  storage:
    capacity: 2Gi
    dynamic:
      storageClass: local-path
    extraVolumes:
      - name: airflow-dags
        persistentVolumeClaim:
          claimName: airflow-dags-pvc
    extraVolumeMounts:
      - name: airflow-dags
        mountPath: /home/jovyan/airflow-dags
  lifecycleHooks:
    postStart:
      exec:
        command:
          - "sh"
          - "-c"
          - |
            pip install -q apache-airflow-client requests 2>&1 | tail -2
            mkdir -p /home/jovyan/airflow-dags/${JUPYTERHUB_USER}
            ln -sfn /home/jovyan/airflow-dags/${JUPYTERHUB_USER} /home/jovyan/dags
  cpu:
    limit: 1
    guarantee: 0.25
  memory:
    limit: 2G
    guarantee: 512M
  startTimeout: 120

scheduling:
  userScheduler:
    enabled: false

prePuller:
  hook:
    enabled: false
  continuous:
    enabled: false

cull:
  enabled: true
  timeout: 3600
  every: 300
JHVALUES
)

echo "$JUPYTERHUB_VALUES" | helm install jupyterhub jupyterhub/jupyterhub \
  --namespace jupyterhub \
  --version "3.3.7" \
  --values /dev/stdin \
  --timeout 10m \
  --wait

log "JupyterHub gotowy na porcie :30088"

# ── Gotowe ─────────────────────────────────────────────────────────────────────
EXTERNAL_IP=$(curl -sf "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip" \
  -H "Metadata-Flavor: Google" || echo "BRAK-IP")

log "========================================"
log "SETUP ZAKOŃCZONY"
log "Airflow UI:    http://$EXTERNAL_IP:30080  (admin / $ADMIN_PASSWORD)"
log "JupyterHub:    http://$EXTERNAL_IP:30088  (analityk01..16 / JupyterCourse2024!)"
log "========================================"

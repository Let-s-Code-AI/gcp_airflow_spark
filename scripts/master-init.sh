#!/bin/bash
set -euo pipefail
exec > /var/log/master-init.log 2>&1

META="http://metadata.google.internal/computeMetadata/v1/instance/attributes"
H="Metadata-Flavor: Google"
PROJECT_ID=$(curl -sf "$META/tf_project_id" -H "$H")
JOIN_BUCKET=$(curl -sf "$META/tf_join_bucket" -H "$H")
DAG_BUCKET=$(curl -sf  "$META/tf_dag_bucket"  -H "$H")
STUDENTS=$(curl -sf    "$META/tf_students"     -H "$H")

K8S_VERSION="1.29"
SPARK_VERSION="3.5.1"
HADOOP_VERSION="3"
AIRFLOW_VERSION="2.9.1"
POD_CIDR="192.168.0.0/16"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ── 1. System deps ─────────────────────────────────────────────────────────────
log "Aktualizacja systemu..."
apt-get update -qq
apt-get install -y -qq curl wget gnupg2 apt-transport-https ca-certificates \
  software-properties-common openjdk-17-jdk python3-pip python3-venv \
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

# ── 8. Spark Standalone (na master jako Spark master, workerzy dołączą sami) ──
log "Instalacja Apache Spark $SPARK_VERSION..."
SPARK_TGZ="spark-${SPARK_VERSION}-bin-hadoop${HADOOP_VERSION}.tgz"
wget -q "https://archive.apache.org/dist/spark/spark-${SPARK_VERSION}/$SPARK_TGZ" -P /tmp
tar -xzf "/tmp/$SPARK_TGZ" -C /opt
ln -s "/opt/spark-${SPARK_VERSION}-bin-hadoop${HADOOP_VERSION}" /opt/spark

cat <<'EOF' > /opt/spark/conf/spark-env.sh
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export SPARK_MASTER_HOST=$(hostname -I | awk '{print $1}')
export SPARK_MASTER_PORT=7077
export SPARK_MASTER_WEBUI_PORT=8181
export SPARK_WORKER_CORES=2
export SPARK_WORKER_MEMORY=6g
export SPARK_LOG_DIR=/var/log/spark
EOF

cat <<EOF > /opt/spark/conf/spark-defaults.conf
spark.master                     spark://$(hostname -I | awk '{print $1}'):7077
spark.eventLog.enabled           true
spark.eventLog.dir               /tmp/spark-events
spark.hadoop.google.cloud.auth.service.account.enable true
EOF

mkdir -p /var/log/spark /tmp/spark-events
chmod 777 /var/log/spark /tmp/spark-events

cat <<'EOF' > /etc/systemd/system/spark-master.service
[Unit]
Description=Apache Spark Master
After=network.target

[Service]
Type=forking
User=root
ExecStart=/opt/spark/sbin/start-master.sh
ExecStop=/opt/spark/sbin/stop-master.sh
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable spark-master
systemctl start spark-master

# Zapisz adres mastera Spark do GCS żeby workerzy wiedzieli dokąd się łączyć
SPARK_MASTER_IP=$(hostname -I | awk '{print $1}')
echo "spark://$SPARK_MASTER_IP:7077" | gsutil cp - "gs://$JOIN_BUCKET/spark-master-url"

# ── 9. Postgres (oficjalny obraz, bundled bitnami ma broken tagi) ──────────────
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

# ── 10. Airflow via Helm (1.15.0 + zewnętrzny postgres) ───────────────────────
log "Instalacja Apache Airflow via Helm..."
helm repo add apache-airflow https://airflow.apache.org
helm repo update

helm install airflow apache-airflow/airflow \
  --namespace airflow \
  --version "1.15.0" \
  --set "executor=LocalExecutor" \
  --set "dags.gitSync.enabled=false" \
  --set "dags.persistence.enabled=false" \
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

# ── 12. Konta studentów ────────────────────────────────────────────────────────
log "Tworzenie kont studentów w Airflow..."
AIRFLOW_POD=$(kubectl get pod -n airflow -l component=webserver -o jsonpath='{.items[0].metadata.name}')
python3 -c "
import json, subprocess
students = json.loads('$STUDENTS')
for s in students:
    subprocess.run([
        'kubectl', 'exec', '-n', 'airflow', '$AIRFLOW_POD', '--',
        'airflow', 'users', 'create',
        '--username', s,
        '--password', s + 'Pass123!',
        '--role', 'User',
        '--email', s + '@course.local',
        '--firstname', s,
        '--lastname', 'Student'
    ], check=False)
print(f'Utworzono {len(students)} kont studentów')
"

# ── Gotowe ─────────────────────────────────────────────────────────────────────
EXTERNAL_IP=$(curl -sf "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip" \
  -H "Metadata-Flavor: Google" || echo "BRAK-IP")

log "========================================"
log "SETUP ZAKOŃCZONY"
log "Airflow UI:    http://$EXTERNAL_IP:30080  (admin/admin)"
log "Spark UI:      http://$EXTERNAL_IP:8181"
log "========================================"

#!/bin/bash
set -euo pipefail
exec > /var/log/worker-init.log 2>&1

META="http://metadata.google.internal/computeMetadata/v1/instance/attributes"
H="Metadata-Flavor: Google"
JOIN_BUCKET=$(curl -sf "$META/tf_join_bucket" -H "$H")
WORKER_ID=$(curl -sf   "$META/tf_worker_id"   -H "$H")
SPARK_VERSION="3.5.1"
HADOOP_VERSION="3"
K8S_VERSION="1.29"

log() { echo "[$(date '+%H:%M:%S')] worker-$WORKER_ID: $*"; }

# ── 1. System deps ─────────────────────────────────────────────────────────────
log "Aktualizacja systemu..."
apt-get update -qq
apt-get install -y -qq curl wget gnupg2 apt-transport-https ca-certificates \
  software-properties-common openjdk-17-jdk

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

# ── 4. Czekaj na join-command od mastera (max 10 min) ─────────────────────────
log "Oczekiwanie na join-command z GCS..."
for i in $(seq 1 60); do
  if gsutil -q stat "gs://$JOIN_BUCKET/join-command.sh" 2>/dev/null; then
    break
  fi
  log "Próba $i/60 — plik jeszcze nie gotowy, czekam 10s..."
  sleep 10
done

gsutil cp "gs://$JOIN_BUCKET/join-command.sh" /tmp/join-command.sh
chmod +x /tmp/join-command.sh

log "Dołączanie do klastra K8s..."
bash /tmp/join-command.sh

# ── 5. Apache Spark Worker ────────────────────────────────────────────────────
log "Instalacja Apache Spark $SPARK_VERSION..."
SPARK_TGZ="spark-${SPARK_VERSION}-bin-hadoop${HADOOP_VERSION}.tgz"
wget -q "https://archive.apache.org/dist/spark/spark-${SPARK_VERSION}/$SPARK_TGZ" -P /tmp
tar -xzf "/tmp/$SPARK_TGZ" -C /opt
ln -s "/opt/spark-${SPARK_VERSION}-bin-hadoop${HADOOP_VERSION}" /opt/spark

# Pobierz adres Spark mastera
log "Oczekiwanie na adres Spark mastera..."
for i in $(seq 1 30); do
  if gsutil -q stat "gs://$JOIN_BUCKET/spark-master-url" 2>/dev/null; then
    break
  fi
  sleep 10
done

SPARK_MASTER_URL=$(gsutil cat "gs://$JOIN_BUCKET/spark-master-url")

cat <<EOF > /opt/spark/conf/spark-env.sh
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export SPARK_MASTER_HOST=$SPARK_MASTER_URL
export SPARK_WORKER_CORES=3
export SPARK_WORKER_MEMORY=12g
export SPARK_LOG_DIR=/var/log/spark
EOF

mkdir -p /var/log/spark /tmp/spark-events
chmod 777 /var/log/spark /tmp/spark-events

MASTER_IP=$(echo "$SPARK_MASTER_URL" | sed 's|spark://||' | cut -d: -f1)

cat <<EOF > /etc/systemd/system/spark-worker.service
[Unit]
Description=Apache Spark Worker $WORKER_ID
After=network.target

[Service]
Type=forking
User=root
ExecStart=/opt/spark/sbin/start-worker.sh $SPARK_MASTER_URL
ExecStop=/opt/spark/sbin/stop-worker.sh
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable spark-worker
systemctl start spark-worker

log "Worker $WORKER_ID gotowy. K8s + Spark worker uruchomiony."

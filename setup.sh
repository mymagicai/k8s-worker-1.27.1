#!/bin/bash

# initialize-k8s-node.sh
# This script prepares a Ubuntu server to join a Kubernetes cluster
# Run as root (sudo bash initialize-k8s-node.sh)

set -e  # Exit on any error

echo "[1/8] Creating necessary directories..."
mkdir -p /etc/kubernetes/manifests
mkdir -p /etc/systemd/system/kubelet.service.d
mkdir -p /var/lib/kubelet
mkdir -p /var/lib/dockershim
mkdir -p /var/lib/cni
mkdir -p /var/run/kubernetes
mkdir -p /etc/cni/net.d

echo "[2/8] Installing system dependencies..."
apt-get update
apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    linux-headers-$(uname -r) \
    iproute2 \
    net-tools \
    ethtool \
    socat \
    conntrack

echo "[3/8] Installing crictl..."
CRICTL_VERSION="v1.27.0"
curl -L https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-amd64.tar.gz --output crictl.tar.gz
tar zxvf crictl.tar.gz -C /usr/local/bin
rm -f crictl.tar.gz

# Configure crictl
cat > /etc/crictl.yaml <<EOF
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF

echo "[4/8] Setting up containerd..."
apt-get install -y containerd

# Configure containerd
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

echo "[5/8] Setting up system configurations..."
# Load necessary modules
modprobe overlay
modprobe br_netfilter

# Setup required sysctl params
cat > /etc/sysctl.d/kubernetes.conf <<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
EOF

# Apply sysctl params
sysctl --system

# Disable swap
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

echo "[6/8] Installing Kubernetes binaries..."
cd /root
mkdir -p kubernetes-1.27.1
cd kubernetes-1.27.1
curl -LO https://dl.k8s.io/v1.27.1/kubernetes-server-linux-amd64.tar.gz
echo "0752a63510a6d0ae06d8e24e42faa1641e093c25061f60b4c8355f735788ddd4bd25ae2a47a796064b6eb2ea15f0d451852fddc3c1b82b0e1afd279df700cea2 kubernetes-server-linux-amd64.tar.gz" | sha512sum --check
tar -xzvf kubernetes-server-linux-amd64.tar.gz
cd kubernetes/server/bin
chmod +x kubectl kubeadm kubelet
mv kubectl kubeadm kubelet /usr/local/bin/
cd /root
rm -rf kubernetes-1.27.1

echo "[7/8] Configuring kubelet..."
# Create kubelet service
cat > /etc/systemd/system/kubelet.service <<EOF
[Unit]
Description=kubelet: The Kubernetes Node Agent
Documentation=https://kubernetes.io/docs/home/
Wants=network-online.target
After=network-online.target

[Service]
ExecStart=/usr/local/bin/kubelet \\
    --container-runtime-endpoint=unix:///var/run/containerd/containerd.sock \\
    --bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf \\
    --kubeconfig=/etc/kubernetes/kubelet.conf \\
    --config=/var/lib/kubelet/config.yaml \\
    --register-node=true
Restart=always
StartLimitInterval=0
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Create kubelet configuration
cat > /var/lib/kubelet/config.yaml <<EOF
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
authentication:
  anonymous:
    enabled: false
  webhook:
    cacheTTL: 0s
    enabled: true
  x509:
    clientCAFile: /etc/kubernetes/pki/ca.crt
authorization:
  mode: Webhook
  webhook:
    cacheAuthorizedTTL: 0s
    cacheUnauthorizedTTL: 0s
cgroupDriver: systemd
clusterDNS:
- 10.96.0.10
clusterDomain: cluster.local
containerRuntimeEndpoint: unix:///var/run/containerd/containerd.sock
staticPodPath: /etc/kubernetes/manifests
networkPlugin: cni
EOF

echo "[8/8] Starting services..."
# Enable and start services
systemctl daemon-reload
systemctl enable containerd
systemctl enable kubelet
systemctl restart containerd
systemctl restart kubelet

echo "Node initialization complete!"
echo "To join the cluster, run the 'kubeadm join' command provided by your master node."
echo "Example: kubeadm join <master-ip>:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>"

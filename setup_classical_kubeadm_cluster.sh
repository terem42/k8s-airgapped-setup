#!/bin/bash
set -e

# Cluster configuration
CLUSTER_NAME="hetzner-cluster"

K8S_VERSION="1.34.1"
K8S_VERSION_NO_PATCH="1.34"

# CRI-O configuration - MUST match Kubernetes version
CRIO_VERSION="1.34"

CALICO_VERSION="3.25.0"
CLUSTER_CIDR="10.244.0.0/16"  # Pod network
SERVICE_CIDR="10.96.0.0/12"

LOAD_BALANCER_IP="10.0.0.2"
LOAD_BALANCER_PORT="8443"

CONTROL_PLANE_ENDPOINT="$LOAD_BALANCER_IP:$LOAD_BALANCER_PORT" # using  HAProxy on master node

# Air-gapped installation configuration
# Path on each node where Docker image tar archives are stored
# Set to empty string "" to skip loading images (for online installation)
AIRGAPPED_IMAGES_PATH="/mnt/usb/k8s-images"

# Network configuration
PRIVATE_NETWORK_CIDR="10.0.0.0/16"
PRIVATE_NETWORK_PREFIX="10.0."
GATEWAY="10.0.0.1"  # Hetzner private network gateway

# Node configuration - all nodes are remote from local workstation
CONTROL_PLANES=("dev01" "dev02" "dev03")
WORKERS=()  # Add worker nodes here if needed, e.g., ("worker01" "worker02")
NODES=("${CONTROL_PLANES[@]}" "${WORKERS[@]}")

# Kernel requirements for Calico (less strict than Cilium)
MIN_KERNEL_MAJOR=4
MIN_KERNEL_MINOR=19

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Global array to store node IPs
declare -A NODE_IPS

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"
    exit 1
}

# Function to check kernel version compatibility with Calico
check_kernel_version() {
    local node="$1"
    local kernel_check_cmd="
    KERNEL_MAJOR=\$(uname -r | cut -d. -f1)
    KERNEL_MINOR=\$(uname -r | cut -d. -f2)  
    
    if [ \$KERNEL_MAJOR -gt $MIN_KERNEL_MAJOR ] || \
       { [ \$KERNEL_MAJOR -eq $MIN_KERNEL_MAJOR ] && [ \$KERNEL_MINOR -ge $MIN_KERNEL_MINOR ]; }; then
        echo 'PASS'
    else
        echo 'FAIL'
        echo 'Kernel: '\$KERNEL_MAJOR.\$KERNEL_MINOR
    fi
    "
    
    local result
    result=$(ssh k8s-admin@$node "$kernel_check_cmd")
    
    if [[ "$result" == *"FAIL"* ]]; then
        error "Kernel version check failed on $node: $result. Calico requires Linux kernel >=$MIN_KERNEL_MAJOR.$MIN_KERNEL_MINOR"
    else
        log "Kernel version check passed on $node"
    fi
}

# Function to discover private IP address on a node
discover_private_ip() {
    local node="$1"
    local ip_cmd="ip -o -4 addr show | awk '{print \$4}' | cut -d'/' -f1 | grep '^$PRIVATE_NETWORK_PREFIX' | head -1"
    
    local private_ip
    private_ip=$(ssh k8s-admin@$node "$ip_cmd")
    
    if [ -z "$private_ip" ]; then
        error "No private IP address found in network $PRIVATE_NETWORK_CIDR on node $node"
    fi
    
    echo "$private_ip"
}

# Function to check private network routing on a node
check_private_routing() {
    local node="$1"
    local route_cmd="ip route show | grep '$PRIVATE_NETWORK_CIDR via $GATEWAY' || true"
    
    local route
    route=$(ssh k8s-admin@$node "$route_cmd")
    
    if [ -z "$route" ]; then
        warn "Private network route to $PRIVATE_NETWORK_CIDR via $GATEWAY not found on $node. Hetzner DHCP should set this; check configuration."
    else
        log "Private network routing check passed on $node"
    fi
}

# Function to discover IPs on all nodes
discover_all_private_ips() {
    log "Discovering private IP addresses in network $PRIVATE_NETWORK_CIDR"
    
    for node in "${NODES[@]}"; do
        log "Discovering private IP on $node..."
        local private_ip=$(discover_private_ip "$node")
        
        if [ -n "$private_ip" ]; then
            NODE_IPS["$node"]="$private_ip"
            log "✓ $node private IP: $private_ip"
        else
            error "Failed to discover private IP for $node in network $PRIVATE_NETWORK_CIDR"
        fi
    done
    
    if [ ${#NODE_IPS[@]} -ne ${#NODES[@]} ]; then
        error "Failed to discover private IPs for all nodes. Found: ${#NODE_IPS[@]}, Expected: ${#NODES[@]}"
    fi
    
    log "All private IP addresses discovered successfully:"
    for node in "${!NODE_IPS[@]}"; do
        log "  $node: ${NODE_IPS[$node]}"
    done   
        
    log "Control plane endpoint set to: $CONTROL_PLANE_ENDPOINT"
    warn "Using port 8443 for HAProxy on master node. For production, consider a dedicated load balancer for true HA without SPOF."
}

# Function to run command on remote node
run_on_node() {
    local node="$1"
    local cmd="$2"
    
    log "Running on $node: $cmd"
    ssh k8s-admin@$node "$cmd"
}

# Function to run command on all nodes
run_on_all_nodes() {
    local cmd="$1"
    for node in "${NODES[@]}"; do
        log "Running on $node: $cmd"
        ssh k8s-admin@$node "$cmd" || warn "Command failed on $node, but continuing..."
    done
}

# Function to copy file to remote node
copy_to_node() {
    local node="$1"
    local src="$2"
    local dest="$3"
    
    log "Copying $src to $node:$dest"
    scp "$src" "k8s-admin@$node:$dest"
}

# Function to copy file from remote node
copy_from_node() {
    local node="$1"
    local src="$2"
    local dest="$3"
    
    log "Copying $node:$src to $dest"
    scp "k8s-admin@$node:$src" "$dest"
}

# Function to load Docker images from tar archives for air-gapped installation
# Uses crictl load -i for CRI-O runtime
load_airgapped_images() {
    local node="$1"
    
    # Skip if AIRGAPPED_IMAGES_PATH is not set or empty
    if [ -z "$AIRGAPPED_IMAGES_PATH" ]; then
        log "Skipping air-gapped images loading (AIRGAPPED_IMAGES_PATH not configured)"
        return 0
    fi
    
    log "Loading container images from tar archives on $node"
    log "Images path: $AIRGAPPED_IMAGES_PATH"
    
    # Check if the images directory exists on the node
    if ! ssh k8s-admin@$node "test -d '$AIRGAPPED_IMAGES_PATH'"; then
        error "Air-gapped images directory not found on $node: $AIRGAPPED_IMAGES_PATH"
    fi
    
    # Get list of tar files in the images directory
    local tar_files=$(ssh k8s-admin@$node "find '$AIRGAPPED_IMAGES_PATH' -maxdepth 1 -name '*.tar' -type f 2>/dev/null | sort")
    
    if [ -z "$tar_files" ]; then
        warn "No tar files found in $AIRGAPPED_IMAGES_PATH on $node"
        return 0
    fi
    
    # Count total images for progress tracking
    local total_images=$(echo "$tar_files" | wc -l)
    local current=0
    local failed=0
    
    log "Found $total_images image tar file(s) to load on $node"
    
    # Load each tar file
    while IFS= read -r tar_file; do
        [ -z "$tar_file" ] && continue
        
        current=$((current + 1))
        local filename=$(basename "$tar_file")
        
        log "  [$current/$total_images] Loading: $filename"
        
        if ssh k8s-admin@$node "sudo crictl load -i '$tar_file'" 2>&1; then
            log "  ✓ Successfully loaded: $filename"
        else
            warn "  ✗ Failed to load: $filename"
            failed=$((failed + 1))
        fi
    done <<< "$tar_files"
    
    # Summary
    local succeeded=$((total_images - failed))
    log "Image loading completed on $node: $succeeded/$total_images succeeded"
    
    if [ $failed -gt 0 ]; then
        warn "$failed image(s) failed to load on $node"
    fi
    
    # Verify loaded images
    log "Verifying loaded images on $node:"
    ssh k8s-admin@$node "sudo crictl images" || warn "Could not list images on $node"
    
    log "✓ Air-gapped images loading completed on $node"
}

# Function to load images on all nodes
load_airgapped_images_all_nodes() {
    if [ -z "$AIRGAPPED_IMAGES_PATH" ]; then
        log "Skipping air-gapped images loading (AIRGAPPED_IMAGES_PATH not configured)"
        return 0
    fi
    
    log "Loading air-gapped container images on all nodes..."
    
    for node in "${NODES[@]}"; do
        load_airgapped_images "$node"
    done
    
    log "✓ Air-gapped images loaded on all nodes"
}

# Function to setup CRI-O networking for Calico
setup_crio_networking() {
    local node="$1"
    log "Setting up CRI-O networking and registry configuration on $node"
    
    # Create CRI-O network configuration
    run_on_node $node "sudo mkdir -p /etc/cni/net.d"
    
    # Configure CRI-O to use Calico CNI
    cat <<EOF | ssh k8s-admin@$node "sudo tee /etc/cni/net.d/10-calico.conflist > /dev/null"
{
  "name": "k8s-pod-network",
  "cniVersion": 0.3.1,
  "plugins": [
    {
      "type": "calico",
      "log_level": "info",
      "datastore_type": "kubernetes",
      "nodename": "$node",
      "mtu": 1440,
      "ipam": {
        "type": "calico-ipam"
      },
      "policy": {
        "type": "k8s"
      },
      "kubernetes": {
        "kubeconfig": "/etc/cni/net.d/calico-kubeconfig"
      }
    },
    {
      "type": "portmap",
      "snat": true,
      "capabilities": {"portMappings": true}
    },
    {
      "type": "bandwidth",
      "capabilities": {"bandwidth": true}
    }
  ]
}
EOF

    # Configure CRI-O registries using the correct separate files
    log "Configuring CRI-O registries and short-name resolution on $node"
    
    # 1. Configure search registries in containers/registries.conf
    run_on_node $node "sudo mkdir -p /etc/containers"
    cat <<EOF | ssh k8s-admin@$node "sudo tee /etc/containers/registries.conf > /dev/null"
[registries]    
unqualified-search-registries = ["docker.io", "quay.io"]
EOF

    # 2. Configure short-name mode in CRI-O specific config
    run_on_node $node "sudo mkdir -p /etc/crio/crio.conf.d"
    cat <<EOF | ssh k8s-admin@$node "sudo tee /etc/crio/crio.conf.d/00-short-names.conf > /dev/null"
[crio.image]
 short_name_mode="disabled"
EOF

    log "✓ CRI-O networking and registry configuration completed on $node"
}

# Function to setup audit policy on all control plane nodes
setup_audit_policy() {
    log "Setting up audit policy on all control plane nodes"
    
    for node in "${CONTROL_PLANES[@]}"; do
        log "Setting up audit policy on $node"
        
        # Create directories
        run_on_node $node "sudo mkdir -p /etc/kubernetes"
        run_on_node $node "sudo mkdir -p /var/log/apiserver"
        
        # Create audit policy file directly using heredoc pipe
        cat <<EOF | ssh k8s-admin@$node "sudo tee /etc/kubernetes/audit-policy.yaml > /dev/null"
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  - level: Metadata
EOF
        
        log "✓ Audit policy configured on $node"
    done
    
    log "Audit policy setup completed on all control plane nodes"
}

# Basic setup for ALL nodes (no kubelet start)
setup_node_basic() {
    local node=$1
    local node_ip=${NODE_IPS[$node]}
    
    log "Basic setup for node: $node (IP: $node_ip)"
    
    # Check kernel version
    check_kernel_version "$node"
    
    # Check private routing
    check_private_routing "$node"

    # stop unattended-upgrades, if any
    stop_unattended_upgrades "$node"    
    
    # Disable swap
    run_on_node $node "sudo swapoff -a"
    run_on_node $node "sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab"
    
    # Load kernel modules
    run_on_node $node "sudo modprobe br_netfilter"
    run_on_node $node "sudo modprobe overlay"
    
    # Create sysctl config
    run_on_node $node "cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF"
    run_on_node $node "sudo sysctl --system"
    
    # Install dependencies
    run_on_node $node "sudo apt-get update && sudo apt-get install -y apt-transport-https ca-certificates curl gpg software-properties-common etcd-client software-properties-common cri-o runc"

    # Setup CRI-O networking for Calico
    setup_crio_networking "$node"

    # Start and enable CRI-O
    run_on_node $node "sudo systemctl daemon-reload"
    run_on_node $node "sudo systemctl enable crio --now"
    run_on_node $node "sudo systemctl status crio --no-pager"   
    
    log "Basic setup completed for $node"
}

# Function to stop unattended-upgrades
stop_unattended_upgrades() {
    local node="$1"
    
    log "Stopping unattended-upgrades on $node"
    run_on_node $node "sudo systemctl stop unattended-upgrades"
    run_on_node $node "sudo systemctl disable unattended-upgrades"  # Optional: disable for current boot
    
    # Verify it's stopped
    if run_on_node $node "pgrep unattended-upgr > /dev/null 2>&1"; then
        warn "unattended-upgrades still running, attempting to kill"
        run_on_node $node "sudo pkill -9 unattended-upgr"
    fi
    
    # Also kill any apt processes that might be stuck
    run_on_node $node "sudo pkill -9 apt-get || true"
    run_on_node $node "sudo pkill -9 apt || true"
    run_on_node $node "sudo pkill -9 dpkg || true"
}

# node setup (includes kubeadm install but no kubelet start)
setup_kubernetes_node() {
    local node=$1
    local node_type=$2  # "control-plane" or "worker"
    local node_ip=${NODE_IPS[$node]}    
    
    log "Kubernetes setup for $node_type: $node (IP: $node_ip)"
    
    # Install packages based on node type
    if [ "$node_type" = "control-plane" ]; then
        run_on_node $node "sudo apt-get update && sudo apt-get install -y kubelet kubeadm kubectl"
    else
        run_on_node $node "sudo apt-get update && sudo apt-get install -y kubelet kubeadm"
    fi
    
    # Common configuration
    # Skip image pull if using air-gapped installation (images loaded from tar files)
    if [ -z "$AIRGAPPED_IMAGES_PATH" ]; then
        run_on_node $node "sudo kubeadm config images pull --cri-socket unix:///var/run/crio/crio.sock"
    else
        log "Skipping kubeadm images pull (air-gapped mode - images loaded from tar files)"
    fi
    run_on_node $node "cat <<EOF | sudo tee /etc/default/kubelet
KUBELET_EXTRA_ARGS=--node-ip=$node_ip --container-runtime-endpoint=unix:///var/run/crio/crio.sock --runtime-request-timeout=5m --cgroup-driver=systemd
EOF"
    run_on_node $node "sudo systemctl enable kubelet"
    
    log "Kubernetes setup completed for $node ($node_type)"
}

# Initialize the first control plane node with CRI-O socket
init_first_control_plane() {
    local dev01_ip=${NODE_IPS[dev01]}
    
    log "Initializing first control plane node on dev01 (IP: $dev01_ip)"
    
    # Create and copy kubeadm config using heredoc pipeline
    log "Creating kubeadm configuration with API version v1beta4"
    cat <<EOF | ssh k8s-admin@dev01 "sudo tee /root/kubeadm-config.yaml > /dev/null"
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: $dev01_ip
  bindPort: 6443
nodeRegistration:
  kubeletExtraArgs:
    - name: node-ip
      value: $dev01_ip
    - name: container-runtime-endpoint
      value: unix:///var/run/crio/crio.sock
    - name: runtime-request-timeout
      value: 5m
    - name: cgroup-driver
      value: systemd
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v$K8S_VERSION
controlPlaneEndpoint: "$CONTROL_PLANE_ENDPOINT"
networking:
  serviceSubnet: "$SERVICE_CIDR"
  podSubnet: "$CLUSTER_CIDR"
  dnsDomain: "cluster.local"
apiServer:
  extraArgs:
    - name: audit-log-path
      value: /var/log/apiserver/audit.log
    - name: audit-log-maxage
      value: "30"
    - name: audit-log-maxbackup
      value: "10"
    - name: audit-log-maxsize
      value: "100"
    - name: audit-policy-file
      value: /etc/kubernetes/audit-policy.yaml
  extraVolumes:
    - name: audit
      hostPath: /var/log/apiserver
      mountPath: /var/log/apiserver
      pathType: DirectoryOrCreate
      readOnly: false
    - name: audit-policy
      hostPath: /etc/kubernetes/audit-policy.yaml
      mountPath: /etc/kubernetes/audit-policy.yaml
      pathType: File
      readOnly: true
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
EOF

    # Initialize cluster with CRI-O socket (keep kube-proxy for Calico)
    log "Initializing Kubernetes cluster with kubeadm"
    run_on_node dev01 "sudo kubeadm init --config /root/kubeadm-config.yaml --upload-certs"
    
    # Setup kubectl for admin user on dev01
    log "Setting up kubectl configuration"
    run_on_node dev01 "mkdir -p /home/k8s-admin/.kube"
    run_on_node dev01 "sudo cp /etc/kubernetes/admin.conf /home/k8s-admin/.kube/config"
    run_on_node dev01 "sudo chown k8s-admin:k8s-admin /home/k8s-admin/.kube/config"
    
    # Also copy to root on dev01
    run_on_node dev01 "sudo mkdir -p /root/.kube"
    run_on_node dev01 "sudo cp /etc/kubernetes/admin.conf /root/.kube/config"
    
    # Copy kubeconfig to local workstation for kubectl access
    log "Copying kubeconfig to local workstation..."
    mkdir -p ~/.kube
    copy_from_node dev01 "/home/k8s-admin/.kube/config" ~/.kube/config
    
    log "First control plane initialized successfully with CRI-O"
}

# pre-join health check with ports reachability tests
pre_join_check_node_health() {
    local node=$1
    local node_type=$2  # "control-plane" or "worker"
    
    log "Performing pre-join health check on $node ($node_type)"
    
    # Basic checks
    local checks=(        
        "crio_service:sudo systemctl is-active crio"
        "container_runtime:sudo crictl info"
        "kubelet_binary:timeout 5 /usr/bin/kubelet --version"
        "kubelet_config:test -f /etc/default/kubelet"
        "swap:! (free | grep -q swap && [ \$(free | grep swap | awk '{print \$2}') -ne 0 ])"
        "kernel_modules:lsmod | grep -q br_netfilter && lsmod | grep -q overlay"
    )    
    
    local ports_checks=(
        "6443:kubernetes_apiserver:${NODE_IPS[dev01]}"
        "8443:haproxy_apiserver:$LOAD_BALANCER_IP"
    )
    
    # For control plane nodes joining, also check etcd ports
    if [ "$node_type" = "control-plane" ]; then
        ports_checks+=(
            "2379:etcd_client:${NODE_IPS[dev01]}"
            "2380:etcd_peer:${NODE_IPS[dev01]}"
        )
    fi
    
    # Run basic checks
    for check in "${checks[@]}"; do
        local name=${check%%:*}
        local cmd=${check#*:}
        
        if ssh k8s-admin@$node "$cmd" >/dev/null 2>&1; then
            log "  ✓ $name"
        else
            error "$name check failed on $node"
        fi
    done
    
    # Run ports reachability tests
    log "  Testing ports reachability to control plane:"
    for port_check in "${ports_checks[@]}"; do
        local port=${port_check%%:*}
        local remainder=${port_check#*:}
        local service=${remainder%%:*}
        local target_ip=${remainder#*:}
        
        if ssh k8s-admin@$node "timeout 3 nc -z -w 2 $target_ip $port" >/dev/null 2>&1; then
            log "    ✓ $service ($target_ip:$port)"
        else
            error "Cannot reach $service on $target_ip:$port from $node"
        fi
    done
    
    # Additional control plane specific checks
    if [ "$node_type" = "control-plane" ]; then
        log "  Testing control plane specific requirements:"
        
        # Verify kubeadm can pull control plane images (skip in air-gapped mode)
        if [ -z "$AIRGAPPED_IMAGES_PATH" ]; then
            if ssh k8s-admin@$node "sudo kubeadm config images pull --cri-socket unix:///var/run/crio/crio.sock >/dev/null 2>&1"; then
                log "    ✓ kubeadm can pull control plane images"
            else
                error "kubeadm failed to pull control plane images on $node"
            fi
        else
            log "    ✓ Skipping image pull check (air-gapped mode)"
        fi
        
        # Verify required ports are not in use locally
        local local_ports=("6443" "2379" "2380")
        for port in "${local_ports[@]}"; do
            if ssh k8s-admin@$node "sudo ss -tulpn | grep -q \":$port \""; then
                warn "Port $port is already in use on $node (may conflict during join)"
            else
                log "    ✓ Port $port available for binding"
            fi
        done
    fi
    
    log "✓ All pre-join health checks passed for $node"
}

# Dedicated health check phase
perform_pre_join_health_checks() {
    
    # Check all additional control planes
    for node in "${CONTROL_PLANES[@]:1}"; do
        log "=== Pre-join health check for control plane: $node ==="
        pre_join_check_node_health "$node" "control-plane"
    done
    
    # Check all workers
    for node in "${WORKERS[@]}"; do
        log "=== Pre-join health check for worker: $node ==="
        pre_join_check_node_health "$node" "worker"
    done
    
    log "✓ All nodes passed pre-join health checks - ready for cluster join"
}

# Check control plane etcd health
check_control_plane_etcd_health() {
    log "Checking etcd cluster health on control plane (dev01)"
    
    # Run etcdctl health check and capture exit code
    if ssh k8s-admin@dev01 "sudo ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key endpoint health > /dev/null 2>&1"; then
        log "✓ etcd cluster is healthy and ready to accept new members"
    else
        error "etcd cluster is not healthy on control plane node (dev01)"
    fi
}

# Join other control plane nodes
join_control_plane_nodes() {
    log "Joining other control plane nodes"
    
    # Get join command for control plane nodes - extract only the actual command
    local full_output=$(run_on_node dev01 "sudo kubeadm token create --print-join-command" 2>/dev/null)
    local join_cmd=$(echo "$full_output" | grep '^kubeadm join')
    local cert_key=$(run_on_node dev01 "sudo kubeadm init phase upload-certs --upload-certs" 2>/dev/null | tail -1)
    
    if [[ -z "$join_cmd" || -z "$cert_key" ]]; then
        error "Failed to get join command or certificate key"
    fi
    
    log "Join command: $join_cmd"
    log "Certificate key: $cert_key"
    
    for node in "${CONTROL_PLANES[@]:1}"; do
        local node_ip=${NODE_IPS[$node]}
        log "Joining $node as control plane node (IP: $node_ip)"
        run_on_node $node "sudo $join_cmd --control-plane --certificate-key $cert_key --apiserver-advertise-address=$node_ip --cri-socket unix:///var/run/crio/crio.sock"
        
        # Copy kubeconfig using reliable temp file approach
        log "Copying kubeconfig from dev01 to $node"
        local temp_kubeconfig=$(mktemp)
        
        # Copy FROM dev01 to local temp file
        copy_from_node dev01 "/home/k8s-admin/.kube/config" "$temp_kubeconfig"
        
        # Create .kube directory on the target node first
        run_on_node $node "sudo mkdir -p /home/k8s-admin/.kube"
        run_on_node $node "sudo chown k8s-admin:k8s-admin /home/k8s-admin/.kube"
        
        # Copy FROM local temp file TO the target node
        copy_to_node $node "$temp_kubeconfig" "/home/k8s-admin/.kube/config"
        
        # Set proper ownership on the target node
        run_on_node $node "sudo chown k8s-admin:k8s-admin /home/k8s-admin/.kube/config"
        
        # Clean up local temp file
        rm -f "$temp_kubeconfig"
        
        log "Kubeconfig copied successfully to $node"
    done
    
    log "All control plane nodes joined successfully"
}

# Join worker nodes
join_worker_nodes() {
    if [ ${#WORKERS[@]} -eq 0 ]; then
        log "No worker nodes defined, skipping worker join"
        return
    fi
    
    log "Joining worker nodes"
    
    # Get join command for workers - extract only the actual command
    local full_output=$(run_on_node dev01 "sudo kubeadm token create --print-join-command" 2>/dev/null)
    local join_cmd=$(echo "$full_output" | grep '^kubeadm join')
    
    if [[ -z "$join_cmd" ]]; then
        error "Failed to get join command for workers"
    fi
    
    log "Worker join command: $join_cmd"
    
    for node in "${WORKERS[@]}"; do
        local node_ip=${NODE_IPS[$node]}
        log "Joining $node as worker node (IP: $node_ip)"
        run_on_node $node "sudo $join_cmd --cri-socket unix:///var/run/crio/crio.sock"
        
        # Copy kubeconfig to workers (optional for admin access) using reliable temp file approach
        log "Copying kubeconfig from dev01 to worker $node"
        local temp_kubeconfig=$(mktemp)
        
        # Copy FROM dev01 to local temp file
        copy_from_node dev01 "/home/k8s-admin/.kube/config" "$temp_kubeconfig"

        # Create .kube directory on the target node first
        run_on_node $node "sudo mkdir -p /home/k8s-admin/.kube"
        run_on_node $node "sudo chown k8s-admin:k8s-admin /home/k8s-admin/.kube"        
        
        # Copy FROM local temp file TO the worker node
        copy_to_node $node "$temp_kubeconfig" "/home/k8s-admin/.kube/config"
        
        # Set proper ownership on the worker node
        run_on_node $node "sudo chown k8s-admin:k8s-admin /home/k8s-admin/.kube/config"
        
        # Clean up local temp file
        rm -f "$temp_kubeconfig"
        
        log "Kubeconfig copied successfully to worker $node"
    done
    
    log "All worker nodes joined successfully"
}

# Set optimized resource limits for control plane components
set_control_plane_resources() {
    log "Setting optimized resource limits for control plane"
    
    kubectl get nodes >/dev/null 2>&1 || error "Control plane not healthy"
    
    local resources=(
        "etcd:100m:256Mi:500m:1Gi"
        "kube-apiserver:250m:512Mi:1:2Gi" 
        "kube-controller-manager:100m:256Mi:500m:1Gi"
        "kube-scheduler:50m:128Mi:250m:512Mi"
    )
    
    for node in "${CONTROL_PLANES[@]}"; do
        log "Configuring resources on $node"
        for resource in "${resources[@]}"; do
            IFS=':' read -r component requests_cpu requests_mem limits_cpu limits_mem <<< "$resource"
            run_on_node $node "sudo yq e '.spec.containers[0].resources = {\"requests\": {\"cpu\": \"$requests_cpu\", \"memory\": \"$requests_mem\"}, \"limits\": {\"cpu\": \"$limits_cpu\", \"memory\": \"$limits_mem\"}}' -i /etc/kubernetes/manifests/${component}.yaml"
            log "  ✓ $component"
        done
    done
    
    log "Resource limits applied - control plane pods restarting"
}

# Function to wait for unattended-upgrades to complete
wait_for_unattended_upgrades() {
    local node="$1"
    local timeout=300
    local counter=0
    
    log "Checking for unattended-upgrades on $node..."
    
    while [ $counter -lt $timeout ]; do
        if ! run_on_node $node "pgrep unattended-upgr > /dev/null 2>&1"; then
            log "✓ No unattended-upgrades running on $node"
            return 0
        fi
        log "Waiting for unattended-upgrades to complete on $node... ($counter/$timeout seconds)"
        sleep 10
        counter=$((counter + 10))
    done
    
    warn "unattended-upgrades still running after $timeout seconds, forcing continue"
}

# Install Calico CNI using the official calico.yaml manifest, then apply custom IPPool
install_calico() {
    log "Installing Calico CNI using official manifest from https://docs.projectcalico.org/manifests/calico.yaml"    
    
    # Function to check API server health
    check_api_server_health() {
        local max_attempts=30
        local attempt=1
        
        while [ $attempt -le $max_attempts ]; do
            if kubectl get nodes --request-timeout=5s >/dev/null 2>&1; then
                log "✓ API server is responsive"
                return 0
            fi
            log "Waiting for API server to be responsive... (attempt $attempt/$max_attempts)"
            sleep 10
            attempt=$((attempt + 1))
        done
        error "API server is not responsive after $max_attempts attempts"
    }
    
    # Ensure API server is healthy before starting
    log "Checking API server health before installing Calico"
    check_api_server_health
    
    # Apply the Calico manifest with retry logic
    log "Applying Calico manifest (with retry logic)"
    local max_retries=3
    local retry_count=0
    
    while [ $retry_count -lt $max_retries ]; do
        if kubectl apply -f ./calico.yaml; then
            log "✓ Calico manifest applied successfully"
            break
        else
            retry_count=$((retry_count + 1))
            warn "Calico apply failed (attempt $retry_count/$max_retries), waiting for API server to stabilize..."
            sleep 20
            
            # Check API server health before retry
            check_api_server_health
        fi
    done
    
    if [ $retry_count -eq $max_retries ]; then
        error "Failed to apply Calico manifest after $max_retries attempts"
    fi    
    
    # Wait for Calico pods to be scheduled and become ready
    log "Waiting for Calico pods to be ready (this may take a few minutes)"
    
    # Give some time for pods to be scheduled and API server to stabilize
    sleep 30
    
    # Check API server health again before waiting for pods
    check_api_server_health
    
    # Now wait for pods to be ready with a longer timeout and retry logic
    log "Waiting for calico-node pods to be ready"
    local pod_timeout=300
    local pod_attempt=1
    local max_pod_attempts=3
    
    while [ $pod_attempt -le $max_pod_attempts ]; do
        if kubectl wait --for=condition=ready pod -l k8s-app=calico-node -n kube-system --timeout=180s 2>/dev/null; then
            log "✓ Calico node pods are ready"
            break
        else
            pod_attempt=$((pod_attempt + 1))
            if [ $pod_attempt -le $max_pod_attempts ]; then
                warn "Calico node pods not ready yet (attempt $pod_attempt/$max_pod_attempts)"
                sleep 20
                check_api_server_health
            else
                warn "Calico node pods took longer than expected to become ready, but continuing..."
                # Show current pod status for debugging
                kubectl get pods -n kube-system -l k8s-app=calico-node || true
            fi
        fi
    done
    
    # Wait for calico-kube-controllers with similar retry logic
    log "Waiting for calico-kube-controllers pod to be ready"
    if kubectl wait --for=condition=ready pod -l k8s-app=calico-kube-controllers -n kube-system --timeout=120s 2>/dev/null; then
        log "✓ Calico kube-controllers pod is ready"
    else
        warn "Calico kube-controllers pod took longer than expected, but continuing..."
        kubectl get pods -n kube-system -l k8s-app=calico-kube-controllers || true
    fi
    
    # Check Calico pods status after configuration change
    log "Checking Calico pods status after VXLAN configuration..."
    kubectl get pods -n kube-system -l k8s-app=calico-node
    
    # Final health check
    check_api_server_health
    
    log "Calico installed successfully with custom VXLAN configuration"
}

# Remove taints to allow scheduling on control plane nodes
allow_scheduling_on_control_plane() {
    log "Removing taints from control plane nodes to allow workload scheduling"
    
    for node in "${CONTROL_PLANES[@]}"; do
        kubectl taint nodes $node node-role.kubernetes.io/control-plane- 2>/dev/null || true
        kubectl taint nodes $node node-role.kubernetes.io/master- 2>/dev/null || true
        log "Taints removed from $node"
    done
    
    log "Control plane nodes are now schedulable for workloads"
}

# Install etcd backup CronJob on all control plane nodes
install_etcd_backup() {
    log "Installing etcd backup CronJob on all control plane nodes"
    
    for node in "${CONTROL_PLANES[@]}"; do
        local node_ip=${NODE_IPS[$node]}
        log "Installing etcd backup on control plane node: $node (IP: $node_ip)"
        
        cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: CronJob
metadata:
  name: etcd-backup-${node}
  namespace: kube-system
spec:
  schedule: "0 */6 * * *"
  jobTemplate:
    spec:
      template:
        spec:
          nodeSelector:
            kubernetes.io/hostname: $node
          initContainers:
          - name: etcd-snapshot
            image: registry.k8s.io/etcd:3.6.4-0
            imagePullPolicy: IfNotPresent
            command:
            - /bin/sh
            - -c
            - |
              set -e
              BACKUP_FILE="/backup/etcd-snapshot-latest.db"
              echo "Taking etcd snapshot on node $node: \$BACKUP_FILE"
              
              # Take the snapshot - this is the ONLY thing etcd container does
              ETCDCTL_API=3 etcdctl \
                --endpoints=https://127.0.0.1:2379 \
                --cacert=/etc/kubernetes/pki/etcd/ca.crt \
                --cert=/etc/kubernetes/pki/etcd/server.crt \
                --key=/etc/kubernetes/pki/etcd/server.key \
                snapshot save \$BACKUP_FILE
              
              echo "etcdctl snapshot command completed successfully on $node"
            volumeMounts:
            - name: etcd-certs
              mountPath: /etc/kubernetes/pki/etcd
              readOnly: true
            - name: backup
              mountPath: /backup
            resources:
              requests:
                cpu: 50m
                memory: 64Mi
              limits:
                cpu: 200m
                memory: 256Mi
          
          containers:
          - name: backup-processor
            image: quay.io/quay/busybox:latest
            imagePullPolicy: IfNotPresent
            command:
            - /bin/sh
            - -c
            - |
              echo "Starting backup post-processing on node $node..."
              
              # Verify the backup file exists and has content
              BACKUP_SRC="/backup/etcd-snapshot-latest.db"
              if [ ! -f "\$BACKUP_SRC" ]; then
                echo "✗ Backup file not found at \$BACKUP_SRC"
                exit 1
              fi
              
              FILE_SIZE=\$(stat -c%s "\$BACKUP_SRC")
              if [ "\$FILE_SIZE" -eq 0 ]; then
                echo "✗ Backup file exists but is empty (0 bytes)"
                exit 1
              fi
              
              echo "✓ Backup file verified: \$BACKUP_SRC (\$FILE_SIZE bytes)"
              
              # Add timestamp to the backup
              TIMESTAMP=\$(date +%Y%m%d-%H%M%S)
              BACKUP_DST="/backup/etcd-snapshot-\${TIMESTAMP}.db"
              
              echo "Creating timestamped backup: \$BACKUP_DST"
              cp "\$BACKUP_SRC" "\$BACKUP_DST"
              
              # Verify copy was successful
              if [ -f "\$BACKUP_DST" ]; then
                NEW_FILE_SIZE=\$(stat -c%s "\$BACKUP_DST")
                echo "✓ Backup created: \$BACKUP_DST (\$NEW_FILE_SIZE bytes)"
                
                # Clean up old backups (keep last 7 days)
                echo "Cleaning up backups older than 7 days..."
                find /backup -name "etcd-snapshot-*.db" -type f -mtime +7 -delete
                
                # Enforce maximum count as safety net (keep last 50 max)
                echo "Enforcing maximum backup count (last 50)..."
                ls -tp /backup/etcd-snapshot-*.db 2>/dev/null | grep -v '/$' | tail -n +51 | xargs -I {} rm -f {}
                
                echo "Current backups on $node:"
                ls -lht /backup/etcd-snapshot-*.db 2>/dev/null | head -10 || echo "No backups found"
              else
                echo "✗ Failed to create timestamped backup"
                exit 1
              fi
              
              echo "✓ Backup processing completed successfully on $node"
            volumeMounts:
            - name: backup
              mountPath: /backup
            resources:
              requests:
                cpu: 10m
                memory: 32Mi
              limits:
                cpu: 100m
                memory: 128Mi
          
          volumes:
          - name: etcd-certs
            hostPath:
              path: /etc/kubernetes/pki/etcd
              type: Directory
          - name: backup
            hostPath:
              path: /var/backup/etcd
              type: DirectoryOrCreate
          restartPolicy: OnFailure
          hostNetwork: true
EOF
        log "✓ etcd backup CronJob installed on $node"
    done
    
    log "etcd backup CronJobs installed on all control plane nodes (hourly snapshots)"
}

# Apply default deny network policy
apply_default_deny_policy() {
    log "Applying default deny network policy in default namespace"
    
    cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
EOF

    log "Default deny network policy applied. Add allow policies as needed."
}

# Verify cluster status
verify_cluster() {
    log "Verifying cluster status"
    
    log "=== Node Status ==="
    kubectl get nodes -o wide
    
    log "=== System Pod Status ==="
    kubectl get pods -n kube-system  
    
    log "=== Service Status ==="
    kubectl get services -A    
    
    log "=== Checking CRI-O runtime ==="
    kubectl get nodes -o wide | grep -q cri-o && echo 'CRI-O runtime detected' || echo 'CRI-O runtime NOT detected'
    
    log "Cluster verification completed"
}

# Check connectivity to all nodes
check_connectivity() {
    log "Checking connectivity to all nodes..."
    for node in "${NODES[@]}"; do
        if ssh -o ConnectTimeout=5 k8s-admin@$node "echo 'Connected to $node'" > /dev/null 2>&1; then
            log "✓ Connected to $node"
        else
            error "✗ Cannot connect to $node. Please check SSH access from local workstation"
        fi
    done
}

# Main execution
main() {
    log "Starting Kubernetes HA cluster bootstrap from local workstation"
    log "Load balancer is presumed to be already installed and reachable on $CONTROL_PLANE_ENDPOINT"
    log "Private Network: $PRIVATE_NETWORK_CIDR (gateway: $GATEWAY)"
    log "Pod Network: $CLUSTER_CIDR"
    log "Service Network: $SERVICE_CIDR"
    log "Control Planes: ${CONTROL_PLANES[*]}"
    log "Workers: ${WORKERS[*]}"
    log "Container Runtime: CRI-O $CRIO_VERSION"
    log "CNI: Calico $CALICO_VERSION with VXLAN"
    log "Kernel Requirement: >=$MIN_KERNEL_MAJOR.$MIN_KERNEL_MINOR"
    
    # Pre-flight: Stop kubelet on all nodes to fix any current crashes
    #log "Pre-flight: Ensuring kubelet is stopped on all nodes..."
    # stop_kubelet_on_all_nodes
    
    # Phase 0: Discover private IPs on all nodes
    log "Phase 0: Discovering private IP addresses..."
    discover_all_private_ips
    
    # Phase 1: Basic setup on ALL nodes (CRI-O, kernel modules, etc.)    
    log "Phase 1: Setting up all nodes..."
    for node in "${NODES[@]}"; do
        setup_node_basic "$node"
        if [[ " ${CONTROL_PLANES[@]} " =~ " ${node} " ]]; then
            setup_kubernetes_node "$node" "control-plane"
        else
            setup_kubernetes_node "$node" "worker"
        fi
    done

    # Phase 1.5: Load air-gapped container images (if configured)
    log "Phase 1.5: Loading air-gapped container images..."
    load_airgapped_images_all_nodes

    # Phase 2: Setup audit policy on all control plane nodes
    log "Phase 2: Setting up audit policy on all control plane nodes..."
    setup_audit_policy    

    # Phase 3: Initialize first control plane (this starts kubelet on dev01)
    log "Phase 3: Initializing first control plane..."
    init_first_control_plane

    # Phase 3.1: Control first control plane health checks...
    log "Phase 3.1: Control first control plane health checks..."    
    check_control_plane_etcd_health    

    # Phase 3.2: Performing comprehensive pre-join health checks
    log "Phase 3.2: Performing comprehensive pre-join health checks"
    perform_pre_join_health_checks
    
    # Phase 4: Setup and join other control plane nodes
    log "Phase 4: Setting up and joining control plane nodes..."
    join_control_plane_nodes    
    
    # Phase 5: Setup and join worker nodes  
    log "Phase 5: Setting up and joining worker nodes..."
    for node in "${WORKERS[@]}"; do
        log "Setting up worker node: $node"
        setup_worker_node "$node"
    done
    join_worker_nodes
    
    # Set resource limits for control plane
    log "Phase 6: Setting control plane resource limits..."
    set_control_plane_resources
    
    # Install Calico with VXLAN
    log "Phase 7: Installing Calico CNI..."
    install_calico    
    
    # Allow scheduling on control plane nodes
    log "Phase 8: Configuring scheduling..."
    allow_scheduling_on_control_plane
    
    # Install etcd backup
    log "Phase 8.5: Installing etcd backup CronJob..."
    install_etcd_backup
    
    # Apply default deny policy, commented for simplicity, you can apply it when you need
    # log "Phase 8.6: Applying default deny network policy..."    
    # apply_default_deny_policy
    
    # Verify cluster
    log "Phase 9: Verifying cluster..."
    verify_cluster
    
    log "===================================================================="
    log "Kubernetes HA cluster bootstrap completed successfully!"
    log "===================================================================="
    log "Access your cluster using: kubectl get nodes"
    log "Cluster API endpoint: https://$CONTROL_PLANE_ENDPOINT"
    log "HAProxy stats: http://${NODE_IPS[dev01]}:8080"
    log "Private network: $PRIVATE_NETWORK_CIDR"
    log "Pod network: $CLUSTER_CIDR"
    log "Container Runtime: CRI-O $CRIO_VERSION"
    log "CNI: Calico $CALICO_VERSION with VXLAN encapsulation"
    log ""
    log "Node IP assignments:"
    for node in "${!NODE_IPS[@]}"; do
        log "  $node: ${NODE_IPS[$node]}"
    done
    log ""
    log "To use the cluster from local workstation:"
    log "  kubectl get nodes"
    log ""
    log "To access from other nodes, copy kubeconfig:"
    log "  scp ~/.kube/config k8s-admin@dev01:~/.kube/config"
    log "===================================================================="
}

# Run pre-flight checks and main function
log "Running pre-flight checks..."
check_connectivity

# Execute main function
main "$@"

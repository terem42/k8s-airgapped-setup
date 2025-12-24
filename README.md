# Air-Gapped Kubernetes Cluster Setup

## Overview

Complete toolkit for deploying **production-ready Kubernetes HA clusters** in air-gapped environments.

**Includes:**
- 📦 **APT Mirror** - Minimal repository with Ubuntu, ZFS, Kubernetes, and CRI-O packages
- 🐳 **Container Images** - Pull and save all required images as tar files
- 🚀 **Cluster Bootstrap** - Automated HA cluster setup with kubeadm, CRI-O, and Calico

## Quick Start

```bash
# Deploy to mirror server
scp apt-mirror-config.sh generate-airgap-mirror.sh update-apt-mirror-weekly setup-apt-mirror-ubuntu user@mirror:/tmp/
ssh user@mirror "cd /tmp && sudo ./setup-apt-mirror-ubuntu"

# Run first mirror generation (or dry-run first)
ssh user@mirror "sudo /usr/local/bin/generate-airgap-mirror.sh --dry-run"
ssh user@mirror "sudo /usr/local/bin/update-apt-mirror-weekly"
```

## Architecture

```
/var/cache/airgap-mirror/
├── airgap                    → symlink to current version
├── airgap-20251211-173520/   ← current version (active)
│   ├── amd64/
│   │   ├── pkg1.deb         ← hardlinks to preserve unchanged packages
│   │   ├── pkg2.deb
│   │   └── ...
│   ├── Packages.gz          ← regenerated fresh each build
│   ├── Release              ← regenerated fresh each build  
│   ├── Release.gpg
│   ├── InRelease
│   └── Release.key
└── airgap-20251210-..../     ← deleted after successful switch
```

### How It Works

1. **Create new versioned directory** (`airgap-YYYYMMDD-HHMMSS/`)
2. **Hardlink cached packages** from current version (instant, no copy)
3. **Create minimal apt-only chroot** via `mmdebstrap --variant=apt`
4. **Bind-mount** package directory as chroot's apt cache
5. **Download packages** via `apt-get --download-only` in chroot
6. **Regenerate fresh metadata** (`Packages.gz`, `Release`, signatures)
7. **Atomic symlink switch** (`airgap → new version`)
8. **Delete old version**

### Key Design Decisions

| Aspect | Implementation | Why |
|--------|---------------|-----|
| **Atomic updates** | Versioned dirs + symlink swap | Zero-downtime updates, instant rollback |
| **Package caching** | Hardlinks between versions | ~1GB reuse without disk copy |
| **Minimal chroot** | `mmdebstrap --variant=apt` | Smallest chroot that can run apt |
| **Chroot mounts** | Only apt cache bind-mount + DNS | No proc/sys/dev needed for download-only |
| **Metadata** | Regenerated fresh each build | Checksums always match actual packages |

### Package Manifest

Packages are defined in `apt-mirror-config.sh`:

| Category | Packages |
|----------|----------|
| System | linux-image-generic, linux-headers-generic, ssh, curl, nano, htop |
| ZFS | zfs-dkms, zfsutils-linux, zfs-initramfs |
| Kubernetes | kubelet, kubeadm, kubectl |
| CRI-O | cri-o, runc |

## Client Configuration

```bash
# On air-gapped client systems
MIRROR_IP="192.168.1.100"

# Import GPG key
curl -fsSL http://$MIRROR_IP/airgap/Release.key | \
  sudo gpg --dearmor -o /etc/apt/keyrings/airgap.gpg

# Add repository
echo "deb [signed-by=/etc/apt/keyrings/airgap.gpg] http://$MIRROR_IP/airgap/ stable main" | \
  sudo tee /etc/apt/sources.list.d/airgap.list

sudo apt update
```

## Files

| File | Description |
|------|-------------|
| `apt-mirror-config.sh` | Central configuration with package manifest |
| `generate-airgap-mirror.sh` | Core mirror generation with atomic updates and caching |
| `update-apt-mirror-weekly` | Weekly update wrapper with nginx integration |
| `setup-apt-mirror-ubuntu` | One-time setup script |

## Commands

```bash
# Dry-run (preview packages)
sudo /usr/local/bin/generate-airgap-mirror.sh --dry-run

# Generate/update mirror
sudo /usr/local/bin/update-apt-mirror-weekly

# Force rebuild all packages
sudo /usr/local/bin/generate-airgap-mirror.sh --force

# Check timer status
systemctl status apt-mirror-weekly.timer

# View logs
tail -f /var/log/airgap-mirror.log
```

## Customization

Edit `/etc/apt-mirror-config.sh` to:
- Change Kubernetes/CRI-O versions
- Add/remove packages from manifest arrays
- Modify Ubuntu mirror URL

## Benefits

- **Minimal footprint**: ~1GB exact packages vs full repository mirrors
- **Complete dependencies**: mmdebstrap ensures 100% reproducible installs
- **Single repository**: Ubuntu + Kubernetes + CRI-O unified
- **Zero-downtime updates**: Atomic symlink switching
- **Efficient caching**: Hardlinks reuse unchanged packages

## Troubleshooting

```bash
# Check packages in mirror
ls /var/cache/airgap-mirror/airgap/amd64/*.deb | wc -l

# Verify repository metadata
cat /var/cache/airgap-mirror/airgap/Packages | grep "^Package:" | wc -l

# Test signing
gpg --verify /var/cache/airgap-mirror/airgap/dists/stable/Release.gpg
```

---

## Kubernetes Cluster Setup

### Scripts Overview

| File | Description |
|------|-------------|
| `setup-k8s-admin-on-all-nodes.sh` | Setup passwordless SSH access with k8s-admin user on all nodes |
| `setup_classical_kubeadm_cluster.sh` | Complete HA Kubernetes cluster bootstrap with CRI-O and Calico |
| `pull_and_save_images.sh` | Download and save container images as tar files for air-gapped transfer |

### Configuration

Both scripts share common version settings at the top:

```bash
K8S_VERSION="1.34.1"      # Kubernetes version
CALICO_VERSION="3.25.0"   # Must match calico.yaml
CRIO_VERSION="1.34"       # CRI-O version (matches K8s major.minor)
```

Default node configuration:
```bash
CONTROL_PLANES=("dev01" "dev02" "dev03")
WORKERS=()  # Add worker nodes here if needed
```

---

### Step 0: Setup Passwordless SSH Access

> **⚠️ Required First**  
> All other scripts require passwordless SSH access to cluster nodes using the `k8s-admin` user.

Use `setup-k8s-admin-on-all-nodes.sh` to configure SSH access automatically:

```bash
# 1. Configure node IPs in the script
vi setup-k8s-admin-on-all-nodes.sh

# Edit the NODES map:
declare -A NODES=(
    ["dev01"]="10.0.0.3"
    ["dev02"]="10.0.0.4"
    ["dev03"]="10.0.0.5"
)

# 2. Set AUTH_KEY to your SSH key with root access to nodes
export AUTH_KEY=~/.ssh/your-root-key.key

# 3. Run setup (requires initial root SSH access to nodes)
chmod +x setup-k8s-admin-on-all-nodes.sh
./setup-k8s-admin-on-all-nodes.sh
```

The script will:
- Create `k8s-admin` user on each node
- Configure passwordless sudo with command logging
- Copy your SSH key for `k8s-admin` access
- Update your `~/.ssh/config` with host entries
- Validate connectivity to all nodes

After setup, verify access:
```bash
ssh dev01 hostname
ssh dev02 hostname
ssh dev03 hostname
```

---

### Cluster Setup Script (`setup_classical_kubeadm_cluster.sh`)

Deploys a production-ready HA Kubernetes cluster with:
- **3 control plane nodes** with etcd
- **CRI-O** container runtime
- **Calico CNI** with VXLAN encapsulation
- **HAProxy** load balancer (pre-installed)
- **Automatic etcd backups** via CronJob

#### Air-Gapped Configuration

```bash
# Path on each node where container image tar files are located
AIRGAPPED_IMAGES_PATH="/mnt/usb/k8s-images"

# Leave empty for online installation
AIRGAPPED_IMAGES_PATH=""
```

When `AIRGAPPED_IMAGES_PATH` is set:
- Container images are loaded from `.tar` files via `crictl load -i`
- `kubeadm config images pull` is skipped
- Pre-join health checks skip image pull verification

---

## Air-Gapped Installation Workflow

### Complete Sequence

```
┌─────────────────────────────────────────────────────────────────┐
│                    ONLINE ENVIRONMENT                           │
│  (workstation with internet access)                             │
├─────────────────────────────────────────────────────────────────┤
│  1. Generate APT mirror     → USB/Network share                 │
│  2. Pull container images   → USB drive                         │
│  3. Download calico.yaml    → USB drive                         │
└─────────────────────────────────────────────────────────────────┘
                              ↓
                        Transfer via USB
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                   AIR-GAPPED ENVIRONMENT                        │
│  (target cluster nodes)                                         │
├─────────────────────────────────────────────────────────────────┤
│  4. Configure APT to use local mirror                           │
│  5. Mount USB with container images                             │
│  6. Run cluster setup script                                    │
└─────────────────────────────────────────────────────────────────┘
```

### Step 1: Generate APT Mirror (Online)

```bash
# On mirror server with internet access
sudo /usr/local/bin/generate-airgap-mirror.sh
```

### Step 2: Pull and Save Container Images (Online)

```bash
# Make script executable
chmod +x pull_and_save_images.sh

# Pull all required images and save as tar files
./pull_and_save_images.sh /path/to/usb/k8s-images
```

This creates tar files for:
- **Kubernetes**: kube-apiserver, kube-controller-manager, kube-scheduler, kube-proxy, coredns, pause, etcd
- **Calico**: cni, node, kube-controllers, typha, pod2daemon-flexvol, apiserver, csi, node-driver-registrar
- **Utilities**: busybox

### Step 3: Prepare USB Drive

```bash
# Copy to USB drive
USB_MOUNT="/mnt/usb"
cp -r ./k8s-images "$USB_MOUNT/"
cp calico.yaml "$USB_MOUNT/"
```

### Step 4: Configure Air-Gapped Clients

On each cluster node:

```bash
# Configure APT to use local mirror
MIRROR_IP="192.168.1.100"
curl -fsSL http://$MIRROR_IP/airgap/Release.key | \
  sudo gpg --dearmor -o /etc/apt/keyrings/airgap.gpg

echo "deb [signed-by=/etc/apt/keyrings/airgap.gpg] http://$MIRROR_IP/airgap/ stable main" | \
  sudo tee /etc/apt/sources.list.d/airgap.list

# Disable other repositories
sudo mv /etc/apt/sources.list /etc/apt/sources.list.disabled
sudo apt update
```

### Step 5: Mount USB with Container Images

On each cluster node:

```bash
# Mount USB drive
sudo mkdir -p /mnt/usb
sudo mount /dev/sdb1 /mnt/usb

# Verify images are accessible
ls /mnt/usb/k8s-images/*.tar
```

### Step 6: Run Cluster Setup

```bash
# Configure the script
vi setup_classical_kubeadm_cluster.sh

# Set air-gapped images path
AIRGAPPED_IMAGES_PATH="/mnt/usb/k8s-images"

# Run from your workstation (with SSH access to all nodes)
chmod +x setup_classical_kubeadm_cluster.sh
./setup_classical_kubeadm_cluster.sh
```

---

## Container Images Reference

### Kubernetes Images (from registry.k8s.io)

| Image | Description |
|-------|-------------|
| `kube-apiserver` | Kubernetes API server |
| `kube-controller-manager` | Controller manager |
| `kube-scheduler` | Scheduler |
| `kube-proxy` | Network proxy |
| `coredns/coredns` | Cluster DNS |
| `pause` | Pod infrastructure container |
| `etcd` | Key-value store for cluster state |

### Calico Images (from docker.io/calico)

| Image | Description |
|-------|-------------|
| `cni` | CNI plugin binary installer |
| `node` | Calico node agent (Felix + BIRD) |
| `kube-controllers` | Kubernetes controllers for Calico |
| `typha` | Fan-out proxy for Felix |
| `pod2daemon-flexvol` | Flexvolume driver |
| `apiserver` | Calico API server |

### Verifying Loaded Images

After cluster setup, verify images on any node:

```bash
sudo crictl images
```

#!/bin/bash
set -e

# =============================================================================
# Pull and Save Kubernetes Images for Air-Gapped Installation
# =============================================================================
# This script pulls all required images for kubeadm and Calico, then saves
# them as tar files for transfer to an air-gapped environment.
#
# Usage: ./pull_and_save_images.sh [output_directory]
#        Default output directory: ./k8s-images
# =============================================================================

# Configuration - MUST match your cluster settings
K8S_VERSION="1.34.1"

# IMPORTANT: This MUST match the version in your calico.yaml file!
# Check your calico.yaml for the actual version used (grep "image:" calico.yaml)
CALICO_VERSION="3.25.0"

# Output directory for tar files
OUTPUT_DIR="${1:-./k8s-images}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

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

# Check if docker or podman is available
check_container_runtime() {
    if command -v docker &> /dev/null; then
        CONTAINER_CMD="docker"
        log "Using Docker as container runtime"
    elif command -v podman &> /dev/null; then
        CONTAINER_CMD="podman"
        log "Using Podman as container runtime"
    else
        error "Neither Docker nor Podman found. Please install one of them."
    fi
}

# Pull an image and save it to tar
pull_and_save_image() {
    local image="$1"
    local filename=$(echo "$image" | tr '/:' '_').tar
    local filepath="$OUTPUT_DIR/$filename"
    
    log "Pulling: $image"
    if $CONTAINER_CMD pull "$image"; then
        log "Saving: $image -> $filename"
        $CONTAINER_CMD save -o "$filepath" "$image"
        log "✓ Saved: $filename ($(du -h "$filepath" | cut -f1))"
    else
        warn "✗ Failed to pull: $image"
        return 1
    fi
}

# Get kubeadm required images
get_kubeadm_images() {
    log "Getting list of kubeadm required images for Kubernetes v$K8S_VERSION..."
    
    # If kubeadm is installed, use it to get the image list
    if command -v kubeadm &> /dev/null; then
        kubeadm config images list --kubernetes-version="v$K8S_VERSION"
    else
        # Fallback: hardcoded list based on typical kubeadm requirements
        # These are from registry.k8s.io
        cat <<EOF
registry.k8s.io/kube-apiserver:v$K8S_VERSION
registry.k8s.io/kube-controller-manager:v$K8S_VERSION
registry.k8s.io/kube-scheduler:v$K8S_VERSION
registry.k8s.io/kube-proxy:v$K8S_VERSION
registry.k8s.io/coredns/coredns:v1.12.0
registry.k8s.io/pause:3.10
registry.k8s.io/etcd:3.5.21-0
EOF
    fi
}

# Get Calico required images
# Full list based on official Calico documentation for air-gapped installations
# Reference: https://docs.tigera.io/calico/latest/operations/image-options/imageset
get_calico_images() {
    log "Getting list of Calico images for version $CALICO_VERSION..."
    
    # Core Calico images required for standard manifest-based installation
    # NOTE: Verify these match your calico.yaml file!
    cat <<EOF
docker.io/calico/cni:v$CALICO_VERSION
docker.io/calico/node:v$CALICO_VERSION
docker.io/calico/kube-controllers:v$CALICO_VERSION
docker.io/calico/typha:v$CALICO_VERSION
docker.io/calico/pod2daemon-flexvol:v$CALICO_VERSION
docker.io/calico/apiserver:v$CALICO_VERSION
docker.io/calico/csi:v$CALICO_VERSION
docker.io/calico/node-driver-registrar:v$CALICO_VERSION
docker.io/calico/dikastes:v$CALICO_VERSION
docker.io/calico/ctl:v$CALICO_VERSION
EOF
}

# Get additional utility images used in the cluster
get_utility_images() {
    log "Getting additional utility images..."
    
    cat <<EOF
quay.io/quay/busybox:latest
EOF
}

# Main execution
main() {
    log "=============================================="
    log "Kubernetes Air-Gapped Image Downloader"
    log "=============================================="
    log "Kubernetes Version: v$K8S_VERSION"
    log "Calico Version: v$CALICO_VERSION"
    log "Output Directory: $OUTPUT_DIR"
    log "=============================================="
    
    # Check container runtime
    check_container_runtime
    
    # Create output directory
    mkdir -p "$OUTPUT_DIR"
    log "Created output directory: $OUTPUT_DIR"
    
    # Collect all images
    local all_images=()
    
    log ""
    log "=== Collecting kubeadm images ==="
    while IFS= read -r image; do
        [ -n "$image" ] && all_images+=("$image")
    done < <(get_kubeadm_images)
    
    log ""
    log "=== Collecting Calico images ==="
    while IFS= read -r image; do
        [ -n "$image" ] && all_images+=("$image")
    done < <(get_calico_images)
    
    log ""
    log "=== Collecting utility images ==="
    while IFS= read -r image; do
        [ -n "$image" ] && all_images+=("$image")
    done < <(get_utility_images)
    
    # Remove duplicates
    local unique_images=($(printf '%s\n' "${all_images[@]}" | sort -u))
    
    log ""
    log "Total images to download: ${#unique_images[@]}"
    log ""
    
    # Pull and save each image
    local failed=0
    local succeeded=0
    local total=${#unique_images[@]}
    local current=0
    
    for image in "${unique_images[@]}"; do
        current=$((current + 1))
        log "[$current/$total] Processing: $image"
        
        if pull_and_save_image "$image"; then
            succeeded=$((succeeded + 1))
        else
            failed=$((failed + 1))
        fi
        echo ""
    done
    
    # Summary
    log "=============================================="
    log "Download Complete!"
    log "=============================================="
    log "Succeeded: $succeeded"
    [ $failed -gt 0 ] && warn "Failed: $failed"
    log "Output directory: $OUTPUT_DIR"
    log ""
    log "Total size: $(du -sh "$OUTPUT_DIR" | cut -f1)"
    log ""
    log "Files created:"
    ls -lh "$OUTPUT_DIR"/*.tar 2>/dev/null || warn "No tar files created"
    log ""
    log "Next steps:"
    log "  1. Copy the '$OUTPUT_DIR' directory to your USB drive"
    log "  2. Mount USB on each node at AIRGAPPED_IMAGES_PATH"
    log "  3. Run the cluster setup script"
    log "=============================================="
}

main "$@"

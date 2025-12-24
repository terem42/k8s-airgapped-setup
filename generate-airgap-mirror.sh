#!/bin/bash
set -e

# ==============================================
# Air-Gap Mirror Generator
# ==============================================
# Creates a minimal, exact package mirror for air-gapped deployment
# Uses mmdebstrap to simulate clean install and captures all required packages
#
# Caching: The mirror's amd64/ directory serves as both the final
# repository AND the apt cache. Packages are downloaded once and reused.
# ==============================================

# Load central configuration
if [ -f /etc/apt-mirror-config.sh ]; then
    source /etc/apt-mirror-config.sh
elif [ -f "$(dirname "$0")/apt-mirror-config.sh" ]; then
    source "$(dirname "$0")/apt-mirror-config.sh"
else
    echo "ERROR: Configuration file not found" >&2
    exit 1
fi

# Parse command line arguments
DRY_RUN=false
VERBOSE=false
FORCE_REBUILD=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --force)
            FORCE_REBUILD=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --dry-run    Show what would be downloaded without downloading"
            echo "  --verbose    Show detailed progress"
            echo "  --force      Force rebuild even if packages exist"
            echo "  --help       Show this help"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# Logging functions
log() {
    echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

warn() {
    echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1" | tee -a "$LOG_FILE" >&2
    exit 1
}

verbose() {
    if [ "$VERBOSE" = true ]; then
        echo "  $1" | tee -a "$LOG_FILE"
    fi
}

# ==============================================
# ATOMIC UPDATE STRATEGY
# ==============================================
# We maintain two versioned directories and a symlink:
#   mirror/airgap-v1/    ← previous version
#   mirror/airgap-v2/    ← current version  
#   mirror/airgap        ← symlink to current
#
# On update:
#   1. Build new version in airgap-new/
#   2. Copy cached .debs from current version
#   3. Download only new/updated packages
#   4. Atomic switch: symlink → new version
#   5. Delete old version
# ==============================================

# Get the actual directory (resolving symlink)
get_current_mirror_dir() {
    local symlink="$MIRROR_ROOT/$MIRROR_PREFIX"
    if [ -L "$symlink" ]; then
        readlink -f "$symlink"
    elif [ -d "$symlink" ]; then
        echo "$symlink"
    else
        echo ""
    fi
}

# Get path for new mirror build
get_new_mirror_dir() {
    local timestamp=$(date +%Y%m%d-%H%M%S)
    echo "$MIRROR_ROOT/${MIRROR_PREFIX}-${timestamp}"
}

# Get symlink path
get_mirror_symlink() {
    echo "$MIRROR_ROOT/$MIRROR_PREFIX"
}

# Atomic switch to new mirror version
atomic_switch_mirror() {
    local new_dir="$1"
    local symlink=$(get_mirror_symlink)
    local old_dir=$(get_current_mirror_dir)
    
    log "Performing atomic switch..."
    log "  New: $new_dir"
    log "  Symlink: $symlink"
    
    # Handle case where symlink path is an existing directory (first run after migration)
    if [ -d "$symlink" ] && [ ! -L "$symlink" ]; then
        log "  Migrating existing directory to versioned format..."
        local backup_dir="${symlink}-old-$(date +%Y%m%d-%H%M%S)"
        mv "$symlink" "$backup_dir"
        old_dir="$backup_dir"
        log "  Moved old directory to: $backup_dir"
    fi
    
    # Create/update symlink atomically
    local temp_link="${symlink}.new"
    ln -sfn "$new_dir" "$temp_link"
    mv -T "$temp_link" "$symlink"
    
    log "  Symlink updated"
    
    # Remove old version if different from new
    if [ -n "$old_dir" ] && [ "$old_dir" != "$new_dir" ] && [ -d "$old_dir" ]; then
        log "  Removing old version: $old_dir"
        rm -rf "$old_dir"
    fi
}

# Copy cached packages from current mirror to new mirror (using hardlinks)
copy_cached_packages() {
    local new_pkg_dir="$1"
    local current_dir=$(get_current_mirror_dir)
    
    if [ -n "$current_dir" ] && [ -d "$current_dir/amd64" ]; then
        local count=$(find "$current_dir/amd64" -maxdepth 1 -name "*.deb" 2>/dev/null | wc -l)
        if [ "$count" -gt 0 ]; then
            log "  Hardlinking $count cached packages from current mirror..."
            # Use hardlinks to save space and time (same filesystem)
            # Falls back to copy if hardlink fails (different filesystem)
            for deb in "$current_dir/amd64"/*.deb; do
                [ -f "$deb" ] || continue
                local filename=$(basename "$deb")
                if ! ln "$deb" "$new_pkg_dir/$filename" 2>/dev/null; then
                    cp "$deb" "$new_pkg_dir/$filename" 2>/dev/null || true
                fi
            done
            log "  Cached packages ready"
        fi
    fi
}

# Check required commands
check_requirements() {
    log "Checking requirements..."
    
    local required_cmds=("mmdebstrap" "gpg" "dpkg-scanpackages")
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            error "$cmd is required but not installed. Run: apt install mmdebstrap dpkg-dev wget gnupg"
        fi
    done
    
    log "All requirements satisfied"
}

# Create clean chroot with mmdebstrap (with caching via mirror directory)
create_clean_chroot() {
    local chroot_dir="$1"
    local mirror_pkg_dir="$2"
    
    log "Creating minimal Ubuntu $UBUNTU_CODENAME chroot with mmdebstrap (apt-only)..."
    
    # Ensure mirror package directory exists with partial subdir for apt
    mkdir -p "$mirror_pkg_dir/partial"
    
    local cached_count=$(find "$mirror_pkg_dir" -maxdepth 1 -name "*.deb" 2>/dev/null | wc -l)
    log "  Existing cached packages: $cached_count"
    
    # Create hook to sync packages back to mirror after mmdebstrap completes
    local sync_script=$(mktemp)
    cat > "$sync_script" <<EOF
#!/bin/bash
# Copy any newly downloaded packages to mirror directory
for deb in "\$1/var/cache/apt/archives"/*.deb; do
    [ -f "\$deb" ] || continue
    filename=\$(basename "\$deb")
    [ -f "$mirror_pkg_dir/\$filename" ] || cp "\$deb" "$mirror_pkg_dir/"
done
EOF
    chmod +x "$sync_script"
    
    # Build mmdebstrap command - minimal chroot just for apt to work
    # variant=apt is the smallest variant that includes apt
    # We only include curl/gnupg to add external repos
    local mmdebstrap_cmd=(
        mmdebstrap
        --variant=apt
        --include="curl,gnupg,ca-certificates"
        --components="$UBUNTU_COMPONENTS"
    )
    
    # Clean up any orphan bind mounts from previous failed runs
    # These can occur if mmdebstrap fails before the teardown hook runs
    cleanup_orphan_mounts() {
        local mount_point
        while IFS= read -r mount_point; do
            if [ -n "$mount_point" ]; then
                log "  Cleaning up orphan mount: $mount_point"
                umount "$mount_point" 2>/dev/null || true
            fi
        done < <(grep -E '/tmp/tmp\.[^/]+/var/cache/apt/archives' /proc/mounts | awk '{print $2}')
    }
    cleanup_orphan_mounts
    
    # If we have cached packages, use bind-mount to make them available to apt
    # This avoids copying ~1GB of data on each run
    local cache_setup_hook=""
    local cache_teardown_hook=""
    if [ "$cached_count" -gt 0 ]; then
        cache_setup_hook=$(mktemp)
        cat > "$cache_setup_hook" <<SETUP_EOF
#!/bin/bash
# Bind-mount mirror directory as apt cache (instant, no copy needed)
mkdir -p "\$1/var/cache/apt/archives/partial"
mount --bind "$mirror_pkg_dir" "\$1/var/cache/apt/archives"
SETUP_EOF
        chmod +x "$cache_setup_hook"
        
        cache_teardown_hook=$(mktemp)
        cat > "$cache_teardown_hook" <<TEARDOWN_EOF
#!/bin/bash
# Unmount before mmdebstrap cleans up
umount "\$1/var/cache/apt/archives" 2>/dev/null || true
TEARDOWN_EOF
        chmod +x "$cache_teardown_hook"
        
        mmdebstrap_cmd+=(--setup-hook="$cache_setup_hook \"\$1\"")
        mmdebstrap_cmd+=(--customize-hook="$cache_teardown_hook \"\$1\"")
    fi
    
    mmdebstrap_cmd+=(
        --customize-hook="$sync_script \"\$1\""
        "$UBUNTU_CODENAME"
        "$chroot_dir"
        "deb $UBUNTU_MIRROR $UBUNTU_CODENAME $UBUNTU_COMPONENTS"
        "deb $UBUNTU_MIRROR ${UBUNTU_CODENAME}-updates $UBUNTU_COMPONENTS"
        "deb $UBUNTU_SECURITY_MIRROR ${UBUNTU_CODENAME}-security $UBUNTU_COMPONENTS"
    )
    
    # Run mmdebstrap
    "${mmdebstrap_cmd[@]}" || true  # Don't fail on mmdebstrap error, cleanup will handle it
    
    # Cleanup hook scripts
    rm -f "$sync_script"
    [ -n "$cache_setup_hook" ] && rm -f "$cache_setup_hook"
    [ -n "$cache_teardown_hook" ] && rm -f "$cache_teardown_hook"
    
    # Ensure bind mount is unmounted (customize hook may have failed)
    if mountpoint -q "$chroot_dir/var/cache/apt/archives" 2>/dev/null; then
        log "  Unmounting bind mount from chroot..."
        umount "$chroot_dir/var/cache/apt/archives" 2>/dev/null || true
    fi
    
    # Final cleanup of any orphan mounts (in case mmdebstrap failed mid-way)
    cleanup_orphan_mounts
    
    local new_count=$(find "$mirror_pkg_dir" -maxdepth 1 -name "*.deb" 2>/dev/null | wc -l)
    log "  Cached packages after bootstrap: $new_count (+$((new_count - cached_count)))"
    
    log "Clean chroot created at $chroot_dir"
}

# Set up chroot environment with mirror as apt cache (bind mount)
setup_chroot_environment() {
    local chroot_dir="$1"
    local mirror_pkg_dir="$2"
    
    log "Setting up chroot environment (minimal for apt download-only)..."
    
    # Clean any stale apt metadata from mirror dir before bind mount
    rm -f "$mirror_pkg_dir/Packages" "$mirror_pkg_dir/Packages.gz" 2>/dev/null || true
    rm -f "$mirror_pkg_dir/Release" "$mirror_pkg_dir/Release.gpg" "$mirror_pkg_dir/InRelease" 2>/dev/null || true
    
    # Ensure partial directory exists for apt
    mkdir -p "$mirror_pkg_dir/partial"
    
    # Bind mount mirror directory as apt cache
    # Any package apt downloads goes directly to mirror
    mkdir -p "$chroot_dir/var/cache/apt/archives/partial"
    mount --bind "$mirror_pkg_dir" "$chroot_dir/var/cache/apt/archives"
    
    # Configure DNS resolution (only thing apt needs for network)
    configure_chroot_dns "$chroot_dir"
    
    log "  Mirror bind-mounted as apt cache"
    log "Chroot environment ready"
}

# Clean up chroot environment
cleanup_chroot_environment() {
    local chroot_dir="$1"
    
    log "Cleaning up chroot environment..."
    
    # Unmount apt cache bind mount
    umount "$chroot_dir/var/cache/apt/archives" 2>/dev/null || true
}

# Configure DNS resolution in chroot
configure_chroot_dns() {
    local chroot_dir="$1"
    
    log "  Setting up DNS resolution..."
    mkdir -p "$chroot_dir/run/systemd/resolve"
    
    if command -v resolvectl >/dev/null 2>&1; then
        local DNS_SERVERS
        DNS_SERVERS=$(resolvectl dns | awk '/^Global:/ { for(i=2; i<=NF; i++) print $i }' | head -3)
        
        if [ -z "$DNS_SERVERS" ]; then
            DNS_SERVERS=$(resolvectl dns | awk '/^Link [0-9]+ / && NF > 3 { for(i=4; i<=NF; i++) print $i; exit }')
        fi
        
        if [ -n "$DNS_SERVERS" ]; then
            echo "$DNS_SERVERS" | while read -r dns; do echo "nameserver $dns"; done > "$chroot_dir/etc/resolv.conf"
            log "  Using DNS: $(echo "$DNS_SERVERS" | tr '\n' ' ')"
        else
            echo "nameserver 8.8.8.8" > "$chroot_dir/etc/resolv.conf"
            warn "No DNS found, using 8.8.8.8"
        fi
    else
        if [ -f /etc/resolv.conf ]; then
            cp /etc/resolv.conf "$chroot_dir/etc/resolv.conf"
        else
            echo "nameserver 8.8.8.8" > "$chroot_dir/etc/resolv.conf"
        fi
    fi
}

# Configure external repositories inside chroot
configure_external_repos() {
    local chroot_dir="$1"
    
    log "Configuring external repositories in chroot..."
    
    log "  Adding Kubernetes repository..."
    LC_ALL=C chroot "$chroot_dir" /bin/bash -c "
        mkdir -p /etc/apt/keyrings
        curl -fsSL ${K8S_REPO_URL}/Release.key | gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes.gpg
        echo 'deb [signed-by=/etc/apt/keyrings/kubernetes.gpg] ${K8S_REPO_URL} /' > /etc/apt/sources.list.d/kubernetes.list
    "
    
    log "  Adding CRI-O repository..."
    LC_ALL=C chroot "$chroot_dir" /bin/bash -c "
        curl -fsSL ${CRIO_REPO_URL}/Release.key | gpg --batch --yes --dearmor -o /etc/apt/keyrings/cri-o.gpg
        echo 'deb [signed-by=/etc/apt/keyrings/cri-o.gpg] ${CRIO_REPO_URL} /' > /etc/apt/sources.list.d/cri-o.list
    "
    
    log "  Updating package lists..."
    LC_ALL=C chroot "$chroot_dir" apt-get update -qq
    
    log "External repositories configured"
}

# Download all packages via apt-get inside chroot
# With mirror bind-mounted as apt cache, existing packages are skipped automatically
download_packages_via_apt() {
    local chroot_dir="$1"
    
    log "Downloading packages via apt-get..."
    
    local ubuntu_packages=$(get_all_ubuntu_packages)
    local k8s_packages=$(get_k8s_packages)
    local crio_packages=$(get_crio_packages)
    local all_packages="$ubuntu_packages $k8s_packages $crio_packages"
    
    log "  Package manifest: $(echo $all_packages | wc -w) packages"
    verbose "  Packages: $all_packages"
    
    # Count packages before download
    local before_count=$(find "$chroot_dir/var/cache/apt/archives" -maxdepth 1 -name "*.deb" 2>/dev/null | wc -l)
    
    # Use apt-get with --download-only to fetch packages without installing
    # Packages already in cache (bind-mounted mirror) are skipped
    LC_ALL=C chroot "$chroot_dir" apt-get install --download-only -y $all_packages 2>&1 | tee -a "$LOG_FILE" || {
        warn "Some packages may have failed"
    }
    
    # Count packages after download
    local after_count=$(find "$chroot_dir/var/cache/apt/archives" -maxdepth 1 -name "*.deb" 2>/dev/null | wc -l)
    local new_downloads=$((after_count - before_count))
    
    log "Package download complete: $before_count cached, $new_downloads new"
}

# Generate repository metadata
generate_repository_metadata() {
    local mirror_dir="$1"
    local mirror_pkg_dir="$2"
    
    log "Generating repository metadata..."
    
    cd "$mirror_dir"
    
    # Clean up apt's partial directory and any stale metadata in pkg dir
    rm -rf "$mirror_pkg_dir/partial"
    rm -f "$mirror_pkg_dir/Packages" "$mirror_pkg_dir/Packages.gz" 2>/dev/null || true
    
    # Remove old metadata from mirror root (will be regenerated)
    rm -f "$mirror_dir/Packages" "$mirror_dir/Packages.gz" 2>/dev/null || true
    
    if [ -d "amd64" ] && ls amd64/*.deb >/dev/null 2>&1; then
        # Generate Packages file in mirror root (not in amd64/)
        dpkg-scanpackages "amd64" /dev/null > "Packages" 2>/dev/null
        gzip -c "Packages" > "Packages.gz"
        
        local pkg_count=$(grep -c "^Package:" Packages)
        log "  Generated Packages.gz with $pkg_count packages"
    else
        error "No .deb packages found in $mirror_pkg_dir"
    fi
}

# Main function
main() {
    log "=========================================="
    log "Air-Gap Mirror Generator"
    log "=========================================="
    
    [ "$DRY_RUN" = true ] && log "DRY RUN MODE"
    
    check_requirements
    
    local mirror_dir=$(get_new_mirror_dir)
    local mirror_pkg_dir="$mirror_dir/amd64"
    local mirror_symlink=$(get_mirror_symlink)
    local current_mirror=$(get_current_mirror_dir)
    # Note: chroot_dir is intentionally NOT local so the EXIT trap can access it
    chroot_dir=$(mktemp -d)
    
    mkdir -p "$mirror_pkg_dir"
    
    cleanup() {
        log "Cleaning up..."
        cleanup_chroot_environment "$chroot_dir"
        # Clean up any remaining mounts in our specific chroot directory
        while IFS= read -r mount_point; do
            [ -n "$mount_point" ] && log "  Unmounting: $mount_point" && umount "$mount_point" 2>/dev/null || true
        done < <(grep -F " $chroot_dir/" /proc/mounts | awk '{print $2}' | sort -r)
        rm -rf "$chroot_dir" 2>/dev/null || true
        # On failure, remove incomplete new mirror
        if [ -d "$mirror_dir" ] && [ ! -L "$mirror_symlink" -o "$(readlink -f "$mirror_symlink")" != "$mirror_dir" ]; then
            log "Removing incomplete mirror build: $mirror_dir"
            rm -rf "$mirror_dir" 2>/dev/null || true
        fi
    }
    trap cleanup EXIT
    
    log "Current mirror: ${current_mirror:-none}"
    log "Building new: $mirror_dir"
    log "Symlink: $mirror_symlink"
    log "Chroot: $chroot_dir"
    
    # Copy packages from current mirror as cache
    copy_cached_packages "$mirror_pkg_dir"
    
    create_clean_chroot "$chroot_dir" "$mirror_pkg_dir"
    setup_chroot_environment "$chroot_dir" "$mirror_pkg_dir"
    configure_external_repos "$chroot_dir"
    
    if [ "$DRY_RUN" = true ]; then
        log ""
        log "=== Packages to download (dry-run) ==="
        LC_ALL=C chroot "$chroot_dir" apt-get install --print-uris -y \
            $(get_all_ubuntu_packages) $(get_k8s_packages) $(get_crio_packages) 2>/dev/null | \
            grep "^'" | cut -d"'" -f2
        log ""
        # Clean up dry-run directory
        rm -rf "$mirror_dir"
        exit 0
    fi
    
    download_packages_via_apt "$chroot_dir"
    generate_repository_metadata "$mirror_dir" "$mirror_pkg_dir"
    
    log "Signing repository..."
    if generate_gpg_key && sign_repository "$mirror_dir"; then
        log "Repository signed"
    else
        warn "Signing failed"
    fi
    
    # Atomic switch to new mirror
    atomic_switch_mirror "$mirror_dir"
    
    local pkg_count=$(find "$mirror_pkg_dir" -maxdepth 1 -name "*.deb" 2>/dev/null | wc -l)
    local mirror_size=$(du -shL "$mirror_dir" 2>/dev/null | cut -f1)
    
    log ""
    log "=========================================="
    log "Complete"
    log "=========================================="
    log "Location: $mirror_dir"
    log "Symlink: $mirror_symlink → $mirror_dir"
    log "Packages: $pkg_count"
    log "Size: $mirror_size"
    log ""
}

main "$@"
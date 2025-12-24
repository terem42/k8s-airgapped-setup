#!/bin/bash
# ==============================================
# Central Configuration for Air-Gap Mirror
# ==============================================
# This file is sourced by:
# - /usr/local/bin/generate-airgap-mirror.sh
# - /usr/local/bin/update-apt-mirror-weekly
# - /usr/local/bin/setup-apt-mirror-ubuntu
# ==============================================

# ==============================================
# MIRROR PATHS AND DIRECTORIES
# ==============================================

# Base mirror directory
MIRROR_ROOT="/var/cache/airgap-mirror"

# Nginx web root
NGINX_ROOT="/var/www/html"

# Mirror prefix (how it appears in URLs)
MIRROR_PREFIX="airgap"

# ==============================================
# UBUNTU CONFIGURATION
# ==============================================

UBUNTU_CODENAME="noble"
UBUNTU_MIRROR="https://mirror.hetzner.com/ubuntu/packages"
UBUNTU_SECURITY_MIRROR="https://mirror.hetzner.com/ubuntu/security"

# Components to include from Ubuntu repos
UBUNTU_COMPONENTS="main universe"

# ==============================================
# KUBERNETES CONFIGURATION
# ==============================================

K8S_VERSION="1.34"
K8S_REPO_URL="https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb"

# ==============================================
# CRI-O CONFIGURATION
# ==============================================

CRIO_VERSION="1.34"
CRIO_REPO_URL="https://ftp.gwdg.de/pub/opensuse/repositories/isv:/cri-o:/stable:/v${CRIO_VERSION}/deb"

# ==============================================
# PACKAGE MANIFEST
# ==============================================

# Bootstrap packages (installed via mmdebstrap --include)
# These form the minimal base system
BOOTSTRAP_PACKAGES=(
    "systemd-resolved"
    "locales"
    "debconf-i18n"
    "apt-utils"
    "keyboard-configuration"
    "console-setup"
    "kbd"
    "extlinux"
    "initramfs-tools"
    "zstd"
    # Required for adding external repos in chroot
    "curl"
    "gnupg"
    "ca-certificates"
)

# System packages (installed after bootstrap)
# Core system utilities and kernel
SYSTEM_PACKAGES=(
    "linux-image-generic"
    "linux-headers-generic"
    "software-properties-common"
    "bash"
    "curl"
    "nano"
    "htop"
    "net-tools"
    "ssh"
    "rsyslog"
)

# ZFS packages (from universe/updates)
ZFS_PACKAGES=(
    "zfs-dkms"
    "zfsutils-linux"
    "zfs-initramfs"
)

# Kubernetes prerequisites (from Ubuntu repos)
K8S_PREREQ_PACKAGES=(
    "apt-transport-https"
    "ca-certificates"
    "curl"
    "gpg"
    "etcd-client"
)

# Kubernetes packages (from pkgs.k8s.io)
K8S_PACKAGES=(
    "kubelet"
    "kubeadm"
    "kubectl"
)

# CRI-O packages (from CRI-O repo)
CRIO_PACKAGES=(
    "cri-o"
)

# Additional packages from Ubuntu repos needed for CRI-O
CRIO_UBUNTU_DEPS=(
    "runc"
)

# ==============================================
# GPG KEY CONFIGURATION
# ==============================================

GPG_KEY_NAME="Terem Air-Gap Mirror"
GPG_KEY_EMAIL="root@$(hostname -f)"
GPG_KEY_EXPIRE="0"  # 0 = never expires
GPG_KEY_PATH="/etc/apt-mirror/keys/airgap.gpg"  # Private key for signing
GPG_KEYRING_PATH="/etc/apt/keyrings/airgap.gpg"  # Public keyring for clients
GPG_PUBLIC_KEY_PATH="$MIRROR_ROOT/$MIRROR_PREFIX/Release.key"  # Public key for download

# ==============================================
# LOGGING CONFIGURATION
# ==============================================

LOG_FILE="/var/log/airgap-mirror.log"

# ==============================================
# HELPER FUNCTIONS
# ==============================================

# Get all packages as a single space-separated string
get_all_ubuntu_packages() {
    echo "${BOOTSTRAP_PACKAGES[*]} ${SYSTEM_PACKAGES[*]} ${ZFS_PACKAGES[*]} ${K8S_PREREQ_PACKAGES[*]} ${CRIO_UBUNTU_DEPS[*]}"
}

# Get Kubernetes packages as a single space-separated string
get_k8s_packages() {
    echo "${K8S_PACKAGES[*]}"
}

# Get CRI-O packages as a single space-separated string
get_crio_packages() {
    echo "${CRIO_PACKAGES[*]}"
}

# Get mirror directory path
get_mirror_dir() {
    echo "$MIRROR_ROOT/$MIRROR_PREFIX"
}

# ==============================================
# VERSION COMPARISON FUNCTIONS
# ==============================================

# Compare two Debian package versions using dpkg
# Returns: 0 if version1 > version2, 1 otherwise
compare_versions_gt() {
    local version1="$1"
    local version2="$2"

    if [ -z "$version1" ] || [ -z "$version2" ]; then
        return 2  # Error: missing parameter
    fi

    if dpkg --compare-versions "$version1" gt "$version2"; then
        return 0  # version1 is greater
    else
        return 1  # version1 is not greater
    fi
}

# Extract version from a .deb filename
# Example: "package_1:1.2.3-4ubuntu5_amd64.deb" -> "1:1.2.3-4ubuntu5"
extract_version_from_deb() {
    local filename="$1"
    local basename="${filename##*/}"
    basename="${basename%.deb}"
    local version_arch="${basename#*_}"
    local version="${version_arch%_*}"
    echo "$version"
}

# ==============================================
# GPG KEY GENERATION
# ==============================================

generate_gpg_key() {
    echo "Generating GPG key for Air-Gap Mirror..."
    
    # Check if private key already exists and is valid
    if [ -f "$GPG_KEY_PATH" ] && [ -s "$GPG_KEY_PATH" ]; then
        local temp_gnupg_check=$(mktemp -d)
        export GNUPGHOME="$temp_gnupg_check"
        if gpg --batch --no-tty --import "$GPG_KEY_PATH" 2>/dev/null; then
            local key_info=$(gpg --list-keys --with-colons 2>/dev/null | grep '^pub:' | head -1)
            local key_length=$(echo "$key_info" | cut -d: -f4)
            if [ "$key_length" != "2048" ]; then
                echo "GPG private key already exists (${key_length}-bit), skipping generation."
                rm -rf "$temp_gnupg_check"
                unset GNUPGHOME
                return 0
            fi
            echo "Existing key is 2048-bit RSA (weak), regenerating as 4096-bit..."
        fi
        rm -rf "$temp_gnupg_check"
        unset GNUPGHOME
    fi
    
    # Create directories for keys
    mkdir -p "$(dirname "$GPG_KEY_PATH")"
    mkdir -p "$(dirname "$GPG_KEYRING_PATH")"
    mkdir -p "$(dirname "$GPG_PUBLIC_KEY_PATH")"
    
    # Create temporary GNUPG home
    local temp_gnupg=$(mktemp -d)
    export GNUPGHOME="$temp_gnupg"
    
    # Generate GPG key non-interactively - 4096-bit RSA
    cat > /tmp/gpg-keygen.batch <<EOF
%echo Generating Air-Gap Mirror GPG key (4096-bit RSA)
Key-Type: RSA
Key-Length: 4096
Key-Usage: sign
Name-Real: $GPG_KEY_NAME
Name-Email: $GPG_KEY_EMAIL
Expire-Date: $GPG_KEY_EXPIRE
%no-protection
%commit
%echo Done
EOF
    
    if gpg --batch --no-tty --generate-key /tmp/gpg-keygen.batch 2>/dev/null; then
        local key_id=$(gpg --list-keys --with-colons "$GPG_KEY_EMAIL" 2>/dev/null | grep '^fpr:' | cut -d: -f10 | head -1)
        
        if [ -z "$key_id" ]; then
            echo "ERROR: Failed to get key ID after generation"
            rm -f /tmp/gpg-keygen.batch
            rm -rf "$temp_gnupg"
            unset GNUPGHOME
            return 1
        fi
        
        # Export keys
        gpg --export --armor "$key_id" > "$GPG_PUBLIC_KEY_PATH" 2>/dev/null
        gpg --export --armor "$key_id" | gpg --dearmor > "$GPG_KEYRING_PATH" 2>/dev/null
        gpg --export-secret-keys --armor "$key_id" > "$GPG_KEY_PATH" 2>/dev/null
        
        echo "GPG key generated successfully:"
        echo "  Key ID: $key_id"
        echo "  Public key: $GPG_PUBLIC_KEY_PATH"
        echo "  Keyring: $GPG_KEYRING_PATH"
        
        chmod 644 "$GPG_PUBLIC_KEY_PATH"
        chmod 644 "$GPG_KEYRING_PATH"
        chmod 600 "$GPG_KEY_PATH"
        
        rm -f /tmp/gpg-keygen.batch
        rm -rf "$temp_gnupg"
        unset GNUPGHOME
        return 0
    else
        echo "ERROR: Failed to generate GPG key"
        rm -f /tmp/gpg-keygen.batch
        rm -rf "$temp_gnupg"
        unset GNUPGHOME
        return 1
    fi
}

# ==============================================
# REPOSITORY SIGNING
# ==============================================

sign_repository() {
    local repo_dir="$1"
    
    if [ ! -d "$repo_dir" ]; then
        echo "ERROR: Repository directory not found: $repo_dir"
        return 1
    fi
    
    if [ ! -f "$repo_dir/Packages.gz" ]; then
        echo "ERROR: Packages.gz not found in $repo_dir"
        return 1
    fi
    
    cd "$repo_dir" || return 1
    
    # Create proper directory structure
    mkdir -p dists/stable/main/binary-amd64
    
    # Copy Packages files
    cp Packages.gz dists/stable/main/binary-amd64/ 2>/dev/null || true
    cp Packages dists/stable/main/binary-amd64/ 2>/dev/null || true
    
    # Generate Release file
    cd "dists/stable" || return 1
    local valid_until
    valid_until=$(date -d "+90 days" -Ru)
    
    local pkg_gz_size pkg_size
    pkg_gz_size=$(stat -c %s "main/binary-amd64/Packages.gz" 2>/dev/null || echo "0")
    pkg_size=$(stat -c %s "main/binary-amd64/Packages" 2>/dev/null || echo "0")
    
    # Generate hashes for both files
    local sha1_gz sha256_gz sha512_gz
    local sha1_pkg sha256_pkg sha512_pkg
    
    sha1_gz=$(sha1sum main/binary-amd64/Packages.gz | awk '{print $1}')
    sha256_gz=$(sha256sum main/binary-amd64/Packages.gz | awk '{print $1}')
    sha512_gz=$(sha512sum main/binary-amd64/Packages.gz | awk '{print $1}')
    
    sha1_pkg=$(sha1sum main/binary-amd64/Packages | awk '{print $1}')
    sha256_pkg=$(sha256sum main/binary-amd64/Packages | awk '{print $1}')
    sha512_pkg=$(sha512sum main/binary-amd64/Packages | awk '{print $1}')
    
    cat > Release <<RELEASE_EOF
Origin: HDI Air-Gap Mirror
Label: Air-Gap Mirror
Suite: stable
Codename: stable
Architectures: amd64
Components: main
Description: Air-gapped deployment mirror with Ubuntu, Kubernetes, and CRI-O packages
Date: $(date -Ru)
Valid-Until: $valid_until
SHA1:
 $sha1_pkg $pkg_size main/binary-amd64/Packages
 $sha1_gz $pkg_gz_size main/binary-amd64/Packages.gz
SHA256:
 $sha256_pkg $pkg_size main/binary-amd64/Packages
 $sha256_gz $pkg_gz_size main/binary-amd64/Packages.gz
SHA512:
 $sha512_pkg $pkg_size main/binary-amd64/Packages
 $sha512_gz $pkg_gz_size main/binary-amd64/Packages.gz
RELEASE_EOF
    
    # Sign the Release file
    local temp_gnupg=$(mktemp -d)
    export GNUPGHOME="$temp_gnupg"
    
    if gpg --batch --no-tty --import "$GPG_KEY_PATH" 2>/dev/null; then
        local key_id=$(gpg --list-keys --with-colons 2>/dev/null | grep '^fpr:' | cut -d: -f10 | head -1)
        
        if [ -n "$key_id" ]; then
            gpg --clear-sign --batch --no-tty --yes --default-key "$key_id" --output InRelease Release
            gpg --detach-sign --armor --batch --no-tty --yes --default-key "$key_id" --output Release.gpg Release
            cp "$GPG_PUBLIC_KEY_PATH" Release.key 2>/dev/null || true
            
            echo "Repository signed successfully"
            rm -rf "$temp_gnupg"
            unset GNUPGHOME
            return 0
        fi
    fi
    
    echo "ERROR: Failed to sign repository"
    rm -rf "$temp_gnupg"
    unset GNUPGHOME
    return 1
}

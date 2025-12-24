#!/bin/bash

# Exit on any error
set -e

# Configuration
AUTH_KEY="${AUTH_KEY:-~/.ssh/put-your-key-here.key}"
AUTH_KEY_EXPANDED=$(eval echo "$AUTH_KEY")

# Node map: node_name -> ip_address
#["dev03"]="10.0.0.5"
declare -A NODES=(
    ["dev01"]="10.0.0.3"
    ["dev02"]="10.0.0.4"
    ["dev03"]="10.0.0.5"
)

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if permissions are actually wrong (not just different representation)
check_sudoers_permissions() {
    local file="$1"
    
    if [[ -f "$file" ]]; then
        local current_mode=$(stat -c %a "$file")
        # Check if permissions are too permissive (not 440, 440, 0440, or 0440)
        if [[ ! "$current_mode" =~ ^0?440$ ]] || [[ "$current_mode" == "440" && "$(stat -c %A "$file")" =~ [w+]] ]]; then
            log_warn "Fixing permissions on $file (was $current_mode, should be 0440)"
            chmod 0440 "$file"
            return 1
        fi
    fi
    return 0
}

# Function to validate sudoers configuration
validate_sudoers() {
    if visudo -c &>/dev/null; then
        log_info "✓ Sudoers configuration is valid"
        return 0
    else
        log_error "✗ Sudoers configuration has errors"
        return 1
    fi
}

# Function to setup k8s-admin user on a remote node
setup_remote_node() {
    local node_name="$1"
    local node_ip="$2"
    
    log_info "Setting up k8s-admin on $node_name ($node_ip)..."
    
    # Check if we can connect to the node    
    if ! ssh -o ConnectTimeout=10 -o BatchMode=yes -i "$AUTH_KEY_EXPANDED" root@"$node_ip" "echo 'Connection successful'" &>/dev/null; then
        log_error "Cannot connect to $node_name ($node_ip). Skipping..."
        return 1
    fi
    
    # Create the setup script for remote execution
    local remote_script=$(cat << 'REMOTE_SCRIPT'
#!/bin/bash
set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 1. Create the user if it doesn't exist
if ! id "k8s-admin" &>/dev/null; then
    log_info "Creating user 'k8s-admin'..."
    useradd -m -s /bin/bash k8s-admin
else
    log_info "User 'k8s-admin' already exists."
fi

# 2. Add to sudoers with NOPASSWD (idempotent check)
SUDOERS_FILE="/etc/sudoers.d/k8s-admin"
SUDOERS_CONTENT="k8s-admin ALL=(ALL) NOPASSWD:ALL"

if [[ ! -f "$SUDOERS_FILE" ]] || ! grep -qxF "$SUDOERS_CONTENT" "$SUDOERS_FILE" 2>/dev/null; then
    echo "$SUDOERS_CONTENT" > "$SUDOERS_FILE"
    chmod 0440 "$SUDOERS_FILE"
    log_info "Configured sudoers for k8s-admin"
fi

# 3. Set up SSH access (idempotent)
log_info "Setting up SSH access for 'k8s-admin'..."
mkdir -p /home/k8s-admin/.ssh

# Copy authorized_keys from root if it exists
if [[ -f "/root/.ssh/authorized_keys" ]]; then
    if [[ ! -f "/home/k8s-admin/.ssh/authorized_keys" ]] || \
       ! cmp -s "/root/.ssh/authorized_keys" "/home/k8s-admin/.ssh/authorized_keys"; then
        cp /root/.ssh/authorized_keys /home/k8s-admin/.ssh/
        log_info "Copied authorized_keys to k8s-admin"
    fi
else
    log_warn "No authorized_keys found in /root/.ssh/"
fi

# Set proper permissions
chown -R k8s-admin:k8s-admin /home/k8s-admin/.ssh
chmod 700 /home/k8s-admin/.ssh
if [[ -f "/home/k8s-admin/.ssh/authorized_keys" ]]; then
    chmod 600 /home/k8s-admin/.ssh/authorized_keys
fi

# 4. Configure sudo logging
log_info "Configuring sudo command logging..."

# Create log directory if it doesn't exist
LOG_DIR="/var/log/sudo"
if [[ ! -d "$LOG_DIR" ]]; then
    mkdir -p "$LOG_DIR"
fi

# Create sudoers logging configuration
SUDO_LOGGING_CONFIG="/etc/sudoers.d/k8s-admin-logging"
cat > "$SUDO_LOGGING_CONFIG" << 'EOF'
# Sudo logging configuration for k8s-admin
Defaults:k8s-admin log_host, log_year, log_input, log_output
Defaults:k8s-admin logfile="/var/log/sudo/sudo_commands.log"
EOF
chmod 0440 "$SUDO_LOGGING_CONFIG"

# Create log file with proper permissions
LOG_FILE="/var/log/sudo/sudo_commands.log"
if [[ ! -f "$LOG_FILE" ]]; then
    touch "$LOG_FILE"
fi
chown root:adm "$LOG_FILE"
chmod 640 "$LOG_FILE"

# 5. Configure logrotate for sudo logs
LOGROTATE_CONFIG="/etc/logrotate.d/sudo-commands"
cat > "$LOGROTATE_CONFIG" << 'EOF'
/var/log/sudo/sudo_commands.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    create 640 root adm
    postrotate
        /usr/bin/systemctl reload rsyslog 2>/dev/null || true
    endscript
}
EOF

# Validate sudoers configuration
if visudo -c &>/dev/null; then
    log_info "✓ Sudoers configuration validated"
else
    log_error "✗ Sudoers configuration has errors"
    exit 1
fi

log_info "✓ k8s-admin setup completed on $(hostname)"
REMOTE_SCRIPT
)

    # Execute the remote script
    log_info "Executing setup script on $node_name..."
    if ssh -o ConnectTimeout=30 -i "$AUTH_KEY_EXPANDED" root@"$node_ip" "bash -s" <<< "$remote_script"; then
        log_info "✓ Successfully setup k8s-admin on $node_name"
        return 0
    else
        log_error "✗ Failed to setup k8s-admin on $node_name"
        return 1
    fi
}

# Function to add hosts to known_hosts (remove and re-add for freshness)
add_to_known_hosts() {
    log_info "Updating known_hosts for all nodes..."
    
    # Ensure known_hosts file exists with proper permissions
    mkdir -p ~/.ssh
    touch ~/.ssh/known_hosts
    chmod 644 ~/.ssh/known_hosts
    
    for node_name in "${!NODES[@]}"; do
        local node_ip="${NODES[$node_name]}"
        
        log_info "Updating known_hosts for $node_name ($node_ip)..."
        
        # Remove existing entries for both IP and hostname
        ssh-keygen -R "$node_ip" -f ~/.ssh/known_hosts &>/dev/null
        ssh-keygen -R "$node_name" -f ~/.ssh/known_hosts &>/dev/null
        
        # Get fresh host keys and add to known_hosts
        log_info "Fetching fresh SSH keys for $node_name ($node_ip)..."
        if timeout 10s ssh-keyscan -H "$node_ip" >> ~/.ssh/known_hosts 2>/dev/null; then
            log_info "✓ Successfully updated known_hosts for $node_ip"
            
            # Also add hostname entry if it resolves differently
            if [[ "$node_ip" != "$node_name" ]]; then
                echo "$node_name" >> ~/.ssh/known_hosts.tmp
                if timeout 10s ssh-keyscan -H "$node_name" >> ~/.ssh/known_hosts 2>/dev/null; then
                    log_info "✓ Successfully updated known_hosts for $node_name"
                else
                    log_warn "⚠ Could not resolve hostname $node_name, using IP only"
                fi
            fi
        else
            log_error "✗ Could not reach $node_ip - no host keys added"
        fi
    done
    
    # Remove any duplicate entries that might have been created
    if [[ -f ~/.ssh/known_hosts ]]; then
        sort -u ~/.ssh/known_hosts > ~/.ssh/known_hosts.tmp && mv ~/.ssh/known_hosts.tmp ~/.ssh/known_hosts
        log_info "Cleaned duplicate entries from known_hosts"
    fi
}

# Function to validate node accessibility
validate_nodes() {
    log_info "Validating node accessibility with k8s-admin user..."
    
    local accessible_nodes=()
    local failed_nodes=()
    
    for node_name in "${!NODES[@]}"; do
        local node_ip="${NODES[$node_name]}"
        
        log_info "Testing connection to $node_name as k8s-admin..."
        if ssh -o ConnectTimeout=10 -o BatchMode=yes -i "$AUTH_KEY_EXPANDED" k8s-admin@"$node_ip" "echo 'Connection successful'" &>/dev/null; then
            log_info "✓ $node_name is accessible as k8s-admin"
            accessible_nodes+=("$node_name")
        else
            log_error "✗ $node_name is not accessible as k8s-admin"
            failed_nodes+=("$node_name")
        fi
    done
    
    # Return arrays via global variables
    VALIDATION_ACCESSIBLE_NODES=("${accessible_nodes[@]}")
    VALIDATION_FAILED_NODES=("${failed_nodes[@]}")
    
    # Print summary
    log_info "=== Validation Summary ==="
    log_info "Accessible nodes (${#accessible_nodes[@]}): ${accessible_nodes[*]}"
    if [[ ${#failed_nodes[@]} -gt 0 ]]; then
        log_error "Failed nodes (${#failed_nodes[@]}): ${failed_nodes[*]}"
        return 1
    fi
    
    return 0
}

# Function to update SSH config with a single consolidated entry
# Function to update SSH config with individual host entries (simpler version)
update_ssh_config() {
    log_info "Updating SSH configuration..."
    
    local ssh_config=~/.ssh/config
    local config_backup="${ssh_config}.backup.$(date +%Y%m%d_%H%M%S)"
    local temp_config="${ssh_config}.tmp.$$"
    
    # Backup existing config
    if [[ -f "$ssh_config" ]]; then
        cp "$ssh_config" "$config_backup"
        log_info "Backed up existing SSH config to $config_backup"
    fi
    
    # Start with non-k8s section from existing config
    if [[ -f "$ssh_config" ]]; then
        # Extract everything before the k8s section
        awk '
            /^# Kubernetes nodes configuration/ { in_k8s_section=1; next }
            /^# End Kubernetes nodes configuration/ { in_k8s_section=0; next }
            in_k8s_section { next }
            { print }
        ' "$ssh_config" > "$temp_config"
    else
        touch "$temp_config"
    fi
    
    # Add k8s section header
    {
        echo ""
        echo "# Kubernetes nodes configuration"
        echo "# Generated by k8s-admin setup script"
        echo "# Last updated: $(date)"
        echo ""
    } >> "$temp_config"
    
    # Add individual host entries for each successfully configured node
    for node_name in "${SUCCESSFUL_NODES[@]}"; do
        local node_ip="${NODES[$node_name]}"
        {
            echo "Host $node_name"
            echo "    HostName $node_ip"
            echo "    User k8s-admin"
            echo "    IdentityFile $AUTH_KEY_EXPANDED"
            echo "    StrictHostKeyChecking yes"
            echo "    UserKnownHostsFile ~/.ssh/known_hosts"
            echo "    LogLevel INFO"
            echo ""
        } >> "$temp_config"
    done
    
    # Add end marker
    echo "# End Kubernetes nodes configuration" >> "$temp_config"
    
    # Replace the original config
    mv "$temp_config" "$ssh_config"
    chmod 600 "$ssh_config"
    
    log_info "✓ SSH configuration updated at $ssh_config"
    log_info "Configured individual entries for: ${SUCCESSFUL_NODES[*]}"
}

# Function to generate final report
generate_final_report() {
    local successful_setups="$1"
    local total_nodes="$2"
    
    log_info ""
    log_info "=== FINAL SETUP REPORT ==="
    log_info "Total nodes targeted: $total_nodes"
    log_info "Successfully configured: $successful_setups"
    
    # Show successfully configured nodes
    if [[ ${#SUCCESSFUL_NODES[@]} -gt 0 ]]; then
        log_info ""
        log_info "✓ SUCCESSFULLY CONFIGURED NODES (${#SUCCESSFUL_NODES[@]}):"
        for node in "${SUCCESSFUL_NODES[@]}"; do
            log_info "  - $node (${NODES[$node]})"
        done
        
        # Show accessible nodes from validation
        if [[ ${#VALIDATION_ACCESSIBLE_NODES[@]} -gt 0 ]]; then
            log_info ""
            log_info "✓ VALIDATED & ACCESSIBLE NODES (${#VALIDATION_ACCESSIBLE_NODES[@]}):"
            for node in "${VALIDATION_ACCESSIBLE_NODES[@]}"; do
                log_info "  - $node (${NODES[$node]})"
            done
        fi
    fi
    
    # Show failed setups
    if [[ ${#FAILED_SETUP_NODES[@]} -gt 0 ]]; then
        log_info ""
        log_error "✗ FAILED SETUP NODES (${#FAILED_SETUP_NODES[@]}):"
        for node in "${FAILED_SETUP_NODES[@]}"; do
            log_error "  - $node (${NODES[$node]}) - Setup failed or node unreachable"
        done
    fi
    
    # Show validation failures
    if [[ ${#VALIDATION_FAILED_NODES[@]} -gt 0 ]]; then
        log_info ""
        log_error "✗ VALIDATION FAILED NODES (${#VALIDATION_FAILED_NODES[@]}):"
        for node in "${VALIDATION_FAILED_NODES[@]}"; do
            log_error "  - $node (${NODES[$node]}) - Node not accessible as k8s-admin"
        done
    fi
    
    # Usage instructions for successful nodes
    if [[ ${#SUCCESSFUL_NODES[@]} -gt 0 ]]; then
        log_info ""
        log_info "=== USAGE INSTRUCTIONS ==="
        log_info "You can now connect to configured nodes using:"
        for node in "${SUCCESSFUL_NODES[@]}"; do
            log_info "  ssh $node    # Connect to $node using k8s-admin user"
        done
        log_info ""
        log_info "All connections use key-based authentication with: $AUTH_KEY_EXPANDED"
    fi
    
    # Overall status
    log_info ""
    if [[ $successful_setups -eq $total_nodes ]] && [[ ${#VALIDATION_FAILED_NODES[@]} -eq 0 ]]; then
        log_info "🎉 ALL NODES SUCCESSFULLY CONFIGURED AND VALIDATED!"
    elif [[ $successful_setups -gt 0 ]]; then
        log_warn "⚠ PARTIAL SUCCESS: Some nodes configured successfully, but some failed."
    else
        log_error "💥 ALL NODES FAILED! No successful configurations."
    fi
}

# Main execution
main() {
    log_info "Starting k8s-admin setup across all nodes..."
    log_info "Using authentication key: $AUTH_KEY_EXPANDED"
    
    # Global arrays to track node status
    declare -a SUCCESSFUL_NODES=()
    declare -a FAILED_SETUP_NODES=()
    declare -a VALIDATION_ACCESSIBLE_NODES=()
    declare -a VALIDATION_FAILED_NODES=()
    
    # Check if authentication key exists
    if [[ ! -f "$AUTH_KEY_EXPANDED" ]]; then
        log_error "Authentication key not found: $AUTH_KEY_EXPANDED"
        exit 1
    fi
    
    # Set strict permissions on the key
    chmod 600 "$AUTH_KEY_EXPANDED"
    
    # 1. Add all nodes to known_hosts
    add_to_known_hosts
    
    # 2. Setup k8s-admin on each node
    local successful_setups=0
    local total_nodes="${#NODES[@]}"
    
    for node_name in "${!NODES[@]}"; do
        local node_ip="${NODES[$node_name]}"
        
        if setup_remote_node "$node_name" "$node_ip"; then        
            successful_setups=$((successful_setups + 1))        
            SUCCESSFUL_NODES+=("$node_name")
            echo $SUCCESSFUL_NODES
        else
            FAILED_SETUP_NODES+=("$node_name")
        fi
        echo # Add spacing between nodes
    done    
    
    log_info "=== Setup Summary ==="
    log_info "Successfully configured: $successful_setups/$total_nodes nodes"
    
    if [[ $successful_setups -eq 0 ]]; then
        log_error "No nodes were successfully configured. Exiting."
        exit 1
    fi
    
    # 3. Validate node accessibility (only for successfully configured nodes)
    if [[ ${#SUCCESSFUL_NODES[@]} -gt 0 ]]; then
        if ! validate_nodes; then
            log_warn "Some nodes are not accessible, but continuing with SSH config update..."
        fi
    else
        log_error "No successful node setups to validate."
        exit 1
    fi
    
    # 4. Update SSH config (only with successfully configured nodes)
    if [[ ${#SUCCESSFUL_NODES[@]} -gt 0 ]]; then
        update_ssh_config
    else
        log_error "No successfully configured nodes to add to SSH config"
        exit 1
    fi
    
    # 5. Generate final dynamic report
    generate_final_report "$successful_setups" "$total_nodes"
}

# Run main function
main "$@"

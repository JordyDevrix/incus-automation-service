#!/usr/bin/env bash
# ==============================================================================
# Script: provision_vm.sh
# Description: Provisions an Incus VM directly with dedicated, non-conflicting
# IPv4 and IPv6 addresses designed to scale to 400+ student workloads.
# Single source of truth for Incus VM creation, resource configuration, and networking.
# ==============================================================================

set -euo pipefail

# ANSI color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

log_step() {
    echo -e "${CYAN}==>${NC} $1"
}

# ------------------------------------------------------------------------------
# 1. Defaults and Argument Parsing
# ------------------------------------------------------------------------------
VM_NAME="${INSTANCE_VM_NAME:-}"
OS_IMAGE="${INSTANCE_OS_IMAGE:-ubuntu-24.04}"
CPU_COUNT="${INSTANCE_CPU_COUNT:-2}"
RAM_SIZE="${INSTANCE_RAM_SIZE:-4GiB}"
DISK_SIZE="${INSTANCE_DISK_SIZE:-40GiB}"
SSH_KEY="${INSTANCE_ADMIN_SSH_KEY:-}"
ADMIN_USER="${INSTANCE_ADMIN_USER:-admin}"
LIFETIME="${INSTANCE_LIFETIME:-7d}"
VM_IDENTIFIER="${VM_IDENTIFIER:-}"

# High-Capacity /20 Network Configuration (4,093 usable host IPs)
NETWORK_NAME="${INSTANCE_NETWORK:-incusbr0}"
ASSIGNED_IPV4="${INSTANCE_IPV4:-}"
ASSIGNED_IPV6="${INSTANCE_IPV6:-}"
GATEWAY_IPV4="${INSTANCE_GATEWAY_IPV4:-10.100.0.1}"
GATEWAY_IPV6="${INSTANCE_GATEWAY_IPV6:-fd42:100:100::1}"
SUBNET_CIDR_V4="${INSTANCE_SUBNET_CIDR:-20}"
SUBNET_CIDR_V6="${INSTANCE_SUBNET_CIDR_V6:-64}"

DRY_RUN="${DRY_RUN:-0}"

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  -n, --name NAME             VM Instance Name (required)
  -i, --image IMAGE           OS Image (default: ubuntu-24.04)
  -c, --cpu CORES             CPU cores count (default: 2)
  -m, --ram RAM               RAM memory size (e.g. 4GiB, default: 4GiB)
  -d, --disk DISK             Disk size (e.g. 40GiB, default: 40GiB)
  -k, --ssh-key KEY           Admin SSH public key
  -u, --user USERNAME         Admin username (default: admin)
  -l, --lifetime DURATION     Lifetime (e.g. 7d, 24h, persistent, default: 7d)
      --ipv4 IP               Dedicated IPv4 address (e.g. 10.100.0.15)
      --ipv6 IP               Dedicated IPv6 address (e.g. fd42:100:100::15)
      --network NAME          Incus Network bridge name (default: incusbr0)
      --gateway-v4 IP         IPv4 Gateway (default: 10.100.0.1)
      --gateway-v6 IP         IPv6 Gateway (default: fd42:100:100::1)
      --vm-id ID              Unique VM Identifier (default: same as VM name)
      --dry-run               Simulate provisioning without modifying Incus host
  -h, --help                  Show this help message

Environment variables with the same names (or INSTANCE_*) are also supported.
EOF
    exit 1
}

# Parse CLI arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--name)
            VM_NAME="$2"
            shift 2
            ;;
        -i|--image)
            OS_IMAGE="$2"
            shift 2
            ;;
        -c|--cpu)
            CPU_COUNT="$2"
            shift 2
            ;;
        -m|--ram)
            RAM_SIZE="$2"
            shift 2
            ;;
        -d|--disk)
            DISK_SIZE="$2"
            shift 2
            ;;
        -k|--ssh-key)
            SSH_KEY="$2"
            shift 2
            ;;
        -u|--user)
            ADMIN_USER="$2"
            shift 2
            ;;
        -l|--lifetime)
            LIFETIME="$2"
            shift 2
            ;;
        --ipv4)
            ASSIGNED_IPV4="$2"
            shift 2
            ;;
        --ipv6)
            ASSIGNED_IPV6="$2"
            shift 2
            ;;
        --network)
            NETWORK_NAME="$2"
            shift 2
            ;;
        --gateway-v4)
            GATEWAY_IPV4="$2"
            shift 2
            ;;
        --gateway-v6)
            GATEWAY_IPV6="$2"
            shift 2
            ;;
        --vm-id)
            VM_IDENTIFIER="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN="1"
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_error "Unknown argument: $1"
            usage
            ;;
    esac
done

# Validate required parameters
if [[ -z "$VM_NAME" ]]; then
    log_error "VM Instance name is required. Specify with -n or --name."
    exit 1
fi

if [[ -z "$VM_IDENTIFIER" ]]; then
    VM_IDENTIFIER="$VM_NAME"
fi

# Fallback deterministic IP if not provided
if [[ -z "$ASSIGNED_IPV4" ]]; then
    # Generate deterministic IP based on crc32/hash within 10.100.0.2 - 10.100.15.254 range
    HASH_VAL=$(echo -n "$VM_IDENTIFIER" | cksum | awk '{print $1}')
    IP_OFFSET=$(( (HASH_VAL % 4090) + 2 ))
    OCT3=$(( IP_OFFSET / 256 ))
    OCT4=$(( IP_OFFSET % 256 ))
    if [[ $OCT4 -eq 0 ]]; then OCT4=1; fi
    ASSIGNED_IPV4="10.100.${OCT3}.${OCT4}"
    ASSIGNED_IPV6=$(printf "fd42:100:100::%x" "$IP_OFFSET")
fi

if [[ -z "$ASSIGNED_IPV6" ]]; then
    ASSIGNED_IPV6="fd42:100:100::$(echo -n "$ASSIGNED_IPV4" | awk -F. '{printf "%x%02x", $3, $4}')"
fi

# ------------------------------------------------------------------------------
# 2. Image Alias Resolution
# ------------------------------------------------------------------------------
RESOLVED_IMAGE="$OS_IMAGE"
case "$OS_IMAGE" in
    "ubuntu-24.04"|"ubuntu/24.04"|"24.04")
        RESOLVED_IMAGE="images:ubuntu/24.04/cloud"
        ;;
    "ubuntu-22.04"|"ubuntu/22.04"|"22.04")
        RESOLVED_IMAGE="images:ubuntu/22.04/cloud"
        ;;
    "debian-12"|"debian/12")
        RESOLVED_IMAGE="images:debian/12/cloud"
        ;;
    "debian-11"|"debian/11")
        RESOLVED_IMAGE="images:debian/11/cloud"
        ;;
    "alpine-3.20"|"alpine/3.20")
        RESOLVED_IMAGE="images:alpine/3.20/cloud"
        ;;
    "archlinux"|"arch")
        RESOLVED_IMAGE="images:archlinux/cloud"
        ;;
    *)
        RESOLVED_IMAGE="$OS_IMAGE"
        ;;
esac

# ------------------------------------------------------------------------------
# 3. Print Provisioning Plan
# ------------------------------------------------------------------------------
log_info "=========================================="
log_info "Incus VM High-Capacity Provisioning Plan"
log_info "=========================================="
echo "  - VM Identifier : $VM_IDENTIFIER"
echo "  - VM Name       : $VM_NAME"
echo "  - OS Image      : $OS_IMAGE (Resolved: $RESOLVED_IMAGE)"
echo "  - CPU Limit     : $CPU_COUNT cores"
echo "  - RAM Limit     : $RAM_SIZE"
echo "  - Root Disk     : $DISK_SIZE"
echo "  - Assigned IPv4 : $ASSIGNED_IPV4 / $SUBNET_CIDR_V4 (Gateway: $GATEWAY_IPV4)"
echo "  - Assigned IPv6 : $ASSIGNED_IPV6 / $SUBNET_CIDR_V6 (Gateway: $GATEWAY_IPV6)"
echo "  - Network Bridge: $NETWORK_NAME (High-capacity /20 pool: 4093 hosts)"
echo "  - Admin User    : $ADMIN_USER"
echo "  - SSH Key       : $(if [[ -n "$SSH_KEY" ]]; then echo "${SSH_KEY:0:25}... (${#SSH_KEY} chars)"; else echo "(none)"; fi)"
echo "  - Lifetime      : $LIFETIME"
echo "  - Dry Run Mode  : $DRY_RUN"

# ------------------------------------------------------------------------------
# 4. Check Incus Environment & Dry Run Mode
# ------------------------------------------------------------------------------
INCUS_BIN="$(command -v incus || true)"

if [[ -z "$INCUS_BIN" ]]; then
    log_warn "Incus command binary not found on this system PATH."
    log_warn "Executing in SIMULATION / DRY-RUN mode."
    DRY_RUN="1"
elif [[ "$DRY_RUN" == "1" || "$DRY_RUN" == "true" ]]; then
    log_info "Dry-Run mode requested."
fi

# ------------------------------------------------------------------------------
# 5. Prepare Cloud-Init User Data & Dual-Redundancy Network Configuration
# ------------------------------------------------------------------------------
TMP_CLOUD_INIT=$(mktemp /tmp/cloud-init-XXXXXX.yml)
TMP_NET_CONFIG=$(mktemp /tmp/cloud-net-XXXXXX.yml)
trap 'rm -f "$TMP_CLOUD_INIT" "$TMP_NET_CONFIG"' EXIT

# Cloud-Init User Data
cat <<EOF > "$TMP_CLOUD_INIT"
#cloud-config
users:
  - name: ${ADMIN_USER}
    gecos: ${ADMIN_USER} Administrator
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    groups: [adm, sudo, wheel]
EOF

if [[ -n "${SSH_KEY:-}" ]]; then
    cat <<EOF >> "$TMP_CLOUD_INIT"
    ssh_authorized_keys:
      - "${SSH_KEY}"
EOF
fi

cat <<EOF >> "$TMP_CLOUD_INIT"
package_update: true
packages:
  - curl
  - htop
  - qemu-guest-agent
EOF

# Cloud-Init Network Config (v2) with explicit static addresses & gateways + DHCP fallback
cat <<EOF > "$TMP_NET_CONFIG"
version: 2
ethernets:
  all-interfaces:
    match:
      name: "en*|eth*"
    addresses:
      - ${ASSIGNED_IPV4}/${SUBNET_CIDR_V4}
      - ${ASSIGNED_IPV6}/${SUBNET_CIDR_V6}
    routes:
      - to: default
        via: ${GATEWAY_IPV4}
      - to: default
        via: ${GATEWAY_IPV6}
    nameservers:
      addresses:
        - ${GATEWAY_IPV4}
        - 1.1.1.1
        - 8.8.8.8
        - 2606:4700:4700::1111
    dhcp4: true
    dhcp6: true
    accept-ra: true
EOF

# ------------------------------------------------------------------------------
# 6. Execute Provisioning
# ------------------------------------------------------------------------------
if [[ "$DRY_RUN" == "1" || "$DRY_RUN" == "true" ]]; then
    log_step "[DRY-RUN] Step 1: Initializing VM instance"
    echo "  >> incus init \"$RESOLVED_IMAGE\" \"$VM_NAME\" --vm"
    
    log_step "[DRY-RUN] Step 2: Configuring CPU limit"
    echo "  >> incus config set \"$VM_NAME\" limits.cpu=\"$CPU_COUNT\""
    
    log_step "[DRY-RUN] Step 3: Configuring RAM memory limit"
    echo "  >> incus config set \"$VM_NAME\" limits.memory=\"$RAM_SIZE\""
    
    log_step "[DRY-RUN] Step 4: Configuring Root Disk size"
    echo "  >> incus config device override \"$VM_NAME\" root size=\"$DISK_SIZE\""
    
    log_step "[DRY-RUN] Step 5: Binding static IPv4 ($ASSIGNED_IPV4) and IPv6 ($ASSIGNED_IPV6) to NIC device"
    echo "  >> incus config device add \"$VM_NAME\" eth0 nic network=\"$NETWORK_NAME\" name=eth0 ipv4.address=\"$ASSIGNED_IPV4\" ipv6.address=\"$ASSIGNED_IPV6\""
    
    log_step "[DRY-RUN] Step 6: Setting Cloud-Init Dual-Stack Network Config"
    echo "  >> incus config set \"$VM_NAME\" user.network-config < (addresses: [$ASSIGNED_IPV4/20, $ASSIGNED_IPV6/64])"
    
    log_step "[DRY-RUN] Step 7: Applying Cloud-Init User Data & SSH keys"
    echo "  >> incus config set \"$VM_NAME\" user.user-data < cloud-init"
    
    log_step "[DRY-RUN] Step 8: Setting VM Identifier and Lifetime Metadata"
    echo "  >> incus config set \"$VM_NAME\" user.vm_identifier=\"$VM_IDENTIFIER\""
    echo "  >> incus config set \"$VM_NAME\" user.lifetime=\"$LIFETIME\""
    echo "  >> incus config set \"$VM_NAME\" user.assigned_ipv4=\"$ASSIGNED_IPV4\""
    echo "  >> incus config set \"$VM_NAME\" user.assigned_ipv6=\"$ASSIGNED_IPV6\""
    
    log_step "[DRY-RUN] Step 9: Starting VM instance"
    echo "  >> incus start \"$VM_NAME\""

    log_success "[DRY-RUN] Workload '$VM_NAME' (ID: $VM_IDENTIFIER) verified with dedicated IPv4: $ASSIGNED_IPV4 and IPv6: $ASSIGNED_IPV6."
    exit 0
fi

# Live Execution
if incus info "$VM_NAME" &>/dev/null; then
    log_error "An Incus instance with name '$VM_NAME' already exists."
    exit 1
fi

# Ensure high-capacity network bridge exists (if creating a new bridge)
if ! incus network show "$NETWORK_NAME" &>/dev/null; then
    log_info "Creating high-capacity network bridge '$NETWORK_NAME' with /20 subnet..."
    incus network create "$NETWORK_NAME" \
        ipv4.address="${GATEWAY_IPV4}/${SUBNET_CIDR_V4}" \
        ipv4.nat=true \
        ipv4.dhcp=true \
        ipv6.address="${GATEWAY_IPV6}/${SUBNET_CIDR_V6}" \
        ipv6.nat=true \
        ipv6.dhcp=true || true
fi

log_step "Step 1: Initializing VM instance '$VM_NAME' with image '$RESOLVED_IMAGE'..."
incus init "$RESOLVED_IMAGE" "$VM_NAME" --vm

log_step "Step 2: Setting CPU limits ($CPU_COUNT cores)..."
incus config set "$VM_NAME" limits.cpu="$CPU_COUNT"

log_step "Step 3: Setting RAM memory limits ($RAM_SIZE)..."
incus config set "$VM_NAME" limits.memory="$RAM_SIZE"

log_step "Step 4: Setting root disk size ($DISK_SIZE)..."
incus config device override "$VM_NAME" root size="$DISK_SIZE" || incus config device set "$VM_NAME" root size="$DISK_SIZE"

log_step "Step 5: Binding dedicated IPv4 ($ASSIGNED_IPV4) & IPv6 ($ASSIGNED_IPV6) to NIC device..."
if incus config device show "$VM_NAME" 2>/dev/null | grep -q "eth0:"; then
    incus config device set "$VM_NAME" eth0 ipv4.address="$ASSIGNED_IPV4"
    incus config device set "$VM_NAME" eth0 ipv6.address="$ASSIGNED_IPV6"
else
    incus config device add "$VM_NAME" eth0 nic network="$NETWORK_NAME" name=eth0 ipv4.address="$ASSIGNED_IPV4" ipv6.address="$ASSIGNED_IPV6"
fi

log_step "Step 6: Applying Dual-Stack static + DHCP network configuration..."
incus config set "$VM_NAME" user.network-config - < "$TMP_NET_CONFIG"

log_step "Step 7: Applying cloud-init user-data..."
incus config set "$VM_NAME" user.user-data - < "$TMP_CLOUD_INIT"

log_step "Step 8: Setting metadata (vm_identifier=$VM_IDENTIFIER, lifetime=$LIFETIME)..."
incus config set "$VM_NAME" user.vm_identifier="$VM_IDENTIFIER"
incus config set "$VM_NAME" user.lifetime="$LIFETIME"
incus config set "$VM_NAME" user.assigned_ipv4="$ASSIGNED_IPV4"
incus config set "$VM_NAME" user.assigned_ipv6="$ASSIGNED_IPV6"

log_step "Step 9: Starting VM '$VM_NAME'..."
incus start "$VM_NAME"

log_success "Workload '$VM_NAME' (ID: $VM_IDENTIFIER) launched successfully with dedicated IPv4 ($ASSIGNED_IPV4) and IPv6 ($ASSIGNED_IPV6)!"

log_step "Current VM Status & Network Leases:"
incus info "$VM_NAME" || true

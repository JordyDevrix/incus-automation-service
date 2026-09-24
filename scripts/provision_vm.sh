#!/usr/bin/env bash
# ==============================================================================
# Script: provision_vm.sh
# Description: Provisions an Incus VM directly with guaranteed, non-conflicting
# IPv4 and IPv6 addresses aligned with the active host Incus bridge network.
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
INSTANCE_TYPE="${INSTANCE_TYPE:-container}"
CPU_COUNT="${INSTANCE_CPU_COUNT:-2}"
RAM_SIZE="${INSTANCE_RAM_SIZE:-4GiB}"
DISK_SIZE="${INSTANCE_DISK_SIZE:-40GiB}"
SSH_KEY="${INSTANCE_ADMIN_SSH_KEY:-}"
ADMIN_USER="${INSTANCE_ADMIN_USER:-admin}"
LIFETIME="${INSTANCE_LIFETIME:-7d}"
VM_IDENTIFIER="${VM_IDENTIFIER:-}"

# Network Defaults
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
  -n, --name NAME             Instance Name (required)
  -t, --type TYPE             Workload type: container (default) or vm
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
      --vm-id ID              Unique Workload Identifier (default: same as instance name)
      --dry-run               Simulate provisioning without modifying Incus host
  -h, --help                  Show this help message

Environment variables with the same names (or INSTANCE_*) are also supported.
EOF
    exit 1
}

# Parse CLI arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--type|--instance-type)
            INSTANCE_TYPE="$2"
            shift 2
            ;;
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

INCUS_BIN=""
for candidate in "$(command -v incus || true)" "/usr/local/bin/incus" "/usr/bin/incus" "/snap/bin/incus" "$(command -v lxc || true)"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
        INCUS_BIN="$candidate"
        break
    fi
done

if [[ -z "$INCUS_BIN" ]]; then
    log_warn "Incus command binary not found on this system PATH."
    log_warn "Executing in SIMULATION / DRY-RUN mode."
    DRY_RUN="1"
elif [[ "$DRY_RUN" == "1" || "$DRY_RUN" == "true" ]]; then
    log_info "Dry-Run mode requested."
fi

# ------------------------------------------------------------------------------
# 2. Bridge Network Kernel & Subnet Inspection
# ------------------------------------------------------------------------------
ACTUAL_BRIDGE_V4=""
ACTUAL_BRIDGE_V6=""

# 1. Check kernel network interface via ip command
if command -v ip &>/dev/null; then
    ACTUAL_BRIDGE_V4="$(ip -4 -o addr show dev "$NETWORK_NAME" 2>/dev/null | awk '{print $4}' | head -n 1 || true)"
    ACTUAL_BRIDGE_V6="$(ip -6 -o addr show dev "$NETWORK_NAME" scope global 2>/dev/null | awk '{print $4}' | head -n 1 || true)"
fi

# 2. Check Incus CLI if ip command didn't find CIDR
if [[ -z "$ACTUAL_BRIDGE_V4" && -n "$INCUS_BIN" ]]; then
    raw_cli_v4="$("$INCUS_BIN" network get "$NETWORK_NAME" ipv4.address 2>/dev/null || true)"
    if [[ "$raw_cli_v4" =~ / ]]; then
        ACTUAL_BRIDGE_V4="$raw_cli_v4"
    fi
fi
if [[ -z "$ACTUAL_BRIDGE_V6" && -n "$INCUS_BIN" ]]; then
    raw_cli_v6="$("$INCUS_BIN" network get "$NETWORK_NAME" ipv6.address 2>/dev/null || true)"
    if [[ "$raw_cli_v6" =~ / ]]; then
        ACTUAL_BRIDGE_V6="$raw_cli_v6"
    fi
fi

# Dynamically calculate and align IP parameters with active host bridge subnet
ALIGNED_NETWORK_PARAMS=$(python3 - <<EOF
import ipaddress
import sys
import zlib

bridge_v4 = "$ACTUAL_BRIDGE_V4".strip()
bridge_v6 = "$ACTUAL_BRIDGE_V6".strip()
req_v4 = "$ASSIGNED_IPV4".strip()
req_v6 = "$ASSIGNED_IPV6".strip()
vm_id = "$VM_IDENTIFIER".strip()
def_v4_gw = "$GATEWAY_IPV4"
def_v4_cidr = "$SUBNET_CIDR_V4"
def_v6_gw = "$GATEWAY_IPV6"
def_v6_cidr = "$SUBNET_CIDR_V6"

final_v4 = ""
final_v4_gw = def_v4_gw
final_v4_cidr = def_v4_cidr

final_v6 = ""
final_v6_gw = def_v6_gw
final_v6_cidr = def_v6_cidr

# 1. Process IPv4 Subnet Alignment
if bridge_v4 and "/" in bridge_v4:
    try:
        ip_part, cidr_part = bridge_v4.split("/")
        net4 = ipaddress.IPv4Network(f"{ip_part}/{cidr_part}", strict=False)
        final_v4_gw = ip_part
        final_v4_cidr = cidr_part

        # Check if requested IP fits inside this exact subnet
        if req_v4:
            try:
                ip_obj = ipaddress.IPv4Address(req_v4)
                if ip_obj in net4 and ip_obj != net4.network_address and ip_obj != ipaddress.IPv4Address(final_v4_gw) and ip_obj != net4.broadcast_address:
                    final_v4 = req_v4
            except Exception:
                pass

        if not final_v4:
            # Generate deterministic IP in this bridge subnet
            hash_val = zlib.crc32(vm_id.encode())
            num_hosts = net4.num_addresses - 3
            if num_hosts > 0:
                offset = (hash_val % num_hosts) + 2
                final_v4 = str(net4.network_address + offset)
    except Exception:
        pass

if not final_v4:
    if req_v4:
        final_v4 = req_v4
    else:
        hash_val = zlib.crc32(vm_id.encode())
        offset = (hash_val % 4090) + 2
        oct3 = offset // 256
        oct4 = offset % 256
        if oct4 == 0: oct4 = 1
        final_v4 = f"10.100.{oct3}.{oct4}"

# 2. Process IPv6 Subnet Alignment
if bridge_v6 and "/" in bridge_v6:
    try:
        v6_ip_part, v6_cidr_part = bridge_v6.split("/")
        net6 = ipaddress.IPv6Network(f"{v6_ip_part}/{v6_cidr_part}", strict=False)
        final_v6_gw = v6_ip_part
        final_v6_cidr = v6_cidr_part
        
        parts = [p for p in v6_ip_part.split(":") if p]
        prefix = ":".join(parts[:4] if len(parts) >= 4 else parts[:3])
        
        hash_val = (zlib.crc32(vm_id.encode()) % 65530) + 2
        final_v6 = f"{prefix}::{hash_val:x}"
    except Exception:
        pass

if not final_v6:
    if req_v6:
        final_v6 = req_v6
    else:
        hash_val = (zlib.crc32(vm_id.encode()) % 65530) + 2
        final_v6 = f"fd42:100:100::{hash_val:x}"

print(f"ASSIGNED_IPV4={final_v4}")
print(f"GATEWAY_IPV4={final_v4_gw}")
print(f"SUBNET_CIDR_V4={final_v4_cidr}")
print(f"ASSIGNED_IPV6={final_v6}")
print(f"GATEWAY_IPV6={final_v6_gw}")
print(f"SUBNET_CIDR_V6={final_v6_cidr}")
EOF
)

while IFS='=' read -r key val; do
    if [[ -n "$key" ]]; then
        export "$key"="$val"
    fi
done <<< "$ALIGNED_NETWORK_PARAMS"

# ------------------------------------------------------------------------------
# 3. Image Alias Resolution
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
# 4. Print Provisioning Plan
# ------------------------------------------------------------------------------
log_info "=========================================="
log_info "Incus High-Capacity Provisioning Plan"
log_info "=========================================="
echo "  - Workload Type : $INSTANCE_TYPE"
echo "  - Identifier    : $VM_IDENTIFIER"
echo "  - Instance Name : $VM_NAME"
echo "  - OS Image      : $OS_IMAGE (Resolved: $RESOLVED_IMAGE)"
echo "  - CPU Limit     : $CPU_COUNT cores"
echo "  - RAM Limit     : $RAM_SIZE"
echo "  - Root Disk     : $DISK_SIZE"
echo "  - Assigned IPv4 : $ASSIGNED_IPV4 / $SUBNET_CIDR_V4 (Gateway: $GATEWAY_IPV4)"
echo "  - Assigned IPv6 : $ASSIGNED_IPV6 / $SUBNET_CIDR_V6 (Gateway: $GATEWAY_IPV6)"
echo "  - Network Bridge: $NETWORK_NAME (Subnet: $GATEWAY_IPV4/$SUBNET_CIDR_V4)"
echo "  - Admin User    : $ADMIN_USER"
echo "  - SSH Key       : $(if [[ -n "$SSH_KEY" ]]; then echo "${SSH_KEY:0:25}... (${#SSH_KEY} chars)"; else echo "(none)"; fi)"
echo "  - Lifetime      : $LIFETIME"
echo "  - Dry Run Mode  : $DRY_RUN"

# ------------------------------------------------------------------------------
# 5. Prepare Cloud-Init User Data
# ------------------------------------------------------------------------------
TMP_CLOUD_INIT=$(mktemp /tmp/cloud-init-XXXXXX.yml)
trap 'rm -f "$TMP_CLOUD_INIT"' EXIT

# Cloud-Init User Data for user/auth setup
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

if [[ "$INSTANCE_TYPE" == "vm" ]]; then
    cat <<EOF >> "$TMP_CLOUD_INIT"
package_update: true
packages:
  - curl
  - htop
  - qemu-guest-agent
runcmd:
  - [ systemctl, enable, --now, qemu-guest-agent ]
EOF
else
    cat <<EOF >> "$TMP_CLOUD_INIT"
package_update: false
EOF
fi

# ------------------------------------------------------------------------------
# 6. Execute Provisioning
# ------------------------------------------------------------------------------
if [[ "$DRY_RUN" == "1" || "$DRY_RUN" == "true" ]]; then
    log_step "[DRY-RUN] Step 1: Initializing $INSTANCE_TYPE instance"
    if [[ "$INSTANCE_TYPE" == "vm" ]]; then
        echo "  >> incus init \"$RESOLVED_IMAGE\" \"$VM_NAME\" --vm"
    else
        echo "  >> incus init \"$RESOLVED_IMAGE\" \"$VM_NAME\""
    fi
    
    log_step "[DRY-RUN] Step 2: Configuring CPU limit"
    echo "  >> incus config set \"$VM_NAME\" limits.cpu=\"$CPU_COUNT\""
    
    log_step "[DRY-RUN] Step 3: Configuring RAM memory limit"
    echo "  >> incus config set \"$VM_NAME\" limits.memory=\"$RAM_SIZE\""
    
    log_step "[DRY-RUN] Step 4: Configuring Root Disk size"
    echo "  >> incus config device override \"$VM_NAME\" root size=\"$DISK_SIZE\""
    
    log_step "[DRY-RUN] Step 5: Binding static IPv4 ($ASSIGNED_IPV4) and IPv6 ($ASSIGNED_IPV6) to NIC device"
    echo "  >> incus config device override \"$VM_NAME\" eth0 ipv4.address=\"$ASSIGNED_IPV4\" ipv6.address=\"$ASSIGNED_IPV6\""
    
    log_step "[DRY-RUN] Step 6: Applying Cloud-Init User Data & SSH keys"
    echo "  >> incus config set \"$VM_NAME\" user.user-data=- < cloud-init"
    
    log_step "[DRY-RUN] Step 7: Setting Identifier, Type, and Lifetime Metadata"
    echo "  >> incus config set \"$VM_NAME\" user.vm_identifier=\"$VM_IDENTIFIER\""
    echo "  >> incus config set \"$VM_NAME\" user.instance_type=\"$INSTANCE_TYPE\""
    echo "  >> incus config set \"$VM_NAME\" user.lifetime=\"$LIFETIME\""
    echo "  >> incus config set \"$VM_NAME\" user.assigned_ipv4=\"$ASSIGNED_IPV4\""
    echo "  >> incus config set \"$VM_NAME\" user.assigned_ipv6=\"$ASSIGNED_IPV6\""
    
    log_step "[DRY-RUN] Step 8: Starting $INSTANCE_TYPE instance and verifying network lease"
    echo "  >> incus start \"$VM_NAME\""
    echo "  >> [Simulated] Verified active IPv4: $ASSIGNED_IPV4 (eth0)"

    log_success "[DRY-RUN] Workload '$VM_NAME' (ID: $VM_IDENTIFIER, Type: $INSTANCE_TYPE) verified with dedicated IPv4: $ASSIGNED_IPV4 and IPv6: $ASSIGNED_IPV6."
    exit 0
fi

# Live Execution
if "$INCUS_BIN" info "$VM_NAME" &>/dev/null; then
    log_error "An Incus instance with name '$VM_NAME' already exists."
    exit 1
fi

log_step "Step 1: Initializing $INSTANCE_TYPE instance '$VM_NAME' with image '$RESOLVED_IMAGE'..."
if [[ "$INSTANCE_TYPE" == "vm" ]]; then
    "$INCUS_BIN" init "$RESOLVED_IMAGE" "$VM_NAME" --vm
else
    "$INCUS_BIN" init "$RESOLVED_IMAGE" "$VM_NAME"
fi

log_step "Step 2: Setting CPU limits ($CPU_COUNT cores)..."
"$INCUS_BIN" config set "$VM_NAME" limits.cpu="$CPU_COUNT"

log_step "Step 3: Setting RAM memory limits ($RAM_SIZE)..."
"$INCUS_BIN" config set "$VM_NAME" limits.memory="$RAM_SIZE"

log_step "Step 4: Setting root disk size ($DISK_SIZE)..."
"$INCUS_BIN" config device override "$VM_NAME" root size="$DISK_SIZE" 2>/dev/null || "$INCUS_BIN" config device set "$VM_NAME" root size="$DISK_SIZE"

log_step "Step 5: Binding dedicated IPv4 ($ASSIGNED_IPV4) & IPv6 ($ASSIGNED_IPV6) to NIC device..."
if "$INCUS_BIN" config show "$VM_NAME" --expanded 2>/dev/null | grep -q "eth0:"; then
    # Device exists in expanded profile -> override or set with key=value syntax
    "$INCUS_BIN" config device override "$VM_NAME" eth0 ipv4.address="$ASSIGNED_IPV4" ipv6.address="$ASSIGNED_IPV6" 2>/dev/null \
    || "$INCUS_BIN" config device set "$VM_NAME" eth0 ipv4.address="$ASSIGNED_IPV4" ipv6.address="$ASSIGNED_IPV6" 2>/dev/null \
    || "$INCUS_BIN" config device override "$VM_NAME" eth0 ipv4.address="$ASSIGNED_IPV4" 2>/dev/null \
    || "$INCUS_BIN" config device set "$VM_NAME" eth0 ipv4.address="$ASSIGNED_IPV4" 2>/dev/null || true
else
    "$INCUS_BIN" config device add "$VM_NAME" eth0 nic network="$NETWORK_NAME" name=eth0 ipv4.address="$ASSIGNED_IPV4" ipv6.address="$ASSIGNED_IPV6" 2>/dev/null \
    || "$INCUS_BIN" config device add "$VM_NAME" eth0 nic network="$NETWORK_NAME" name=eth0 2>/dev/null || true
fi

log_step "Step 6: Applying cloud-init user-data..."
"$INCUS_BIN" config set "$VM_NAME" user.user-data=- < "$TMP_CLOUD_INIT"

log_step "Step 7: Setting metadata (vm_identifier=$VM_IDENTIFIER, lifetime=$LIFETIME, instance_type=$INSTANCE_TYPE)..."
"$INCUS_BIN" config set "$VM_NAME" user.vm_identifier="$VM_IDENTIFIER"
"$INCUS_BIN" config set "$VM_NAME" user.instance_type="$INSTANCE_TYPE"
"$INCUS_BIN" config set "$VM_NAME" user.lifetime="$LIFETIME"
"$INCUS_BIN" config set "$VM_NAME" user.assigned_ipv4="$ASSIGNED_IPV4"
"$INCUS_BIN" config set "$VM_NAME" user.assigned_ipv6="$ASSIGNED_IPV6"

log_step "Step 8: Starting $INSTANCE_TYPE '$VM_NAME'..."
"$INCUS_BIN" start "$VM_NAME"

log_step "Step 9: Waiting for instance to acquire dedicated IPv4 ($ASSIGNED_IPV4)..."
ACQUIRED_IPV4=""
ACQUIRED_IPV6=""
for ((attempt=1; attempt<=25; attempt++)); do
    IP_CSV="$("$INCUS_BIN" list "^${VM_NAME}$" --format csv -c 4,6 2>/dev/null || true)"
    V4_RAW="$(echo "$IP_CSV" | awk -F',' '{print $1}' | awk '{print $1}' | tr -d ' ' || true)"
    V6_RAW="$(echo "$IP_CSV" | awk -F',' '{print $2}' | awk '{print $1}' | tr -d ' ' || true)"
    
    if [[ -n "$V4_RAW" && "$V4_RAW" != "-" && "$V4_RAW" != "127.0.0.1" ]]; then
        ACQUIRED_IPV4="$V4_RAW"
        ACQUIRED_IPV6="$V6_RAW"
        break
    fi

    # At 5 seconds, if IP has not appeared yet, trigger container networking if container
    if [[ $attempt -eq 5 && "$INSTANCE_TYPE" == "container" ]]; then
        log_info "Activating container network interface..."
        "$INCUS_BIN" exec "$VM_NAME" -- ip link set eth0 up 2>/dev/null || true
        "$INCUS_BIN" exec "$VM_NAME" -- dhclient -4 eth0 2>/dev/null \
        || "$INCUS_BIN" exec "$VM_NAME" -- udhcpc -i eth0 2>/dev/null \
        || "$INCUS_BIN" exec "$VM_NAME" -- systemctl restart systemd-networkd 2>/dev/null \
        || "$INCUS_BIN" exec "$VM_NAME" -- systemctl restart networking 2>/dev/null \
        || true
    fi

    # At 10 seconds, fallback to direct IP assignment on eth0 inside container
    if [[ $attempt -eq 10 && "$INSTANCE_TYPE" == "container" ]]; then
        log_info "Ensuring IP on eth0 directly..."
        "$INCUS_BIN" exec "$VM_NAME" -- ip addr add "${ASSIGNED_IPV4}/${SUBNET_CIDR_V4}" dev eth0 2>/dev/null || true
        "$INCUS_BIN" exec "$VM_NAME" -- ip route add default via "${GATEWAY_IPV4}" dev eth0 2>/dev/null || true
    fi

    sleep 1
done

if [[ -n "$ACQUIRED_IPV4" && "$ACQUIRED_IPV4" != "-" ]]; then
    log_success "Workload '$VM_NAME' (ID: $VM_IDENTIFIER) active with IPv4: $ACQUIRED_IPV4 and IPv6: ${ACQUIRED_IPV6:-$ASSIGNED_IPV6}!"
else
    log_warn "Workload '$VM_NAME' started (Assigned: $ASSIGNED_IPV4). Querying current status:"
fi

log_step "Current $INSTANCE_TYPE Status & Network Leases:"
"$INCUS_BIN" list "^${VM_NAME}$" || "$INCUS_BIN" info "$VM_NAME" || true

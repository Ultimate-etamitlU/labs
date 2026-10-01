#!/bin/bash
set -euo pipefail

# =============================================================================
# OpenShift IPI Bare-Metal Deployment Script (KVM/libvirt + VBMC)
#
# Deploys a 3-master + 2-worker IPI cluster using VMs that simulate
# bare-metal servers via VirtualBMC (IPMI). The installer manages bootstrap,
# PXE provisioning (ironic), and load balancing (keepalived) automatically.
#
# Usage: ./ocp-ipi-deploy.sh <ocp_version> [cluster_name] [ip_offset] [network_type]
#   ocp_version  - e.g. 4.17.0
#   cluster_name - optional, defaults to "ipi1"
#   ip_offset    - optional, defaults to 140
#                  API VIP = .offset, Ingress VIP = .offset+1, masters = .offset+2..4, workers = .offset+5..6
#   network_type - optional, OVNKubernetes (default) or OpenShiftSDN (4.14 and below)
#
# Prerequisites:
#   - VirtualBMC daemon running (vbmcd)
#   - libvirt "default" network (baremetal); the slot-scoped PXE network is
#     created and validated automatically
#   - Pull secret at /root/pull-secret.txt
#   - SSH key at /etc/labusers/id_ed25519.pub
# =============================================================================

# --- CONFIGURATION ---

if [ -f /etc/ocp-lab.conf ]; then
    # shellcheck source=/dev/null
    source /etc/ocp-lab.conf
fi

BASE_DOMAIN="${BASE_DOMAIN:-example.com}"
STORAGE_DIR="${STORAGE_DIR:-/kvm}"

VERSION="${1:-}"
CLUSTER_NAME="${2:-ipi1}"
IP_OFFSET="${3:-${IP_OFFSET:-140}}"
NETWORK_TYPE="${4:-OVNKubernetes}"

if [ -z "$VERSION" ]; then
    echo "Usage: $0 <ocp_version> [cluster_name] [ip_offset] [network_type]"
    echo "  cluster_name defaults to 'ipi1' if omitted"
    echo "  ip_offset defaults to 140 (VIPs at .140/.141, masters .142-.144)"
    echo "  network_type defaults to OVNKubernetes (use OpenShiftSDN for 4.14 and below)"
    exit 1
fi

case "$VERSION" in
    4.*) MIRROR_CHANNEL="openshift-v4" ;;
    5.*) MIRROR_CHANNEL="openshift-v5" ;;
    *)
        echo "Unsupported OCP version '$VERSION'. Supported major versions: 4.x and 5.x."
        exit 1
        ;;
esac

BASE_DIR="$STORAGE_DIR/client_tools/$VERSION"
INSTALL_DIR="$STORAGE_DIR/clusters/${CLUSTER_NAME}-${VERSION}"
MIRROR_URL="https://mirror.openshift.com/pub/${MIRROR_CHANNEL}/clients/ocp/$VERSION"

# Networking — every IPI slot gets its own provisioning L2 context.  The
# portal writes the authoritative mapping to /etc/ocp-lab.conf; the fallback
# keeps direct invocation usable before that file has been regenerated.
BM_BRIDGE="virbr0"
PROV_NETWORK_NAME=""
PROV_BRIDGE=""
PROV_NET_CIDR=""
PROV_BRIDGE_IP=""

select_ipi_provisioning_network() {
    local entry slot network bridge cidr gateway
    for entry in ${IPI_PROVISIONING_NETWORKS:-}; do
        IFS=: read -r slot network bridge cidr gateway <<< "$entry"
        if [[ "$slot" == "$CLUSTER_NAME" ]]; then
            PROV_NETWORK_NAME="$network"
            PROV_BRIDGE="$bridge"
            PROV_NET_CIDR="$cidr"
            PROV_BRIDGE_IP="$gateway"
            break
        fi
    done

    if [[ -z "$PROV_NETWORK_NAME" ]]; then
        case "$CLUSTER_NAME" in
            ipi1) PROV_NETWORK_NAME="provisioning-ipi1"; PROV_BRIDGE="prov-ipi1"; PROV_NET_CIDR="192.168.10.0/24"; PROV_BRIDGE_IP="192.168.10.1" ;;
            ipi2) PROV_NETWORK_NAME="provisioning-ipi2"; PROV_BRIDGE="prov-ipi2"; PROV_NET_CIDR="192.168.11.0/24"; PROV_BRIDGE_IP="192.168.11.1" ;;
            ipi3) PROV_NETWORK_NAME="provisioning-ipi3"; PROV_BRIDGE="prov-ipi3"; PROV_NET_CIDR="192.168.12.0/24"; PROV_BRIDGE_IP="192.168.12.1" ;;
            *)
                echo "FAIL: no isolated provisioning network is configured for IPI slot '$CLUSTER_NAME'."
                echo "      Add the slot to IPI_PROVISIONING_NETWORKS in /etc/ocp-lab.conf."
                exit 1
                ;;
        esac
    fi
}

select_ipi_provisioning_network

ensure_provisioning_network() {
    local xml_file xml
    if virsh net-info "$PROV_NETWORK_NAME" &>/dev/null; then
        xml=$(virsh net-dumpxml "$PROV_NETWORK_NAME")
        if ! grep -Eq "<bridge name=['\"]${PROV_BRIDGE}['\"]" <<< "$xml" || \
           ! grep -Eq "<ip address=['\"]${PROV_BRIDGE_IP}['\"]" <<< "$xml"; then
            echo "FAIL: libvirt network '$PROV_NETWORK_NAME' does not match the expected isolated IPI context."
            echo "      Expected bridge=$PROV_BRIDGE gateway=$PROV_BRIDGE_IP"
            return 1
        fi
        if [[ "$(virsh net-info "$PROV_NETWORK_NAME" | awk '/^Active:/{print $2}')" != "yes" ]]; then
            virsh net-start "$PROV_NETWORK_NAME"
        fi
        virsh net-autostart "$PROV_NETWORK_NAME" >/dev/null
        return 0
    fi

    xml_file=$(mktemp "/tmp/${PROV_NETWORK_NAME}.XXXXXX.xml")
    cat > "$xml_file" <<_PROVISIONING_NETWORK_
<network>
  <name>${PROV_NETWORK_NAME}</name>
  <bridge name='${PROV_BRIDGE}' stp='off' delay='0'/>
  <ip address='${PROV_BRIDGE_IP}' netmask='255.255.255.0'/>
</network>
_PROVISIONING_NETWORK_
    if ! virsh net-define "$xml_file" >/dev/null; then
        rm -f "$xml_file"
        return 1
    fi
    rm -f "$xml_file"
    virsh net-start "$PROV_NETWORK_NAME"
    virsh net-autostart "$PROV_NETWORK_NAME" >/dev/null
    echo "Created isolated provisioning network $PROV_NETWORK_NAME ($PROV_NET_CIDR, bridge $PROV_BRIDGE)."
}

# VIPs — managed by keepalived on the cluster nodes (no HAProxy needed)
API_VIP="192.168.122.${IP_OFFSET}"
INGRESS_VIP="192.168.122.$(( IP_OFFSET + 1 ))"

# MAC address scheme: 52:54:00:<HEX_OFFSET>:01:XX
# Uses :01: in 4th octet to avoid collision with UPI's :00:
MAC_BASE=$(printf "%02x" "$IP_OFFSET")

# VBMC port scheme: 6200 + (IP_OFFSET - 100)
VBMC_PORT_BASE=$(( 6200 + IP_OFFSET - 100 ))
VBMC_USER="admin"
VBMC_PASS="password"

# Per-cluster VM name prefix
VM_PREFIX="vm-${CLUSTER_NAME}"

# Node count
NUM_MASTERS=3
NUM_WORKERS=2

# OpenShift bare-metal minimums (OCP 4.20/4.21 documentation).  The IPI
# bootstrap VM is temporary but is included in the pre-flight peak footprint.
BOOTSTRAP_VCPUS=4
BOOTSTRAP_RAM_MB=16384
CONTROL_PLANE_VCPUS=4
CONTROL_PLANE_RAM_MB=16384
WORKER_VCPUS=2
WORKER_RAM_MB=8192

# Pull secret and SSH key
PULL_SECRET_FILE="${PULL_SECRET_FILE:-/root/pull-secret.txt}"
SSH_KEY_FILE="${SSH_KEY_FILE:-/etc/labusers/id_ed25519.pub}"


# --- CLEANUP FUNCTION ---
cleanup_ipi() {
    local cluster="$1"
    local prefix="vm-${cluster}"
    echo ""
    echo "Cleaning up IPI cluster: $cluster"

    # Destroy and undefine VMs
    for i in $(seq 0 $(( NUM_MASTERS - 1 ))); do
        local vm="${prefix}-master-${i}"
        virsh destroy "$vm" 2>/dev/null || true
        virsh undefine "$vm" --remove-all-storage 2>/dev/null || true
    done
    for i in $(seq 0 $(( NUM_WORKERS - 1 ))); do
        local vm="${prefix}-worker-${i}"
        virsh destroy "$vm" 2>/dev/null || true
        virsh undefine "$vm" --remove-all-storage 2>/dev/null || true
    done
    # IPI may create a bootstrap VM
    virsh destroy "${prefix}-bootstrap" 2>/dev/null || true
    virsh undefine "${prefix}-bootstrap" --remove-all-storage 2>/dev/null || true

    # Stop and delete VBMC entries
    for i in $(seq 0 $(( NUM_MASTERS - 1 ))); do
        local vm="${prefix}-master-${i}"
        vbmc stop "$vm" 2>/dev/null || true
        vbmc delete "$vm" 2>/dev/null || true
    done
    for i in $(seq 0 $(( NUM_WORKERS - 1 ))); do
        local vm="${prefix}-worker-${i}"
        vbmc stop "$vm" 2>/dev/null || true
        vbmc delete "$vm" 2>/dev/null || true
    done

    # Remove DHCP reservations (masters)
    for i in $(seq 0 $(( NUM_MASTERS - 1 ))); do
        local bm_mac
        bm_mac="52:54:00:${MAC_BASE}:01:$(printf '%02x' $(( 0x11 + i )))"
        virsh net-update default delete ip-dhcp-host \
            "<host mac='$bm_mac'/>" \
            --live --config 2>/dev/null || true
    done
    # Remove DHCP reservations (workers)
    for i in $(seq 0 $(( NUM_WORKERS - 1 ))); do
        local bm_mac
        bm_mac="52:54:00:${MAC_BASE}:01:$(printf '%02x' $(( 0x21 + i )))"
        virsh net-update default delete ip-dhcp-host \
            "<host mac='$bm_mac'/>" \
            --live --config 2>/dev/null || true
    done

    echo "Cleanup complete for $cluster."
}


# --- TRAP ---
trap 'echo ""; echo "Caught signal — aborting."' INT TERM

# --- PRE-FLIGHT CHECKS ---
echo "=== Pre-flight checks ==="

preflight_ok=true

# Required commands
for cmd in virsh virt-install vbmc ipmitool curl python3 flock; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "FAIL: '$cmd' is not installed."
        preflight_ok=false
    fi
done

# Pull secret
if [ ! -f "$PULL_SECRET_FILE" ]; then
    echo "FAIL: Pull secret not found at $PULL_SECRET_FILE"
    preflight_ok=false
fi

# SSH key
if [ ! -f "$SSH_KEY_FILE" ]; then
    echo "FAIL: SSH public key not found at $SSH_KEY_FILE"
    preflight_ok=false
fi

# VBMC daemon
if ! systemctl is-active vbmcd &>/dev/null; then
    echo "FAIL: vbmcd service is not running. Start with: systemctl start vbmcd"
    preflight_ok=false
fi

# libvirt default network
if ! virsh net-info default &>/dev/null; then
    echo "FAIL: libvirt 'default' network does not exist."
    preflight_ok=false
fi

# Create or validate this slot's isolated provisioning network.  The legacy
# shared "provisioning" network is intentionally left untouched for existing
# clusters; new installs never attach to it.
if command -v virsh &>/dev/null; then
    if ! ensure_provisioning_network; then
        preflight_ok=false
    fi
fi

# Check for existing VMs with this prefix
for i in $(seq 0 $(( NUM_MASTERS - 1 ))); do
    if virsh dominfo "${VM_PREFIX}-master-${i}" &>/dev/null; then
        echo "FAIL: VM '${VM_PREFIX}-master-${i}' already exists. Delete it first or use a different cluster name."
        preflight_ok=false
    fi
done
for i in $(seq 0 $(( NUM_WORKERS - 1 ))); do
    if virsh dominfo "${VM_PREFIX}-worker-${i}" &>/dev/null; then
        echo "FAIL: VM '${VM_PREFIX}-worker-${i}' already exists. Delete it first or use a different cluster name."
        preflight_ok=false
    fi
done

# Check VBMC ports are free
TOTAL_NODES=$(( NUM_MASTERS + NUM_WORKERS ))
for i in $(seq 0 $(( TOTAL_NODES - 1 ))); do
    local_port=$(( VBMC_PORT_BASE + i ))
    if vbmc list 2>/dev/null | grep -q ":.*${local_port}"; then
        echo "FAIL: VBMC port $local_port already in use."
        preflight_ok=false
    fi
done

# CPU/RAM check — include the temporary bootstrap VM in the peak footprint.
HOST_VCPUS=$(nproc)
REQUIRED_VCPUS=$(( BOOTSTRAP_VCPUS + NUM_MASTERS * CONTROL_PLANE_VCPUS + NUM_WORKERS * WORKER_VCPUS ))
if [ "$HOST_VCPUS" -lt "$REQUIRED_VCPUS" ]; then
    echo "WARN: Host exposes ${HOST_VCPUS} CPUs, IPI peak needs ~${REQUIRED_VCPUS} vCPUs."
    echo "      Deployment may fail or be very slow due to CPU contention."
fi

AVAIL_RAM_KB=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
AVAIL_RAM_GB=$(( AVAIL_RAM_KB / 1024 / 1024 ))
REQUIRED_RAM_GB=$(( (BOOTSTRAP_RAM_MB + NUM_MASTERS * CONTROL_PLANE_RAM_MB + NUM_WORKERS * WORKER_RAM_MB) / 1024 ))
if [ "$AVAIL_RAM_GB" -lt "$REQUIRED_RAM_GB" ]; then
    echo "WARN: Only ${AVAIL_RAM_GB} GB RAM available, IPI peak needs ~${REQUIRED_RAM_GB} GB."
    echo "      Deployment may fail or be very slow."
fi

# os-variant
if command -v osinfo-query &>/dev/null && osinfo-query os | grep -q 'rhel9.0'; then
    OS_VARIANT="rhel9.0"
else
    OS_VARIANT="rhel9-unknown"
fi

if [ "$preflight_ok" = false ]; then
    echo ""
    echo "Pre-flight checks FAILED. Fix the issues above and re-run."
    exit 1
fi

# Ensure VBMC UDP ports are open in the libvirt firewall zone when firewalld
# is in use.  Some lab hosts intentionally run without firewalld; in that
# case firewall-cmd returns 252 and must not abort an otherwise valid deploy.
VBMC_PORT_RANGE="${VBMC_PORT_BASE}-$(( VBMC_PORT_BASE + TOTAL_NODES - 1 ))/udp"
if ! systemctl is-active --quiet firewalld 2>/dev/null; then
    echo "WARN: firewalld is inactive; skipping firewall rule for VBMC ports ${VBMC_PORT_RANGE}."
elif ! command -v firewall-cmd &>/dev/null; then
    echo "FAIL: firewalld is active but firewall-cmd is not available."
    exit 1
else
    if ! firewall-cmd --zone=libvirt --query-port="$VBMC_PORT_RANGE" &>/dev/null; then
        if ! firewall-cmd --zone=libvirt --add-port="$VBMC_PORT_RANGE" --permanent &>/dev/null; then
            echo "FAIL: unable to configure libvirt firewall port ${VBMC_PORT_RANGE}."
            exit 1
        fi
    fi
    if ! firewall-cmd --zone=libvirt --add-port="$VBMC_PORT_RANGE" &>/dev/null; then
        echo "FAIL: unable to activate libvirt firewall port ${VBMC_PORT_RANGE}."
        exit 1
    fi
fi

echo "=== Pre-flight checks passed ==="
echo ""
echo "Cluster:       $CLUSTER_NAME"
echo "OCP Version:   $VERSION"
echo "API VIP:       $API_VIP"
echo "Ingress VIP:   $INGRESS_VIP"
echo "Provisioning:  $PROV_NETWORK_NAME ($PROV_NET_CIDR, bridge $PROV_BRIDGE)"
echo "Masters:       192.168.122.$(( IP_OFFSET + 2 )) - 192.168.122.$(( IP_OFFSET + 4 ))"
echo "Workers:       192.168.122.$(( IP_OFFSET + 5 )) - 192.168.122.$(( IP_OFFSET + 4 + NUM_WORKERS ))"
echo "VBMC ports:    $VBMC_PORT_BASE - $(( VBMC_PORT_BASE + TOTAL_NODES - 1 ))"
echo ""

TOOL_BIN_DIR="$BASE_DIR/bin"
mkdir -p "$BASE_DIR" "$TOOL_BIN_DIR" "$INSTALL_DIR"

# --- 1. TOOLS MANAGEMENT ---
install_binary() {
    local binary=$1
    cp "$BASE_DIR/$binary" "$TOOL_BIN_DIR/${binary}.tmp.$$"
    chmod 0755 "$TOOL_BIN_DIR/${binary}.tmp.$$"
    mv "$TOOL_BIN_DIR/${binary}.tmp.$$" "$TOOL_BIN_DIR/$binary"
}

check_and_get_tool() {
    local tool=$1; local binary=$2

    if [[ -f "$TOOL_BIN_DIR/$binary" ]] && [[ "$("$TOOL_BIN_DIR/$binary" version 2>/dev/null)" == *"$VERSION"* ]]; then
        echo "$binary $VERSION is already active."
        return
    fi

    if [[ -f "$BASE_DIR/$binary" ]]; then
        echo "$binary found in cache ($BASE_DIR), installing..."
        install_binary "$binary"
        if [[ "$binary" == "oc" ]] && [[ -f "$BASE_DIR/kubectl" ]]; then
            install_binary "kubectl"
        fi
        return
    fi

    echo "Downloading $tool..."
    curl --fail -SL "$MIRROR_URL/${tool}-linux.tar.gz" -o "$BASE_DIR/${tool}.tar.gz"

    local sha_file="$BASE_DIR/${tool}-sha256.txt"
    if curl --fail -sSL "$MIRROR_URL/sha256sum.txt" -o "$sha_file" 2>/dev/null; then
        local expected
        expected=$(grep "${tool}-linux" "$sha_file" | grep -v arm64 | grep -v ppc64 | grep -v s390x | head -1 | awk '{print $1}' || true)
        if [ -n "$expected" ]; then
            local actual
            actual=$(sha256sum "$BASE_DIR/${tool}.tar.gz" | awk '{print $1}')
            if [ "$expected" != "$actual" ]; then
                echo "FAIL: Checksum mismatch for ${tool}-linux.tar.gz"
                exit 1
            fi
            echo "Checksum verified for $tool."
        fi
    fi

    tar -xzf "$BASE_DIR/${tool}.tar.gz" -C "$BASE_DIR"
    rm -f "$BASE_DIR/${tool}.tar.gz" "$BASE_DIR/${tool}-sha256.txt"

    install_binary "$binary"
    if [[ "$binary" == "oc" ]] && [[ -f "$BASE_DIR/kubectl" ]]; then
        install_binary "kubectl"
    fi
}

exec 9>"$BASE_DIR/.tools.lock"
flock 9
check_and_get_tool "openshift-install" "openshift-install"
check_and_get_tool "openshift-client" "oc"
flock -u 9
OPENSHIFT_INSTALL="$TOOL_BIN_DIR/openshift-install"

# --- 2. CREATE EMPTY VMs ---
echo ""
echo "=== Creating empty VMs for IPI provisioning ==="

declare -a PROV_MACS=()
declare -a BM_MACS=()

for i in $(seq 0 $(( NUM_MASTERS - 1 ))); do
    vm_name="${VM_PREFIX}-master-${i}"
    prov_mac="52:54:00:${MAC_BASE}:01:$(printf '%02x' $(( 0x01 + i )))"
    bm_mac="52:54:00:${MAC_BASE}:01:$(printf '%02x' $(( 0x11 + i )))"
    master_ip="192.168.122.$(( IP_OFFSET + 2 + i ))"
    hostname="master-${i}.${CLUSTER_NAME}.${BASE_DOMAIN}"

    PROV_MACS+=("$prov_mac")
    BM_MACS+=("$bm_mac")

    # Clean up any stale VM with this name
    virsh destroy "$vm_name" 2>/dev/null || true
    virsh undefine "$vm_name" --remove-all-storage 2>/dev/null || true

    # Remove stale SSH host keys
    ssh-keygen -R "$master_ip" 2>/dev/null || true

    echo "Creating VM: $vm_name (prov=$prov_mac, bm=$bm_mac)"
    virt-install --name "$vm_name" \
        --ram "$CONTROL_PLANE_RAM_MB" \
        --vcpus "$CONTROL_PLANE_VCPUS" \
        --cpu host-passthrough \
        --disk size=120,bus=virtio \
        --network network="$PROV_NETWORK_NAME",mac="$prov_mac" \
        --network network=default,mac="$bm_mac" \
        --pxe \
        --boot network,hd \
        --graphics vnc,listen=127.0.0.1 \
        --video virtio \
        --noautoconsole \
        --os-variant "$OS_VARIANT" \
        --noreboot

    # Shut down the VM — virt-install --pxe starts it, but IPI needs them off
    # so the installer can power them on via IPMI/VBMC
    virsh destroy "$vm_name" 2>/dev/null || true

    echo "Adding DHCP reservation: $bm_mac -> $master_ip ($hostname)"
    virsh net-update default add ip-dhcp-host \
        "<host mac='$bm_mac' name='$hostname' ip='$master_ip'/>" \
        --live --config 2>/dev/null || true
done

# Worker VMs — smaller specs than masters
for i in $(seq 0 $(( NUM_WORKERS - 1 ))); do
    vm_name="${VM_PREFIX}-worker-${i}"
    prov_mac="52:54:00:${MAC_BASE}:01:$(printf '%02x' $(( 0x05 + i )))"
    bm_mac="52:54:00:${MAC_BASE}:01:$(printf '%02x' $(( 0x21 + i )))"
    worker_ip="192.168.122.$(( IP_OFFSET + 5 + i ))"
    hostname="worker-${i}.${CLUSTER_NAME}.${BASE_DOMAIN}"

    PROV_MACS+=("$prov_mac")
    BM_MACS+=("$bm_mac")

    virsh destroy "$vm_name" 2>/dev/null || true
    virsh undefine "$vm_name" --remove-all-storage 2>/dev/null || true
    ssh-keygen -R "$worker_ip" 2>/dev/null || true

    echo "Creating VM: $vm_name (prov=$prov_mac, bm=$bm_mac)"
    virt-install --name "$vm_name" \
        --ram "$WORKER_RAM_MB" \
        --vcpus "$WORKER_VCPUS" \
        --cpu host-passthrough \
        --disk size=120,bus=virtio \
        --network network="$PROV_NETWORK_NAME",mac="$prov_mac" \
        --network network=default,mac="$bm_mac" \
        --pxe \
        --boot network,hd \
        --graphics vnc,listen=127.0.0.1 \
        --video virtio \
        --noautoconsole \
        --os-variant "$OS_VARIANT" \
        --noreboot

    virsh destroy "$vm_name" 2>/dev/null || true

    echo "Adding DHCP reservation: $bm_mac -> $worker_ip ($hostname)"
    virsh net-update default add ip-dhcp-host \
        "<host mac='$bm_mac' name='$hostname' ip='$worker_ip'/>" \
        --live --config 2>/dev/null || true
done

echo "VMs created successfully."

# --- 3. VBMC SETUP ---
echo ""
echo "=== Setting up VirtualBMC entries ==="

for i in $(seq 0 $(( NUM_MASTERS - 1 ))); do
    vm_name="${VM_PREFIX}-master-${i}"
    vbmc_port=$(( VBMC_PORT_BASE + i ))

    # Clean up any stale entry
    vbmc stop "$vm_name" 2>/dev/null || true
    vbmc delete "$vm_name" 2>/dev/null || true

    echo "Creating VBMC: $vm_name on port $vbmc_port"
    vbmc add "$vm_name" \
        --port "$vbmc_port" \
        --address "$PROV_BRIDGE_IP" \
        --username "$VBMC_USER" \
        --password "$VBMC_PASS"

    vbmc start "$vm_name"
done

for i in $(seq 0 $(( NUM_WORKERS - 1 ))); do
    vm_name="${VM_PREFIX}-worker-${i}"
    vbmc_port=$(( VBMC_PORT_BASE + NUM_MASTERS + i ))

    vbmc stop "$vm_name" 2>/dev/null || true
    vbmc delete "$vm_name" 2>/dev/null || true

    echo "Creating VBMC: $vm_name on port $vbmc_port"
    vbmc add "$vm_name" \
        --port "$vbmc_port" \
        --address "$PROV_BRIDGE_IP" \
        --username "$VBMC_USER" \
        --password "$VBMC_PASS"

    vbmc start "$vm_name"
done

# Verify VBMC is responding
echo ""
echo "Verifying VBMC connectivity..."
for i in $(seq 0 $(( TOTAL_NODES - 1 ))); do
    vbmc_port=$(( VBMC_PORT_BASE + i ))
    if [ "$i" -lt "$NUM_MASTERS" ]; then
        vm_name="${VM_PREFIX}-master-${i}"
    else
        vm_name="${VM_PREFIX}-worker-$(( i - NUM_MASTERS ))"
    fi
    status=$(ipmitool -I lanplus -H "$PROV_BRIDGE_IP" -p "$vbmc_port" \
        -U "$VBMC_USER" -P "$VBMC_PASS" power status 2>&1 || true)
    if echo "$status" | grep -qi "off\|on"; then
        echo "  $vm_name (port $vbmc_port): OK — $status"
    else
        echo "  FAIL: $vm_name (port $vbmc_port) — VBMC not responding: $status"
        echo "  Aborting. Check vbmcd and firewall."
        exit 1
    fi
done

# --- 4. DNS RECORDS (static) ---
echo ""
echo "=== Verifying DNS records ==="
# DNS is static in forward.example.com — slots ipi1/ipi2/ipi3 pre-configured.
for record in "api.${CLUSTER_NAME}.${BASE_DOMAIN}" "*.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"; do
    resolved=$(dig +short "$record" @127.0.0.1 2>/dev/null || true)
    if [ -n "$resolved" ]; then
        echo "  $record -> $resolved"
    else
        echo "  ERROR: $record did not resolve — check /var/named/forward.example.com"
        exit 1
    fi
done

# --- 5. INSTALL-CONFIG ---
echo ""
echo "=== Generating install-config.yaml ==="
cd "$INSTALL_DIR"

PULL_SECRET=$(cat "$PULL_SECRET_FILE")
SSH_KEY=$(cat "$SSH_KEY_FILE")

# Build hosts YAML block
HOSTS_YAML=""
for i in $(seq 0 $(( NUM_MASTERS - 1 ))); do
    vbmc_port=$(( VBMC_PORT_BASE + i ))
    prov_mac="${PROV_MACS[$i]}"
    HOSTS_YAML+="    - name: master-${i}
      role: master
      bmc:
        address: ipmi://${PROV_BRIDGE_IP}:${vbmc_port}
        username: ${VBMC_USER}
        password: ${VBMC_PASS}
      bootMACAddress: ${prov_mac}
      rootDeviceHints:
        deviceName: /dev/vda
"
done
for i in $(seq 0 $(( NUM_WORKERS - 1 ))); do
    vbmc_port=$(( VBMC_PORT_BASE + NUM_MASTERS + i ))
    prov_mac="${PROV_MACS[$(( NUM_MASTERS + i ))]}"
    HOSTS_YAML+="    - name: worker-${i}
      role: worker
      bmc:
        address: ipmi://${PROV_BRIDGE_IP}:${vbmc_port}
        username: ${VBMC_USER}
        password: ${VBMC_PASS}
      bootMACAddress: ${prov_mac}
      rootDeviceHints:
        deviceName: /dev/vda
"
done

cat > install-config.yaml <<_INSTALL_CONFIG_
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
networking:
  networkType: ${NETWORK_TYPE}
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  serviceNetwork:
  - 172.30.0.0/16
  machineNetwork:
  - cidr: 192.168.122.0/24
compute:
- name: worker
  replicas: ${NUM_WORKERS}
controlPlane:
  name: master
  replicas: ${NUM_MASTERS}
  platform:
    baremetal: {}
platform:
  baremetal:
    apiVIPs:
    - ${API_VIP}
    ingressVIPs:
    - ${INGRESS_VIP}
    provisioningNetworkCIDR: ${PROV_NET_CIDR}
    provisioningBridge: ${PROV_BRIDGE}
    externalBridge: ${BM_BRIDGE}
    hosts:
${HOSTS_YAML}
pullSecret: '${PULL_SECRET}'
sshKey: '${SSH_KEY}'
_INSTALL_CONFIG_

cp -f install-config.yaml install-config.yaml_backup
echo "install-config.yaml created."

# --- 6. RUN INSTALLER ---
echo ""
echo "=== Starting IPI installation ==="
echo "This will take approximately 45-60 minutes."
echo "The installer will:"
echo "  1. Create a bootstrap VM and PXE boot the masters via ironic"
echo "  2. Install RHCOS on the masters"
echo "  3. Bootstrap the cluster"
echo "  4. Tear down the bootstrap VM"
echo ""

# Ensure the external bridge (virbr0) is UP — the installer rejects DOWN bridges.
# Start a VM to bring the bridge carrier up; the installer will power-manage
# all VMs via IPMI/VBMC so this is safe.
if [ "$(cat /sys/class/net/${BM_BRIDGE}/operstate 2>/dev/null)" != "up" ]; then
    echo "Bringing up ${BM_BRIDGE} by starting a VM..."
    virsh start "${VM_PREFIX}-master-0" 2>/dev/null || true
    for _w in $(seq 1 5); do
        [ "$(cat /sys/class/net/${BM_BRIDGE}/operstate 2>/dev/null)" = "up" ] && break
        sleep 1
    done
    echo "${BM_BRIDGE} operstate: $(cat /sys/class/net/${BM_BRIDGE}/operstate 2>/dev/null)"
fi

# The per-slot provisioning bridge also needs carrier before the installer
# validates provisioningBridge.  It is otherwise DOWN when all slot VMs are
# powered off, even though the libvirt network itself is active.
ip link set "$PROV_BRIDGE" up 2>/dev/null || true
if [ "$(cat /sys/class/net/${PROV_BRIDGE}/operstate 2>/dev/null)" != "up" ]; then
    echo "Bringing up ${PROV_BRIDGE} by starting a VM..."
    virsh start "${VM_PREFIX}-master-0" 2>/dev/null || true
    for _w in $(seq 1 5); do
        [ "$(cat /sys/class/net/${PROV_BRIDGE}/operstate 2>/dev/null)" = "up" ] && break
        sleep 1
    done
    echo "${PROV_BRIDGE} operstate: $(cat /sys/class/net/${PROV_BRIDGE}/operstate 2>/dev/null)"
fi
if [ "$(cat /sys/class/net/${PROV_BRIDGE}/operstate 2>/dev/null)" != "up" ]; then
    echo "FAIL: provisioning bridge ${PROV_BRIDGE} is not up."
    exit 1
fi

"$OPENSHIFT_INSTALL" create cluster --dir=. --log-level=info

# Fix qcow2 disk image ownership created by Ironic during provisioning.
# Ironic creates disks as root:root, but libvirt needs qemu:qemu access.
echo ""
echo "=== Fixing disk ownership (created by Ironic) ==="
for disk in "$STORAGE_DIR"/kvm_images/"${VM_PREFIX}"-*.qcow2; do
    [ -f "$disk" ] && chown qemu:qemu "$disk" && chmod 600 "$disk" && echo "Fixed: $disk"
done

# --- 7. POST-INSTALL ---
export KUBECONFIG="$INSTALL_DIR/auth/kubeconfig"

# Grant labusers group read-write access to cluster files (kubeconfig, etc.)
if getent group labusers &>/dev/null; then
    setfacl -R -m g:labusers:rwX -m m::rwx "$INSTALL_DIR"
    setfacl -R -d -m g:labusers:rwX -m m::rwx "$INSTALL_DIR"
fi

# Update MOTD
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -x "$SCRIPT_DIR/update-motd.sh" ]; then
    "$SCRIPT_DIR/update-motd.sh"
else
    echo "WARN: update-motd.sh not found — MOTD not updated."
fi

KUBE_PASS=$(cat "$INSTALL_DIR/auth/kubeadmin-password" 2>/dev/null || echo "UNKNOWN")
CONSOLE="console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"
echo ""
echo "==========================================="
echo "  IPI Cluster ${CLUSTER_NAME} (OCP ${VERSION}) is ready!"
echo "  Type:       ${NUM_MASTERS} masters + ${NUM_WORKERS} workers (IPI Baremetal)"
echo "  Console:    https://$CONSOLE"
echo "  Username:   kubeadmin"
echo "  Password:   $KUBE_PASS"
echo "  KUBECONFIG: export KUBECONFIG=$INSTALL_DIR/auth/kubeconfig"
echo "  API VIP:    $API_VIP"
echo "  Ingress:    $INGRESS_VIP"
echo "==========================================="

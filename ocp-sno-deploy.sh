#!/bin/bash
set -euo pipefail

# =============================================================================
# OpenShift SNO (Single Node) Deployment Script
#
# Runs on BigB (portal host), orchestrates SNO deployment on a remote machine
# via SSH. Tools download and ISO creation happen ON the remote machine —
# no large file transfers across datacenters.
#
# Usage: ./ocp-sno-deploy.sh <version> <cluster_name> <target_host> [install_method]
#
#   version        - OCP version (e.g. 4.17.5)
#   cluster_name   - Slot name (sno1 or sno2)
#   target_host    - Remote machine hostname/IP
#   install_method - agent-none (default), agent-external, upi-bip
#
# Environment:
#   SSH_USER         - Remote SSH user (default: root)
#   SSH_PORT         - Remote SSH port (default: 22)
#   PULL_SECRET_FILE - Path to pull secret (default: /root/pull-secret.txt)
#   SSH_KEY_FILE     - Path to SSH public key (default: ~/.ssh/id_ed25519.pub)
# =============================================================================

# --- Load site config ---
if [ -f /etc/ocp-lab.conf ]; then
    # shellcheck source=/dev/null
    source /etc/ocp-lab.conf
fi

BASE_DOMAIN="${BASE_DOMAIN:-example.com}"
STORAGE_DIR="${STORAGE_DIR:-/kvm}"

VERSION="${1:-}"
CLUSTER_NAME="${2:-}"
TARGET_HOST="${3:-}"
INSTALL_METHOD="${4:-agent-none}"

SSH_USER="${SSH_USER:-root}"
SSH_PORT="${SSH_PORT:-22}"
PULL_SECRET_FILE="${PULL_SECRET_FILE:-/root/pull-secret.txt}"
SSH_KEY_FILE="${SSH_KEY_FILE:-$HOME/.ssh/id_ed25519.pub}"

if [ -z "$VERSION" ] || [ -z "$CLUSTER_NAME" ] || [ -z "$TARGET_HOST" ]; then
    echo "Usage: $0 <version> <cluster_name> <target_host> [install_method]"
    echo ""
    echo "  install_method: agent-none (default), agent-external, upi-bip"
    echo "  cluster_name:   sno1 or sno2"
    exit 1
fi

# --- SNO slot definitions ---
SNO_SUBNET="192.168.200"
BRIDGE_IP="${SNO_SUBNET}.1"
NETWORK_NAME="sno"

declare -A SNO_SLOTS=(
    [sno1]="10"
    [sno2]="20"
)
declare -A SNO_MACS=(
    [sno1]="52:54:00:c8:00:10"
    [sno2]="52:54:00:c8:00:20"
)

# VM sizing
SNO_VCPUS=8
SNO_RAM_MB=32768
SNO_DISK_GB=120

# Derived values
IP_SUFFIX="${SNO_SLOTS[$CLUSTER_NAME]:-}"
if [ -z "$IP_SUFFIX" ]; then
    echo "FATAL: Unknown cluster name '${CLUSTER_NAME}'. Valid: ${!SNO_SLOTS[*]}"
    exit 1
fi
NODE_IP="${SNO_SUBNET}.${IP_SUFFIX}"
NODE_MAC="${SNO_MACS[$CLUSTER_NAME]}"
VM_NAME="vm-${CLUSTER_NAME}-master-0"

MIRROR_URL="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/$VERSION"
REMOTE_CLUSTERS_DIR="/kvm/clusters"
REMOTE_IMAGES_DIR="/kvm/images"
REMOTE_TOOLS_DIR="/kvm/client_tools/$VERSION"
REMOTE_INSTALL_DIR="${REMOTE_CLUSTERS_DIR}/${CLUSTER_NAME}-${VERSION}"

# Local install dir (for kubeconfig copy-back)
LOCAL_INSTALL_DIR="$STORAGE_DIR/clusters/${CLUSTER_NAME}-${VERSION}"

SSH_CMD="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -p ${SSH_PORT} ${SSH_USER}@${TARGET_HOST}"
SCP_CMD="scp -o StrictHostKeyChecking=no -P ${SSH_PORT}"

ts() { date "+%H:%M:%S"; }
log() { echo "[$(ts)] $*"; }
die() { echo "[$(ts)] FATAL: $*" >&2; exit 1; }

# --- Cleanup trap ---
cleanup() {
    local rc=$?
    if [ $rc -ne 0 ]; then
        log ""
        log "Deployment failed (exit code $rc). Partial resources may exist."
        log "To clean up: destroy VM '$VM_NAME' on $TARGET_HOST and remove $REMOTE_INSTALL_DIR"
    fi
}
trap cleanup EXIT

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================
log "=== SNO Deployment ==="
log "Version:    $VERSION"
log "Cluster:    $CLUSTER_NAME"
log "Target:     ${SSH_USER}@${TARGET_HOST}"
log "Method:     $INSTALL_METHOD"
log "Node IP:    $NODE_IP"
log "VM:         $VM_NAME (${SNO_VCPUS} vCPUs, $((SNO_RAM_MB / 1024)) GB RAM, ${SNO_DISK_GB} GB disk)"
log ""

log "=== Pre-flight checks ==="
preflight_ok=true

# Local checks
if [ ! -f "$PULL_SECRET_FILE" ]; then
    log "FAIL: Pull secret not found at $PULL_SECRET_FILE"
    preflight_ok=false
fi

if [ ! -f "$SSH_KEY_FILE" ]; then
    log "FAIL: SSH public key not found at $SSH_KEY_FILE"
    preflight_ok=false
fi

# Check install method
case "$INSTALL_METHOD" in
    agent-none|agent-external|upi-bip) ;;
    *) die "Unknown install method: $INSTALL_METHOD" ;;
esac

# Remote checks
log "  Checking SSH connectivity to $TARGET_HOST..."
if ! $SSH_CMD "echo ok" &>/dev/null; then
    die "Cannot SSH to ${SSH_USER}@${TARGET_HOST}:${SSH_PORT}"
fi

log "  Checking remote prerequisites..."
REMOTE_CHECK=$($SSH_CMD "
    errors=''
    [ -e /dev/kvm ] || errors=\"\${errors}no-kvm \"
    systemctl is-active libvirtd &>/dev/null || errors=\"\${errors}no-libvirtd \"
    virsh net-info ${NETWORK_NAME} &>/dev/null || errors=\"\${errors}no-network \"
    podman pod exists sno-infra 2>/dev/null || errors=\"\${errors}no-infra-pod \"
    command -v virt-install &>/dev/null || errors=\"\${errors}no-virt-install \"
    virsh dominfo ${VM_NAME} &>/dev/null 2>&1 && errors=\"\${errors}vm-exists \"
    echo \"\${errors:-ok}\"
" 2>/dev/null)

if [ "$REMOTE_CHECK" != "ok" ]; then
    for err in $REMOTE_CHECK; do
        case "$err" in
            no-kvm) log "FAIL: /dev/kvm not found on $TARGET_HOST" ;;
            no-libvirtd) log "FAIL: libvirtd not running on $TARGET_HOST" ;;
            no-network) log "FAIL: libvirt network '$NETWORK_NAME' not found — run karamchari-setup.sh" ;;
            no-infra-pod) log "FAIL: sno-infra pod not running — run karamchari-setup.sh" ;;
            no-virt-install) log "FAIL: virt-install not found on $TARGET_HOST" ;;
            vm-exists) log "FAIL: VM '$VM_NAME' already exists on $TARGET_HOST" ;;
        esac
    done
    preflight_ok=false
fi

if [ "$preflight_ok" = false ]; then
    die "Pre-flight checks failed."
fi
log "  All checks passed"
log ""

# =============================================================================
# 1. DOWNLOAD TOOLS ON REMOTE
# =============================================================================
log "=== Step 1: Download tools on $TARGET_HOST ==="

$SSH_CMD "
    set -euo pipefail
    MIRROR='${MIRROR_URL}'
    TOOLS_DIR='${REMOTE_TOOLS_DIR}'
    mkdir -p \"\$TOOLS_DIR\"

    for tool_info in openshift-install:openshift-install openshift-client:oc; do
        tool=\${tool_info%%:*}
        binary=\${tool_info##*:}

        if [ -f \"\$TOOLS_DIR/\$binary\" ]; then
            echo \"  \$binary cached in \$TOOLS_DIR\"
        else
            echo \"  Downloading \$tool...\"
            curl --fail -SL \"\$MIRROR/\${tool}-linux.tar.gz\" -o \"\$TOOLS_DIR/\${tool}.tar.gz\"
            tar -xzf \"\$TOOLS_DIR/\${tool}.tar.gz\" -C \"\$TOOLS_DIR\"
            rm -f \"\$TOOLS_DIR/\${tool}.tar.gz\" \"\$TOOLS_DIR/README.md\"
            echo \"  \$binary downloaded\"
        fi

        cp \"\$TOOLS_DIR/\$binary\" \"/usr/local/bin/\${binary}.tmp.\$\$\"
        chmod 0755 \"/usr/local/bin/\${binary}.tmp.\$\$\"
        mv \"/usr/local/bin/\${binary}.tmp.\$\$\" \"/usr/local/bin/\$binary\"

        if [ \"\$binary\" = \"oc\" ] && [ -f \"\$TOOLS_DIR/kubectl\" ]; then
            cp \"\$TOOLS_DIR/kubectl\" \"/usr/local/bin/kubectl.tmp.\$\$\"
            chmod 0755 \"/usr/local/bin/kubectl.tmp.\$\$\"
            mv \"/usr/local/bin/kubectl.tmp.\$\$\" /usr/local/bin/kubectl
        fi
    done
    echo '  Tools ready'
" 2>&1 | while read -r line; do log "  [remote] $line"; done
log ""

# =============================================================================
# 2. GENERATE AND UPLOAD CONFIGS
# =============================================================================
log "=== Step 2: Generate install configs ==="

PULL_SECRET=$(cat "$PULL_SECRET_FILE")
SSH_KEY=$(cat "$SSH_KEY_FILE")

case "$INSTALL_METHOD" in
    agent-none)
        PLATFORM_YAML="  none: {}"
        HAPROXY_MODE="yes"
        ;;
    agent-external)
        PLATFORM_YAML="  external: {}"
        HAPROXY_MODE="no"
        ;;
    upi-bip)
        PLATFORM_YAML="  none: {}"
        HAPROXY_MODE="yes"
        ;;
esac

# Create remote install dir and write configs there
$SSH_CMD "mkdir -p ${REMOTE_INSTALL_DIR}"

# Generate install-config.yaml
$SSH_CMD "cat > ${REMOTE_INSTALL_DIR}/install-config.yaml" << ICEOF
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
networking:
  networkType: OVNKubernetes
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  serviceNetwork:
  - 172.30.0.0/16
  machineNetwork:
  - cidr: ${SNO_SUBNET}.0/24
compute:
- name: worker
  replicas: 0
controlPlane:
  name: master
  replicas: 1
platform:
${PLATFORM_YAML}
pullSecret: '${PULL_SECRET}'
sshKey: '${SSH_KEY}'
ICEOF

# Backup
$SSH_CMD "cp ${REMOTE_INSTALL_DIR}/install-config.yaml ${REMOTE_INSTALL_DIR}/install-config.yaml.bak"
log "  install-config.yaml written to $TARGET_HOST"

# Generate agent-config.yaml for agent-based methods
case "$INSTALL_METHOD" in
    agent-none|agent-external)
        $SSH_CMD "cat > ${REMOTE_INSTALL_DIR}/agent-config.yaml" << ACEOF
apiVersion: v1beta1
kind: AgentConfig
metadata:
  name: ${CLUSTER_NAME}
rendezvousIP: ${NODE_IP}
hosts:
- hostname: master-0
  role: master
  interfaces:
  - name: enp1s0
    macAddress: "${NODE_MAC}"
  networkConfig:
    interfaces:
    - name: enp1s0
      type: ethernet
      state: up
      mac-address: "${NODE_MAC}"
      ipv4:
        enabled: true
        address:
        - ip: ${NODE_IP}
          prefix-length: 24
        dhcp: false
    dns-resolver:
      config:
        server:
        - ${BRIDGE_IP}
    routes:
      config:
      - destination: 0.0.0.0/0
        next-hop-address: ${BRIDGE_IP}
        next-hop-interface: enp1s0
ACEOF
        log "  agent-config.yaml written to $TARGET_HOST"
        ;;
esac
log ""

# =============================================================================
# 3. CREATE ISO ON REMOTE
# =============================================================================
log "=== Step 3: Create ISO on $TARGET_HOST ==="

case "$INSTALL_METHOD" in
    agent-none|agent-external)
        log "  Running: openshift-install agent create image on $TARGET_HOST..."
        $SSH_CMD "cd ${REMOTE_INSTALL_DIR} && openshift-install agent create image --dir . 2>&1" | \
            while read -r line; do log "  [remote] $line"; done

        $SSH_CMD "test -f ${REMOTE_INSTALL_DIR}/agent.x86_64.iso" || die "Agent ISO not created"
        ISO_SIZE=$($SSH_CMD "du -h ${REMOTE_INSTALL_DIR}/agent.x86_64.iso | cut -f1" 2>/dev/null)
        REMOTE_ISO="${REMOTE_INSTALL_DIR}/agent.x86_64.iso"
        log "  Agent ISO created: ${ISO_SIZE}"
        ;;

    upi-bip)
        log "  Running: openshift-install create single-node-ignition-config on $TARGET_HOST..."
        $SSH_CMD "cd ${REMOTE_INSTALL_DIR} && openshift-install create single-node-ignition-config --dir . 2>&1" | \
            while read -r line; do log "  [remote] $line"; done

        # Download RHCOS ISO on remote
        log "  Getting RHCOS ISO URL..."
        RHCOS_URL=$($SSH_CMD "openshift-install coreos print-stream-json 2>/dev/null | \
            jq -r '.architectures.x86_64.artifacts.metal.formats.iso.disk.location'")
        RHCOS_ISO="${REMOTE_TOOLS_DIR}/rhcos-live.iso"

        $SSH_CMD "
            if [ ! -f '${RHCOS_ISO}' ]; then
                echo 'Downloading RHCOS live ISO...'
                curl --fail -SL '${RHCOS_URL}' -o '${RHCOS_ISO}'
            else
                echo 'RHCOS ISO cached'
            fi
            cp '${RHCOS_ISO}' '${REMOTE_INSTALL_DIR}/sno-bip.iso'
            coreos-installer iso ignition embed -i '${REMOTE_INSTALL_DIR}/bootstrap-in-place-for-live-iso.ign' '${REMOTE_INSTALL_DIR}/sno-bip.iso'
            coreos-installer iso kargs modify \
                -a 'ip=${NODE_IP}::${BRIDGE_IP}:255.255.255.0:master-0.${CLUSTER_NAME}.${BASE_DOMAIN}:enp1s0:none' \
                -a 'nameserver=${BRIDGE_IP}' \
                '${REMOTE_INSTALL_DIR}/sno-bip.iso'
        " 2>&1 | while read -r line; do log "  [remote] $line"; done

        REMOTE_ISO="${REMOTE_INSTALL_DIR}/sno-bip.iso"
        ISO_SIZE=$($SSH_CMD "du -h ${REMOTE_ISO} | cut -f1" 2>/dev/null)
        log "  BIP ISO created: ${ISO_SIZE}"
        ;;
esac
log ""

# =============================================================================
# 4. UPDATE DNS + HAPROXY ON REMOTE
# =============================================================================
log "=== Step 4: Update DNS + HAProxy ==="

$SSH_CMD "/root/labs/sno-infra-update.sh add ${CLUSTER_NAME} ${NODE_IP} ${BASE_DOMAIN} ${HAPROXY_MODE}" 2>&1 | \
    while read -r line; do log "  [remote] $line"; done
log ""

# =============================================================================
# 5. CREATE VM ON REMOTE
# =============================================================================
log "=== Step 5: Create VM on $TARGET_HOST ==="

$SSH_CMD "
    virt-install \
        --name ${VM_NAME} \
        --ram ${SNO_RAM_MB} \
        --vcpus ${SNO_VCPUS} \
        --cpu host-passthrough \
        --disk size=${SNO_DISK_GB},bus=virtio,format=qcow2,pool=default \
        --network network=${NETWORK_NAME},mac=${NODE_MAC} \
        --cdrom ${REMOTE_ISO} \
        --boot hd,cdrom \
        --os-variant rhel9-unknown \
        --graphics none \
        --noautoconsole
" 2>&1 | while read -r line; do log "  [remote] $line"; done

log "  VM $VM_NAME created and booting from ISO"
log ""

# =============================================================================
# 6. WAIT FOR INSTALLATION
# =============================================================================
log "=== Step 6: Waiting for installation ==="
log "  (This typically takes 30-45 minutes)"

case "$INSTALL_METHOD" in
    agent-none|agent-external)
        $SSH_CMD "cd ${REMOTE_INSTALL_DIR} && openshift-install agent wait-for install-complete --dir . 2>&1" | \
            while read -r line; do log "  [remote] $line"; done
        ;;
    upi-bip)
        $SSH_CMD "cd ${REMOTE_INSTALL_DIR} && openshift-install wait-for install-complete --dir . 2>&1" | \
            while read -r line; do log "  [remote] $line"; done
        ;;
esac
log ""

# =============================================================================
# 7. POST-INSTALL
# =============================================================================
log "=== Step 7: Post-install ==="

# Copy kubeconfig back to BigB
mkdir -p "$LOCAL_INSTALL_DIR/auth"

$SCP_CMD "${SSH_USER}@${TARGET_HOST}:${REMOTE_INSTALL_DIR}/auth/kubeconfig" \
    "$LOCAL_INSTALL_DIR/auth/kubeconfig" 2>/dev/null || true
$SCP_CMD "${SSH_USER}@${TARGET_HOST}:${REMOTE_INSTALL_DIR}/auth/kubeadmin-password" \
    "$LOCAL_INSTALL_DIR/auth/kubeadmin-password" 2>/dev/null || true

if [ -f "$LOCAL_INSTALL_DIR/auth/kubeconfig" ]; then
    log "  Kubeconfig saved: $LOCAL_INSTALL_DIR/auth/kubeconfig"
else
    log "  WARN: Could not retrieve kubeconfig from $TARGET_HOST"
fi

if [ -f "$LOCAL_INSTALL_DIR/auth/kubeadmin-password" ]; then
    KUBEADMIN_PW=$(cat "$LOCAL_INSTALL_DIR/auth/kubeadmin-password")
    log "  Console: https://console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"
    log "  kubeadmin password: ${KUBEADMIN_PW}"
fi

log ""
log "=== SNO deployment complete ==="
log "  Cluster:    ${CLUSTER_NAME}"
log "  Version:    ${VERSION}"
log "  Node IP:    ${NODE_IP}"
log "  API:        https://api.${CLUSTER_NAME}.${BASE_DOMAIN}:6443"
log "  Kubeconfig: export KUBECONFIG=$LOCAL_INSTALL_DIR/auth/kubeconfig"

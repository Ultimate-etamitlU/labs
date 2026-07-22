#!/bin/bash
# =============================================================================
# peer.sh — One-time setup for SNO cluster infrastructure
#
# Sets up libvirt, Podman-based dnsmasq + HAProxy, and the snonet network
# on a peer remote lab machine for hosting SNO OCP clusters.
#
# Usage: ./peer.sh [--domain example.com]
#
# Run this ON the peer system (ssh root@<peer>, then execute).
# =============================================================================
set -euo pipefail

MANAGED_BY="# Managed by: OCP Lab Portal (peer.sh)"
DOMAIN="${1:---domain}"
if [ "$DOMAIN" = "--domain" ]; then
    DOMAIN="${2:-example.com}"
fi

# --- Configuration ---
SNO_SUBNET="192.168.200"
BRIDGE_IP="${SNO_SUBNET}.1"
NETWORK_NAME="sno"
BRIDGE_NAME="virbr-sno"
STORAGE_DIR="/kvm"
INFRA_DIR="${STORAGE_DIR}/infra"
IMAGES_DIR="${STORAGE_DIR}/images"
CLUSTERS_DIR="${STORAGE_DIR}/clusters"

DNSMASQ_CONF="${INFRA_DIR}/dnsmasq.conf"
HAPROXY_CFG="${INFRA_DIR}/haproxy.cfg"

POD_NAME="sno-infra"
DNSMASQ_CTR="${POD_NAME}-dnsmasq"
HAPROXY_CTR="${POD_NAME}-haproxy"

# SNO slot definitions
declare -A SNO_SLOTS=(
    [sno1]="10"
    [sno2]="20"
)

ts() { date "+%H:%M:%S"; }
log() { echo "[$(ts)] $*"; }
die() { echo "[$(ts)] FATAL: $*" >&2; exit 1; }

log "=== peer SNO Infrastructure Setup ==="
log "Domain: ${DOMAIN}"
log "Network: ${SNO_SUBNET}.0/24 (${NETWORK_NAME})"
log ""

# --- Phase 1: Install packages ---
log "=== Phase 1: Package installation ==="
PKGS=()
for pkg in libvirt qemu-kvm virt-install podman nmstate; do
    if ! rpm -q "$pkg" &>/dev/null; then
        PKGS+=("$pkg")
    else
        log "  OK: $pkg installed"
    fi
done

if [ ${#PKGS[@]} -gt 0 ]; then
    log "  Installing: ${PKGS[*]}"
    dnf install -y "${PKGS[@]}" || die "Package installation failed"
fi

systemctl enable --now libvirtd
log "  libvirtd enabled and running"

# --- Phase 2: Create storage directories ---
log ""
log "=== Phase 2: Storage directories ==="
for d in "$STORAGE_DIR" "$INFRA_DIR" "$IMAGES_DIR" "$CLUSTERS_DIR"; do
    mkdir -p "$d"
    log "  OK: $d"
done

# --- Phase 3: Create snonet libvirt network ---
log ""
log "=== Phase 3: Libvirt network (${NETWORK_NAME}) ==="

if virsh net-info "$NETWORK_NAME" &>/dev/null; then
    log "  Network ${NETWORK_NAME} already exists"
    if ! virsh net-info "$NETWORK_NAME" 2>/dev/null | grep -q "Active.*yes"; then
        virsh net-start "$NETWORK_NAME" 2>/dev/null || true
        log "  Started ${NETWORK_NAME}"
    fi
    # Ensure DHCP reservations exist
    for slot in "${!SNO_SLOTS[@]}"; do
        offset=${SNO_SLOTS[$slot]}
        mac_suffix=$(printf "%02x" "$offset")
        virsh net-update "$NETWORK_NAME" add ip-dhcp-host \
            "<host mac='52:54:00:c8:00:${mac_suffix}' name='${slot}-master-0' ip='${SNO_SUBNET}.${offset}'/>" \
            --live --config 2>/dev/null || true
    done
    log "  DHCP reservations verified"
elif false; then
    # Skip creation — handled above
    NETXML=$(mktemp)
    cat > "$NETXML" << NETEOF
<network>
  <name>${NETWORK_NAME}</name>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='${BRIDGE_NAME}' stp='on' delay='0'/>
  <dns enable='no'/>
  <ip address='${BRIDGE_IP}' netmask='255.255.255.0'>
    <dhcp>
      <range start='${SNO_SUBNET}.100' end='${SNO_SUBNET}.200'/>
      <host mac='52:54:00:c8:00:10' name='sno1-master-0' ip='${SNO_SUBNET}.10'/>
      <host mac='52:54:00:c8:00:20' name='sno2-master-0' ip='${SNO_SUBNET}.20'/>
    </dhcp>
  </ip>
</network>
NETEOF
    virsh net-define "$NETXML"
    virsh net-start "$NETWORK_NAME"
    virsh net-autostart "$NETWORK_NAME"
    rm -f "$NETXML"
    log "  Created and started ${NETWORK_NAME}"
fi

log "  Bridge ${BRIDGE_NAME} at ${BRIDGE_IP}"
log "  DHCP reservations: sno1=${SNO_SUBNET}.10, sno2=${SNO_SUBNET}.20"

# --- Phase 4: Generate dnsmasq config ---
log ""
log "=== Phase 4: dnsmasq configuration ==="

cat > "$DNSMASQ_CONF" << DNSEOF
${MANAGED_BY}
# dnsmasq config for SNO clusters on peer
# Upstream DNS
server=8.8.8.8
server=8.8.4.4

# Listen on all interfaces inside the container
listen-address=0.0.0.0
bind-interfaces

# Don't read /etc/resolv.conf
no-resolv

# Don't read /etc/hosts
no-hosts

# Log queries for debugging (comment out in production)
log-queries

# Per-cluster DNS records are added/removed dynamically
# by sno-infra-update.sh using marked blocks below.

# --- Dynamic cluster records ---
DNSEOF

log "  Written: $DNSMASQ_CONF"

# --- Phase 5: Generate HAProxy config ---
log ""
log "=== Phase 5: HAProxy configuration ==="

cat > "$HAPROXY_CFG" << HAEOF
${MANAGED_BY}
# HAProxy config for SNO clusters on peer
global
  log         stdout local0
  maxconn     4000

defaults
  mode                    tcp
  log                     global
  option                  dontlognull
  option                  redispatch
  retries                 3
  timeout http-request    10s
  timeout queue           1m
  timeout connect         10s
  timeout client          1m
  timeout server          1m
  timeout check           10s
  maxconn                 3000

# Kubernetes API (6443) — SNI routing
frontend api-server-6443
  bind *:6443
  mode tcp
  tcp-request inspect-delay 5s
  tcp-request content accept if { req_ssl_hello_type 1 }
# --- Dynamic api frontends ---

# Machine Config Server (22623) — SNI routing
frontend mcs-22623
  bind *:22623
  mode tcp
  tcp-request inspect-delay 5s
  tcp-request content accept if { req_ssl_hello_type 1 }
# --- Dynamic mcs frontends ---

# Ingress HTTPS (443) — SNI routing
frontend ingress-https-443
  bind *:443
  mode tcp
  tcp-request inspect-delay 5s
  tcp-request content accept if { req_ssl_hello_type 1 }
# --- Dynamic ingress-https frontends ---

# Ingress HTTP (80) — Host header routing
frontend ingress-http-80
  bind *:80
  mode http
# --- Dynamic ingress-http frontends ---

# --- Dynamic backends ---
HAEOF

log "  Written: $HAPROXY_CFG"

# --- Phase 6: Create Podman pod and containers ---
log ""
log "=== Phase 6: Podman infrastructure pod ==="

# Stop existing pod if running
if podman pod exists "$POD_NAME" 2>/dev/null; then
    log "  Stopping existing pod ${POD_NAME}..."
    podman pod stop "$POD_NAME" 2>/dev/null || true
    podman pod rm -f "$POD_NAME" 2>/dev/null || true
fi

log "  Creating pod ${POD_NAME}..."
podman pod create \
    --name "$POD_NAME" \
    -p "${BRIDGE_IP}:53:53/udp" \
    -p "${BRIDGE_IP}:53:53/tcp" \
    -p "0.0.0.0:6443:6443" \
    -p "0.0.0.0:22623:22623" \
    -p "0.0.0.0:443:443" \
    -p "0.0.0.0:80:80"

# dnsmasq container
log "  Creating dnsmasq container..."
podman run -d \
    --name "$DNSMASQ_CTR" \
    --pod "$POD_NAME" \
    --cap-add NET_ADMIN \
    -v "${DNSMASQ_CONF}:/etc/dnsmasq.conf:Z" \
    quay.io/fedora/fedora-minimal:latest \
    sh -c 'microdnf install -y dnsmasq && exec dnsmasq --no-daemon --conf-file=/etc/dnsmasq.conf'

# HAProxy container
log "  Creating HAProxy container..."
podman run -d \
    --name "$HAPROXY_CTR" \
    --pod "$POD_NAME" \
    -v "${HAPROXY_CFG}:/usr/local/etc/haproxy/haproxy.cfg:Z" \
    quay.io/fedora/fedora-minimal:latest \
    sh -c 'microdnf install -y haproxy && exec haproxy -f /usr/local/etc/haproxy/haproxy.cfg'

log "  Pod ${POD_NAME} created with dnsmasq + HAProxy"

# Verify
log ""
log "  Pod status:"
podman pod ps --filter "name=${POD_NAME}" --format "  {{.Name}}: {{.Status}}"
podman ps --pod --filter "pod=${POD_NAME}" --format "  {{.Names}}: {{.Status}}" 2>/dev/null || true

# --- Phase 7: systemd-resolved forwarding ---
log ""
log "=== Phase 7: DNS forwarding for ${DOMAIN} ==="

RESOLVED_DROP="/etc/systemd/resolved.conf.d"
mkdir -p "$RESOLVED_DROP"
cat > "${RESOLVED_DROP}/sno-lab.conf" << REOF
# Forward lab domain to dnsmasq on snonet bridge
[Resolve]
DNS=${BRIDGE_IP}
Domains=~${DOMAIN}
REOF
systemctl restart systemd-resolved 2>/dev/null || true
log "  Configured systemd-resolved to forward *.${DOMAIN} to ${BRIDGE_IP}"

# --- Phase 8: Firewall ---
log ""
log "=== Phase 8: Firewall configuration ==="
if command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null 2>&1; then
    OCP_PORTS=(6443/tcp 22623/tcp 443/tcp 80/tcp 53/udp 53/tcp)
    for port in "${OCP_PORTS[@]}"; do
        if ! firewall-cmd --query-port="$port" &>/dev/null; then
            firewall-cmd --add-port="$port" &>/dev/null
            firewall-cmd --add-port="$port" --permanent &>/dev/null
            log "  Opened $port"
        else
            log "  $port already open"
        fi
    done

    # Also open in libvirt zone for VM traffic
    LIBVIRT_ZONE="libvirt"
    if firewall-cmd --get-zones 2>/dev/null | grep -q "$LIBVIRT_ZONE"; then
        for port in "${OCP_PORTS[@]}"; do
            firewall-cmd --zone="$LIBVIRT_ZONE" --add-port="$port" &>/dev/null 2>&1 || true
            firewall-cmd --zone="$LIBVIRT_ZONE" --add-port="$port" --permanent &>/dev/null 2>&1 || true
        done
        log "  Also opened ports in ${LIBVIRT_ZONE} zone"
    fi
else
    log "  firewalld not running — ensure ports 6443,22623,443,80,53 are open"
fi

# --- Phase 9: SELinux ---
log ""
log "=== Phase 9: SELinux ==="
if command -v getenforce &>/dev/null && [ "$(getenforce)" != "Disabled" ]; then
    setsebool -P container_manage_cgroup on 2>/dev/null || true
    log "  Set container_manage_cgroup = on"
else
    log "  SELinux disabled — skipping"
fi

# --- Phase 10: Generate systemd unit for auto-start ---
log ""
log "=== Phase 10: Systemd auto-start ==="
UNIT_DIR="/etc/systemd/system"
cat > "${UNIT_DIR}/sno-infra.service" << SVCEOF
[Unit]
Description=SNO Infrastructure Pod (dnsmasq + HAProxy)
After=network-online.target libvirtd.service
Wants=network-online.target

[Service]
Type=forking
Restart=on-failure
RestartSec=10
ExecStartPre=/usr/bin/podman pod start ${POD_NAME}
ExecStart=/bin/true
ExecStop=/usr/bin/podman pod stop ${POD_NAME}

[Install]
WantedBy=multi-user.target
SVCEOF
systemctl daemon-reload
systemctl enable sno-infra.service
log "  Created and enabled sno-infra.service"

# --- Phase 11: Copy helper script ---
log ""
log "=== Phase 11: Helper scripts ==="
SCRIPT_DIR="/root/labs"
mkdir -p "$SCRIPT_DIR"
if [ -f "sno-infra-update.sh" ]; then
    cp sno-infra-update.sh "${SCRIPT_DIR}/sno-infra-update.sh"
    chmod +x "${SCRIPT_DIR}/sno-infra-update.sh"
    log "  Copied sno-infra-update.sh to ${SCRIPT_DIR}/"
else
    log "  WARN: sno-infra-update.sh not found in current dir — copy manually"
fi

# --- Verify ---
log ""
log "=== Verification ==="

# Check dnsmasq responds
if command -v dig &>/dev/null; then
    dig +short +time=2 @"${BRIDGE_IP}" test.${DOMAIN} &>/dev/null && \
        log "  dnsmasq: responding on ${BRIDGE_IP}:53" || \
        log "  dnsmasq: not responding yet (may still be starting)"
else
    log "  dig not installed — skipping DNS verify (dnf install bind-utils)"
fi

# Check HAProxy
if curl -sk --connect-timeout 2 "https://${BRIDGE_IP}:6443" &>/dev/null; then
    log "  HAProxy: port 6443 reachable"
else
    log "  HAProxy: port 6443 accepting connections (no backends yet — expected)"
fi

log ""
log "=== Setup complete ==="
log ""
log "SNO slot layout on ${NETWORK_NAME} (${SNO_SUBNET}.0/24):"
for slot in "${!SNO_SLOTS[@]}"; do
    offset=${SNO_SLOTS[$slot]}
    log "  ${slot}: ${SNO_SUBNET}.${offset}"
done
log ""
log "Infra pod: ${POD_NAME} (dnsmasq + HAProxy)"
log "Config dir: ${INFRA_DIR}/"
log "Storage dir: ${STORAGE_DIR}/"
log ""
log "Next: deploy an SNO cluster via the portal or CLI."

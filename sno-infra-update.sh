#!/bin/bash
# =============================================================================
# sno-infra-update.sh — Dynamically add/remove SNO cluster DNS + HAProxy records
#
# Runs ON the peer system. Called via SSH by the deploy/delete scripts.
# Uses marked blocks (SNO-START/SNO-END) for clean add/remove operations.
#
# Usage:
#   ./sno-infra-update.sh add    <cluster_name> <node_ip> <domain> [haproxy]
#   ./sno-infra-update.sh remove <cluster_name> <node_ip> <domain>
#
# haproxy mode (optional, default "yes"):
#   "yes"  — add HAProxy backends (platform:none, external DNS/LB)
#   "no"   — skip HAProxy (platform:external, cluster manages VIPs)
# =============================================================================
set -euo pipefail

INFRA_DIR="/kvm/infra"
DNSMASQ_CONF="${INFRA_DIR}/dnsmasq.conf"
HAPROXY_CFG="${INFRA_DIR}/haproxy.cfg"

POD_NAME="sno-infra"
DNSMASQ_CTR="${POD_NAME}-dnsmasq"
HAPROXY_CTR="${POD_NAME}-haproxy"

ACTION="${1:?Usage: $0 add|remove <cluster> <node_ip> <domain> [haproxy]}"
CLUSTER="${2:?Missing cluster name}"
NODE_IP="${3:?Missing node IP}"
DOMAIN="${4:?Missing domain}"
HAPROXY_MODE="${5:-yes}"

MARKER_START="# SNO-START ${CLUSTER}"
MARKER_END="# SNO-END ${CLUSTER}"

ts() { date "+%H:%M:%S"; }
log() { echo "[$(ts)] $*"; }
die() { echo "[$(ts)] FATAL: $*" >&2; exit 1; }

remove_block() {
    local file=$1
    if grep -q "^${MARKER_START}$" "$file" 2>/dev/null; then
        sed -i "/^${MARKER_START}$/,/^${MARKER_END}$/d" "$file"
        log "  Removed ${CLUSTER} block from $(basename "$file")"
    fi
}

add_dns() {
    remove_block "$DNSMASQ_CONF"

    cat >> "$DNSMASQ_CONF" << EOF
${MARKER_START}
address=/api.${CLUSTER}.${DOMAIN}/${NODE_IP}
address=/api-int.${CLUSTER}.${DOMAIN}/${NODE_IP}
address=/.apps.${CLUSTER}.${DOMAIN}/${NODE_IP}
${MARKER_END}
EOF
    log "  Added DNS records for ${CLUSTER} -> ${NODE_IP}"
}

add_haproxy() {
    remove_haproxy_blocks

    # Add use_backend lines to each frontend
    local tmp
    tmp=$(mktemp)

    # Process the config: insert use_backend lines after the dynamic markers
    awk -v cluster="$CLUSTER" -v domain="$DOMAIN" -v node="$NODE_IP" -v ms="$MARKER_START" -v me="$MARKER_END" '
    /^# --- Dynamic api frontends ---/ {
        print
        print ms
        print "  use_backend api-" cluster "-6443 if { req.ssl_sni -i api." cluster "." domain " }"
        print "  use_backend api-" cluster "-6443 if { req.ssl_sni -i api-int." cluster "." domain " }"
        print me
        next
    }
    /^# --- Dynamic mcs frontends ---/ {
        print
        print ms
        print "  use_backend mcs-" cluster "-22623 if { req.ssl_sni -i api-int." cluster "." domain " }"
        print me
        next
    }
    /^# --- Dynamic ingress-https frontends ---/ {
        print
        print ms
        print "  use_backend ingress-https-" cluster "-443 if { req.ssl_sni -m end .apps." cluster "." domain " }"
        print me
        next
    }
    /^# --- Dynamic ingress-http frontends ---/ {
        print
        print ms
        print "  use_backend ingress-http-" cluster "-80 if { hdr_end(host) -i .apps." cluster "." domain " }"
        print me
        next
    }
    /^# --- Dynamic backends ---/ {
        print
        print ms
        print ""
        print "backend api-" cluster "-6443"
        print "  mode tcp"
        print "  option httpchk GET /readyz HTTP/1.0"
        print "  option log-health-checks"
        print "  default-server inter 10s downinter 5s rise 2 fall 3 slowstart 60s maxconn 250 maxqueue 256 weight 100"
        print "  server " cluster "-master-0 " node ":6443 check check-ssl verify none"
        print ""
        print "backend mcs-" cluster "-22623"
        print "  mode tcp"
        print "  server " cluster "-master-0 " node ":22623 check inter 1s"
        print ""
        print "backend ingress-https-" cluster "-443"
        print "  mode tcp"
        print "  balance source"
        print "  server " cluster "-master-0 " node ":443 check inter 1s"
        print ""
        print "backend ingress-http-" cluster "-80"
        print "  mode http"
        print "  balance source"
        print "  server " cluster "-master-0 " node ":80 check inter 1s"
        print me
        next
    }
    { print }
    ' "$HAPROXY_CFG" > "$tmp"

    mv "$tmp" "$HAPROXY_CFG"
    log "  Added HAProxy frontends + backends for ${CLUSTER}"
}

remove_haproxy_blocks() {
    if grep -q "^${MARKER_START}$" "$HAPROXY_CFG" 2>/dev/null; then
        sed -i "/^${MARKER_START}$/,/^${MARKER_END}$/d" "$HAPROXY_CFG"
        log "  Removed ${CLUSTER} blocks from haproxy.cfg"
    fi
    # Also remove indented markers (frontend use_backend lines)
    if grep -q "^  ${MARKER_START}$" "$HAPROXY_CFG" 2>/dev/null; then
        sed -i "/^  ${MARKER_START}$/,/^  ${MARKER_END}$/d" "$HAPROXY_CFG"
    fi
}

restart_containers() {
    podman restart "$DNSMASQ_CTR" 2>/dev/null || log "  WARN: dnsmasq restart failed"
    if [ "$HAPROXY_MODE" = "yes" ] || [ "$ACTION" = "remove" ]; then
        podman restart "$HAPROXY_CTR" 2>/dev/null || log "  WARN: HAProxy restart failed"
    fi
    log "  Containers restarted"
}

case "$ACTION" in
    add)
        log "Adding ${CLUSTER} (node=${NODE_IP}, domain=${DOMAIN}, haproxy=${HAPROXY_MODE})"
        add_dns
        if [ "$HAPROXY_MODE" = "yes" ]; then
            add_haproxy
        fi
        restart_containers
        log "Done — ${CLUSTER} infra ready"
        ;;
    remove)
        log "Removing ${CLUSTER}"
        remove_block "$DNSMASQ_CONF"
        remove_haproxy_blocks
        restart_containers
        log "Done — ${CLUSTER} infra cleaned"
        ;;
    *)
        die "Unknown action: ${ACTION}. Use 'add' or 'remove'."
        ;;
esac

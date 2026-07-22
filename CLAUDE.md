# OCP Lab — Claude Code Guide

This repo contains automation for deploying and managing OpenShift 4.x clusters on a shared KVM/libvirt host ("the lab system"), plus a Flask web portal for self-service cluster lifecycle management.

## Repository Layout

```
labs/
├── ocp-upi-deploy.sh         # UPI cluster deployment (fixed slots)
├── ocp-ipi-deploy.sh         # IPI baremetal deployment (dynamic slots)
├── cluster-infra-setup.sh    # One-time DNS + HAProxy setup
├── csr-approver.sh           # Auto-approve CSRs (systemd template)
├── update-motd.sh            # Dynamic SSH MOTD with cluster info
├── labportal/                # Flask + SocketIO web portal
│   ├── app.py                # Routes, auth, terminal, lifecycle
│   ├── config.py             # Site config (DB-backed + env vars)
│   ├── db.py                 # SQLite schema
│   ├── static/style.css      # PatternFly 5 dark theme
│   └── templates/            # Jinja2 templates
└── README.md
```

## Architecture

- **Portal**: Flask + Flask-SocketIO, SQLite DB, PatternFly 5 dark UI
- **Proxy**: Apache httpd reverse proxy (HTTPS + WebSocket)
- **Deploy**: Shell scripts run as detached processes, survive portal restarts
- **Lifecycle**: Background reaper thread auto-deletes expired clusters every 5 min
- **Terminal**: Browser-based xterm.js over SocketIO with 1-hour inactivity timeout
- **UPI**: Fixed slots (upi1/upi2/upi3) with pre-configured DNS + HAProxy
- **IPI**: Fixed slots (ipi1/ipi2/ipi3) with 15-IP blocks from range 200-244 with VBMC/ironic

## Lab System Rules

These rules are non-negotiable for anyone working on this codebase:

1. **Shared infrastructure** — The lab host is multi-user. Never auto-destroy VMs without explicit confirmation. Other users may have active clusters.
2. **Management network is off-limits** — Only operate within the libvirt default network (192.168.122.0/24) for cluster VMs. Never touch the host's management/primary network interface.
3. **SELinux stays enforcing** — Never use `setenforce 0` or permissive mode. If SELinux blocks something, fix it properly (correct contexts, file ownership, include files).
4. **Minimal firewall** — Default-deny. Only open ports that are actually needed, in the correct zone. Document any new firewall rules.
5. **No real IPs/hostnames in code or docs** — Use `example.com` as domain, `lab.example.com` as hostname. The README already follows this convention.
6. **Cluster artifacts live at `/kvm/clusters/`** — Not `~/` or `~/clusters/`. Kubeconfigs at `/kvm/clusters/<name>/auth/kubeconfig`.

## Development Workflow

### Git workflow
- Never push directly to main
- Open a GitHub issue first, then submit a PR linked to it
- PRs require admin merge: `gh pr merge --admin --merge --delete-branch`

### Code on laptop, run on lab
- Code is developed locally and synced to the lab host
- All runtime testing (oc, kubectl, virsh, vbmc, DNS) happens on the lab host, not locally
- The portal runs on the lab host as a systemd service

### Testing custom OCP images
When testing a code fix on a live cluster:
1. Build binaries locally
2. Create `Dockerfile.custom` using the running image as base
3. Build and push to the lab host's local registry (port 5050)
4. Add insecure registry to cluster, wait for MCPs
5. Set operator to unmanaged via clusterversion overrides
6. Patch deployment/daemonset with custom image

Never copy binaries into running containers — it doesn't work (Go version mismatches, text file busy).

## Key Configuration

| Variable | Default | Purpose |
|----------|---------|---------|
| `LABPORTAL_SECRET_KEY` | *(required in prod)* | Flask session secret |
| `LABPORTAL_CORS_ORIGINS` | auto-detect | Allowed CORS origins |
| `LABPORTAL_DB` | `labportal/labportal.db` | SQLite database path |
| `LABPORTAL_UPI_SCRIPT` | `/root/labs/ocp-upi-deploy.sh` | UPI deploy script |
| `LABPORTAL_IPI_SCRIPT` | `/root/labs/ocp-ipi-deploy.sh` | IPI deploy script |
| `CLUSTERS_DIR` | `/kvm/clusters` | Cluster artifacts directory |

## Code Conventions

- **Python**: Flask patterns, no type hints in existing code, use `get_db_ctx()` context manager for DB access
- **Shell**: Bash, `set -euo pipefail`, functions for major steps, log with timestamps
- **Frontend**: PatternFly 5 dark theme, no custom JS frameworks, vanilla JS + SocketIO
- **Security**: Input validation at all boundaries, parameterized SQL, no shell injection via user input, CSRF protection via Flask sessions
- **Templates**: Jinja2 with `base.html` layout, PatternFly component classes

## Cluster Slot Layout

### UPI (fixed)
| Slot | Allocated Range | Node IPs | Bootstrap | Masters | Workers |
|------|----------------|----------|-----------|---------|---------|
| upi1 | .110-.130 | .110-.115 | .110 | .111-.113 | .114-.115 |
| upi2 | .131-.150 | .131-.137 | .131 | .132-.134 | .135-.137 |
| upi3 | .151-.170 | .151-.156 | .151 | .152-.154 | .155-.156 |

### IPI (fixed slots, 15-IP blocks)
| Slot | Range | API VIP | Ingress VIP | Masters | Workers | Spare |
|------|-------|---------|-------------|---------|---------|-------|
| ipi1 | .200-.214 | .200 | .201 | .202-.204 | .205-.209 | .210-.214 |
| ipi2 | .215-.229 | .215 | .216 | .217-.219 | .220-.224 | .225-.229 |
| ipi3 | .230-.244 | .230 | .231 | .232-.234 | .235-.239 | .240-.244 |

`.245-.254` reserved as buffer. All IPs on `192.168.122.0/24`.

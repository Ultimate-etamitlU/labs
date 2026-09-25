import json
import os
import secrets
import socket
import threading

BASE_DIR = os.path.dirname(os.path.abspath(__file__))

_secret = os.environ.get("LABPORTAL_SECRET_KEY")
if not _secret and os.environ.get("FLASK_ENV") != "development":
    raise RuntimeError("LABPORTAL_SECRET_KEY must be set in production")
SECRET_KEY = _secret or secrets.token_hex(32)

# Database path — must be known before DB exists
DB_PATH = os.environ.get("LABPORTAL_DB", os.path.join(BASE_DIR, "labportal.db"))

# Direct web-console forwarding ports on the lab host. UPI slots use their
# configured order, followed by the fixed IPI slots, so the portal and
# infrastructure setup share one stable mapping.
CONSOLE_PORT_BASE = int(os.environ.get("LABPORTAL_CONSOLE_PORT_BASE", "6100"))
CONSOLE_ACTIVATION_DIR = os.environ.get(
    "LABPORTAL_CONSOLE_ACTIVATION_DIR", "/var/lib/labportal-console"
)

# Deploy script paths — host-level config, not portal-level
DEPLOY_SCRIPT = os.environ.get("LABPORTAL_DEPLOY_SCRIPT", "/root/labs/ocp-upi-deploy.sh")

# Install types — resource costs and deploy scripts per installation method
INSTALL_TYPES = {
    "upi": {
        "label": "UPI (User Provisioned)",
        "script": os.environ.get("LABPORTAL_UPI_SCRIPT", "/root/labs/ocp-upi-deploy.sh"),
        "vcpus": 16,    # 3×4 masters + 2×2 workers
        "ram_gb": 80,    # 5×16G
        "requires_slot": True,
    },
    "ipi": {
        "label": "IPI (Installer Provisioned)",
        "script": os.environ.get("LABPORTAL_IPI_SCRIPT", "/root/labs/ocp-ipi-deploy.sh"),
        "vcpus": 32,    # 3×8 masters + 2×4 workers
        "ram_gb": 128,   # 3×32G + 2×16G
        "requires_slot": False,
        "requires_ipi_slot": True,
    },
    "sno": {
        "label": "SNO (Single Node)",
        "script": os.environ.get("LABPORTAL_SNO_SCRIPT", "/root/labs/ocp-sno-deploy.sh"),
        "vcpus": 8,
        "ram_gb": 32,
        "requires_slot": False,
        "remote": True,
    },
}

# Release presets shown in the deployment form.  OCP 5.0.0-rc.2 is pinned
# because this is the temporary EC2 release being exposed on the lab host.
OCP_RELEASES = {
    "ocp4": {
        "label": "OpenShift 4.x",
        "version": "",
    },
    "ocp5-ec2": {
        "label": "OpenShift 5.0 - EC2",
        "version": "5.0.0-rc.2",
    },
}


def ocp_mirror_channel(version):
    """Return the mirror channel for a supported OCP version."""
    if version.startswith("4."):
        return "openshift-v4"
    if version.startswith("5."):
        return "openshift-v5"
    raise ValueError(f"Unsupported OCP major version: {version}")


def ocp_mirror_url(version):
    """Return the exact client-tool directory for an OCP version."""
    channel = ocp_mirror_channel(version)
    return f"https://mirror.openshift.com/pub/{channel}/clients/ocp/{version}/"

SNO_SLOTS = {
    "sno1": {"ip_suffix": 10, "ip": "192.168.200.10", "mac": "52:54:00:c8:00:10"},
    "sno2": {"ip_suffix": 20, "ip": "192.168.200.20", "mac": "52:54:00:c8:00:20"},
}

SNO_INSTALL_METHODS = {
    "agent-none": "Agent-based (External DNS)",
    "agent-external": "Agent-based (VIPs)",
    "upi-bip": "UPI (Bootstrap-in-Place)",
}


def sno_deployments_enabled():
    """Whether the portal may accept new SNO deployments."""
    value = os.environ.get("LABPORTAL_ALLOW_SNO", "")
    return value.strip().lower() in {"1", "true", "yes", "on"}


def sno_target_roles():
    """Return machine roles available for new SNO deployments."""
    return ("boss", "peer") if sno_deployments_enabled() else ()


# IPI fixed slots — 15-IP blocks from 200-244
IPI_SLOTS = {
    "ipi1": 200,
    "ipi2": 215,
    "ipi3": 230,
}

def ipi_slots():
    return IPI_SLOTS


# ---------------------------------------------------------------------------
# Site configuration — DB-backed with in-memory cache
# ---------------------------------------------------------------------------
# All site settings live in the admin_config table (key/value).
# On first run the setup wizard populates them.  After that they're read
# from DB once and cached in memory for the lifetime of the process.

_site_cache = {}
_site_loaded = False
_site_lock = threading.RLock()


def _db_ctx():
    """Lazy import to avoid circular dependency with db.py."""
    from db import get_db_ctx
    return get_db_ctx()


def load_site_config():
    """Load all admin_config rows into the in-memory cache."""
    global _site_cache, _site_loaded
    with _site_lock:
        try:
            with _db_ctx() as conn:
                rows = conn.execute("SELECT key, value FROM admin_config").fetchall()
            _site_cache = {row["key"]: row["value"] for row in rows}
        except Exception:
            _site_cache = {}
        _site_loaded = True


def get_site(key, default=None):
    """Read a site config value (cached)."""
    with _site_lock:
        if not _site_loaded:
            load_site_config()
        return _site_cache.get(key, default)


def set_site(key, value):
    """Write a site config value to DB and update cache."""
    with _db_ctx() as conn:
        conn.execute(
            "INSERT OR REPLACE INTO admin_config (key, value) VALUES (?, ?)",
            (key, value)
        )
        conn.commit()
    with _site_lock:
        _site_cache[key] = value


def set_site_bulk(data: dict):
    """Write multiple site config values at once."""
    with _db_ctx() as conn:
        for k, v in data.items():
            conn.execute(
                "INSERT OR REPLACE INTO admin_config (key, value) VALUES (?, ?)",
                (k, v)
            )
        conn.commit()
    with _site_lock:
        _site_cache.update(data)


def reload_site_config():
    """Force-reload config from DB (e.g. after admin edits settings)."""
    global _site_loaded
    with _site_lock:
        _site_loaded = False
    load_site_config()


def is_setup_complete():
    """Check whether the first-run wizard has been completed."""
    return get_site("setup_complete") == "true"


# --- Convenience accessors for commonly used settings ---

def admin_user():
    return get_site("admin_user", "admin")

def base_domain():
    return get_site("base_domain", "example.com")

def allowed_email_domains():
    raw = get_site("allowed_email_domains", "")
    if not raw:
        return set()
    return {d.strip().lower() for d in raw.split(",") if d.strip()}

def cluster_slots():
    raw = get_site("cluster_slots", "{}")
    try:
        slots = json.loads(raw)
        return {k: int(v) for k, v in slots.items()}
    except (json.JSONDecodeError, ValueError):
        return {}


def console_cluster_order():
    """Return console-enabled slots: configured UPI slots, then fixed IPI slots."""
    upi_slots = sorted(cluster_slots().items(), key=lambda item: (item[1], item[0]))
    ipi_slots_ordered = sorted(ipi_slots().items(), key=lambda item: (item[1], item[0]))
    return [name for name, _offset in upi_slots + ipi_slots_ordered]


def console_ports():
    """Return the direct BigB console port for each configured UPI and IPI slot."""
    return {
        cluster_name: CONSOLE_PORT_BASE + index
        for index, cluster_name in enumerate(console_cluster_order())
    }


def console_url(cluster_name, domain=None, public_host=None):
    """Return the direct console URL, or None when no forwarding is defined.

    The cluster DNS name is intentionally private to BigB. When the portal
    supplies its reachable host, the browser stays on BigB while the server
    proxy maps the request to the private OpenShift console and OAuth routes.
    """
    port = console_ports().get(cluster_name)
    if port is None:
        return None
    if public_host:
        return f"https://{public_host}:{port}"
    domain = domain or base_domain()
    return f"https://console-openshift-console.apps.{cluster_name}.{domain}:{port}"


def admin_email():
    return get_site("admin_email", "")

def lab_hostname():
    return get_site("lab_hostname", "lab.local")

def storage_dir():
    return get_site("storage_dir", "/kvm")

def _local_ips():
    """Detect this machine's non-loopback IPv4 addresses."""
    ips = set()
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ip = info[4][0]
            if not ip.startswith("127."):
                ips.add(ip)
    except socket.gaierror:
        pass
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(0)
        s.connect(("10.255.255.255", 1))
        ips.add(s.getsockname()[0])
        s.close()
    except Exception:
        pass
    return ips


def cors_origins():
    """CORS origins: explicit env override, or auto-detect from local IPs."""
    explicit = os.environ.get("LABPORTAL_CORS_ORIGINS")
    if explicit:
        return [o.strip() for o in explicit.split(",") if o.strip()]
    origins = set()
    for ip in _local_ips():
        origins.add(f"https://{ip}")
        origins.add(f"http://{ip}")
    origins.add("https://localhost")
    origins.add("http://localhost")
    return list(origins)

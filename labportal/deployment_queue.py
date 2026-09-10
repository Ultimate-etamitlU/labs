"""Small, database-backed primitives for the deployment queue.

The portal uses SQLite as its source of truth.  These helpers deliberately keep
the queue state transitions short and transactional so a second portal worker
cannot claim the same request after the first worker has claimed it.
"""

import sqlite3


QUEUED_STATUS = "queued"
STARTING_STATUS = "starting"
DEPLOYING_STATUS = "deploying"
COMPLETED_STATUSES = ("completed", "complete")
ACTIVE_DEPLOYMENT_STATUSES = (
    QUEUED_STATUS,
    STARTING_STATUS,
    DEPLOYING_STATUS,
    "completed",
    "complete",
    "stale",
)
RUNNING_DEPLOYMENT_STATUSES = (STARTING_STATUS, DEPLOYING_STATUS)
TERMINAL_DEPLOYMENT_STATUSES = ("failed", "cancelled", "stale", "completed", "complete")


def sql_statuses(statuses):
    """Return a safely constructed SQL literal list for fixed status values."""
    allowed = set(ACTIVE_DEPLOYMENT_STATUSES) | set(TERMINAL_DEPLOYMENT_STATUSES)
    if any(status not in allowed for status in statuses):
        raise ValueError("unknown deployment status")
    return ", ".join(f"'{status}'" for status in statuses)


def ensure_schema(conn):
    """Add queue/audit columns to an existing deployments table.

    Migrations are additive and safe to run repeatedly.  Existing deployment
    rows retain their original status and history.
    """
    columns = {row[1] for row in conn.execute("PRAGMA table_info(deployments)")}
    additions = {
        "install_method": "TEXT DEFAULT ''",
        "reservation_hours": "INTEGER NOT NULL DEFAULT 8",
        "resource_vcpus": "INTEGER NOT NULL DEFAULT 0",
        "resource_ram_gb": "INTEGER NOT NULL DEFAULT 0",
        "queued_at": "TIMESTAMP",
        "claimed_at": "TIMESTAMP",
        "heartbeat_at": "TIMESTAMP",
        "process_group": "INTEGER",
        "failure_reason": "TEXT DEFAULT ''",
        "exit_code": "INTEGER",
        "last_reconciled_at": "TIMESTAMP",
        "claimed_by": "TEXT DEFAULT ''",
    }
    for name, definition in additions.items():
        if name not in columns:
            conn.execute(f"ALTER TABLE deployments ADD COLUMN {name} {definition}")

    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_deployments_queue "
        "ON deployments(status, queued_at, id)"
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_deployments_cluster_status "
        "ON deployments(cluster_name, status, id)"
    )


def claim_job(conn, job_id, worker_id):
    """Atomically move one queued job to ``starting`` and return its row.

    ``None`` means another worker changed the job before this transaction
    acquired the write lock.
    """
    if conn.in_transaction:
        conn.commit()
    conn.execute("BEGIN IMMEDIATE")
    try:
        cursor = conn.execute(
            "UPDATE deployments "
            "SET status=?, claimed_at=CURRENT_TIMESTAMP, heartbeat_at=CURRENT_TIMESTAMP, "
            "claimed_by=? "
            "WHERE id=? AND status=?",
            (STARTING_STATUS, worker_id, job_id, QUEUED_STATUS),
        )
        if cursor.rowcount != 1:
            conn.rollback()
            return None
        row = conn.execute(
            "SELECT * FROM deployments WHERE id=?", (job_id,)
        ).fetchone()
        conn.commit()
        return row
    except Exception:
        conn.rollback()
        raise


def active_statuses_sql():
    return sql_statuses(ACTIVE_DEPLOYMENT_STATUSES)


def running_statuses_sql():
    return sql_statuses(RUNNING_DEPLOYMENT_STATUSES)


def is_sqlite_database_error(exc):
    return isinstance(exc, sqlite3.Error)

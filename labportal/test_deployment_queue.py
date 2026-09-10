import sqlite3
import unittest

from deployment_queue import (
    ACTIVE_DEPLOYMENT_STATUSES,
    QUEUED_STATUS,
    STARTING_STATUS,
    claim_job,
    ensure_schema,
    sql_statuses,
)


class DeploymentQueueSchemaTests(unittest.TestCase):
    def setUp(self):
        self.conn = sqlite3.connect(":memory:")
        self.conn.row_factory = sqlite3.Row
        self.conn.execute(
            "CREATE TABLE deployments ("
            "id INTEGER PRIMARY KEY AUTOINCREMENT, "
            "cluster_name TEXT NOT NULL, ocp_version TEXT NOT NULL, "
            "status TEXT NOT NULL DEFAULT 'deploying', started_at TIMESTAMP, "
            "finished_at TIMESTAMP, pid INTEGER, log_file TEXT)"
        )
        ensure_schema(self.conn)

    def tearDown(self):
        self.conn.close()

    def test_migration_is_idempotent(self):
        ensure_schema(self.conn)
        columns = {row[1] for row in self.conn.execute("PRAGMA table_info(deployments)")}
        self.assertIn("queued_at", columns)
        self.assertIn("failure_reason", columns)
        self.assertIn("process_group", columns)

    def test_claim_is_atomic_and_only_claims_queued_rows(self):
        self.conn.execute(
            "INSERT INTO deployments (cluster_name, ocp_version, status, queued_at) "
            "VALUES ('upi1', '4.19.22', 'queued', CURRENT_TIMESTAMP)"
        )
        self.conn.execute(
            "INSERT INTO deployments (cluster_name, ocp_version, status) "
            "VALUES ('upi2', '4.19.22', 'deploying')"
        )
        self.conn.commit()

        claimed = claim_job(self.conn, 1, "worker-a")
        self.assertIsNotNone(claimed)
        self.assertEqual(claimed["status"], STARTING_STATUS)
        self.assertEqual(claimed["claimed_by"], "worker-a")
        self.assertIsNone(claim_job(self.conn, 1, "worker-b"))
        self.assertIsNone(claim_job(self.conn, 2, "worker-a"))

    def test_status_sql_is_fixed_and_parameter_free(self):
        status_sql = sql_statuses((QUEUED_STATUS, "stale"))
        self.assertEqual(status_sql, "'queued', 'stale'")
        self.assertEqual(len(ACTIVE_DEPLOYMENT_STATUSES), 6)


if __name__ == "__main__":
    unittest.main()

import os
import unittest
from unittest.mock import patch

from config import sno_deployments_enabled, sno_target_roles


class SnoDeploymentPolicyTests(unittest.TestCase):
    def test_sno_deployments_are_disabled_by_default(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertFalse(sno_deployments_enabled())
            self.assertEqual(sno_target_roles(), ())

    def test_sno_deployments_can_be_enabled_with_common_true_values(self):
        for value in ("1", "true", "yes", "on", " TRUE "):
            with self.subTest(value=value), patch.dict(
                os.environ, {"LABPORTAL_ALLOW_SNO": value}, clear=True
            ):
                self.assertTrue(sno_deployments_enabled())
                self.assertEqual(sno_target_roles(), ("boss", "peer"))

    def test_false_values_keep_sno_deployments_disabled(self):
        for value in ("", "0", "false", "no", "off", "unexpected"):
            with self.subTest(value=value), patch.dict(
                os.environ, {"LABPORTAL_ALLOW_SNO": value}, clear=True
            ):
                self.assertFalse(sno_deployments_enabled())
                self.assertEqual(sno_target_roles(), ())


if __name__ == "__main__":
    unittest.main()

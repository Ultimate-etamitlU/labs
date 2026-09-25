import unittest
from unittest.mock import patch

from config import OCP_RELEASES, console_ports, console_url, ocp_mirror_channel, ocp_mirror_url


class OcpVersionTests(unittest.TestCase):
    def test_release_preset_for_ocp_5_ec2(self):
        self.assertEqual(OCP_RELEASES["ocp5-ec2"]["label"], "OpenShift 5.0 - EC2")
        self.assertEqual(OCP_RELEASES["ocp5-ec2"]["version"], "5.0.0-rc.2")

    def test_mirror_channels(self):
        self.assertEqual(ocp_mirror_channel("4.22.14"), "openshift-v4")
        self.assertEqual(ocp_mirror_channel("5.0.0-rc.2"), "openshift-v5")
        self.assertEqual(
            ocp_mirror_url("5.0.0-rc.2"),
            "https://mirror.openshift.com/pub/openshift-v5/clients/ocp/5.0.0-rc.2/",
        )

    def test_unsupported_major_version(self):
        with self.assertRaises(ValueError):
            ocp_mirror_channel("6.0.0")

    def test_direct_console_ports_follow_slot_order(self):
        with patch("config.cluster_slots", return_value={"upi2": 131, "upi1": 110}):
            self.assertEqual(console_ports(), {
                "upi1": 6100,
                "upi2": 6101,
                "ipi1": 6102,
                "ipi2": 6103,
                "ipi3": 6104,
            })
            self.assertEqual(
                console_url("upi2", "example.com"),
                "https://console-openshift-console.apps.upi2.example.com:6101",
            )
            self.assertEqual(
                console_url("upi1", "example.com", "10.1.224.14"),
                "https://10.1.224.14:6100",
            )


if __name__ == "__main__":
    unittest.main()

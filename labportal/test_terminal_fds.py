import os
import subprocess
import sys
import unittest


class TerminalFdTests(unittest.TestCase):
    def test_terminal_child_helper_closes_inherited_descriptors(self):
        child_code = "\n".join((
            "import os",
            "from terminal_fds import close_inherited_fds",
            "fd = os.open(os.devnull, os.O_RDONLY)",
            "assert fd >= 3",
            "close_inherited_fds()",
            "try:",
            "    os.fstat(fd)",
            "except OSError:",
            "    os._exit(0)",
            "os._exit(1)",
        ))
        result = subprocess.run(
            [sys.executable, "-c", child_code],
            cwd=os.path.dirname(__file__),
            capture_output=True,
            text=True,
            timeout=5,
        )
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()

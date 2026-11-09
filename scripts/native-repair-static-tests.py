#!/usr/bin/env python3
"""Owned metadata/API compatibility checks. No app, root, mount or service."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("native_package_probe", ROOT / "scripts/native-tmpfs-package-probe.py")
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class ProbeAPIs(unittest.TestCase):
    def test_darwin_xattrs_work_without_python_os_wrappers(self):
        with mock.patch.object(probe.os, "getxattr", None, create=True), mock.patch.object(probe.os, "setxattr", None, create=True):
            probe.preflight_apis()
            scratch = ROOT / "artifacts/native-repair-static"
            scratch.mkdir(parents=True, exist_ok=True)
            with tempfile.TemporaryDirectory(prefix="xattr-", dir=scratch) as value:
                path = Path(value) / "owned fixture"
                path.write_bytes(b"owned metadata fixture")
                for payload in [b"", b"file-metadata\x00binary"]:
                    probe.XATTRS.setxattr(path, "com.ramnest.fixture", payload)
                    self.assertEqual(probe.XATTRS.getxattr(path, "com.ramnest.fixture"), payload)
                with self.assertRaises(OSError):
                    probe.XATTRS.getxattr(path, "com.ramnest.absent")
                with self.assertRaises(RuntimeError):
                    probe.XATTRS.setxattr(path, "com.ramnest.fixture", b"x" * ((1 << 20) + 1))
                self.assertEqual(path.read_bytes(), b"owned metadata fixture")

    def test_missing_platform_api_rejects_preflight(self):
        with mock.patch.object(probe.os, "chflags", None):
            with self.assertRaisesRegex(RuntimeError, "Missing fixture API"):
                probe.preflight_apis()


if __name__ == "__main__":
    unittest.main(verbosity=2)

#!/usr/bin/env python3
"""Artifact-neutral production dependency/provenance checks; no compiler or mount."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


class NativeProductionContracts(unittest.TestCase):
    def test_default_cmake_has_only_native_helper_and_pure_protocol_tests(self):
        cmake = (ROOT / "Native/CMakeLists.txt").read_text()
        self.assertIn("add_executable(ramnest-helper NativeTmpfsHelper.cpp)", cmake)
        self.assertIn("add_executable(ramnest-native-protocol-tests NativeTmpfsProtocolTests.cpp)", cmake)
        self.assertEqual({p.name for p in (ROOT / "Native").iterdir() if p.is_file()},
                         {"CMakeLists.txt", "NativeTmpfsHelper.cpp", "NativeTmpfsProtocol.hpp", "NativeTmpfsProtocolTests.cpp"})
        for dependency in ["FUSET_ROOT", "libfuse", "target_link_libraries", "LEGACY_TESTS", "include(Legacy"]:
            self.assertNotIn(dependency, cmake)

    def test_xcode_embeds_native_target_with_required_sandbox_inputs(self):
        project = (ROOT / "project.yml").read_text()
        prebuild = project.split("    preBuildScripts:\n", 1)[1].split("    postBuildScripts:\n", 1)[0]
        self.assertIn('"$native_config" ramnest-helper', prebuild)
        for name in ["CMakeLists.txt", "NativeTmpfsHelper.cpp", "NativeTmpfsProtocol.hpp", "NativeTmpfsProtocolTests.cpp"]:
            self.assertIn("$(PROJECT_DIR)/Native/" + name, prebuild)
        self.assertNotIn("Native/MemoryFS.cpp", prebuild)
        self.assertNotIn("Native/Helper.cpp", prebuild)
        self.assertIn("ENABLE_USER_SCRIPT_SANDBOXING: YES", project)
        self.assertEqual(project.count("INFOPLIST_FILE:"), 2)  # existing app file + test generated file

    def test_provenance_authenticates_production_inputs_and_helper(self):
        scratch = ROOT / "artifacts/native-production-static"
        scratch.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="receipt-", dir=scratch) as value:
            build = Path(value)
            command = "clang++ -O2 -c " + str(ROOT / "Native/NativeTmpfsHelper.cpp")
            (build / "compile_commands.json").write_text(json.dumps([
                {"file": str(ROOT / "Native/NativeTmpfsHelper.cpp"), "command": command},
                {"file": str(ROOT / "Native/NativeTmpfsProtocolTests.cpp"), "command": "clang++ -O2 -UNDEBUG -c protocol"},
            ]))
            (build / "ramnest-helper").write_bytes(b"owned helper identity fixture")
            args = [sys.executable, str(ROOT / "scripts/native-provenance.py"), str(ROOT), str(build), "RelWithDebInfo"]
            subprocess.run(args + ["--prepare"], check=True, capture_output=True)
            subprocess.run(args, check=True, capture_output=True)
            receipt = json.loads((build / "provenance.json").read_text())
            self.assertEqual(receipt["engine"], "native-tmpfs-v1")
            self.assertEqual(receipt["nativeCompileCommand"], command)
            self.assertNotIn("memoryCompileCommand", receipt)
            self.assertIn("Native/NativeTmpfsHelper.cpp", receipt["sources"])
            self.assertNotIn("Native/MemoryFS.cpp", receipt["sources"])
            sources = json.loads((build / "source-inputs.json").read_text())
            sources["Native/NativeTmpfsHelper.cpp"] = "changed-input-fixture"
            (build / "source-inputs.json").write_text(json.dumps(sources))
            result = subprocess.run(args, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("sources changed", result.stderr.lower())


if __name__ == "__main__":
    unittest.main(verbosity=2)

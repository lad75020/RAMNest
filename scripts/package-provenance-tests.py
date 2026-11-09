#!/usr/bin/env python3
"""Exercise both actual embed scripts with owned fixtures, without building/signing."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("scratch", type=Path, help="Existing owned directory for disposable fixtures")
args = parser.parse_args()
ROOT = Path(__file__).resolve().parent.parent
BUILD = (ROOT / "scripts/build.sh").read_text()
PROJECT = (ROOT / "project.yml").read_text()
EMBED = PROJECT.split("    postBuildScripts:\n", 1)[1].split("  RAMNestCoreTests:", 1)[0]


class PackageProvenanceTests(unittest.TestCase):
    def exercise(self, script):
        with tempfile.TemporaryDirectory(prefix="package-provenance-", dir=args.scratch) as tmp:
            base = Path(tmp)
            native = base / "temp/ramnest-native-Debug"
            authority = direct_authority = base / "build/native-authority"
            generated = base / "build/direct/NativeHelperBuildIdentity.swift"
            direct = base / "build/direct"
            for directory in [native, direct, base / "resources", base / "scripts"]:
                directory.mkdir(parents=True)
            for path, data in {
                native / "ramnest-helper": b"helper fixture",
                native / "provenance.json": (json.dumps({"engine":"native-tmpfs-v1", "configuration":"Debug", "helperSHA256":hashlib.sha256(b"helper fixture").hexdigest()}) + "\n").encode(),
                direct / "ramnest": b"cli fixture",
                direct / "RAMNest": b"app fixture",
                direct / "libRAMNestCore.dylib": b"library fixture",
                base / "resources/Info.plist": b"plist fixture",
                base / "scripts/native-build-authority.py": (ROOT / "scripts/native-build-authority.py").read_bytes(),
            }.items():
                path.write_bytes(data)
            subprocess.run(["python3", str(ROOT / "scripts/native-build-authority.py"), "generate", str(native), "Debug", str(authority), str(generated)], check=True)
            # Xcode's shared producer output lives under its configuration product directory.
            shared = direct / "RAMNestNativeAuthority-Debug"
            subprocess.run(["python3", str(ROOT / "scripts/native-build-authority.py"), "generate", str(native), "Debug", str(shared), str(generated)], check=True)
            app = base / "products/RAMNest.app"
            env = dict(os.environ, app=str(app), native=str(native), build=str(base / "build"), authority=str(direct_authority), generated=str(generated), PROJECT_DIR=str(ROOT), WRAPPER_NAME="RAMNest.app",
                       TARGET_BUILD_DIR=str(base / "products"), CONTENTS_FOLDER_PATH="RAMNest.app/Contents",
                       DERIVED_FILE_DIR=str(base / "derived"), TEMP_DIR=str(base / "temp"),
                       CONFIGURATION="Debug", BUILT_PRODUCTS_DIR=str(direct))
            subprocess.run(["/bin/bash", "-eu", "-c", script], cwd=base, env=env, check=True, timeout=10)
            contents = app / "Contents"
            self.assertEqual((contents / "Resources/native-provenance.json").read_bytes(),
                             (native / "provenance.json").read_bytes())
            self.assertEqual(sorted(p.name for p in (contents / "Helpers").iterdir()),
                             ["ramnest", "ramnest-helper"])
            self.assertEqual((contents / "Helpers/ramnest").read_bytes(), b"cli fixture")
            self.assertEqual((contents / "Helpers/ramnest-helper").read_bytes(), b"helper fixture")

    def test_direct_build_embed(self):
        script = BUILD[BUILD.index('mkdir -p "$app/Contents/MacOS"'):BUILD.index("xcrun actool")]
        self.exercise(script)

    def test_xcode_embed(self):
        script = textwrap.dedent(EMBED.split("        script: |\n", 1)[1].split("        inputFiles:", 1)[0])
        self.exercise(script)

    def test_xcode_declares_provenance_dependency_and_resource_output(self):
        inputs, outputs = EMBED.split("        inputFiles:\n", 1)[1].split("        outputFiles:\n", 1)
        self.assertIn("- $(BUILT_PRODUCTS_DIR)/RAMNestNativeAuthority-$(CONFIGURATION)/provenance.json", inputs)
        self.assertIn("- $(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Resources/native-provenance.json", outputs)
        self.assertNotIn("Helpers/native-provenance.json", PROJECT + BUILD)

    def test_xcode_declares_production_native_source_inputs(self):
        prebuild = PROJECT.split("    preBuildScripts:\n", 1)[1].split("    postBuildScripts:\n", 1)[0]
        inputs = prebuild.split("        inputFiles:\n", 1)[1].split("        outputFiles:\n", 1)[0]
        # The old executable engine is deleted. CMake also configures the pure
        # native protocol test, so its sources belong to the sandbox inputs.
        for name in ["CMakeLists.txt", "NativeTmpfsHelper.cpp", "NativeTmpfsProtocol.hpp", "NativeTmpfsProtocolTests.cpp"]:
            self.assertIn("- $(PROJECT_DIR)/Native/" + name, inputs)
        self.assertNotIn("Native/MemoryFS.cpp", inputs)
        self.assertNotIn("Native/Helper.cpp", inputs)

    def test_xcode_preserves_script_sandbox_and_uses_auxiliary_temp(self):
        self.assertIn("ENABLE_USER_SCRIPT_SANDBOXING: YES", PROJECT)
        self.assertIn('native="$TEMP_DIR/ramnest-native-$CONFIGURATION"', PROJECT)
        self.assertIn('authority="$BUILT_PRODUCTS_DIR/RAMNestNativeAuthority-$CONFIGURATION"', PROJECT)
        self.assertNotIn('"$DERIVED_FILE_DIR/native-$CONFIGURATION"', PROJECT)


if __name__ == "__main__":
    unittest.main(argv=[__file__], verbosity=2)

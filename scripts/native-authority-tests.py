#!/usr/bin/env python3
"""Artifact-neutral compiled-identity generation/packaging regressions. No builds."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("native_authority", ROOT / "scripts/native-build-authority.py")
authority = importlib.util.module_from_spec(spec)
spec.loader.exec_module(authority)


class NativeAuthorityTests(unittest.TestCase):
    def setUp(self):
        scratch = ROOT / "artifacts/native-authority-static"
        scratch.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="case-", dir=scratch)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def prepare(self, config, payload=None):
        native = self.root / config / "native"
        native.mkdir(parents=True, exist_ok=True)
        payload = payload or ("opaque signed-image fixture " + config).encode()
        (native / "ramnest-helper").write_bytes(payload)
        receipt = {"engine": authority.ENGINE, "configuration": "Debug" if config == "Debug" else "RelWithDebInfo",
                   "helperSHA256": hashlib.sha256(payload).hexdigest(), "nativeCompileCommand": "fixture only, no compiler executed"}
        (native / "provenance.json").write_text(json.dumps(receipt) + "\n")
        output = self.root / config / "products/authority"
        generated = self.root / config / "derived/NativeHelperBuildIdentity.swift"
        return native, output, generated

    def test_debug_release_generation_embed_and_reproducibility(self):
        results = {}
        for config in ["Debug", "Release"]:
            native, output, generated = self.prepare(config)
            authority.generate(native, config, output, generated)
            before, timestamp = generated.read_bytes(), generated.stat().st_mtime_ns
            authority.generate(native, config, output, generated)
            self.assertEqual(generated.read_bytes(), before)
            self.assertEqual(generated.stat().st_mtime_ns, timestamp)
            independent = self.root / config / "independent-output"
            independent_source = independent / "derived/NativeHelperBuildIdentity.swift"
            authority.generate(native, config, independent / "products", independent_source)
            self.assertEqual(independent_source.read_bytes(), before)
            self.assertEqual((independent / "products/authority.json").read_bytes(), (output / "authority.json").read_bytes())
            expected = hashlib.sha256((native / "ramnest-helper").read_bytes()).hexdigest()
            self.assertEqual(before, authority.swift_source(expected, config))
            app = self.root / config / "RAMNest.app"
            authority.embed(output, generated, app)
            self.assertEqual((app / "Contents/Helpers/ramnest-helper").read_bytes(), (native / "ramnest-helper").read_bytes())
            self.assertEqual((app / "Contents/Resources/native-provenance.json").read_bytes(), (native / "provenance.json").read_bytes())
            results[config] = before
        self.assertNotEqual(results["Debug"], results["Release"])

    def test_changed_helper_recomputes_compiled_identity_without_touching_other_configuration(self):
        debug = self.prepare("Debug")
        release = self.prepare("Release")
        for config, paths in [("Debug", debug), ("Release", release)]:
            authority.generate(paths[0], config, paths[1], paths[2])
        previous_debug, previous_release = debug[2].read_bytes(), release[2].read_bytes()
        native, output, generated = debug
        changed = b"changed opaque helper, new final signing bytes"
        (native / "ramnest-helper").write_bytes(changed)
        receipt = json.loads((native / "provenance.json").read_text())
        receipt["helperSHA256"] = hashlib.sha256(changed).hexdigest()
        (native / "provenance.json").write_text(json.dumps(receipt))
        authority.generate(native, "Debug", output, generated)
        self.assertNotEqual(generated.read_bytes(), previous_debug)
        self.assertIn(receipt["helperSHA256"].encode(), generated.read_bytes())
        self.assertEqual(release[2].read_bytes(), previous_release)
        authority.verify(release[1], release[2])

    def test_stale_native_manifest_refuses_generation_and_invalidates_previous_completion(self):
        for config in ["Debug", "Release"]:
            native, output, generated = self.prepare(config)
            authority.generate(native, config, output, generated)
            (native / "ramnest-helper").write_bytes(b"changed without a new native receipt")
            with self.assertRaisesRegex(ValueError, "mismatch"):
                authority.generate(native, config, output, generated)
            self.assertFalse((output / "authority.json").exists())
            with self.assertRaises(ValueError):
                authority.embed(output, generated, self.root / config / "must-not-embed.app")

    def test_package_mutations_refuse_embedding_before_creating_destination(self):
        for config in ["Debug", "Release"]:
            native, output, generated = self.prepare(config)
            for field in ["helper", "receipt", "source", "marker", "shared-source", "configuration"]:
                authority.generate(native, config, output, generated)
                if field == "helper":
                    (output / "ramnest-helper").write_bytes(b"replaced signed helper")
                elif field == "receipt":
                    (output / "provenance.json").write_text('{}')
                elif field == "source":
                    generated.write_bytes(b'let fake = "external override"\n')
                elif field == "shared-source":
                    (output / "NativeHelperBuildIdentity.swift").write_bytes(b"stale compiled source")
                else:
                    path = output / "authority.json"
                    value = json.loads(path.read_text())
                    value["configuration" if field == "configuration" else "helperSHA256"] = "Release" if config == "Debug" else "Debug"
                    path.write_text(json.dumps(value))
                app = self.root / config / (field + ".app")
                with self.assertRaises(ValueError):
                    authority.embed(output, generated, app)
                self.assertFalse(app.exists())

    def test_missing_and_empty_authority_cannot_generate_placeholder(self):
        native, output, generated = self.prepare("Debug")
        (native / "ramnest-helper").unlink()
        with self.assertRaises(ValueError):
            authority.generate(native, "Debug", output, generated)
        self.assertFalse(generated.exists())
        with self.assertRaises(ValueError):
            authority.swift_source("", "Debug")

    def phase(self, target):
        project = (ROOT / "project.yml").read_text()
        section = project.split("  " + target + ":\n", 1)[1]
        body = section.split("        script: |\n", 1)[1].split("        inputFiles:", 1)[0]
        return "\n".join(line[10:] for line in body.splitlines()) + "\n"

    def test_failed_native_producer_cannot_generate_from_coherent_stale_outputs(self):
        native, output, generated = self.prepare("Debug")
        authority.generate(native, "Debug", output, generated)
        project = self.root / "project"
        scripts = project / "scripts"
        scripts.mkdir(parents=True)
        (scripts / "build-native.sh").write_text("#!/bin/bash\nexit 29\n")
        shutil.copyfile(ROOT / "scripts/native-build-authority.py", scripts / "native-build-authority.py")
        temp = self.root / "target-temp"
        temp.mkdir()
        shutil.copytree(native, temp / "ramnest-native-Debug")
        products = self.root / "shared-products"
        products.mkdir()
        shared = products / "RAMNestNativeAuthority-Debug"
        shutil.copytree(output, shared)
        environment = dict(os.environ, PROJECT_DIR=str(project), TEMP_DIR=str(temp),
                           BUILT_PRODUCTS_DIR=str(products), DERIVED_FILE_DIR=str(self.root / "derived"), CONFIGURATION="Debug")
        result = subprocess.run(["/bin/bash", "-c", self.phase("RAMNestCore")], env=environment, capture_output=True)
        self.assertEqual(result.returncode, 29, result.stderr.decode())
        self.assertFalse((shared / "authority.json").exists())

    def test_failed_embed_cannot_be_masked_by_successful_cli_copy(self):
        project = self.root / "project"
        scripts = project / "scripts"
        scripts.mkdir(parents=True)
        (scripts / "native-build-authority.py").write_text("raise SystemExit(31)\n")
        products = self.root / "products"
        products.mkdir()
        (products / "ramnest").write_bytes(b"new CLI fixture")
        app = products / "RAMNest.app"
        helpers = app / "Contents/Helpers"
        helpers.mkdir(parents=True)
        (helpers / "ramnest").write_bytes(b"existing CLI fixture")
        environment = dict(os.environ, PROJECT_DIR=str(project), BUILT_PRODUCTS_DIR=str(products),
                           TARGET_BUILD_DIR=str(products), WRAPPER_NAME="RAMNest.app", CONTENTS_FOLDER_PATH="RAMNest.app/Contents", CONFIGURATION="Debug")
        result = subprocess.run(["/bin/bash", "-c", self.phase("RAMNest")], env=environment, capture_output=True)
        self.assertEqual(result.returncode, 31, result.stderr.decode())
        self.assertEqual((helpers / "ramnest").read_bytes(), b"existing CLI fixture")

    def test_atomic_generation_uses_explicit_declared_staging_directory(self):
        native, output, generated = self.prepare("Debug")
        staging = self.root / "declared-target-temp"
        authority.generate(native, "Debug", output, generated, staging=staging)
        authority.verify(output, generated)
        self.assertEqual(list(staging.iterdir()), [])
        project = (ROOT / "project.yml").read_text()
        self.assertIn('--staging-dir "$TEMP_DIR/ramnest-authority-stage-$CONFIGURATION"', project)
        self.assertIn('$(TEMP_DIR)/ramnest-authority-stage-$(CONFIGURATION)', project)

    def test_real_production_capture_uses_only_compiled_expected_authority(self):
        source = (ROOT / "Sources/RAMNestCore/NativeHelperAuthorization.swift").read_text()
        self.assertIn("NativeHelperBuildIdentity.sha256", source)
        self.assertIn("NativeHelperCompiledAuthority.current.require(pinnedDigest: digest, receipt: receipt)", source)
        self.assertLess(source.index("NativeHelperCompiledAuthority.current.require(pinnedDigest: digest, receipt: receipt)"),
                        source.index("return NativeHelperImage(source: helper"))
        self.assertNotIn("ProcessInfo.processInfo.environment", source)
        dispatch = (ROOT / "Sources/RAMNestCore/NativeTmpfs.swift").read_text()
        self.assertLess(dispatch.index("let image = try NativeHelperImage.capture(helper: helper)"),
                        dispatch.index('Control.run("/usr/bin/osascript"'))
        build = (ROOT / "scripts/build-native.sh").read_text()
        self.assertLess(build.index('/usr/bin/codesign --force --sign -'), build.rindex('python3 "$source_root/scripts/native-provenance.py"'))
        direct = (ROOT / "scripts/build.sh").read_text()
        self.assertLess(direct.index("native-build-authority.py generate"), direct.index("-module-name RAMNestCore"))
        self.assertIn('Sources/RAMNestCore/*.swift "$generated"', direct)
        signing = direct[direct.index("for binary in"):direct.index("; do codesign")]
        self.assertNotIn("ramnest-helper", signing)
        project = (ROOT / "project.yml").read_text()
        core = project.split("  RAMNestCore:\n", 1)[1].split("  ramnest:\n", 1)[0]
        app = project.split("  RAMNest:\n", 1)[1].split("  RAMNestCoreTests:\n", 1)[0]
        self.assertIn("preBuildScripts:", core)
        self.assertIn("native-build-authority.py\" generate", core)
        self.assertIn("type: file\n        optional: true\n        buildPhase: sources", core)
        self.assertIn("$(DERIVED_FILE_DIR)/RAMNestNativeAuthority/NativeHelperBuildIdentity.swift", core)
        self.assertNotIn("preBuildScripts:", app)
        self.assertIn("- target: RAMNestCore", app)
        self.assertIn("native-build-authority.py\" embed", app)
        self.assertIn("ENABLE_USER_SCRIPT_SANDBOXING: YES", project)
        probe = (ROOT / "scripts/native-tmpfs-package-probe.py").read_text()
        self.assertIn('"--store", str(Path(__file__).resolve())', probe)


if __name__ == "__main__":
    unittest.main(verbosity=2)

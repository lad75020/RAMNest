#!/usr/bin/env python3
"""Bind one finalized native helper to compiled Core source and package inputs.

No default/placeholder identity exists. The helper MUST have been built and signed
before generation. This script never builds/signs; the production caller does so
before the native provenance receipt. Fixtures may supply opaque bytes to test
these file/hash transactions without building or executing code.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import tempfile

ENGINE = "native-tmpfs-v1"
VERSION = 1


def sha(data):
    return hashlib.sha256(data).hexdigest()


def regular(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError("Missing/unsafe native authority input: " + str(path))
    return path.read_bytes()


def atomic(path, data, staging=None):
    path.parent.mkdir(parents=True, exist_ok=True)
    # Avoid touching unchanged generated source during an incremental build.
    if path.is_file() and not path.is_symlink() and path.read_bytes() == data:
        return
    # Xcode grants the explicit target-temp staging directory, not arbitrary
    # siblings of individual shared-product outputs. Rename still fails closed
    # if the caller puts staging on a different filesystem.
    temporary = staging if staging is not None else path.parent
    temporary.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".authority-", dir=temporary)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def swift_source(digest, configuration):
    # All substitutions are strict fixed enums or a SHA256, never shell/source text.
    if configuration not in ["Debug", "Release"] or len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
        raise ValueError("Invalid native compiled identity")
    return ("// Generated from the finalized helper BEFORE RAMNestCore compilation. Do not edit.\n"
            "enum NativeHelperBuildIdentity {\n"
            f'    static let engine = "{ENGINE}"\n'
            f'    static let sha256 = "{digest}"\n'
            f'    static let configuration = "{configuration}"\n'
            "}\n").encode()


def generate(native, configuration, output, generated, staging=None):
    marker = output / "authority.json"
    if marker.exists() or marker.is_symlink():
        marker.unlink()
    helper = regular(native / "ramnest-helper")
    receipt_bytes = regular(native / "provenance.json")
    receipt = json.loads(receipt_bytes)
    expected_config = "Debug" if configuration == "Debug" else "RelWithDebInfo"
    if not helper or receipt.get("engine") != ENGINE or receipt.get("configuration") != expected_config or receipt.get("helperSHA256") != sha(helper):
        raise ValueError("Native helper/provenance/configuration mismatch; authority not generated")
    source = swift_source(sha(helper), configuration)
    # Retire the previous completion marker first. A failed build cannot reuse it.
    atomic(output / "ramnest-helper", helper, staging)
    os.chmod(output / "ramnest-helper", 0o755)
    atomic(output / "provenance.json", receipt_bytes, staging)
    atomic(output / "NativeHelperBuildIdentity.swift", source, staging)
    atomic(generated, source, staging)
    atomic(marker, (json.dumps({
        "version": VERSION, "configuration": configuration, "engine": ENGINE,
        "helperSHA256": sha(helper), "provenanceSHA256": sha(receipt_bytes),
        "generatedSourceSHA256": sha(source),
    }, sort_keys=True, indent=2) + "\n").encode(), staging)
    verify(output, generated)


def verify(output, generated):
    authority = json.loads(regular(output / "authority.json"))
    helper = regular(output / "ramnest-helper")
    receipt_bytes = regular(output / "provenance.json")
    receipt = json.loads(receipt_bytes)
    configuration = authority.get("configuration")
    expected_source = swift_source(sha(helper), configuration)
    if (authority.get("version") != VERSION or authority.get("engine") != ENGINE or
        authority.get("helperSHA256") != sha(helper) or receipt.get("helperSHA256") != sha(helper) or
        receipt.get("engine") != ENGINE or
        receipt.get("configuration") != ("Debug" if configuration == "Debug" else "RelWithDebInfo") or
        authority.get("provenanceSHA256") != sha(receipt_bytes) or
        authority.get("generatedSourceSHA256") != sha(expected_source) or
        regular(output / "NativeHelperBuildIdentity.swift") != expected_source or
        regular(generated) != expected_source):
        raise ValueError("Compiled native authority/package inputs are incoherent; embed refused")
    return helper, receipt_bytes


def embed(output, generated, app):
    helper, receipt = verify(output, generated)
    helpers, resources = app / "Contents/Helpers", app / "Contents/Resources"
    helpers.mkdir(parents=True, exist_ok=True)
    resources.mkdir(parents=True, exist_ok=True)
    # These are build products, not durable journals. Write only the two declared
    # Xcode output paths (no undeclared sibling temp files/sandbox exception).
    # A failed/interrupted embed cannot produce a valid signed/coherent package.
    for path, data, mode in [(helpers / "ramnest-helper", helper, 0o755),
                             (resources / "native-provenance.json", receipt, 0o644)]:
        if path.is_symlink():
            raise ValueError("Refusing symlink package output")
        with path.open("wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(path, mode)
    if regular(helpers / "ramnest-helper") != helper:
        raise ValueError("Embedded helper bytes changed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    g = commands.add_parser("generate")
    g.add_argument("native", type=Path)
    g.add_argument("configuration", choices=["Debug", "Release"])
    g.add_argument("output", type=Path)
    g.add_argument("generated", type=Path)
    g.add_argument("--staging-dir", type=Path)
    for name in ["verify", "embed"]:
        p = commands.add_parser(name)
        p.add_argument("output", type=Path)
        p.add_argument("generated", type=Path)
        if name == "embed":
            p.add_argument("app", type=Path)
    args = parser.parse_args()
    if args.command == "generate":
        generate(args.native, args.configuration, args.output, args.generated, args.staging_dir)
    elif args.command == "verify":
        verify(args.output, args.generated)
    else:
        embed(args.output, args.generated, args.app)


if __name__ == "__main__":
    main()

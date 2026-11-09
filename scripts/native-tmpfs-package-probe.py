#!/usr/bin/env python3
"""Parent-only exact-package probe. Creates fresh owned fixtures; never installs.

Requires interactive one-shot macOS administrator dialogs. No automatic cleanup
on failure: retain the generated source/store/journals and inspect the exact slot.
"""
import argparse
import ctypes
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shlex
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import time
import uuid



class DarwinXattrs:
    """Bounded Darwin xattr ABI, also available when Python omits os.*xattr."""
    def __init__(self):
        require(sys.platform == "darwin", "This exact-package probe requires macOS")
        self.libc = ctypes.CDLL(None, use_errno=True)
        self.get = self.libc.getxattr
        self.get.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
        self.get.restype = ctypes.c_ssize_t
        self.set = self.libc.setxattr
        self.set.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
        self.set.restype = ctypes.c_int

    def getxattr(self, path, name):
        size = self.get(os.fsencode(path), name.encode("utf-8"), None, 0, 0, 0)
        if size < 0:
            raise OSError(ctypes.get_errno(), "Darwin getxattr", str(path))
        require(size <= 1 << 20, "Fixture xattr exceeds bounded read limit")
        buffer = ctypes.create_string_buffer(max(1, size))
        actual = self.get(os.fsencode(path), name.encode("utf-8"), buffer, size, 0, 0)
        if actual < 0:
            raise OSError(ctypes.get_errno(), "Darwin getxattr", str(path))
        require(actual == size, "Fixture xattr changed during read")
        return buffer.raw[:actual]

    def setxattr(self, path, name, value):
        require(isinstance(value, bytes) and len(value) <= 1 << 20, "Invalid fixture xattr")
        buffer = ctypes.create_string_buffer(value)
        if self.set(os.fsencode(path), name.encode("utf-8"), buffer, len(value), 0, 0) != 0:
            raise OSError(ctypes.get_errno(), "Darwin setxattr", str(path))


XATTRS = None  # Initialized/preflighted before any fixture is created.


def preflight_apis():
    global XATTRS
    XATTRS = DarwinXattrs()
    for name in ["statvfs", "chflags", "link", "symlink", "fsync", "ftruncate"]:
        require(callable(getattr(os, name, None)), "Missing fixture API: os." + name)
    require(all(hasattr(stat, name) for name in ["UF_HIDDEN", "UF_NODUMP"]), "Missing Darwin BSD flag constants")
    for executable in ["/usr/bin/otool", "/usr/bin/vm_stat", "/sbin/mount", "/usr/bin/osascript"]:
        require(os.access(executable, os.X_OK), "Missing probe utility: " + executable)

def mapping_worker(path):
    """Real fd-closed MAP_SHARED mapping; Python mmap would duplicate the fd."""
    libc = ctypes.CDLL(None, use_errno=True)
    libc.mmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_longlong]
    libc.mmap.restype = ctypes.c_void_p
    libc.munmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
    fd = os.open(path, os.O_RDWR)
    address = libc.mmap(None, 32768, 3, 1, fd, 0)  # PROT_READ|WRITE, MAP_SHARED
    os.close(fd)
    if address == ctypes.c_void_p(-1).value:
        raise OSError(ctypes.get_errno(), "mmap")
    try:
        print("READY", flush=True)
        for line in sys.stdin:
            if line.strip() == "write":
                ctypes.memmove(address, b"mapped-write", 12)
                print("WROTE", flush=True)
            if line.strip() == "close":
                break
    finally:
        if libc.munmap(address, 32768) != 0:
            raise OSError(ctypes.get_errno(), "munmap")


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def real_owned_parent(value):
    path = Path(value).absolute()
    require(path == path.resolve(), "Scratch parent must be canonical, with no symlink ancestors")
    s = path.lstat()
    require(stat.S_ISDIR(s.st_mode) and s.st_uid == os.getuid(), "Scratch parent must already be an owned directory")
    return path


def allocation(path):
    fs = os.statvfs(path)
    size = fs.f_frsize or fs.f_bsize
    return {"used": (fs.f_blocks - fs.f_bfree) * size, "capacity": fs.f_blocks * size}


def physical_context():
    result = subprocess.run(["/usr/bin/vm_stat"], capture_output=True, text=True, timeout=10)
    return {"exit": result.returncode, "vm_stat": result.stdout, "stderr": result.stderr,
            "interpretation": "Shared-host context only; not isolated physical RAM attribution or proof of zero swap"}


def dynamic_content_probe(source, result):
    target = source / ".owned-allocation-probe"
    require(not target.exists(), "Allocation probe collision")
    readings = [{"phase": "empty", **allocation(source), "host": physical_context()}]
    with target.open("xb") as stream:
        for _ in range(16):
            stream.write(os.urandom(1 << 20))
        stream.flush()
        os.fsync(stream.fileno())
    readings.append({"phase": "16MiB", **allocation(source), "host": physical_context()})
    with target.open("r+b") as stream:
        stream.truncate(4 << 20)
        stream.flush()
        os.fsync(stream.fileno())
    readings.append({"phase": "truncate4MiB", **allocation(source), "host": physical_context()})
    pinned = os.open(target, os.O_RDONLY)
    try:
        target.unlink()
        held = allocation(source)
        readings.append({"phase": "unlinked-fd-held", **held, "host": physical_context()})
        require(held["used"] >= readings[2]["used"] - (1 << 20), "Open-unlinked native data was not retained as expected")
    finally:
        os.close(pinned)
    for _ in range(30):
        deleted = allocation(source)
        if deleted["used"] < readings[2]["used"] - (1 << 20):
            break
        time.sleep(0.1)
    readings.append({"phase": "last-close", **deleted, "host": physical_context()})
    result.append(readings)
    require(len({r["capacity"] for r in readings}) == 1, "Mounted capacity changed unexpectedly")
    require(readings[1]["used"] > readings[0]["used"] + (8 << 20), "Native allocation did not grow with written content")
    require(readings[2]["used"] < readings[1]["used"] - (4 << 20), "Truncation did not release native filesystem allocation")
    require(readings[4]["used"] < readings[2]["used"] - (1 << 20), "Deletion did not release native filesystem allocation")


def validate_metadata(source, expected_payload, initial_inode=None, native=False):
    require((source / "payload").read_bytes() == expected_payload, "Payload differs")
    require((source / "hardlink").stat().st_ino == (source / "payload").stat().st_ino, "Hardlink class split")
    require(os.readlink(source / "sym") == "payload", "Symlink target changed")
    require(stat.S_IMODE(source.stat().st_mode) == 0o750, "Root mode changed")
    require(stat.S_IMODE((source / "payload").stat().st_mode) == 0o640, "File mode changed")
    require(XATTRS.getxattr(source, "com.ramnest.fixture") == b"root-metadata", "Root xattr changed")
    require(XATTRS.getxattr(source / "payload", "com.ramnest.fixture") == b"file-metadata", "File xattr changed")
    require((source / "payload").stat().st_flags & (stat.UF_HIDDEN | stat.UF_NODUMP) == stat.UF_HIDDEN | stat.UF_NODUMP, "BSD flags changed")
    sparse = (source / "sparse").stat()
    require(sparse.st_size == (8 << 20) + 4, "Sparse logical size changed")
    if not native:
        require(sparse.st_blocks * 512 < sparse.st_size // 2, "Restored disk sparse data was materialized densely")
    with (source / "sparse").open("rb") as stream:
        require(stream.read(4096) == bytes(4096), "Sparse hole does not read as zero")
        stream.seek(8 << 20)
        require(stream.read() == b"tail", "Sparse tail changed")
    if initial_inode is not None:
        require(source.stat().st_ino == initial_inode, "Temporary mode did not restore original root inode")


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--mapping-worker":
        mapping_worker(sys.argv[2])
        return
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True, help="Exact NEW candidate RAMNest.app from parent Xcode/package workflow")
    parser.add_argument("--scratch-parent", required=True, help="Existing owned canonical disposable parent; a new child is created")
    parser.add_argument("--ack-admin-prompts", action="store_true", help="Explicitly run administrator-authorized disposable native lifecycle operations")
    parser.add_argument("--force-loss", action="store_true", help="Also force-unmount ONLY a newly generated fixture to verify loss disclosure/checkpoint-only recovery")
    args = parser.parse_args()
    require(args.ack_admin_prompts, "Pass --ack-admin-prompts only when the parent is ready to authorize the exact candidate fixture")
    preflight_apis()
    app = args.app.absolute()
    require(app == app.resolve() and app.suffix == ".app", "Use a canonical candidate app path")
    cli, helper = app / "Contents/Helpers/ramnest", app / "Contents/Helpers/ramnest-helper"
    require(cli.is_file() and helper.is_file(), "Candidate lacks its embedded CLI/helper")
    # Read linked constants without opening any store. The old candidate cannot
    # satisfy this gate merely by replacing a mutable provenance resource.
    # An old CLI may open its store before rejecting an unknown command. Give it
    # an existing regular file as an intentionally unusable explicit store, so it
    # cannot reach a default/user store. The new diagnostic opens no store at all.
    compiled = json.loads(subprocess.check_output([str(cli), "--store", str(Path(__file__).resolve()),
                                                   "native-build-identity", "--json"], text=True))
    receipt = json.loads((app / "Contents/Resources/native-provenance.json").read_text())
    require(compiled["engine"] == receipt["engine"] == "native-tmpfs-v1" and compiled["sha256"] == sha(helper) == receipt["helperSHA256"],
            "Final embedded helper/provenance do not match compiled CLI authority")
    require(compiled["configuration"] in ["Debug", "Release"] and receipt["configuration"] == ("Debug" if compiled["configuration"] == "Debug" else "RelWithDebInfo"),
            "Compiled native configuration differs from packaged receipt")
    require(subprocess.check_output([str(helper), "--capabilities"], text=True).strip() == "native-tmpfs-v1", "Wrong helper protocol")
    dependencies = subprocess.check_output(["/usr/bin/otool", "-L", str(helper)], text=True)
    require("fuse" not in dependencies.lower(), "Production helper still depends on FUSE")
    parent = real_owned_parent(args.scratch_parent)
    root = Path(tempfile.mkdtemp(prefix="ramnest-native-package-", dir=parent))
    evidence = {"root": str(root), "app": str(app), "cliSHA256": sha(cli), "helperSHA256": sha(helper), "compiledAuthority": compiled,
                "helperDependencies": dependencies, "commands": [], "allocation": [], "cycles": [], "complete": False}
    report = root / "evidence.json"
    print("Owned evidence fixture:", root, flush=True)
    def persist():
        report.write_text(json.dumps(evidence, indent=2) + "\n")
    try:
        for mode in ["sync", "temporary"]:
            fixture = root / mode
            fixture.mkdir(mode=0o700)
            source = fixture / "Source ' space & Unicode é"
            source.mkdir(mode=0o750)
            os.chmod(source, 0o750)
            initial = os.urandom(65536)
            (source / "payload").write_bytes(initial)
            os.chmod(source / "payload", 0o640)
            os.link(source / "payload", source / "hardlink")
            os.symlink("payload", source / "sym")
            with (source / "sparse").open("xb") as stream:
                stream.seek(8 << 20)
                stream.write(b"tail")
                stream.flush()
                os.fsync(stream.fileno())
                # Darwin sys/fcntl.h: F_PUNCHHOLE=99, fpunchhole_t is
                # {uint32 flags, uint32 reserved, off_t offset, off_t length}.
                # APFS may materialize seek-created gaps on flush; establish
                # a genuinely sparse original before testing its preservation.
                fcntl.fcntl(stream.fileno(), 99, struct.pack("IIqq", 0, 0, 0, 8 << 20))
                os.fsync(stream.fileno())
            (source / "mapped").write_bytes(bytes(32768))
            XATTRS.setxattr(source, "com.ramnest.fixture", b"root-metadata")
            XATTRS.setxattr(source / "payload", "com.ramnest.fixture", b"file-metadata")
            os.chflags(source / "payload", stat.UF_HIDDEN | stat.UF_NODUMP)
            validate_metadata(source, initial)
            initial_inode = source.stat().st_ino
            original_file_inode = (source / "payload").stat().st_ino
            store = fixture / "store"
            def command(*parts, expected=0):
                result = subprocess.run([str(cli), "--store", str(store), *map(str, parts)], capture_output=True, text=True, timeout=900)
                evidence["commands"].append({"mode": mode, "args": list(map(str, parts)), "exit": result.returncode,
                                             "stdout": result.stdout, "stderr": result.stderr})
                persist()
                require(result.returncode == expected, "CLI did not return expected exit code: " + str(parts) + "\n" + result.stderr)
                return result
            create = ["create", source, "--size", "128MB", "--name", mode, "--no-mount", "--no-mount-at-launch", "--json"]
            if mode == "temporary":
                create.append("--no-sync-folder")
            folder = json.loads(command(*create).stdout)
            ref = folder["id"]
            def info():
                return json.loads(command("info", ref, "--json").stdout)
            expected_disk = initial
            for cycle in range(2):
                print(mode, "mount cycle", cycle + 1, flush=True)
                command("mount", ref)
                current = info()
                j = current["journal"]
                require(j["backend"] == "tmpfs" and "fsKitLink" not in j and j["nativeLink"]["version"] == 2, "Native layout discriminator is wrong")
                sid = j["session"]
                require(str(uuid.UUID(sid)).upper() == sid, "Noncanonical session")
                mount = Path(f"/Users/Shared/RAMNestNative-{os.getuid()}") / sid / "mount"
                require(j["nativeLink"]["mountPath"] == str(mount / "tree/data"), "Unexpected physical data path")
                require(source.is_symlink() and os.readlink(source) == str(mount / "tree/data"), "Original path link is not journal-bound")
                require((mount / ".fseventsd").parent != source.resolve(), "OS root metadata leaked into logical tree")
                require(not (source / ".fseventsd").exists(), "OS root metadata appeared in logical tree")
                mounts = subprocess.check_output(["/sbin/mount"], text=True)
                require(any(" on " + str(mount) + " (tmpfs" in line for line in mounts.splitlines()), "Physical mount is not native tmpfs")
                for forbidden in [b"freeze\n", b"export3\t/arbitrary/store\n", b"period\t5;id\n"]:
                    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as channel:
                        channel.settimeout(3)
                        channel.connect(j["socket"])
                        channel.sendall(forbidden)
                        require(channel.recv(8192) == b"ERR\t22\n", "Native pin accepted a nonallowlisted command")
                holding = Path(j["nativeLink"]["holdingPath"]) / "data"
                require((holding / "payload").read_bytes() == expected_disk, "Retained original changed during population")
                if mode == "temporary":
                    require((holding / "payload").stat().st_ino == original_file_inode, "Original inode was not retained")
                validate_metadata(source, expected_disk, native=True)
                if cycle == 0:
                    old_socket = j["socket"]
                    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as channel:
                        channel.settimeout(3); channel.connect(old_socket); channel.sendall(b"retire\n")
                        require(channel.recv(8192) == b"OK\n", "Pin retirement failed")
                    command("reconnect", ref)
                    resumed = info()["journal"]
                    require(resumed["nativeTmpfs"]["filesystem"] == j["nativeTmpfs"]["filesystem"] and resumed["socket"] != old_socket, "Reconnect changed kernel identity or reused an old socket")
                    j = resumed
                dynamic_content_probe(source, evidence["allocation"])
                changed = (mode + "-cycle-" + str(cycle)).encode().ljust(65536, b"x")
                (source / "payload").write_bytes(changed)
                if mode == "sync" and cycle == 0:
                    worker = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "--mapping-worker", str(source / "mapped")],
                                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                    try:
                        require(worker.stdout.readline().strip() == "READY", "fd-closed mapping worker did not start")
                        before = info()["journal"]["revision"]
                        rejected = command("save", ref, expected=78)
                        require("regular files or shared mappings remain open" in rejected.stderr, "Save failed for a reason other than the mandatory mapping detector")
                        require(info()["journal"]["revision"] == before, "Rejected mapping scan promoted a checkpoint")
                        # Ignore Busy MUST encounter the same nonbypassable gate.
                        command("unmount", ref, "--ignore-busy", expected=78)
                        worker.stdin.write("write\n"); worker.stdin.flush()
                        require(worker.stdout.readline().strip() == "WROTE", "Failed save did not restore writable native state")
                    finally:
                        worker.communicate("close\n", timeout=15)
                        require(worker.returncode == 0, "Mapping worker did not close normally")
                if mode == "sync":
                    command("save", ref)
                else:
                    command("save", ref, expected=64)
                    export = fixture / f"live-export-{cycle}"
                    command("export", ref, export, "--live")
                    validate_metadata(export, changed)
                # Eject must capture a subsequent change, never reuse a stale save.
                final = changed[:-4] + b"late"
                (source / "payload").write_bytes(final)
                before_capacity = info()["folder"]["capacity"]
                command("resize", ref, "--size", "192MB", expected=64)
                require(info()["folder"]["capacity"] == before_capacity, "Rejected live resize changed configuration")
                command("unmount", ref, "--ignore-busy")
                after = info()
                require(after["journal"]["phase"] == "idle" and not source.is_symlink(), "Eject did not restore the original path")
                expected_disk = final if mode == "sync" else initial
                validate_metadata(source, expected_disk, initial_inode if mode == "temporary" else None)
                require(not mount.parent.exists(), "Owned native runtime slot was not released")
                leftovers = [p.name for p in fixture.iterdir() if p.name.startswith(".ramnest-" + ref + "-")]
                require(not leftovers, "Owned original/staging/link cleanup is incomplete: " + repr(leftovers))
                evidence["cycles"].append({"mode": mode, "cycle": cycle + 1, "session": sid, "restored": True, "slotReleased": True})
                persist()
            if mode == "sync" and args.force_loss:
                command("mount", ref)
                checkpoint = info()["journal"]["revision"]
                # New mount's initial capture is a committed disk checkpoint.
                lost = info()["journal"]
                mount = Path(f"/Users/Shared/RAMNestNative-{os.getuid()}") / lost["session"] / "mount"
                require(lost["nativeLink"]["mountPath"] == str(mount / "tree/data"), "Force-loss target is not the fresh fixture")
                require(mount.parent.parent.lstat().st_uid == 0 and mount.parent.lstat().st_uid == 0, "Unsafe native parent")
                (source / "unsaved-loss-sentinel").write_bytes(b"intentionally lost fixture only")
                shell = "/sbin/umount -f " + shlex.quote(str(mount))
                literal = shell.replace("\\", "\\\\").replace('"', '\\"')
                subprocess.run(["/usr/bin/osascript", "-e", 'do shell script "' + literal + '" with administrator privileges'], check=True, timeout=180)
                result = subprocess.run([str(cli), "--store", str(store), "export", ref, str(fixture / "must-not-export-lost"), "--live"], capture_output=True, text=True, timeout=30)
                require(result.returncode != 0 and not (fixture / "must-not-export-lost").exists(), "Lost RAM was exported as a live tree")
                require(info()["journal"]["revision"] == checkpoint, "Lost-RAM operation changed the committed checkpoint")
                command("internal-finalize", ref, expected=6)
                command("recover", ref)
                restored = info()
                require(restored["journal"]["nativeTmpfs"].get("lossDisclosure"), "External loss was not disclosed")
                require(not (source / "unsaved-loss-sentinel").exists(), "Recovered a vanished unsaved sentinel unexpectedly")
                validate_metadata(source, expected_disk)
                require(not mount.parent.exists(), "Force-loss recovery left owned slot")
                evidence["forcedLoss"] = {"checkpoint": checkpoint, "disclosed": True}
        evidence["complete"] = True
        persist()
        print("Verified exact-package native lifecycle evidence:", report)
    except BaseException as error:
        evidence["failure"] = str(error)
        persist()
        print("FAILED; retained owned fixture and recovery evidence:", root, file=sys.stderr)
        print("Inspect evidence.json and its journal-bound native slot. No automatic force-unmount or recursive cleanup was performed.", file=sys.stderr)
        raise


if __name__ == "__main__":
    main()

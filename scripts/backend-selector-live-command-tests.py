#!/usr/bin/env python3
"""No-mount command/journal immutability check; reports a sandbox bind denial."""
import errno
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import threading
import uuid

project = Path(__file__).resolve().parent.parent
artifacts = project / "artifacts/backend-selector"
root = artifacts / "command-fixtures" / str(uuid.uuid4())
root.mkdir(parents=True, mode=0o700)
# Match UUID.uuidString, the format written by the production Swift encoder.
folder_id = str(uuid.uuid4()).upper()
volume = root / "volumes" / folder_id
(root / "volumes").mkdir(mode=0o700)
volume.mkdir(mode=0o700)
(volume / "revisions").mkdir(mode=0o700)
os.chdir(artifacts)
path = Path("probe-" + uuid.uuid4().hex[:8] + ".sock")
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    server.bind(str(path))
except OSError as error:
    server.close()
    if error.errno not in (errno.EPERM, errno.EACCES):
        raise
    (artifacts / "command-result.json").write_text(json.dumps({"status":"skipped", "reason":"sandbox AF_UNIX bind denial", "errno":error.errno}) + "\n")
    print(f"SKIP live-command recorder: sandbox denied project-local AF_UNIX bind ({error.errno}); run this focused script on parent host")
    sys.exit(0)
server.listen(4)
server.settimeout(0.1)
requests = []
stopped = threading.Event()
def record():
    while not stopped.is_set():
        try:
            client, _ = server.accept()
        except socket.timeout:
            continue
        with client:
            client.settimeout(3)
            frame = b""
            while not frame.endswith(b"\n"):
                part = client.recv(8192)
                if not part:
                    break
                frame += part
            requests.append(frame)
            client.sendall(f"OK\t{folder_id}\t{os.getpid()}\tmounted\t0\t16777216\tactive\n".encode())
thread = threading.Thread(target=record)
thread.start()
try:
    # Prove that the recorder catches a real command before checking silence.
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as probe:
        probe.connect(str(path)); probe.sendall(b"recorder-check\n"); probe.recv(8192)
    assert requests == [b"recorder-check\n"]
    requests.clear()
    options = dict(compression=True, mountAtLaunch=True, nobrowse=True, sync=True,
                   periodicSave=False, intervalMinutes=15, comparison="checksum")
    config = dict(version=1, menuBarMode=True, backend="fskit", folders=[dict(
        id=folder_id, name="Live fixture", path=str(root / "selected"),
        capacity=16777216, device=1, inode=2, options=options)])
    configuration = root / "configuration.json"
    configuration.write_text(json.dumps(config))
    journal = volume / "journal.json"
    journal.write_text(json.dumps(dict(phase="mounted", session=str(uuid.uuid4()),
        backend="fskit", socket=str(path), populationVerified=True,
        evacuatedEntries=[], restoredEntries=[], updated=0)))
    before = journal.read_bytes()
    for backend in ("nfs", "fskit", "smb"):
        subprocess.run([str(artifacts / "build/backend-selector-tests"), "--set-backend",
                        str(root), backend], check=True, timeout=10)
        assert journal.read_bytes() == before
        saved = json.loads(configuration.read_text())
        assert saved == dict(config, backend=backend)
    assert not requests, requests
    (artifacts / "command-result.json").write_text(json.dumps({"status":"passed", "requests":len(requests)}) + "\n")
    print("PASS setBackend: three real subprocess saves, zero live helper commands, journal bytes unchanged; calibrated AF_UNIX recorder")
finally:
    stopped.set(); thread.join(timeout=4); server.close(); path.unlink(missing_ok=True)

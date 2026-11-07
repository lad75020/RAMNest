#!/usr/bin/env python3
"""Focused real AF_UNIX regression. No mounts or user repository access.

Build ControlTestClient.swift against RAMNestCore and the normal native control
test target first; pass both binary paths. Fixtures and logs stay in --root.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import threading
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--client", type=Path, required=True)
parser.add_argument("--native", type=Path, required=True)
parser.add_argument("--root", type=Path, default=Path("artifacts/helper-timeout-fix"))
parser.add_argument("--socketpair", action="store_true", help="Use anonymous AF_UNIX pairs if pathname bind is sandboxed")
args = parser.parse_args()
args.root = args.root.resolve()
args.client = args.client.resolve()
args.native = args.native.resolve()
run = args.root / f"socket-run-{time.time_ns()}"
run.mkdir(parents=True)
results = []


def address():
    path = args.root / f"t{os.getpid()}-{len(results)}.sock"
    assert len(os.fsencode(path)) < 104, path
    return str(path)


def client(path, command, timeout=1):
    connection = path if isinstance(path, socket.socket) else None
    fd = connection.fileno() if connection else None
    address = f"fd:{fd}" if connection else path
    process = subprocess.Popen([str(args.client), address, command, str(timeout)],
                               pass_fds=(fd,) if connection else (),
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if connection:
        connection.close()  # EOF must reflect the child, not a retained parent fd.
    return process


def complete(process, expected=None, maximum=10):
    output, _ = process.communicate(timeout=maximum)
    if expected is None:
        assert process.returncode == 0 and output.startswith("OK"), output
    else:
        assert process.returncode == 1 and expected in output, output
        assert "Helper " in output and "UNEXPECTED_ERROR" not in output, output
    return output


def record(name, started, output, **extra):
    result = dict(name=name, elapsed_seconds=round(time.monotonic()-started, 3),
                  response=output.strip()[:300], **extra)
    results.append(result)
    print(f"PASS {name}: {result['elapsed_seconds']}s {result['response'][:140]}", flush=True)


def fake(name, frames, expected=None, command="populate", timeout=1,
         minimum=0, maximum=1.7, interrupt=False):
    if args.socketpair:
        path, server = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
    else:
        path = address()
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(path)
        server.listen(1)
    accepted = threading.Event()
    errors = []

    def serve():
        try:
            conn = server if args.socketpair else server.accept()[0]
            with conn:
                request = b""
                while not request.endswith(b"\n"):
                    request += conn.recv(8192)
                assert request == (command+"\n").encode(), request
                accepted.set()
                for delay, frame in frames:
                    time.sleep(delay)
                    if frame:
                        conn.sendall(frame)
        except (BrokenPipeError, ConnectionResetError):
            pass  # Expected when the deadline closes an unfinished stream.
        except BaseException as error:
            errors.append(error)
        finally:
            server.close()

    worker = threading.Thread(target=serve)
    worker.start()
    started = time.monotonic()
    process = client(path, command, timeout)
    stop = threading.Event()

    def signals():
        assert accepted.wait(2)
        while not stop.wait(.025):
            try:
                os.kill(process.pid, signal.SIGUSR1)
            except ProcessLookupError:
                return

    interrupter = threading.Thread(target=signals) if interrupt else None
    if interrupter:
        interrupter.start()
    try:
        output = complete(process, expected)
        elapsed = time.monotonic()-started
        assert minimum <= elapsed <= maximum, (name, elapsed, output)
        record(name, started, output)
    finally:
        stop.set()
        if interrupter:
            interrupter.join(2)
        worker.join(5)
        assert not worker.is_alive(), name
        if not args.socketpair:
            os.unlink(path)
    assert not errors, errors


def raw_request(path, request, timeout=8, incomplete=False):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
        conn.settimeout(timeout)
        conn.connect(path)
        conn.sendall(request)
        if incomplete:
            conn.shutdown(socket.SHUT_WR)
        output = b""
        while not output.endswith(b"\n"):
            frame = conn.recv(8192)
            if not frame:
                break
            output += frame
        return output


def production_pair(mode, leave=False, incomplete=False, kill=False, operation=None):
    caller, peer = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
    fixture = run / f"{len(results)}-{mode}"
    helper = subprocess.Popen([str(args.native), "--connected-fixture", mode, str(peer.fileno()), str(fixture)],
                              pass_fds=(peer.fileno(),), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    peer.close()
    started = time.monotonic()
    elapsed = None
    operation = operation or ("populate" if "populate" in mode else "quiesce" if "quiesce" in mode else "export")
    command = operation if operation == "populate" else operation+"\t"+str(fixture/"stage-result")
    if operation == "populate2":
        deadline = time.monotonic()+5
        while not (fixture/"modes.bin").exists():
            assert time.monotonic()<deadline, "format-2 population fixture did not become ready"
            time.sleep(.01)
        command = "populate2\t"+hashlib.sha256((fixture/"modes.bin").read_bytes()).hexdigest()
    try:
        if leave or incomplete:
            caller.settimeout(3)
            caller.sendall((command+("" if incomplete else "\n")).encode())
            if incomplete:
                caller.shutdown(socket.SHUT_WR)
                assert caller.recv(8192) == b""
            else:
                assert caller.recv(8192).startswith(b"PROGRESS\t")
            caller.close()
            output = "incomplete request was not executed" if incomplete else "client left after real progress; worker retained"
        else:
            process = client(caller, command)
            if kill:
                time.sleep(.35)
                helper.kill()
                output = complete(process, "disconnected")
                assert time.monotonic()-started < 1.5
                helper.communicate(timeout=3)
                record("killed-production-peer", started, output, boundary="AF_UNIX socketpair")
                return
            expected = "timed out waiting for progress" if mode.startswith("stall") else "rejected operation" if mode.startswith("error") else None
            output = complete(process, expected)
            if operation in ("export2", "quiesce2", "export3", "quiesce3") and expected is None:
                fields = output.removeprefix("OK ").strip().split("\t")
                assert len(fields) == (6 if operation.endswith("3") else 5) and int(fields[0]) > 0 and fields[1] == "exported" and int(fields[2]) > 0 and int(fields[3]) == 0 and fields[4], output
                if operation.endswith("3"):
                    assert len(fields[5]) == 64 and all(c in "0123456789abcdef" for c in fields[5]), output
                    assert fields[5] == hashlib.sha256((fixture/"stage-result.modes").read_bytes()).hexdigest(), output
            elapsed = time.monotonic()-started
            if mode.startswith("slow"):
                assert elapsed > 1.5, (mode, elapsed)
            if mode.startswith("stall"):
                assert .8 < elapsed < 1.6, (mode, elapsed)
        # serveControl returns only after the job finishes, even after client
        # EOF/timeout. Native assertions verify exact retained/exported bytes.
        native_output, _ = helper.communicate(timeout=10)
        (fixture/"native-result.log").write_text(native_output)
        assert helper.returncode == 0 and "PASS production Unix control" in native_output, native_output
        record(operation+"-"+mode+("-leave" if leave else ""), started, output,
               native=native_output.strip(), fixture=str(fixture), boundary="AF_UNIX socketpair",
               client_elapsed_seconds=round(elapsed, 3) if elapsed is not None else None)
    finally:
        caller.close()
        if helper.poll() is None:
            helper.kill()
            helper.communicate(timeout=3)


def production(mode, leave=False, queued_probe=False, incomplete=False, kill=False, operation=None):
    if args.socketpair:
        return production_pair(mode, leave=leave, incomplete=incomplete, kill=kill, operation=operation)
    path = address()
    fixture = run / f"{len(results)}-{mode}"
    helper = subprocess.Popen([str(args.native), "--socket-fixture", mode, path, str(fixture)],
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    connection = None
    try:
        ready_by = time.monotonic()+5
        while not os.path.exists(path):
            assert helper.poll() is None, helper.communicate()[0]
            assert time.monotonic() < ready_by, "fixture server did not become ready"
            time.sleep(.01)
        operation = operation or ("populate" if "populate" in mode else "quiesce" if "quiesce" in mode else "export")
        command = operation if operation == "populate" else operation+"\t"+str(fixture/"stage-result")
        if operation == "populate2":
            command = "populate2\t"+hashlib.sha256((fixture/"modes.bin").read_bytes()).hexdigest()
        started = time.monotonic()
        elapsed = None
        if incomplete:
            assert raw_request(path, command.encode(), incomplete=True) == b""
            output = "incomplete command was not executed"
        elif leave:
            connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            connection.settimeout(2)
            connection.connect(path)
            connection.sendall((command+"\n").encode())
            assert connection.recv(8192).startswith(b"PROGRESS\t")
            connection.close()
            output = "client left after real progress; worker retained"
        else:
            process = client(path, command)
            if kill:
                time.sleep(.35)
                helper.kill()  # Only our generated-data fixture process.
                output = complete(process, "disconnected")
                assert time.monotonic()-started < 1.5
                helper.communicate(timeout=3)
                record("killed-production-peer", started, output)
                return
            if queued_probe:
                time.sleep(.2)
                probe_started = time.monotonic()
                # Status has an independent authenticated worker now. Prove it
                # replies while export is still running; retain the separate
                # stalled-peer two-second deadline regression below.
                probe_output = complete(client(path, "status"))
                assert time.monotonic()-probe_started < 1.6, probe_output
                fields = probe_output.removeprefix("OK ").strip().split("\t")
                assert len(fields) == 6 and fields[0] == "12345678-1234-1234-1234-123456789ABC", probe_output
                assert int(fields[1]) == helper.pid and fields[2] == "retained" and fields[5] == "active", probe_output
                assert 0 <= int(fields[3]) <= int(fields[4]) == 16*1024*1024, probe_output
                assert process.poll() is None, "status did not complete until after export"
            expected = "timed out waiting for progress" if mode.startswith("stall") else "rejected operation" if mode.startswith("error") else None
            output = complete(process, expected)
            if operation in ("export2", "quiesce2", "export3", "quiesce3") and expected is None:
                fields = output.removeprefix("OK ").strip().split("\t")
                assert len(fields) == (6 if operation.endswith("3") else 5) and int(fields[0]) > 0 and fields[1] == "exported" and int(fields[2]) > 0 and int(fields[3]) == 0 and fields[4], output
                if operation.endswith("3"):
                    assert len(fields[5]) == 64 and all(c in "0123456789abcdef" for c in fields[5]), output
                    assert fields[5] == hashlib.sha256((fixture/"stage-result.modes").read_bytes()).hexdigest(), output
            elapsed = time.monotonic()-started
            if mode.startswith("slow"):
                assert elapsed > 1.5, (mode, elapsed)
            if mode.startswith("stall"):
                assert .8 < elapsed < 1.6, (mode, elapsed)
        # Wait for the fixture observer to publish its retained state after the
        # worker finishes. Independent connection workers can now deliver retire
        # before that observer runs; EBUSY there is correct, not lost work.
        # Native assertions still prove retained bytes and serialized mutations.
        time.sleep(.05)
        deadline = time.monotonic()+12
        while True:
            status = raw_request(path, b"status\n").decode().strip().split("\t")
            if len(status) == 7 and status[3] == "retained":
                break
            assert time.monotonic() < deadline, status
            time.sleep(.01)
        # Mutations now fail explicitly with EBUSY rather than queuing behind
        # unfinished work. Retry only that rejection within the fixture bound;
        # the native byte/metadata assertions must still pass after completion.
        retire_deadline = time.monotonic()+12
        while True:
            retire = raw_request(path, b"retire\n")
            if retire == b"OK\n":
                break
            assert retire == b"ERR\t16\n", retire
            assert helper.poll() is None and time.monotonic() < retire_deadline, "worker stayed busy"
            time.sleep(.01)
        assert retire == b"OK\n", retire
        native_output, _ = helper.communicate(timeout=10)
        (fixture/"native-result.log").write_text(native_output)
        assert helper.returncode == 0 and "PASS production Unix control" in native_output, native_output
        record(operation+"-"+mode+("-leave" if leave else "")+("-responsive-status" if queued_probe else ""),
               started, output, native=native_output.strip(), fixture=str(fixture),
               client_elapsed_seconds=round(elapsed, 3) if elapsed is not None else None)
    finally:
        if connection:
            connection.close()
        if helper.poll() is None:
            helper.kill()
            helper.communicate(timeout=3)
        if os.path.exists(path):
            os.unlink(path)



def lost_incremental_ack(operation):
    # Relay actual production progress, but drop its completed final ACK. The
    # Swift client must fail closed even though native export/data checks pass.
    upstream, peer = socket.socketpair()
    caller, relay = socket.socketpair()
    fixture = run / f"{len(results)}-{operation}-lost-ack"
    mode = "slow-quiesce" if operation.startswith("quiesce") else "slow-export"
    helper = subprocess.Popen([str(args.native), "--connected-fixture", mode, str(peer.fileno()), str(fixture)],
                              pass_fds=(peer.fileno(),), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    peer.close()
    started = time.monotonic()
    process = client(caller, operation+"\t"+str(fixture/"stage-result"))
    progress = 0
    final = None
    try:
        relay.settimeout(8)
        upstream.settimeout(8)
        request = b""
        while not request.endswith(b"\n"):
            chunk = relay.recv(8192)
            assert chunk, "client disconnected before request"
            request += chunk
        upstream.sendall(request)
        with upstream.makefile("rb") as frames:
            for frame in frames:
                if frame.startswith(b"PROGRESS\t"):
                    progress += 1
                    relay.sendall(frame)
                else:
                    assert frame.startswith(b"OK\t") and b"\texported\t" in frame, frame
                    final = frame
        assert progress > 0 and final is not None, (progress, final)
        relay.close()
        output = complete(process, "disconnected before a final reply")
        native_output, _ = helper.communicate(timeout=10)
        assert helper.returncode == 0 and "PASS production Unix control" in native_output, native_output
        (fixture/"native-result.log").write_text(native_output)
        record(operation+"-lost-final-ACK", started, output, progress_frames=progress,
               dropped_ack=final.decode().strip(), native=native_output.strip(), fixture=str(fixture),
               boundary="production serveControl / AF_UNIX socketpair relay / Swift exchange")
    finally:
        upstream.close()
        relay.close()
        for owned in (process, helper):
            if owned.poll() is None:
                owned.kill()
                owned.communicate(timeout=3)


try:
    # Put the new production seam first so a RED run identifies the actual bug.
    for operation in ("export2", "quiesce2", "export3", "quiesce3"):
        mode = "slow-quiesce" if operation.startswith("quiesce") else "slow-export"
        production(mode, operation=operation, queued_probe=True)
        production("stall-quiesce" if operation.startswith("quiesce") else "stall-export", operation=operation)
        production(mode, operation=operation, leave=True)
        production(mode, operation=operation, kill=True)
        lost_incremental_ack(operation)
        for name, frame in [("zero", b"0"), ("malformed", b"wat"), ("overflow", b"18446744073709551616"), ("extra-field", b"1\tx")]:
            fake(operation+"-invalid-counter-"+name, [(0, b"PROGRESS\t"+frame+b"\n")],
                 "invalid progress frame", command=operation)
        fake(operation+"-regressing-counter", [(0, b"PROGRESS\t2\nPROGRESS\t1\n")],
             "invalid progress frame", command=operation)
        ack=b"OK\t3\texported\t655360\t0\tfixture-incarnation"+(b"\t"+b"a"*64 if operation.endswith("3") else b"")+b"\n"
        fake(operation+"-fragmented-progress-final-ACK", [(.45, b"PRO"), (.05, b"GRESS\t1\n"),
             (.6, b"PROGRESS\t2\n"), (.6, ack)],
             command=operation, minimum=1.5, maximum=2.5)
        fake(operation+"-repeated-counter-stalls", [(.15, b"PROGRESS\t1\n")]*14,
             "timed out waiting for progress", command=operation, minimum=1, maximum=1.8)
        fake(operation+"-fragment-trickle-stalls", [(.15, b"P")]*14,
             "timed out waiting for progress", command=operation, minimum=.8)
        fake(operation+"-truncated-progress", [(0, b"PROGRESS\t1")], "truncated reply frame", command=operation)
    production("slow-populate")
    production("slow-populate2", operation="populate2")
    production("stall-populate2", operation="populate2")
    fake("populate2-progress-policy", [(0, b"PROGRESS\t1\nOK\n")], command="populate2\t"+"a"*64)
    production("slow-export", queued_probe=True)
    production("slow-quiesce")
    production("stall-populate")
    production("stall-export")
    production("slow-export", leave=True)
    production("error-export")
    production("incomplete-export", incomplete=True)
    production("slow-export", kill=True)
    fake("ordinary-OK", [(0, b"OK\tvalue\t2\n")])
    fake("helper-ERR", [(0, b"ERR\t5\n")], "Helper populate rejected operation")
    fake("fragmented-progress", [(.45, b"PRO"), (.05, b"GRESS\t1\n"),
                                 (.6, b"PROGRESS\t2\n"), (.6, b"OK\n")], minimum=1.5, maximum=2.5)
    fake("empty-EOF", [], "disconnected before a final reply")
    fake("truncated-OK", [(0, b"OK")], "truncated reply frame")
    fake("truncated-progress", [(0, b"PROGRESS\t1")], "truncated reply frame")
    fake("progress-then-EOF", [(0, b"PROGRESS\t1\n")], "disconnected before a final reply")
    fake("no-progress", [(1.8, b"")], "timed out waiting for progress", minimum=.8)
    fake("repeated-counter-is-no-work", [(.15, b"PROGRESS\t1\n")]*14,
         "timed out waiting for progress", minimum=1, maximum=1.8)
    fake("trickled-incomplete-frame", [(.15, b"P")]*14, "timed out waiting for progress", minimum=.8)
    fake("oversized-frame", [(0, b"OK\t"+b"x"*8190+b"\n")], "reply frame exceeds 8192 bytes")
    fake("exact-frame-limit", [(0, b"OK\t"+b"x"*8189+b"\n")])
    fake("unterminated-limit", [(0, b"OK\t"+b"x"*8189)], "truncated reply frame")
    for name, frame in [("zero", b"0"), ("malformed", b"wat"), ("overflow", b"18446744073709551616"), ("extra-field", b"1\tx")]:
        fake("invalid-progress-"+name, [(0, b"PROGRESS\t"+frame+b"\n")], "invalid progress frame")
    fake("regressing-counter", [(0, b"PROGRESS\t2\nPROGRESS\t1\n")], "invalid progress frame")
    fake("invalid-UTF8", [(0, b"OK\t\xff\n")], "invalid reply frame")
    fake("unknown-frame", [(0, b"WHAT\n")], "invalid reply frame")
    fake("short-status-refuses-progress", [(0, b"PROGRESS\t1\n")], "invalid progress frame", command="status")
    fake("status-two-second-bound", [(2.8, b"")], "Helper status timed out waiting for a reply",
         command="status", timeout=2, minimum=1.8, maximum=2.6)
    fake("interrupted-IO-succeeds", [(.5, b"OK\n")], interrupt=True)
    fake("interrupted-stall-stays-bounded", [(1.8, b"")], "timed out waiting for progress", minimum=.8, interrupt=True)
finally:
    (run/"results.json").write_text(json.dumps(results, indent=2)+"\n")
print(f"PASS {len(results)} real Unix socket scenarios; evidence {run}")

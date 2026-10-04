#!/usr/bin/env python3
"""One local command per connection. Never retries start or infers Phone call status."""
import argparse
import json
import os
from pathlib import Path
import socket
import stat
import sys
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", default=f"/tmp/solar-call-desk-{os.getuid()}/control.sock")
    parser.add_argument("--timeout", type=float, default=5.0)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("status")
    probe = sub.add_parser("inspect-phone-controls", help="Read-only Phone UI inspection; never opens or presses a call control.")
    probe.add_argument("--number", help="Optional exact international number to match; absent means window metadata only.")
    sub.add_parser("phone-controls-result", help="Read the most recent local Phone UI inspection.")
    sub.add_parser("cancel-phone-inspection", help="Cancel read-only inspection; does not affect Phone.")
    prepare = sub.add_parser("prepare")
    prepare.add_argument("--job-id", required=True, type=uuid.UUID)
    prepare.add_argument("--recipient", required=True)
    prepare.add_argument("--number", required=True)
    prepare.add_argument("--message-file", required=True, type=Path)
    for name in ("start", "result", "stop-voice", "report-ended"):
        item = sub.add_parser(name)
        item.add_argument("--job-id", required=True, type=uuid.UUID)
        if name == "report-ended":
            item.add_argument("--user-confirmed", required=True, action="store_true",
                              help="Only use after an actual user report that Phone ended or never started.")
    args = parser.parse_args()
    if not 0.1 <= args.timeout <= 10:
        parser.error("timeout must be between0.1 and10 seconds")
    command = {"command": args.command}
    if args.command not in ("status", "inspect-phone-controls", "phone-controls-result", "cancel-phone-inspection"):
        command["job_id"] = str(args.job_id)
    if args.command == "inspect-phone-controls" and args.number is not None:
        command["expected_number"] = args.number
    if args.command == "prepare":
        # Bound reading before decoding. No audio/key/transcript file is written by this tool.
        with args.message_file.open("rb") as source:
            content = source.read(16_385)
        if len(content) > 16_384:
            parser.error("message file must be at most16384 UTF8 bytes")
        command.update(recipient=args.recipient, number=args.number, message=content.decode("utf-8"))
    if args.command == "report-ended":
        command["user_confirmed"] = True
    request = json.dumps(command, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n"
    if len(request) > 65_537:
        parser.error("encoded command exceeds65536 bytes")
    path = Path(args.socket)
    directory = path.parent.lstat()
    endpoint = path.lstat()
    if not stat.S_ISDIR(directory.st_mode) or directory.st_uid != os.getuid() or stat.S_IMODE(directory.st_mode) != 0o700:
        parser.error("control directory must be a same-user real directory with mode0700")
    if not stat.S_ISSOCK(endpoint.st_mode) or endpoint.st_uid != os.getuid() or stat.S_IMODE(endpoint.st_mode) != 0o600:
        parser.error("control endpoint must be a same-user socket with mode0600")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(args.timeout)
        connection.connect(str(path))
        # Connected peer UID is checked by the server; the private path also guards the client.
        connection.sendall(request)
        response = bytearray()
        while b"\n" not in response:
            data = connection.recv(min(4_096, 2_097_153 - len(response)))
            if not data:
                raise RuntimeError("connection ended without a complete response")
            response.extend(data)
            if len(response) > 2_097_153:
                raise RuntimeError("response exceeded its bound")
        result = json.loads(response.split(b"\n", 1)[0])
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, ValueError) as error:
        # Never print a supplied message/key or retry a mutation after ambiguous delivery.
        print(json.dumps({"ok": False, "status": "unknown", "error": type(error).__name__,
                          "guidance": "Enable Sambha control and check status. A timed-out start may already be active; do not redial or auto-retry. Use status/result with the same job_id."}), file=sys.stderr)
        sys.exit(2)

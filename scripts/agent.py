#!/usr/bin/env python3
"""
AGY LAN Mesh — Zero-Dependency Target Node Agent & Terminal Console
Uses ONLY Python 3 standard library (no pip packages required).
"""

import argparse
import base64
import getpass
import hashlib
import json
import os
import platform
import select
import socket
import ssl
import struct
import subprocess
import sys
import threading
import time
import urllib.parse
import uuid
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_STAMPED_WS = "__DEFAULT_WS_URL__"
MAGIC_PROBE = b"AGY_MESH_DISCOVER_V1"


class MinimalWsClient:
    """RFC 6455 WebSocket client built purely on Python stdlib sockets."""

    def __init__(self, ws_url: str, timeout: float = 15.0):
        parsed = urllib.parse.urlparse(ws_url)
        self.is_tls = parsed.scheme == "wss"
        self.host = parsed.hostname or "127.0.0.1"
        self.port = parsed.port or (443 if self.is_tls else 80)
        self.path = parsed.path or "/ws"
        if parsed.query:
            self.path += "?" + parsed.query
        self.sock = None
        self._send_lock = threading.Lock()
        self.closed = False
        self._connect(timeout)

    def _connect(self, timeout: float):
        raw = socket.create_connection((self.host, self.port), timeout=timeout)
        if self.is_tls:
            ctx = ssl.create_default_context()
            raw = ctx.wrap_socket(raw, server_hostname=self.host)
        raw.settimeout(None)
        self.sock = raw

        key = base64.b64encode(os.urandom(16)).decode("ascii")
        handshake = (
            f"GET {self.path} HTTP/1.1\r\n"
            f"Host: {self.host}:{self.port}\r\n"
            f"Upgrade: websocket\r\n"
            f"Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            f"Sec-WebSocket-Version: 13\r\n\r\n"
        )
        self.sock.sendall(handshake.encode("ascii"))

        resp = b""
        while b"\r\n\r\n" not in resp:
            chunk = self.sock.recv(1024)
            if not chunk:
                raise ConnectionError("Server closed connection during WS handshake")
            resp += chunk

        header_text, remainder = resp.split(b"\r\n\r\n", 1)
        status_line = header_text.split(b"\r\n")[0].decode("latin1", errors="replace")
        if "101" not in status_line:
            raise ConnectionError(f"WebSocket upgrade rejected: {status_line}")

        expected_accept = base64.b64encode(
            hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("ascii")).digest()
        ).decode("ascii")
        if expected_accept.lower() not in header_text.decode("latin1", errors="replace").lower():
            raise ConnectionError("Invalid Sec-WebSocket-Accept header")
        self._buffer = bytearray(remainder)

    def _read_exact(self, n: int) -> bytes:
        while len(self._buffer) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                self.closed = True
                raise EOFError("WebSocket closed")
            self._buffer.extend(chunk)
        out = bytes(self._buffer[:n])
        del self._buffer[:n]
        return out

    def recv_text(self) -> str:
        fragments = bytearray()
        while True:
            b1, b2 = self._read_exact(2)
            fin = (b1 & 0x80) != 0
            opcode = b1 & 0x0F
            masked = (b2 & 0x80) != 0
            length = b2 & 0x7F
            if length == 126:
                (length,) = struct.unpack("!H", self._read_exact(2))
            elif length == 127:
                (length,) = struct.unpack("!Q", self._read_exact(8))
            mask_key = self._read_exact(4) if masked else None
            payload = bytearray(self._read_exact(length))
            if mask_key:
                for i in range(length):
                    payload[i] ^= mask_key[i % 4]

            if opcode == 0x8:  # Close
                self.closed = True
                raise EOFError("WebSocket closed by server")
            elif opcode == 0x9:  # Ping
                self._send_frame(0xA, bytes(payload))
                continue
            elif opcode == 0xA:  # Pong
                continue
            elif opcode in (0x1, 0x0):
                fragments.extend(payload)
                if fin:
                    return fragments.decode("utf-8", errors="replace")

    def send_text(self, text: str):
        self._send_frame(0x1, text.encode("utf-8"))

    def _send_frame(self, opcode: int, data: bytes):
        if self.closed:
            return
        mask_key = os.urandom(4)
        header = bytearray([0x80 | (opcode & 0x0F)])
        n = len(data)
        if n < 126:
            header.append(0x80 | n)
        elif n < 65536:
            header.append(0x80 | 126)
            header.extend(struct.pack("!H", n))
        else:
            header.append(0x80 | 127)
            header.extend(struct.pack("!Q", n))
        header.extend(mask_key)
        masked = bytearray(data)
        for i in range(n):
            masked[i] ^= mask_key[i % 4]
        with self._send_lock:
            self.sock.sendall(header + masked)

    def close(self):
        self.closed = True
        try:
            self.sock.close()
        except Exception:
            pass


def discover_lan_hub(discovery_port: int = 8766, timeout: float = 3.0):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sock.settimeout(timeout)
    try:
        sock.sendto(MAGIC_PROBE, ("255.255.255.255", discovery_port))
        data, (addr, _) = sock.recvfrom(4096)
        info = json.loads(data.decode("utf-8"))
        port = info.get("port", 8765)
        return f"ws://{addr}:{port}/ws", info.get("serverName", addr)
    except Exception:
        return None, None
    finally:
        sock.close()


def state_file_path() -> Path:
    if os.name == "nt":
        base = Path(os.environ.get("LOCALAPPDATA", Path.home()))
    else:
        base = Path.home() / ".config"
    p = base / "agy-lan-mesh" / "node_auth.json"
    p.parent.mkdir(parents=True, exist_ok=True)
    return p


def load_saved_auth() -> dict:
    p = state_file_path()
    if p.exists():
        try:
            return json.loads(p.read_text())
        except Exception:
            return {}
    return {}


def save_auth(data: dict):
    state_file_path().write_text(json.dumps(data, indent=2))


def detect_privilege_level(sudo_pw: str | None) -> str:
    if os.name == "nt":
        try:
            import ctypes
            if ctypes.windll.shell32.IsUserAnAdmin() != 0:
                return "admin"
        except Exception:
            pass
        return "standard"
    else:
        if hasattr(os, "geteuid") and os.geteuid() == 0:
            return "root"
        if sudo_pw:
            return "sudoUnlocked"
        return "standard"


def verify_sudo_password(pw: str) -> bool:
    try:
        proc = subprocess.run(
            ["sudo", "-S", "-k", "-p", "", "true"],
            input=(pw + "\n").encode("utf-8"),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=8,
        )
        return proc.returncode == 0
    except Exception:
        return False


class TargetNodeAgent:
    def __init__(self, ws_url: str, pin: str | None, approval_mode: str, sudo_pw: str | None, cwd: str):
        self.ws_url = ws_url
        self.pin = pin
        self.approval_mode = approval_mode
        self._sudo_pw = sudo_pw  # Strictly held in local process RAM
        self.cwd = cwd
        saved = load_saved_auth()
        self.node_id = saved.get("nodeId") or str(uuid.uuid4())
        self.token = saved.get("token") or ""
        self.active_session_id = None
        self.ws: MinimalWsClient | None = None
        self._prompt_lock = threading.Lock()

    def build_node_info(self) -> dict:
        now = datetime.now(timezone.utc).isoformat()
        os_name = "windows" if os.name == "nt" else ("macos" if sys.platform == "darwin" else "linux")
        return {
            "nodeId": self.node_id,
            "hostname": socket.gethostname(),
            "os": os_name,
            "osVersion": platform.platform(),
            "arch": platform.machine(),
            "privilegeLevel": detect_privilege_level(self._sudo_pw),
            "approvalMode": self.approval_mode,
            "cwd": self.cwd,
            "capabilities": ["exec", "fs", "chat"],
            "online": True,
            "connectedAt": now,
            "lastSeenAt": now,
        }

    def prompt_tty(self, question: str) -> str:
        with self._prompt_lock:
            try:
                with open("/dev/tty", "r+") as tty:
                    tty.write(question)
                    tty.flush()
                    return tty.readline().strip()
            except Exception:
                return input(question).strip()

    def handle_exec(self, payload: dict):
        req_id = payload.get("requestId", "")
        cmd = payload.get("command", "")
        cwd = payload.get("cwd") or self.cwd
        elevated = bool(payload.get("elevated", False))
        timeout_sec = int(payload.get("timeoutSec", 120))
        sess_title = payload.get("requestingSessionTitle") or "AGY Brain"

        if elevated and self.approval_mode == "askForElevated":
            self.ws.send_text(json.dumps({
                "type": "rpc.awaiting_approval",
                "payload": {"requestId": req_id},
            }))
            ans = self.prompt_tty(
                f"\n⚡ [APPROVAL REQUIRED from '{sess_title}']\n"
                f"   Command : {cmd}\n"
                f"   Dir     : {cwd}\n"
                f"   Elevated: {elevated}\n"
                f"   Approve? [y = yes / n = deny / a = switch to Full Auto]: "
            ).lower()
            if ans == "a":
                self.approval_mode = "fullAuto"
                self.ws.send_text(json.dumps({
                    "type": "node.update",
                    "payload": {"approvalMode": self.approval_mode},
                }))
            elif ans not in ("y", "yes"):
                self.ws.send_text(json.dumps({
                    "type": "rpc.exec_result",
                    "payload": {
                        "requestId": req_id,
                        "exitCode": 126,
                        "stdout": "",
                        "stderr": "Command denied by local user on target machine.",
                        "approved": False,
                        "durationMs": 0,
                    },
                }))
                return

        t0 = time.monotonic()
        try:
            stdin_bytes = None
            if os.name == "nt":
                run_args = ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", cmd]
            elif elevated and hasattr(os, "geteuid") and os.geteuid() != 0:
                if self._sudo_pw:
                    run_args = ["sudo", "-S", "-p", "", "--", "bash", "-c", cmd]
                    stdin_bytes = (self._sudo_pw + "\n").encode("utf-8")
                else:
                    run_args = ["sudo", "-n", "--", "bash", "-c", cmd]
            else:
                run_args = ["bash", "-c", cmd]

            proc = subprocess.run(
                run_args,
                input=stdin_bytes,
                cwd=cwd if os.path.isdir(cwd) else None,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=timeout_sec,
            )
            dur = int((time.monotonic() - t0) * 1000)
            self.ws.send_text(json.dumps({
                "type": "rpc.exec_result",
                "payload": {
                    "requestId": req_id,
                    "exitCode": proc.returncode,
                    "stdout": proc.stdout.decode("utf-8", errors="replace"),
                    "stderr": proc.stderr.decode("utf-8", errors="replace"),
                    "approved": True,
                    "durationMs": dur,
                },
            }))
        except subprocess.TimeoutExpired:
            dur = int((time.monotonic() - t0) * 1000)
            self.ws.send_text(json.dumps({
                "type": "rpc.exec_result",
                "payload": {
                    "requestId": req_id,
                    "exitCode": 124,
                    "stdout": "",
                    "stderr": f"Timed out after {timeout_sec}s",
                    "approved": True,
                    "durationMs": dur,
                },
            }))
        except Exception as e:
            dur = int((time.monotonic() - t0) * 1000)
            self.ws.send_text(json.dumps({
                "type": "rpc.exec_result",
                "payload": {
                    "requestId": req_id,
                    "exitCode": -1,
                    "stdout": "",
                    "stderr": str(e),
                    "approved": True,
                    "durationMs": dur,
                    "errorMessage": str(e),
                },
            }))

    def handle_file_op(self, payload: dict):
        req_id = payload.get("requestId", "")
        op = payload.get("op", "read")
        raw_path = os.path.expanduser(payload.get("path", ""))
        target_path = Path(raw_path) if os.path.isabs(raw_path) else (Path(self.cwd) / raw_path)

        try:
            if op == "read":
                if not target_path.is_file():
                    raise FileNotFoundError(f"File not found: {target_path}")
                lines = target_path.read_text(encoding="utf-8", errors="replace").splitlines()
                s = max(1, int(payload.get("startLine") or 1))
                e = min(len(lines), int(payload.get("endLine") or len(lines))) if lines else 1
                text = "\n".join(lines[s - 1 : e]) if lines else ""
                res = {"requestId": req_id, "ok": True, "content": text}
            elif op == "write":
                target_path.parent.mkdir(parents=True, exist_ok=True)
                content = payload.get("content") or ""
                mode = "a" if payload.get("append") else "w"
                with open(target_path, mode, encoding="utf-8") as f:
                    f.write(content)
                res = {"requestId": req_id, "ok": True, "message": f"Wrote {len(content)} chars to {target_path}"}
            elif op == "edit":
                if not target_path.is_file():
                    raise FileNotFoundError(f"File not found: {target_path}")
                existing = target_path.read_text(encoding="utf-8")
                target = payload.get("target") or ""
                replacement = payload.get("replacement") or ""
                if not target or target not in existing:
                    raise ValueError(f"Target string not found in {target_path}")
                target_path.write_text(existing.replace(target, replacement), encoding="utf-8")
                res = {"requestId": req_id, "ok": True, "message": f"Edited {target_path}"}
            elif op == "list":
                if not target_path.is_dir():
                    raise NotADirectoryError(f"Directory not found: {target_path}")
                entries = []
                for child in sorted(target_path.iterdir(), key=lambda x: (not x.is_dir(), x.name.lower())):
                    st = child.stat()
                    entries.append({
                        "name": child.name,
                        "path": str(child),
                        "isDirectory": child.is_dir(),
                        "size": st.st_size,
                        "modifiedAt": datetime.fromtimestamp(st.st_mtime, tz=timezone.utc).isoformat(),
                    })
                res = {"requestId": req_id, "ok": True, "entries": entries}
            else:
                res = {"requestId": req_id, "ok": False, "error": f"Unknown op: {op}"}
        except Exception as e:
            res = {"requestId": req_id, "ok": False, "error": str(e)}

        self.ws.send_text(json.dumps({"type": "rpc.file_op_result", "payload": res}))

    def start_stdin_chat_loop(self):
        def _loop():
            print(
                f"💬 Interactive Brain Chat Ready! Type any prompt to run on '{socket.gethostname()}' "
                f"(cwd: {self.cwd}), or '/new' for a fresh session.\n> ",
                end="",
                flush=True,
            )
            while True:
                try:
                    line = sys.stdin.readline()
                    if not line:
                        break
                    text = line.strip()
                    if not text:
                        print("> ", end="", flush=True)
                        continue
                    if text == "/new":
                        self.active_session_id = str(uuid.uuid4())
                        print(f"[Started fresh session {self.active_session_id}]\n> ", end="", flush=True)
                        continue
                    if not self.active_session_id:
                        self.active_session_id = str(uuid.uuid4())
                    if self.ws and not self.ws.closed:
                        self.ws.send_text(json.dumps({
                            "type": "chat.send",
                            "payload": {
                                "sessionId": self.active_session_id,
                                "targetNodeId": self.node_id,
                                "workspacePath": self.cwd,
                                "prompt": text,
                            },
                        }))
                except Exception:
                    break

        t = threading.Thread(target=_loop, daemon=True)
        t.start()

    def run_forever(self, enable_chat_loop: bool = True):
        chat_started = False
        while True:
            try:
                self.ws = MinimalWsClient(self.ws_url)
                hello = {
                    "type": "auth.hello",
                    "payload": {
                        "pin": self.pin or "",
                        "token": self.token,
                        "registerAsNode": True,
                        "nodeInfo": self.build_node_info(),
                    },
                }
                self.ws.send_text(json.dumps(hello))

                while True:
                    raw = self.ws.recv_text()
                    env = json.loads(raw)
                    mtype = env.get("type", "")
                    payload = env.get("payload") or {}

                    if mtype == "auth.ok":
                        self.node_id = payload.get("nodeId", self.node_id)
                        self.token = payload.get("token", self.token)
                        save_auth({"nodeId": self.node_id, "token": self.token, "wsUrl": self.ws_url})
                        priv = detect_privilege_level(self._sudo_pw)
                        print(
                            f"✅ Connected to AGY Hub '{payload.get('serverHostname')}' "
                            f"as '{socket.gethostname()}' [privilege={priv}, mode={self.approval_mode}]"
                        )
                        if enable_chat_loop and not chat_started and sys.stdin.isatty():
                            chat_started = True
                            self.start_stdin_chat_loop()

                    elif mtype == "auth.error":
                        print(f"❌ Auth failed: {payload.get('message')}")
                        self.pin = self.prompt_tty("Enter 6-digit Pairing PIN from Server: ")
                        self.token = ""
                        break

                    elif mtype == "node.ping":
                        self.ws.send_text(json.dumps({"type": "node.pong"}))

                    elif mtype == "rpc.exec":
                        threading.Thread(target=self.handle_exec, args=(payload,), daemon=True).start()

                    elif mtype == "rpc.file_op":
                        threading.Thread(target=self.handle_file_op, args=(payload,), daemon=True).start()

                    elif mtype == "chat.event":
                        if payload.get("sessionId") == self.active_session_id:
                            kind = payload.get("kind")
                            if kind == "text_delta":
                                print(payload.get("delta", ""), end="", flush=True)
                            elif kind == "tool_event":
                                te = payload.get("toolEvent") or {}
                                if te.get("status") == "running":
                                    print(f"\n🔧 {te.get('summary')}", flush=True)
                    elif mtype == "session.detail":
                        sess = payload.get("session") or {}
                        if sess.get("sessionId") == self.active_session_id and sess.get("status") in ("idle", "error"):
                            print("\n> ", end="", flush=True)

            except KeyboardInterrupt:
                print("\nDisconnecting agent.")
                return
            except Exception as e:
                print(f"[Agent] Connection lost ({e}). Reconnecting in 3s...")
                time.sleep(3)


def main():
    parser = argparse.ArgumentParser(description="AGY LAN Mesh Zero-Install Node Agent")
    parser.add_argument("--server", help="Hub WebSocket URL (e.g. ws://192.168.1.10:8765/ws)")
    parser.add_argument("--pin", help="6-digit Pairing PIN")
    parser.add_argument(
        "--mode",
        choices=["auto", "ask"],
        default="ask",
        help="Execution policy: 'auto' (Full Auto) or 'ask' (Ask Approval for Admin/Sudo)",
    )
    parser.add_argument("--cwd", default=os.getcwd(), help="Default project workspace directory")
    parser.add_argument("--unlock-sudo", action="store_true", help="Prompt for local sudo password into RAM vault")
    parser.add_argument("--no-chat", action="store_true", help="Run as background daemon without interactive stdin chat")
    args = parser.parse_args()

    saved = load_saved_auth()
    ws_url = args.server
    if not ws_url:
        if not DEFAULT_STAMPED_WS.startswith("__DEFAULT"):
            ws_url = DEFAULT_STAMPED_WS
        elif saved.get("wsUrl"):
            ws_url = saved["wsUrl"]
        else:
            print("🔍 Searching LAN for AGY Hub Server via UDP broadcast...")
            ws_url, sname = discover_lan_hub()
            if ws_url:
                print(f"✨ Discovered AGY Hub '{sname}' at {ws_url}")
            else:
                host = input("Could not auto-discover Hub. Enter Server IP (e.g. 192.168.1.50): ").strip()
                ws_url = f"ws://{host}:8765/ws" if "://" not in host else host

    sudo_pw = None
    if os.name != "nt" and hasattr(os, "geteuid") and os.geteuid() != 0 and args.unlock_sudo:
        pw = getpass.getpass("🔐 Enter local sudo password (kept strictly in local RAM, never sent over LAN): ")
        if verify_sudo_password(pw):
            sudo_pw = pw
            print("✅ Local sudo vault unlocked.")
        else:
            print("⚠️ Sudo verification failed; continuing as standard user.")

    mode_str = "fullAuto" if args.mode == "auto" else "askForElevated"
    agent = TargetNodeAgent(
        ws_url=ws_url,
        pin=args.pin,
        approval_mode=mode_str,
        sudo_pw=sudo_pw,
        cwd=os.path.abspath(args.cwd),
    )
    agent.run_forever(enable_chat_loop=not args.no_chat)


if __name__ == "__main__":
    main()

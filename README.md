# AGY LAN Mesh

Run **Antigravity (`agy`)** on a single primary computer on your LAN, and seamlessly code, administer, and chat across **all** your Windows, Linux, and Android devices without installing or logging into `agy` on every machine.

## Key Capabilities

1. **Central LAN Hub & Streamable HTTP MCP Server (`agy-mesh-server`)**:
   - Exposes `http://127.0.0.1:8765/mcp` to Antigravity (`lan-mesh`) so working directly on the Server gives `agy` full remote execution & file tools across every paired computer.
   - Orchestrates **concurrent multi-project sessions** (`agy -p ... --output-format stream-json --conversation <id>`) so prompts sent from any client machine, Web browser, or Android phone use the Server's Brain while keeping each project's remote folder and conversation context isolated.
2. **Multi-Platform Flutter Client & Console (`apps/mesh_client`)**:
   - Runs natively on **Linux**, **Windows**, **Android**, and **Web** (served directly by the Hub at `http://<server-ip>:8765`).
   - Supports **Multi-Session Sidebar** (filter by machine, browse remote directories, run parallel sessions across different computers, cancel turns).
   - **Privilege Controls**: Windows Admin detection + one-click `RunAs` relaunch; Linux `su -` (`root`) or **RAM-only Local Sudo Vault** (password never leaves client RAM); per-device toggle between **`Ask Approval for Admin/Sudo`** and **`Full Auto`**.
3. **Zero-Install 1-Command Target Agents (`scripts/agent.ps1` & `scripts/agent.py`)**:
   - Connect any Windows PC (PowerShell) or Linux machine (Python 3 stdlib only—zero pip packages) in 5 seconds over HTTP.

---

## Quickstart

### 1. Start the Hub Server (on the machine where `agy` is logged in)
```bash
cd /home/tmc/Projects/agy-lan-mesh
./build/agy-mesh-server start --register-mcp
```
Note the **6-Digit Pairing PIN** and LAN URL printed in the banner, or open `http://127.0.0.1:8765` on the server to manage all project sessions visually.

### 2. Connect Target Computers (No `agy` install or login required!)

- **Option A — Zero-Install Windows (Run in Administrator PowerShell)**:
  ```powershell
  irm http://<SERVER_IP>:8765/agent.ps1 -OutFile $env:TEMP\agy.ps1
  powershell -ExecutionPolicy Bypass -File $env:TEMP\agy.ps1 -Pin <PIN>
  ```
- **Option B — Zero-Install Linux (`su -` or `--unlock-sudo`)**:
  ```bash
  curl -fsSL http://<SERVER_IP>:8765/agent.sh | bash -s -- --pin <PIN> --unlock-sudo
  ```
- **Option C — Native Flutter App**:
  - **Linux**: Run `apps/mesh_client/build/linux/x64/release/bundle/mesh_client`
  - **Android**: Download `http://<SERVER_IP>:8765/downloads/agy-mesh-client.apk`
  - **Windows**: Run `flutter build windows` once on a Windows machine (or use `.github/workflows/build-windows.yml`) and copy the portable `Release` folder anywhere.
  - **Any Browser**: Open `http://<SERVER_IP>:8765`

### 3. Manage Multi-Project Sessions from the Server CLI (or UI)
```bash
# List all active/idle project sessions across machines
./build/agy-mesh-server sessions list

# Create a pinned project session for a specific machine & folder
./build/agy-mesh-server sessions new -t "Win-PC Backend" -n WIN-DESKTOP -w "C:\Projects\backend"

# List all paired LAN computers and their privilege/online status
./build/agy-mesh-server nodes
```

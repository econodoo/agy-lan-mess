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

- **Easiest (From Client Browser)**: Open `http://<SERVER_IP>:8765` on the client PC, enter the 6-digit PIN, and click **Copy Client Command** in the top bar for a pre-stamped 1-line command!
- **Option A — Zero-Install Windows (1-Line PowerShell with Auto-UAC Elevation)**:
  ```powershell
  irm "http://<SERVER_IP>:8765/agent.ps1?pin=<PIN>&elevate=1" | iex
  ```
- **Option B — Zero-Install Linux / macOS (1-Line Terminal with Sudo Vault)**:
  ```bash
  curl -fsSL "http://<SERVER_IP>:8765/agent.sh?pin=<PIN>&sudo=1" | bash
  ```
- **Option C — Pre-Built Native Apps (Windows, macOS, Linux, Android, Web)**:
  - **GitHub Releases**: Download ready-made archives from [Releases](https://github.com/econodoo/agy-lan-mess/releases)
  - **Android (Direct LAN)**: `http://<SERVER_IP>:8765/downloads/agy-mesh-client.apk`
  - **Any Browser**: `http://<SERVER_IP>:8765`

### 3. Check `agy` Connectivity, Quota & Active Model
- **In the UI**: Open the **Brain & Setup** tab (or click the `Model: ...` chip in the header) to inspect `agy` login status, account email, MCP registration, cumulative token usage, run a live quota ping (**Verify Brain & Quota**), or switch the active model across all sessions.
- **From the Server CLI**:
  ```bash
  ./build/agy-mesh-server doctor --ping
  ```

### 4. Manage Multi-Project Sessions from the Server CLI (or UI)
```bash
# List all active/idle project sessions across machines
./build/agy-mesh-server sessions list

# Create a pinned project session for a specific machine & folder
./build/agy-mesh-server sessions new -t "Win-PC Backend" -n WIN-DESKTOP -w "C:\Projects\backend"

# List all paired LAN computers and their privilege/online status
./build/agy-mesh-server nodes
```

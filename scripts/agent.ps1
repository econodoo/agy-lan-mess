<#
.SYNOPSIS
    AGY LAN Mesh — Zero-Install Windows PowerShell Node Agent & Console
.DESCRIPTION
    Connects any Windows PC on your LAN to your central Antigravity Brain Hub
    with zero external dependencies. Supports Administrator elevation, UDP LAN
    auto-discovery, 6-digit PIN pairing, Full Auto vs Ask-Approval modes, and
    remote file/PowerShell execution.
#>
param(
    [string]$Server = "__DEFAULT_WS_URL__",
    [string]$Pin = "",
    [ValidateSet("ask", "auto")]
    [string]$Mode = "ask",
    [string]$Cwd = (Get-Location).Path,
    [switch]$Elevate
)

$ErrorActionPreference = "Stop"

function Test-IsAdmin {
    $current = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($current)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if ($Elevate -and -not (Test-IsAdmin)) {
    Write-Host "🔼 Relaunching PowerShell Agent as Administrator..." -ForegroundColor Cyan
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Mode $Mode -Cwd `"$Cwd`""
    if ($Server -and -not $Server.StartsWith("__DEFAULT")) { $argList += " -Server `"$Server`"" }
    if ($Pin) { $argList += " -Pin `"$Pin`"" }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
    exit
}

$StateDir = Join-Path $env:LOCALAPPDATA "agy-lan-mesh"
if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
$AuthFile = Join-Path $StateDir "node_auth.json"
$SavedAuth = @{}
if (Test-Path $AuthFile) {
    try { $SavedAuth = Get-Content $AuthFile -Raw | ConvertFrom-Json } catch {}
}

$NodeId = if ($SavedAuth.nodeId) { $SavedAuth.nodeId } else { [guid]::NewGuid().ToString() }
$Token  = if ($SavedAuth.token)  { $SavedAuth.token }  else { "" }

function Find-LanHub {
    try {
        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.EnableBroadcast = $true
        $udp.Client.ReceiveTimeout = 3000
        $probe = [Text.Encoding]::UTF8.GetBytes("AGY_MESH_DISCOVER_V1")
        $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Broadcast, 8766)
        [void]$udp.Send($probe, $probe.Length, $ep)
        $remoteEp = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $resp = $udp.Receive([ref]$remoteEp)
        $info = [Text.Encoding]::UTF8.GetString($resp) | ConvertFrom-Json
        $udp.Close()
        return "ws://$($remoteEp.Address.IPAddressToString):$($info.port)/ws"
    } catch {
        return $null
    }
}

$WsUrl = $Server
if (-not $WsUrl -or $WsUrl.StartsWith("__DEFAULT")) {
    if ($SavedAuth.wsUrl) {
        $WsUrl = $SavedAuth.wsUrl
    } else {
        Write-Host "🔍 Discovering AGY Hub on LAN..." -ForegroundColor Cyan
        $WsUrl = Find-LanHub
        if (-not $WsUrl) {
            $ip = Read-Host "Enter AGY Hub Server IP (e.g. 192.168.1.50)"
            $WsUrl = if ($ip -match "^ws") { $ip } else { "ws://${ip}:8765/ws" }
        }
    }
}

$ApprovalMode = if ($Mode -eq "auto") { "fullAuto" } else { "askForElevated" }

function Send-WsJson($ws, $obj) {
    $json = $obj | ConvertTo-Json -Depth 10 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $seg = New-Object System.ArraySegment[byte](,$bytes)
    $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
}

function Receive-WsText($ws) {
    $ms = New-Object System.IO.MemoryStream
    $buf = New-Object byte[] 16384
    do {
        $seg = New-Object System.ArraySegment[byte](,$buf)
        $res = $ws.ReceiveAsync($seg, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
        if ($res.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
            throw "WebSocket closed by server"
        }
        $ms.Write($buf, 0, $res.Count)
    } while (-not $res.EndOfMessage)
    return [Text.Encoding]::UTF8.GetString($ms.ToArray())
}

while ($true) {
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    try {
        Write-Host "🔌 Connecting to $WsUrl ..." -ForegroundColor Gray
        $ws.ConnectAsync([Uri]$WsUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null

        $priv = if (Test-IsAdmin) { "admin" } else { "standard" }
        $now = (Get-Date).ToUniversalTime().ToString("o")
        Send-WsJson $ws @{
            type = "auth.hello"
            payload = @{
                pin = $Pin
                token = $Token
                registerAsNode = $true
                nodeInfo = @{
                    nodeId = $NodeId
                    hostname = $env:COMPUTERNAME
                    os = "windows"
                    osVersion = [Environment]::OSVersion.VersionString
                    arch = $env:PROCESSOR_ARCHITECTURE
                    privilegeLevel = $priv
                    approvalMode = $ApprovalMode
                    cwd = $Cwd
                    capabilities = @("exec", "fs", "chat")
                    online = $true
                    connectedAt = $now
                    lastSeenAt = $now
                }
            }
        }

        while ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            $raw = Receive-WsText $ws
            $envMsg = $raw | ConvertFrom-Json
            $p = $envMsg.payload

            switch ($envMsg.type) {
                "auth.ok" {
                    $NodeId = $p.nodeId
                    $Token = $p.token
                    @{ nodeId = $NodeId; token = $Token; wsUrl = $WsUrl } | ConvertTo-Json | Set-Content $AuthFile
                    Write-Host "✅ Paired & Online as '$($env:COMPUTERNAME)' [Privilege: $priv | Mode: $ApprovalMode | CWD: $Cwd]" -ForegroundColor Green
                }
                "auth.error" {
                    Write-Host "❌ $($p.message)" -ForegroundColor Yellow
                    $Pin = Read-Host "Enter 6-digit Pairing PIN from Server"
                    $Token = ""
                    break
                }
                "node.ping" {
                    Send-WsJson $ws @{ type = "node.pong"; payload = @{} }
                }
                "rpc.exec" {
                    $reqId = $p.requestId
                    $cmd = $p.command
                    $execCwd = if ($p.cwd) { $p.cwd } else { $Cwd }
                    $elevated = [bool]$p.elevated

                    $approved = $true
                    if ($elevated -and $ApprovalMode -eq "askForElevated") {
                        Send-WsJson $ws @{ type = "rpc.awaiting_approval"; payload = @{ requestId = $reqId } }
                        Write-Host "`n⚡ [APPROVAL REQUIRED] Command: $cmd (in $execCwd)" -ForegroundColor Yellow
                        $ans = Read-Host "Approve? [y = yes / n = deny / a = switch to Full Auto]"
                        if ($ans -eq "a") {
                            $ApprovalMode = "fullAuto"
                            Send-WsJson $ws @{ type = "node.update"; payload = @{ approvalMode = "fullAuto" } }
                        } elseif ($ans -notin @("y", "yes")) {
                            $approved = $false
                        }
                    }

                    if (-not $approved) {
                        Send-WsJson $ws @{
                            type = "rpc.exec_result"
                            payload = @{ requestId = $reqId; exitCode = 126; stdout = ""; stderr = "Denied by local user."; approved = $false; durationMs = 0 }
                        }
                    } else {
                        $sw = [Diagnostics.Stopwatch]::StartNew()
                        $psi = New-Object Diagnostics.ProcessStartInfo
                        $psi.FileName = "powershell.exe"
                        $psi.Arguments = "-NoProfile -NonInteractive -Command `"$($cmd.Replace('"', '\"'))`""
                        if (Test-Path $execCwd) { $psi.WorkingDirectory = $execCwd }
                        $psi.RedirectStandardOutput = $true
                        $psi.RedirectStandardError = $true
                        $psi.UseShellExecute = $false
                        $proc = [Diagnostics.Process]::Start($psi)
                        $stdout = $proc.StandardOutput.ReadToEnd()
                        $stderr = $proc.StandardError.ReadToEnd()
                        $proc.WaitForExit()
                        $sw.Stop()
                        Send-WsJson $ws @{
                            type = "rpc.exec_result"
                            payload = @{
                                requestId = $reqId
                                exitCode = $proc.ExitCode
                                stdout = $stdout
                                stderr = $stderr
                                approved = $true
                                durationMs = [int]$sw.ElapsedMilliseconds
                            }
                        }
                    }
                }
                "rpc.file_op" {
                    $reqId = $p.requestId
                    $op = $p.op
                    $targetPath = if ([IO.Path]::IsPathRooted($p.path)) { $p.path } else { Join-Path $Cwd $p.path }
                    try {
                        if ($op -eq "read") {
                            $lines = Get-Content -LiteralPath $targetPath -Encoding UTF8
                            $txt = if ($null -eq $lines) { "" } else { ($lines -join "`n") }
                            Send-WsJson $ws @{ type = "rpc.file_op_result"; payload = @{ requestId = $reqId; ok = $true; content = $txt } }
                        } elseif ($op -eq "write") {
                            $parent = Split-Path -Parent $targetPath
                            if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
                            if ($p.append) { Add-Content -LiteralPath $targetPath -Value $p.content -Encoding UTF8 -NoNewline }
                            else { [IO.File]::WriteAllText($targetPath, [string]$p.content, [Text.UTF8Encoding]::new($false)) }
                            Send-WsJson $ws @{ type = "rpc.file_op_result"; payload = @{ requestId = $reqId; ok = $true; message = "Wrote $targetPath" } }
                        } elseif ($op -eq "edit") {
                            $existing = [IO.File]::ReadAllText($targetPath, [Text.Encoding]::UTF8)
                            if (-not $existing.Contains([string]$p.target)) { throw "Target text not found in $targetPath" }
                            $updated = $existing.Replace([string]$p.target, [string]$p.replacement)
                            [IO.File]::WriteAllText($targetPath, $updated, [Text.UTF8Encoding]::new($false))
                            Send-WsJson $ws @{ type = "rpc.file_op_result"; payload = @{ requestId = $reqId; ok = $true; message = "Edited $targetPath" } }
                        } elseif ($op -eq "list") {
                            $items = Get-ChildItem -LiteralPath $targetPath -Force | ForEach-Object {
                                @{
                                    name = $_.Name
                                    path = $_.FullName
                                    isDirectory = [bool]$_.PSIsContainer
                                    size = if ($_.PSIsContainer) { 0 } else { [int64]$_.Length }
                                    modifiedAt = $_.LastWriteTimeUtc.ToString("o")
                                }
                            }
                            Send-WsJson $ws @{ type = "rpc.file_op_result"; payload = @{ requestId = $reqId; ok = $true; entries = @($items) } }
                        }
                    } catch {
                        Send-WsJson $ws @{ type = "rpc.file_op_result"; payload = @{ requestId = $reqId; ok = $false; error = $_.Exception.Message } }
                    }
                }
            }
        }
    } catch {
        Write-Host "[Agent] Disconnected ($($_.Exception.Message)). Retrying in 3s..." -ForegroundColor DarkYellow
        Start-Sleep -Seconds 3
    } finally {
        $ws.Dispose()
    }
}

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
    [string]$Pin = "__DEFAULT_PIN__",
    [ValidateSet("ask", "auto")]
    [string]$Mode = "__DEFAULT_MODE__",
    [string]$Cwd = (Get-Location).Path,
    [switch]$Elevate
)

$ErrorActionPreference = "Stop"
if ($Pin.StartsWith("__DEFAULT")) { $Pin = "" }
if ($Mode -notin @("ask", "auto")) { $Mode = "ask" }
$StampedElevate = ("__DEFAULT_ELEVATE__" -eq "1")
$SelfHttpUrl = "__SELF_HTTP_URL__"

function Test-IsAdmin {
    $current = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($current)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (($Elevate -or $StampedElevate) -and -not (Test-IsAdmin)) {
    Write-Host "🔼 Relaunching PowerShell Agent as Administrator..." -ForegroundColor Cyan
    if ($PSCommandPath) {
        $argList = "-NoExit -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Mode $Mode -Cwd `"$Cwd`""
        if ($Server -and -not $Server.StartsWith("__DEFAULT")) { $argList += " -Server `"$Server`"" }
        if ($Pin) { $argList += " -Pin `"$Pin`"" }
        Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
    } elseif (-not $SelfHttpUrl.StartsWith("__SELF")) {
        $safeCwd = $Cwd.Replace("'", "''")
        $iexCmd = "Set-Location '$safeCwd'; irm '$SelfHttpUrl' | iex"
        Start-Process powershell.exe -Verb RunAs -ArgumentList @("-NoExit", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $iexCmd)
    }
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

        $activeJobs = @{}
        $recvBuf = New-Object byte[] 16384
        $recvMs = New-Object System.IO.MemoryStream
        $recvSeg = New-Object System.ArraySegment[byte](,$recvBuf)
        $recvTask = $ws.ReceiveAsync($recvSeg, [Threading.CancellationToken]::None)

        while ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            # Check running background jobs & send 5s heartbeats without blocking WebSocket!
            foreach ($jid in @($activeJobs.Keys)) {
                $item = $activeJobs[$jid]
                $job = $item.Job
                $elapsed = [int]$item.Sw.ElapsedMilliseconds
                if ($job.State -notin @("Running", "NotStarted")) {
                    $item.Sw.Stop()
                    $jobOut = Receive-Job -Job $job -ErrorAction SilentlyContinue
                    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
                    $activeJobs.Remove($jid)

                    $code = if ($jobOut -and $null -ne $jobOut.exitCode) { [int]$jobOut.exitCode } else { 0 }
                    $outStr = if ($jobOut -and $jobOut.stdout) { [string]$jobOut.stdout } else { "" }
                    $errStr = if ($jobOut -and $jobOut.stderr) { [string]$jobOut.stderr } else { "" }
                    Write-Host "[Finished #$($item.ShortId)] exit=$code in $([Math]::Round($elapsed / 1000.0, 2))s" -ForegroundColor Cyan
                    Send-WsJson $ws @{
                        type = "rpc.exec_result"
                        payload = @{
                            requestId = $jid
                            exitCode = $code
                            stdout = $outStr
                            stderr = $errStr
                            approved = $true
                            durationMs = $elapsed
                        }
                    }
                } elseif (($elapsed - $item.LastHbMs) -ge 5000) {
                    $item.LastHbMs = $elapsed
                    Send-WsJson $ws @{
                        type = "rpc.exec_heartbeat"
                        payload = @{
                            requestId = $jid
                            alive = $true
                            elapsedMs = $elapsed
                        }
                    }
                    if (($elapsed - $item.LastLogMs) -ge 10000) {
                        $item.LastLogMs = $elapsed
                        Write-Host "[Alive    #$($item.ShortId)] still running ($([Math]::Round($elapsed / 1000.0, 1))s elapsed)..." -ForegroundColor DarkGray
                    }
                }
            }

            $delayTask = [Threading.Tasks.Task]::Delay(800)
            $doneTask = [Threading.Tasks.Task]::WhenAny($recvTask, $delayTask).GetAwaiter().GetResult()
            if ($doneTask -ne $recvTask) {
                continue
            }

            $res = $recvTask.GetAwaiter().GetResult()
            if ($res.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                throw "WebSocket closed by server"
            }
            $recvMs.Write($recvBuf, 0, $res.Count)
            if (-not $res.EndOfMessage) {
                $recvSeg = New-Object System.ArraySegment[byte](,$recvBuf)
                $recvTask = $ws.ReceiveAsync($recvSeg, [Threading.CancellationToken]::None)
                continue
            }

            $raw = [Text.Encoding]::UTF8.GetString($recvMs.ToArray())
            $recvMs.SetLength(0)
            $recvSeg = New-Object System.ArraySegment[byte](,$recvBuf)
            $recvTask = $ws.ReceiveAsync($recvSeg, [Threading.CancellationToken]::None)

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
                "rpc.task_kill" {
                    $killId = [string]$p.requestId
                    if ($activeJobs.ContainsKey($killId)) {
                        $item = $activeJobs[$killId]
                        Write-Host "[Killed   #$($item.ShortId)] Stopping job by server request..." -ForegroundColor Yellow
                        Stop-Job -Job $item.Job -ErrorAction SilentlyContinue
                        Remove-Job -Job $item.Job -Force -ErrorAction SilentlyContinue
                        $activeJobs.Remove($killId)
                        Send-WsJson $ws @{
                            type = "rpc.exec_result"
                            payload = @{ requestId = $killId; exitCode = 137; stdout = ""; stderr = "Terminated by mesh_kill_task"; approved = $true; durationMs = [int]$item.Sw.ElapsedMilliseconds }
                        }
                    }
                }
                "rpc.exec" {
                    $reqId = [string]$p.requestId
                    $shortId = if ($reqId.Length -ge 8) { $reqId.Substring(0, 8) } else { $reqId }
                    $cmd = [string]$p.command
                    $execCwd = if ($p.cwd) { [string]$p.cwd } else { $Cwd }
                    $elevated = [bool]$p.elevated

                    Write-Host "`n[Received #$shortId] $cmd (cwd: $execCwd)" -ForegroundColor Cyan

                    $approved = $true
                    if ($elevated -and $ApprovalMode -eq "askForElevated") {
                        Send-WsJson $ws @{ type = "rpc.awaiting_approval"; payload = @{ requestId = $reqId } }
                        Write-Host "⚡ [APPROVAL REQUIRED] Command: $cmd (in $execCwd)" -ForegroundColor Yellow
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
                        $job = Start-Job -ArgumentList $cmd, $execCwd -ScriptBlock {
                            param($commandText, $workingDir)
                            if ($workingDir -and (Test-Path -LiteralPath $workingDir)) {
                                Set-Location -LiteralPath $workingDir
                            }
                            $global:LASTEXITCODE = 0
                            $outputLines = Invoke-Expression $commandText 2>&1
                            $stdOutList = New-Object System.Collections.Generic.List[string]
                            $stdErrList = New-Object System.Collections.Generic.List[string]
                            foreach ($item in $outputLines) {
                                if ($item -is [System.Management.Automation.ErrorRecord]) {
                                    $stdErrList.Add($item.ToString())
                                } elseif ($null -ne $item) {
                                    $stdOutList.Add($item.ToString())
                                }
                            }
                            $code = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
                            return @{
                                exitCode = $code
                                stdout = ($stdOutList -join "`n")
                                stderr = ($stdErrList -join "`n")
                            }
                        }
                        Write-Host "[Running  #$shortId] Background job #$($job.Id) started..." -ForegroundColor Green
                        $activeJobs[$reqId] = @{
                            Job = $job
                            Sw = $sw
                            LastHbMs = 0
                            LastLogMs = 0
                            ShortId = $shortId
                        }
                        Send-WsJson $ws @{
                            type = "rpc.exec_heartbeat"
                            payload = @{ requestId = $reqId; pid = $job.Id; alive = $true; elapsedMs = 0 }
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

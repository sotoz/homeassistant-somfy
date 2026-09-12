#Requires -Version 7.0
<#
.SYNOPSIS
    TCP client for the RFLink WiFi bridge. Connects to the ESP32-C3 stream server, sends RFLink
    command lines terminated with CR/LF, and prints every reply line.

.DESCRIPTION
    Phase 3 acceptance tool: proves the bridge is a transparent byte pipe to the Mega before Home
    Assistant is configured. This is the same protocol as Send-RFLink.ps1, over TCP instead of a
    COM port, so a reply here means the whole chain works: TCP -> ESP32-C3 -> UART -> RFLink.

    Unplug the Mega's USB cable from the PC before running this, so the bridge is the only thing
    driving the Mega's serial lines.

    The same destructive commands are refused as in Send-RFLink.ps1 unless -Force is given:
    10;RTSCLEAN;, 10;RTSRECCLEAN=n, 10;RTSINVERT;, 10;RTSLONGTX;

.PARAMETER BridgeHost
    IP or hostname of the bridge, e.g. 192.168.1.50 or rflink-bridge.local

.PARAMETER Port
    TCP port of the stream server. Default 1234, matching esphome\rflink-bridge.yaml.

.PARAMETER Command
    RFLink command lines. Omit to listen only.

.EXAMPLE
    .\Test-RFLinkBridge.ps1 -BridgeHost rflink-bridge.local -Command '10;PING;'
    Expected: 20;xx;PONG;

.EXAMPLE
    .\Test-RFLinkBridge.ps1 -BridgeHost 192.168.1.50 -Command '10;VERSION;','10;RTSSHOW;' -ListenSeconds 8
    Full health check: firmware revision plus the rolling-code table.

.EXAMPLE
    .\Test-RFLinkBridge.ps1 -BridgeHost 192.168.1.50 -ListenSeconds 60
    Listen only: press a button on the Situo and watch the frames arrive over WiFi.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$BridgeHost,

    [Parameter(Position = 1)]
    [string[]]$Command,

    [int]$Port = 1234,

    [ValidateRange(0, 3600)]
    [double]$ListenSeconds = 5,

    [ValidateRange(0, 10000)]
    [int]$InterCommandDelayMs = 400,

    [int]$ConnectTimeoutMs = 5000,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# `pwsh -File` flattens -Command 'a','b' into the single string "a,b"; RFLink commands never
# contain a comma, so splitting on it makes both invocation styles behave the same.
$Command = @($Command ?? @()) |
    ForEach-Object { $_ -split ',' } |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_.Length -gt 0 }

$blacklist = '^\s*10;\s*(RTSCLEAN|RTSRECCLEAN|RTSINVERT|RTSLONGTX)'
foreach ($c in $Command) {
    if ($c -match $blacklist -and -not $Force) {
        throw "Refusing to send '$c'. It destroys or alters RTS pairings. Override with -Force only if you truly mean it."
    }
}

$client = [System.Net.Sockets.TcpClient]::new()
$client.NoDelay = $true
$stream = $null
$pending = ''
$lineCount = 0

function Read-Available {
    param([Parameter(Mandatory)][System.Net.Sockets.NetworkStream]$Stream)

    while ($Stream.DataAvailable) {
        $buffer = [byte[]]::new(4096)
        $read = $Stream.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) { break }
        $script:pending += [System.Text.Encoding]::ASCII.GetString($buffer, 0, $read)
    }

    while ($script:pending -match "`r?`n") {
        $idx  = $script:pending.IndexOf("`n")
        $line = $script:pending.Substring(0, $idx).TrimEnd("`r")
        $script:pending = $script:pending.Substring($idx + 1)
        if ($line.Length -eq 0) { continue }

        $script:lineCount++
        $stamp = (Get-Date).ToString('HH:mm:ss.fff')
        $colour = switch -Regex ($line) {
            'RFLink Gateway'         { 'Green'; break }
            '^20;[0-9a-fA-F]{2};OK;' { 'Green'; break }
            'VER=|PONG'              { 'Green'; break }
            'CMD='                   { 'Yellow'; break }
            default                  { 'Gray' }
        }
        Write-Host "$stamp  RX  $line" -ForegroundColor $colour
    }
}

function Wait-Replies {
    param([Parameter(Mandatory)][System.Net.Sockets.NetworkStream]$Stream, [double]$Seconds)

    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        Read-Available -Stream $Stream
        Start-Sleep -Milliseconds 25
    }
    Read-Available -Stream $Stream
}

try {
    Write-Host "Connecting to ${BridgeHost}:${Port} ..." -ForegroundColor Cyan
    $connect = $client.ConnectAsync($BridgeHost, $Port)
    if (-not $connect.Wait($ConnectTimeoutMs)) {
        throw "No TCP connection to ${BridgeHost}:${Port} within ${ConnectTimeoutMs} ms. Check the bridge is powered, on the network, and that the stream server port matches."
    }
    if ($connect.IsFaulted) { throw $connect.Exception.GetBaseException() }

    $stream = $client.GetStream()
    Write-Host "Connected." -ForegroundColor Cyan

    foreach ($c in $Command) {
        $stamp = (Get-Date).ToString('HH:mm:ss.fff')
        Write-Host "$stamp  TX  $c" -ForegroundColor White
        $bytes = [System.Text.Encoding]::ASCII.GetBytes("$c`r`n")
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
        Wait-Replies -Stream $stream -Seconds ($InterCommandDelayMs / 1000)
    }

    Wait-Replies -Stream $stream -Seconds $ListenSeconds

    if ($pending.Trim().Length -gt 0) {
        Write-Host "$((Get-Date).ToString('HH:mm:ss.fff'))  RX  $($pending.Trim())  <incomplete line>" -ForegroundColor DarkGray
    }
    if ($lineCount -eq 0) {
        Write-Warning 'TCP connected but nothing came back. The socket is fine, so suspect the UART: wrong tx/rx pins on the shield, wrong baud rate, or the Mega is not powered.'
    } else {
        Write-Host "Done. $lineCount line(s) received." -ForegroundColor Cyan
    }
} finally {
    if ($null -ne $stream) { $stream.Dispose() }
    $client.Dispose()
}

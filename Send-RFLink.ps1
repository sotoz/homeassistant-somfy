#Requires -Version 7.0
<#
.SYNOPSIS
    Serial console for an RFLink gateway. Opens a COM port at 57600 8N1, sends command
    lines terminated with CR/LF, and prints every reply line that arrives.

.DESCRIPTION
    Phase 1/2 tool for the Somfy RTS gateway project. Uses System.IO.Ports.SerialPort
    directly, so there is no dependency on PuTTY, the RFLink Loader or the Arduino IDE.

    Destructive RFLink commands are refused unless -Force is given:
        10;RTSCLEAN;         wipes every rolling-code slot
        10;RTSRECCLEAN=n;    wipes one slot
        10;RTSINVERT;        silently flips RTS ON/OFF semantics
        10;RTSLONGTX;        silently changes RTS transmit length
    These destroy or corrupt pairings. There is no reason to send them in this project.

.PARAMETER Port
    COM port name, e.g. COM5. Omit to list candidate ports and exit.

.PARAMETER Command
    One or more RFLink command lines, e.g. '10;VERSION;'. Omit to listen only, which is
    how you capture the Situo remote's address in Phase 2.

.PARAMETER ResetBoard
    Toggle DTR after opening to reset the Mega, so the startup banner
    (20;00;Nodo RadioFrequencyLink - RFLink Gateway V1.1 - Rxx;) is captured.

.PARAMETER ListenSeconds
    How long to keep printing replies after the last command. Default 5.

.EXAMPLE
    .\Send-RFLink.ps1
    Lists COM ports with their descriptions, so you can spot the CH340.

.EXAMPLE
    .\Send-RFLink.ps1 -Port COM5 -ResetBoard -Command '10;VERSION;','10;PING;'
    Resets the Mega, prints the banner, then asks for version and ping.

.EXAMPLE
    .\Send-RFLink.ps1 -Port COM5 -Command '10;RTSSHOW;' -ListenSeconds 8
    Dumps the rolling-code table. Give it time: the table is 16 lines.

.EXAMPLE
    .\Send-RFLink.ps1 -Port COM5 -ListenSeconds 30
    Listen only. Press a button on the Situo remote and read the address RFLink hears.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Port,

    [Parameter(Position = 1)]
    [string[]]$Command,

    [int]$BaudRate = 57600,

    [ValidateRange(0, 3600)]
    [double]$ListenSeconds = 5,

    [ValidateRange(0, 10000)]
    [int]$InterCommandDelayMs = 400,

    [switch]$ResetBoard,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try { Add-Type -AssemblyName 'System.IO.Ports' -ErrorAction Stop } catch { }
if (-not ('System.IO.Ports.SerialPort' -as [type])) {
    throw 'System.IO.Ports is unavailable. Run this in PowerShell 7 on Windows.'
}

function Get-SerialPortInventory {
    $names = [System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object
    $described = @{}
    try {
        foreach ($p in Get-CimInstance -ClassName Win32_SerialPort -ErrorAction Stop) {
            $described[$p.DeviceID] = $p.Description
        }
    } catch { }
    # USB-serial bridges frequently appear only under Win32_PnPEntity.
    try {
        foreach ($d in Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop |
                       Where-Object { $_.Name -match '\(COM\d+\)' }) {
            if ($d.Name -match '\((COM\d+)\)') { $described[$Matches[1]] = $d.Name }
        }
    } catch { }

    foreach ($n in $names) {
        [pscustomobject]@{
            Port        = $n
            Description = if ($described.ContainsKey($n)) { $described[$n] } else { '(no description)' }
        }
    }
}

if (-not $Port) {
    $inventory = @(Get-SerialPortInventory)
    if ($inventory.Count -eq 0) {
        Write-Warning 'No COM ports found. If the Mega is plugged in, install the CH340 driver.'
    } else {
        Write-Host 'Available COM ports:' -ForegroundColor Cyan
        $inventory | Format-Table -AutoSize | Out-Host
        Write-Host 'Re-run with -Port <name>, e.g. .\Send-RFLink.ps1 -Port COM5 -ResetBoard -Command ''10;VERSION;''' -ForegroundColor Cyan
    }
    return
}

# `pwsh -File script.ps1 -Command 'a','b'` flattens the array into the single string "a,b",
# which would put two commands on one RFLink line. RFLink commands never contain a comma,
# so splitting on it is safe and makes both invocation styles behave identically.
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

$sp = [System.IO.Ports.SerialPort]::new($Port, $BaudRate, [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One)
$sp.NewLine      = "`r`n"
$sp.Encoding     = [System.Text.Encoding]::ASCII
$sp.ReadTimeout  = 200
$sp.WriteTimeout = 2000
$sp.DtrEnable    = $false
$sp.RtsEnable    = $false

$pending = ''
$lineCount = 0

function Read-Available {
    param([Parameter(Mandatory)][System.IO.Ports.SerialPort]$SerialPort)

    $chunk = ''
    try { $chunk = $SerialPort.ReadExisting() } catch [TimeoutException] { return }
    if ([string]::IsNullOrEmpty($chunk)) { return }

    $script:pending += $chunk
    while ($script:pending -match "`r?`n") {
        $idx  = $script:pending.IndexOf("`n")
        $line = $script:pending.Substring(0, $idx).TrimEnd("`r")
        $script:pending = $script:pending.Substring($idx + 1)
        if ($line.Length -eq 0) { continue }

        $script:lineCount++
        $stamp = (Get-Date).ToString('HH:mm:ss.fff')
        $colour = switch -Regex ($line) {
            'RFLink Gateway'      { 'Green'; break }
            '^20;[0-9a-fA-F]{2};OK;' { 'Green'; break }
            'VER=|PONG'           { 'Green'; break }
            'CMD='                { 'Yellow'; break }
            default               { 'Gray' }
        }
        Write-Host "$stamp  RX  $line" -ForegroundColor $colour
    }
}

function Wait-Replies {
    param([Parameter(Mandatory)][System.IO.Ports.SerialPort]$SerialPort, [double]$Seconds)

    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        Read-Available -SerialPort $SerialPort
        Start-Sleep -Milliseconds 25
    }
    Read-Available -SerialPort $SerialPort
}

try {
    $sp.Open()
    Write-Host "Opened $Port at $BaudRate 8N1." -ForegroundColor Cyan

    if ($ResetBoard) {
        # A DTR pulse resets the ATmega2560 through the CH340, which makes it reprint its banner.
        $sp.DtrEnable = $true
        Start-Sleep -Milliseconds 120
        $sp.DtrEnable = $false
        Write-Host 'DTR pulsed: waiting for the RFLink banner...' -ForegroundColor Cyan
        Wait-Replies -SerialPort $sp -Seconds 3
    }

    foreach ($c in ($Command ?? @())) {
        $line = $c.Trim()
        $stamp = (Get-Date).ToString('HH:mm:ss.fff')
        Write-Host "$stamp  TX  $line" -ForegroundColor White
        $sp.WriteLine($line)
        Wait-Replies -SerialPort $sp -Seconds ($InterCommandDelayMs / 1000)
    }

    Wait-Replies -SerialPort $sp -Seconds $ListenSeconds

    if ($pending.Trim().Length -gt 0) {
        Write-Host "$((Get-Date).ToString('HH:mm:ss.fff'))  RX  $($pending.Trim())  <incomplete line>" -ForegroundColor DarkGray
    }
    if ($lineCount -eq 0) {
        Write-Warning 'Nothing received. Either the Mega has no RFLink firmware, the baud rate is wrong, or the ESP32-C3 is contending for the same serial lines (unseat it).'
    } else {
        Write-Host "Done. $lineCount line(s) received." -ForegroundColor Cyan
    }
} finally {
    if ($sp.IsOpen) { $sp.Close() }
    $sp.Dispose()
}

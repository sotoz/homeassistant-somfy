# Somfy RTS blinds in Home Assistant, over WiFi, via an RFLink Pro gateway

Control Somfy RTS blinds from Home Assistant without buying a TaHoma/Connexoon hub, without MQTT,
and without a custom integration — using a nodo-shop **RFLink PRO** gateway reached over WiFi by an
**ESP32-C3** acting as a transparent serial-to-TCP bridge.

The gateway is paired to each blind **as an additional remote**, so your existing Somfy remote keeps
working and rolling codes never desynchronise.

Everything here was built and measured on real hardware. Where a claim comes from a datasheet or
official docs it says so; where it comes from a measurement, the measurement is included.

> All addresses, IPs and MAC addresses in this repository are examples. Replace them with your own.

## How it works

```
Home Assistant  ──rflink integration, TCP──►  ESP32-C3 SuperMini (ESPHome + stream_server)
                                                        │  UART 57600 8N1
                                              Mega 2560 Pro running RFLink firmware
                                                        │  433.42 MHz
                                              Somfy RTS motor
```

Three ideas explain the whole system:

1. **RFLink is the API.** The Mega runs finished firmware that speaks a line-based text protocol:
   you send `10;RTS;0A0A0A;0;UP;`, it answers `20;03;OK;`. You never write code for the Mega.
2. **The ESP32-C3 is a wire extension.** It copies bytes between a TCP socket and the Mega's serial
   port, unchanged — no parsing, no reframing. The fewer components that interpret the protocol, the
   fewer can misinterpret it.
3. **Home Assistant already speaks RFLink.** The built-in [`rflink`](https://www.home-assistant.io/integrations/rflink/)
   integration turns cover open/stop/close into those text commands. No HACS, no MQTT broker, no
   scripts in between.

### What you get, and what you don't

- ✅ Open, stop, close from Home Assistant, dashboards and automations
- ✅ The original Somfy remote keeps working
- ✅ Optionally, the entity follows presses on the physical remote (RFLink can *hear* it)
- ✅ Standalone operation: one USB-C adapter powers the whole stack, no PC attached
- ❌ **No position feedback.** RTS is one-way. Home Assistant shows an assumed state, and
  `20;xx;OK;` means "the radio transmitted", never "the blind moved"
- ❌ No tilt/favourite-position support

## Hardware

| Part | Notes |
|---|---|
| RobotDyn Mega 2560 Pro Embed | ATmega2560 + CH340 USB-serial. Any Mega 2560 works; RFLink targets this MCU |
| [nodo-shop RFLink PRO](https://www.nodo-shop.nl/21-rflink-) shield, V1.2 (2024) | Carries the transceiver, SMA connector, and a socket for the ESP32-C3 |
| Aurel RTX MID transceiver, **433.42 MHz** | The frequency matters: Somfy RTS is 433.42 MHz, not 433.92 |
| ESP32-C3 SuperMini | Ships with a LuatOS image; gets reflashed with ESPHome. UART0 = GPIO21 TX / GPIO20 RX |
| 5 V USB-C adapter | Powers the stack through the C3; the shield feeds the Mega |
| An already-paired Somfy remote (e.g. Situo 1 RTS) | Needed for its PROG button, to authorise a new remote |

The ESP32-C3 is **directly connected** to the Mega's UART0 by the shield — no level shifter, since
the C3's pins are 5 V tolerant. If you wire an ESP to a Mega yourself instead of using this shield,
check that; the Home Assistant docs recommend a BSS138 level shifter for the ESP8266 case.

## Software prerequisites

- Home Assistant (any install type). The reference build is **HAOS 2026.9.2** on a Pi 4
- ESPHome **2026.8.2+** for building the bridge firmware — see [Rebuilding the bridge](#rebuilding-the-bridge-firmware)
- PowerShell 7 on Windows for the helper scripts (they use `System.IO.Ports` / `TcpClient`; port
  them to `pyserial`/`socat` on Linux if you prefer)
- The CH340 driver, if your Mega's COM port doesn't appear on Windows

## Repository layout

| File | Purpose |
|---|---|
| `Send-RFLink.ps1` | Serial console over USB: send RFLink commands, print replies. Used for pairing |
| `Test-RFLinkBridge.ps1` | The same over TCP, to test the bridge with Home Assistant out of the way |
| `esphome/rflink-bridge.yaml` | Bridge firmware configuration |
| `esphome/secrets.yaml.example` | Template for WiFi credentials and keys — copy to `secrets.yaml` |
| `homeassistant/configuration-rflink.yaml` | Blocks to paste into `configuration.yaml` |
| `homeassistant/automation-sunset.yaml` | Example automation, to prove service calls reach the cover |
| `TROUBLESHOOTING.md` | Symptom → likely cause → how to confirm → fix |

Both scripts **refuse the destructive RFLink commands** (`10;RTSCLEAN;`, `10;RTSRECCLEAN=n`,
`10;RTSINVERT;`, `10;RTSLONGTX;`) unless you pass `-Force`. The first two erase pairings; the last
two silently change RTS behaviour for every RTS device on the gateway.

## Step by step

### 0. Fill in a worksheet first

One row per blind. Choose addresses that are unique, easy to spot in a log, and **never starting
with `00`** (community convention — it is not in the protocol reference):

| Blind | RTS address | Start rolling code | EEPROM record | HA device ID |
|---|---|---|---|---|
| Upstairs blinds | `0A0A0A` | `0101` | `4` | `RTS_0A0A0A_0` |

RFLink stores rolling codes in **16 EEPROM slots (0–15)**. Keep this worksheet: with it, re-pairing
after an EEPROM loss takes a minute; without it, you are guessing.

### 1. Check the Mega's firmware

Plug the Mega into your PC by USB. If the ESP32-C3 is seated on the shield, leave it unpowered —
both it and the CH340 drive the Mega's UART0, and two masters produce garbage.

```powershell
.\Send-RFLink.ps1                                    # lists COM ports; look for USB-SERIAL CH340
.\Send-RFLink.ps1 -Port COM3 -ResetBoard -Command '10;VERSION;','10;PING;'
```

Expected:

```
20;00;Nodo RadioFrequencyLink - RFLink Gateway V1.1 - R51
20;04;VER=1.1;REV=51;BUILD=01;
20;05;PONG;
```

A version reply means RFLink is already installed — many nodo-shop boards ship pre-flashed, so
**check before you flash anything**. If it stays silent, get the firmware from
[rflink.nl/download.php](https://www.rflink.nl/download.php) and flash it with the RFLink Loader, or
with `avrdude` against `atmega2560`.

Then inspect the rolling-code table, and **do not assume it is empty**:

```powershell
.\Send-RFLink.ps1 -Port COM3 -Command '10;RTSSHOW;' -ListenSeconds 8
```

### 2. Find your remote's address before choosing yours

With the console listening, press a button on your Somfy remote:

```powershell
.\Send-RFLink.ps1 -Port COM3 -ListenSeconds 60
```

```
20;06;DEBUG;RTS P1;a541081ea1b2c3;
20;07;RTS;ID=a1b2c3;SWITCH=01;CMD=DOWN;
```

This does three jobs: proves the receiver works, gives you the alias for Home Assistant
(`rts_<address>_01` — note the **two-digit** switch), and reveals collisions. In the reference
build, the remote's address `a1b2c3` turned out to be **already stored in EEPROM record 0** by a
previous owner — a clone of the physical remote with a counter 330 presses stale. Transmitting from
such a slot fights your real remote. If you find one, blacklist that slot and pick a different
address.

### 3. Pair, over USB

Timing is tight, so type the command first and press Enter on the visual cue:

1. Hold **PROG** on the back of the remote until the blind jogs once.
2. Press Enter immediately:
   ```powershell
   .\Send-RFLink.ps1 -Port COM3 -Command '10;RTS;0A0A0A;0101;4;PAIR;'
   ```
3. The blind jogs again and you get `20;xx;OK;` — about **3.3 s later**, because that delay is the
   PROG frame being transmitted.

**Send it exactly once.** In Somfy RTS, a second PROG frame from an already-known remote *removes*
it, so a "let's try again" retry can silently undo a successful pairing. If nothing happened, wait
for the blind to leave programming mode (~30 s) and start over from step 1.

Verify, then test:

```powershell
.\Send-RFLink.ps1 -Port COM3 -Command '10;RTSSHOW;' -ListenSeconds 8
.\Send-RFLink.ps1 -Port COM3 -Command '10;RTS;0A0A0A;0;UP;'
.\Send-RFLink.ps1 -Port COM3 -Command '10;RTS;0A0A0A;0;STOP;'
```

Leave **~6 seconds between commands** — see [measured behaviour](#measured-behaviour-read-this-before-debugging).

### 4. Flash the bridge

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install esphome
Copy-Item esphome\secrets.yaml.example esphome\secrets.yaml   # then fill in WiFi + generate keys
esphome run --device <node-hostname-or-ip> esphome\rflink-bridge.yaml
```

Generate the API key with:

```powershell
[Convert]::ToBase64String((1..32 | ForEach-Object { Get-Random -Maximum 256 }))
```

If your C3 already runs the stock `esphome-web` firmware (from `web.esphome.io`), **no USB cable is
needed** — it installs over the air. That firmware ships with a bare `api:` and a password-less
`ota:`, so a takeover is permitted; add `use_address: esphome-web-xxxxxx.local` to the `wifi:` block
for the first upload only, since the node still answers to its factory name, then remove it.

Always pass `--device`. Otherwise `esphome run` offers the local COM port — which is the **Mega**,
not the C3.

What the config does, and why:

- `stream_server` on TCP **1234**, UART **57600 8N1** on **GPIO21/GPIO20**
- `logger: hardware_uart: USB_SERIAL_JTAG` so log output can never reach the Mega's RX line
- `rx_buffer_size: 1024` and `buffer_size: 512`, because `10;RTSSHOW;` emits ~1.3 kB in one burst
  and the 128-byte default truncates it
- No `manual_ip:` — pin a DHCP lease on your router instead, so one bad static block can't lock you
  out of OTA
- A `connected` binary sensor, so Home Assistant can see whether the stream has a client

### 5. Test the bridge before involving Home Assistant

Unplug the Mega's USB from the PC and power the stack from the USB-C adapter on the C3, so only one
master drives the serial lines. Then:

```powershell
Test-NetConnection <bridge-ip> -Port 1234
.\Test-RFLinkBridge.ps1 -BridgeHost <bridge-ip> -Command '10;PING;','10;VERSION;'
```

`20;xx;PONG;` proves the whole chain: TCP → ESP32-C3 → UART → RFLink. If TCP connects but nothing
comes back, the fault is the UART — swap `tx_pin`/`rx_pin` and rebuild.

### 6. Configure Home Assistant

Add to `configuration.yaml` — **nested format only**; the old `cover: - platform: rflink` form is
removed in Home Assistant **2026.12.0**:

```yaml
rflink:
  host: 192.168.1.50        # your bridge's pinned IP
  port: 1234                   # with `host` set, this is the TCP port, not a serial path
  tcp_keepalive_idle_timer: 600
  cover:
    devices:
      RTS_0A0A0A_0:
        name: Upstairs blinds
        aliases:
          - rts_a1b2c3_01      # your physical remote, so the entity tracks it
        # type: inverted        # only if open/close come out backwards
```

The trailing `_0` is not cosmetic. `python-rflink` builds commands as
`{node};{protocol};{id};{switch};{command};`, so `RTS_0A0A0A_0` emits exactly
`10;RTS;0A0A0A;0;UP;` — the documented RTS form where that field is unused.

Then restart and verify:

```bash
ha core check && ha core restart          # HAOS/Supervised
# hass --script check_config -c /config   # Core in a venv
```

Add debug logging while bringing it up, and remove it afterwards — it is the only thing that
distinguishes "HA never sent the command" from "the motor ignored it":

```yaml
logger:
  default: error
  logs:
    rflink: debug
    homeassistant.components.rflink: debug
```

### 7. Harden

- Power-cycle the bridge; confirm Home Assistant reconnects and the cover still works
- Restart Home Assistant; confirm the same
- Run [`automation-sunset.yaml`](homeassistant/automation-sunset.yaml) manually to prove service
  calls reach the cover
- Pin the DHCP lease against the C3's MAC
- Remove the debug `logger:` block

## Measured behaviour (read this before debugging)

Numbers measured on RFLink **R51** with a Somfy RTS blind:

| Observation | Value | Why it matters |
|---|---|---|
| RTS command transmit time | **~3.2 s** before `20;xx;OK;` | The ack is not slow software; it's the radio. `wait_for_ack: true` serialises on it |
| Receiver ignore-window | 2.8 s after the ack is **ignored**, 5.8 s **works** | Leave ~6 s between commands. Rapid open-then-stop taps silently do nothing |
| Command latency over the bridge | 70–150 ms | The WiFi hop is negligible next to the radio |
| `10;RTSSHOW;` output | printed **twice**, as plain text | Not `20;xx;` packets, so `python-rflink` logs it as unparseable. Expected |
| Rolling code on air | RFLink **updates a stored slot's counter when it hears that address** | A slot cloned from your remote tracks it — but still must not be used to transmit |
| EEPROM persistence | Survived cold boot | Pairings are not lost by power cycling; only by `RTSCLEAN`/`RTSRECCLEAN` or an EEPROM erase |

The most confusing failure in the reference build: after a successful pairing, `UP` worked and a
`STOP` sent 6 s later did nothing, while the rolling counter advanced for both. Every frame *was*
transmitted; the motor simply ignored the second. The fix was pacing, not pairing.

## Gotchas that cost real time

- **`10;RTSSHOW;` may not be empty on a new board.** Check before you claim a slot, and never assume
  slot 0 is free.
- **A slot holding your remote's own address is a trap.** Transmitting from it fights the physical
  remote's counter.
- **`oxan/esphome-stream-server` master does not build on ESPHome 2026.7+** — `network::get_use_address()`
  was removed and the fix sits in unmerged PRs. This project pins
  `github://grob6000/esphome-stream-server@get_use_address_to` (upstream master + a 4-line fix).
  `thegroove/esphome-serial-server` is abandoned (last push 2021).
- **ESPHome's `serial_proxy` cannot replace this.** It exposes a UART over the ESPHome *native API*,
  not as a TCP socket, and `rflink` is a YAML-only integration that takes a serial path or
  `host`+`port`. Plain TCP is the supported route.
- **Windows `MAX_PATH` breaks ESP-IDF builds** with a missing header that is present on disk
  (`fatal error: bits/os_defines.h: No such file or directory`). GCC probes multilib include dirs
  through un-normalized self-relative paths, inflating a 210-character path past 260. Fix:
  ```powershell
  [Environment]::SetEnvironmentVariable('ESPHOME_ESP_IDF_PREFIX','C:\idf','User')
  ```
  ESPHome's own check requires the tools path + 245 < 260, so keep that prefix ≤15 characters.
  Alternatively enable long paths (`LongPathsEnabled=1`, admin + reboot) or build on Linux.
- **The Home Assistant ESPHome integration cannot compile YAML.** It is a client for finished
  devices. Building needs the ESPHome Device Builder or the CLI.
- **On HAOS, the SSH add-on's `/config` may not be Home Assistant's config directory** (it is often
  `/homeassistant`, sometimes symlinked). Check before concluding your YAML was ignored.
- **One TCP client at a time.** `stream_server` broadcasts replies to every client, so a test script
  running alongside Home Assistant produces interleaved, confusing output.

## Rebuilding the bridge firmware

```powershell
esphome run --device rflink-bridge.local esphome\rflink-bridge.yaml
```

On Home Assistant OS or Supervised you can instead install the **ESPHome Device Builder** add-on and
build there — no Windows toolchain, no `MAX_PATH` problem, at the cost of slower compiles on a Pi.
The CLI path above is what this repository was built and tested with.

USB-C on the C3 is only the recovery path: hold **BOOT**, tap **RESET**, release **BOOT**, then
flash over the native USB serial/JTAG interface.

## Backup and recovery

Back up three things:

1. **A Home Assistant backup** (Settings → System → Backups, or `ha backups new`) — covers
   `configuration.yaml`.
2. **This repository** — firmware config, scripts, and the worksheet. Keep `esphome/secrets.yaml`
   out of it; it is gitignored and holds your WiFi password, API key and OTA password.
3. **The worksheet values** — address, EEPROM record, starting rolling code. These are the only
   values that cannot be recovered by inspecting something else.

If a slot is ever wiped, recovery needs no guesswork: plug the Mega into a PC, unpower the C3, hold
PROG until the blind jogs, and re-send the worksheet's pairing command **once**. Because the address
and record are unchanged, Home Assistant needs no edits.

## Adapting this

- **More blinds:** one worksheet row each, a distinct address and free EEPROM record per blind, one
  `RTS_<addr>_0` device each. 16 slots total. Mind the pacing when commanding several at once.
- **No compiler available:** ESPEasy with plugin **P020 "Serial Server"** in RFLink mode (57600, TCP
  1234) ships as a pre-built binary and is community-confirmed on this exact nodo board. You lose
  ESPHome OTA, the HA device entry and the connected sensor.
- **Home Assistant on the same machine as the Mega:** skip the bridge entirely and point `rflink:`
  at the serial device with `port: /dev/serial/by-id/...`.
- **Other RF devices:** RFLink speaks many protocols; the `rflink` integration exposes lights,
  switches, sensors and binary sensors too. This project deliberately touches only RTS.

## Sources

- [RFLink protocol reference](https://www.rflink.nl/protref.php) — command syntax, 57600 8N1,
  `RTSSHOW`/`RTSCLEAN`, RTS pairing forms
- [RFLink downloads](https://www.rflink.nl/download.php) and [FAQ](https://www.rflink.nl/faq.php) —
  firmware, and the "pair as a second remote" recommendation
- [Home Assistant `rflink` integration](https://www.home-assistant.io/integrations/rflink/) — TCP
  mode, nested configuration format, legacy-format removal in 2026.12.0
- [`aequitas/python-rflink`](https://github.com/aequitas/python-rflink) — how device IDs become
  wire commands
- [`oxan/esphome-stream-server`](https://github.com/oxan/esphome-stream-server) — the UART-to-TCP
  component
- [ESPHome install docs](https://esphome.io/install/) and [`serial_proxy`](https://esphome.io/components/serial_proxy/)
- [`filipmaelbrancke/ha-rflink-rts`](https://github.com/filipmaelbrancke/ha-rflink-rts) — earlier
  community write-up of the RTS pairing flow
- [Somfy RTS protocol analysis](https://pushstack.wordpress.com/somfy-rts-protocol/) — rolling codes
  and framing
- [Home Assistant community thread on the nodo RFLink Pro](https://community.home-assistant.io/t/nodo-rflink-pro-module-first-time-setup/808384)
  — the ESPEasy P020 route

## License

[MIT](LICENSE). The pinned `stream_server` fork is a separate project with its own (unclear,
GitHub-reported `NOASSERTION`) licence; this repository only references it by URL and does not
redistribute its code.

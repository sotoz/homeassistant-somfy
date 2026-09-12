# Troubleshooting

Every "confirm it" step below is a command you can run, not a guess. Timings quoted as measured
come from this gateway (RFLink R51) on 2026-09-12.

Two numbers to keep in mind, because they explain most surprises:

- An RTS command occupies the gateway for **~3.2 s** before its `20;xx;OK;` ack.
- The Somfy receiver ignores a new command that arrives too soon after the previous one. Measured:
  2.8 s after the ack is **ignored**, 5.8 s after the ack **works**. Leave ~6 s between commands.

| Symptom | Most likely cause | How to confirm | Fix |
|---|---|---|---|
| **Blind ignores commands after successful pairing** | Commands sent too close together. Only the first of a burst is obeyed — the receiver treats the rest as repeats. This exact symptom cost us Phase 2: UP worked, STOP and DOWN 6 s apart did nothing. | `.\Send-RFLink.ps1 -Port COM3 -Command '10;RTSSHOW;'` — if the record's RC is advancing, RFLink *is* transmitting and the motor is ignoring, not missing, the frames. Then send one command alone and watch the blind. | Leave ≥6 s between commands. In HA, don't tap open then stop immediately. If you need it faster, `10;RTSLONGTX;` toggles RFLink's long-transmit mode — non-destructive but it changes RTS timing, so read the toggle back with `10;RTSSHOW;` and change one thing at a time. |
| | Rolling code outside the receiver's forward window, e.g. many frames burned while the motor wasn't listening. | Compare the record's RC in `10;RTSSHOW;` against what the motor last accepted — if dozens of codes were burned with no motion, suspect this. | Re-pair the same address on the same record: `10;RTS;0A0A0A;<newcode>;4;PAIR;`. Rewriting a slot is idempotent and does not disturb other slots. |
| **Pairing never gets `OK`** | The command went out but you are looking for the wrong thing: `OK` is RFLink acking the serial command, and it arrives **~3.3 s late** because the PROG frame is still transmitting. | Watch the timestamps: `TX 10;RTS;...PAIR;` then `RX 20;xx;OK;` about 3.3 s later. | Nothing to fix. Increase `-ListenSeconds` if your window closed too early. |
| | No serial connection at all — wrong port, or the ESP32-C3 is contending for the same lines. | `.\Send-RFLink.ps1` with no arguments lists ports; look for `USB-SERIAL CH340`. | Use the CH340 port. If it is silent, unseat the ESP32-C3 and retry — both it and the CH340 drive the Mega's UART0. |
| | `OK` arrives but the blind never jogs a second time: the PROG frame landed outside the blind's programming window. | The EEPROM record will still show your address — `OK` and a stored record prove transmission, not acceptance. | Hold PROG until the blind jogs, then send the pair command within ~3 s. Type the command first, press Enter after the jog. Send it **once**: a second PROG frame from an already-known remote *removes* it. |
| **RTSSHOW shows the record but the blind moves the wrong way** | Open and close are inverted for this motor. | Send `10;RTS;<addr>;0;UP;` from the serial console. If the blind closes, it is inverted. | Add `type: inverted` to the cover in `configuration.yaml`. Fix it in HA, not with `10;RTSINVERT;` — that toggle is global to all RTS devices and persists in the gateway. |
| **Home Assistant shows the entities but nothing moves** | Device ID is wrong, so HA transmits an address the motor was never paired with. | Enable the `logger:` block and watch for `10;RTS;0A0A0A;0;UP;`. If the address or the trailing field differ from the worksheet, that is the fault. | Use `RTS_<ADDRESS>_0`. The ID becomes `{protocol};{id};{switch};{command}`, so `_0` yields the documented `;0;` form. |
| | HA is connected to the bridge but the bridge is not reaching the Mega. | `.\Test-RFLinkBridge.ps1 -BridgeHost <ip> -Command '10;PING;'` with HA stopped. Silence with a successful TCP connect means the UART, not the network. | Swap `tx_pin`/`rx_pin` in `esphome\rflink-bridge.yaml` (GPIO21/GPIO20 are the module defaults; the shield's routing is undocumented), or check the Mega is powered. |
| | Dead socket that HA still believes in, typically after the AP or NAT dropped an idle connection. | In HA's log, commands are logged as sent but no `20;xx;OK;` ever comes back. | `tcp_keepalive_idle_timer: 600`. Restart HA to force a reconnect. |
| **Home Assistant cannot connect to the bridge** | Bridge IP changed — DHCP lease moved. | `Test-NetConnection <ip> -Port 1234`. Then look up the current IP in UniFi by MAC `AA:BB:CC:DD:EE:FF`. | Pin the fixed lease on the router, and put that IP in `rflink: host:`. |
| | Another client already holds the stream. | `.\Test-RFLinkBridge.ps1` works while HA is stopped, but replies are interleaved or missing when HA is running. | Run exactly one client at a time. Stop your test script before starting HA, and vice versa. |
| | VLAN or firewall blocks the port. | `Test-NetConnection` from a host on HA's VLAN, not just from your desktop. | Allow HA → bridge TCP 1234. |
| **Garbage characters in the log** | Two drivers on one wire: the CH340 (PC USB) and the ESP32-C3 both drive the Mega's UART0. | Unplug the Mega's USB cable from the PC and retry. If the garbage disappears, that was it. | Only one master at a time: USB for pairing, bridge for normal operation. |
| | Baud mismatch. | Clean text at 57600 elsewhere, garbage here. | `baud_rate: 57600` in the UART block; RFLink's protocol reference fixes this at 57600 8N1. |
| | Harmless variant: a short burst of junk immediately before the banner after a reset. | Only ever appears right after a DTR pulse or power-up, e.g. `?L?????R=AR...`. | Ignore — that is the ATmega bootloader talking at its own baud rate. |
| | Not garbage at all: `RTS Record: ...` lines in HA's debug log. | These appear only after `10;RTSSHOW;`. | Expected. `RTSSHOW` output is plain text, not `20;xx;` packets, so python-rflink cannot parse it. |
| **Everything works over USB but not over WiFi** | Wrong ESP32 pins for this shield — the one fact nodo never documented. | TCP connects, `10;PING;` returns nothing. That combination isolates the fault to the UART. | Swap `tx_pin: GPIO21` / `rx_pin: GPIO20` in the YAML, rebuild, OTA, retest. |
| | ESPHome logger writing into the Mega's RX. | Garbage on the Mega's side, or the Mega misbehaving only when the bridge is active. | `logger: hardware_uart: USB_SERIAL_JTAG` (the C3 default, set explicitly in our YAML). Never let the logger share the RFLink UART. |
| | Mega not powered when the PC cable is out. | Mega's power LED dark with only the C3's USB-C adapter connected. | Confirmed working on this hardware. If it ever regresses, power the Mega from its own USB port. |
| | Buffer too small for an `RTSSHOW` burst, so lines are truncated over TCP. | Serial console prints all 16 records; the TCP client shows fewer. | `rx_buffer_size: 1024` on the UART and `buffer_size: 512` on `stream_server` (both already set). |

## Commands that must never be sent

`10;RTSCLEAN;` (wipes all 16 slots), `10;RTSRECCLEAN=<n>` (wipes one), `10;RTSINVERT;` and
`10;RTSLONGTX;` (silently change RTS semantics for every RTS device). Both PowerShell scripts refuse
all four unless `-Force` is given.

## Addresses that must never be transmitted from

`A1B2C3` — EEPROM record 0. That is the Situo remote's own address, cloned by a previous owner with
a stale counter. Transmitting from it would fight the physical remote. Our blind uses `0A0A0A` on
record 4. Records 1–3 (`9BF93A`, `02C00C`, `02FFFF`) are unidentified pre-existing entries and are
left untouched.

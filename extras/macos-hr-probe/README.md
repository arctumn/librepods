# macOS heart-rate probe

> ## Status: the buds accept the stream, then send nothing
>
> No heart-rate reading has been obtained. That is now a **result** rather than a
> shortcoming of the tool: on a fully served AAP session the buds answer the
> request with the `4A 02 08 13` stream ACK and then deliver zero readings — the
> same behaviour Windows sees, on a host whose SDP Device ID record is
> byte-identical to an iPhone's. Read *Where it actually stands* below.

Opens the AAP L2CAP channel (**PSM `0x1001`**) to AirPods from user space via
IOBluetooth and replays the heart-rate start sequence that works on Android.

## Why macOS is the right host to test this on

Two reasons, and together they make this the cleanest available experiment.

**No kernel driver needed.** macOS exposes L2CAP to user space
(`openL2CAPChannelSync`). Windows exposes only RFCOMM, which is why this repo
carries an entire KMDF driver (`windows/drivers/aap/`) just to reach the same
channel. Here it is ~200 lines of Swift.

**A Mac passes every Apple-host identity check.** A Mac's SDP Device ID record is
**byte-identical** to an iPhone's — same `004C:7805:1A50`, same Apple-private
`0xA000`/`0xA001`/`0xAFFF` attributes (see *Host Identification* in
`AAP Definitions.md`). So this isolates the variable:

| Outcome | What it proves |
|---|---|
| Readings arrive | Host identity is **not** the gate. The macOS absence of heart rate is missing software (no HealthKit), not a refusal by the accessory. |
| Buds ACK `4A 02 08 13` then send nothing | Same behaviour as Windows — on a host whose DID is indistinguishable from an iPhone's. The gate is deeper than the DID record. |

**This is the outcome that was measured** — the second row. Details below.

## Build

```sh
xcrun swiftc -O main.swift -o hr-probe
```

## Run

```sh
./hr-probe                                   # first paired device named "AirPod*"
./hr-probe --address xx-xx-xx-xx-xx-xx       # explicit
./hr-probe --seconds 90                      # longer listening window
```

In practice `./hr-probe` on its own will fail with `0xE00002BC` whenever macOS
has the buds connected. Use the wrapper, which clears that first:

```sh
brew install blueutil switchaudio-osx
./grab-channel.sh --seconds 90
```

See *Known failure modes* for why it works.

Requires **AirPods Pro 3 or later** — earlier models have no PPG sensor. Wear
both buds for the whole run; the sensor only reports while they are in your ears.

## What it sends

Byte-identical to `thibaup/librepods` branch `heart-rate-monitoring`, which is a
working Android implementation, and to what `windows/daemon` already sends:

```
connect service 0        00 00 00 00 01 00 03 00 ...      + 180 ms
capabilities 0           04 00 00 00 01 00 00             + 220 ms
connect service 4        00 00 04 00 01 00 03 00 ...      + 180 ms
capabilities 4           04 00 04 00 01 00 00             + 220 ms
HRM_STATE enable         04 00 04 00 09 00 30 01 00 00 00 + 500 ms
HEART_RATE_START_1S      04 00 04 00 17 00 ... 08 13 ... 40 42 0F 00
```

Readings arrive as `08 13 1A 12` followed by an 18-byte payload; BPM is
`payload[1]`, and `payload[5] == 2` means the reading has locked. The first few
samples are noise and are labelled `acquiring`.

## Where it actually stands

Measured against real AirPods Pro on 2026-08-11. Three things were established,
in order.

**1. The channel opens from user space.** `openL2CAPChannelSync` on PSM `0x1001`
succeeds and `l2capChannelOpenComplete` fires with status 0. This is the barrier
that required a whole KMDF driver on Windows.

**2. The AAP handshake is mandatory, and the Android heart-rate sequence does not
contain it.** The Android code's `initializeAacpSession()` (connect/capabilities
for services 0 and 4) runs *on top of* an already-established session. Sending
only those frames gets the channel **torn down by the buds after 4.2 s**. Adding
`00 00 04 00 01 00 02 …` first — the handshake `AAP Definitions.md` documents as
mandatory — changed that: the channel then survived the full 40 s window and the
buds answered `connect service 4` with

```
01 00 04 00 85 00 01 00 03 00 00 00 00 00 00 00 00 00
```

(`01 00 04 00` is `HANDSHAKE_ACK`, per `linux/airpods_packets.h`.)

**3. The session is served on some runs and dead on others, and you can tell
which from the first response.** This is the variable that decides whether a run
means anything, so check it before reading any heart-rate conclusion:

```
served      RX 01 00 04 00 00 00 01 00 03 ...   answers the handshake in ~110-150 ms,
                                                then floods: name, battery, capabilities,
                                                ear detection, for the whole window
not served  RX 01 00 04 00 85 00 01 00 03 ...   nothing answers the handshake; this
                                                arrives only after `connect service 4`
                                                and is the *only* frame of the run
```

On a dead run, `request notifications` (`FF FF FF FF`) produces **zero** battery
or ear-detection packets across the window — even while an earbud is physically
removed and reinserted, which the buds themselves register (ANC audibly
switches). What flips a run from one to the other is not yet known; it is the
open question in this directory.

**4. On a served session, the buds ACK heart rate and withhold the data.** This
is the measurement the tool exists to make. A 60 s run with a live session —
battery and ear-detection flowing throughout — requested the stream and got back,
twice:

```
RX ACK 4A 02 08 13 — buds accepted the heart-rate stream
```

and not one reading. So the right-hand row of the table above is the one that
happened: **the gate is deeper than the DID record.**

That also settles a tempting next move. Spoofing the Apple Device ID
(`004C:7805:1A50`) onto a non-Apple host will not unlock heart rate — per *Host
Identification* in `AAP Definitions.md`, iPhone and Mac return all 54 bytes
identically, so `ProductID 0x7805` means "Apple host", not "iPhone", and this
result was obtained on a host already carrying it. Spoofing it is only worth
doing for the lesser goal of getting a session *served* at all.

## Known failure modes

| IOReturn | Meaning | Notes |
|---|---|---|
| `0xE00002D6` | `kIOReturnTimeout` | No baseband link — Bluetooth off, or buds in the case. |
| `0xE00002BC` | `kIOReturnError` | macOS `bluetoothd` holds PSM `0x1001`. By far the most common. |

**The `bluetoothd` contention is solved — use `grab-channel.sh`.** While macOS
has the AirPods connected it owns the AAP channel and every open is refused with
`0xE00002BC`. Disconnecting by hand does not help for long, because the buds are
usually the Mac's **default audio output device**, and `coreaudiod` re-acquires
them within a second. Move the output somewhere else *first* and the disconnect
sticks:

```sh
brew install blueutil switchaudio-osx
./grab-channel.sh              # parks audio elsewhere, disconnects, then probes
```

Measured: the channel opened on **attempt 1**, ~930 ms after the request, with no
racing at all. Setting *Connect to This Mac → When Last Connected to This Mac*
does **not** help on its own, and neither does a manual disconnect — it is the
audio-output ownership that has to go first.

**`--steal` does not work — do not rely on it.** It calls
`IOBluetoothDevice.closeConnection()` before opening, on the theory that dropping
the baseband link makes `bluetoothd` release the channel. In practice the open
still fails and IOBluetooth spins: one run produced **170 630**
`openComplete status=0xE00002BC` callbacks in a few seconds. The flag is kept only
so the next person does not waste time re-inventing it.

## Open questions

**What flips a session from served to dead?** See point 3 above. Until that is
understood, a run that shows the `85 00` first response should be discarded, not
reported.

**Is the gate privilege rather than identity?** The Android implementation this
tool replays is not an ordinary application. It ships a Magisk module
(`root-module-manual/`) whose payload is
`system/etc/permissions/privapp-permissions-librepods.xml`, so it runs as a
**privileged system app**, and it does not use the public Bluetooth API to reach
the channel — `BluetoothConnectionManager.kt` builds the `BluetoothSocket` by
reflection, hunting for a hidden constructor taking `(type, auth, encrypt, psm,
uuid)` across five signatures. So on Android LibrePods is *inside* the host's
Bluetooth stack, whereas here — and on Windows — it opens a second, unprivileged
AAP session while the OS remains the buds' real host. That difference is
unexplored and fits the symptoms better than any identity theory the DID record
can support.

**Not tried:** keeping the buds connected to a *different* host (an iPhone) so
macOS never claims them while still being reachable for a second AAP session.
Unpairing is not an option — the link key is needed for the encrypted link.

## Privacy

The probe prints the device name and Bluetooth address of whatever it finds.
Those identify you. Publish decoded protocol facts, not raw logs — same rule as
`AAP Definitions.md` gives for `.pklg`/`.pcap` captures.

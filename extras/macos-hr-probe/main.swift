/*
    LibrePods - AirPods liberated from Apple's ecosystem
    Copyright (C) 2025 LibrePods contributors

    macOS heart-rate probe.

    Opens the AAP L2CAP channel (PSM 0x1001) to a pair of AirPods straight from
    user space via IOBluetooth — no kernel driver needed, unlike Windows — and
    replays the heart-rate start sequence that is known to work on Android
    (thibaup/librepods, branch heart-rate-monitoring).

    Why a Mac is the interesting host: a Mac's SDP Device ID record is
    byte-identical to an iPhone's (see "Host Identification" in AAP
    Definitions.md), so it passes any Apple-host identity check. If readings come
    back here, host identity is not the gate. If they do not, the gate is deeper
    than the DID record.
*/

import Foundation
import IOBluetooth

// MARK: - Protocol constants

let AAP_PSM: BluetoothL2CAPPSM = 0x1001

/// Frames as sent by the working Android implementation. The 4-byte
/// `04 00 04 00` prefix that Android's sendDataPacket() prepends is written out
/// in full here.
enum Frame {
    /// The base AAP handshake. `AAP Definitions.md`: "necessary to establish a
    /// connection with the AirPods. Or else, the AirPods will not respond to any
    /// packets." The Android heart-rate code does NOT send this — it runs on top
    /// of a session that already did.
    static let handshake: [UInt8] = [
        0x00, 0x00, 0x04, 0x00, 0x01, 0x00, 0x02, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ]

    /// Subscribe to notifications; also part of establishing a normal session.
    static let requestNotifications: [UInt8] = [
        0x04, 0x00, 0x04, 0x00, 0x0F, 0x00, 0xFF, 0xFF, 0xFF, 0xFF,
    ]

    /// Host feature bitmask. `FF ...` is what a Mac sends (AAP Definitions.md).
    static let setFeatures: [UInt8] = [
        0x04, 0x00, 0x04, 0x00, 0x4D, 0x00,
        0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ]

    static let connectService0: [UInt8] = [
        0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x03, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ]
    static let capabilitiesService0: [UInt8] = [0x04, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00]
    static let connectService4: [UInt8] = [
        0x00, 0x00, 0x04, 0x00, 0x01, 0x00, 0x03, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ]
    static let capabilitiesService4: [UInt8] = [0x04, 0x00, 0x04, 0x00, 0x01, 0x00, 0x00]

    /// Control command 0x30 (HRM_STATE) = enable.
    static let hrmEnable: [UInt8] = [0x04, 0x00, 0x04, 0x00, 0x09, 0x00, 0x30, 0x01, 0x00, 0x00, 0x00]

    /// Start sensor stream 0x13 (data type 19, heart rate) at a 1 000 000 us period.
    static let heartRateStart1s: [UInt8] = [
        0x04, 0x00, 0x04, 0x00,
        0x17, 0x00, 0x00, 0x00, 0x10, 0x00, 0x10, 0x00,
        0x08, 0xE3, 0x46, 0x42, 0x0B, 0x08, 0x13, 0x10,
        0x02, 0x1A, 0x05, 0x01, 0x40, 0x42, 0x0F, 0x00,
    ]

    /// Raw PPG (stream 0x10, data type 16) at 20 000 us = 50 Hz. iOS starts this
    /// 40 ms AFTER the heart-rate stream; heart rate may be derived from it and
    /// may not produce anything without it running.
    static let ppgStart50Hz: [UInt8] = [
        0x04, 0x00, 0x04, 0x00,
        0x17, 0x00, 0x00, 0x00, 0x10, 0x00, 0x10, 0x00,
        0x08, 0xE4, 0x46, 0x42, 0x0B, 0x08, 0x10, 0x10,
        0x02, 0x1A, 0x05, 0x01, 0x20, 0x4E, 0x00, 0x00,
    ]

    static let ppgStop: [UInt8] = [
        0x04, 0x00, 0x04, 0x00,
        0x17, 0x00, 0x00, 0x00, 0x10, 0x00, 0x10, 0x00,
        0x08, 0xEE, 0x46, 0x42, 0x0B, 0x08, 0x10, 0x10,
        0x02, 0x1A, 0x05, 0x01, 0x00, 0x00, 0x00, 0x00,
    ]

    /// Same stream, period 0 — a zero period is the stop.
    static let heartRateStop: [UInt8] = [
        0x04, 0x00, 0x04, 0x00,
        0x17, 0x00, 0x00, 0x00, 0x10, 0x00, 0x10, 0x00,
        0x08, 0xED, 0x46, 0x42, 0x0B, 0x08, 0x13, 0x10,
        0x02, 0x1A, 0x05, 0x01, 0x00, 0x00, 0x00, 0x00,
    ]
}

/// Marks a SensorDataWX heart-rate payload: type 19, then an 18-byte body.
let HR_MARKER: [UInt8] = [0x08, 0x13, 0x1A, 0x12]
let HR_PAYLOAD_LENGTH = 18
let HR_BPM_OFFSET = 1
let HR_STATE_OFFSET = 5
let HR_STATE_LOCKED: UInt8 = 2

// MARK: - Helpers

func hex(_ bytes: ArraySlice<UInt8>) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

func stamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

func log(_ message: String) {
    print("[\(stamp())] \(message)")
    fflush(stdout)
}

/// Finds every occurrence of `pattern` in `haystack`.
func findAll(_ pattern: [UInt8], in haystack: [UInt8]) -> [Int] {
    guard !pattern.isEmpty, haystack.count >= pattern.count else { return [] }
    var hits: [Int] = []
    for start in 0...(haystack.count - pattern.count)
    where Array(haystack[start..<(start + pattern.count)]) == pattern {
        hits.append(start)
    }
    return hits
}

// MARK: - Probe

final class Probe: NSObject, IOBluetoothL2CAPChannelDelegate {
    private var channel: IOBluetoothL2CAPChannel?
    private var sampleCount = 0
    private var rxCount = 0
    private let sessionOnly: Bool
    private let steal: Bool
    private let holdSeconds: Int

    init(holdSeconds: Int, sessionOnly: Bool, steal: Bool) {
        self.holdSeconds = holdSeconds
        self.sessionOnly = sessionOnly
        self.steal = steal
    }

    // MARK: Device discovery

    /// Picks the target device: an explicit address if given, else the first
    /// paired device whose name mentions AirPods.
    static func resolveDevice(address: String?) -> IOBluetoothDevice? {
        if let address {
            guard let device = IOBluetoothDevice(addressString: address) else {
                log("Could not build a device for address \(address)")
                return nil
            }
            return device
        }

        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            log("No paired devices returned by IOBluetooth. Is Bluetooth on?")
            return nil
        }
        log("Paired devices: \(paired.count)")
        for device in paired {
            log("  \(device.addressString ?? "??")  \(device.name ?? "(unnamed)")")
        }
        let match = paired.first { ($0.name ?? "").lowercased().contains("airpod") }
        if match == nil {
            log("No paired device with 'AirPod' in its name. Pass an address explicitly.")
        }
        return match
    }

    // MARK: Channel

    func open(device: IOBluetoothDevice) -> Bool {
        log("Target: \(device.name ?? "(unnamed)") [\(device.addressString ?? "??")]")
        log("Opening L2CAP PSM 0x\(String(AAP_PSM, radix: 16))...")

        if steal {
            // macOS keeps auto-reconnecting AirPods, and while bluetoothd holds
            // the session the AAP channel is refused. Tear the baseband link
            // down ourselves, then grab the channel before macOS comes back.
            if device.isConnected() {
                let rc = device.closeConnection()
                log("STEAL: closeConnection -> 0x\(String(format: "%08X", rc))")
            } else {
                log("STEAL: device was not connected")
            }
            Thread.sleep(forTimeInterval: 0.250)
        }

        var newChannel: IOBluetoothL2CAPChannel?
        let result = device.openL2CAPChannelSync(&newChannel, withPSM: AAP_PSM, delegate: self)

        guard result == kIOReturnSuccess, let opened = newChannel else {
            log("openL2CAPChannelSync failed: IOReturn 0x\(String(format: "%08X", result))")
            log("")
            log("The usual cause is that macOS's own bluetoothd already holds this")
            log("channel. Disconnect the AirPods from the Mac (leave them paired)")
            log("and run this again, or try while they sit in the open case.")
            return false
        }

        channel = opened
        log("Channel open.")
        return true
    }

    private func send(_ bytes: [UInt8], _ label: String) {
        guard let channel else { return }
        var buffer = bytes
        let result = buffer.withUnsafeMutableBytes { raw -> IOReturn in
            channel.writeSync(raw.baseAddress, length: UInt16(bytes.count))
        }
        if result == kIOReturnSuccess {
            log("TX \(label): \(hex(bytes[...]))")
        } else {
            log("TX \(label) FAILED: IOReturn 0x\(String(format: "%08X", result))")
        }
    }

    // MARK: Sequence

    /// Replays the Android session-init + enable + start, with the same delays.
    func runSequence() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            // Establish a normal AAP session first. Without the handshake the
            // buds ignore everything and tear the channel down after ~4 s.
            send(Frame.handshake, "AAP handshake")
            Thread.sleep(forTimeInterval: 0.400)
            send(Frame.requestNotifications, "request notifications")
            Thread.sleep(forTimeInterval: 0.300)
            send(Frame.setFeatures, "set features (0x4D)")
            Thread.sleep(forTimeInterval: 0.400)

            // Diagnostic mode: is the session real at all? A live AAP session
            // pushes battery/ear-detection packets within seconds. If nothing
            // arrives here, heart rate is not being tested — the session is.
            if sessionOnly {
                log("SESSION-ONLY: listening \(holdSeconds)s for any AAP traffic")
                log("(battery, ear detection, anything). No heart-rate frames sent.")
                Thread.sleep(forTimeInterval: TimeInterval(holdSeconds))
                log("")
                log("RESULT: \(rxCount) frames received in \(holdSeconds)s.")
                if rxCount == 0 {
                    log("Session is NOT being served. Heart rate is untestable")
                    log("until this produces normal AAP traffic.")
                } else {
                    log("Session is alive — heart rate is now worth testing.")
                }
                channel?.close()
                exit(rxCount == 0 ? 4 : 0)
            }

            send(Frame.connectService0, "connect service 0")
            Thread.sleep(forTimeInterval: 0.180)
            send(Frame.capabilitiesService0, "capabilities 0")
            Thread.sleep(forTimeInterval: 0.220)
            send(Frame.connectService4, "connect service 4")
            Thread.sleep(forTimeInterval: 0.180)
            send(Frame.capabilitiesService4, "capabilities 4")
            Thread.sleep(forTimeInterval: 0.220)

            send(Frame.hrmEnable, "HRM_STATE enable (0x30)")
            Thread.sleep(forTimeInterval: 0.500)

            send(Frame.heartRateStart1s, "HEART_RATE_START_1S (stream 0x13 @ 1 Hz)")
            Thread.sleep(forTimeInterval: 0.040)
            send(Frame.ppgStart50Hz, "PPG_START_50Hz (stream 0x10, as iOS does)")

            log("Listening for \(holdSeconds)s. Wear both buds — the sensor only")
            log("reports while they are in your ears.")

            Thread.sleep(forTimeInterval: TimeInterval(holdSeconds))

            send(Frame.ppgStop, "PPG_STOP")
            Thread.sleep(forTimeInterval: 0.100)
            send(Frame.heartRateStop, "HEART_RATE_STOP")
            Thread.sleep(forTimeInterval: 0.300)

            log("")
            if sampleCount == 0 {
                log("RESULT: no heart-rate frames arrived.")
                log("If the buds ACKed with 4A 02 08 13 above, they accepted the")
                log("request and withheld the data — same behaviour as Windows,")
                log("on a host whose DID record is identical to an iPhone's.")
            } else {
                log("RESULT: \(sampleCount) heart-rate samples decoded.")
                log("Host identity is not the gate.")
            }
            channel?.close()
            exit(sampleCount == 0 ? 2 : 0)
        }
    }

    // MARK: Receive

    /// Explicit @objc: these are *optional* members of an @objc protocol, and
    /// without it Swift can silently fail to expose them to the Objective-C
    /// dispatch IOBluetooth uses — the channel then opens and delivers nothing.
    @objc func l2capChannelOpenComplete(
        _ l2capChannel: IOBluetoothL2CAPChannel!, status error: IOReturn
    ) {
        log("DELEGATE openComplete status=0x\(String(format: "%08X", error))")
    }

    @objc func l2capChannelWriteComplete(
        _ l2capChannel: IOBluetoothL2CAPChannel!,
        refcon: UnsafeMutableRawPointer!,
        status error: IOReturn
    ) {
        log("DELEGATE writeComplete status=0x\(String(format: "%08X", error))")
    }

    @objc func l2capChannelQueueSpaceAvailable(_ l2capChannel: IOBluetoothL2CAPChannel!) {
        log("DELEGATE queueSpaceAvailable")
    }

    @objc func l2capChannelReconfigured(_ l2capChannel: IOBluetoothL2CAPChannel!) {
        log("DELEGATE reconfigured")
    }

    @objc func l2capChannelData(
        _ l2capChannel: IOBluetoothL2CAPChannel!,
        data dataPointer: UnsafeMutableRawPointer!,
        length dataLength: Int
    ) {
        guard dataLength > 0, let dataPointer else { return }
        rxCount += 1
        let bytes = Array(UnsafeRawBufferPointer(start: dataPointer, count: dataLength))
            .map { UInt8($0) }

        // The ACK for the stream enable, worth calling out explicitly.
        if !findAll([0x4A, 0x02, 0x08, 0x13], in: bytes).isEmpty {
            log("RX ACK 4A 02 08 13 — buds accepted the heart-rate stream")
        }

        for hit in findAll(HR_MARKER, in: bytes) {
            let start = hit + HR_MARKER.count
            guard start + HR_PAYLOAD_LENGTH <= bytes.count else { continue }
            let payload = Array(bytes[start..<(start + HR_PAYLOAD_LENGTH)])
            let bpm = payload[HR_BPM_OFFSET]
            let state = payload[HR_STATE_OFFSET]
            let locked = state == HR_STATE_LOCKED
            sampleCount += 1
            log("HEART RATE: \(bpm) bpm  [\(locked ? "locked" : "acquiring")]  raw \(hex(payload[...]))")
        }

        log("RX \(dataLength)B: \(hex(bytes.prefix(48)[...]))\(dataLength > 48 ? " ..." : "")")
    }

    @objc func l2capChannelClosed(_ l2capChannel: IOBluetoothL2CAPChannel!) {
        log("Channel closed by remote.")
        exit(3)
    }
}

// MARK: - Entry point

var address: String?
var holdSeconds = 45
var sessionOnly = false
var steal = false

var args = Array(CommandLine.arguments.dropFirst())
while let arg = args.first {
    args.removeFirst()
    switch arg {
    case "--address", "-a":
        address = args.first
        if !args.isEmpty { args.removeFirst() }
    case "--seconds", "-s":
        holdSeconds = Int(args.first ?? "") ?? holdSeconds
        if !args.isEmpty { args.removeFirst() }
    case "--steal":
        steal = true
    case "--session-only":
        sessionOnly = true
    case "--help", "-h":
        print("""
        macOS AirPods heart-rate probe

        USAGE:
          hr-probe [--address AA-BB-CC-DD-EE-FF] [--seconds N]

        Defaults to the first paired device with "AirPod" in its name and a
        45-second listening window. Wear both buds for the duration.
        """)
        exit(0)
    default:
        log("Unknown argument: \(arg)")
        exit(64)
    }
}

guard let device = Probe.resolveDevice(address: address) else { exit(1) }

let probe = Probe(holdSeconds: holdSeconds, sessionOnly: sessionOnly, steal: steal)
guard probe.open(device: device) else { exit(1) }
probe.runSequence()
RunLoop.main.run()

import CoreAudio
import Foundation

/// Thin, throwing wrappers around `AudioObjectGetPropertyData` so the capture classes read like
/// plain Swift. Everything here is global-scope / main-element.
enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// Reads a fixed-size POD property (UInt32, AudioObjectID, AudioStreamBasicDescription, ...).
    static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T,
                       qualifier: UnsafeRawPointer? = nil, qualifierSize: UInt32 = 0) throws -> T {
        var addr = address(selector)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let err = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, qualifierSize, qualifier, &size, $0)
        }
        guard err == noErr else { throw AudioSourceError.coreAudio(err, "get '\(fourCC(selector))'") }
        return value
    }

    /// Reads a variable-length array property (device lists, process lists).
    static func getArray<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, zero: T) throws -> [T] {
        var addr = address(selector)
        var size: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size)
        guard err == noErr else { throw AudioSourceError.coreAudio(err, "size '\(fourCC(selector))'") }
        var items = [T](repeating: zero, count: Int(size) / MemoryLayout<T>.stride)
        if items.isEmpty { return [] }
        err = items.withUnsafeMutableBytes { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0.baseAddress!) }
        guard err == noErr else { throw AudioSourceError.coreAudio(err, "get '\(fourCC(selector))'") }
        // The list can shrink between the two calls (a process exits); trust the second size.
        return Array(items.prefix(Int(size) / MemoryLayout<T>.stride))
    }

    /// CFString properties come back +1 retained (the caller owns them), hence takeRetainedValue.
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
        guard err == noErr, let s = value?.takeRetainedValue() else { return nil }
        return s as String
    }

    static var defaultOutputDevice: AudioDeviceID {
        (try? get(system, kAudioHardwarePropertyDefaultOutputDevice, initial: unknown)) ?? unknown
    }

    static var defaultInputDevice: AudioDeviceID {
        (try? get(system, kAudioHardwarePropertyDefaultInputDevice, initial: unknown)) ?? unknown
    }

    static func uid(_ device: AudioDeviceID) -> String? { string(device, kAudioDevicePropertyDeviceUID) }

    /// True when the default output is a loudspeaker the microphone can hear (built-in speakers,
    /// HDMI/DisplayPort monitors, AirPlay, Thunderbolt docks), so acoustic echo cancellation is
    /// worth its CPU. False for headphones (built-in jack data source), Bluetooth and USB headsets,
    /// and virtual devices (BlackHole, Zoom's). Unknown transports count as speakers (safe side).
    static func outputIsLoudspeaker(_ device: AudioDeviceID = defaultOutputDevice) -> Bool {
        guard device != unknown else { return true }
        let transport = (try? get(device, kAudioDevicePropertyTransportType, initial: UInt32(0))) ?? 0
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE,
             kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeVirtual,
             kAudioDeviceTransportTypeAggregate:
            return false
        case kAudioDeviceTransportTypeBuiltIn:
            // Built-in output with headphones plugged in reports data source 'hdpn'.
            var addr = address(kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput)
            var source: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &source) == noErr, source == 0x6864_706E { return false }
            return true
        default:
            return true
        }
    }
    static func name(_ device: AudioDeviceID) -> String? { string(device, kAudioObjectPropertyName) }

    /// UIDs of every device visible to this process (includes our own private aggregates, which
    /// are invisible to other processes, so this is the only reliable leak check).
    static func allDeviceUIDs() -> [String] {
        ((try? getArray(system, kAudioHardwarePropertyDevices, zero: unknown)) ?? []).compactMap(uid)
    }

    /// Process taps that currently exist in this process (macOS 14.2+).
    static func allTapIDs() -> [AudioObjectID] {
        (try? getArray(system, kAudioHardwarePropertyTapList, zero: unknown)) ?? []
    }

    /// Converts a mach host time (AudioTimeStamp.mHostTime / AVAudioTime.hostTime) to wall-clock
    /// time by measuring its distance from "now" on the same clock. Host time is a monotonic tick
    /// count (1 tick = 125/3 ns on Apple Silicon), never a wall-clock value on its own.
    static func date(fromHostTime hostTime: UInt64) -> Date {
        let nowNanos = Double(AudioConvertHostTimeToNanos(AudioGetCurrentHostTime()))
        let thenNanos = Double(AudioConvertHostTimeToNanos(hostTime))
        return Date().addingTimeInterval(-(nowNanos - thenNanos) / 1e9)
    }

    static func fourCC(_ v: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((v >> UInt32($0)) & 0xFF) }
        if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) { return String(decoding: bytes, as: UTF8.self) }
        return String(v)
    }
}

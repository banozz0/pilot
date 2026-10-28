import AudioToolbox
import CoreAudio

/// Which way a sound device carries sound; the raw value is how the page and its refusals say it.
enum AudioDirection: String, CaseIterable {
    case output, input

    var scope: AudioObjectPropertyScope { self == .output ? kAudioDevicePropertyScopeOutput : kAudioDevicePropertyScopeInput }
    var defaultSelector: AudioObjectPropertySelector {
        self == .output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice
    }
}

struct AudioDevice: Equatable {
    let id: AudioDeviceID
    let name: String
    /// CoreAudio's UID, which a device keeps across reconnects while its numeric id changes; nil when it gives none.
    var uid: String? = nil

    /// What a bind names the device by: its UID, else the numeric id an older bind holds.
    var key: String { uid ?? String(id) }
}

/// A device's volume, 0 to 1, and whether macOS lets an app change it.
struct AudioLevel: Equatable {
    let value: Float
    let settable: Bool
}

/// The Mac's sound devices: the list each way, the default each way, and each device's volume and mute. CoreAudio is the
/// real one; the tests use a fake, so no test touches the real devices.
@MainActor
protocol AudioSystem: AnyObject {
    func devices(_ direction: AudioDirection) -> [AudioDevice]
    func defaultDevice(_ direction: AudioDirection) -> AudioDeviceID?
    func setDefault(_ id: AudioDeviceID, _ direction: AudioDirection) -> Bool
    /// nil when the device has no volume to read; a volume an app may not change reads not settable.
    func volume(_ id: AudioDeviceID, _ direction: AudioDirection) -> AudioLevel?
    func setVolume(_ value: Float, _ id: AudioDeviceID, _ direction: AudioDirection) -> Bool
    /// nil when the device has no mute an app can set.
    func muted(_ id: AudioDeviceID, _ direction: AudioDirection) -> Bool?
    func setMuted(_ muted: Bool, _ id: AudioDeviceID, _ direction: AudioDirection) -> Bool
    /// Calls `changed` when a default, the device list (`devices` true), or these devices' volume or mute (false) change
    /// anywhere: Control Centre, the volume keys. Watching lasts until the returned watch is cancelled.
    func watch(_ devices: [AudioDeviceID], changed: @escaping @MainActor (_ devices: Bool) -> Void) -> Watch
}

/// Sound devices through CoreAudio's public properties, no permission needed. Also the system menu's "Play through …"
/// rows, as Hammerspoon's chooser had them (card agent-bo-95422700), and Setup › Sound (card agent-bo-95422800).
@MainActor
final class CoreAudioSystem: AudioSystem {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    /// Every device with a stream that way.
    func devices(_ direction: AudioDirection) -> [AudioDevice] {
        var list = Self.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(Self.system, &list, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(Self.system, &list, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = Self.address(kAudioDevicePropertyStreams, scope: direction.scope)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr, bytes > 0 else { return nil }
            guard let name = Self.string(id, kAudioObjectPropertyName) else { return nil }
            return AudioDevice(id: id, name: name, uid: Self.string(id, kAudioDevicePropertyDeviceUID))
        }
    }

    /// A device's text property: its name, its UID.
    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// A device's name, as Sound settings shows it.
    func name(_ id: AudioDeviceID) -> String? { Self.string(id, kAudioObjectPropertyName) }

    func defaultDevice(_ direction: AudioDirection) -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        return get(Self.system, Self.address(direction.defaultSelector), &id) && id != kAudioObjectUnknown ? id : nil
    }

    func setDefault(_ id: AudioDeviceID, _ direction: AudioDirection) -> Bool {
        var id = id
        return set(Self.system, Self.address(direction.defaultSelector), &id)
    }

    /// The device's main volume as macOS's own slider shows it (the virtual main volume, which also covers a device
    /// that only has a volume per channel).
    func volume(_ id: AudioDeviceID, _ direction: AudioDirection) -> AudioLevel? {
        let address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: direction.scope)
        var value = Float32(0)
        return get(id, address, &value) ? AudioLevel(value: value, settable: settable(id, address)) : nil
    }

    func setVolume(_ value: Float, _ id: AudioDeviceID, _ direction: AudioDirection) -> Bool {
        var value = Float32(min(max(value, 0), 1))
        return set(id, Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: direction.scope), &value)
    }

    func muted(_ id: AudioDeviceID, _ direction: AudioDirection) -> Bool? {
        let address = Self.address(kAudioDevicePropertyMute, scope: direction.scope)
        var value = UInt32(0)
        guard settable(id, address), get(id, address, &value) else { return nil }
        return value != 0
    }

    func setMuted(_ muted: Bool, _ id: AudioDeviceID, _ direction: AudioDirection) -> Bool {
        var value = UInt32(muted ? 1 : 0)
        return set(id, Self.address(kAudioDevicePropertyMute, scope: direction.scope), &value)
    }

    /// The defaults and the device list (`changed(true)`), each device's volume and mute (`changed(false)`). C listeners
    /// through PropertyListeners: the block ones this used never came off (Build 55), and a burst is one call.
    func watch(_ devices: [AudioDeviceID], changed: @escaping @MainActor (_ devices: Bool) -> Void) -> Watch {
        let lists = Set([kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices]
            .map { PropertyKey(Self.system, $0) })
        let levels = Set(devices.flatMap { id in
            AudioDirection.allCases.flatMap { direction in
                [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute].map { PropertyKey(id, $0, direction.scope) }
            }
        })
        // A device without a property refuses its listener; it has nothing to watch.
        let watches = [PropertyListeners(.audio, wanted: { lists }, changed: { changed(true) }),
                       PropertyListeners(.audio, wanted: { levels }, changed: { changed(false) })]
        watches.forEach { $0.arm() }
        return Watch { MainActor.assumeIsolated { watches.forEach { $0.disarm() } } }
    }

    private func get<T: BitwiseCopyable>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: inout T) -> Bool {
        var address = address
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectHasProperty(object, &address) && AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    }

    private func set<T: BitwiseCopyable>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: inout T) -> Bool {
        var address = address
        return AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value) == noErr
    }

    private func settable(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(object, &address) && AudioObjectIsPropertySettable(object, &address, &settable) == noErr && settable.boolValue
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}

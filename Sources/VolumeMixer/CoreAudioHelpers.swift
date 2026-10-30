import CoreAudio
import AudioToolbox

/// Thin, typed wrappers around the AudioObject property API.
extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    func has(_ selector: AudioObjectPropertySelector,
             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var addr = Self.address(selector, scope)
        return AudioObjectHasProperty(self, &addr)
    }

    func isSettable(_ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var addr = Self.address(selector, scope)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(self, &addr),
              AudioObjectIsPropertySettable(self, &addr, &settable) == noErr else { return false }
        return settable.boolValue
    }

    func get<T: BitwiseCopyable>(_ selector: AudioObjectPropertySelector,
                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                default fallback: T) -> T {
        var addr = Self.address(selector, scope)
        var size = UInt32(MemoryLayout<T>.size)
        var value = fallback
        let err = AudioObjectGetPropertyData(self, &addr, 0, nil, &size, &value)
        return err == noErr ? value : fallback
    }

    @discardableResult
    func set<T: BitwiseCopyable>(_ selector: AudioObjectPropertySelector,
                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                _ value: T) -> OSStatus {
        var addr = Self.address(selector, scope)
        var v = value
        return AudioObjectSetPropertyData(self, &addr, 0, nil, UInt32(MemoryLayout<T>.size), &v)
    }

    func getArray<T>(_ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                     of _: T.Type) -> [T] {
        var addr = Self.address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(self, &addr, 0, nil, &size, buffer) == noErr else { return [] }
        return Array(UnsafeBufferPointer(start: buffer, count: Int(size) / MemoryLayout<T>.stride))
    }

    func getString(_ selector: AudioObjectPropertySelector,
                   scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var addr = Self.address(selector, scope)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(self, &addr, 0, nil, &size, &value) == noErr,
              let str = value?.takeRetainedValue() else { return nil }
        return str as String
    }

    /// Adds a listener on the main queue. Returns a token that removes it.
    func listen(_ selector: AudioObjectPropertySelector,
                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                _ handler: @escaping () -> Void) -> ListenerToken {
        var addr = Self.address(selector, scope)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        AudioObjectAddPropertyListenerBlock(self, &addr, DispatchQueue.main, block)
        return ListenerToken(object: self, address: addr, block: block)
    }
}

final class ListenerToken {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock

    init(object: AudioObjectID, address: AudioObjectPropertyAddress, block: @escaping AudioObjectPropertyListenerBlock) {
        self.object = object
        self.address = address
        self.block = block
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, block)
    }
}

// MARK: - Devices

struct OutputDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let name: String
    let uid: String
}

enum AudioDevices {
    static var defaultOutput: AudioObjectID {
        AudioObjectID.system.get(kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(kAudioObjectUnknown))
    }

    static func setDefaultOutput(_ id: AudioObjectID) {
        AudioObjectID.system.set(kAudioHardwarePropertyDefaultOutputDevice, id)
    }

    static func outputDevices() -> [OutputDevice] {
        AudioObjectID.system.getArray(kAudioHardwarePropertyDevices, of: AudioObjectID.self).compactMap { id in
            let streams = id.getArray(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput, of: AudioObjectID.self)
            guard !streams.isEmpty,
                  let uid = id.getString(kAudioDevicePropertyDeviceUID),
                  let name = id.getString(kAudioObjectPropertyName),
                  !name.hasPrefix("CADefaultDeviceAggregate") else { return nil }
            return OutputDevice(id: id, name: name, uid: uid)
        }
    }
}

import Foundation
import CoreAudio

enum AudioDevices {
    static func defaultOutput() -> AudioDeviceID? {
        var device: AudioDeviceID = 0
        var size = UInt32(MemoryLayout.size(ofValue: device))
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr, device != 0 else { return nil }
        return device
    }

    static func all() -> [(AudioDeviceID, AudioOutputDevice)] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let result = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!) }
        guard result == noErr else { return [] }
        return ids.compactMap { device in
            guard uint32(device, selector:kAudioDevicePropertyIsHidden) != 1 else { return nil }
            guard hasOutput(device), let uid = string(device, selector: kAudioDevicePropertyDeviceUID) else { return nil }
            // AVAudioEngine's process-local default-route aggregate is not a
            // persistent output a person can meaningfully select.
            guard !uid.hasPrefix("CADefaultDeviceAggregate-") else { return nil }
            let name = string(device, selector: kAudioObjectPropertyName) ?? "Audio output"
            return (device, AudioOutputDevice(id: uid, name: name, isHeadphones: isHeadphones(device)))
        }
    }

    static func hasOutput(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, storage) == noErr else { return false }
        return UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self)).contains { $0.mNumberChannels > 0 }
    }

    static func string(_ device: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    static func uint32(_ device: AudioDeviceID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func isHeadphones(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        if AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 {
            var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
            let result = streams.withUnsafeMutableBytes { AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0.baseAddress!) }
            if result == noErr, streams.contains(where: { uint32($0, selector: kAudioStreamPropertyTerminalType) == kAudioStreamTerminalTypeHeadphones }) { return true }
        }
        let name = (string(device, selector: kAudioObjectPropertyName) ?? "").lowercased()
        if ["headphone", "headset", "airpod", "earbud", "beats"].contains(where: name.contains) { return true }
        // Built-in output may retain its generic name when the headphone jack is used.
        if uint32(device, selector: kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput) == 0x6864706e { return true }
        // Bluetooth transport alone is insufficient: Bluetooth speakers are not headphones.
        return false
    }

    @discardableResult static func requestSmallBuffer(_ device: AudioDeviceID) -> UInt32 {
        var range = AudioValueRange(mMinimum: 0, mMaximum: 0)
        var rangeSize = UInt32(MemoryLayout<AudioValueRange>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSizeRange, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(device, &address, 0, nil, &rangeSize, &range) == noErr {
            var requested = UInt32(max(range.mMinimum, min(128, range.mMaximum)))
            address.mSelector = kAudioDevicePropertyBufferFrameSize
            var settable = DarwinBoolean(false)
            if AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue {
                _ = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &requested)
            }
        }
        return uint32(device, selector: kAudioDevicePropertyBufferFrameSize) ?? 0
    }
}

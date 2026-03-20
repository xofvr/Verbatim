import CoreAudio
import Foundation

public struct AudioInputDevice: Equatable, Identifiable, Sendable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
}

public final class AudioDeviceManager: @unchecked Sendable {
    private let lock = NSLock()
    private var _onDevicesChanged: (@Sendable () -> Void)?
    private var listenerRegistered = false

    public init() {}

    public func availableInputDevices() -> [AudioInputDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize
        )
        guard status == noErr, dataSize > 0 else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &deviceIDs
        )
        guard status == noErr else { return [] }

        return deviceIDs.compactMap { deviceID in
            guard hasInputChannels(deviceID) else { return nil }
            guard !isAggregateDevice(deviceID) else { return nil }
            guard let uid = deviceUID(deviceID),
                  let name = deviceName(deviceID) else { return nil }
            return AudioInputDevice(id: deviceID, uid: uid, name: name)
        }
    }

    public func startMonitoring(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        _onDevicesChanged = handler
        guard !listenerRegistered else { return }

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main
        ) { [weak self] _, _ in
            guard let self else { return }
            self.lock.lock()
            let callback = self._onDevicesChanged
            self.lock.unlock()
            callback?()
        }

        if status == noErr {
            listenerRegistered = true
        }
    }

    public func stopMonitoring() {
        lock.lock()
        defer { lock.unlock() }
        _onDevicesChanged = nil
    }

    // MARK: - Private

    private func isAggregateDevice(_ deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyClass,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var classID: AudioClassID = 0
        var dataSize = UInt32(MemoryLayout<AudioClassID>.size)
        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &classID)
        guard status == noErr else { return false }
        return classID == kAudioAggregateDeviceClassID
    }

    private func hasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return false }

        let bufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        defer { bufferListPointer.deallocate() }

        let getStatus = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, bufferListPointer)
        guard getStatus == noErr else { return false }

        let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPointer)
        return bufferList.contains { $0.mNumberChannels > 0 }
    }

    private func deviceUID(_ deviceID: AudioDeviceID) -> String? {
        stringProperty(kAudioDevicePropertyDeviceUID, of: deviceID)
    }

    private func deviceName(_ deviceID: AudioDeviceID) -> String? {
        stringProperty(kAudioObjectPropertyName, of: deviceID)
    }

    private func stringProperty(_ selector: AudioObjectPropertySelector, of deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var result: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &dataSize, &result)
        guard status == noErr, let cfString = result?.takeRetainedValue() else { return nil }
        return cfString as String
    }
}

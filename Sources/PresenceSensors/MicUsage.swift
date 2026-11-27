import CoreAudio
import Foundation

/// Tells whether another app is capturing audio, so the app never listens during a call.
public struct MicUsage: MicUsageReading {
    public init() {}

    public func micInUseByOtherApp() -> Bool {
        guard let device = Self.defaultInputDevice(), Self.isRunningSomewhere(device) else { return false }
        // `DeviceIsRunningSomewhere` counts our own capture too, so ask per process when the OS can say.
        guard let processes = Self.inputProcesses() else { return true }
        return Self.otherAppCapturing(processes: processes, ownPID: getpid())
    }

    struct ProcessInput: Equatable {
        var pid: pid_t
        var runningInput: Bool
    }

    static func otherAppCapturing(processes: [ProcessInput], ownPID: pid_t) -> Bool {
        processes.contains { $0.runningInput && $0.pid != ownPID }
    }

    private static func defaultInputDevice() -> AudioObjectID? {
        var device = AudioObjectID(kAudioObjectUnknown)
        guard read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, into: &device),
              device != kAudioObjectUnknown
        else { return nil }
        return device
    }

    private static func isRunningSomewhere(_ device: AudioObjectID) -> Bool {
        var running: UInt32 = 0
        return read(device, kAudioDevicePropertyDeviceIsRunningSomewhere, into: &running) && running != 0
    }

    private static func inputProcesses() -> [ProcessInput]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return nil }
        return ids.map { id in
            var pid: pid_t = 0
            var input: UInt32 = 0
            _ = read(id, kAudioProcessPropertyPID, into: &pid)
            _ = read(id, kAudioProcessPropertyIsRunningInput, into: &input)
            return ProcessInput(pid: pid, runningInput: input != 0)
        }
    }

    private static func read<T: FixedWidthInteger>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, into value: inout T) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    }
}

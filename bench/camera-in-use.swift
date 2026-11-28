// With a number of seconds, counts the seconds any camera is running, polling once a second.
// With no argument, prints 1 if a camera is running now, else 0.
// Built and run by scripts/bench.sh so each mode reports when and how long the camera was on.
import CoreMediaIO
import Foundation

func property(_ selector: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
    CMIOObjectPropertyAddress(
        mSelector: selector,
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
}

func devices() -> [CMIOObjectID] {
    var address = property(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
    let system = CMIOObjectID(kCMIOObjectSystemObject)
    var size: UInt32 = 0
    guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == 0 else { return [] }
    var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
    var used: UInt32 = 0
    guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &ids) == 0 else { return [] }
    return ids
}

func anyRunning() -> Bool {
    devices().contains { id in
        var address = property(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere))
        var running: UInt32 = 0
        var used: UInt32 = 0
        return CMIOObjectGetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &running) == 0
            && running != 0
    }
}

guard let arg = CommandLine.arguments.dropFirst().first, let seconds = Int(arg) else {
    print(anyRunning() ? 1 : 0)
    exit(0)
}
var on = 0
for _ in 0..<seconds {
    if anyRunning() { on += 1 }
    sleep(1)
}
print(on)

import Foundation
import IOKit

/// Reads the time since the last keyboard or mouse input from IOHIDSystem.
public struct IdleSource: IdleReading {
    public init() {}

    public func secondsSinceInput() -> Double {
        // Looked up per call rather than cached: one registry lookup a second is cheap, and a
        // cached io_object_t would need manual release that a value type cannot own.
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return 0 }
        defer { IOObjectRelease(service) }
        guard
            let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber
        else { return 0 }
        return Self.seconds(fromNanoseconds: value.uint64Value)
    }

    static func seconds(fromNanoseconds ns: UInt64) -> Double {
        Double(ns) / 1_000_000_000
    }
}

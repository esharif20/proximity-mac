@preconcurrency import CoreBluetooth
import Foundation
import Synchronization

/// A device seen during `BLESource.scan`, for the person to pick their phone or watch.
public struct FoundDevice: Sendable, Identifiable, Equatable {
    /// `CBPeripheral.identifier`, the value to store as `PhoneLink.identifier`.
    public var id: String
    public var name: String
    /// Signal strength in dBm; closer to 0 is stronger.
    public var rssi: Double

    public init(id: String, name: String, rssi: Double) {
        self.id = id
        self.name = name
        self.rssi = rssi
    }
}

/// The linked phone or watch as a presence source: its Bluetooth signal strength, smoothed, about every 2 s.
///
/// iPhones and Apple Watches advertise from a private Bluetooth address that changes about every 15 minutes,
/// so a stranger cannot track them. macOS hides the address and hands out `CBPeripheral.identifier`, a UUID
/// it makes up per address. When the phone is signed in to the same Apple ID as the Mac, macOS resolves the
/// private address to the device's real one, so the identifier stays the same across rotations and restarts.
/// For any other device the identifier changes with the address and the link stops reporting until the
/// person picks the device again. See docs/spikes/ble.md.
///
/// The Bluetooth central is created only on the first `setMode` other than `.off` or the first `scan`, so the
/// Bluetooth prompt appears only when the person sets up a phone.
///
/// `@unchecked Sendable`: `central` and `delegate` are touched only on `queue`, every other piece of state
/// is behind `state`.
public final class BLESource: PresenceSource, @unchecked Sendable {
    public let kind = SourceKind.ble

    private struct State {
        var mode = SamplingMode.off
        var identifier: String?
        var smoother = SignalSmoother()
        var handler: (@Sendable (Observation) -> Void)?
        /// Devices seen by the scans running now, by identifier; nil when no scan runs.
        var found: [String: FoundDevice]?
        var scans = 0

        var wantsRadio: Bool { (mode != .off && identifier != nil) || scans > 0 }
    }

    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "ble.central")
    private var central: CBCentralManager?
    private var delegate: CentralDelegate?

    public init() {}

    /// The linked device's `CBPeripheral.identifier`. Nothing is reported while it is nil.
    public var identifier: String? {
        get { state.withLock { $0.identifier } }
        set {
            state.withLock { s in
                if s.identifier != newValue { s.smoother = SignalSmoother() }
                s.identifier = newValue
            }
            reconcile()
        }
    }

    public func onObservation(_ handler: @escaping @Sendable (Observation) -> Void) {
        state.withLock { $0.handler = handler }
    }

    public func setMode(_ mode: SamplingMode) {
        state.withLock { s in
            s.mode = mode
            if mode == .off { s.smoother = SignalSmoother() }
        }
        reconcile()
    }

    /// Named devices seen within `seconds`, strongest signal first.
    public func scan(seconds: Double) async -> [FoundDevice] {
        state.withLock { s in
            if s.found == nil { s.found = [:] }
            s.scans += 1
        }
        reconcile()
        try? await Task.sleep(for: .seconds(seconds))
        let found = state.withLock { s in
            let found = s.found ?? [:]
            s.scans -= 1
            if s.scans == 0 { s.found = nil }
            return found
        }
        reconcile()
        return found.values.sorted { $0.rssi > $1.rssi }
    }

    /// Starts or stops scanning to match `state`, creating the central the first time it is needed.
    private func reconcile() {
        queue.async { [self] in
            let wanted = state.withLock { $0.wantsRadio }
            if wanted, central == nil {
                let delegate = CentralDelegate(owner: self)
                self.delegate = delegate
                // The central reports `.poweredOn` through the delegate, which calls back here to start.
                central = CBCentralManager(delegate: delegate, queue: queue)
                return
            }
            guard let central, central.state == .poweredOn else { return }
            if wanted, !central.isScanning {
                // Duplicates allowed: without them each device is reported once per scan, not on every advert.
                central.scanForPeripherals(
                    withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            } else if !wanted, central.isScanning {
                central.stopScan()
            }
        }
    }

    fileprivate func centralChangedState() { reconcile() }

    fileprivate func discovered(id: String, name: String?, rssi: Double) {
        // 127 is CoreBluetooth's "no reading".
        guard rssi < 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let report: (Observation, @Sendable (Observation) -> Void)? = state.withLock { s in
            if let name, !name.isEmpty, s.found != nil {
                s.found?[id] = FoundDevice(id: id, name: name, rssi: rssi)
            }
            guard s.mode != .off, id == s.identifier, let handler = s.handler,
                  let smoothed = s.smoother.add(rssi, at: now)
            else { return nil }
            return (Observation(source: .ble, person: false, rssi: smoothed), handler)
        }
        if let (observation, handler) = report { handler(observation) }
    }
}

/// Turns raw adverts into one reading about every 2 s: the median of the last 5, so a single reflected or
/// blocked advert does not swing the signal.
struct SignalSmoother {
    static let window = 5
    static let interval = 2.0

    private(set) var readings: [Double] = []
    private var lastReport: Double?

    /// Adds a reading taken at `time` (seconds) and returns the smoothed signal when a report is due.
    mutating func add(_ rssi: Double, at time: Double) -> Double? {
        readings.append(rssi)
        if readings.count > Self.window { readings.removeFirst(readings.count - Self.window) }
        if let lastReport, time - lastReport < Self.interval { return nil }
        lastReport = time
        return Self.median(readings)
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

/// `@unchecked Sendable`: CoreBluetooth calls it only on `BLESource.queue`.
private final class CentralDelegate: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    private weak var owner: BLESource?

    init(owner: BLESource) { self.owner = owner }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        owner?.centralChangedState()
    }

    func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        owner?.discovered(id: peripheral.identifier.uuidString, name: name, rssi: RSSI.doubleValue)
    }
}

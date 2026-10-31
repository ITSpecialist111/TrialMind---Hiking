import CoreBluetooth
import Foundation

/// Hears Android members' trip-group adverts (the receive half of GroupRadio) with Core Bluetooth. Android phones put
/// the sealed group payload in the service data of Bluetooth 5 extended adverts; iOS hands an app that service data
/// when it scans every advert, which it allows only while the app is in the foreground. iPhones can't answer in kind:
/// iOS lets apps advertise only a name and service UUIDs, never service data, and can't choose LE Coded (long range),
/// so Android phones don't see iPhones, and iPhones hear Android phones only on the standard 1M radio.
///
/// Its state lives on the main thread; Core Bluetooth itself runs on a queue of its own, where every call to it goes.
final class GroupBluetooth: NSObject, CBCentralManagerDelegate {
    /// The payload, its signal strength in dBm (nil when iOS doesn't know it) and the advertised transmit power.
    var onAdvert: (([UInt8], Int?, Int?) -> Void)?
    var onChanged: (() -> Void)?

    private(set) var scanning = false
    private(set) var scanStartedAt: Date?
    private(set) var received: Int64 = 0
    /// The radio's state as Core Bluetooth last reported it.
    private(set) var state: CBManagerState = .unknown

    private var central: CBCentralManager?
    private var wanted = false
    private var foreground = true
    private var filtered = false
    private let uuid = CBUUID(string: GroupAdvert.serviceUuid)
    /// Scanning every advert can mean hundreds of callbacks a second in a busy place: they arrive here, and only
    /// TrailMind's go on to the main thread.
    private let queue = DispatchQueue(label: "trailmind.group.bluetooth")

    var authorization: CBManagerAuthorization { CBManager.authorization }
    /// Whether this iPhone receives Bluetooth 5 extended advertising, which Android's group adverts use.
    var extendedScanning: Bool { CBCentralManager.supports(.extendedScanAndConnect) }

    /// The user (or a profile) refused TrailMind Bluetooth; only Settings can change that.
    var refused: Bool { CBManager.authorization == .denied || CBManager.authorization == .restricted }

    /// Why Android members can't be heard right now, or nil.
    var problem: String? {
        switch CBManager.authorization {
        case .denied, .restricted:
            return "Bluetooth isn't allowed for TrailMind, so it can't hear Android members. iPhones still link over Wi-Fi."
        default:
            break
        }
        switch state {
        case .poweredOff: return "Bluetooth is off, so TrailMind can't hear Android members. iPhones still link over Wi-Fi."
        case .unsupported: return "This iPhone can't scan for Bluetooth adverts, so it can't hear Android members."
        default: return extendedScanning ? nil : "This iPhone can't receive the extended Bluetooth adverts Android members send."
        }
    }

    /// For the diagnostics page.
    var stateText: String {
        switch CBManager.authorization {
        case .denied: return "not allowed for TrailMind"
        case .restricted: return "restricted on this iPhone"
        case .notDetermined: return central == nil ? "not asked yet" : "waiting for permission"
        default: break
        }
        switch state {
        case .poweredOn: return "on"
        case .poweredOff: return "off"
        case .unsupported: return "can't scan"
        case .unauthorized: return "not allowed for TrailMind"
        case .resetting: return "restarting"
        default: return central == nil ? "not started" : "starting"
        }
    }

    /// Scans while `on` (main thread). The first call asks iOS for Bluetooth permission.
    func update(on: Bool, foreground: Bool) {
        wanted = on
        self.foreground = foreground
        if on && central == nil {
            central = CBCentralManager(delegate: self, queue: queue, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
        apply()
    }

    /// Starts, changes or stops the scan to match what is wanted (main thread).
    private func apply() {
        guard let c = central else { return }
        guard wanted, state == .poweredOn else {
            if scanning {
                scanning = false
                scanStartedAt = nil
                queue.async { if c.state == .poweredOn { c.stopScan() } }
                onChanged?()
            }
            return
        }
        // In the background iOS only scans for listed services; Android lists none, so that scan is a long shot.
        let wantFiltered = !foreground
        if scanning && wantFiltered == filtered { return }
        let services = wantFiltered ? [uuid] : nil
        queue.async {
            guard c.state == .poweredOn else { return }
            c.scanForPeripherals(withServices: services, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
        filtered = wantFiltered
        if !scanning { scanStartedAt = Date() }
        scanning = true
        onChanged?()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let now = central.state
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.state = now
            // Bluetooth going off drops the scan; it starts afresh when Bluetooth is back.
            if now != .poweredOn {
                self.scanning = false
                self.scanStartedAt = nil
            }
            self.apply()
            self.onChanged?()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        guard let services = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data], let data = services[uuid],
              data.first == UInt8(GroupAdvert.version) else { return }
        let payload = [UInt8](data)
        let value = RSSI.intValue
        // 127 is iOS's "no reading".
        let rssi: Int? = value == 127 ? nil : value
        let txPower = (advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber)?.intValue
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.received += 1
            self.onAdvert?(payload, rssi, txPower)
        }
    }
}

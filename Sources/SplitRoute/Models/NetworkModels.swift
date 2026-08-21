import Foundation

struct HardwarePort: Equatable, Sendable {
    let name: String
    let device: String
}

struct NetworkService: Equatable, Sendable {
    let order: Int
    let name: String
    let device: String?
    let isEnabled: Bool
}

struct InterfaceDetails: Equatable, Sendable {
    let hardwarePort: String
    let device: String
    let ipv4: String?
    let netmask: UInt32?
    let isActive: Bool

    var prefixLength: Int? {
        netmask.map { $0.nonzeroBitCount }
    }

    var cidr: String? {
        guard let ipv4, let prefixLength else { return nil }
        return "\(ipv4)/\(prefixLength)"
    }
}

struct NetworkSnapshot: Equatable, Sendable {
    let wifi: InterfaceDetails?
    let ethernet: InterfaceDetails?
    let gateway: String?
    let primaryService: String?
    let serviceOrder: [NetworkService]
    let capturedAt: Date

    static let empty = NetworkSnapshot(
        wifi: nil,
        ethernet: nil,
        gateway: nil,
        primaryService: nil,
        serviceOrder: [],
        capturedAt: .distantPast
    )

    var isSameSubnet: Bool {
        guard
            let wifi,
            let ethernet,
            let wifiIP = wifi.ipv4,
            let ethernetIP = ethernet.ipv4,
            let wifiMask = wifi.netmask,
            let ethernetMask = ethernet.netmask,
            wifiMask == ethernetMask,
            let wifiValue = IPv4Address(wifiIP)?.rawValue,
            let ethernetValue = IPv4Address(ethernetIP)?.rawValue
        else { return false }

        return (wifiValue & wifiMask) == (ethernetValue & ethernetMask)
    }

    var subnetDescription: String {
        guard
            isSameSubnet,
            let wifiIP = wifi?.ipv4,
            let mask = wifi?.netmask,
            let raw = IPv4Address(wifiIP)?.rawValue
        else { return "Different subnets" }

        let network = IPv4Address(rawValue: raw & mask).description
        return "\(network)/\(mask.nonzeroBitCount)"
    }

    var prerequisiteIssue: String? {
        guard let wifi else { return "Wi-Fi hardware was not found." }
        guard wifi.isActive else { return "Turn on Wi-Fi before enabling split routing." }
        guard wifi.ipv4 != nil else { return "Wi-Fi does not have an IPv4 address." }
        guard let ethernet else { return "Connect a wired Ethernet adapter to enable split routing." }
        guard ethernet.isActive else { return "Connect the Ethernet cable to enable split routing." }
        guard ethernet.ipv4 != nil else { return "Ethernet does not have an IPv4 address." }
        guard gateway != nil else { return "No IPv4 gateway is currently available." }
        guard isSameSubnet else { return "Wi-Fi and Ethernet must be on the same IPv4 subnet." }
        return nil
    }

    var canEnable: Bool { prerequisiteIssue == nil }

    var wifiServiceName: String? {
        guard let wifiDevice = wifi?.device else { return nil }
        return serviceOrder.first { service in
            service.isEnabled && service.device == wifiDevice
        }?.name
    }

    var isWifiPrimary: Bool {
        guard let wifiServiceName, let primaryService else { return false }
        return wifiServiceName == primaryService
    }

    var hasConnectedIPv4Pair: Bool {
        wifi?.isActive == true &&
            wifi?.ipv4 != nil &&
            ethernet?.isActive == true &&
            ethernet?.ipv4 != nil &&
            gateway != nil
    }
}

struct IPv4Address: Equatable, Sendable, CustomStringConvertible {
    let rawValue: UInt32

    init?(_ value: String) {
        let pieces = value.split(separator: ".")
        guard pieces.count == 4 else { return nil }

        var result: UInt32 = 0
        for piece in pieces {
            guard let octet = UInt32(piece), octet <= 255 else { return nil }
            result = (result << 8) | octet
        }
        rawValue = result
    }

    init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    var description: String {
        [24, 16, 8, 0]
            .map { String((rawValue >> UInt32($0)) & 0xff) }
            .joined(separator: ".")
    }
}

enum RoutingState: Equatable, Sendable {
    case off
    case enabling
    case repairing
    case active
    case unsafeActive(String)
    case waitingForEthernet
    case disabling
    case failed(String)

    var isRequested: Bool {
        switch self {
        case .enabling, .repairing, .active, .unsafeActive, .waitingForEthernet, .disabling:
            return true
        case .off, .failed:
            return false
        }
    }

    var label: String {
        switch self {
        case .off: "Off"
        case .enabling: "Enabling…"
        case .repairing: "Repairing…"
        case .active: "Active"
        case .unsafeActive: "Protection stopped"
        case .waitingForEthernet: "Waiting for Ethernet"
        case .disabling: "Turning off…"
        case .failed: "Needs attention"
        }
    }
}

enum AutomaticRepairPolicy {
    static func shouldRequestRepair(
        snapshot: NetworkSnapshot,
        routingState: RoutingState
    ) -> Bool {
        guard snapshot.hasConnectedIPv4Pair else { return false }

        switch routingState {
        case .active:
            if !snapshot.isSameSubnet { return true }
            if snapshot.wifiServiceName != nil && !snapshot.isWifiPrimary { return true }
            return false
        case .waitingForEthernet:
            return snapshot.isSameSubnet
        case .off, .enabling, .repairing, .unsafeActive, .disabling, .failed:
            return false
        }
    }
}

struct InterfaceCounters: Equatable, Sendable {
    let receivedBytes: UInt64
    let sentBytes: UInt64

    static let zero = InterfaceCounters(receivedBytes: 0, sentBytes: 0)

    func delta(from earlier: InterfaceCounters) -> InterfaceCounters {
        InterfaceCounters(
            receivedBytes: receivedBytes >= earlier.receivedBytes ? receivedBytes - earlier.receivedBytes : 0,
            sentBytes: sentBytes >= earlier.sentBytes ? sentBytes - earlier.sentBytes : 0
        )
    }
}

struct LiveTraffic: Equatable, Sendable {
    let wifiDownBytesPerSecond: Double
    let wifiUpBytesPerSecond: Double
    let ethernetDownBytesPerSecond: Double
    let ethernetUpBytesPerSecond: Double

    static let zero = LiveTraffic(
        wifiDownBytesPerSecond: 0,
        wifiUpBytesPerSecond: 0,
        ethernetDownBytesPerSecond: 0,
        ethernetUpBytesPerSecond: 0
    )
}

struct SpeedTestResult: Equatable, Sendable {
    let downloadMbps: Double
    let uploadMbps: Double
    let downloadViaWifiPercent: Double
    let uploadViaEthernetPercent: Double
}

enum SpeedTestPhase: Equatable, Sendable {
    case idle
    case downloading
    case uploading
    case complete
    case failed(String)

    var label: String {
        switch self {
        case .idle: "Ready"
        case .downloading: "Testing download…"
        case .uploading: "Testing upload…"
        case .complete: "Complete"
        case .failed: "Test failed"
        }
    }

    var isRunning: Bool {
        self == .downloading || self == .uploading
    }
}

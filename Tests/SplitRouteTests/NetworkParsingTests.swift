import XCTest
@testable import SplitRoute

final class NetworkParsingTests: XCTestCase {
    func testHardwarePortParsingFindsDynamicDevices() {
        let output = """
        Hardware Port: USB 10/100/1000 LAN
        Device: en10
        Ethernet Address: 00:e0:4c:be:31:28

        Hardware Port: Wi-Fi
        Device: en0
        Ethernet Address: fc:b2:14:e4:18:ce
        """

        XCTAssertEqual(
            NetworkProbe.parseHardwarePorts(output),
            [
                HardwarePort(name: "USB 10/100/1000 LAN", device: "en10"),
                HardwarePort(name: "Wi-Fi", device: "en0")
            ]
        )
    }

    func testServiceOrderParsingPreservesNamesAndDisabledState() {
        let output = """
        An asterisk (*) denotes that a network service is disabled.
        (1) USB 10/100/1000 LAN
        (Hardware Port: USB 10/100/1000 LAN, Device: en10)

        (2) *Thunderbolt Bridge
        (Hardware Port: Thunderbolt Bridge, Device: bridge0)

        (3) Wi-Fi
        (Hardware Port: Wi-Fi, Device: en0)
        """

        XCTAssertEqual(
            NetworkProbe.parseServiceOrder(output),
            [
                NetworkService(order: 1, name: "USB 10/100/1000 LAN", device: "en10", isEnabled: true),
                NetworkService(order: 2, name: "Thunderbolt Bridge", device: "bridge0", isEnabled: false),
                NetworkService(order: 3, name: "Wi-Fi", device: "en0", isEnabled: true)
            ]
        )
    }

    func testInterfaceParsingUsesIPv4AndCarrier() {
        let output = """
        en10: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
            inet6 fe80::1%en10 prefixlen 64 secured scopeid 0xe
            inet 10.0.0.135 netmask 0xffffff00 broadcast 10.0.0.255
            media: autoselect (1000baseT <full-duplex>)
            status: active
        """

        XCTAssertEqual(
            NetworkProbe.parseInterface(output, hardwarePort: "USB LAN", device: "en10"),
            InterfaceDetails(
                hardwarePort: "USB LAN",
                device: "en10",
                ipv4: "10.0.0.135",
                netmask: 0xffffff00,
                isActive: true
            )
        )
    }

    func testGatewayParsing() {
        XCTAssertEqual(
            NetworkProbe.parseGateway("gateway: 10.0.0.1\ninterface: en10\n"),
            "10.0.0.1"
        )
    }

    func testSnapshotRequiresActiveSameSubnetInterfaces() {
        let wifi = InterfaceDetails(
            hardwarePort: "Wi-Fi",
            device: "en0",
            ipv4: "10.0.0.244",
            netmask: 0xffffff00,
            isActive: true
        )
        let ethernet = InterfaceDetails(
            hardwarePort: "USB LAN",
            device: "en10",
            ipv4: "10.0.0.135",
            netmask: 0xffffff00,
            isActive: true
        )
        let snapshot = NetworkSnapshot(
            wifi: wifi,
            ethernet: ethernet,
            gateway: "10.0.0.1",
            primaryService: "USB LAN",
            serviceOrder: [],
            capturedAt: Date()
        )

        XCTAssertTrue(snapshot.isSameSubnet)
        XCTAssertTrue(snapshot.canEnable)
        XCTAssertEqual(snapshot.subnetDescription, "10.0.0.0/24")
    }

    func testSnapshotRejectsDifferentSubnets() {
        let wifi = InterfaceDetails(
            hardwarePort: "Wi-Fi",
            device: "en0",
            ipv4: "10.0.0.244",
            netmask: 0xffffff00,
            isActive: true
        )
        let ethernet = InterfaceDetails(
            hardwarePort: "USB LAN",
            device: "en10",
            ipv4: "192.168.1.20",
            netmask: 0xffffff00,
            isActive: true
        )
        let snapshot = NetworkSnapshot(
            wifi: wifi,
            ethernet: ethernet,
            gateway: "10.0.0.1",
            primaryService: "Wi-Fi",
            serviceOrder: [],
            capturedAt: Date()
        )

        XCTAssertFalse(snapshot.canEnable)
        XCTAssertEqual(snapshot.prerequisiteIssue, "Wi-Fi and Ethernet must be on the same IPv4 subnet.")
    }

    func testEthernetSelectionKeepsActiveMismatchVisibleForRepair() {
        let wifi = InterfaceDetails(
            hardwarePort: "Wi-Fi",
            device: "en0",
            ipv4: "10.0.0.244",
            netmask: 0xffffff00,
            isActive: true
        )
        let mismatchedEthernet = InterfaceDetails(
            hardwarePort: "USB LAN",
            device: "en10",
            ipv4: "192.168.1.20",
            netmask: 0xffffff00,
            isActive: true
        )

        XCTAssertEqual(
            NetworkProbe.selectEthernetCandidate([mismatchedEthernet], wifi: wifi),
            mismatchedEthernet
        )
    }

    func testEthernetSelectionPrefersSameSubnetCandidate() {
        let wifi = InterfaceDetails(
            hardwarePort: "Wi-Fi",
            device: "en0",
            ipv4: "10.0.0.244",
            netmask: 0xffffff00,
            isActive: true
        )
        let mismatchedEthernet = InterfaceDetails(
            hardwarePort: "USB LAN",
            device: "en9",
            ipv4: "192.168.1.20",
            netmask: 0xffffff00,
            isActive: true
        )
        let matchingEthernet = InterfaceDetails(
            hardwarePort: "Thunderbolt Ethernet",
            device: "en10",
            ipv4: "10.0.0.135",
            netmask: 0xffffff00,
            isActive: true
        )

        XCTAssertEqual(
            NetworkProbe.selectEthernetCandidate(
                [mismatchedEthernet, matchingEthernet],
                wifi: wifi
            ),
            matchingEthernet
        )
    }

    func testAutomaticRepairRequestsActiveSubnetDrift() {
        let snapshot = repairSnapshot(
            ethernetIP: "192.168.1.20",
            primaryService: "Wi-Fi"
        )

        XCTAssertTrue(
            AutomaticRepairPolicy.shouldRequestRepair(
                snapshot: snapshot,
                routingState: .active
            )
        )
    }

    func testAutomaticRepairRequestsPrimaryServiceDrift() {
        let snapshot = repairSnapshot(
            ethernetIP: "10.0.0.135",
            primaryService: "USB LAN"
        )

        XCTAssertTrue(
            AutomaticRepairPolicy.shouldRequestRepair(
                snapshot: snapshot,
                routingState: .active
            )
        )
    }

    func testAutomaticRepairRequestsRecoveryFromWaitingState() {
        let snapshot = repairSnapshot(
            ethernetIP: "10.0.0.135",
            primaryService: "Wi-Fi"
        )

        XCTAssertTrue(
            AutomaticRepairPolicy.shouldRequestRepair(
                snapshot: snapshot,
                routingState: .waitingForEthernet
            )
        )
    }

    func testAutomaticRepairDoesNotPromptWhenWatchdogIsUnsafe() {
        let snapshot = repairSnapshot(
            ethernetIP: "192.168.1.20",
            primaryService: "USB LAN"
        )

        XCTAssertFalse(
            AutomaticRepairPolicy.shouldRequestRepair(
                snapshot: snapshot,
                routingState: .unsafeActive("watchdog missing")
            )
        )
    }

    func testShellQuoteHandlesApostrophes() {
        XCTAssertEqual(
            RoutingController.shellQuote("/tmp/Aaron's App/controller.sh"),
            "'/tmp/Aaron'\\''s App/controller.sh'"
        )
    }

    func testPromptFreeRepairWritesOnlyMarkerForCurrentWatchdog() throws {
        let directory = try makeControllerStateDirectory(named: #function)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("intent"))
        try Data("2\n".utf8).write(to: directory.appendingPathComponent("controller.version"))
        try Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8)
            .write(to: directory.appendingPathComponent("watchdog.pid"))

        let controller = RoutingController(stateDirectory: directory)
        try controller.requestRepair()

        XCTAssertEqual(
            try String(
                contentsOf: directory.appendingPathComponent("repair.request"),
                encoding: .utf8
            ),
            "repair\n"
        )
    }

    func testPromptFreeRepairRejectsOldWatchdogWithoutMarker() throws {
        let directory = try makeControllerStateDirectory(named: #function)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("intent"))
        try Data("1\n".utf8).write(to: directory.appendingPathComponent("controller.version"))
        try Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8)
            .write(to: directory.appendingPathComponent("watchdog.pid"))

        let controller = RoutingController(stateDirectory: directory)
        XCTAssertThrowsError(try controller.requestRepair()) { error in
            guard case RoutingControllerError.watchdogUpgradeRequired = error else {
                return XCTFail("Expected watchdogUpgradeRequired, got \(error)")
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("repair.request").path
            )
        )
    }

    func testSpeedTestChunkSizesStayWithinCloudflareLimits() {
        XCTAssertEqual(SpeedTestService.downloadChunkBytes, 25_000_000)
        XCTAssertEqual(SpeedTestService.uploadChunkBytes, 10_000_000)
        XCTAssertEqual(SpeedTestService.fallbackDownloadURL.host(), "fsn1-speed.hetzner.com")
    }

    private func repairSnapshot(
        ethernetIP: String,
        primaryService: String
    ) -> NetworkSnapshot {
        NetworkSnapshot(
            wifi: InterfaceDetails(
                hardwarePort: "Wi-Fi",
                device: "en0",
                ipv4: "10.0.0.244",
                netmask: 0xffffff00,
                isActive: true
            ),
            ethernet: InterfaceDetails(
                hardwarePort: "USB LAN",
                device: "en10",
                ipv4: ethernetIP,
                netmask: 0xffffff00,
                isActive: true
            ),
            gateway: "10.0.0.1",
            primaryService: primaryService,
            serviceOrder: [
                NetworkService(order: 1, name: primaryService, device: primaryService == "Wi-Fi" ? "en0" : "en10", isEnabled: true),
                NetworkService(order: 2, name: primaryService == "Wi-Fi" ? "USB LAN" : "Wi-Fi", device: primaryService == "Wi-Fi" ? "en10" : "en0", isEnabled: true)
            ],
            capturedAt: Date()
        )
    }

    private func makeControllerStateDirectory(named name: String) throws -> URL {
        let safeName = name.replacingOccurrences(of: "()", with: "")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SplitRouteTests-\(ProcessInfo.processInfo.processIdentifier)-\(safeName)",
                isDirectory: true
            )
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        return directory
    }
}

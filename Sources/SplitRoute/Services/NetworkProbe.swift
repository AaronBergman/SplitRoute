import Foundation

struct NetworkProbe: Sendable {
    func capture() throws -> NetworkSnapshot {
        let hardwareOutput = try CommandRunner.checked(
            "/usr/sbin/networksetup",
            arguments: ["-listallhardwareports"]
        )
        let orderOutput = try CommandRunner.checked(
            "/usr/sbin/networksetup",
            arguments: ["-listnetworkserviceorder"]
        )
        let routeOutput = try CommandRunner.checked(
            "/sbin/route",
            arguments: ["-n", "get", "default"]
        )

        let ports = Self.parseHardwarePorts(hardwareOutput)
        let services = Self.parseServiceOrder(orderOutput)
        let gateway = Self.parseGateway(routeOutput)

        let wifiPort = ports.first { port in
            let name = port.name.lowercased()
            return name == "wi-fi" || name == "airport"
        }
        let wifi = wifiPort.flatMap { details(for: $0) }

        let ethernetCandidates = ports
            .filter { Self.isEthernetCandidate($0, wifiDevice: wifiPort?.device) }
            .compactMap { details(for: $0) }
        let ethernet = Self.selectEthernetCandidate(
            ethernetCandidates,
            wifi: wifi
        )

        let primaryService = services
            .sorted { $0.order < $1.order }
            .first(where: \.isEnabled)?
            .name

        return NetworkSnapshot(
            wifi: wifi,
            ethernet: ethernet,
            gateway: gateway,
            primaryService: primaryService,
            serviceOrder: services,
            capturedAt: Date()
        )
    }

    private func details(for port: HardwarePort) -> InterfaceDetails? {
        guard let output = try? CommandRunner.checked("/sbin/ifconfig", arguments: [port.device]) else {
            return nil
        }
        return Self.parseInterface(output, hardwarePort: port.name, device: port.device)
    }

    static func parseHardwarePorts(_ output: String) -> [HardwarePort] {
        var ports: [HardwarePort] = []
        var currentName: String?

        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix("Hardware Port: ") {
                currentName = String(line.dropFirst("Hardware Port: ".count))
            } else if line.hasPrefix("Device: "), let name = currentName {
                ports.append(HardwarePort(
                    name: name,
                    device: String(line.dropFirst("Device: ".count))
                ))
                currentName = nil
            }
        }
        return ports
    }

    static func parseServiceOrder(_ output: String) -> [NetworkService] {
        let orderExpression = try? NSRegularExpression(pattern: #"^\((\d+)\) (.*)$"#)
        let deviceExpression = try? NSRegularExpression(pattern: #"Device: ([^)]+)\)"#)
        var services: [NetworkService] = []

        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            let range = NSRange(line.startIndex..., in: line)
            if let match = orderExpression?.firstMatch(in: line, range: range),
               let orderRange = Range(match.range(at: 1), in: line),
               let nameRange = Range(match.range(at: 2), in: line),
               let order = Int(line[orderRange]) {
                let rawName = String(line[nameRange])
                let enabled = !rawName.hasPrefix("*")
                let name = rawName.trimmingCharacters(in: CharacterSet(charactersIn: "*"))
                services.append(NetworkService(order: order, name: name, device: nil, isEnabled: enabled))
            } else if !services.isEmpty,
                      let match = deviceExpression?.firstMatch(in: line, range: range),
                      let deviceRange = Range(match.range(at: 1), in: line) {
                let last = services.removeLast()
                services.append(NetworkService(
                    order: last.order,
                    name: last.name,
                    device: String(line[deviceRange]),
                    isEnabled: last.isEnabled
                ))
            }
        }
        return services
    }

    static func parseGateway(_ output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            if parts.count >= 2, parts[0] == "gateway:" {
                return String(parts[1])
            }
        }
        return nil
    }

    static func parseInterface(
        _ output: String,
        hardwarePort: String,
        device: String
    ) -> InterfaceDetails {
        let inetExpression = try? NSRegularExpression(
            pattern: #"\binet (\d+\.\d+\.\d+\.\d+) netmask (0x[0-9a-fA-F]+)"#
        )
        let range = NSRange(output.startIndex..., in: output)
        var address: String?
        var mask: UInt32?

        if let match = inetExpression?.firstMatch(in: output, range: range),
           let addressRange = Range(match.range(at: 1), in: output),
           let maskRange = Range(match.range(at: 2), in: output) {
            address = String(output[addressRange])
            mask = UInt32(output[maskRange].dropFirst(2), radix: 16)
        }

        return InterfaceDetails(
            hardwarePort: hardwarePort,
            device: device,
            ipv4: address,
            netmask: mask,
            isActive: output.contains("status: active")
        )
    }

    static func isEthernetCandidate(_ port: HardwarePort, wifiDevice: String?) -> Bool {
        guard port.device != wifiDevice else { return false }
        let name = port.name.lowercased()
        return name.contains("ethernet") || name.contains("lan") || name.contains("thunderbolt")
    }

    static func ethernetScore(_ name: String) -> Int {
        let value = name.lowercased()
        if value.contains("lan") { return 0 }
        if value.contains("usb") && value.contains("ethernet") { return 1 }
        if value.contains("ethernet") { return 2 }
        return 3
    }

    static func selectEthernetCandidate(
        _ candidates: [InterfaceDetails],
        wifi: InterfaceDetails?
    ) -> InterfaceDetails? {
        candidates.sorted { lhs, rhs in
            let lhsRank = ethernetRank(lhs, wifi: wifi)
            let rhsRank = ethernetRank(rhs, wifi: wifi)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return ethernetScore(lhs.hardwarePort) < ethernetScore(rhs.hardwarePort)
        }.first
    }

    private static func ethernetRank(
        _ candidate: InterfaceDetails,
        wifi: InterfaceDetails?
    ) -> Int {
        guard candidate.isActive else { return 3 }
        guard candidate.ipv4 != nil else { return 2 }
        return interfacesShareSubnet(wifi, candidate) ? 0 : 1
    }

    private static func interfacesShareSubnet(
        _ first: InterfaceDetails?,
        _ second: InterfaceDetails
    ) -> Bool {
        guard
            let first,
            let firstIP = first.ipv4,
            let secondIP = second.ipv4,
            let firstMask = first.netmask,
            let secondMask = second.netmask,
            firstMask == secondMask,
            let firstValue = IPv4Address(firstIP)?.rawValue,
            let secondValue = IPv4Address(secondIP)?.rawValue
        else { return false }

        return (firstValue & firstMask) == (secondValue & secondMask)
    }
}

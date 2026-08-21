import Darwin
import Foundation

struct InterfaceCounterReader: Sendable {
    func read(device: String?) -> InterfaceCounters {
        guard let device else { return .zero }

        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return .zero }
        defer { freeifaddrs(addresses) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard String(cString: current.pointee.ifa_name) == device else { continue }
            guard let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK) else {
                continue
            }
            guard let rawData = current.pointee.ifa_data else { continue }

            let data = rawData.assumingMemoryBound(to: if_data.self).pointee
            return InterfaceCounters(
                receivedBytes: UInt64(data.ifi_ibytes),
                sentBytes: UInt64(data.ifi_obytes)
            )
        }
        return .zero
    }
}

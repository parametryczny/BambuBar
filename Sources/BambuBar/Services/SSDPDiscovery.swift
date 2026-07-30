import Darwin
import Foundation

final class SSDPDiscovery: @unchecked Sendable {
    func scan(seconds: TimeInterval = 4) async -> [DiscoveredPrinter] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.performScan(seconds: seconds))
            }
        }
    }

    private func performScan(seconds: TimeInterval) -> [DiscoveredPrinter] {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { return [] }
        defer { close(descriptor) }

        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEPORT, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))

        // Bambu Studio listens for printer SSDP announcements on UDP port 2021.
        var localAddress = sockaddr_in()
        localAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        localAddress.sin_family = sa_family_t(AF_INET)
        localAddress.sin_port = in_port_t(2021).bigEndian
        localAddress.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bindResult = withUnsafePointer(to: &localAddress) { address in
            address.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { return [] }

        var membership = ip_mreq(
            imr_multiaddr: in_addr(s_addr: inet_addr("239.255.255.250")),
            imr_interface: in_addr(s_addr: INADDR_ANY)
        )
        setsockopt(descriptor, IPPROTO_IP, IP_ADD_MEMBERSHIP, &membership, socklen_t(MemoryLayout.size(ofValue: membership)))

        var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))

        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = in_port_t(1900).bigEndian
        inet_pton(AF_INET, "239.255.255.250", &destination.sin_addr)

        let message = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: urn:bambulab-com:device:3dprinter:1\r\n\r\n"
        message.withCString { pointer in
            withUnsafePointer(to: &destination) { address in
                address.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = sendto(descriptor, pointer, strlen(pointer), 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        let deadline = Date().addingTimeInterval(seconds)
        var found: [String: DiscoveredPrinter] = [:]
        while Date() < deadline {
            var buffer = [UInt8](repeating: 0, count: 8192)
            var sender = sockaddr_in()
            var senderLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let received = withUnsafeMutablePointer(to: &sender) { address in
                address.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    recvfrom(descriptor, &buffer, buffer.count, 0, sockaddrPointer, &senderLength)
                }
            }
            guard received > 0 else { continue }

            var senderAddress = sender.sin_addr
            var hostBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &senderAddress, &hostBuffer, socklen_t(INET_ADDRSTRLEN))
            let nullIndex = hostBuffer.firstIndex(of: 0) ?? hostBuffer.endIndex
            let fallbackHost = String(decoding: hostBuffer[..<nullIndex].map(UInt8.init(bitPattern:)), as: UTF8.self)
            let data = Data(buffer.prefix(received))
            if let printer = SSDPResponseParser.parse(data, fallbackHost: fallbackHost) {
                found[printer.serial] = printer
            }
        }
        return found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

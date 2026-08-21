import Foundation
import OSLog
import Security

@MainActor
final class SpeedTestService: ObservableObject {
    // Cloudflare's speed endpoint rejects larger single downloads with HTTP 403.
    // Repeat accepted chunks to fill the timed phase instead of requesting one
    // oversized object.
    nonisolated static let downloadChunkBytes = 25_000_000
    nonisolated static let uploadChunkBytes = 10_000_000
    nonisolated static let fallbackDownloadURL = URL(
        string: "https://fsn1-speed.hetzner.com/100MB.bin"
    )!

    @Published private(set) var phase: SpeedTestPhase = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var result: SpeedTestResult?
    @Published private(set) var liveTraffic: LiveTraffic = .zero
    @Published private(set) var downloadMbps: Double?
    @Published private(set) var uploadMbps: Double?
    @Published private(set) var downloadViaWifiPercent: Double?
    @Published private(set) var uploadViaEthernetPercent: Double?

    private let phaseDuration: TimeInterval = 7
    private let counterReader = InterfaceCounterReader()
    private let logger = Logger(subsystem: "com.aaronbergman.SplitRoute", category: "SpeedTest")
    private var runTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?

    func run(wifiDevice: String, ethernetDevice: String) {
        guard !phase.isRunning else { return }

        runTask?.cancel()
        result = nil
        downloadMbps = nil
        uploadMbps = nil
        downloadViaWifiPercent = nil
        uploadViaEthernetPercent = nil
        progress = 0
        phase = .downloading

        monitorTask = Task { [weak self] in
            await self?.monitorTraffic(wifiDevice: wifiDevice, ethernetDevice: ethernetDevice)
        }

        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                let wifiDownloadStart = counterReader.read(device: wifiDevice)
                let ethernetDownloadStart = counterReader.read(device: ethernetDevice)
                let download = try await runDownloadPhase()
                let wifiDownloadDelta = counterReader.read(device: wifiDevice).delta(from: wifiDownloadStart)
                let ethernetDownloadDelta = counterReader.read(device: ethernetDevice).delta(from: ethernetDownloadStart)
                let inboundTotal = wifiDownloadDelta.receivedBytes + ethernetDownloadDelta.receivedBytes
                let wifiShare = inboundTotal > 0
                    ? Double(wifiDownloadDelta.receivedBytes) / Double(inboundTotal) * 100
                    : 0

                downloadMbps = download
                downloadViaWifiPercent = wifiShare
                phase = .uploading
                progress = 0.5

                let wifiUploadStart = counterReader.read(device: wifiDevice)
                let ethernetUploadStart = counterReader.read(device: ethernetDevice)
                let upload = try await runUploadPhase()
                let wifiUploadDelta = counterReader.read(device: wifiDevice).delta(from: wifiUploadStart)
                let ethernetUploadDelta = counterReader.read(device: ethernetDevice).delta(from: ethernetUploadStart)
                let outboundTotal = wifiUploadDelta.sentBytes + ethernetUploadDelta.sentBytes
                let ethernetShare = outboundTotal > 0
                    ? Double(ethernetUploadDelta.sentBytes) / Double(outboundTotal) * 100
                    : 0

                uploadMbps = upload
                uploadViaEthernetPercent = ethernetShare
                result = SpeedTestResult(
                    downloadMbps: download,
                    uploadMbps: upload,
                    downloadViaWifiPercent: wifiShare,
                    uploadViaEthernetPercent: ethernetShare
                )
                progress = 1
                phase = .complete
            } catch is CancellationError {
                phase = .idle
                progress = 0
            } catch {
                logger.error("Speed test failed: \(error.localizedDescription, privacy: .public)")
                phase = .failed(error.localizedDescription)
            }
            monitorTask?.cancel()
        }
    }

    func cancel() {
        runTask?.cancel()
        monitorTask?.cancel()
        phase = .idle
        progress = 0
    }

    private func runDownloadPhase() async throws -> Double {
        let started = Date()
        var totalBytes: UInt64 = 0
        var downloadURL = URL(
            string: "https://speed.cloudflare.com/__down?bytes=\(Self.downloadChunkBytes)"
        )!
        var isUsingFallback = false

        while Date().timeIntervalSince(started) < phaseDuration {
            try Task.checkCancellation()
            let remaining = phaseDuration - Date().timeIntervalSince(started)
            let timeout = max(0.25, remaining)
            let currentDownloadURL = downloadURL
            do {
                let counts = try await Task.detached(priority: .userInitiated) {
                    try IPv4CurlTransfer.download(url: currentDownloadURL, timeout: timeout)
                }.value
                totalBytes += counts.receivedBytes
            } catch SpeedTestError.httpStatus(429) {
                guard !isUsingFallback else { throw SpeedTestError.rateLimited }
                logger.notice("Cloudflare rate-limited the download; continuing with the documented Hetzner IPv4 test file.")
                downloadURL = Self.fallbackDownloadURL
                isUsingFallback = true
                continue
            }
            progress = min(0.5, Date().timeIntervalSince(started) / phaseDuration * 0.5)
        }

        guard totalBytes > 0 else { throw SpeedTestError.noTransferData }

        let elapsed = max(Date().timeIntervalSince(started), 0.001)
        return Double(totalBytes) * 8 / elapsed / 1_000_000
    }

    private func runUploadPhase() async throws -> Double {
        let uploadBody = try Self.secureRandomData(count: Self.uploadChunkBytes)
        let started = Date()
        var totalBytes: UInt64 = 0

        while Date().timeIntervalSince(started) < phaseDuration {
            try Task.checkCancellation()
            let remaining = phaseDuration - Date().timeIntervalSince(started)
            let timeout = max(0.25, remaining)
            do {
                let counts = try await Task.detached(priority: .userInitiated) {
                    try IPv4CurlTransfer.upload(body: uploadBody, timeout: timeout)
                }.value
                totalBytes += counts.sentBytes
            } catch SpeedTestError.httpStatus(429) {
                guard totalBytes > 0 else { throw SpeedTestError.rateLimited }
                logger.notice("Cloudflare rate-limited a later upload chunk; using the completed timed sample.")
                break
            }
            progress = min(1, 0.5 + Date().timeIntervalSince(started) / phaseDuration * 0.5)
        }

        guard totalBytes > 0 else { throw SpeedTestError.noTransferData }

        let elapsed = max(Date().timeIntervalSince(started), 0.001)
        return Double(totalBytes) * 8 / elapsed / 1_000_000
    }

    private func monitorTraffic(wifiDevice: String, ethernetDevice: String) async {
        var wifiPrevious = counterReader.read(device: wifiDevice)
        var ethernetPrevious = counterReader.read(device: ethernetDevice)
        var previousDate = Date()

        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }

            let now = Date()
            let elapsed = max(now.timeIntervalSince(previousDate), 0.001)
            let wifiCurrent = counterReader.read(device: wifiDevice)
            let ethernetCurrent = counterReader.read(device: ethernetDevice)
            let wifiDelta = wifiCurrent.delta(from: wifiPrevious)
            let ethernetDelta = ethernetCurrent.delta(from: ethernetPrevious)

            liveTraffic = LiveTraffic(
                wifiDownBytesPerSecond: Double(wifiDelta.receivedBytes) / elapsed,
                wifiUpBytesPerSecond: Double(wifiDelta.sentBytes) / elapsed,
                ethernetDownBytesPerSecond: Double(ethernetDelta.receivedBytes) / elapsed,
                ethernetUpBytesPerSecond: Double(ethernetDelta.sentBytes) / elapsed
            )
            wifiPrevious = wifiCurrent
            ethernetPrevious = ethernetCurrent
            previousDate = now
        }
    }

    private static func secureRandomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let result = data.withUnsafeMutableBytes { bytes in
            guard let address = bytes.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, address)
        }
        guard result == errSecSuccess else {
            throw SpeedTestError.randomDataUnavailable
        }
        return data
    }
}

private struct TransferCounts: Sendable {
    let receivedBytes: UInt64
    let sentBytes: UInt64
}

private enum IPv4CurlTransfer {
    private static let endpoint = "https://speed.cloudflare.com/__up"
    private static let metricsFormat = "splitroute|%{http_code}|%{size_download}|%{size_upload}|%{time_total}"

    static func download(url: URL, timeout: TimeInterval) throws -> TransferCounts {
        try run(
            arguments: baseArguments(timeout: timeout) + [url.absoluteString],
            input: nil
        )
    }

    static func upload(body: Data, timeout: TimeInterval) throws -> TransferCounts {
        try run(
            arguments: baseArguments(timeout: timeout) + [
                "--request", "POST",
                "--header", "Content-Type: application/octet-stream",
                "--header", "Cache-Control: no-store",
                "--data-binary", "@-",
                endpoint
            ],
            input: body
        )
    }

    private static func baseArguments(timeout: TimeInterval) -> [String] {
        let timeoutValue = String(
            format: "%.3f",
            locale: Locale(identifier: "en_US_POSIX"),
            timeout
        )
        return [
            "--ipv4",
            "--silent",
            "--show-error",
            "--max-time", timeoutValue,
            "--output", "/dev/null",
            "--write-out", metricsFormat
        ]
    }

    private static func run(arguments: [String], input: Data?) throws -> TransferCounts {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let inputPipe = input == nil ? nil : Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = inputPipe ?? FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw SpeedTestError.transferFailed("Could not start the macOS IPv4 transfer client.")
        }

        if let input, let inputPipe {
            try? inputPipe.fileHandleForWriting.write(contentsOf: input)
            try? inputPipe.fileHandleForWriting.close()
        }

        process.waitUntilExit()
        let output = String(
            decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let errorOutput = String(
            decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        let fields = output.split(separator: "|", omittingEmptySubsequences: false)
        guard fields.count == 5,
              fields[0] == "splitroute",
              let status = Int(fields[1]),
              let received = Double(fields[2]),
              let sent = Double(fields[3]) else {
            throw SpeedTestError.transferFailed(
                errorOutput.isEmpty ? "The IPv4 transfer client returned an unreadable result." : errorOutput
            )
        }

        let counts = TransferCounts(
            receivedBytes: UInt64(max(received, 0)),
            sentBytes: UInt64(max(sent, 0))
        )
        if status >= 400 {
            throw SpeedTestError.httpStatus(status)
        }

        // Exit 28 is the expected end of a timed partial chunk. It remains a
        // valid measurement if bytes moved before the deadline.
        if process.terminationStatus != 0,
           !(process.terminationStatus == 28 && (counts.receivedBytes > 0 || counts.sentBytes > 0)) {
            let message = errorOutput.isEmpty
                ? "The IPv4 transfer client exited with status \(process.terminationStatus)."
                : errorOutput
            throw SpeedTestError.transferFailed(message)
        }
        return counts
    }
}

private enum SpeedTestError: LocalizedError {
    case httpStatus(Int)
    case rateLimited
    case noTransferData
    case randomDataUnavailable
    case transferFailed(String)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let status):
            "The speed-test server returned HTTP \(status)."
        case .rateLimited:
            "Cloudflare is rate-limiting repeated tests. Wait about a minute and try again."
        case .noTransferData:
            "The speed test completed without transferring any data."
        case .randomDataUnavailable:
            "macOS could not prepare secure random upload data."
        case .transferFailed(let message):
            message
        }
    }
}

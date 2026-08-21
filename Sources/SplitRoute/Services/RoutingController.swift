import Darwin
import Foundation

struct RoutingController: Sendable {
    private static let promptFreeRepairVersion = 2

    private let stateDirectory: URL

    init(stateDirectory: URL? = nil) {
        self.stateDirectory = stateDirectory ?? URL(
            fileURLWithPath: "/private/tmp/splitroute-\(getuid())",
            isDirectory: true
        )
    }

    private var statusURL: URL { stateDirectory.appendingPathComponent("status") }
    private var intentURL: URL { stateDirectory.appendingPathComponent("intent") }
    private var stopURL: URL { stateDirectory.appendingPathComponent("stop.request") }
    private var repairURL: URL { stateDirectory.appendingPathComponent("repair.request") }
    private var watchdogPIDURL: URL { stateDirectory.appendingPathComponent("watchdog.pid") }
    private var controllerVersionURL: URL { stateDirectory.appendingPathComponent("controller.version") }

    func readState() -> RoutingState {
        let hasIntent = FileManager.default.fileExists(atPath: intentURL.path)
        let hasRepairRequest = FileManager.default.fileExists(atPath: repairURL.path)
        guard let raw = try? String(contentsOf: statusURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return hasIntent ? .waitingForEthernet : .off
        }

        switch raw {
        case "active":
            guard hasIntent else { return .off }
            if hasIntent && !isWatchdogRunning {
                return .unsafeActive("The safety watchdog is not running. Turn split routing off to restore stock rules.")
            }
            return hasRepairRequest ? .repairing : .active
        case "waiting-for-ethernet":
            guard hasIntent else { return .off }
            if hasIntent && !isWatchdogRunning {
                return .unsafeActive("The safety watchdog is not running. Turn split routing off to restore stock rules.")
            }
            return hasRepairRequest ? .repairing : .waitingForEthernet
        case "enabling": return .enabling
        case "disabling": return .disabling
        case "off": return .off
        default:
            if raw.hasPrefix("error:") {
                return .failed(String(raw.dropFirst("error:".count)).trimmingCharacters(in: .whitespaces))
            }
            return hasIntent ? .waitingForEthernet : .off
        }
    }

    func enable() throws {
        try runPrivileged(command: "enable")
    }

    func requestDisable() throws {
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let marker = Data("disable\n".utf8)
        try marker.write(to: stopURL, options: .atomic)

        // Normally the root watchdog consumes this marker with no second
        // prompt. If it died, restore through the same audited controller.
        if !isWatchdogRunning {
            try runPrivileged(command: "disable")
        }
    }

    func requestRepair() throws {
        guard FileManager.default.fileExists(atPath: intentURL.path) else {
            throw RoutingControllerError.noActiveSession
        }
        guard isWatchdogRunning else {
            throw RoutingControllerError.watchdogUnavailable
        }
        guard supportsPromptFreeRepair else {
            throw RoutingControllerError.watchdogUpgradeRequired
        }

        let marker = Data("repair\n".utf8)
        try marker.write(to: repairURL, options: .atomic)
    }

    var isWatchdogRunning: Bool {
        guard
            let raw = try? String(contentsOf: watchdogPIDURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            let pid = Int32(raw),
            pid > 1
        else { return false }

        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    var supportsPromptFreeRepair: Bool {
        guard
            isWatchdogRunning,
            let raw = try? String(contentsOf: controllerVersionURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            let version = Int(raw)
        else { return false }
        return version >= Self.promptFreeRepairVersion
    }

    private func runPrivileged(command: String) throws {
        guard let controllerURL = Bundle.module.url(
            forResource: "splitroute-controller",
            withExtension: "sh",
            subdirectory: "Resources"
        ) ?? Bundle.module.url(forResource: "splitroute-controller", withExtension: "sh") else {
            throw RoutingControllerError.missingController
        }

        let shellCommand = "/bin/zsh \(Self.shellQuote(controllerURL.path)) \(command) \(getuid())"
        let appleScriptCommand = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let result = try CommandRunner.run(
            "/usr/bin/osascript",
            arguments: ["-e", "do shell script \"\(appleScriptCommand)\" with administrator privileges"]
        )
        guard result.exitCode == 0 else {
            let message = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.contains("User canceled") || message.contains("-128") {
                throw RoutingControllerError.authorizationCancelled
            }
            throw RoutingControllerError.enableFailed(message.isEmpty ? "The privileged controller did not start." : message)
        }
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum RoutingControllerError: LocalizedError {
    case missingController
    case authorizationCancelled
    case enableFailed(String)
    case noActiveSession
    case watchdogUnavailable
    case watchdogUpgradeRequired

    var errorDescription: String? {
        switch self {
        case .missingController:
            "The bundled routing controller is missing. Rebuild SplitRoute."
        case .authorizationCancelled:
            "Administrator authorization was canceled. No routing changes were made."
        case .enableFailed(let message):
            "Split routing could not be enabled: \(message)"
        case .noActiveSession:
            "Split routing is not currently enabled."
        case .watchdogUnavailable:
            "The privileged safety watchdog is not running, so prompt-free repair is unavailable."
        case .watchdogUpgradeRequired:
            "Turn split routing off and on once to install the prompt-free repair upgrade."
        }
    }
}

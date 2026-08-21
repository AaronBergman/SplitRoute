import Foundation

struct CommandResult: Sendable {
    let standardOutput: String
    let standardError: String
    let exitCode: Int32
}

enum CommandError: LocalizedError {
    case launchFailed(String)
    case nonZeroExit(executable: String, code: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let message):
            return message
        case .nonZeroExit(let executable, let code, let message):
            return "\(executable) exited with status \(code): \(message)"
        }
    }
}

enum CommandRunner {
    static func run(_ executable: String, arguments: [String] = []) throws -> CommandResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw CommandError.launchFailed("Could not run \(executable): \(error.localizedDescription)")
        }

        process.waitUntilExit()
        let stdout = String(decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        return CommandResult(
            standardOutput: stdout,
            standardError: stderr,
            exitCode: process.terminationStatus
        )
    }

    static func checked(_ executable: String, arguments: [String] = []) throws -> String {
        let result = try run(executable, arguments: arguments)
        guard result.exitCode == 0 else {
            let message = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CommandError.nonZeroExit(executable: executable, code: result.exitCode, message: message)
        }
        return result.standardOutput
    }
}

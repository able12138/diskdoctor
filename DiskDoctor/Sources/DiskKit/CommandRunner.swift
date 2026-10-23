import Foundation

/// 执行外部命令并捕获输出。
public struct CommandRunner {
    public struct Result {
        public let status: Int32
        public let stdout: String
        public let stderr: String
        public var succeeded: Bool { status == 0 }

        public var combined: String {
            stderr.isEmpty ? stdout : (stdout.isEmpty ? stderr : stdout + "\n" + stderr)
        }
    }

    public struct Failure: LocalizedError {
        public let command: String
        public let result: Result
        public var errorDescription: String? {
            "命令执行失败：\(command)\n\(result.combined)"
        }
    }

    public init() {}

    @discardableResult
    public func run(_ executable: String, _ arguments: [String]) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw Failure(command: ([executable] + arguments).joined(separator: " "),
                          result: Result(status: -1, stdout: "", stderr: error.localizedDescription))
        }

        // 必须先读完管道再 wait，避免管道缓冲区满导致死锁。
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return Result(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    /// 执行命令并在失败时抛出错误。
    @discardableResult
    public func runChecked(_ executable: String, _ arguments: [String]) throws -> Result {
        let r = try run(executable, arguments)
        guard r.succeeded else {
            throw Failure(command: ([executable] + arguments).joined(separator: " "), result: r)
        }
        return r
    }

    /// 通过 /bin/sh 执行一段脚本（用于管道组合）。
    public func shell(_ script: String) throws -> Result {
        try run("/bin/sh", ["-c", script])
    }
}

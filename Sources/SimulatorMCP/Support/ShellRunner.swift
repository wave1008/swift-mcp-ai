import Foundation

enum ShellError: Error, CustomStringConvertible {
    case failed(command: String, status: Int32, stderr: String)

    var description: String {
        switch self {
        case .failed(let command, let status, let stderr):
            return "command failed (\(status)): \(command)\n\(stderr)"
        }
    }
}

enum ShellRunner {
    /// 外部コマンドを実行して標準出力を返す。ブロッキング呼び出しは
    /// cooperative pool を塞がないよう GCD 上で行う。
    static func run(_ executable: String, _ arguments: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                do {
                    try process.run()
                    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    if process.terminationStatus == 0 {
                        continuation.resume(returning: outData)
                    } else {
                        continuation.resume(throwing: ShellError.failed(
                            command: ([executable] + arguments).joined(separator: " "),
                            status: process.terminationStatus,
                            stderr: String(data: errData, encoding: .utf8) ?? ""
                        ))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

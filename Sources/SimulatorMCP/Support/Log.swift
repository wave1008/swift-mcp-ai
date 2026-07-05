import Foundation

/// stdio がプロトコルチャネルのため、ログは必ず stderr へ出す。
enum Log {
    static func info(_ message: String) {
        FileHandle.standardError.write(Data("[simulator-mcp] \(message)\n".utf8))
    }
}

import Foundation

struct SimDevice: Codable, Sendable {
    let name: String
    let udid: String
    let state: String
    let runtime: String
}

enum LocatorError: Error, CustomStringConvertible {
    case notFound(query: String, candidates: [String])
    case notBooted(SimDevice)

    var description: String {
        switch self {
        case .notFound(let query, let candidates):
            let hint = candidates.isEmpty
                ? "no booted simulators"
                : "booted: \(candidates.joined(separator: ", "))"
            return "simulator not found for '\(query)' (\(hint))"
        case .notBooted(let device):
            return "simulator '\(device.name)' (\(device.udid)) is not booted (state: \(device.state))"
        }
    }
}

/// simctl のデバイス一覧と Simulator ウィンドウの解決を担う。
/// 結果はキャッシュし、ミス時のみ再取得する。
actor SimulatorLocator {
    private var devices: [SimDevice] = []
    private var lastRefresh: ContinuousClock.Instant?
    private let staleAfter: Duration = .seconds(10)

    // MARK: - simctl

    private struct SimctlList: Decodable {
        struct Device: Decodable {
            let name: String
            let udid: String
            let state: String
        }
        let devices: [String: [Device]]
    }

    func refreshDevices() async throws -> [SimDevice] {
        let data = try await ShellRunner.run("/usr/bin/xcrun", ["simctl", "list", "devices", "-j"])
        let list = try JSONDecoder().decode(SimctlList.self, from: data)
        devices = list.devices.flatMap { runtimeID, devs in
            devs.map { dev in
                SimDevice(
                    name: dev.name,
                    udid: dev.udid,
                    state: dev.state,
                    runtime: runtimeID
                        .replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
                        .replacingOccurrences(of: "-", with: ".")
                        .replacingOccurrences(of: "iOS.", with: "iOS ")
                )
            }
        }
        lastRefresh = .now
        return devices
    }

    private func currentDevices() async throws -> [SimDevice] {
        if let last = lastRefresh, ContinuousClock.now - last < staleAfter, !devices.isEmpty {
            return devices
        }
        return try await refreshDevices()
    }

    /// UDID または名前で解決する。名前一致が複数ある場合は Booted を優先。
    func resolve(_ query: String) async throws -> SimDevice {
        var devs = try await currentDevices()
        var matched = Self.match(query, in: devs)
        if matched == nil {
            devs = try await refreshDevices()
            matched = Self.match(query, in: devs)
        }
        guard let device = matched else {
            let booted = devs.filter { $0.state == "Booted" }.map { "\($0.name) [\($0.udid)]" }
            throw LocatorError.notFound(query: query, candidates: booted)
        }
        guard device.state == "Booted" else { throw LocatorError.notBooted(device) }
        return device
    }

    private static func match(_ query: String, in devices: [SimDevice]) -> SimDevice? {
        if let byUDID = devices.first(where: { $0.udid.caseInsensitiveCompare(query) == .orderedSame }) {
            return byUDID
        }
        let byName = devices.filter { $0.name == query }
        return byName.first(where: { $0.state == "Booted" }) ?? byName.first
    }

    /// 起動中(Booted)のデバイス一覧を返す。
    func listBooted() async throws -> [SimDevice] {
        let devs = try await refreshDevices()
        return devs.filter { $0.state == "Booted" }
    }
}

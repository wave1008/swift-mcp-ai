import Foundation
@preconcurrency import ScreenCaptureKit

struct SimDevice: Codable, Sendable {
    let name: String
    let udid: String
    let state: String
    let runtime: String
}

enum LocatorError: Error, CustomStringConvertible {
    case notFound(query: String, candidates: [String])
    case notBooted(SimDevice)
    case windowNotFound(SimDevice)
    case screenCapturePermissionDenied

    var description: String {
        switch self {
        case .notFound(let query, let candidates):
            let hint = candidates.isEmpty
                ? "no booted simulators"
                : "booted: \(candidates.joined(separator: ", "))"
            return "simulator not found for '\(query)' (\(hint))"
        case .notBooted(let device):
            return "simulator '\(device.name)' (\(device.udid)) is not booted (state: \(device.state))"
        case .windowNotFound(let device):
            return "no on-screen window for simulator '\(device.name)'. "
                + "Simulator.app / DeviceHub.app のウィンドウが表示されている必要があります(最小化は不可)"
        case .screenCapturePermissionDenied:
            return "screen recording permission denied. "
                + "システム設定 > プライバシーとセキュリティ > 画面収録 でこのプロセス(ターミナル/MCPクライアント)を許可してください"
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

    // MARK: - ScreenCaptureKit window lookup

    /// Simulator ウィンドウを持ちうるホストアプリ。
    /// Xcode 26 までは Simulator.app、Xcode 27 beta からは DeviceHub.app。
    static let hostBundleIDs: Set<String> = [
        "com.apple.iphonesimulator",
        "com.apple.dt.Devices",
    ]

    /// デバイス名に対応する Simulator ウィンドウを探す。
    static func findWindow(for device: SimDevice) async throws -> SCWindow {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw LocatorError.screenCapturePermissionDenied
        }
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        let simWindows = content.windows.filter {
            hostBundleIDs.contains($0.owningApplication?.bundleIdentifier ?? "")
                && $0.frame.height > 100
        }
        // タイトルは通常 "<デバイス名>" または "<デバイス名> — iOS xx.x" 形式。
        // 完全一致 > 区切り付き前方一致 の順で採用し、名前の部分一致誤爆を避ける。
        let name = device.name
        let candidates = simWindows.filter { window in
            guard let title = window.title else { return false }
            if title == name { return true }
            for separator in [" — ", " – ", " - "] where title.hasPrefix(name + separator) {
                return true
            }
            return false
        }
        guard let window = candidates.max(by: { $0.frame.height < $1.frame.height }) else {
            throw LocatorError.windowNotFound(device)
        }
        return window
    }

    func listWithWindowStatus() async throws -> [(device: SimDevice, hasWindow: Bool)] {
        let devs = try await refreshDevices()
        let booted = devs.filter { $0.state == "Booted" }
        var visibleTitles: Set<String> = []
        if CGPreflightScreenCaptureAccess(),
            let content = try? await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
        {
            visibleTitles = Set(
                content.windows
                    .filter { Self.hostBundleIDs.contains($0.owningApplication?.bundleIdentifier ?? "") }
                    .compactMap(\.title))
        }
        return booted.map { device in
            let hasWindow = visibleTitles.contains { title in
                title == device.name || title.hasPrefix(device.name + " ")
            }
            return (device, hasWindow)
        }
    }
}

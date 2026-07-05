import CoreGraphics
import Foundation

struct CaptureResult: Sendable {
    let image: ImageInput
    let source: String  // "framebuffer"
}

/// `simctl io screenshot` でデバイス画面バッファを直接取得する。
/// デバイス画面のみ・ネイティブ解像度。ウィンドウ不要(最小化・背後でも可)・画面収録許可も不要。
actor CaptureEngine {
    func capture(device: SimDevice) async throws -> CaptureResult {
        let image = try await Self.framebufferScreenshot(udid: device.udid)
        return CaptureResult(image: .cgImage(image), source: "framebuffer")
    }

    /// `simctl io screenshot` はファイル出力しか持たないため、一時ファイルを経由して読み込む
    private static func framebufferScreenshot(udid: String) async throws -> CGImage {
        let url = ImageCodec.outputDirectory
            .appendingPathComponent("fb-\(udid.prefix(8))-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await ShellRunner.run(
            "/usr/bin/xcrun", ["simctl", "io", udid, "screenshot", url.path])
        // defer でファイルを消すため、URL 経由の遅延デコードではなくメモリに読み込んでから復号する
        return try ImageCodec.decode(try Data(contentsOf: url))
    }
}

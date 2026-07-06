import CoreGraphics
import Foundation

struct CaptureResult: Sendable {
    let image: ImageInput
    let source: String  // "framebuffer"
}

enum CaptureError: Error, CustomStringConvertible {
    case signatureRenderFailed

    var description: String { "フレーム比較用の縮小描画に失敗しました" }
}

/// `simctl io screenshot` でデバイス画面バッファを直接取得する。
/// デバイス画面のみ・ネイティブ解像度。ウィンドウ不要(最小化・背後でも可)・画面収録許可も不要。
actor CaptureEngine {
    func capture(device: SimDevice) async throws -> CaptureResult {
        let image = try await Self.framebufferScreenshot(udid: device.udid)
        return CaptureResult(image: .cgImage(image), source: "framebuffer")
    }

    /// 画面が静止するまで待ってからキャプチャする。
    ///
    /// スクロールの慣性や画面遷移アニメーションの最中に観察すると、OCR/YOLO の
    /// 座標が数百 px ずれて後続のタップが隣の行に落ちる(実測)。連続2フレームの
    /// 縮小画像がほぼ一致するまで待つ(最大 ~2.5 秒)ことで静止画面を保証する。
    func captureStable(device: SimDevice) async throws -> CaptureResult {
        var current = try await capture(device: device)
        var signature = try Self.motionSignature(current.image.makeCGImage())
        for _ in 0..<7 {
            try? await Task.sleep(for: .milliseconds(300))
            let next = try await capture(device: device)
            let nextSignature = try Self.motionSignature(next.image.makeCGImage())
            if Self.nearlyEqual(signature, nextSignature) { return next }
            current = next
            signature = nextSignature
        }
        return current
    }

    /// 動き検出用の縮小シグネチャ(RGBA 32x64)。
    private static func motionSignature(_ image: CGImage) throws -> [UInt8] {
        let width = 32
        let height = 64
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard
            let context = CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw CaptureError.signatureRenderFailed }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    /// 時計表示の更新やカーソル点滅程度の差分は「静止」とみなす。
    private static func nearlyEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var diff = 0
        for i in 0..<a.count {
            diff += abs(Int(a[i]) - Int(b[i]))
        }
        return diff < a.count * 2
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

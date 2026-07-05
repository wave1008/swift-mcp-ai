import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

/// キャプチャ経路。
/// - window: Simulator ウィンドウを ScreenCaptureKit で取得(常駐ストリームで高速)。
///   ホストアプリの UI(DeviceHub のサイドバー等)やベゼルも写り込む
/// - framebuffer: `simctl io screenshot` でデバイス画面バッファを直接取得。
///   デバイス画面のみ・ネイティブ解像度。ウィンドウ不要(最小化・背後でも可)だが毎回数百 ms
enum CaptureSource: String, Sendable {
    case window
    case framebuffer
}

struct CaptureResult: Sendable {
    let image: ImageInput
    let source: String  // "stream" | "screenshot" | "framebuffer"
}

/// 1つの Simulator ウィンドウに SCStream を常駐させ、最新フレームを保持する。
/// コールバックは SCK のキューから来るためロックで保護する。
final class WindowCapturer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var latestBuffer: CVPixelBuffer?
    private var stream: SCStream?
    private var streamFailed = false
    var lastAccess: ContinuousClock.Instant

    let udid: String

    init(udid: String) {
        self.udid = udid
        self.lastAccess = .now
    }

    /// NSLock は async 文脈から直接呼べないため、同期ヘルパー経由でロックする
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func start(window: SCWindow) async throws {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let pixelScale = CGFloat(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * pixelScale)
        config.height = Int(filter.contentRect.height * pixelScale)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 3

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(
            self, type: .screen,
            sampleHandlerQueue: DispatchQueue(label: "capture.\(udid)"))
        try await stream.startCapture()
        withLock {
            self.stream = stream
            self.streamFailed = false
        }
    }

    func stop() async {
        let stream: SCStream? = withLock {
            let current = self.stream
            self.stream = nil
            self.latestBuffer = nil
            return current
        }
        try? await stream?.stopCapture()
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stream != nil && !streamFailed
    }

    func latestFrame() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        lastAccess = .now
        return latestBuffer
    }

    // MARK: - SCStreamOutput

    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen, sampleBuffer.isValid,
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let statusRaw = attachments.first?[.status] as? Int,
            SCFrameStatus(rawValue: statusRaw) == .complete,
            let buffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        lock.lock()
        latestBuffer = buffer
        lock.unlock()
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        streamFailed = true
        latestBuffer = nil
        lock.unlock()
        Log.info("stream for \(udid) stopped: \(error.localizedDescription)")
    }
}

/// UDID ごとの WindowCapturer を管理するエンジン。
/// 初回はワンショット(SCScreenshotManager)で即応答しつつ裏でストリームを開始、
/// 2回目以降は保持中の最新フレームをゼロ待ちで返す。
actor CaptureEngine {
    private var capturers: [String: WindowCapturer] = [:]
    private var startingStreams: Set<String> = []
    private let idleTimeout: Duration = .seconds(30)
    private var reaperTask: Task<Void, Never>?

    func capture(device: SimDevice, source: CaptureSource = .window) async throws -> CaptureResult {
        if source == .framebuffer {
            let image = try await Self.framebufferScreenshot(udid: device.udid)
            return CaptureResult(image: .cgImage(image), source: "framebuffer")
        }
        let udid = device.udid
        // 常駐ストリームに新しいフレームがあれば即返す
        if let capturer = capturers[udid], capturer.isRunning,
            let buffer = capturer.latestFrame()
        {
            return CaptureResult(image: .pixelBuffer(buffer), source: "stream")
        }

        // ワンショット取得(初回 or ストリーム未確立時)
        let window = try await SimulatorLocator.findWindow(for: device)
        let image = try await Self.screenshot(window: window)

        // 次回以降を高速化するため、裏でストリームを起動しておく
        ensureStream(udid: udid, window: window)
        return CaptureResult(image: .cgImage(image), source: "screenshot")
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

    private static func screenshot(window: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let pixelScale = CGFloat(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * pixelScale)
        config.height = Int(filter.contentRect.height * pixelScale)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config)
    }

    private func ensureStream(udid: String, window: SCWindow) {
        guard capturers[udid]?.isRunning != true, !startingStreams.contains(udid) else { return }
        startingStreams.insert(udid)
        let capturer = WindowCapturer(udid: udid)
        Task {
            do {
                try await capturer.start(window: window)
                await self.registerCapturer(capturer, udid: udid)
            } catch {
                Log.info("failed to start stream for \(udid): \(error)")
                await self.streamStartFinished(udid: udid)
            }
        }
    }

    private func registerCapturer(_ capturer: WindowCapturer, udid: String) async {
        if let old = capturers[udid] {
            await old.stop()
        }
        capturers[udid] = capturer
        startingStreams.remove(udid)
        startReaperIfNeeded()
    }

    private func streamStartFinished(udid: String) {
        startingStreams.remove(udid)
    }

    /// アイドルストリームの自動解放
    private func startReaperIfNeeded() {
        guard reaperTask == nil else { return }
        reaperTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                await self.reapIdle()
            }
        }
    }

    private func reapIdle() async {
        let now = ContinuousClock.now
        for (udid, capturer) in capturers where now - capturer.lastAccess > idleTimeout {
            Log.info("stopping idle stream for \(udid)")
            await capturer.stop()
            capturers.removeValue(forKey: udid)
        }
        if capturers.isEmpty {
            reaperTask?.cancel()
            reaperTask = nil
        }
    }

    func streamStatus() -> [String: Bool] {
        capturers.mapValues(\.isRunning)
    }
}

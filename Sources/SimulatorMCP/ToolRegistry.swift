import CoreGraphics
import Foundation
import MCP

struct AppContext: Sendable {
    let locator: SimulatorLocator
    let capture: CaptureEngine
    let yolo: YoloEngine
}

// MARK: - Output payloads

private struct SimulatorSummary: Codable {
    let name: String
    let udid: String
    let runtime: String
    let windowVisible: Bool
    let streamActive: Bool
}

private struct ListOutput: Codable {
    let screenRecordingPermission: Bool
    let simulators: [SimulatorSummary]
}

private struct DeviceRef: Codable {
    let name: String
    let udid: String
}

private struct ScreenshotOutput: Codable {
    let simulator: DeviceRef
    let path: String
    let width: Int
    let height: Int
    let source: String
    let captureMs: Double
    let encodeMs: Double
}

private struct DetectOutput: Codable {
    let simulator: DeviceRef?
    let imagePath: String?
    let imageWidth: Int
    let imageHeight: Int
    let captureMs: Double?
    let inferenceMs: Double
    let detections: [Detection]
}

private struct OcrOutput: Codable {
    let simulator: DeviceRef?
    let imagePath: String?
    let imageWidth: Int
    let imageHeight: Int
    let captureMs: Double?
    let ocrMs: Double
    let texts: [RecognizedText]
}

private struct AnalyzeOutput: Codable {
    let simulator: DeviceRef
    let imageWidth: Int
    let imageHeight: Int
    let captureMs: Double
    let yoloMs: Double?
    let ocrMs: Double
    let detections: [Detection]?
    let yoloError: String?
    let texts: [RecognizedText]
    let screenshotPath: String?
}

// MARK: - Helpers

private func ms(_ duration: Duration) -> Double {
    let (seconds, attoseconds) = duration.components
    let milliseconds = Double(seconds) * 1000 + Double(attoseconds) / 1e15
    return (milliseconds * 10).rounded() / 10
}

private func jsonText<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.keyEncodingStrategy = .convertToSnakeCase
    return String(data: try encoder.encode(value), encoding: .utf8) ?? "{}"
}

extension [String: Value] {
    fileprivate func string(_ key: String) -> String? {
        self[key]?.stringValue
    }
    fileprivate func number(_ key: String) -> Double? {
        if let d = self[key]?.doubleValue { return d }
        if let i = self[key]?.intValue { return Double(i) }
        return nil
    }
    fileprivate func bool(_ key: String) -> Bool? {
        self[key]?.boolValue
    }
    fileprivate func stringArray(_ key: String) -> [String]? {
        self[key]?.arrayValue?.compactMap(\.stringValue)
    }
    fileprivate func captureSource(_ key: String) throws -> CaptureSource {
        guard let raw = string(key) else { return .window }
        guard let source = CaptureSource(rawValue: raw) else {
            throw MCPError.invalidParams("invalid source '\(raw)' (expected 'window' or 'framebuffer')")
        }
        return source
    }
    fileprivate func pixelRect(_ key: String) -> PixelRect? {
        guard let obj = self[key]?.objectValue,
            let x = obj.number("x"), let y = obj.number("y"),
            let w = obj.number("width"), let h = obj.number("height")
        else { return nil }
        return PixelRect(x: x, y: y, width: w, height: h)
    }
}

// MARK: - Tool registry

enum ToolRegistry {
    private static let simulatorProperty: Value = [
        "type": "string",
        "description": "Simulator の UDID またはデバイス名(例: 'iPhone 16')",
    ]

    private static let sourceProperty: Value = [
        "type": "string", "enum": ["window", "framebuffer"],
        "description": "キャプチャ経路(既定 window)。window: ScreenCaptureKit によるウィンドウ取得。連続呼び出しはほぼ 0ms だがホストアプリの UI やベゼルも写る。framebuffer: simctl でデバイス画面のみをネイティブ解像度で取得。ウィンドウ不要(最小化・背後でも可)だが毎回数百 ms",
    ]

    static let tools: [Tool] = [
        Tool(
            name: "list_simulators",
            description: "起動中の iOS Simulator 一覧(UDID・ウィンドウ表示状態・常駐ストリーム状態)を返す",
            inputSchema: ["type": "object", "properties": [:]]
        ),
        Tool(
            name: "capture_screenshot",
            description: "指定した Simulator のスクリーンショットを ScreenCaptureKit で高速取得しファイルに保存する。"
                + "同じ Simulator への連続呼び出しは常駐ストリームによりほぼゼロレイテンシ",
            inputSchema: [
                "type": "object",
                "properties": [
                    "simulator": simulatorProperty,
                    "source": sourceProperty,
                    "scale": [
                        "type": "number",
                        "description": "ダウンスケール比 0.1〜1.0(既定 1.0)",
                    ],
                    "format": [
                        "type": "string", "enum": ["png", "jpeg"],
                        "description": "出力形式(既定 png)",
                    ],
                    "inline": [
                        "type": "boolean",
                        "description": "true なら base64 画像もレスポンスに含める(既定 false)",
                    ],
                ],
                "required": ["simulator"],
            ]
        ),
        Tool(
            name: "detect_objects",
            description: "YOLO(Core ML 常駐)で物体・UI 要素を検出する。既定モデル(OmniParser icon_detect)は"
                + "ボタンやアイコン等のインタラクティブ UI 要素を 'icon' として検出。simulator 指定で"
                + "スクリーンショットを直接解析、image_path 指定で既存画像を解析。bbox はピクセル座標(左上原点)",
            inputSchema: [
                "type": "object",
                "properties": [
                    "simulator": simulatorProperty,
                    "source": sourceProperty,
                    "image_path": ["type": "string", "description": "解析する画像ファイルのパス(simulator と排他)"],
                    "confidence": ["type": "number", "description": "信頼度しきい値(既定 0.25)"],
                ],
            ]
        ),
        Tool(
            name: "extract_text",
            description: "Vision OCR でテキストと位置(ピクセル座標、左上原点)を抽出する。"
                + "simulator 指定でスクリーンショットを直接解析、image_path 指定で既存画像を解析",
            inputSchema: [
                "type": "object",
                "properties": [
                    "simulator": simulatorProperty,
                    "source": sourceProperty,
                    "image_path": ["type": "string", "description": "解析する画像ファイルのパス(simulator と排他)"],
                    "fast": [
                        "type": "boolean",
                        "description": "高速モード(現環境では Vision の不具合回避のため accurate で実行される。既定 false)",
                    ],
                    "language_correction": ["type": "boolean", "description": "言語補正(既定 false)"],
                    "languages": [
                        "type": "array", "items": ["type": "string"],
                        "description": "認識言語(既定 [\"ja-JP\", \"en-US\"])",
                    ],
                    "roi": [
                        "type": "object",
                        "description": "OCR 対象領域(ピクセル、左上原点)。指定するとさらに高速",
                        "properties": [
                            "x": ["type": "number"], "y": ["type": "number"],
                            "width": ["type": "number"], "height": ["type": "number"],
                        ],
                    ],
                ],
            ]
        ),
        Tool(
            name: "analyze_screen",
            description: "1回のキャプチャで YOLO 物体検出と Vision OCR を並列実行して統合結果を返す。"
                + "両方必要な場合は個別呼び出しより高速",
            inputSchema: [
                "type": "object",
                "properties": [
                    "simulator": simulatorProperty,
                    "source": sourceProperty,
                    "confidence": ["type": "number", "description": "YOLO 信頼度しきい値(既定 0.25)"],
                    "fast": ["type": "boolean", "description": "OCR 高速モード(既定 false)"],
                    "save_screenshot": ["type": "boolean", "description": "キャプチャ画像も保存してパスを返す(既定 false)"],
                ],
                "required": ["simulator"],
            ]
        ),
    ]

    static func handle(params: CallTool.Parameters, context: AppContext) async -> CallTool.Result {
        let args = params.arguments ?? [:]
        do {
            switch params.name {
            case "list_simulators":
                return try await listSimulators(context: context)
            case "capture_screenshot":
                return try await captureScreenshot(args: args, context: context)
            case "detect_objects":
                return try await detectObjects(args: args, context: context)
            case "extract_text":
                return try await extractText(args: args, context: context)
            case "analyze_screen":
                return try await analyzeScreen(args: args, context: context)
            default:
                return CallTool.Result(
                    content: [.text(text: "unknown tool: \(params.name)")], isError: true)
            }
        } catch {
            return CallTool.Result(content: [.text(text: "\(error)")], isError: true)
        }
    }

    // MARK: - Tool implementations

    private static func listSimulators(context: AppContext) async throws -> CallTool.Result {
        let entries = try await context.locator.listWithWindowStatus()
        let streams = await context.capture.streamStatus()
        let output = ListOutput(
            screenRecordingPermission: CGPreflightScreenCaptureAccess(),
            simulators: entries.map { entry in
                SimulatorSummary(
                    name: entry.device.name,
                    udid: entry.device.udid,
                    runtime: entry.device.runtime,
                    windowVisible: entry.hasWindow,
                    streamActive: streams[entry.device.udid] ?? false
                )
            })
        return CallTool.Result(content: [.text(text: try jsonText(output))])
    }

    private static func captureScreenshot(
        args: [String: Value], context: AppContext
    ) async throws -> CallTool.Result {
        guard let query = args.string("simulator") else {
            return CallTool.Result(content: [.text(text: "'simulator' is required")], isError: true)
        }
        let scale = args.number("scale") ?? 1.0
        let format = args.string("format") ?? "png"
        let inline = args.bool("inline") ?? false
        let source = try args.captureSource("source")

        let clock = ContinuousClock()
        let device = try await context.locator.resolve(query)
        let t0 = clock.now
        let captured = try await context.capture.capture(device: device, source: source)
        let captureMs = ms(clock.now - t0)

        let t1 = clock.now
        var cgImage = try captured.image.makeCGImage()
        cgImage = ImageCodec.downscale(cgImage, scale: min(max(scale, 0.1), 1.0))
        let data = try ImageCodec.encode(cgImage, format: format)
        let url = try ImageCodec.writeToTemp(
            data, prefix: String(device.udid.prefix(8)), format: format)
        let encodeMs = ms(clock.now - t1)

        let output = ScreenshotOutput(
            simulator: DeviceRef(name: device.name, udid: device.udid),
            path: url.path,
            width: cgImage.width,
            height: cgImage.height,
            source: captured.source,
            captureMs: captureMs,
            encodeMs: encodeMs
        )
        var content: [Tool.Content] = [.text(text: try jsonText(output))]
        if inline {
            let mime = format.lowercased().hasPrefix("j") ? "image/jpeg" : "image/png"
            content.append(.image(data: data.base64EncodedString(), mimeType: mime))
        }
        return CallTool.Result(content: content)
    }

    /// simulator / image_path のどちらかから解析入力を得る共通処理
    private static func resolveInput(
        args: [String: Value], context: AppContext
    ) async throws -> (input: ImageInput, device: SimDevice?, path: String?, captureMs: Double?) {
        if let query = args.string("simulator") {
            let source = try args.captureSource("source")
            let device = try await context.locator.resolve(query)
            let clock = ContinuousClock()
            let t0 = clock.now
            let captured = try await context.capture.capture(device: device, source: source)
            return (captured.image, device, nil, ms(clock.now - t0))
        }
        if let path = args.string("image_path") {
            return (.cgImage(try ImageCodec.load(path: path)), nil, path, nil)
        }
        throw MCPError.invalidParams("either 'simulator' or 'image_path' is required")
    }

    private static func detectObjects(
        args: [String: Value], context: AppContext
    ) async throws -> CallTool.Result {
        let confidence = args.number("confidence") ?? 0.25
        let (input, device, path, captureMs) = try await resolveInput(args: args, context: context)

        let clock = ContinuousClock()
        let t0 = clock.now
        let detections = try await context.yolo.detect(input: input, minConfidence: confidence)
        let (width, height) = input.pixelSize

        let output = DetectOutput(
            simulator: device.map { DeviceRef(name: $0.name, udid: $0.udid) },
            imagePath: path,
            imageWidth: width,
            imageHeight: height,
            captureMs: captureMs,
            inferenceMs: ms(clock.now - t0),
            detections: detections
        )
        return CallTool.Result(content: [.text(text: try jsonText(output))])
    }

    private static func extractText(
        args: [String: Value], context: AppContext
    ) async throws -> CallTool.Result {
        var options = OcrOptions()
        options.fast = args.bool("fast") ?? false
        options.languageCorrection = args.bool("language_correction") ?? false
        if let languages = args.stringArray("languages"), !languages.isEmpty {
            options.languages = languages
        }
        options.roi = args.pixelRect("roi")

        let (input, device, path, captureMs) = try await resolveInput(args: args, context: context)

        let clock = ContinuousClock()
        let t0 = clock.now
        let texts = try await OcrEngine.recognize(input: input, options: options)
        let (width, height) = input.pixelSize

        let output = OcrOutput(
            simulator: device.map { DeviceRef(name: $0.name, udid: $0.udid) },
            imagePath: path,
            imageWidth: width,
            imageHeight: height,
            captureMs: captureMs,
            ocrMs: ms(clock.now - t0),
            texts: texts
        )
        return CallTool.Result(content: [.text(text: try jsonText(output))])
    }

    private static func analyzeScreen(
        args: [String: Value], context: AppContext
    ) async throws -> CallTool.Result {
        guard let query = args.string("simulator") else {
            return CallTool.Result(content: [.text(text: "'simulator' is required")], isError: true)
        }
        let confidence = args.number("confidence") ?? 0.25
        var options = OcrOptions()
        options.fast = args.bool("fast") ?? false
        let saveScreenshot = args.bool("save_screenshot") ?? false
        let source = try args.captureSource("source")

        let clock = ContinuousClock()
        let device = try await context.locator.resolve(query)
        let t0 = clock.now
        let captured = try await context.capture.capture(device: device, source: source)
        let captureMs = ms(clock.now - t0)
        let input = captured.image

        // 同一フレームに対して YOLO と OCR を並列実行
        let yolo = context.yolo
        let yoloStart = clock.now
        let yoloTask = Task { try await yolo.detect(input: input, minConfidence: confidence) }
        let ocrStart = clock.now
        let ocrTask = Task { try await OcrEngine.recognize(input: input, options: options) }

        var detections: [Detection]?
        var yoloError: String?
        var yoloMs: Double?
        do {
            detections = try await yoloTask.value
            yoloMs = ms(clock.now - yoloStart)
        } catch {
            yoloError = "\(error)"
        }
        let texts = try await ocrTask.value
        let ocrMs = ms(clock.now - ocrStart)

        var screenshotPath: String?
        if saveScreenshot {
            let data = try ImageCodec.encode(try input.makeCGImage(), format: "png")
            screenshotPath = try ImageCodec.writeToTemp(
                data, prefix: String(device.udid.prefix(8)), format: "png").path
        }

        let (width, height) = input.pixelSize
        let output = AnalyzeOutput(
            simulator: DeviceRef(name: device.name, udid: device.udid),
            imageWidth: width,
            imageHeight: height,
            captureMs: captureMs,
            yoloMs: yoloMs,
            ocrMs: ocrMs,
            detections: detections,
            yoloError: yoloError,
            texts: texts,
            screenshotPath: screenshotPath
        )
        return CallTool.Result(content: [.text(text: try jsonText(output))])
    }
}

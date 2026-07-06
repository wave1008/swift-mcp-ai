import CoreGraphics
import Foundation
import MCP

struct AppContext: Sendable {
    let locator: SimulatorLocator
    let capture: CaptureEngine
    let yolo: YoloEngine
    let interact: InteractionEngine
}

// MARK: - Output payloads

private struct SimulatorSummary: Codable {
    let name: String
    let udid: String
    let runtime: String
}

private struct ListOutput: Codable {
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

private struct TapOutput: Codable {
    let simulator: DeviceRef
    let pixelX: Double
    let pixelY: Double
    let pointX: Double
    let pointY: Double
    /// システムジェスチャ回避のため座標を安全域へ調整した場合 true
    let clamped: Bool
}

private struct LaunchAppOutput: Codable {
    let simulator: DeviceRef
    let bundleId: String
    let launched: Bool
}

private struct SwipeOutput: Codable {
    let simulator: DeviceRef
    let fromX: Double
    let fromY: Double
    let toX: Double
    let toY: Double
}

private struct TypeTextOutput: Codable {
    let simulator: DeviceRef
    let typedCharacters: Int
}

private struct TapTextOutput: Codable {
    let simulator: DeviceRef
    let matchedText: String
    let x: Double
    let y: Double
}

private struct InspectRegionOutput: Codable {
    let simulator: DeviceRef
    let anchorText: String?
    let centerX: Double
    let centerY: Double
    let width: Double
    let height: Double
    let averageColor: String
    let colorName: String
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
    let uiElements: [UiElement]?
    let screenshotPath: String?
    let annotatedPath: String?
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

    static let tools: [Tool] = [
        Tool(
            name: "list_simulators",
            description: "起動中の iOS Simulator 一覧(名前・UDID・ランタイム)を返す",
            inputSchema: ["type": "object", "properties": [:]]
        ),
        Tool(
            name: "capture_screenshot",
            description: "指定した Simulator のスクリーンショットを simctl でデバイス画面バッファから取得しファイルに保存する。"
                + "デバイス画面のみ・ネイティブ解像度。ウィンドウ不要(最小化・背後でも可)",
            inputSchema: [
                "type": "object",
                "properties": [
                    "simulator": simulatorProperty,
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
            name: "tap",
            description: "画面の指定座標をタップする。x/y は analyze_screen 等が返すピクセル座標"
                + "(要素の中心座標)をそのまま渡す。point への変換はサーバー側で行う",
            inputSchema: [
                "type": "object",
                "properties": [
                    "simulator": simulatorProperty,
                    "x": ["type": "number", "description": "タップするX座標(ピクセル)"],
                    "y": ["type": "number", "description": "タップするY座標(ピクセル)"],
                ],
                "required": ["simulator", "x", "y"],
            ]
        ),
        Tool(
            name: "swipe",
            description: "指定座標間をスワイプする。座標はピクセル。"
                + "下の内容を表示(上スクロール)するには画面下部から上部へ"
                + "(from_y > to_y)スワイプする",
            inputSchema: [
                "type": "object",
                "properties": [
                    "simulator": simulatorProperty,
                    "from_x": ["type": "number", "description": "開始X座標(ピクセル)"],
                    "from_y": ["type": "number", "description": "開始Y座標(ピクセル)"],
                    "to_x": ["type": "number", "description": "終了X座標(ピクセル)"],
                    "to_y": ["type": "number", "description": "終了Y座標(ピクセル)"],
                    "duration": ["type": "number", "description": "スワイプ時間(秒、既定はAXe標準)"],
                ],
                "required": ["simulator", "from_x", "from_y", "to_x", "to_y"],
            ]
        ),
        Tool(
            name: "type_text",
            description: "フォーカス中の入力欄に文字を入力する。先に tap で入力欄をタップして"
                + "フォーカスしてから使う",
            inputSchema: [
                "type": "object",
                "properties": [
                    "simulator": simulatorProperty,
                    "text": ["type": "string", "description": "入力する文字列"],
                ],
                "required": ["simulator", "text"],
            ]
        ),
        Tool(
            name: "launch_app",
            description: "bundle_id のアプリを初期状態で起動する(起動中なら再起動)。"
                + "ホーム画面でアイコンを探すより確実。例: 設定=com.apple.Preferences",
            inputSchema: [
                "type": "object",
                "properties": [
                    "simulator": simulatorProperty,
                    "bundle_id": [
                        "type": "string",
                        "description": "起動するアプリの bundle identifier",
                    ],
                ],
                "required": ["simulator", "bundle_id"],
            ]
        ),
        Tool(
            name: "tap_text",
            description: "画面上の指定テキストを OCR で探してその場でタップする。"
                + "行・ボタン・リンクを名前で操作するときは tap(座標指定)より確実"
                + "(観察からタップまでに画面がずれる問題がない)",
            inputSchema: [
                "type": "object",
                "properties": [
                    "simulator": simulatorProperty,
                    "text": ["type": "string", "description": "タップする文字列(完全一致優先、部分一致可)"],
                    "occurrence": [
                        "type": "integer",
                        "description": "同じ文字列が複数あるときに何番目をタップするか(1始まり、既定 1)",
                    ],
                ],
                "required": ["simulator", "text"],
            ]
        ),
        Tool(
            name: "inspect_region",
            description: "画面の指定領域の平均色を返す。スイッチの状態判定に使う: "
                + "iOS のスイッチは ON=green、OFF=gray/white。"
                + "anchor_text を指定すると、その文字列の行の右端(スイッチ位置)を同一フレームで調べる。"
                + "anchor_text がない場合は x, y(中心座標、ピクセル)を指定する",
            inputSchema: [
                "type": "object",
                "properties": [
                    "simulator": simulatorProperty,
                    "anchor_text": [
                        "type": "string",
                        "description": "行ラベルの文字列。この行の右端のスイッチ領域を調べる",
                    ],
                    "x": ["type": "number", "description": "領域の中心X座標(ピクセル)"],
                    "y": ["type": "number", "description": "領域の中心Y座標(ピクセル)"],
                    "width": ["type": "number", "description": "領域の幅(ピクセル、既定 60)"],
                    "height": ["type": "number", "description": "領域の高さ(ピクセル、既定 60)"],
                ],
                "required": ["simulator"],
            ]
        ),
        Tool(
            name: "analyze_screen",
            description: "1回のキャプチャで YOLO 物体検出と Vision OCR を並列実行して統合結果を返す。"
                + "ui_elements には検出要素(icon)とテキスト(text)を読み順にまとめた UI マップ"
                + "を含む。両方必要な場合は個別呼び出しより高速",
            inputSchema: [
                "type": "object",
                "properties": [
                    "simulator": simulatorProperty,
                    "confidence": ["type": "number", "description": "YOLO 信頼度しきい値(既定 0.25)"],
                    "fast": ["type": "boolean", "description": "OCR 高速モード(既定 false)"],
                    "save_screenshot": ["type": "boolean", "description": "キャプチャ画像も保存してパスを返す(既定 false)"],
                    "annotate": [
                        "type": "boolean",
                        "description": "ui_elements の bbox(icon=赤枠 / text=緑枠)を描画した画像を保存し annotated_path で返す(既定 false)",
                    ],
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
            case "tap":
                return try await tap(args: args, context: context)
            case "swipe":
                return try await swipe(args: args, context: context)
            case "type_text":
                return try await typeText(args: args, context: context)
            case "launch_app":
                return try await launchApp(args: args, context: context)
            case "tap_text":
                return try await tapText(args: args, context: context)
            case "inspect_region":
                return try await inspectRegion(args: args, context: context)
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
        let devices = try await context.locator.listBooted()
        let output = ListOutput(
            simulators: devices.map { device in
                SimulatorSummary(
                    name: device.name,
                    udid: device.udid,
                    runtime: device.runtime
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

        let clock = ContinuousClock()
        let device = try await context.locator.resolve(query)
        let t0 = clock.now
        let captured = try await context.capture.capture(device: device)
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
            let device = try await context.locator.resolve(query)
            let clock = ContinuousClock()
            let t0 = clock.now
            let captured = try await context.capture.captureStable(device: device)
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

    /// クランプ計算に使う画面ピクセルサイズ(udid ごとに1回だけキャプチャして学習)。
    private static func screenPixelSize(
        device: SimDevice, context: AppContext
    ) async throws -> (width: Int, height: Int) {
        if let cached = await context.interact.cachedScreenSize(udid: device.udid) {
            return cached
        }
        let captured = try await context.capture.capture(device: device)
        let (width, height) = captured.image.pixelSize
        await context.interact.cacheScreenSize(udid: device.udid, width: width, height: height)
        return (width, height)
    }

    private static func tap(
        args: [String: Value], context: AppContext
    ) async throws -> CallTool.Result {
        guard let query = args.string("simulator"),
            let x = args.number("x"), let y = args.number("y")
        else {
            return CallTool.Result(
                content: [.text(text: "'simulator', 'x', 'y' are required")], isError: true)
        }
        let device = try await context.locator.resolve(query)
        let size = try await screenPixelSize(device: device, context: context)
        let safe = InteractionEngine.clampTap(x: x, y: y, width: size.width, height: size.height)
        let point = try await context.interact.tap(
            udid: device.udid, pixelX: safe.x, pixelY: safe.y)
        let output = TapOutput(
            simulator: DeviceRef(name: device.name, udid: device.udid),
            pixelX: safe.x, pixelY: safe.y, pointX: point.x, pointY: point.y,
            clamped: safe.x != x || safe.y != y)
        return CallTool.Result(content: [.text(text: try jsonText(output))])
    }

    private static func swipe(
        args: [String: Value], context: AppContext
    ) async throws -> CallTool.Result {
        guard let query = args.string("simulator"),
            let fromX = args.number("from_x"), let fromY = args.number("from_y"),
            let toX = args.number("to_x"), let toY = args.number("to_y")
        else {
            return CallTool.Result(
                content: [.text(text: "'simulator', 'from_x', 'from_y', 'to_x', 'to_y' are required")],
                isError: true)
        }
        let device = try await context.locator.resolve(query)
        let size = try await screenPixelSize(device: device, context: context)
        let from = InteractionEngine.clampSwipe(
            x: fromX, y: fromY, width: size.width, height: size.height)
        let to = InteractionEngine.clampSwipe(
            x: toX, y: toY, width: size.width, height: size.height)
        try await context.interact.swipe(
            udid: device.udid, fromPixelX: from.x, fromPixelY: from.y,
            toPixelX: to.x, toPixelY: to.y, durationSeconds: args.number("duration"))
        let output = SwipeOutput(
            simulator: DeviceRef(name: device.name, udid: device.udid),
            fromX: from.x, fromY: from.y, toX: to.x, toY: to.y)
        return CallTool.Result(content: [.text(text: try jsonText(output))])
    }

    private static func launchApp(
        args: [String: Value], context: AppContext
    ) async throws -> CallTool.Result {
        guard let query = args.string("simulator"), let bundleID = args.string("bundle_id") else {
            return CallTool.Result(
                content: [.text(text: "'simulator' and 'bundle_id' are required")], isError: true)
        }
        let device = try await context.locator.resolve(query)
        try await context.interact.launchApp(udid: device.udid, bundleID: bundleID)
        let output = LaunchAppOutput(
            simulator: DeviceRef(name: device.name, udid: device.udid),
            bundleId: bundleID, launched: true)
        return CallTool.Result(content: [.text(text: try jsonText(output))])
    }

    private static func typeText(
        args: [String: Value], context: AppContext
    ) async throws -> CallTool.Result {
        guard let query = args.string("simulator"), let text = args.string("text") else {
            return CallTool.Result(
                content: [.text(text: "'simulator' and 'text' are required")], isError: true)
        }
        let device = try await context.locator.resolve(query)
        try await context.interact.typeText(udid: device.udid, text: text)
        let output = TypeTextOutput(
            simulator: DeviceRef(name: device.name, udid: device.udid),
            typedCharacters: text.count)
        return CallTool.Result(content: [.text(text: try jsonText(output))])
    }

    /// OCR 済みテキストから対象を探す(完全一致優先、なければ部分一致)。
    private static func matchTexts(
        _ texts: [RecognizedText], keyword: String
    ) -> [RecognizedText] {
        let exact = texts.filter { $0.text == keyword }
        if !exact.isEmpty { return exact }
        return texts.filter { $0.text.contains(keyword) }
    }

    private static func center(_ rect: PixelRect) -> (x: Double, y: Double) {
        (rect.x + rect.width / 2, rect.y + rect.height / 2)
    }

    /// 見つからなかったときにモデルへ返す「見えているテキスト」の要約。
    private static func visibleTextSummary(_ texts: [RecognizedText]) -> String {
        texts.prefix(20).map(\.text).joined(separator: " / ")
    }

    private static func tapText(
        args: [String: Value], context: AppContext
    ) async throws -> CallTool.Result {
        guard let query = args.string("simulator"), let keyword = args.string("text") else {
            return CallTool.Result(
                content: [.text(text: "'simulator' and 'text' are required")], isError: true)
        }
        let occurrence = max(Int(args.number("occurrence") ?? 1), 1)
        let device = try await context.locator.resolve(query)

        // 静止フレームを取り、同じフレーム内で探してその場でタップする
        // (観察→タップの間に画面がずれる問題を構造的に避ける)
        let captured = try await context.capture.captureStable(device: device)
        let texts = try await OcrEngine.recognize(input: captured.image, options: OcrOptions())
        let matches = matchTexts(texts, keyword: keyword)
        guard matches.count >= occurrence else {
            return CallTool.Result(
                content: [
                    .text(
                        text: "「\(keyword)」が画面内に見つかりません(一致 \(matches.count) 件)。"
                            + "見えているテキスト: \(visibleTextSummary(texts))")
                ], isError: true)
        }
        let match = matches[occurrence - 1]
        let target = center(match.bbox)
        let (width, height) = captured.image.pixelSize
        await context.interact.cacheScreenSize(udid: device.udid, width: width, height: height)
        let safe = InteractionEngine.clampTap(x: target.x, y: target.y, width: width, height: height)
        _ = try await context.interact.tap(udid: device.udid, pixelX: safe.x, pixelY: safe.y)
        let output = TapTextOutput(
            simulator: DeviceRef(name: device.name, udid: device.udid),
            matchedText: match.text, x: safe.x, y: safe.y)
        return CallTool.Result(content: [.text(text: try jsonText(output))])
    }

    private static func inspectRegion(
        args: [String: Value], context: AppContext
    ) async throws -> CallTool.Result {
        guard let query = args.string("simulator") else {
            return CallTool.Result(content: [.text(text: "'simulator' is required")], isError: true)
        }
        let device = try await context.locator.resolve(query)
        let captured = try await context.capture.captureStable(device: device)
        let image = try captured.image.makeCGImage()

        // 領域の決定: anchor_text があれば同一フレーム内で行ラベルを OCR で探し、
        // その行の右側全体(スイッチがある帯)を彩度クラスタ方式で調べる。
        // スイッチの正確な位置は端末・デザインで変わるため座標を当てにせず、
        // 帯の中の「彩度の高い色」(ON の緑トラック等)を直接探す
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        var anchorText: String?
        let color: RegionInspector.Result
        if let keyword = args.string("anchor_text") {
            let texts = try await OcrEngine.recognize(input: captured.image, options: OcrOptions())
            let matches = matchTexts(texts, keyword: keyword)
            guard let match = matches.first else {
                return CallTool.Result(
                    content: [
                        .text(
                            text: "anchor_text「\(keyword)」が画面内に見つかりません。"
                                + "見えているテキスト: \(visibleTextSummary(texts))")
                    ], isError: true)
            }
            anchorText = match.text
            let imageWidth = Double(image.width)
            x = imageWidth * 0.775  // 行の右側 55%〜100% の帯
            y = center(match.bbox).y
            width = imageWidth * 0.45
            height = args.number("height") ?? 110
            color = try RegionInspector.dominantAccentColor(
                of: image, centerX: x, centerY: y, width: width, height: height)
        } else if let argX = args.number("x"), let argY = args.number("y") {
            x = argX
            y = argY
            width = args.number("width") ?? 60
            height = args.number("height") ?? 60
            color = try RegionInspector.averageColor(
                of: image, centerX: x, centerY: y, width: width, height: height)
        } else {
            return CallTool.Result(
                content: [.text(text: "'anchor_text' か 'x'+'y' のどちらかが必要です")],
                isError: true)
        }
        let output = InspectRegionOutput(
            simulator: DeviceRef(name: device.name, udid: device.udid),
            anchorText: anchorText,
            centerX: x, centerY: y, width: width, height: height,
            averageColor: color.hex, colorName: color.name)
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
        let annotate = args.bool("annotate") ?? false

        let clock = ContinuousClock()
        let device = try await context.locator.resolve(query)
        let t0 = clock.now
        let captured = try await context.capture.captureStable(device: device)
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
        let uiElements = detections.map {
            UiMap.build(detections: $0, texts: texts, imageWidth: width)
        }

        var annotatedPath: String?
        if annotate, let uiElements {
            let drawn = try UiMapRenderer.draw(
                elements: uiElements, texts: texts, on: try input.makeCGImage())
            let data = try ImageCodec.encode(drawn, format: "png")
            annotatedPath = try ImageCodec.writeToTemp(
                data, prefix: "\(device.udid.prefix(8))-annotated", format: "png").path
        }
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
            uiElements: uiElements,
            screenshotPath: screenshotPath,
            annotatedPath: annotatedPath
        )
        return CallTool.Result(content: [.text(text: try jsonText(output))])
    }
}

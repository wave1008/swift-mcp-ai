import Darwin
import Foundation
import MCP
import System

// Vision / Core ML は診断メッセージを stdout に出力することがあり、
// JSON-RPC チャネルを破壊する。プロトコル用に stdout を複製してから
// fd 1 を stderr に付け替え、ライブラリの出力を stderr へ逃がす。
let protocolFD = dup(STDOUT_FILENO)
dup2(STDERR_FILENO, STDOUT_FILENO)

let locator = SimulatorLocator()
let captureEngine = CaptureEngine()
let yoloEngine = YoloEngine(
    modelPath: ProcessInfo.processInfo.environment["YOLO_MODEL_PATH"])
let interactionEngine = InteractionEngine(
    axePath: ProcessInfo.processInfo.environment["AXE_PATH"])
let context = AppContext(
    locator: locator, capture: captureEngine, yolo: yoloEngine, interact: interactionEngine)

let server = Server(
    name: "simulator-mcp",
    version: "0.2.0",
    instructions: """
        iOS Simulator の画面を simctl でデバイス画面バッファから取得し、\
        YOLO(Core ML)による物体検出と Vision OCR によるテキスト抽出、\
        AXe による UI 操作(tap / swipe / type_text)を提供します。\
        simulator 引数には UDID かデバイス名を1つだけ指定してください。\
        座標は知覚・操作ともキャプチャ画像のピクセル座標(左上原点)で統一されています。
        """,
    capabilities: .init(tools: .init(listChanged: false))
)

_ = await server.withMethodHandler(ListTools.self) { _ in
    ListTools.Result(tools: ToolRegistry.tools)
}
_ = await server.withMethodHandler(CallTool.self) { params in
    await ToolRegistry.handle(params: params, context: context)
}

// YOLO / OCR はバックグラウンドでロード+ウォームアップし、初回呼び出しの遅延を吸収する
// (Vision の日本語 accurate モデルは初回ロードに数十秒かかる)
Task.detached(priority: .utility) {
    await yoloEngine.warmUp()
}
Task.detached(priority: .utility) {
    await OcrEngine.warmUp()
}

let transport = StdioTransport(output: FileDescriptor(rawValue: protocolFD))
try await server.start(transport: transport)
Log.info("simulator-mcp started (pid \(ProcessInfo.processInfo.processIdentifier))")
await server.waitUntilCompleted()

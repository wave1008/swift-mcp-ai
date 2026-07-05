import CoreML
import Foundation
@preconcurrency import Vision

struct Detection: Codable, Sendable {
    let label: String
    let confidence: Double
    let bbox: PixelRect
}

struct PixelRect: Codable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

enum YoloError: Error, CustomStringConvertible {
    case modelNotFound([String])
    case invalidResults

    var description: String {
        switch self {
        case .modelNotFound(let searched):
            return """
                YOLO model not found. Searched: \(searched.joined(separator: ", ")). \
                環境変数 YOLO_MODEL_PATH で .mlpackage / .mlmodelc を指定するか、\
                scripts/export_yolo.py で Models/ にモデルを生成してください
                """
        case .invalidResults:
            return "YOLO model returned unexpected results (export with nms=True required)"
        }
    }
}

/// Core ML 化した YOLO を常駐ロードして推論する。
/// モデルは初回アクセス時にロード+ウォームアップし、以後メモリに保持する。
actor YoloEngine {
    private var vnModel: VNCoreMLModel?
    private var loadError: Error?
    private let explicitPath: String?

    init(modelPath: String?) {
        self.explicitPath = modelPath
    }

    // MARK: - Model loading

    private func searchPaths() -> (candidates: [String], searchedDirs: [String]) {
        var paths: [String] = []
        if let explicitPath { paths.append(explicitPath) }
        let cwd = FileManager.default.currentDirectoryPath
        let executableDir = Bundle.main.executableURL?
            .deletingLastPathComponent().path ?? cwd
        let dirs = [cwd + "/Models", executableDir + "/Models", executableDir]
        for dir in dirs {
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) {
                for entry in entries.sorted()
                where entry.hasSuffix(".mlpackage") || entry.hasSuffix(".mlmodelc") {
                    paths.append(dir + "/" + entry)
                }
            }
        }
        return (paths, (explicitPath.map { [$0] } ?? []) + dirs)
    }

    private func loadedModel() throws -> VNCoreMLModel {
        if let vnModel { return vnModel }
        if let loadError { throw loadError }
        do {
            let (paths, searchedDirs) = searchPaths()
            guard let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) })
            else { throw YoloError.modelNotFound(searchedDirs) }

            let modelURL = URL(fileURLWithPath: path)
            let compiledURL: URL
            if path.hasSuffix(".mlmodelc") {
                compiledURL = modelURL
            } else {
                compiledURL = try Self.compiledURL(for: modelURL)
            }
            let config = MLModelConfiguration()
            config.computeUnits = .all  // ANE/GPU 優先
            let clock = ContinuousClock()
            let start = clock.now
            let mlModel = try MLModel(contentsOf: compiledURL, configuration: config)
            let model = try VNCoreMLModel(for: mlModel)
            Log.info("YOLO model loaded from \(path) in \(clock.now - start)")
            vnModel = model
            return model
        } catch {
            loadError = error
            throw error
        }
    }

    /// .mlpackage はコンパイルが必要。結果を mtime キーでキャッシュし再起動を高速化する。
    private static func compiledURL(for modelURL: URL) throws -> URL {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("simulator-mcp/compiled-models", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let attrs = try FileManager.default.attributesOfItem(atPath: modelURL.path)
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(modelURL.lastPathComponent)-\(Int(mtime)).mlmodelc"
        let cached = cacheDir.appendingPathComponent(key)
        if FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        let compiled = try MLModel.compileModel(at: modelURL)
        try? FileManager.default.removeItem(at: cached)
        try FileManager.default.moveItem(at: compiled, to: cached)
        return cached
    }

    /// 起動直後にバックグラウンドで呼び、初回推論の ANE コンパイル遅延を吸収する。
    func warmUp() async {
        do {
            let model = try loadedModel()
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 640, 640, kCVPixelFormatType_32BGRA, nil, &buffer)
            if let buffer {
                let clock = ContinuousClock()
                let start = clock.now
                _ = try? Self.perform(model: model, input: .pixelBuffer(buffer), minConfidence: 0.99)
                Log.info("YOLO warm-up done in \(clock.now - start)")
            }
        } catch {
            Log.info("YOLO warm-up skipped: \(error)")
        }
    }

    // MARK: - Inference

    func detect(input: ImageInput, minConfidence: Double) async throws -> [Detection] {
        let model = try loadedModel()
        // Vision の同期 perform は GCD 上で実行し cooperative pool を塞がない
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let detections = try Self.perform(
                        model: model, input: input, minConfidence: minConfidence)
                    continuation.resume(returning: detections)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func perform(
        model: VNCoreMLModel, input: ImageInput, minConfidence: Double
    ) throws -> [Detection] {
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill

        let handler: VNImageRequestHandler
        switch input {
        case .pixelBuffer(let buffer):
            handler = VNImageRequestHandler(cvPixelBuffer: buffer)
        case .cgImage(let image):
            handler = VNImageRequestHandler(cgImage: image)
        }
        try handler.perform([request])

        guard let observations = request.results as? [VNRecognizedObjectObservation] else {
            throw YoloError.invalidResults
        }
        let (width, height) = input.pixelSize
        return observations.compactMap { obs -> Detection? in
            guard let top = obs.labels.first, Double(obs.confidence) >= minConfidence else {
                return nil
            }
            // Vision の正規化座標(左下原点)→ ピクセル座標(左上原点)
            let box = obs.boundingBox
            return Detection(
                label: top.identifier,
                confidence: Double(obs.confidence),
                bbox: PixelRect(
                    x: box.origin.x * Double(width),
                    y: (1.0 - box.origin.y - box.height) * Double(height),
                    width: box.width * Double(width),
                    height: box.height * Double(height)
                ))
        }
    }
}

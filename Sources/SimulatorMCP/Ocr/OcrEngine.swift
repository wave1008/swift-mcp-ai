import CoreGraphics
import CoreVideo
import Foundation
@preconcurrency import Vision

struct RecognizedText: Codable, Sendable {
    let text: String
    let confidence: Double
    let bbox: PixelRect
}

struct OcrOptions: Sendable {
    var fast: Bool = false
    var languages: [String] = ["ja-JP", "en-US"]
    var languageCorrection: Bool = false
    /// 対象領域(ピクセル、左上原点)。nil なら全面。
    var roi: PixelRect?
}

/// Vision の VNRecognizeTextRequest によるテキスト+位置抽出。
/// リクエストはステートレスなので複数呼び出しがそのまま並列実行できる。
enum OcrEngine {
    static func recognize(input: ImageInput, options: OcrOptions) async throws -> [RecognizedText] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try perform(input: input, options: options))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 起動直後にバックグラウンドで呼ぶ。Vision の日本語 accurate モデルは
    /// 初回ロードに数十秒かかるため、ここで一度実行して吸収する。
    static func warmUp() async {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard let buffer else { return }
        let clock = ContinuousClock()
        let start = clock.now
        _ = try? await recognize(input: .pixelBuffer(buffer), options: OcrOptions())
        Log.info("OCR warm-up done in \(clock.now - start)")
    }

    private static func perform(input: ImageInput, options: OcrOptions) throws -> [RecognizedText] {
        let request = VNRecognizeTextRequest()
        // .fast はこの環境(macOS 27)の Vision fast パスの不具合
        // (E5 モデルバンドル欠落 → Array index out of range で即クラッシュ)により
        // 使用できないため、常に .accurate で実行する。ウォーム後は 150〜300ms 程度。
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = options.languageCorrection
        // 非対応言語を渡すと Vision 内部でクラッシュする恐れがあるため対応言語に絞る
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        let usable = options.languages.filter(supported.contains)
        request.recognitionLanguages = usable.isEmpty ? ["en-US"] : usable

        let (width, height) = input.pixelSize
        var region = CGRect(x: 0, y: 0, width: 1, height: 1)
        if let roi = options.roi, width > 0, height > 0 {
            // ピクセル座標(左上原点)→ Vision の正規化座標(左下原点)
            region = CGRect(
                x: roi.x / Double(width),
                y: 1.0 - (roi.y + roi.height) / Double(height),
                width: roi.width / Double(width),
                height: roi.height / Double(height)
            ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            request.regionOfInterest = region
        }

        let handler: VNImageRequestHandler
        switch input {
        case .pixelBuffer(let buffer):
            handler = VNImageRequestHandler(cvPixelBuffer: buffer)
        case .cgImage(let image):
            handler = VNImageRequestHandler(cgImage: image)
        }
        try handler.perform([request])

        let observations = request.results ?? []
        return observations.compactMap { obs -> RecognizedText? in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            // ROI 指定時、observation の座標は ROI 相対 → フル画像の正規化座標へ戻す
            var box = obs.boundingBox
            if region != CGRect(x: 0, y: 0, width: 1, height: 1) {
                box = CGRect(
                    x: region.origin.x + box.origin.x * region.width,
                    y: region.origin.y + box.origin.y * region.height,
                    width: box.width * region.width,
                    height: box.height * region.height)
            }
            return RecognizedText(
                text: candidate.string,
                confidence: Double(candidate.confidence),
                bbox: PixelRect(
                    x: box.origin.x * Double(width),
                    y: (1.0 - box.origin.y - box.height) * Double(height),
                    width: box.width * Double(width),
                    height: box.height * Double(height)
                ))
        }
    }
}

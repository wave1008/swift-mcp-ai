import Foundation

/// UI マップの1要素。
/// - icon: YOLO が検出した UI 要素(label は持たない)
/// - text: OCR が認識したテキスト(label に文字列を持つ)
struct UiElement: Codable, Sendable {
    let kind: String
    let label: String?
    let confidence: Double
    let bbox: PixelRect
}

/// YOLO 検出(icon)と OCR テキスト(text)を1つの UI マップに統合する。
/// icon と text はそれぞれ独立した要素として保持し、読み順にソートする。
enum UiMap {
    static func build(
        detections: [Detection], texts: [RecognizedText], imageWidth: Int
    ) -> [UiElement] {
        var elements: [UiElement] = []
        for icon in detections {
            elements.append(UiElement(
                kind: "icon", label: nil,
                confidence: icon.confidence, bbox: icon.bbox))
        }
        for text in texts {
            elements.append(UiElement(
                kind: "text", label: text.text,
                confidence: text.confidence, bbox: text.bbox))
        }
        return elements.sorted { readingOrder($0.bbox, $1.bbox) }
    }

    // MARK: - Geometry helpers

    private static func centerY(_ rect: PixelRect) -> Double {
        rect.y + rect.height / 2
    }

    /// 読み順(上→下、同じ高さ帯なら左→右)
    private static func readingOrder(_ lhs: PixelRect, _ rhs: PixelRect) -> Bool {
        let (lc, rc) = (centerY(lhs), centerY(rhs))
        if abs(lc - rc) > max(lhs.height, rhs.height) / 2 { return lc < rc }
        return lhs.x < rhs.x
    }
}

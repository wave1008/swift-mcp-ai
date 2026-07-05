import Foundation

/// ラベル付き UI マップの1要素。
/// - icon: YOLO が検出した UI 要素。label は位置照合で関連付けた OCR テキスト
/// - text: どの icon にも関連付かなかった OCR テキスト
struct UiElement: Codable, Sendable {
    let kind: String
    let label: String?
    let confidence: Double
    let bbox: PixelRect
}

/// YOLO 検出(icon)と OCR テキストを位置照合して UI マップを組み立てる。
/// 照合規則: (1) icon 内に中心があるテキストの先頭(カード型要素)、
/// (2) 同じ行(垂直中心が icon の高さ内)の右側で最も近いテキスト(リスト行)。
enum UiMap {
    static func build(
        detections: [Detection], texts: [RecognizedText], imageWidth: Int
    ) -> [UiElement] {
        var consumed = [Bool](repeating: false, count: texts.count)
        var elements: [UiElement] = []

        let icons = detections.sorted { readingOrder($0.bbox, $1.bbox) }
        for icon in icons {
            var label: String?
            if let index = containedTextIndex(of: icon.bbox, in: texts, consumed: consumed)
                ?? rowTextIndex(of: icon.bbox, in: texts, consumed: consumed, imageWidth: imageWidth)
            {
                label = texts[index].text
                consumed[index] = true
            }
            elements.append(UiElement(
                kind: "icon", label: label,
                confidence: icon.confidence, bbox: icon.bbox))
        }
        for (index, text) in texts.enumerated() where !consumed[index] {
            elements.append(UiElement(
                kind: "text", label: text.text,
                confidence: text.confidence, bbox: text.bbox))
        }
        return elements.sorted { readingOrder($0.bbox, $1.bbox) }
    }

    /// icon 内に中心があるテキストのうち読み順で最初のもの
    private static func containedTextIndex(
        of icon: PixelRect, in texts: [RecognizedText], consumed: [Bool]
    ) -> Int? {
        texts.indices
            .filter { !consumed[$0] && contains(icon, center(texts[$0].bbox)) }
            .min { readingOrder(texts[$0].bbox, texts[$1].bbox) }
    }

    /// 同じ行の右側にあるテキストのうち水平距離が最小のもの
    private static func rowTextIndex(
        of icon: PixelRect, in texts: [RecognizedText], consumed: [Bool], imageWidth: Int
    ) -> Int? {
        let maxGap = Double(imageWidth) * 0.4
        return texts.indices
            .filter { index in
                guard !consumed[index] else { return false }
                let text = texts[index].bbox
                let sameRow = abs(centerY(text) - centerY(icon)) <= max(icon.height, text.height) / 2
                let gap = text.x - (icon.x + icon.width)
                return sameRow && gap > -icon.width * 0.2 && gap <= maxGap
            }
            .min { lhs, rhs in
                texts[lhs].bbox.x - icon.x < texts[rhs].bbox.x - icon.x
            }
    }

    // MARK: - Geometry helpers

    private static func center(_ rect: PixelRect) -> (x: Double, y: Double) {
        (rect.x + rect.width / 2, rect.y + rect.height / 2)
    }

    private static func centerY(_ rect: PixelRect) -> Double {
        rect.y + rect.height / 2
    }

    private static func contains(_ rect: PixelRect, _ point: (x: Double, y: Double)) -> Bool {
        point.x >= rect.x && point.x <= rect.x + rect.width
            && point.y >= rect.y && point.y <= rect.y + rect.height
    }

    /// 読み順(上→下、同じ高さ帯なら左→右)
    private static func readingOrder(_ lhs: PixelRect, _ rhs: PixelRect) -> Bool {
        let (lc, rc) = (centerY(lhs), centerY(rhs))
        if abs(lc - rc) > max(lhs.height, rhs.height) / 2 { return lc < rc }
        return lhs.x < rhs.x
    }
}

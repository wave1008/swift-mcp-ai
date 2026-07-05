import CoreGraphics
import CoreText
import Foundation

/// ラベル付き UI マップのバウンディングボックスを画像に描画する。
enum UiMapRenderer {
    /// icon 要素の bbox を赤枠(label は赤地白文字のタグ)、
    /// OCR テキストの bbox を緑枠で描く。
    static func draw(
        elements: [UiElement], texts: [RecognizedText] = [], on image: CGImage
    ) throws -> CGImage {
        let width = image.width
        let height = image.height
        guard
            let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw CodecError.encodeFailed("annotate") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let red = CGColor(srgbRed: 1.0, green: 0.176, blue: 0.333, alpha: 1)
        let green = CGColor(srgbRed: 0.157, green: 0.655, blue: 0.271, alpha: 1)
        let lineWidth = max(2.0, Double(width) / 400)
        let fontSize = max(11.0, Double(width) / 45)

        func pixelRectToCG(_ box: PixelRect) -> CGRect {
            // ピクセル座標(左上原点)→ CG 座標(左下原点)
            CGRect(
                x: box.x, y: Double(height) - box.y - box.height,
                width: box.width, height: box.height)
        }

        // OCR テキスト(緑)を先に描き、icon 枠とラベル(赤)を上に重ねる
        context.setLineWidth(max(1.5, lineWidth * 0.7))
        context.setStrokeColor(green)
        for text in texts {
            context.stroke(pixelRectToCG(text.bbox))
        }

        context.setLineWidth(lineWidth)
        context.setStrokeColor(red)
        for element in elements where element.kind == "icon" {
            let rect = pixelRectToCG(element.bbox)
            context.stroke(rect)
            if let label = element.label {
                drawTag(label, above: rect, in: context,
                        color: red, fontSize: fontSize, imageHeight: height)
            }
        }
        guard let result = context.makeImage() else {
            throw CodecError.encodeFailed("annotate")
        }
        return result
    }

    /// 枠の左上に赤文字のラベルを描く(背景なし。上端をはみ出す場合は枠内に落とす)
    private static func drawTag(
        _ text: String, above rect: CGRect, in context: CGContext,
        color: CGColor, fontSize: Double, imageHeight: Int
    ) {
        let font = CTFontCreateWithName("HiraginoSans-W6" as CFString, fontSize, nil)
        let attributes = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color,
        ] as CFDictionary
        guard let attributed = CFAttributedStringCreate(nil, text as CFString, attributes) else {
            return
        }
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, [])

        let padding = fontSize * 0.3
        let tagHeight = bounds.height + padding * 2
        var origin = CGPoint(x: rect.minX, y: rect.maxY)
        if origin.y + tagHeight > Double(imageHeight) {
            origin.y = rect.maxY - tagHeight
        }
        context.textPosition = CGPoint(
            x: origin.x + padding,
            y: origin.y + padding - bounds.origin.y)
        CTLineDraw(line, context)
    }
}

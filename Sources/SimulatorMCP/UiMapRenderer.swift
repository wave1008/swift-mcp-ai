import CoreGraphics
import CoreText
import Foundation

/// ラベル付き UI マップのバウンディングボックスを画像に描画する。
enum UiMapRenderer {
    /// 各要素の bbox を赤枠で描き、label があれば枠の上に赤地白文字で添える。
    static func draw(elements: [UiElement], on image: CGImage) throws -> CGImage {
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
        let lineWidth = max(2.0, Double(width) / 400)
        let fontSize = max(11.0, Double(width) / 45)
        context.setLineWidth(lineWidth)

        for element in elements {
            let box = element.bbox
            // ピクセル座標(左上原点)→ CG 座標(左下原点)
            let rect = CGRect(
                x: box.x, y: Double(height) - box.y - box.height,
                width: box.width, height: box.height)
            context.setStrokeColor(red)
            context.stroke(rect)
            if element.kind == "icon", let label = element.label {
                drawTag(label, above: rect, in: context,
                        background: red, fontSize: fontSize, imageHeight: height)
            }
        }
        guard let result = context.makeImage() else {
            throw CodecError.encodeFailed("annotate")
        }
        return result
    }

    /// 枠の左上に赤地白文字のラベルタグを描く(上端をはみ出す場合は枠内に落とす)
    private static func drawTag(
        _ text: String, above rect: CGRect, in context: CGContext,
        background: CGColor, fontSize: Double, imageHeight: Int
    ) {
        let font = CTFontCreateWithName("HiraginoSans-W6" as CFString, fontSize, nil)
        let attributes = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
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
        let tagRect = CGRect(
            x: origin.x, y: origin.y,
            width: bounds.width + padding * 2, height: tagHeight)
        context.setFillColor(background)
        context.fill(tagRect)
        context.textPosition = CGPoint(
            x: tagRect.minX + padding,
            y: tagRect.minY + padding - bounds.origin.y)
        CTLineDraw(line, context)
    }
}

import CoreGraphics
import Foundation

enum RegionInspectorError: Error, CustomStringConvertible {
    case emptyRegion
    case renderFailed

    var description: String {
        switch self {
        case .emptyRegion: return "指定領域が画像の範囲外です"
        case .renderFailed: return "領域の描画に失敗しました"
        }
    }
}

/// 画像の指定領域の平均色を計算する。スイッチの ON(緑)/OFF(グレー)のような
/// 「テキストにならない状態」を色で判定するための最小プリミティブ。
enum RegionInspector {
    struct Result {
        let hex: String
        let name: String
    }

    /// 中心座標+サイズ(ピクセル)で指定した領域の平均色を返す。
    static func averageColor(
        of image: CGImage, centerX: Double, centerY: Double, width: Double, height: Double
    ) throws -> Result {
        let pixels = try renderRegion(
            of: image, centerX: centerX, centerY: centerY, width: width, height: height)
        var sumR = 0, sumG = 0, sumB = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            sumR += Int(pixels[i])
            sumG += Int(pixels[i + 1])
            sumB += Int(pixels[i + 2])
        }
        let count = max(pixels.count / 4, 1)
        let r = sumR / count
        let g = sumG / count
        let b = sumB / count
        return Result(
            hex: String(format: "#%02X%02X%02X", r, g, b),
            name: Self.colorName(r: r, g: g, b: b))
    }

    /// 領域内の「彩度の高い色クラスタ」を探して代表色を返す。
    ///
    /// スイッチの ON/OFF 判定用: 領域の大半は白背景+白ノブなので単純平均では
    /// 白に埋もれる。彩度の高い画素(ON トラックの緑など)だけを平均することで、
    /// スイッチの正確な位置が分からなくても行ストリップ全体から状態色を拾える。
    /// 彩度の高い画素が閾値未満なら領域は無彩色(OFF のグレー等)とみなし平均色を返す。
    static func dominantAccentColor(
        of image: CGImage, centerX: Double, centerY: Double, width: Double, height: Double
    ) throws -> Result {
        let pixels = try renderRegion(
            of: image, centerX: centerX, centerY: centerY, width: width, height: height)
        var accentR = 0, accentG = 0, accentB = 0, accentCount = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]) / 255
            let g = Double(pixels[i + 1]) / 255
            let b = Double(pixels[i + 2]) / 255
            let maxV = max(r, g, b)
            let saturation = maxV == 0 ? 0 : (maxV - min(r, g, b)) / maxV
            if saturation > 0.3, maxV > 0.3 {
                accentR += Int(pixels[i])
                accentG += Int(pixels[i + 1])
                accentB += Int(pixels[i + 2])
                accentCount += 1
            }
        }
        let total = max(pixels.count / 4, 1)
        // 彩度の高い画素が 1% 以上あれば、その平均を代表色とする
        if accentCount * 100 >= total {
            let r = accentR / accentCount
            let g = accentG / accentCount
            let b = accentB / accentCount
            return Result(
                hex: String(format: "#%02X%02X%02X", r, g, b),
                name: Self.colorName(r: r, g: g, b: b))
        }
        return try averageColor(
            of: image, centerX: centerX, centerY: centerY, width: width, height: height)
    }

    /// 領域を RGBA8 に再描画して画素バッファを返す。
    private static func renderRegion(
        of image: CGImage, centerX: Double, centerY: Double, width: Double, height: Double
    ) throws -> [UInt8] {
        let rect = CGRect(
            x: centerX - width / 2, y: centerY - height / 2, width: width, height: height
        ).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !rect.isEmpty, let cropped = image.cropping(to: rect) else {
            throw RegionInspectorError.emptyRegion
        }
        let w = cropped.width
        let h = cropped.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard
            let context = CGContext(
                data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw RegionInspectorError.renderFailed }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
        return pixels
    }

    /// 平均色をおおまかな色名に分類する(モデルが状態判定に使う)。
    static func colorName(r: Int, g: Int, b: Int) -> String {
        let rf = Double(r) / 255, gf = Double(g) / 255, bf = Double(b) / 255
        let maxV = max(rf, gf, bf)
        let minV = min(rf, gf, bf)
        let delta = maxV - minV
        let saturation = maxV == 0 ? 0 : delta / maxV

        if saturation < 0.12 {
            if maxV > 0.95 { return "white" }
            if maxV < 0.2 { return "black" }
            return "gray"
        }

        var hue: Double
        if delta == 0 {
            hue = 0
        } else if maxV == rf {
            hue = 60 * (((gf - bf) / delta).truncatingRemainder(dividingBy: 6))
        } else if maxV == gf {
            hue = 60 * ((bf - rf) / delta + 2)
        } else {
            hue = 60 * ((rf - gf) / delta + 4)
        }
        if hue < 0 { hue += 360 }

        switch hue {
        case ..<15: return "red"
        case ..<45: return "orange"
        case ..<70: return "yellow"
        case ..<170: return "green"
        case ..<200: return "cyan"
        case ..<255: return "blue"
        case ..<290: return "purple"
        case ..<345: return "pink"
        default: return "red"
        }
    }
}

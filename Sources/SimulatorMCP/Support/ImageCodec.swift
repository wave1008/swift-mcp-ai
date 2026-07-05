import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

/// キャプチャ・解析間で受け渡す画像。CVPixelBuffer / CGImage を
/// エンコードなしでそのまま保持する。
enum ImageInput: @unchecked Sendable {
    case pixelBuffer(CVPixelBuffer)
    case cgImage(CGImage)

    var pixelSize: (width: Int, height: Int) {
        switch self {
        case .pixelBuffer(let buffer):
            return (CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer))
        case .cgImage(let image):
            return (image.width, image.height)
        }
    }

    func makeCGImage() throws -> CGImage {
        switch self {
        case .cgImage(let image):
            return image
        case .pixelBuffer(let buffer):
            var cgImage: CGImage?
            let status = VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &cgImage)
            guard status == noErr, let cgImage else {
                throw CodecError.conversionFailed(status)
            }
            return cgImage
        }
    }
}

enum CodecError: Error, CustomStringConvertible {
    case conversionFailed(OSStatus)
    case encodeFailed(String)
    case loadFailed(String)

    var description: String {
        switch self {
        case .conversionFailed(let status): return "pixel buffer conversion failed (\(status))"
        case .encodeFailed(let format): return "image encode failed (\(format))"
        case .loadFailed(let path): return "cannot load image: \(path)"
        }
    }
}

enum ImageCodec {
    static let outputDirectory: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("simulator-mcp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func load(path: String) throws -> CGImage {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw CodecError.loadFailed(path) }
        return image
    }

    /// メモリ上のデータからデコードする。CGImage のデコードは遅延実行されるため、
    /// 読み込み後すぐ削除されるファイルは URL ではなくこちらを使うこと
    static func decode(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw CodecError.loadFailed("<in-memory data>") }
        return image
    }

    static func downscale(_ image: CGImage, scale: Double) -> CGImage {
        guard scale < 1.0, scale > 0 else { return image }
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        guard
            let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return image }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    static func encode(_ image: CGImage, format: String, quality: Double = 0.85) throws -> Data {
        let type: UTType = format.lowercased() == "jpeg" || format.lowercased() == "jpg"
            ? .jpeg : .png
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, type.identifier as CFString, 1, nil)
        else { throw CodecError.encodeFailed(format) }
        let options: [CFString: Any] = type == .jpeg
            ? [kCGImageDestinationLossyCompressionQuality: quality] : [:]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CodecError.encodeFailed(format)
        }
        return data as Data
    }

    static func writeToTemp(_ data: Data, prefix: String, format: String) throws -> URL {
        let ext = format.lowercased() == "jpeg" || format.lowercased() == "jpg" ? "jpg" : "png"
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let url = outputDirectory.appendingPathComponent("\(prefix)-\(timestamp).\(ext)")
        try data.write(to: url)
        return url
    }
}

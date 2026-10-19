import Accelerate
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

/// A contiguous BGRA8 buffer, allocated once and reused (the same memory layout AVFoundation
/// delivers as kCVPixelFormatType_32BGRA).
public final class BGRABuffer: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public let rowBytes: Int
    public let data: UnsafeMutableRawPointer

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        rowBytes = width * 4
        data = UnsafeMutableRawPointer.allocate(byteCount: rowBytes * height, alignment: 64)
        data.initializeMemory(as: UInt8.self, repeating: 0, count: rowBytes * height)
    }

    deinit {
        data.deallocate()
    }

    /// A view of the pixels that does not keep this buffer alive. Prefer `withVImage`: in
    /// `pipeline.analyze(frame: makeBuffer().vImage)` the temporary can be freed before the call reads it.
    public var vImage: vImage_Buffer {
        vImage_Buffer(data: data, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rowBytes)
    }

    /// The pixels as a vImage buffer, with this buffer kept alive until `body` returns.
    public func withVImage<R>(_ body: (vImage_Buffer) throws -> R) rethrows -> R {
        try withExtendedLifetime(self) { try body(vImage) }
    }

    public var bytes: UnsafeMutablePointer<UInt8> { data.assumingMemoryBound(to: UInt8.self) }

    /// A CGContext drawing straight into this buffer (BGRA = premultipliedFirst, 32-bit little endian).
    public func context() -> CGContext {
        let ctx = CGContext(data: data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: rowBytes,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.interpolationQuality = .high
        return ctx
    }

    public func fill(gray: UInt8) {
        let p = bytes
        for i in 0..<(width * height) {
            p[i * 4] = gray
            p[i * 4 + 1] = gray
            p[i * 4 + 2] = gray
            p[i * 4 + 3] = 255
        }
    }
}

public enum ImageFile {
    public static func load(_ url: URL) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        return img
    }

    /// Aspect-fit render onto a grey canvas, the stored-image camera's frame.
    public static func render(_ img: CGImage, into b: BGRABuffer, gray: UInt8 = 90) {
        b.fill(gray: gray)
        let s = min(Double(b.width) / Double(img.width), Double(b.height) / Double(img.height))
        let w = Double(img.width) * s, h = Double(img.height) * s
        b.context().draw(img, in: CGRect(x: (Double(b.width) - w) / 2, y: (Double(b.height) - h) / 2, width: w, height: h))
    }
}

public enum PixelBuffers {
    /// IOSurface-backed BGRA, so Core ML can read it without a copy.
    public static func makeBGRA(width: Int, height: Int) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs, &pb)
        return pb!
    }

    public static func copy(_ b: BGRABuffer, to pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let dst = CVPixelBufferGetBaseAddress(pb)!, rb = CVPixelBufferGetBytesPerRow(pb)
        for y in 0..<b.height {
            (dst + y * rb).copyMemory(from: b.data + y * b.rowBytes, byteCount: b.width * 4)
        }
    }

    public static func withVImage<R>(_ pb: CVPixelBuffer, _ body: (vImage_Buffer) throws -> R) rethrows -> R {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let v = vImage_Buffer(data: CVPixelBufferGetBaseAddress(pb), height: vImagePixelCount(CVPixelBufferGetHeight(pb)),
                              width: vImagePixelCount(CVPixelBufferGetWidth(pb)), rowBytes: CVPixelBufferGetBytesPerRow(pb))
        return try body(v)
    }
}

/// Mean BT.601 luma of a BGRA buffer, sampling every `step`-th pixel in both directions.
public func meanLuma(_ v: vImage_Buffer, step: Int = 8) -> Double {
    let p = v.data.assumingMemoryBound(to: UInt8.self)
    var sum = 0, n = 0
    for y in stride(from: step / 2, to: Int(v.height), by: step) {
        let row = p + y * v.rowBytes
        for x in stride(from: step / 2, to: Int(v.width), by: step) {
            let px = row + x * 4
            sum += 29 * Int(px[0]) + 150 * Int(px[1]) + 77 * Int(px[2])
            n += 1
        }
    }
    return n > 0 ? Double(sum) / Double(n) / 256 : 0
}

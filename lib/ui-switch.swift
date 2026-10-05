// Inspect one switch in an already captured guest image. No desktop capture.
import Foundation
import CoreGraphics
import ImageIO

func run() throws {
    guard CommandLine.arguments.count == 3,
          let x = Int(CommandLine.arguments[1]), let y = Int(CommandLine.arguments[2]),
          x >= 16, x < 1008, y >= 4, y < 764 else { throw NSError(domain: "coordinates", code: 1) }
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard data.count <= 32 * 1024 * 1024,
          let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          image.width == 1024, image.height == 768 else { throw NSError(domain: "image", code: 1) }
    var bytes = [UInt8](repeating: 0, count: 1024 * 768 * 4)
    let result: String = bytes.withUnsafeMutableBytes { buffer in
        guard let ctx = CGContext(data: buffer.baseAddress, width: 1024, height: 768, bitsPerComponent: 8,
            bytesPerRow: 4096, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return "unknown" }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1024, height: 768))
        let pixels = buffer.bindMemory(to: UInt8.self)
        func brightness(_ px: Int) -> Double {
            var sum = 0.0
            for dy in -2...2 { for dx in -2...2 {
                let offset = ((y + dy) * 1024 + px + dx) * 4
                sum += Double(min(pixels[offset], pixels[offset+1], pixels[offset+2])) / 255
            } }
            return sum / 25
        }
        let left = brightness(x - 9), right = brightness(x + 9)
        if left > 0.94 && left - right > 0.12 { return "off" }
        if right > 0.94 && right - left > 0.12 { return "on" }
        return "unknown"
    }
    print(result)
}
do { try run() } catch { fputs("Cannot inspect guest switch.\n", stderr); exit(1) }

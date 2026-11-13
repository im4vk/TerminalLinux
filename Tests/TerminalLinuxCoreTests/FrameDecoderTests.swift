import Testing
import Foundation
import Compression
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import TerminalLinuxCore

@Suite struct FrameDecoderTests {
    @Test func pngDimensionsAreCheckedBeforeDecode() throws {
        func png(width: Int) throws -> Data {
            let context = try #require(CGContext(data: nil, width: width, height: 1, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let image = try #require(context.makeImage())
            let data = NSMutableData()
            let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
            return data as Data
        }
        #expect(FrameDecoder.image(try png(width: 16)) != nil)
        #expect(FrameDecoder.image(try png(width: 8193)) == nil)
    }
    @Test func validPixelsRoundTripInBothEncodings() throws {
        let data = Data(repeating: 42, count: 16 * 8 * 4)
        let lz4 = try (data as NSData).compressed(using: .lz4) as Data
        #expect(try FrameDecoder.pixels(lz4, width: 16, height: 8, bytesPerRow: 64, algorithm: .lz4) == data)
        let deflate = try (data as NSData).compressed(using: .zlib) as Data
        #expect(try FrameDecoder.pixels(deflate, width: 16, height: 8, bytesPerRow: 64) == data)
        #expect(FrameDecoder.algorithm(for: "bgra-deflate") == .zlib)
        #expect(FrameDecoder.algorithm(for: "bgra-lz4") == .lz4)
        #expect(FrameDecoder.algorithm(for: "png") == nil)
    }
    @Test(arguments: [Algorithm.lz4, .zlib])
    func expansionBeyondDeclaredSizeIsRejected(algorithm: Algorithm) throws {
        let compressed = try (Data(repeating: 0, count: 1024 * 1024) as NSData).compressed(using: algorithm == .lz4 ? .lz4 : .zlib) as Data
        #expect(throws: (any Error).self) { try FrameDecoder.pixels(compressed, width: 1, height: 1, bytesPerRow: 4, algorithm: algorithm) }
    }
    @Test func invalidDimensionsAndTruncatedFrameAreRejected() throws {
        let compressed = try (Data(repeating: 0, count: 4) as NSData).compressed(using: .zlib) as Data
        for width in [0, -1, 8193, Int.max] {
            #expect(throws: (any Error).self) { try FrameDecoder.pixels(compressed, width: width, height: 1, bytesPerRow: 4) }
        }
        #expect(throws: (any Error).self) { try FrameDecoder.pixels(compressed, width: 2, height: 1, bytesPerRow: 8) }
        #expect(throws: (any Error).self) { try FrameDecoder.pixels(compressed, width: 8192, height: 8192, bytesPerRow: 33792) }
        #expect(FrameDecoder.image(Data("invalid image".utf8)) == nil)
    }
}

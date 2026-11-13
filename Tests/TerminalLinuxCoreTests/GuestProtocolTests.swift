import Testing
import Foundation
import Compression
@testable import TerminalLinuxCore

/// The Swift host and the Python guest helper must agree on the mailbox wire format. These tests run the
/// helper's real Mailbox and encoders (Tests/guest/mailbox_peer.py) against the Swift Mailbox.
@Suite struct GuestProtocolTests {
    private let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func startPeer(_ exchange: URL, requests: Int) throws -> Process {
        let peer = Process()
        peer.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        peer.arguments = ["python3", "-I", repository.appendingPathComponent("Tests/guest/mailbox_peer.py").path, exchange.path, String(requests)]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        peer.environment = environment
        try peer.run()
        return peer
    }
    /// A private root holding a shared exchange, laid out like a VM bundle.
    private func exchange() throws -> (root: URL, exchange: URL) {
        let root = try temporary()
        guard chmod(root.path, 0o700) == 0 else { throw Failure("chmod") }
        let exchange = root.appendingPathComponent("exchange")
        _ = try Mailbox(exchange, create: true, shared: true)
        return (root, exchange)
    }

    @Test func pythonHelperAnswersSwiftRequests() async throws {
        let (root, exchange) = try exchange(); defer { remove(root) }
        let peer = try startPeer(exchange, requests: 2)
        defer { if peer.isRunning { peer.terminate() } }
        let mailbox = try Mailbox(exchange)
        let reply = try await mailbox.call(Request(action: "echo", arguments: ["text": "héllo 🌍", "x": "640"], timeout: 8))
        #expect(reply.values == ["text": "héllo 🌍", "x": "640"])
        do {
            _ = try await mailbox.call(Request(action: "unknown", timeout: 8))
            Issue.record("Expected the helper's error reply")
        } catch {
            #expect(error.localizedDescription == "unknown action unknown")
        }
        peer.waitUntilExit()
        #expect(peer.terminationStatus == 0)
        // Requests and replies are cleaned up; the helper left no temporary files behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: exchange.path) == [])
    }

    @Test func pythonFramesDecodeOnTheHost() async throws {
        let (root, exchange) = try exchange(); defer { remove(root) }
        let peer = try startPeer(exchange, requests: 1)
        defer { if peer.isRunning { peer.terminate() } }
        let mailbox = try Mailbox(exchange)
        let request = Request(action: "frame", timeout: 8)
        let reply = try await mailbox.call(request)
        let width = try #require(Int(reply.values["width"] ?? "")), height = try #require(Int(reply.values["height"] ?? ""))
        let stride = try #require(Int(reply.values["bytesPerRow"] ?? ""))
        let deflated = try #require(try mailbox.read("image-\(request.id.uuidString).bin"))
        let pixels = try FrameDecoder.pixels(deflated, width: width, height: height, bytesPerRow: stride, algorithm: .zlib)
        // Pixel (x: 3, y: 2) is BGRX (24, 32, 200, 255) in the peer's test frame.
        let offset = 2 * stride + 3 * 4
        #expect(Array(pixels[offset..<offset + 4]) == [24, 32, 200, 255])
        let png = try #require(try mailbox.read("image-\(request.id.uuidString).png"))
        let image = try #require(FrameDecoder.image(png))
        #expect(image.width == 16 && image.height == 8)
        peer.waitUntilExit()
        #expect(peer.terminationStatus == 0)
    }
}

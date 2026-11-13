import Testing
import Foundation
import Darwin
@testable import TerminalLinuxCore

/// A fresh directory; callers remove it with `defer { remove(root) }`.
func temporary() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-linux-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }

@Suite struct SetupTests {
    @Test func setupPlanFollowsInstallationState() {
        let installed = Machine(name: "work", cpu: 4, memoryGiB: 4, diskGiB: 32, installed: true)
        #expect(SetupPlan(name: "work", machine: installed, hasInstaller: false).steps ==
                ["start-or-resume-vm", "check-guest-helper", "open-terminal-view-if-supported"])
        #expect(Array(SetupPlan(name: "work", machine: nil, hasInstaller: true).steps.prefix(2)) == ["create-vm-with-installer-iso", "install-linux-in-vm-window"])
        #expect(SetupPlan(name: "work", machine: nil, hasInstaller: false).steps.first == "missing-installer-iso")
        var partial = installed; partial.installed = false
        #expect(SetupPlan(name: "work", machine: partial, hasInstaller: false).steps.first == "install-linux-in-vm-window")
    }
    @Test func guestReadinessRequiresCaptureAndInput() {
        #expect(GuestReadiness(nil) == .unavailable)
        #expect(GuestReadiness([:]) == .permissions)
        #expect(GuestReadiness(["capture": "true", "input": "false"]) == .permissions)
        #expect(GuestReadiness(["capture": "false", "input": "true", "problem": "Wayland"]) == .permissions)
        #expect(GuestReadiness(["capture": "true", "input": "true"]) == .ready)
        #expect(helperRunsFromLiveMedia(["live": "true"]))
        #expect(!helperRunsFromLiveMedia(["live": "false"]))
        #expect(!helperRunsFromLiveMedia(nil))
    }
    @Test func machineRecordsInstallerAndDecodesWithoutOne() throws {
        let machine = Machine(name: "work", cpu: 2, memoryGiB: 4, diskGiB: 32, installer: "/tmp/debian.iso")
        let decoded = try JSONDecoder().decode(Machine.self, from: JSONEncoder().encode(machine))
        #expect(decoded.installer == "/tmp/debian.iso")
        #expect(!decoded.installed)
        let minimal = #"{"name":"a","cpu":2,"memoryGiB":4,"diskGiB":32,"width":1280,"height":800,"network":false,"installed":true}"#
        let old = try JSONDecoder().decode(Machine.self, from: Data(minimal.utf8))
        #expect(old.installer == nil)
        #expect(old.networkDescription == "offline")
    }
    @Test func setupLockPreventsConcurrentInstallAndReleases() throws {
        let root = try temporary(); defer { remove(root) }
        let path = root.appendingPathComponent("setup.lock")
        var first: FileLock? = try FileLock(path)
        withExtendedLifetime(first) { _ = #expect(throws: (any Error).self) { try FileLock(path) } }
        first = nil
        #expect(throws: Never.self) { try FileLock(path) }
    }
    @Test func setupLockRejectsSymlink() throws {
        let root = try temporary(); defer { remove(root) }
        let target = root.appendingPathComponent("target")
        try Data().write(to: target)
        let link = root.appendingPathComponent("setup.lock")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: (any Error).self) { try FileLock(link) }
    }
    @Test func machineNamesCannotEscapeStore() {
        for name in ["../host", "/tmp", "", ".", "a/b", "a b", String(repeating: "x", count: 49)] {
            #expect(throws: (any Error).self) { try validateName(name) }
        }
        for name in ["default", "agent-1", "linux_test", "D13"] { #expect(throws: Never.self) { try validateName(name) } }
    }
    @Test func parserRejectsUnknownDuplicateAndMissingOptions() throws {
        #expect(throws: (any Error).self) { try Arguments(["--force"], flags: ["offline"]) }
        #expect(throws: (any Error).self) { try Arguments(["--disk"], options: ["disk"]) }
        #expect(throws: (any Error).self) { try Arguments(["--disk", "4", "--disk", "8"], options: ["disk"]) }
        #expect(throws: (any Error).self) { try Arguments(["--disk", "0"], options: ["disk"]).integer("disk", default: 32, range: 16...1024) }
        #expect(try Arguments(["--", "--literal"]).positionals == ["--literal"])
    }
}

@Suite struct MailboxTests {
    @Test func sharedMailboxGivesTheGuestReadableFilesAndPrivateOneDoesNot() throws {
        let root = try temporary(); defer { remove(root) }
        let shared = root.appendingPathComponent("exchange"), privateBox = root.appendingPathComponent("host-control")
        _ = try Mailbox(shared, create: true, shared: true)
        _ = try Mailbox(privateBox, create: true)
        func mode(_ url: URL) throws -> Int { (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue }
        #expect(try mode(shared) == 0o777)
        #expect(try mode(privateBox) == 0o700)
        // A later, non-creating open (the viewer, the CLI) must keep writing guest-readable files.
        try Mailbox(shared).write(Data("x".utf8), named: "request-a.json")
        try Mailbox(privateBox).write(Data("x".utf8), named: "request-a.json")
        #expect(try mode(shared.appendingPathComponent("request-a.json")) == 0o666)
        #expect(try mode(privateBox.appendingPathComponent("request-a.json")) == 0o600)
    }
    @Test func rejectsTraversalSymlinksHardlinksAndOversizedFiles() throws {
        let root = try temporary(); defer { remove(root) }
        let mailbox = try Mailbox(root)
        let secret = root.appendingPathComponent("secret")
        try Data("host file".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: secret.path)
        #expect(throws: (any Error).self) { try mailbox.read("link") }
        #expect(throws: (any Error).self) { try mailbox.read("../secret") }
        #expect(throws: (any Error).self) { try mailbox.write(Data(), named: "../escape") }
        #expect(throws: (any Error).self) { try mailbox.read("secret", limit: 1) }
        #expect(link(secret.path, root.appendingPathComponent("hardlink").path) == 0)
        #expect(throws: (any Error).self) { try mailbox.read("hardlink") }
    }
    @Test func publishingReplacesSymlinkInsteadOfWritingItsTarget() throws {
        let root = try temporary(); defer { remove(root) }
        let mailbox = try Mailbox(root)
        let target = root.appendingPathComponent("target")
        try Data("untouched".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("reply.json").path, withDestinationPath: target.path)
        try mailbox.write(Data("reply".utf8), named: "reply.json")
        #expect(try Data(contentsOf: target) == Data("untouched".utf8))
        #expect(try mailbox.read("reply.json") == Data("reply".utf8))
    }
    @Test func rejectsDirectorySymlinkAndNonregularFile() throws {
        let parent = try temporary(); defer { remove(parent) }
        let actual = parent.appendingPathComponent("actual")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        let alias = parent.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        #expect(throws: (any Error).self) { try Mailbox(alias) }
        let mailbox = try Mailbox(actual)
        #expect(mkfifo(actual.appendingPathComponent("pipe").path, 0o600) == 0)
        #expect(throws: (any Error).self) { try mailbox.read("pipe") }
    }
    @Test func expiredAndMismatchedRequestsAreDiscarded() throws {
        let root = try temporary(); defer { remove(root) }
        let mailbox = try Mailbox(root)
        let expired = Request(action: "click", timeout: -1)
        try mailbox.write(JSONEncoder().encode(expired), named: "request-\(expired.id.uuidString).json")
        let valid = Request(action: "status")
        try mailbox.write(JSONEncoder().encode(valid), named: "request-\(UUID().uuidString).json")
        #expect(try mailbox.requests().isEmpty)
    }
    @Test func requestReplyRoundTripAndCleanup() async throws {
        let root = try temporary(); defer { remove(root) }
        let client = try Mailbox(root)
        let server = try Mailbox(root)
        let request = Request(action: "type", arguments: ["text": "hello 🌍"], timeout: 2)
        let task = Task { try await client.call(request) }
        var received: Request?
        for _ in 0..<50 {
            received = try server.requests().first
            if received != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(received?.arguments["text"] == "hello 🌍")
        try server.respond(Reply(id: request.id, values: ["done": "true"]))
        let reply = try await task.value
        #expect(reply.values["done"] == "true")
        #expect(try client.read("request-\(request.id.uuidString).json") == nil)
        #expect(try client.read("reply-\(request.id.uuidString).json") == nil)
    }
    @Test func timeoutCleansPendingAction() async throws {
        let root = try temporary(); defer { remove(root) }
        let mailbox = try Mailbox(root)
        let request = Request(action: "click", timeout: 0.05)
        await #expect(throws: MailboxTimeout.self) { try await mailbox.call(request) }
        #expect(try mailbox.read("request-\(request.id.uuidString).json") == nil)
    }
}

@Suite struct TerminalInputTests {
    @Test func handlesFragmentedUnicodeArrowsMouseAndExit() {
        var parser = TerminalInput()
        let emoji = Array("🌍".utf8)
        #expect(parser.feed(Array(emoji.prefix(2))) == [])
        #expect(parser.feed(Array(emoji.dropFirst(2))) == [.text("🌍")])
        #expect(parser.feed([27, 91]) == [])
        #expect(parser.feed([65]) == [.key("up")])
        #expect(parser.feed(Array("\u{1b}[<0;12;8M".utf8)) == [.mouse(button: 0, column: 12, row: 8, released: false)])
        #expect(parser.feed(Array("\u{1b}[<0;12;8m".utf8)) == [.mouse(button: 0, column: 12, row: 8, released: true)])
        #expect(parser.feed([3, 29]) == [.key("ctrl+c"), .quit])
    }
    @Test func escapeAndUnknownSequencesDoNotBecomeGuestText() {
        var parser = TerminalInput()
        #expect(parser.feed([27]) == [])
        #expect(parser.feed([], flushEscape: true) == [.key("escape")])
        #expect(parser.feed(Array("\u{1b}[99~".utf8)) == [])
        #expect(parser.feed(Array("\u{1b}[<0;0;0M".utf8)) == [])
        #expect(parser.feed([255, 65]) == [.text("A")])
    }
}

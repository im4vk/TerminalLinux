import AppKit
import TerminalLinuxCore
import Darwin

@main
struct Entry {
    @MainActor static func main() {
        let command = CommandLine.arguments.dropFirst().first
        // The background VM process needs an AppKit event loop for its window; it also leaves the user's session group.
        let runsVM = command == "__run"
        if runsVM { _ = setsid(); NSApplication.shared.setActivationPolicy(.accessory) }
        let cli = CLI()
        Task { @MainActor in
            do { try await cli.run(Array(CommandLine.arguments.dropFirst())); exit(0) }
            catch { stderr("terminal-linux: \(error.localizedDescription)"); exit(1) }
        }
        if runsVM { NSApplication.shared.run() } else { CFRunLoopRun() }
    }
}

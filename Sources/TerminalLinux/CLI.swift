import AppKit
import Virtualization
import TerminalLinuxCore
import Darwin

@MainActor
final class CLI {
    let store = Store()
    var runtime: MachineRuntime?
    var executableURL: URL {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .standardizedFileURL.resolvingSymlinksInPath()
    }
    /// The guest helper and its installer, shared read-only with every VM.
    var toolsURL: URL {
        executableURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/guest-tools")
    }
    var toolsBundled: Bool { FileManager.default.fileExists(atPath: toolsURL.appendingPathComponent("terminal_linux_helper.py").path) }

    func run(_ input: [String], quietStartup: Bool = false) async throws {
        let command = input.first ?? (isatty(STDIN_FILENO) == 1 ? "up" : "help")
        let tail = Array(input.dropFirst())
        switch command {
        case "help", "--help", "-h": print(Self.help)
        case "--version", "version": print("terminal-linux \(appVersion)")
        case "up", "setup": try await up(tail)
        case "doctor":
            _ = try Arguments(tail)
            try printJSON(["architecture": "arm64", "virtualizationSupported": String(VZVirtualMachine.isSupported),
                           "macOS": ProcessInfo.processInfo.operatingSystemVersionString, "dataDirectory": store.root.path,
                           "guestToolsBundled": String(toolsBundled)])
        case "create":
            let args = try Arguments(tail, flags: ["offline"], options: ["iso", "cpus", "memory", "disk", "width", "height"])
            let machine = try VirtualMachines.create(args, store: store)
            try printJSON(["name": machine.name, "state": "created", "next": "terminal-linux up \(machine.name)"])
        case "ls", "list":
            _ = try Arguments(tail)
            let directory = store.root.appendingPathComponent("machines")
            let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            let machines = urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { try? store.load($0.lastPathComponent) }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(machines), as: UTF8.self))
        case "start":
            let args = try Arguments(tail, flags: ["window"])
            let name = try args.machineName()
            _ = try store.load(name)
            let directory = try store.directory(name)
            if runtimeIsLocked(directory) {
                if args.flags.contains("window") { _ = try await host(name, action: "show") }
                if !quietStartup { try printJSON(["name": name, "state": "already-running"]) }; return
            }
            guard toolsBundled else { throw Failure("Guest tools are missing. Run scripts/build.sh and use dist/terminal-linux.") }
            let log = directory.appendingPathComponent("runtime.log")
            if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            let logHandle = try FileHandle(forWritingTo: log)
            try logHandle.seekToEnd()
            defer { try? logHandle.close() }
            let process = Process()
            process.executableURL = executableURL
            process.arguments = ["__run", name] + (args.flags.contains("window") ? ["--window"] : [])
            var environment = ProcessInfo.processInfo.environment; environment["TERMINAL_LINUX_HOME"] = store.root.path
            process.environment = environment
            process.standardOutput = logHandle; process.standardError = logHandle; process.standardInput = FileHandle.nullDevice
            try process.run()
            _ = try Mailbox(directory.appendingPathComponent("host-control"), create: true)
            do {
                let reply = try await host(name, action: "status", timeout: 30)
                if !quietStartup { try printJSON(reply.values) }
            } catch {
                throw Failure("VM did not become ready: \(error.localizedDescription). Details: \(log.path)")
            }
        case "__run":
            let args = try Arguments(tail, flags: ["window"])
            let name = try args.machineName()
            let machine = try store.load(name)
            runtime = try MachineRuntime(machine: machine, directory: store.directory(name), tools: toolsURL)
            try await runtime!.start(show: args.flags.contains("window"))
            while true { try await Task.sleep(nanoseconds: 1_000_000_000) }
        case "status", "show", "hide", "pause", "resume", "stop":
            let args = try Arguments(tail, flags: command == "stop" ? ["force"] : [])
            let name = try args.machineName()
            _ = try store.load(name)
            if !runtimeIsLocked(try store.directory(name)) {
                // Nothing would answer the lifecycle mailbox; say so instead of waiting for a timeout.
                guard command == "status" || command == "stop" else { throw Failure("VM '\(name)' is stopped. Start it with: terminal-linux start \(name)") }
                try printJSON(["name": name, "state": "stopped"]); return
            }
            let reply = try await host(name, action: command, arguments: ["force": String(args.flags.contains("force"))])
            try printJSON(reply.values)
        case "eject":
            // Detaches the installer ISO for good. `up` does this by itself once the helper answers from the installed system.
            let args = try Arguments(tail)
            let name = try args.machineName()
            var machine = try store.load(name)
            guard !runtimeIsLocked(try store.directory(name)) else { throw Failure("Stop the VM first: terminal-linux stop \(name). The ISO is detached at the next boot.") }
            machine.installed = true
            try store.save(machine)
            try printJSON(["name": name, "installer": "detached"])
        case "network":
            let args = try Arguments(tail, flags: ["nat", "offline"])
            let name = try args.machineName()
            var machine = try store.load(name)
            guard args.flags.count == 1 else { throw Failure("Usage: terminal-linux network [NAME] --nat|--offline") }
            guard !runtimeIsLocked(try store.directory(name)) else { throw Failure("Stop the VM first: terminal-linux stop \(name). The network mode applies at the next boot.") }
            machine.network = args.flags.contains("nat")
            try store.save(machine)
            try printJSON(["name": name, "network": machine.networkDescription])
        case "guest-setup":
            _ = try Arguments(tail)
            print(Self.guestSetup)
        case "action": try await action(tail)
        case "mcp":
            let args = try Arguments(tail, flags: ["config"])
            let name = try args.machineName()
            if args.flags.contains("config") {
                let server: [String: Any] = ["command": launcherPath, "args": name == "default" ? ["mcp"] : ["mcp", name]]
                let data = try JSONSerialization.data(withJSONObject: ["mcpServers": ["terminal-linux": server]], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                print(String(decoding: data, as: UTF8.self)); return
            }
            try await AgentServer(store: store, name: name).run()
        case "skills":
            let args = try Arguments(tail, options: ["dir"])
            guard let skill = bundledSkill else { throw Failure("This build has no bundled skill. Rebuild with scripts/build.sh.") }
            switch args.positionals {
            case ["get"], []: print(try String(contentsOf: skill, encoding: .utf8), terminator: "")
            case ["path"]: print(skill.path)
            case ["install"]:
                let root = args.options["dir"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills")
                let destination = root.appendingPathComponent("terminal-linux/SKILL.md")
                if let existing = try? String(contentsOf: destination, encoding: .utf8), !existing.contains("\nname: terminal-linux\n") {
                    throw Failure("Refusing to replace a different skill at \(destination.path)")
                }
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(contentsOf: skill).write(to: destination, options: .atomic)
                try printJSON(["installed": destination.path])
            default: throw Failure("Usage: terminal-linux skills [get|path|install [--dir ~/.claude/skills]]")
            }
        case "view":
            let args = try Arguments(tail, flags: ["read-only"], options: ["protocol"])
            let name = try args.machineName()
            let machine = try store.load(name)
            guard runtimeIsLocked(try store.directory(name)) else { throw Failure("VM '\(name)' is stopped. Start it with: terminal-linux start \(name)") }
            let viewer = try TerminalViewer(directory: store.directory(name), machine: machine, graphics: args.options["protocol"], readOnly: args.flags.contains("read-only"))
            try await viewer.run()
        default: throw Failure("Unknown command: \(command). Run terminal-linux help.")
        }
    }
    /// Lifecycle requests go to the background VM process, never to the guest.
    func host(_ name: String, action: String, arguments: [String: String] = [:], timeout: Double = 5) async throws -> Reply {
        let directory = try store.directory(name)
        do {
            return try await Mailbox(directory.appendingPathComponent("host-control")).call(Request(action: action, arguments: arguments, timeout: timeout))
        } catch is MailboxTimeout {
            if !Self.isRunning(directory) { throw Failure("VM '\(name)' stopped before it could \(action). Details: \(directory.appendingPathComponent("runtime.log").path)") }
            throw Failure("The VM process did not answer '\(action)'. Details: \(directory.appendingPathComponent("runtime.log").path)")
        }
    }
    func action(_ input: [String]) async throws {
        let args = try Arguments(input, flags: ["double"], options: ["x", "y", "x2", "y2", "dx", "dy", "text", "key", "button", "count", "output", "timeout"])
        let actions: Set<String> = ["status", "screenshot", "snapshot", "click", "move", "drag", "scroll", "type", "key"]
        var positions = args.positionals
        let name: String
        if let first = positions.first, actions.contains(first) { name = "default" }
        else { guard !positions.isEmpty else { throw Failure("Usage: terminal-linux action [NAME] screenshot|click|type|key|scroll|status") }; name = positions.removeFirst() }
        try validateName(name)
        _ = try store.load(name)
        guard !positions.isEmpty, actions.contains(positions[0]) else { throw Failure("Unknown or missing guest action") }
        let verb = positions.removeFirst()
        var parameters = args.options
        parameters.removeValue(forKey: "output"); parameters.removeValue(forKey: "timeout")
        if verb == "type", !positions.isEmpty { parameters["text"] = positions.joined(separator: " "); positions.removeAll() }
        if verb == "key", positions.count == 1 { parameters["key"] = positions.removeFirst() }
        if ["click", "move"].contains(verb), positions.count == 2 { parameters["x"] = positions.removeFirst(); parameters["y"] = positions.removeFirst() }
        if verb == "drag", positions.count == 4 {
            for key in ["x", "y", "x2", "y2"] { parameters[key] = positions.removeFirst() }
        }
        guard positions.isEmpty else { throw Failure("Unexpected action arguments") }
        if args.flags.contains("double") { parameters["double"] = "true" }
        let timeout = try args.integer("timeout", default: 15, range: 1...120)
        guard runtimeIsLocked(try store.directory(name)) else { throw Failure("VM '\(name)' is stopped. Start it with: terminal-linux start \(name)") }
        let mailbox = try Mailbox(store.directory(name).appendingPathComponent("exchange"))
        let request = Request(action: verb, arguments: parameters, timeout: Double(timeout))
        let imageName = "image-\(request.id.uuidString).png"
        defer { mailbox.remove(imageName) }
        let reply: Reply
        do { reply = try await mailbox.call(request) }
        catch let failure as MailboxTimeout {
            // Whether the request file was taken tells a missing helper apart from a busy one.
            throw Failure(failure.pickedUp
                ? "The guest helper received '\(verb)' but did not answer within \(timeout) s. Inside the VM, see ~/.local/state/terminal-linux/helper.log."
                : """
                  No guest helper is reading the mailbox, so '\(verb)' was not delivered. Either:
                    • the guest is still booting or at its login screen: log in (terminal-linux show \(name)), or
                    • the helper is not set up yet: inside the VM, run the commands from 'terminal-linux guest-setup', or
                    • the share is not mounted after a reboot: inside the VM, sudo mount -t virtiofs terminal-linux /mnt/terminal-linux
                  """)
        }
        var values = reply.values
        if verb == "screenshot" || verb == "snapshot" {
            guard values["image"] == imageName, let png = try mailbox.read(imageName, limit: 64 * 1024 * 1024),
                  FrameDecoder.image(png) != nil else { throw Failure("Invalid guest image response") }
            let output = URL(fileURLWithPath: ((args.options["output"] ?? "terminal-linux-\(name).png") as NSString).expandingTildeInPath)
            try png.write(to: output, options: .atomic)
            values["image"] = output.path
        }
        try printJSON(values)
    }
    var bundledSkill: URL? {
        let bundled = executableURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/skills/terminal-linux/SKILL.md")
        if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        var directory = executableURL.deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent("skills/terminal-linux/SKILL.md")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        return nil
    }
    var launcherPath: String {
        let invoked = CommandLine.arguments[0]
        if invoked.contains("/") { return URL(fileURLWithPath: invoked).standardizedFileURL.path }
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = "\(directory)/\(invoked)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return executableURL.path
    }
    func runtimeIsLocked(_ directory: URL) -> Bool { Self.isRunning(directory) }
    static func isRunning(_ directory: URL) -> Bool {
        let fd = open(directory.appendingPathComponent("runtime.lock").path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { flock(fd, LOCK_UN); return false }
        return true
    }

    /// Typed by the user in a terminal inside the guest, once, after installing Linux.
    static let guestSetup = """
    In the Linux VM, open a terminal and run:

      sudo mkdir -p /mnt/terminal-linux
      sudo mount -t virtiofs terminal-linux /mnt/terminal-linux
      bash /mnt/terminal-linux/tools/install.sh

    If sudo says you are not in the sudoers file (Debian with a root password),
    use the root password instead for the first two lines:

      su -c 'mkdir -p /mnt/terminal-linux && mount -t virtiofs terminal-linux /mnt/terminal-linux'

    install.sh checks the session (it must be X11, not Wayland), asks before each
    system change, installs the helper for your user only and starts it.
    """

    static let help = """
    terminal-linux — a separate Linux desktop for computer-use agents

    up [NAME] --iso PATH        First run: create a VM from an ARM64 installer ISO and open it
    up [NAME]                   Later runs: boot, wait for the guest helper, open the desktop
      [--no-view | --detach]    Wait for readiness without viewing, or just boot
      [--plan] [--timeout 3600] Preview steps without changes; setup wait in seconds
      [--cpus 4 --memory 4 --disk 32 --width 1280 --height 800 --offline]

    create [NAME] --iso PATH    Prepare a VM without booting it (same sizing options)
    start [NAME] [--window]     Boot in the background; show the VM window if requested
    view [NAME] [--read-only]   Live terminal desktop (Ghostty, Kitty, iTerm2)
      [--protocol kitty|iterm]  Ctrl+G opens Linux shortcuts; Ctrl+] exits
    show|hide [NAME]            Show or hide the native VM window
    status|pause|resume [NAME]  Manage the VM
    stop [NAME] [--force]       Press the guest's power button (or immediately power off)
    eject [NAME]                Detach the installer ISO (stopped VM)
    network [NAME] --nat|--offline
    guest-setup                 Print the commands that install the helper inside the guest
    ls                          List VMs as JSON
    doctor                      Check host support and bundled guest tools

    action [NAME] status
    action [NAME] screenshot [--output PATH]
    action [NAME] click X Y [--button right] [--double]
    action [NAME] move X Y
    action [NAME] drag X Y X2 Y2
    action [NAME] type 'text'
    action [NAME] key ctrl+alt+t | super | alt+tab | return
    action [NAME] scroll --dy -300 [--dx 0 --x 640 --y 400]

    mcp [NAME]                  MCP server (stdio) with computer-use tools for agents:
                                claude mcp add terminal-linux -- terminal-linux mcp
      [--config]                Print an mcpServers entry for other MCP clients
    skills get|path|install     The agent skill for this version

    Actions need the guest helper running in the guest's logged-in X11 session.
    Nothing is downloaded by this tool: you provide the installer ISO.
    TERMINAL_LINUX_HOME overrides the host data directory.
    """
}

let appBundle: Bundle = {
    let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).standardizedFileURL.resolvingSymlinksInPath()
    return Bundle(url: executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) ?? Bundle.main
}()
var appVersion: String { appBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }

func printJSON(_ value: [String: String]) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

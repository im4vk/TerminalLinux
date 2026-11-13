import AppKit
import Virtualization
import TerminalLinuxCore

extension CLI {
    /// create (first run) → start → wait for the guest helper → view.
    /// Installing Linux and the helper happen in the VM window; this flow guides and waits, it never downloads anything.
    func up(_ input: [String]) async throws {
        let args = try Arguments(input, flags: ["plan", "no-view", "detach", "offline"], options: ["iso", "cpus", "memory", "disk", "width", "height", "timeout", "protocol"])
        let name = try args.machineName()
        let directory = try store.directory(name)
        let exists = FileManager.default.fileExists(atPath: directory.appendingPathComponent("machine.json").path)
        let existing = exists ? try store.load(name) : nil
        if args.flags.contains("plan") {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(SetupPlan(name: name, machine: existing, hasInstaller: args.options["iso"] != nil)), as: UTF8.self)); return
        }
        guard VZVirtualMachine.isSupported else { throw Failure("This Mac cannot run virtual machines. Use Apple silicon and the signed build in dist/.") }
        guard toolsBundled else { throw Failure("Guest tools are missing from this build. Run scripts/build.sh.") }
        if let graphics = args.options["protocol"], !["kitty", "iterm"].contains(graphics) { throw Failure("--protocol must be kitty or iterm") }
        let timeout = try args.integer("timeout", default: 3600, range: 1...14400)
        let sizing: Set<String> = ["iso", "cpus", "memory", "disk", "width", "height"]

        // Refuse before touching the disk, so a mistyped command leaves nothing behind.
        if existing == nil && args.options["iso"] == nil {
            throw Failure("""
            No VM named '\(name)' yet. Give it an ARM64 (aarch64) installer ISO:
              terminal-linux up \(name) --iso ~/Downloads/<distro>-arm64.iso
            Recommended: Debian 13 arm64 with the Xfce desktop, or Ubuntu 24.04 LTS desktop arm64 (choose "Ubuntu on Xorg" at login).
            """)
        }
        if existing != nil && (!Set(args.options.keys).intersection(sizing).isEmpty || args.flags.contains("offline")) {
            throw Failure("VM '\(name)' already exists. Creation options only apply to a new VM; run terminal-linux up \(name) without them.")
        }

        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var setupLock: FileLock? = try FileLock(store.root.appendingPathComponent("setup-\(name).lock"))
        defer { withExtendedLifetime(setupLock) {} }

        if existing == nil {
            var createInput = [name]
            for key in sizing { if let value = args.options[key] { createInput += ["--\(key)", value] } }
            if args.flags.contains("offline") { createInput.append("--offline") }
            _ = try VirtualMachines.create(Arguments(createInput, flags: ["offline"], options: sizing), store: store)
        }

        try await run(["start", name], quietStartup: true)
        let lifecycle = try await host(name, action: "status", timeout: 30)
        if lifecycle.values["state"] == "paused" { _ = try await host(name, action: "resume") }
        setupLock = nil
        if args.flags.contains("detach") {
            try printJSON(["name": name, "state": "started", "setup": "not-checked"]); return
        }

        let mailbox = try Mailbox(directory.appendingPathComponent("exchange"))
        func probe() async -> [String: String]? { try? await mailbox.call(Request(action: "status", timeout: 2)).values }
        var values = await probe()
        var readiness = GuestReadiness(values)
        let inline = !args.flags.contains("no-view") && (TerminalViewer.supportsCurrentTerminal || args.options["protocol"] != nil)

        // A guest that was ready before is normally just booting or at its login screen: the viewer handles that itself.
        if readiness != .ready, inline, FileManager.default.fileExists(atPath: TerminalViewer.readyMarker(directory).path) {
            try await TerminalViewer(directory: directory, machine: store.load(name), graphics: args.options["protocol"], readOnly: false).run()
            return
        }
        var showedWindow = false
        if readiness != .ready {
            // The VM may already have powered off (nothing bootable); the wait loop below explains that case.
            _ = try? await host(name, action: "show")
            showedWindow = true
            let machine = try store.load(name)
            stderr(machine.installed ? """
            Finish setup in the VM window (titled "terminal-linux · \(name)"):
              • Log in to an X11 session (Xfce, or "Ubuntu on Xorg" from the login screen's gear menu).
              • If the helper is not installed yet, open a terminal in the VM and run the commands from:
                  terminal-linux guest-setup
            Waiting for the guest helper. You can rerun this command later.
            """ : """
            The installer is booting in the VM window (titled "terminal-linux · \(name)").
              1. Install Linux to the virtual disk: choose "vda … Virtio Block Device", not the small
                 "Apple Virtual Disk" (that is the ISO). Pick a desktop that runs on X11 (Xfce is easiest).
              2. When it reboots, the VM powers off: run 'terminal-linux up \(name)' again to boot the installed system.
              3. Log in, open a terminal in the VM and run the commands from: terminal-linux guest-setup
            Waiting for the guest helper. You can rerun this command later.
            """)
        }
        let started = Date(), deadline = started.addingTimeInterval(Double(timeout))
        var lastReadiness = readiness
        while readiness != .ready && Date() < deadline {
            try Task.checkCancellation()
            guard Self.isRunning(directory) else {
                let machine = try store.load(name)
                if !machine.installed && Date().timeIntervalSince(started) < 60 {
                    throw Failure("""
                    The VM powered off within a minute of starting. Usually UEFI found nothing it can boot:
                    check that the ISO is an ARM64 (aarch64) image, not x86/amd64: \(machine.installer ?? "?")
                    If the installer did start and you closed or finished it, run 'terminal-linux up \(name)' again.
                    """)
                }
                throw Failure("The VM powered off (an installer reboot does this). Run 'terminal-linux up \(name)' to boot it again.")
            }
            values = await probe()
            readiness = GuestReadiness(values)
            if readiness != lastReadiness && readiness != .ready {
                stderr(readiness == .permissions ? "Guest helper connected, but \(values?["problem"] ?? "it cannot capture the screen or send input yet")." : "Waiting for the guest helper…")
                lastReadiness = readiness
            }
            if readiness != .ready { try await Task.sleep(nanoseconds: 1_000_000_000) }
        }
        guard readiness == .ready else { throw Failure("Setup is still pending. The VM is running; rerun 'terminal-linux up \(name)' when ready.") }
        // The helper answered from the installed system, so the ISO is no longer needed at the next boot.
        var machine = try store.load(name)
        if !machine.installed && !helperRunsFromLiveMedia(values) {
            machine.installed = true
            try store.save(machine)
            stderr("Linux is installed; the installer ISO is detached from the next boot. You may delete the ISO.")
        }
        stderr("Your virtual Linux desktop is ready.")
        FileManager.default.createFile(atPath: TerminalViewer.readyMarker(directory).path, contents: nil, attributes: [.posixPermissions: 0o600])
        if args.flags.contains("no-view") {
            if showedWindow { _ = try await host(name, action: "hide") }
            try printJSON(values ?? [:]); return
        }
        if !inline {
            _ = try await host(name, action: "show")
            stderr("Opened the native VM window. For the inline terminal desktop use Ghostty, Kitty or iTerm2. Agent actions work from any terminal.")
            return
        }
        if showedWindow { _ = try await host(name, action: "hide") }
        try await TerminalViewer(directory: directory, machine: store.load(name), graphics: args.options["protocol"], readOnly: false).run()
    }
}

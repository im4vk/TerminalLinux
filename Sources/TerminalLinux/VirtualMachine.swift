import AppKit
import Virtualization
import TerminalLinuxCore
import TerminalUI
import Darwin

/// The virtio-fs tag the guest mounts: `mount -t virtiofs terminal-linux /mnt/terminal-linux`.
/// It holds two directories, `control` (the mailbox) and `tools` (the helper, read-only).
let shareTag = "terminal-linux"

@MainActor
enum VirtualMachines {
    /// A generic ARM64 machine booted through UEFI, like a small PC: the distro's own bootloader takes it from there.
    static func configuration(_ machine: Machine, at directory: URL, tools: URL?, installer: URL?) throws -> VZVirtualMachineConfiguration {
        let config = VZVirtualMachineConfiguration()
        let loader = VZEFIBootLoader()
        loader.variableStore = VZEFIVariableStore(url: directory.appendingPathComponent("efi-vars.bin"))
        config.bootLoader = loader
        config.cpuCount = machine.cpu
        config.memorySize = UInt64(machine.memoryGiB) * 1024 * 1024 * 1024

        let platform = VZGenericPlatformConfiguration()
        guard let identity = VZGenericMachineIdentifier(dataRepresentation: try Data(contentsOf: directory.appendingPathComponent("identity.bin"))) else {
            throw Failure("The VM's machine identifier is unreadable")
        }
        platform.machineIdentifier = identity
        config.platform = platform

        let disk = try VZDiskImageStorageDeviceAttachment(url: directory.appendingPathComponent("disk.img"), readOnly: false)
        var storage: [VZStorageDeviceConfiguration] = [VZVirtioBlockDeviceConfiguration(attachment: disk)]
        if let installer {
            // The ISO appears as a USB stick. UEFI boots it while the disk is still empty.
            let media = try VZDiskImageStorageDeviceAttachment(url: installer, readOnly: true)
            storage.append(VZUSBMassStorageDeviceConfiguration(attachment: media))
        }
        config.storageDevices = storage

        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: machine.width, heightInPixels: machine.height)]
        config.graphicsDevices = [graphics]
        config.keyboards = [VZUSBKeyboardConfiguration()]
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        if machine.network {
            let network = VZVirtioNetworkDeviceConfiguration()
            network.attachment = VZNATNetworkDeviceAttachment()
            config.networkDevices = [network]
        }

        // Kernel messages for diagnosis, when the guest boots with console=hvc0 (most installers don't by default).
        let console = VZVirtioConsoleDeviceSerialPortConfiguration()
        console.attachment = try VZFileSerialPortAttachment(url: directory.appendingPathComponent("console.log"), append: true)
        config.serialPorts = [console]

        var shares: [String: VZSharedDirectory] = ["control": VZSharedDirectory(url: directory.appendingPathComponent("exchange"), readOnly: false)]
        if let tools { shares["tools"] = VZSharedDirectory(url: tools, readOnly: true) }
        let filesystem = VZVirtioFileSystemDeviceConfiguration(tag: shareTag)
        filesystem.share = VZMultipleDirectoryShare(directories: shares)
        config.directorySharingDevices = [filesystem]

        try config.validate()
        return config
    }

    /// Prepares an empty VM: sparse disk, UEFI variables, identity and the installer ISO reference.
    /// Nothing is downloaded and the ISO is not copied.
    static func create(_ args: Arguments, store: Store) throws -> Machine {
        guard VZVirtualMachine.isSupported else { throw Failure("Virtualization is unavailable. Use an Apple silicon Mac and the signed build in dist/.") }
        let name = try args.machineName()
        guard let iso = args.options["iso"] else { throw Failure("Provide --iso /path/to/linux-arm64.iso (see README: recommended images).") }
        let isoURL = URL(fileURLWithPath: (iso as NSString).expandingTildeInPath).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: isoURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw Failure("Installer ISO does not exist: \(isoURL.path)")
        }
        let directory = try store.directory(name)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw Failure("VM '\(name)' already exists at \(directory.path). It will not be overwritten.")
        }
        let host = ProcessInfo.processInfo.activeProcessorCount
        let cpu = try args.integer("cpus", default: max(2, min(4, host / 2)), range: 1...min(host, VZVirtualMachineConfiguration.maximumAllowedCPUCount))
        let memory = try args.integer("memory", default: 4, range: 2...Int(VZVirtualMachineConfiguration.maximumAllowedMemorySize / 1_073_741_824))
        let disk = try args.integer("disk", default: 32, range: 16...2048)
        let width = try args.integer("width", default: 1280, range: 800...3840)
        let height = try args.integer("height", default: 800, range: 600...2160)
        let machine = Machine(name: name, cpu: cpu, memoryGiB: memory, diskGiB: disk, width: width, height: height,
                              network: !args.flags.contains("offline"), installer: isoURL.path)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard chmod(directory.path, 0o700) == 0 else { throw Failure("Cannot make the VM directory private") }
        _ = try Mailbox(directory.appendingPathComponent("exchange"), create: true, shared: true)
        try VZGenericMachineIdentifier().dataRepresentation.write(to: directory.appendingPathComponent("identity.bin"))
        _ = try VZEFIVariableStore(creatingVariableStoreAt: directory.appendingPathComponent("efi-vars.bin"), options: [])
        let diskURL = directory.appendingPathComponent("disk.img")
        guard FileManager.default.createFile(atPath: diskURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw Failure("Cannot create disk image") }
        let file = try FileHandle(forWritingTo: diskURL)
        try file.truncate(atOffset: UInt64(disk) * 1_073_741_824)
        try file.close()
        try store.save(machine)
        stderr("Created '\(name)': \(cpu) CPUs, \(memory) GiB RAM, \(disk) GiB sparse disk, \(width)×\(height) display, installer \(isoURL.lastPathComponent).")
        return machine
    }
}

@MainActor
final class MachineRuntime: NSObject, VZVirtualMachineDelegate, NSWindowDelegate {
    let vm: VZVirtualMachine
    let machine: Machine
    let mailbox: Mailbox
    let lock: Int32
    var window: NSWindow?
    var loop: Task<Void, Never>?
    var stopping = false
    var stopDeadline: Date?

    init(machine: Machine, directory: URL, tools: URL) throws {
        self.machine = machine
        lock = open(directory.appendingPathComponent("runtime.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw Failure("Cannot open VM lock") }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { close(lock); throw Failure("VM is already running") }
        mailbox = try Mailbox(directory.appendingPathComponent("host-control"), create: true)
        var installer: URL?
        if !machine.installed, let path = machine.installer {
            guard FileManager.default.fileExists(atPath: path) else {
                throw Failure("The installer ISO moved or was deleted: \(path). Restore it, or run 'terminal-linux eject \(machine.name)' if Linux is already installed.")
            }
            installer = URL(fileURLWithPath: path)
        }
        vm = VZVirtualMachine(configuration: try VirtualMachines.configuration(machine, at: directory, tools: tools, installer: installer))
        super.init()
        vm.delegate = self
        if let installer { stderr("Installer attached: \(installer.lastPathComponent)") }
    }
    deinit { close(lock) }
    func start(show: Bool) async throws {
        if show { showWindow() }
        try await vm.start()
        stderr("VM '\(machine.name)' is running (PID \(getpid())).")
        loop = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                do { for request in try mailbox.requests() { await handle(request) } }
                catch { stderr(error.localizedDescription) }
                if let stopDeadline, Date() > stopDeadline {
                    stderr("The guest has not powered off 60 seconds after the power button. It may be showing a shutdown dialog: terminal-linux show \(machine.name). Use stop --force to power off immediately (unsaved guest work is lost).")
                    self.stopDeadline = nil
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }
    func showWindow() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        NSApp.setActivationPolicy(.regular)
        // Open at half the pixel size on Retina screens so the window is not enormous; the view scales the scanout.
        let scale = NSScreen.main?.backingScaleFactor ?? 1
        let view = VZVirtualMachineView(frame: NSRect(x: 0, y: 0, width: CGFloat(machine.width) / scale * 1.5, height: CGFloat(machine.height) / scale * 1.5))
        view.virtualMachine = vm
        view.capturesSystemKeys = true
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "terminal-linux · \(machine.name)"
        window.contentView = view
        window.contentAspectRatio = NSSize(width: machine.width, height: machine.height)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { sender.orderOut(nil); return false }
    func handle(_ request: Request) async {
        do {
            var values: [String: String] = [:]
            switch request.action {
            case "status": values = ["name": machine.name, "state": stateName, "pid": String(getpid()), "network": machine.networkDescription,
                                     "installer": machine.installed ? "detached" : "attached"]
            case "show": showWindow()
            case "hide": window?.orderOut(nil); NSApp.hide(nil)
            case "pause": try await vm.pause()
            case "resume": try await vm.resume()
            case "stop":
                if request.arguments["force"] == "true" {
                    try await vm.stop()
                    try mailbox.respond(Reply(id: request.id, values: ["state": "stopped"]))
                    exit(0)
                }
                guard !stopping else { throw Failure("Shutdown is already in progress") }
                // An ACPI power-button press: desktops show their shutdown dialog or power off.
                try vm.requestStop(); stopping = true; stopDeadline = Date().addingTimeInterval(60)
                values["state"] = "shutdown-requested"
            default: throw Failure("Unknown lifecycle action")
            }
            try mailbox.respond(Reply(id: request.id, values: values))
        } catch { try? mailbox.respond(Reply(id: request.id, error: error.localizedDescription)) }
    }
    var stateName: String {
        switch vm.state {
        case .stopped: return "stopped"
        case .running: return stopping ? "stopping" : "running"
        case .paused: return "paused"
        case .starting: return "starting"
        case .pausing: return "pausing"
        case .resuming: return "resuming"
        case .stopping: return "stopping"
        case .saving: return "saving"
        case .restoring: return "restoring"
        case .error: return "error"
        @unknown default: return "unknown"
        }
    }
    // Virtualization has no guest reset: a Linux reboot ends the VM, and `up` or `start` boots it again.
    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) { stderr("Guest powered off or rebooted."); exit(0) }
    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) { stderr(error.localizedDescription); exit(1) }
}

/// Diagnostics can quote guest- or file-provided text, so control characters are neutralised line by line;
/// the newlines of multi-line messages are kept.
func stderr(_ message: String) {
    let safe = message.split(separator: "\n", omittingEmptySubsequences: false).map { Span(String($0)).safeText }.joined(separator: "\n")
    FileHandle.standardError.write(Data((safe + "\n").utf8))
}

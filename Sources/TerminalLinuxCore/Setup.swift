import Foundation
import Darwin

public final class FileLock {
    private let fd: Int32
    public init(_ url: URL) throws {
        // Assign `fd` only once the lock is held: a class whose properties are all set runs deinit even when its
        // initializer throws, which would close the descriptor a second time (possibly someone else's by then).
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure("Cannot open lock: \(url.path)") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor); throw Failure("Another terminal-linux operation is already using \(url.lastPathComponent). Wait for it to finish, then retry.")
        }
        fd = descriptor
    }
    deinit { close(fd) }
}

/// What the guest helper's `status` reply says about computer use.
/// `capture`: it can read the X11 screen. `input`: the XTest extension is available for synthetic input.
public enum GuestReadiness: String {
    case unavailable, permissions, ready
    public init(_ values: [String: String]?) {
        guard let values else { self = .unavailable; return }
        self = values["capture"] == "true" && values["input"] == "true" ? .ready : .permissions
    }
}

/// True when the helper answered from installer media (a live session), so the ISO must stay attached.
public func helperRunsFromLiveMedia(_ values: [String: String]?) -> Bool { values?["live"] == "true" }

public struct SetupPlan: Codable {
    public let name: String
    public let steps: [String]
    public init(name: String, machine: Machine?, hasInstaller: Bool) {
        self.name = name
        var steps: [String] = []
        if machine == nil { steps.append(hasInstaller ? "create-vm-with-installer-iso" : "missing-installer-iso") }
        if machine?.installed != true { steps.append("install-linux-in-vm-window") }
        steps += ["start-or-resume-vm", "check-guest-helper", "open-terminal-view-if-supported"]
        self.steps = steps
    }
}

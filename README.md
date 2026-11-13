# terminal-linux

A separate **Linux desktop for computer-use agents**, running in a VM on your Apple silicon Mac and viewed or
driven from the terminal. AI agents (through MCP) and scripts (through the CLI) see the Linux screen and send it
clicks, keystrokes and scrolling. Your own Mac's mouse, keyboard and clipboard are never touched.

terminal-linux is built on [terminal-mac](https://github.com/govijr/terminal-mac) (MIT). It reuses that project's
file mailbox, terminal viewer, frame renderer, terminal UI and MCP server, and replaces the macOS guest with an
**ARM64 Linux guest** booted through UEFI and a Python guest helper. Linux guests don't have Apple's limit of two
concurrent macOS VMs, boot quickly and cost nothing to license, so several can run side by side for agent fleets
and tests.

> **Status: working prototype.** Validated end to end on 13 November 2026: macOS 26.7 host (Apple silicon), Debian
> 13.7 arm64 guest with Xfce, through installation, guest setup, every agent action, the MCP server and a reboot.
> See [Validation](#validation) for exactly what was tested and what wasn't.

## Contents

- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Build and test](#build-and-test)
- [Quick start: Debian 13 with Xfce](#quick-start-debian-13-with-xfce)
- [Everyday use](#everyday-use)
- [Using it with agents (MCP)](#using-it-with-agents-mcp)
- [Command reference](#command-reference)
- [The guest helper](#the-guest-helper)
- [Troubleshooting](#troubleshooting)
- [Where things live, and cleanup](#where-things-live-and-cleanup)
- [Isolation and security](#isolation-and-security)
- [Validation](#validation)
- [Known limitations and roadmap](#known-limitations-and-roadmap)
- [Project layout and development](#project-layout-and-development)
- [Credits and license](#credits-and-license)

## How it works

```
┌──────────────────── your Mac (host) ─────────────────────┐
│  terminal-linux CLI · terminal viewer · MCP server       │
│        │  writes request-<id>.json, reads reply-<id>.json│
│        ▼                                                 │
│  ~/Library/Application Support/terminal-linux/           │
│        machines/NAME/exchange/   ◀──────┐                │
│                                         │ virtio-fs      │
│  terminal-linux __run NAME  ── owns the VM (Apple        │
│  (background process)          Virtualization framework) │
└─────────────────────────────────────────┼────────────────┘
┌──────────────────── Linux guest (VM) ───┼────────────────┐
│  /mnt/terminal-linux/control  ◀─────────┘  (mailbox)     │
│  /mnt/terminal-linux/tools    (helper + scripts, r/o)    │
│                                                          │
│  terminal_linux_helper.py, in the logged-in X11 session: │
│    XGetImage → screenshots and change-only live frames   │
│    XTest     → clicks, drags, scrolling, keys, typing    │
└──────────────────────────────────────────────────────────┘
```

**Three roles, one host binary.**

1. **Front end** (`terminal-linux up | action | view | mcp`): what you or an agent run.
2. **VM process** (`terminal-linux __run NAME`): started by `start` or `up` and detached from your terminal. It
   owns the `VZVirtualMachine`, holds an exclusive lock on the VM, shows the native window on request and answers
   lifecycle requests (status, show, hide, pause, resume, stop) through a private `host-control` mailbox.
3. **Guest helper** (`terminal_linux_helper.py`): a Python program inside the guest's X11 session that answers
   screen and input requests through the shared `exchange` mailbox.

**The mailbox, not a network port.** The host writes `request-<UUID>.json` into a folder shared with the guest over
virtio-fs, and the helper writes `reply-<UUID>.json` (plus `image-<UUID>.png|.bin` for screens). Files are written
under a temporary name and renamed, so neither side ever sees a partial file. Readers reject symlinks, hard links
and non-regular files, sizes are bounded, and every request carries a deadline. If a request file is never picked
up, the CLI knows that no helper is running, and says so.

**The VM** is a generic ARM64 machine booted through UEFI:

| Part | terminal-mac | terminal-linux |
|---|---|---|
| Boot | `VZMacOSBootLoader`, IPSW installer | `VZEFIBootLoader` + EFI variable store; the ISO is attached as a USB stick until Linux is installed |
| Platform | Mac hardware model, auxiliary storage | `VZGenericPlatformConfiguration` + machine identifier |
| Disk | sparse `disk.img` | sparse `disk.img` on virtio-blk (32 GiB logical by default) |
| Display | Mac graphics, Retina | virtio-gpu scanout, 1280×800 pixels by default |
| Input devices | USB keyboard, absolute pointer | the same |
| Shared folder | automounted by macOS | `terminal-linux` virtio-fs tag with `control/` and `tools/` |
| Console | none | virtio console → `console.log` (when the kernel uses `hvc0`) |
| Guest helper | Swift app (ScreenCaptureKit, CGEvent) | Python 3 standard library + `ctypes` (libX11, libXtst; libXext and libXss when present) |
| Frames | BGRA + lz4 | BGRX + raw DEFLATE, change detection by CRC |
| Readiness | Screen Recording + Accessibility grants | an X11 session + the XTest extension |

The guest helper needs **no `pip` or package installs**: Python 3, libX11 and libXtst ship with ordinary X11
desktops.

**What happens when an agent clicks** (`click x=640 y=400 screenshot=true`):

```
MCP server ── request-….json {action: click, x: 640, y: 400} ──▶ exchange/
                                         guest helper: XTest motion + button press/release
MCP server ◀── reply-….json {ok: true} ──────────────────────── exchange/
MCP server ── waits 0.4 s, then a screenshot request ──▶ helper: XGetImage → PNG
MCP server ◀── image-….png → JPEG → returned to the agent as an image
```

**The live viewer** long-polls for frames: `screenshot {format: bgra-deflate, since: <last frame>, wait: 500 ms}`.
The helper captures the screen every 50 ms, compares checksums and answers only when something changed
(or with `unchanged` after the wait), so an idle desktop costs almost nothing. A full 1280×800 frame is 4 MB of
pixels, typically about 175 KB after DEFLATE, delivered in roughly 70 ms.

## Requirements

**Host**

- Apple silicon Mac with macOS 14 or later.
- The Swift toolchain. The Command Line Tools are enough (`xcode-select --install`); full Xcode isn't needed.
- About 1 GB of free disk for the ISO and build output, plus whatever the guest uses (a Debian Xfce install is
  about 6 GB; the VM disk is sparse, so it only uses what the guest writes).
- RAM for the guest while it runs: 4 GiB by default, released when the VM is stopped.
- Optional: **Ghostty, Kitty or iTerm2** for the inline terminal desktop. Other terminals (Terminal.app, VS Code)
  use the native VM window instead; agent actions work from any terminal.

**Guest**

- An **ARM64 (aarch64)** Linux installer ISO. x86/amd64 ISOs will not boot (see [Troubleshooting](#troubleshooting)).
- A desktop that runs on **X11**:
  - **Debian 13 arm64 with Xfce** (recommended, validated): X11 by default.
  - **Ubuntu 24.04 LTS desktop arm64**: choose "Ubuntu on Xorg" at the login screen, or let `install.sh` set GDM to X11.
  - Avoid Wayland-only desktops; recent GNOME releases have dropped their X11 session.
- Python 3.8 or newer, libX11 and libXtst (present on X11 desktops; `install.sh` checks).

## Build and test

```sh
git clone https://github.com/im4vk-avalara/terminal-linux.git
cd terminal-linux
bash scripts/build.sh          # → dist/TerminalLinux.app and the dist/terminal-linux launcher
bash scripts/test.sh           # all offline tests: Python helper + Swift host (incl. Swift↔Python protocol)
./dist/terminal-linux doctor   # checks Virtualization support and the bundled guest tools
```

- The build signs the app ad-hoc with the `com.apple.security.virtualization` entitlement, which Virtualization
  requires. Always use `dist/terminal-linux`, not the raw `swift build` product.
- Nothing is downloaded by the build or by the tool itself; you provide the ISO.
- Rebuilding while a VM runs is safe: the guest tools are updated in place, never deleted, so the running guest
  keeps its share and picks up a new helper the next time it starts.
- With only the Command Line Tools, `scripts/test.sh` points SwiftPM at their Swift Testing framework
  (XCTest ships only with Xcode).

## Quick start: Debian 13 with Xfce

### 1. Download the ISO and verify it

```sh
mkdir -p ~/Downloads/debian-arm64 && cd ~/Downloads/debian-arm64
base=https://cdimage.debian.org/debian-cd/current/arm64/iso-cd
curl -fLO "$base/SHA256SUMS"
iso=$(awk '/arm64-netinst.iso$/ {print $2}' SHA256SUMS)   # e.g. debian-13.7.0-arm64-netinst.iso (~700 MB)
curl -fLO "$base/$iso"
shasum -a 256 -c SHA256SUMS --ignore-missing              # must print: <iso>: OK
```

The checksum proves the download is intact. Proving it came from Debian also needs `SHA256SUMS.sign` and GPG, which
isn't installed on macOS by default.

### 2. Create the VM and install Debian

```sh
cd ~/path/to/terminal-linux
./dist/terminal-linux up --iso ~/Downloads/debian-arm64/debian-13.7.0-arm64-netinst.iso
```

This creates a VM (4 CPUs, 4 GiB RAM, a 32 GiB sparse disk, a 1280×800 display) and opens the window
**"terminal-linux · default"** with the Debian installer. The netinst image downloads packages during the
installation, so the guest needs internet (the default NAT networking provides it). In the installer:

| Screen | Choose |
|---|---|
| Partition disks: select disk | **`Virtual disk 1 (vda) – 34.4 GB Virtio Block Device`**. The highlighted `SCSI1 … (sda) – Apple Virtual Disk` is the ISO itself (read-only); neither choice can touch your Mac's disk |
| Partitioning scheme | "All files in one partition" |
| Software selection | tick **Xfce**, untick **GNOME** (GNOME uses Wayland), keep "standard system utilities" |
| Force EFI installation to the removable media path | **Yes** (harmless in a VM; makes booting from disk reliable) |
| Root password | If you set one, your user is **not** in the `sudo` group. Remember it: guest setup asks for it |

When the installer finishes, choose **Continue**. Virtualization has no reset, so the reboot **powers the VM off**.
That's expected.

### 3. Boot the installed system

```sh
./dist/terminal-linux up
```

You'll see GRUB, then the LightDM login screen. Log in with **Xfce Session** selected. If the Debian installer
appears again instead, run `./dist/terminal-linux stop --force && ./dist/terminal-linux eject && ./dist/terminal-linux up`.

### 4. Install the helper (inside the VM, once)

Open **Applications → Terminal Emulator** in the VM and run the commands that `./dist/terminal-linux guest-setup`
prints:

```sh
sudo mkdir -p /mnt/terminal-linux
sudo mount -t virtiofs terminal-linux /mnt/terminal-linux
bash /mnt/terminal-linux/tools/install.sh
```

If `sudo` says *"linux is not in the sudoers file"* (Debian with a root password), use the root password instead:

```sh
su -c 'mkdir -p /mnt/terminal-linux && mount -t virtiofs terminal-linux /mnt/terminal-linux'
bash /mnt/terminal-linux/tools/install.sh
```

`install.sh` runs five steps and **asks before every system change**. Questions take **y** or **n** only; anything
else is asked again, and when a password is needed it says so and asks on the next line.

1. **Checks** the share, Python, libX11/libXtst and that the session is X11. If a library is missing it shows the
   package command and runs it only if you agree.
2. **Mounts the share at every boot** by adding `terminal-linux /mnt/terminal-linux virtiofs rw,nofail 0 0` to
   `/etc/fstab`, through `sudo` or, without sudo, `su` (root password). `nofail` keeps the guest booting even
   without the share. **Answer y**: without it the share is gone after a reboot and the helper just waits.
3. **Installs the helper** for your user only: `~/.local/share/terminal-linux/`, the launcher
   `~/.local/bin/terminal-linux-helper` and an autostart entry.
4. **Keeps the screen awake** (optional, no password): turns off Xfce's blanking and display power saving, GNOME's
   idle delay, and the X screen saver at every login. Recommended for agent use.
5. **Starts the helper** and prints its status. It ends with **"✓ Ready"**.

On the Mac, `up` notices the helper, prints **"Your virtual Linux desktop is ready."** and detaches the ISO from future
boots. You can delete the ISO now.

Optional: let your user use sudo with `su -c 'usermod -aG sudo linux'`, then log out and back in. Turning on
automatic login in LightDM means the helper is ready after every boot without a manual login.

### 5. Try it

```sh
./dist/terminal-linux action status
./dist/terminal-linux action screenshot --output ~/Desktop/linux.png && open ~/Desktop/linux.png
./dist/terminal-linux action key ctrl+alt+t          # opens a terminal in Xfce
./dist/terminal-linux action type 'echo "Hello from the Mac! héllo € → $(uname -sm)"'
./dist/terminal-linux action key return
```

## Everyday use

```sh
./dist/terminal-linux up             # boot (or reconnect) and open the desktop
./dist/terminal-linux view           # live desktop in Ghostty/Kitty/iTerm2: Ctrl+G shortcuts, Ctrl+O VM window, Ctrl+] quit
./dist/terminal-linux show | hide    # the native VM window (closing it only hides it)
./dist/terminal-linux status         # running / paused / stopped
./dist/terminal-linux pause | resume
./dist/terminal-linux stop           # presses the power button; Xfce asks Log Out / Restart / Shut Down
./dist/terminal-linux stop --force   # immediate power-off; unsaved guest work is lost
```

After a reboot, log in (or enable auto-login): the share mounts from `/etc/fstab`, the helper starts from autostart
and keep-awake is re-applied, with nothing to type. Validated in practice.

## Using it with agents (MCP)

**Claude Code**:

```sh
claude mcp add terminal-linux -- "$PWD/dist/terminal-linux" mcp
./dist/terminal-linux skills install     # → ~/.claude/skills/terminal-linux/SKILL.md (observe → act → verify)
```

**Other MCP clients** (Cursor, VS Code, Codex…): paste the output of `./dist/terminal-linux mcp --config`. Use
`mcp NAME` for a VM other than `default`.

| Tool | Arguments | Notes |
|---|---|---|
| `screenshot` | none | JPEG of the desktop. Its pixel coordinates are the coordinates every other tool takes |
| `click` | `x`, `y`, `button` (`left`/`right`), `clicks` (1–3), `screenshot` | |
| `move` | `x`, `y`, `screenshot` | Hover menus and tooltips |
| `drag` | `x`, `y`, `toX`, `toY`, `screenshot` | Select text, move windows |
| `scroll` | `x`, `y`, `dy`, `dx`, `screenshot` | Pixels, −1000…1000; negative `dy` scrolls content down |
| `type` | `text`, `screenshot` | Literal Unicode text (up to 32 KiB) |
| `key` | `key`, `screenshot` | `return`, `tab`, `escape`, `super`, `alt+tab`, `ctrl+c`, `ctrl+alt+t`, `f1`–`f12`… |
| `status` | none | VM state and the helper's capabilities |

`screenshot: true` on an action returns a fresh screenshot 0.4 s after it. Keys use Linux conventions; `cmd` in a
chord means `ctrl`. When the VM is stopped, at its login screen or without a helper, the tools say so, so the agent
can ask you. The server never touches your Mac's desktop.

## Command reference

| Command | Purpose |
|---|---|
| `up [NAME] --iso PATH` | First run: create the VM from an installer ISO, boot it, show the window and wait for the helper |
| `up [NAME]` | Later: boot or reconnect, wait for the helper, open the desktop. `--no-view` waits and prints status JSON; `--detach` only boots; `--plan` lists the steps without changing anything; `--timeout` sets the wait (default 3600 s); `--protocol kitty\|iterm` forces a graphics protocol |
| `create [NAME] --iso PATH` | Prepare a VM without booting it |
| sizing options (`up`/`create`) | `--cpus` (default: half the host's cores, between 2 and 4), `--memory` GiB (4), `--disk` GiB (32, sparse), `--width`/`--height` pixels (1280×800), `--offline` (no network device) |
| `start [NAME] [--window]` | Boot in the background, optionally showing the window |
| `view [NAME] [--read-only]` | Live terminal desktop |
| `show` / `hide` / `status` / `pause` / `resume` `[NAME]` | Window and lifecycle |
| `stop [NAME] [--force]` | Power button, or immediate power-off |
| `eject [NAME]` | Detach the installer ISO (stopped VM). `up` does this by itself once the helper answers from the installed system |
| `network [NAME] --nat\|--offline` | Switch a stopped VM's networking |
| `guest-setup` | Print the commands that install the helper inside the guest |
| `ls` | List VMs as JSON |
| `doctor` | Host support and bundled tools |
| `action [NAME] status` | The helper's status (see [below](#the-guest-helper)) |
| `action [NAME] screenshot [--output PATH]` | Save a PNG |
| `action [NAME] click X Y [--button right] [--double]` | |
| `action [NAME] move X Y` | |
| `action [NAME] drag X Y X2 Y2` | |
| `action [NAME] scroll --dy N [--dx N] [--x X --y Y]` | |
| `action [NAME] type 'text'` | |
| `action [NAME] key CHORD` | |
| `mcp [NAME] [--config]` | MCP server over stdio, or a client config entry |
| `skills get\|path\|install [--dir DIR]` | The bundled agent skill |

Actions accept `--timeout SECONDS` (1–120, default 15) and print JSON; failures exit non-zero with a message.
`TERMINAL_LINUX_HOME` changes where VMs are stored.

## The guest helper

- **Language and dependencies:** Python 3 standard library and `ctypes`. libX11 and libXtst are required; libXext
  (DPMS) and libXss (screen saver state) are used when present.
- **Safety guard:** it refuses to run unless the `terminal-linux` virtio-fs share is mounted, so it can't drive a
  desktop outside this VM by accident.
- **One instance per user:** a lock file in `~/.local/state/terminal-linux/`. A second helper would answer every
  request twice and type every key twice. `--restart` replaces a running helper.
- **Launcher** (`~/.local/bin/terminal-linux-helper`): runs the copy in the read-only share when it's mounted, so a
  rebuilt host updates the guest automatically, and falls back to the installed copy. Runs Python in isolated
  mode (`-I`) and logs to `~/.local/state/terminal-linux/helper.log` (rotated at 1 MB).
- **Started** at login by `~/.config/autostart/terminal-linux-helper.desktop`. `install.sh` also starts it immediately.
- **Blank screens:** before each screenshot or frame, a blanked screen (X screen saver or DPMS standby/off) is woken,
  exactly as a mouse move would, so agents never get a black image from an idle desktop. When neither extension can
  report the state, an almost entirely black frame triggers the same wake.
- **Typing:** characters on the current keyboard layout are typed with their key (plus Shift when needed). Others
  (`€`, `→`, emoji, CJK) are bound to a spare keycode for a moment, the technique `xdotool` uses. Nothing touches
  the clipboard.

`action status` fields:

| Field | Meaning |
|---|---|
| `capture` / `input` | The helper can read the screen / send XTest input. Both `true` means ready |
| `screen` | `on`, `blanked` (screen saver), `standby` / `suspend` / `off` (DPMS) or `unknown` |
| `session` | `x11` or `wayland` (Wayland can't be captured; see `problem`) |
| `live` | `true` when running from installer or live media; `up` then keeps the ISO attached |
| `width` / `height` | Screen size in pixels, which are also input coordinates |
| `virtualization` | What `systemd-detect-virt` reports (`apple` under Virtualization) |
| `version`, `pid` | Which helper answered |
| `problem` | Why capture or input isn't available, when not ready |

Manual control inside the guest: `terminal-linux-helper --check` prints status JSON; `terminal-linux-helper --restart`
replaces the running helper.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| The VM powers off within seconds of `up --iso`, before any installer appears | UEFI found nothing to boot, nearly always an **x86/amd64 ISO**. Use an arm64/aarch64 image. `up` reports this case |
| The installer's disk list highlights `sda … Apple Virtual Disk` | That's the ISO. Choose **`vda … Virtio Block Device`** |
| `up` says the VM powered off after installation | Expected: a guest reboot ends the VM. Run `up` again |
| The installer boots again instead of Debian | `stop --force`, `eject`, `up` |
| `sudo: linux is not in the sudoers file` | Debian with a root password. Use `su -c '…'` for the mount, then answer `install.sh`'s questions with y and the root password; optionally `su -c 'usermod -aG sudo linux'` |
| `install.sh` printed "Skipped" for `/etc/fstab` | The question was answered with something other than `y`. Rerun `install.sh`. Current versions ask again on unclear answers |
| `action …`: *"No guest helper is reading the mailbox"* | The guest is booting or at its login screen (log in), the helper isn't installed yet (`guest-setup`), or the share isn't mounted after a reboot (`/etc/fstab`; mount manually with `sudo mount -t virtiofs terminal-linux /mnt/terminal-linux`) |
| `action …`: *"received … but did not answer"* | The helper is stuck or busy. See `~/.local/state/terminal-linux/helper.log` in the guest; `terminal-linux-helper --restart` |
| Black screenshots | The idle desktop blanked. Current helpers wake it automatically; `install.sh` step 4 turns blanking off |
| `status` shows `capture: false` with a Wayland problem | Log out and pick an X11 session (Xfce, "Ubuntu on Xorg"); or let `install.sh` set `WaylandEnable=false` for GDM |
| "The guest has not powered off 60 seconds after the power button" | Xfce shows a Log Out / Shut Down dialog. `show` the window and choose, or `stop --force` |
| `view` says to use Ghostty, Kitty or iTerm2 | Inline graphics need one of those; use `show` for the native window in other terminals |
| No network in the guest on a corporate VPN | macOS NAT's DNS relay can fail under TUN-mode VPNs. terminal-mac's user-space network (gvproxy) isn't ported yet |

Logs: `~/Library/Application Support/terminal-linux/machines/NAME/runtime.log` (VM process) and `console.log` (guest
console) on the Mac; `~/.local/state/terminal-linux/helper.log` in the guest.

## Where things live, and cleanup

| What | Where | Size |
|---|---|---|
| VMs (disk, EFI variables, identity, mailbox, logs) | `~/Library/Application Support/terminal-linux/machines/NAME/` (`TERMINAL_LINUX_HOME` overrides) | Sparse disk: what the guest uses (~6 GB for Debian Xfce) |
| Installer ISO | wherever you downloaded it; never copied | ~700 MB (Debian netinst) |
| Build output | `.build/`, `dist/` in the repository | ~600 MB / ~1 MB |
| Guest helper | in the guest: `~/.local/share/terminal-linux`, `~/.local/bin/terminal-linux-helper`, `~/.config/autostart/terminal-linux-*.desktop`, `~/.local/state/terminal-linux/` | small |
| Guest system changes | `/etc/fstab` line; optionally `/etc/gdm3/custom.conf` (backed up) | |

`du -sh ~/Library/Application\ Support/terminal-linux/machines/*` shows real disk use (`ls -l` shows the logical size).

```sh
# Remove the helper from the guest (undoes keep-awake, asks about /etc/fstab and GDM):
bash /mnt/terminal-linux/tools/uninstall.sh            # inside the VM

# Remove everything on the Mac:
./dist/terminal-linux stop --force
rm -rf ~/Library/Application\ Support/terminal-linux   # all VMs
rm -rf .build dist                                     # build output
rm -rf ~/Downloads/debian-arm64                        # the ISO, if you used the quick start
claude mcp remove terminal-linux; rm -rf ~/.claude/skills/terminal-linux   # if you added them
```

There's deliberately no command that deletes a VM.

## Isolation and security

- Agent actions run inside the guest; host input and screen APIs are never used, and the host desktop and
  clipboard are not shared.
- The guest sees two shares: `control` (read/write, the mailbox) and `tools` (read-only). Your home folder,
  projects, microphone and camera aren't attached.
- Linux sees virtio-fs files with the **host** user's uid, so the guest user is "other" to them. The `exchange`
  mailbox is therefore mode 0777 with 0666 files, **inside** the 0700 VM folder, so no other account on the Mac can
  reach it. The host-only `host-control` mailbox stays 0700/0600.
- There's no network listener. The host never executes content from the guest: replies are bounded, validated JSON
  and image data, and diagnostics printed from them are stripped of terminal control characters.
- The helper's VM check prevents accidents; it isn't attestation.
- NAT networking lets the guest reach the internet and possibly your LAN; `--offline` removes the network device.
- This isn't a hardened sandbox for hostile code.

## Validation

**Offline tests** (`bash scripts/test.sh`, no VM or network needed): 24 Python tests of the guest helper (mailbox
safety, request validation, PNG and DEFLATE encoders, key and chord parsing, every action against a fake display,
screen-state and wake logic, Wayland detection) and 24 Swift tests of the host (setup plans, readiness, machine
records, locks, mailbox safety and permissions, frame decoding, terminal input, terminal text sanitizing), including
**two cross-language tests where the Swift mailbox exchanges requests and frames with the real Python helper code**.

**Live run**, 13 November 2026, macOS 26.7.2 host, Debian 13.7.0 arm64 netinst + Xfce guest:

| Area | Result |
|---|---|
| VM creation, UEFI boot of the ISO, installation to the virtio disk | ✅ |
| Booting the installed system, ISO detached automatically | ✅ |
| Shared folder and mailbox (including the 0777/0666 permission model on real virtio-fs) | ✅ |
| `install.sh` without sudo (su path), `/etc/fstab`, keep-awake | ✅ after fixing two prompt bugs found in this run |
| `status`, screenshot (~0.13 s for 1280×800) | ✅ |
| Live frame stream (~70 ms per changed frame, 4 MB → ~175 KB; `unchanged` when idle) | ✅ |
| Click, type (including `é € →`), Return, `ctrl+alt+t`, scroll | ✅ |
| Window drag | ✅ 3 of 4; the first drag misbehaved and could not be reproduced (see below) |
| MCP server: initialize, 8 tools, `status`, `screenshot` | ✅ |
| Screen blanking: blanked screen detected and woken by a screenshot; keep-awake persists across login | ✅ |
| Power button → Xfce dialog → Shut Down; reboot → login → helper reconnects with nothing typed | ✅ |
| Rebuilding the host while the VM runs | ✅ |
| Inline terminal viewer (Ghostty/Kitty/iTerm2) | ⏳ not tried: no such terminal on the test Mac; the frame stream it uses was tested directly |
| Ubuntu, other desktops, `--offline`, several VMs at once | ⏳ not tried |

Bugs found and fixed during validation:
- Multi-line messages were garbled (newlines replaced by `�`).
- A file descriptor could be closed twice when a lock was busy (also present in terminal-mac).
- Misleading errors when an ISO isn't bootable, or when the VM had already stopped.
- `install.sh` assumed sudo, and treated unclear answers as "no".
- `build.sh` replaced the shared tools folder under a running VM.
- Black screenshots after idle blanking.

**Open:** in the first live session, one window drag moved the wrong windows and left a text selection behind. Three
later drags, with and without concurrent frame streaming and right after opening a window, were all exact, so the
cause is unknown. Report it if you see it again.

## Known limitations and roadmap

- X11 only. Wayland would need portal or compositor-specific capture plus uinput.
- The mouse pointer isn't drawn in screenshots (XGetImage excludes it).
- No HiDPI: the guest renders at the scanout's pixel size.
- A guest reboot powers the VM off (Virtualization has no reset); run `up` or `start` again.
- `snapshot` is an alias of `screenshot`, not an accessibility tree.
- Not yet: snapshots and rollback (APFS clones + saved VM state), user-space networking (gvproxy), Rosetta for x86
  Linux binaries, an accessibility-tree snapshot (AT-SPI), unattended installation (preseed / autoinstall).

## Project layout and development

```
Sources/TerminalLinux/       CLI, VM configuration and runtime, guided `up`, viewer, renderer, MCP server
Sources/TerminalLinuxCore/   mailbox, models, setup plan, readiness, frame decoding, terminal input parsing
Sources/TerminalUI/          terminal chrome, metrics, writer        (from terminal-mac)
Sources/CPhoneShim/          POSIX shared-memory shim for Kitty      (from terminal-mac)
guest/                       terminal_linux_helper.py, install.sh, uninstall.sh (shipped in the tools share)
skills/terminal-linux/       SKILL.md for agents
Tests/TerminalLinuxCoreTests Swift Testing suites (incl. Swift↔Python protocol)
Tests/guest/                 Python helper tests and the protocol peer
scripts/                     build.sh, test.sh
resources/                   the Virtualization entitlement
```

- Adding a guest action: implement it in `Helper.handle` (`guest/terminal_linux_helper.py`), add it to the CLI's
  `action` verbs and, for agents, to `AgentServer.tools`, then add a test with the fake display.
- After changing the helper, rebuild and run `terminal-linux-helper --restart` in the guest (the launcher already
  prefers the shared copy).
- Shell scripts must stay compatible with macOS's bash 3.2 where they're tested on the host.

## Credits and license

MIT; see [LICENSE](LICENSE). The mailbox, terminal viewer, renderer, terminal UI and MCP server derive from
[terminal-mac](https://github.com/govijr/terminal-mac) by Govijr (MIT). Apple's
[Virtualization framework](https://developer.apple.com/documentation/virtualization) runs the VM.

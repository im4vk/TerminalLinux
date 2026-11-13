---
name: terminal-linux
description: Use a separate virtual Linux desktop (X11) through the terminal-linux MCP tools or CLI. Observe with a screenshot, act with click/type/key/scroll/drag, then verify with another screenshot.
---

# terminal-linux: computer use in a virtual Linux desktop

terminal-linux runs an ARM64 Linux VM on the user's Mac with Apple's Virtualization framework. A helper inside the
guest's X11 session captures the screen and sends synthetic input. Your actions never touch the user's own Mac.

## Tools (MCP server `terminal-linux`)

| Tool | Use |
|---|---|
| `status` | Is the VM running, can the helper capture and send input? Check first if anything fails. |
| `screenshot` | The current desktop. Every x/y you send is a pixel in this image (top-left origin). |
| `click` | `x`, `y`, optional `button: "right"`, `clicks: 2` for a double click. |
| `move` | Hover, for menus and tooltips. |
| `drag` | Press at `x,y`, release at `toX,toY`: select text, move windows. |
| `scroll` | At `x,y`; negative `dy` scrolls the content down. |
| `type` | Literal text into the focused field. Unicode is fine. |
| `key` | A key or chord: `return`, `tab`, `escape`, `super`, `alt+tab`, `ctrl+c`, `ctrl+shift+v`, `ctrl+alt+t`. |

Most action tools accept `screenshot: true` to return a fresh screenshot after the action.

## Loop

1. **Observe**: `screenshot`. Read the screen before acting; do not guess coordinates.
2. **Act**: one action at a time, aimed at the centre of the target.
3. **Verify**: screenshot again (or pass `screenshot: true`). If nothing changed, wait briefly and look again before retrying.

## Linux habits

- Copy and paste are `ctrl+c` / `ctrl+v`; in terminal emulators use `ctrl+shift+c` / `ctrl+shift+v`.
- `super` opens the app launcher or Activities; type the app's name and press `return`.
- `ctrl+alt+t` opens a terminal on GNOME and Xfce. Prefer the terminal for file and package work: it is faster and more reliable than clicking.
- `cmd` in a chord is treated as `ctrl`.
- An idle desktop may blank its screen. Screenshots wake it automatically; `status` reports `screen` (`on`, `blanked`, `standby`, `off`).

## Ask the user when

- The VM is stopped or has no helper (`status` fails, or a timeout says there is no logged-in session): ask them to run `terminal-linux up`.
- A password is requested (login screen, `sudo`, keyring prompt). Never guess or type a password you were not given.
- The helper reports a Wayland session: they must log in with an X11 (Xorg) session.

## CLI equivalents

```sh
terminal-linux action status
terminal-linux action screenshot --output /tmp/linux.png
terminal-linux action click 640 400
terminal-linux action type 'hello'
terminal-linux action key ctrl+alt+t
terminal-linux action scroll --dy -300 --x 640 --y 400
```

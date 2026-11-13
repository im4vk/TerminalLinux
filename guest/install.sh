#!/bin/bash
# terminal-linux guest setup. Run inside the Linux VM, as your normal user, from the logged-in desktop:
#   bash /mnt/terminal-linux/tools/install.sh
# It installs the helper for this user only, asks before every system-wide change, and never installs packages
# by itself: if something is missing it prints the command for you to review and run.
set -euo pipefail

tools="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mount_point=/mnt/terminal-linux
tag=terminal-linux
data="${XDG_DATA_HOME:-$HOME/.local/share}/terminal-linux"
state="${XDG_STATE_HOME:-$HOME/.local/state}/terminal-linux"
bin="$HOME/.local/bin"
autostart="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✕\033[0m %s\n' "$*"; exit 1; }
# Yes/no only: anything else is asked again, so a password typed here is never taken as an answer.
ask() {
  local reply
  while true; do
    read -r -p "  $1 [y/N] " reply
    case "$reply" in
      [yY]|[yY][eE][sS]) return 0 ;;
      ""|[nN]|[nN][oO]) return 1 ;;
      *) echo "  Please answer y or n. (If a password is needed, you'll be asked for it on the next line.)" ;;
    esac
  done
}

# Debian leaves the first user out of the sudo group when a root password is set during installation.
# System steps then go through `su` (the root password) instead.
if sudo -n true 2>/dev/null || id -nG | tr ' ' '\n' | grep -qxE 'sudo|wheel|admin'; then
  as_root() { sudo sh -c "$1"; }
  root_tool=sudo
  password_hint="sudo may ask for your password next"
else
  as_root() { su -c "$1" root; }
  root_tool="su"
  password_hint="su asks for the ROOT password next"
fi

[[ "$(id -u)" != 0 ]] || fail "Run this as your normal desktop user, not root. It uses sudo (or su) only for the steps you approve."

bold "1. Checking this guest"
[[ "$(uname -s)" == Linux ]] || fail "This is not Linux."
grep -qs "^$tag .* virtiofs " /proc/mounts || fail "The $tag share is not mounted. Run: sudo mkdir -p $mount_point && sudo mount -t virtiofs $tag $mount_point (without sudo: su -c 'mkdir -p $mount_point && mount -t virtiofs $tag $mount_point')"
ok "terminal-linux share mounted at $(awk -v t="$tag" '$1==t && $3=="virtiofs" {print $2; exit}' /proc/mounts)"
command -v python3 >/dev/null || fail "python3 is missing. Install it with your package manager (for example: sudo apt install python3), then rerun."
python3 -I -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' || fail "Python 3.8 or newer is required."
ok "$(python3 --version)"

missing=()
for library in libX11.so.6 libXtst.so.6; do
  python3 -I -c "import ctypes; ctypes.CDLL('$library')" 2>/dev/null || missing+=("$library")
done
if (( ${#missing[@]} )); then
  warn "Missing X11 libraries: ${missing[*]}"
  if command -v apt-get >/dev/null; then suggestion="sudo apt-get install -y libx11-6 libxtst6"
  elif command -v dnf >/dev/null; then suggestion="sudo dnf install -y libX11 libXtst"
  elif command -v pacman >/dev/null; then suggestion="sudo pacman -S --needed libx11 libxtst"
  else suggestion=""; fi
  if [[ -n "$suggestion" ]] && ask "Install them now (${suggestion#sudo }; $password_hint)?"; then as_root "${suggestion#sudo }"
  else fail "Install ${missing[*]} with your package manager, then rerun this script."; fi
fi
ok "libX11 and libXtst available"

session="${XDG_SESSION_TYPE:-unknown}"
if [[ "$session" == wayland || -n "${WAYLAND_DISPLAY:-}" ]]; then
  warn "This desktop session is Wayland. The helper needs X11 to see the screen and send input."
  warn "Log out, pick an X11 session on the login screen (GNOME: gear icon → \"Ubuntu on Xorg\" / \"GNOME on Xorg\"), log in and rerun."
  if [[ -f /etc/gdm3/custom.conf ]] && ! grep -qs '^WaylandEnable=false' /etc/gdm3/custom.conf; then
    if ask "Or make GDM always use X11 (WaylandEnable=false in /etc/gdm3/custom.conf, after a reboot; $password_hint)?"; then
      as_root "cp /etc/gdm3/custom.conf /etc/gdm3/custom.conf.terminal-linux.bak"
      if grep -qs '^#\?WaylandEnable=' /etc/gdm3/custom.conf; then as_root "sed -i 's/^#\\?WaylandEnable=.*/WaylandEnable=false/' /etc/gdm3/custom.conf"
      else as_root "sed -i 's/^\\[daemon\\]\$/[daemon]\\nWaylandEnable=false/' /etc/gdm3/custom.conf"; fi
      ok "GDM will start X11 sessions after a reboot (backup: /etc/gdm3/custom.conf.terminal-linux.bak)"
    fi
  fi
  wayland=1
else
  [[ -n "${DISPLAY:-}" ]] || fail "DISPLAY is not set. Run this from a terminal inside the graphical desktop."
  ok "X11 session on display $DISPLAY"
  wayland=0
fi

bold "2. Mounting the share at every boot"
if grep -qs "^$tag[[:space:]]" /etc/fstab; then
  ok "/etc/fstab already mounts $tag"
elif ask "Add '$tag $mount_point virtiofs rw,nofail 0 0' to /etc/fstab ($password_hint)?"; then
  if as_root "mkdir -p '$mount_point' && echo '$tag $mount_point virtiofs rw,nofail 0 0' >> /etc/fstab"; then
    ok "Added to /etc/fstab. 'nofail' keeps the guest booting even without the share."
  else
    warn "Could not change /etc/fstab. As root, run: echo '$tag $mount_point virtiofs rw,nofail 0 0' >> /etc/fstab"
  fi
else
  warn "Skipped. Without it the share is gone after a reboot and the helper waits. As root, later:"
  warn "  echo '$tag $mount_point virtiofs rw,nofail 0 0' >> /etc/fstab"
fi
if [[ "$root_tool" != sudo ]]; then
  warn "Your user cannot use sudo. To allow it, run 'su -' and then 'usermod -aG sudo $USER', then log out and back in."
fi

bold "3. Installing the helper for $USER"
mkdir -p "$data" "$state" "$bin" "$autostart"
install -m 0644 "$tools/terminal_linux_helper.py" "$data/terminal_linux_helper.py"
# The launcher prefers the copy in the read-only share, so a rebuilt host updates the helper by itself.
cat > "$bin/terminal-linux-helper" <<EOF
#!/bin/sh
# terminal-linux guest helper launcher (installed by install.sh)
shared="$mount_point/tools/terminal_linux_helper.py"
local="$data/terminal_linux_helper.py"
if [ -r "\$shared" ]; then helper="\$shared"; else helper="\$local"; fi
log="$state/helper.log"
if [ -f "\$log" ] && [ "\$(wc -c < "\$log")" -gt 1048576 ]; then mv -f "\$log" "\$log.1"; fi
exec python3 -I "\$helper" "\$@" 2>>"\$log"
EOF
chmod 0755 "$bin/terminal-linux-helper"
cat > "$autostart/terminal-linux-helper.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=terminal-linux helper
Comment=Lets the terminal-linux host see this desktop and send input
Exec=$bin/terminal-linux-helper --restart
X-GNOME-Autostart-enabled=true
NoDisplay=true
Terminal=false
EOF
ok "Helper: $data/terminal_linux_helper.py"
ok "Launcher: $bin/terminal-linux-helper"
ok "Starts at login: $autostart/terminal-linux-helper.desktop"
ok "Log: $state/helper.log"

bold "4. Keeping the screen awake (optional)"
# An idle desktop blanks after about 10 minutes. The helper wakes it before each screenshot, but agents and the
# live viewer work more smoothly when it never blanks. Only this user's desktop settings change; no password.
if (( wayland )); then
  warn "Skipped: log in to an X11 session first."
elif [[ -f "$state/keep-awake" ]]; then
  ok "Already kept awake (undo with uninstall.sh)"
elif ask "Turn off screen blanking and monitor power saving for this desktop?"; then
  : > "$state/keep-awake"
  if command -v xfconf-query >/dev/null; then
    xfset() { xfconf-query -c "$1" -p "$2" -s "$4" 2>/dev/null || xfconf-query -c "$1" -p "$2" -n -t "$3" -s "$4"; }
    xfset xfce4-power-manager /xfce4-power-manager/blank-on-ac int 0
    xfset xfce4-power-manager /xfce4-power-manager/dpms-enabled bool false
    echo xfce >> "$state/keep-awake"
    ok "Xfce power manager: blanking and display power saving off"
  fi
  if command -v gsettings >/dev/null && [[ "${XDG_CURRENT_DESKTOP:-}" == *GNOME* ]]; then
    gsettings set org.gnome.desktop.session idle-delay 0
    echo gnome >> "$state/keep-awake"
    ok "GNOME: idle blanking off"
  fi
  if command -v xset >/dev/null; then
    xset s off -dpms
    cat > "$autostart/terminal-linux-keep-awake.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=terminal-linux keep awake
Comment=Stops the X server from blanking the screen (installed by terminal-linux)
Exec=xset s off -dpms
NoDisplay=true
Terminal=false
EOF
    ok "X server: screen saver and DPMS off now and at every login"
  fi
else
  ok "Left as is. The helper still wakes a blanked screen before each screenshot."
fi

bold "5. Starting it"
if (( wayland )); then
  warn "Not started: log in to an X11 session first. It then starts by itself."
  exit 0
fi
nohup "$bin/terminal-linux-helper" --restart >/dev/null 2>&1 &
sleep 1.5
if "$bin/terminal-linux-helper" --check > "$state/check.json" 2>/dev/null; then
  cat "$state/check.json"
  if grep -q '"capture": "true"' "$state/check.json" && grep -q '"input": "true"' "$state/check.json"; then
    ok "Ready. On the Mac, 'terminal-linux up' continues by itself."
  else
    warn "The helper runs but reports a problem (see \"problem\" above and $state/helper.log)."
  fi
else
  warn "The check failed; see $state/helper.log"
fi
cat <<EOF

Optional: turn on automatic login in your display manager (LightDM, GDM) so the helper is ready after every boot.
To remove everything later: bash $mount_point/tools/uninstall.sh
EOF

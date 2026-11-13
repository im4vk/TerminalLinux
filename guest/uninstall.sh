#!/bin/bash
# Removes the terminal-linux helper from this guest user and undoes install.sh's optional changes.
# Asks before touching /etc/fstab or GDM settings (those use sudo, or su with the root password).
set -euo pipefail
data="${XDG_DATA_HOME:-$HOME/.local/share}/terminal-linux"
state="${XDG_STATE_HOME:-$HOME/.local/state}/terminal-linux"
autostart="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"

ask() {
  local reply
  while true; do
    read -r -p "$1 [y/N] " reply
    case "$reply" in
      [yY]|[yY][eE][sS]) return 0 ;;
      ""|[nN]|[nN][oO]) return 1 ;;
      *) echo "Please answer y or n. (If a password is needed, you'll be asked for it on the next line.)" ;;
    esac
  done
}
if sudo -n true 2>/dev/null || id -nG | tr ' ' '\n' | grep -qxE 'sudo|wheel|admin'; then
  as_root() { sudo sh -c "$1"; }; password_hint="sudo may ask for your password next"
else
  as_root() { su -c "$1" root; }; password_hint="su asks for the ROOT password next"
fi

pkill -f 'terminal_linux_helper.py' 2>/dev/null || true

# Undo "keep the screen awake", returning each setting to the desktop's default.
if [[ -f "$state/keep-awake" ]]; then
  if grep -qx xfce "$state/keep-awake" && command -v xfconf-query >/dev/null; then
    xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/blank-on-ac -r 2>/dev/null || true
    xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-enabled -r 2>/dev/null || true
  fi
  if grep -qx gnome "$state/keep-awake" && command -v gsettings >/dev/null; then
    gsettings reset org.gnome.desktop.session idle-delay || true
  fi
  if command -v xset >/dev/null && [[ -n "${DISPLAY:-}" ]]; then xset s default +dpms || true; fi
  echo "Restored screen blanking and power saving."
fi

rm -f "$HOME/.local/bin/terminal-linux-helper" "$autostart/terminal-linux-helper.desktop" "$autostart/terminal-linux-keep-awake.desktop"
rm -rf "$data" "$state"
echo "Removed the helper, its launcher, autostart entries and logs."

if grep -qs '^terminal-linux[[:space:]]' /etc/fstab && ask "Remove the terminal-linux line from /etc/fstab ($password_hint)?"; then
  as_root "sed -i '/^terminal-linux[[:space:]]/d' /etc/fstab" && echo "Removed from /etc/fstab."
fi
if [[ -f /etc/gdm3/custom.conf.terminal-linux.bak ]] && ask "Restore the GDM settings saved by install.sh ($password_hint)?"; then
  as_root "mv /etc/gdm3/custom.conf.terminal-linux.bak /etc/gdm3/custom.conf" && echo "Restored /etc/gdm3/custom.conf."
fi

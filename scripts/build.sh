#!/bin/bash
# Builds dist/TerminalLinux.app and the dist/terminal-linux launcher. Needs only the Swift toolchain
# (Xcode or the Command Line Tools); nothing is downloaded.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -m)" != arm64 ]]; then
  echo 'terminal-linux requires Apple silicon.' >&2
  exit 1
fi
configuration="${CONFIGURATION:-release}"
# Ad-hoc signing is enough: unlike terminal-mac, no guest app identity needs to survive rebuilds.
identity="${SIGN_IDENTITY:--}"
version="${VERSION:-0.1.0}"
build_number="${BUILD_NUMBER:-1}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
  echo 'VERSION must be x.y.z and BUILD_NUMBER a positive integer.' >&2
  exit 1
fi
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
build_options=(--disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/configuration" --security-path "$PWD/.build/security")
swift build "${build_options[@]}" -c "$configuration"
binary_dir="$(swift build "${build_options[@]}" -c "$configuration" --show-bin-path)"

app="$PWD/dist/TerminalLinux.app"
tools="$app/Contents/Resources/guest-tools"
mkdir -p "$app/Contents/MacOS"
# Replace rather than overwrite: rewriting a running VM's executable in place can kill it.
rm -f "$app/Contents/MacOS/terminal-linux"
cp "$binary_dir/terminal-linux" "$app/Contents/MacOS/terminal-linux"

# The guest reads the tools share as "other" (virtio-fs reports the host uid), so they must be world-readable.
# A running VM shares this directory itself, so it is updated in place, never deleted and recreated: each file
# is written beside its target and renamed over it, and the guest sees the new helper on its next launch.
mkdir -p "$tools"
chmod 0755 "$tools"
publish() {
  local source="$1" mode="$2" target="$tools/$(basename "$1")"
  install -m "$mode" "$source" "$target.new"
  mv -f "$target.new" "$target"
}
publish guest/terminal_linux_helper.py 0644
publish guest/install.sh 0755
publish guest/uninstall.sh 0755
for existing in "$tools"/*; do
  case "$(basename "$existing")" in
    terminal_linux_helper.py|install.sh|uninstall.sh) ;;
    *) rm -rf "$existing" ;;  # Files dropped from the project.
  esac
done

rm -rf "$app/Contents/Resources/skills"
mkdir -p "$app/Contents/Resources/skills"
cp -R skills/terminal-linux "$app/Contents/Resources/skills/"

plist="$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Clear dict' "$plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string dev.terminal-linux.host" "$plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleName string TerminalLinux" "$plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string terminal-linux' "$plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "$plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $version" "$plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $build_number" "$plist"
/usr/libexec/PlistBuddy -c 'Add :LSMinimumSystemVersion string 14.0' "$plist"
/usr/libexec/PlistBuddy -c 'Add :NSHighResolutionCapable bool true' "$plist"

# Virtualization refuses to start VMs without this entitlement.
codesign --force --sign "$identity" --options runtime --timestamp=none --entitlements resources/terminal-linux.entitlements "$app"
codesign --verify --deep --strict "$app"
ln -sfn TerminalLinux.app/Contents/MacOS/terminal-linux dist/terminal-linux
echo "Built: $PWD/dist/terminal-linux"

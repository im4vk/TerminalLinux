#!/usr/bin/env python3
"""terminal-linux guest helper.

Runs inside the Linux VM's logged-in X11 session. It answers requests that the host writes into the
shared virtio-fs mailbox (/mnt/terminal-linux/control): screenshots, a change-driven frame stream, and
synthetic mouse and keyboard input through the XTest extension.

Only the Python standard library is used. X11 is reached through ctypes (libX11.so.6, libXtst.so.6),
which every X11 desktop already ships, so nothing has to be installed with pip or a package manager.

The mailbox protocol matches terminal-mac's Swift `Mailbox`:
  host  -> request-<UUID>.json  {"id", "action", "arguments": {str: str}, "deadline": <Swift Date>}
  guest -> reply-<UUID>.json    {"id", "ok", "values": {str: str}, "error"?}
  guest -> image-<UUID>.png | image-<UUID>.bin   (screenshot payloads)
Files are written under a temporary name and renamed, so readers never see partial content.
"""

import argparse
import ctypes
import ctypes.util
import errno
import fcntl
import json
import os
import signal
import stat
import struct
import subprocess
import sys
import threading
import time
import uuid
import zlib

VERSION = "0.2.0"
SHARE_TAG = "terminal-linux"
DEFAULT_EXCHANGE = "/mnt/terminal-linux/control"
# Swift's JSONEncoder writes Date as seconds since 2001-01-01 UTC.
APPLE_EPOCH = 978307200.0
REQUEST_LIMIT = 256 * 1024
MAX_TEXT_BYTES = 32 * 1024
MAX_REQUESTS_PER_POLL = 32
STATE_DIR = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"), "terminal-linux")


class HelperError(Exception):
    """An action failed in a way the host should report to the user or agent."""


def log(message):
    stamp = time.strftime("%Y-%m-%d %H:%M:%S")
    sys.stderr.write(f"{stamp} {message}\n")
    sys.stderr.flush()


# --------------------------------------------------------------------------------------------------
# Mailbox
# --------------------------------------------------------------------------------------------------

def _check_name(name):
    if not name or name in (".", "..") or "/" in name or "\0" in name:
        raise HelperError("Invalid mailbox filename")


class Mailbox:
    """Flat directory mailbox. Rejects symlinks, hard links and non-regular files, and bounds sizes."""

    def __init__(self, path):
        self.path = path
        self.dirfd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)

    def close(self):
        os.close(self.dirfd)

    def read(self, name, limit=1024 * 1024):
        _check_name(name)
        try:
            fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=self.dirfd)
        except FileNotFoundError:
            return None
        except OSError as error:
            raise HelperError(f"Cannot read mailbox file {name} (symlinks are rejected): {error.strerror}")
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > limit:
                raise HelperError("Invalid or oversized mailbox file")
            chunks, total = [], 0
            while True:
                chunk = os.read(fd, 65536)
                if not chunk:
                    break
                total += len(chunk)
                if total > limit:
                    raise HelperError("Mailbox file exceeded size limit")
                chunks.append(chunk)
            return b"".join(chunks)
        finally:
            os.close(fd)

    def write(self, data, name):
        _check_name(name)
        temporary = f".{uuid.uuid4()}.tmp"
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o666, dir_fd=self.dirfd)
        try:
            try:
                os.fchmod(fd, 0o666)
            except OSError:
                pass  # The host reads guest files as their owner; the mode is a courtesy.
            view = memoryview(data)
            while view:
                written = os.write(fd, view)
                view = view[written:]
            os.close(fd)
            fd = -1
            os.rename(temporary, name, src_dir_fd=self.dirfd, dst_dir_fd=self.dirfd)
        finally:
            if fd >= 0:
                os.close(fd)
            try:
                os.unlink(temporary, dir_fd=self.dirfd)
            except FileNotFoundError:
                pass

    def remove(self, name):
        try:
            _check_name(name)
            os.unlink(name, dir_fd=self.dirfd)
        except (HelperError, FileNotFoundError):
            pass

    def requests(self, now=None):
        now = time.time() if now is None else now
        found = []
        for name in os.listdir(self.dirfd):
            if not (name.startswith("request-") and name.endswith(".json")):
                continue
            try:
                data = self.read(name, REQUEST_LIMIT)
            except HelperError as error:
                log(f"Discarding {name}: {error}")
                data = None
            finally:
                self.remove(name)
            request = parse_request(name, data, now)
            if request is not None:
                found.append(request)
            if len(found) == MAX_REQUESTS_PER_POLL:
                break
        found.sort(key=lambda request: request["deadline"])
        return found

    def respond(self, request_id, values=None, error=None):
        reply = {"id": request_id, "ok": error is None, "values": {str(k): str(v) for k, v in (values or {}).items()}}
        if error is not None:
            reply["error"] = str(error)
        self.write(json.dumps(reply).encode("utf-8"), f"reply-{request_id}.json")


def parse_request(name, data, now):
    """Validates a request exactly like the Swift side: matching id, string arguments, unexpired deadline."""
    if data is None:
        return None
    try:
        body = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    if not isinstance(body, dict):
        return None
    request_id, action, arguments, deadline = body.get("id"), body.get("action"), body.get("arguments"), body.get("deadline")
    if not isinstance(request_id, str) or not isinstance(action, str) or not isinstance(arguments, dict):
        return None
    if isinstance(deadline, bool) or not isinstance(deadline, (int, float)):
        return None
    try:
        uuid.UUID(request_id)
    except ValueError:
        return None
    if name != f"request-{request_id}.json":
        return None
    if not all(isinstance(k, str) and isinstance(v, str) for k, v in arguments.items()):
        return None
    deadline = float(deadline) + APPLE_EPOCH
    if deadline <= now:
        return None
    return {"id": request_id, "action": action, "arguments": arguments, "deadline": deadline}


# --------------------------------------------------------------------------------------------------
# Image encoding
# --------------------------------------------------------------------------------------------------

def bgrx_to_rgb_rows(pixels, width, height, stride):
    """PNG scanlines (filter byte 0 + RGB) from X11 ZPixmap BGRX rows."""
    out = bytearray()
    for y in range(height):
        row = pixels[y * stride: y * stride + width * 4]
        rgb = bytearray(width * 3)
        rgb[0::3] = row[2::4]
        rgb[1::3] = row[1::4]
        rgb[2::3] = row[0::4]
        out += b"\x00" + rgb
    return bytes(out)


def encode_png(pixels, width, height, stride):
    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)
    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    raw = bgrx_to_rgb_rows(pixels, width, height, stride)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b"")


def deflate_raw(data):
    """Raw DEFLATE (RFC 1951), which Apple's Compression framework decodes as COMPRESSION_ZLIB."""
    compressor = zlib.compressobj(1, zlib.DEFLATED, -15)
    return compressor.compress(data) + compressor.flush()


# --------------------------------------------------------------------------------------------------
# Keyboard model
# --------------------------------------------------------------------------------------------------

KEYSYMS = {
    "return": 0xFF0D, "enter": 0xFF0D, "tab": 0xFF09, "escape": 0xFF1B, "esc": 0xFF1B, "backspace": 0xFF08,
    "delete": 0xFFFF, "insert": 0xFF63, "home": 0xFF50, "end": 0xFF57, "pageup": 0xFF55, "pagedown": 0xFF56,
    "left": 0xFF51, "up": 0xFF52, "right": 0xFF53, "down": 0xFF54, "space": 0x20, "menu": 0xFF67,
    "print": 0xFF61, "capslock": 0xFFE5,
    "super": 0xFFEB, "win": 0xFFEB, "meta": 0xFFEB, "ctrl": 0xFFE3, "control": 0xFFE3, "alt": 0xFFE9,
    "option": 0xFFE9, "shift": 0xFFE1,
}
KEYSYMS.update({f"f{n}": 0xFFBE + n - 1 for n in range(1, 13)})
# Mac habits ("cmd+c") map to the Linux equivalent, Control.
MODIFIERS = {"shift": 0xFFE1, "ctrl": 0xFFE3, "control": 0xFFE3, "cmd": 0xFFE3, "command": 0xFFE3,
             "alt": 0xFFE9, "option": 0xFFE9, "super": 0xFFEB, "win": 0xFFEB, "meta": 0xFFEB}
SHIFT_L = 0xFFE1


def char_to_keysym(character):
    code = ord(character)
    if character in "\r\n":
        return 0xFF0D
    if character == "\t":
        return 0xFF09
    if 0x20 <= code <= 0x7E or 0xA0 <= code <= 0xFF:
        return code  # Latin-1 keysyms equal their code points.
    if code < 0x20 or 0x7F <= code < 0xA0:
        return None  # Other control characters are not typed.
    return 0x01000000 | code  # X11 Unicode keysym.


def parse_chord(chord):
    """'ctrl+shift+t' -> ([Control_L, Shift_L], keysym of 't'). A lone modifier ('super') is the key itself."""
    text = chord.strip().lower()
    if text == "+":
        parts = ["+"]
    elif text.endswith("++"):
        parts = text[:-2].split("+") + ["+"]  # 'ctrl++' presses '+'.
    else:
        parts = text.split("+")  # A trailing single '+' ('ctrl+') leaves an empty key and is rejected below.
    if not parts or not parts[-1]:
        raise HelperError(f"Unknown key: {chord!r}. Examples: return, super, alt+tab, ctrl+alt+t")
    key = parts[-1]
    modifiers = []
    for name in parts[:-1]:
        if name not in MODIFIERS:
            raise HelperError(f"Unknown modifier: {name}. Use ctrl, alt, shift or super")
        modifiers.append(MODIFIERS[name])
    if key in KEYSYMS:
        keysym = KEYSYMS[key]
    elif key in ("cmd", "command"):
        keysym = MODIFIERS[key]
    elif len(key) == 1:
        keysym = char_to_keysym(key)
    else:
        keysym = None
    if keysym is None:
        raise HelperError(f"Unknown key: {chord!r}. Examples: return, super, alt+tab, ctrl+alt+t")
    return modifiers, keysym


DPMS_LEVELS = {0: "on", 1: "standby", 2: "suspend", 3: "off"}


def screen_state(saver_on, dpms_enabled, dpms_level):
    """'on', 'blanked' (X screen saver active), a DPMS power level, or 'unknown' when nothing could be queried."""
    if dpms_enabled and dpms_level in (1, 2, 3):
        return DPMS_LEVELS[dpms_level]
    if saver_on:
        return "blanked"
    if saver_on is None and dpms_level is None:
        return "unknown"
    return "on"


def looks_blank(pixels):
    """A screen saver's black window: at least three quarters zero bytes (BGR all zero, padding 0 or 255)."""
    return len(pixels) > 0 and pixels.count(b"\x00") * 4 >= len(pixels) * 3


def scroll_clicks(delta):
    """Viewer and agents send pixels (60 per wheel notch); X11 scrolls in notches."""
    if delta == 0:
        return 0
    return max(1, min(30, round(abs(delta) / 60)))


# --------------------------------------------------------------------------------------------------
# X11 through ctypes
# --------------------------------------------------------------------------------------------------

class XScreenSaverInfo(ctypes.Structure):
    _fields_ = [("window", ctypes.c_ulong), ("state", ctypes.c_int), ("kind", ctypes.c_int),
                ("til_or_since", ctypes.c_ulong), ("idle", ctypes.c_ulong), ("eventMask", ctypes.c_ulong)]


class XImageFuncs(ctypes.Structure):
    _fields_ = [("create_image", ctypes.c_void_p),
                ("destroy_image", ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p)),
                ("get_pixel", ctypes.c_void_p), ("put_pixel", ctypes.c_void_p),
                ("sub_image", ctypes.c_void_p), ("add_pixel", ctypes.c_void_p)]


class XImage(ctypes.Structure):
    _fields_ = [("width", ctypes.c_int), ("height", ctypes.c_int), ("xoffset", ctypes.c_int), ("format", ctypes.c_int),
                ("data", ctypes.c_void_p), ("byte_order", ctypes.c_int), ("bitmap_unit", ctypes.c_int),
                ("bitmap_bit_order", ctypes.c_int), ("bitmap_pad", ctypes.c_int), ("depth", ctypes.c_int),
                ("bytes_per_line", ctypes.c_int), ("bits_per_pixel", ctypes.c_int),
                ("red_mask", ctypes.c_ulong), ("green_mask", ctypes.c_ulong), ("blue_mask", ctypes.c_ulong),
                ("obdata", ctypes.c_void_p), ("f", XImageFuncs)]


ZPIXMAP = 2
ALL_PLANES = ctypes.c_ulong(-1).value
_libraries = {}
_error_handler = None


def _load(name, soname):
    if name not in _libraries:
        try:
            _libraries[name] = ctypes.CDLL(soname)
        except OSError:
            found = ctypes.util.find_library(name)
            if not found:
                raise HelperError(f"{soname} is not installed in the guest")
            _libraries[name] = ctypes.CDLL(found)
    return _libraries[name]


def optional_library(name, soname, signatures):
    """libXext (DPMS) and libXss (screen saver state) only improve blank-screen handling; absent is fine."""
    try:
        library = _load(name, soname)
    except (HelperError, OSError):
        return None
    for function, (arguments, result) in signatures.items():
        try:
            getattr(library, function).argtypes = arguments
            getattr(library, function).restype = result
        except AttributeError:
            return None
    return library


def x11_libraries():
    """Loads and types libX11 and libXtst once. Xlib errors are logged instead of killing the helper."""
    global _error_handler
    if "X11" in _libraries and "Xtst" in _libraries:
        return _libraries["X11"], _libraries["Xtst"]
    x = _load("X11", "libX11.so.6")
    t = _load("Xtst", "libXtst.so.6")
    p, ul, i, ui, ub = ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_uint, ctypes.c_ubyte
    signatures = {
        x: {"XInitThreads": ([], i), "XOpenDisplay": ([ctypes.c_char_p], p), "XCloseDisplay": ([p], i),
            "XDefaultScreen": ([p], i), "XDefaultRootWindow": ([p], ul), "XDisplayWidth": ([p, i], i),
            "XDisplayHeight": ([p, i], i), "XFlush": ([p], i), "XSync": ([p, i], i), "XFree": ([p], i),
            "XGetImage": ([p, ul, i, i, ui, ui, ul, i], ctypes.POINTER(XImage)),
            "XKeysymToKeycode": ([p, ul], ub), "XDisplayKeycodes": ([p, ctypes.POINTER(i), ctypes.POINTER(i)], i),
            "XGetKeyboardMapping": ([p, ub, i, ctypes.POINTER(i)], ctypes.POINTER(ul)),
            "XChangeKeyboardMapping": ([p, i, i, ctypes.POINTER(ul), i], i), "XForceScreenSaver": ([p, i], i)},
        t: {"XTestQueryExtension": ([p, ctypes.POINTER(i), ctypes.POINTER(i), ctypes.POINTER(i), ctypes.POINTER(i)], i),
            "XTestFakeMotionEvent": ([p, i, i, i, ul], i), "XTestFakeButtonEvent": ([p, ui, i, ul], i),
            "XTestFakeKeyEvent": ([p, ui, i, ul], i)},
    }
    for library, functions in signatures.items():
        for function, (arguments, result) in functions.items():
            getattr(library, function).argtypes = arguments
            getattr(library, function).restype = result
    x.XInitThreads()
    handler_type = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p)

    def on_error(display, event):
        log("Xlib reported a protocol error")
        return 0
    _error_handler = handler_type(on_error)
    x.XSetErrorHandler.argtypes = [handler_type]
    x.XSetErrorHandler.restype = ctypes.c_void_p
    x.XSetErrorHandler(_error_handler)
    return x, t


class Display:
    """One X connection. Xlib connections are not shared between threads; each thread opens its own."""

    def __init__(self):
        self.x, self.t = x11_libraries()
        name = os.environ.get("DISPLAY")
        if not name:
            raise HelperError("DISPLAY is not set: start the helper from the logged-in X11 desktop session")
        self.handle = self.x.XOpenDisplay(name.encode())
        if not self.handle:
            raise HelperError(f"Cannot open X display {name}")
        self.screen = self.x.XDefaultScreen(self.handle)
        self.root = self.x.XDefaultRootWindow(self.handle)
        n = ctypes.c_int()
        self.has_xtest = bool(self.t.XTestQueryExtension(self.handle, ctypes.byref(n), ctypes.byref(n), ctypes.byref(n), ctypes.byref(n)))
        self.xext = optional_library("Xext", "libXext.so.6", {
            "DPMSCapable": ([ctypes.c_void_p], ctypes.c_int),
            "DPMSInfo": ([ctypes.c_void_p, ctypes.POINTER(ctypes.c_ushort), ctypes.POINTER(ctypes.c_ubyte)], ctypes.c_int),
            "DPMSForceLevel": ([ctypes.c_void_p, ctypes.c_ushort], ctypes.c_int)})
        self.xss = optional_library("Xss", "libXss.so.1", {
            "XScreenSaverQueryInfo": ([ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(XScreenSaverInfo)], ctypes.c_int)})
        self.has_dpms = bool(self.xext and self.xext.DPMSCapable(self.handle))

    @property
    def size(self):
        return self.x.XDisplayWidth(self.handle, self.screen), self.x.XDisplayHeight(self.handle, self.screen)

    def screen_state(self):
        saver_on = dpms_enabled = dpms_level = None
        if self.xss:
            info = XScreenSaverInfo()
            if self.xss.XScreenSaverQueryInfo(self.handle, self.root, ctypes.byref(info)):
                saver_on = info.state == 1  # ScreenSaverOn
        if self.has_dpms:
            level, enabled = ctypes.c_ushort(), ctypes.c_ubyte()
            if self.xext.DPMSInfo(self.handle, ctypes.byref(level), ctypes.byref(enabled)):
                dpms_enabled, dpms_level = bool(enabled.value), level.value
        return screen_state(saver_on, dpms_enabled, dpms_level)

    def wake(self):
        """What any mouse move does: end the screen saver and switch the monitor back on."""
        self.x.XForceScreenSaver(self.handle, 0)  # ScreenSaverReset
        if self.has_dpms:
            self.xext.DPMSForceLevel(self.handle, 0)  # DPMSModeOn
        self.x.XSync(self.handle, 0)
        time.sleep(0.4)  # The compositor repaints before the next capture.

    def capture(self, wake=True):
        """The whole root window as BGRX rows: (bytes, width, height, bytes_per_line).
        A blanked screen is woken first, so callers never receive a black frame from an idle desktop."""
        state = self.screen_state() if wake else "on"
        if state not in ("on", "unknown"):
            self.wake()
        frame = self.grab()
        if wake and state == "unknown" and looks_blank(frame[0]):
            self.wake()
            frame = self.grab()
        return frame

    def grab(self):
        width, height = self.size
        image = self.x.XGetImage(self.handle, self.root, 0, 0, width, height, ALL_PLANES, ZPIXMAP)
        if not image:
            raise HelperError("XGetImage failed: the screen cannot be captured")
        try:
            img = image.contents
            if img.bits_per_pixel != 32 or img.byte_order != 0 or img.blue_mask != 0xFF or img.red_mask != 0xFF0000:
                raise HelperError(f"Unsupported X11 pixel format ({img.bits_per_pixel} bpp, depth {img.depth})")
            data = ctypes.string_at(img.data, img.bytes_per_line * img.height)
            return data, img.width, img.height, img.bytes_per_line
        finally:
            image.contents.f.destroy_image(ctypes.cast(image, ctypes.c_void_p))

    # Input ----------------------------------------------------------------------------------------

    def require_input(self):
        if not self.has_xtest:
            raise HelperError("The X server has no XTest extension, so input cannot be sent")

    def flush(self):
        self.x.XFlush(self.handle)

    def move(self, x, y):
        self.require_input()
        self.t.XTestFakeMotionEvent(self.handle, self.screen, x, y, 0)
        self.flush()

    def button(self, number, pressed):
        self.t.XTestFakeButtonEvent(self.handle, number, 1 if pressed else 0, 0)
        self.flush()

    def click(self, x, y, number=1, times=1):
        self.move(x, y)
        for index in range(times):
            if index:
                time.sleep(0.04)
            self.button(number, True)
            time.sleep(0.01)
            self.button(number, False)

    def drag(self, x1, y1, x2, y2):
        self.move(x1, y1)
        self.button(1, True)
        steps = max(2, min(30, int(((x2 - x1) ** 2 + (y2 - y1) ** 2) ** 0.5 / 12)))
        for step in range(1, steps + 1):
            fraction = step / steps
            self.t.XTestFakeMotionEvent(self.handle, self.screen, round(x1 + (x2 - x1) * fraction), round(y1 + (y2 - y1) * fraction), 0)
            self.flush()
            time.sleep(0.008)
        self.button(1, False)

    def scroll(self, dx, dy):
        self.require_input()
        # Positive dy scrolls content up (wheel up, button 4); positive dx scrolls left (button 6).
        for amount, positive, negative in ((dy, 4, 5), (dx, 6, 7)):
            number = positive if amount > 0 else negative
            for _ in range(scroll_clicks(amount)):
                self.button(number, True)
                self.button(number, False)

    def keymap(self):
        """keysym -> (keycode, needs_shift) for the current layout's first group."""
        low, high = ctypes.c_int(), ctypes.c_int()
        self.x.XDisplayKeycodes(self.handle, ctypes.byref(low), ctypes.byref(high))
        count = high.value - low.value + 1
        per = ctypes.c_int()
        table = self.x.XGetKeyboardMapping(self.handle, low.value, count, ctypes.byref(per))
        mapping, spare = {}, None
        try:
            for index in range(count):
                keycode = low.value + index
                row = [table[index * per.value + level] for level in range(per.value)]
                if not any(row) and spare is None and keycode > low.value + 8:
                    spare = keycode
                for level in (0, 1):
                    if level < len(row) and row[level] and row[level] not in mapping:
                        mapping[row[level]] = (keycode, level == 1)
        finally:
            self.x.XFree(ctypes.cast(table, ctypes.c_void_p))
        return mapping, spare

    def key(self, keycode, pressed):
        self.t.XTestFakeKeyEvent(self.handle, keycode, 1 if pressed else 0, 0)

    def keycode(self, keysym):
        keycode = self.x.XKeysymToKeycode(self.handle, keysym)
        if not keycode:
            raise HelperError(f"The keyboard layout has no key for keysym 0x{keysym:x}")
        return keycode

    def press_chord(self, chord):
        self.require_input()
        modifiers, keysym = parse_chord(chord)
        held = [self.keycode(modifier) for modifier in modifiers]
        mapping, _ = self.keymap()
        target, shifted = mapping.get(keysym, (None, False))
        if target is None:
            target = self.keycode(keysym)
        if shifted and SHIFT_L not in modifiers:
            held.append(self.keycode(SHIFT_L))
        for keycode in held:
            self.key(keycode, True)
        self.key(target, True)
        self.key(target, False)
        for keycode in reversed(held):
            self.key(keycode, False)
        self.flush()

    def type_text(self, text):
        """Types literal text. Characters missing from the layout are bound to a spare keycode for a moment."""
        self.require_input()
        mapping, spare = self.keymap()
        shift = self.keycode(SHIFT_L)
        for index, character in enumerate(text):
            keysym = char_to_keysym(character)
            if keysym is None:
                continue
            if keysym in mapping:
                keycode, shifted = mapping[keysym]
                if shifted:
                    self.key(shift, True)
                self.key(keycode, True)
                self.key(keycode, False)
                if shifted:
                    self.key(shift, False)
            elif spare is not None:
                symbols = (ctypes.c_ulong * 2)(keysym, keysym)
                self.x.XChangeKeyboardMapping(self.handle, spare, 2, symbols, 1)
                self.x.XSync(self.handle, 0)
                time.sleep(0.03)  # Clients apply MappingNotify before they see the key.
                self.key(spare, True)
                self.key(spare, False)
                self.x.XSync(self.handle, 0)
                time.sleep(0.03)
                empty = (ctypes.c_ulong * 2)(0, 0)
                self.x.XChangeKeyboardMapping(self.handle, spare, 2, empty, 1)
                self.x.XSync(self.handle, 0)
            else:
                raise HelperError(f"Cannot type {character!r}: no spare keycode in this layout")
            if index % 16 == 15:
                self.flush()
        self.flush()


# --------------------------------------------------------------------------------------------------
# Environment checks
# --------------------------------------------------------------------------------------------------

def mounted_share(mounts_path="/proc/mounts"):
    """True when terminal-linux's own virtio-fs share is mounted, i.e. we are inside its VM."""
    try:
        with open(mounts_path, encoding="utf-8", errors="replace") as mounts:
            return any(len(f) >= 3 and f[0] == SHARE_TAG and f[2] == "virtiofs" for f in (line.split() for line in mounts))
    except OSError:
        return False


def require_virtual_machine():
    if not sys.platform.startswith("linux"):
        raise HelperError("The guest helper only runs inside a terminal-linux VM")
    if not mounted_share():
        raise HelperError(f"The {SHARE_TAG} virtio-fs share is not mounted, so this is not a terminal-linux VM "
                          f"(or the share is not mounted yet: sudo mount -t virtiofs {SHARE_TAG} /mnt/terminal-linux)")


def live_session(cmdline_path="/proc/cmdline"):
    """Installer and 'try it' sessions boot with casper (Ubuntu) or live-boot (Debian)."""
    try:
        with open(cmdline_path, encoding="utf-8", errors="replace") as cmdline:
            words = cmdline.read().split()
    except OSError:
        return False
    return "boot=casper" in words or "boot=live" in words


def session_problem():
    if os.environ.get("XDG_SESSION_TYPE") == "wayland" or os.environ.get("WAYLAND_DISPLAY"):
        return "the desktop session is Wayland; log out and choose an X11 (Xorg) session"
    return None


_virtualization = None


def virtualization():
    global _virtualization
    if _virtualization is None:
        try:
            result = subprocess.run(["systemd-detect-virt", "--vm"], capture_output=True, text=True, timeout=3)
            _virtualization = result.stdout.strip() or "unknown"
        except (OSError, subprocess.SubprocessError):
            _virtualization = "unknown"
    return _virtualization


# --------------------------------------------------------------------------------------------------
# Request handling
# --------------------------------------------------------------------------------------------------

def loose_integer(raw, default):
    """For long-poll hints (since, wait) that never fail a request."""
    try:
        return int(raw)
    except (TypeError, ValueError):
        return default


def integer(arguments, key, low, high, default=None):
    raw = arguments.get(key)
    if raw is None and default is not None:
        return default
    try:
        value = int(raw)
    except (TypeError, ValueError):
        raise HelperError(f"Invalid {key}; expected {low}...{high}")
    if not low <= value <= high:
        raise HelperError(f"Invalid {key}; expected {low}...{high}")
    return value


class FrameStream:
    """Change-driven frames: a request waits up to `wait` ms until the screen differs from frame `since`."""

    def __init__(self):
        self.sequence = 0
        self.checksum = None
        self.latest = None

    def next(self, display, since, wait_seconds):
        deadline = time.monotonic() + wait_seconds
        while True:
            data, width, height, stride = display.capture()
            checksum = zlib.crc32(data)
            if checksum != self.checksum:
                self.checksum = checksum
                self.sequence += 1
                self.latest = (data, width, height, stride)
            if self.sequence != since:
                return self.sequence, self.latest
            if time.monotonic() >= deadline:
                return self.sequence, None
            time.sleep(0.05)


class Helper:
    def __init__(self, exchange):
        self.mailbox = Mailbox(exchange)
        self.input_display = None
        self.frame_display = None
        self.frames = FrameStream()
        self.frame_lock = threading.Lock()
        self.last_request = 0.0

    def display(self):
        if self.input_display is None:
            self.input_display = Display()
        return self.input_display

    def status(self):
        values = {"version": VERSION, "pid": os.getpid(), "live": str(live_session()).lower(),
                  "session": os.environ.get("XDG_SESSION_TYPE", "unknown"), "virtualization": virtualization(),
                  "capture": "false", "input": "false"}
        problem = session_problem()
        try:
            display = self.display()
            width, height = display.size
            values.update(width=width, height=height, input=str(display.has_xtest).lower(), screen=display.screen_state())
            if problem is None:
                display.capture(wake=False)
                values["capture"] = "true"
            if not display.has_xtest:
                problem = problem or "the X server has no XTest extension"
        except HelperError as error:
            problem = problem or str(error)
        if problem:
            values["problem"] = problem
        return values

    def coordinates(self, arguments, x="x", y="y"):
        width, height = self.display().size
        return integer(arguments, x, 0, width - 1), integer(arguments, y, 0, height - 1)

    def handle(self, request):
        action, arguments = request["action"], request["arguments"]
        values = {}
        if action == "status":
            values = self.status()
        elif action in ("screenshot", "snapshot") and arguments.get("format") in ("bgra-deflate", "bgra-lz4"):
            values = self.frame(request)
        elif action in ("screenshot", "snapshot"):
            problem = session_problem()
            if problem:
                raise HelperError(f"Cannot capture: {problem}")
            data, width, height, stride = self.display().capture()
            name = f"image-{request['id']}.png"
            self.mailbox.write(encode_png(data, width, height, stride), name)
            values = {"image": name, "width": width, "height": height}
        elif action == "move":
            self.display().move(*self.coordinates(arguments))
        elif action == "click":
            x, y = self.coordinates(arguments)
            number = 3 if arguments.get("button") == "right" else 1
            integer(arguments, "count", 1, 3, default=1)  # Validated; X11 counts clicks by their timing.
            self.display().click(x, y, number, 2 if arguments.get("double") == "true" else 1)
        elif action == "drag":
            self.display().drag(*self.coordinates(arguments), *self.coordinates(arguments, "x2", "y2"))
        elif action == "scroll":
            if "x" in arguments:
                self.display().move(*self.coordinates(arguments))
            self.display().scroll(integer(arguments, "dx", -1000, 1000, default=0), integer(arguments, "dy", -1000, 1000))
        elif action == "type":
            text = arguments.get("text")
            if not text or len(text.encode("utf-8")) > MAX_TEXT_BYTES:
                raise HelperError("Provide text (maximum 32 KiB)")
            self.display().type_text(text)
        elif action == "key":
            self.display().press_chord(arguments.get("key", ""))
        else:
            raise HelperError(f"Unknown guest action: {action}")
        return values

    def frame(self, request):
        """Live frames run on their own thread and X connection, so input never waits behind a long poll."""
        arguments = request["arguments"]
        integer(arguments, "maxWidth", 16, 7680, default=1280)
        integer(arguments, "maxHeight", 16, 4320, default=800)
        since = loose_integer(arguments.get("since"), -1)
        wait = min(1000, max(0, loose_integer(arguments.get("wait"), 0))) / 1000
        problem = session_problem()
        if problem:
            raise HelperError(f"Cannot capture: {problem}")
        with self.frame_lock:
            if self.frame_display is None:
                self.frame_display = Display()
            width, height = self.frame_display.size
            values = {"pointWidth": width, "pointHeight": height}
            sequence, frame = self.frames.next(self.frame_display, since, wait)
        if frame is None:
            values["unchanged"] = "true"
            return values
        data, width, height, stride = frame
        name = f"image-{request['id']}.bin"
        self.mailbox.write(deflate_raw(data), name)
        values.update(image=name, format="bgra-deflate", width=width, height=height, bytesPerRow=stride, sequence=sequence)
        return values

    def answer(self, request):
        try:
            values = self.handle(request)
            self.mailbox.respond(request["id"], values)
        except Exception as error:  # Every request gets a reply, so the host never waits for a timeout.
            message = str(error) if isinstance(error, HelperError) else f"{type(error).__name__}: {error}"
            if not isinstance(error, HelperError):
                log(f"{request['action']} failed: {message}")
            try:
                self.mailbox.respond(request["id"], error=message)
            except OSError as reply_error:
                log(f"Cannot reply to {request['id']}: {reply_error}")

    def run(self):
        log(f"terminal-linux helper {VERSION} serving {self.mailbox.path} (pid {os.getpid()})")
        while True:
            try:
                for request in self.mailbox.requests():
                    self.last_request = time.monotonic()
                    if request["action"] in ("screenshot", "snapshot") and request["arguments"].get("format"):
                        threading.Thread(target=self.answer, args=(request,), daemon=True).start()
                    else:
                        self.answer(request)
            except OSError as error:
                log(f"Mailbox error: {error}")
                time.sleep(1)
            # Poll quickly while a viewer or agent is active, and gently when idle.
            time.sleep(0.003 if time.monotonic() - self.last_request < 3 else 0.04)


# --------------------------------------------------------------------------------------------------
# Process management
# --------------------------------------------------------------------------------------------------

def single_instance(restart):
    """One helper per user: two would answer every request and type each key twice."""
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    path = os.path.join(STATE_DIR, "helper.lock")
    lock = open(path, "a+")
    for attempt in range(50):
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            lock.seek(0)
            lock.truncate()
            lock.write(str(os.getpid()))
            lock.flush()
            return lock
        except OSError as error:
            if error.errno not in (errno.EAGAIN, errno.EACCES):
                raise
            if not restart:
                raise HelperError("Another terminal-linux helper is already running. Use --restart to replace it.")
            if attempt == 0:
                lock.seek(0)
                try:
                    pid = int(lock.read().strip() or "0")
                    if pid > 1:
                        os.kill(pid, signal.SIGTERM)
                except (ValueError, ProcessLookupError, PermissionError):
                    pass
            time.sleep(0.1)
    raise HelperError("The previous helper did not exit")


def wait_for_exchange(path):
    announced = False
    while True:
        try:
            require_virtual_machine()
            if os.path.isdir(path):
                return
        except HelperError as error:
            if not announced:
                log(f"Waiting: {error}")
                announced = True
        time.sleep(2)


def main(argv=None):
    parser = argparse.ArgumentParser(description="terminal-linux guest helper (runs inside the VM)")
    parser.add_argument("--exchange", default=DEFAULT_EXCHANGE, help="mailbox directory shared by the host")
    parser.add_argument("--restart", action="store_true", help="replace a helper that is already running")
    parser.add_argument("--check", action="store_true", help="print status as JSON and exit")
    parser.add_argument("--version", action="version", version=f"terminal-linux helper {VERSION}")
    options = parser.parse_args(argv)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    try:
        if options.check:
            require_virtual_machine()
            helper = Helper(options.exchange)
            print(json.dumps(helper.status(), indent=2, sort_keys=True, default=str))
            return 0
        lock = single_instance(options.restart)
        wait_for_exchange(options.exchange)
        try:
            Helper(options.exchange).run()
        finally:
            lock.close()
    except HelperError as error:
        log(f"terminal-linux helper: {error}")
        return 1
    except KeyboardInterrupt:
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())

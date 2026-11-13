"""Offline tests for the guest helper: mailbox safety, request validation, encoders, key parsing and actions.

They use a fake display, so they run on macOS or Linux without an X server:
    python3 -I Tests/guest/test_helper.py -v
"""
import json
import os
import struct
import sys
import tempfile
import time
import unittest
import uuid
import zlib

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "guest"))
import terminal_linux_helper as helper  # noqa: E402


def swift_deadline(seconds_from_now):
    """A deadline as Swift's JSONEncoder writes Date: seconds since 2001-01-01."""
    return time.time() + seconds_from_now - helper.APPLE_EPOCH


def request_json(action="status", arguments=None, timeout=10, request_id=None):
    request_id = request_id or str(uuid.uuid4()).upper()
    return request_id, json.dumps({"id": request_id, "action": action, "arguments": arguments or {}, "deadline": swift_deadline(timeout)}).encode()


def frame(width, height, value=0):
    """BGRX pixels where every pixel is (blue=value, green=value+1, red=value+2, x=255)."""
    return bytes([value % 256, (value + 1) % 256, (value + 2) % 256, 255]) * (width * height)


class FakeDisplay:
    def __init__(self, width=64, height=32):
        self.width, self.height, self.has_xtest = width, height, True
        self.events, self.pixels, self.state = [], frame(width, height), "on"

    @property
    def size(self):
        return self.width, self.height

    def capture(self, wake=True):
        return self.pixels, self.width, self.height, self.width * 4

    def screen_state(self):
        return self.state

    def move(self, x, y): self.events.append(("move", x, y))
    def click(self, x, y, number=1, times=1): self.events.append(("click", x, y, number, times))
    def drag(self, *points): self.events.append(("drag",) + points)
    def scroll(self, dx, dy): self.events.append(("scroll", dx, dy))
    def type_text(self, text): self.events.append(("type", text))
    def press_chord(self, chord): helper.parse_chord(chord); self.events.append(("key", chord))


class TemporaryDirectory(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.mkdtemp(prefix="terminal-linux-test-")
        self.mailbox = helper.Mailbox(self.directory)

    def tearDown(self):
        self.mailbox.close()
        for name in os.listdir(self.directory):
            os.unlink(os.path.join(self.directory, name))
        os.rmdir(self.directory)

    def put(self, name, data):
        with open(os.path.join(self.directory, name), "wb") as file:
            file.write(data)


class MailboxTests(TemporaryDirectory):
    def test_write_is_atomic_readable_and_leaves_no_temporary_files(self):
        self.mailbox.write(b"hello", "reply-x.json")
        self.assertEqual(self.mailbox.read("reply-x.json"), b"hello")
        self.assertEqual(os.listdir(self.directory), ["reply-x.json"])

    def test_rejects_traversal_symlinks_hardlinks_fifos_and_oversized_files(self):
        secret = os.path.join(self.directory, "secret")
        self.put("secret", b"host file")
        os.symlink(secret, os.path.join(self.directory, "link"))
        os.link(secret, os.path.join(self.directory, "hardlink"))
        os.mkfifo(os.path.join(self.directory, "pipe"))
        for name in ("link", "hardlink", "pipe"):
            with self.assertRaises(helper.HelperError):
                self.mailbox.read(name)
        for name in ("../secret", "", ".", "..", "a/b"):
            with self.assertRaises(helper.HelperError):
                self.mailbox.read(name)
            with self.assertRaises(helper.HelperError):
                self.mailbox.write(b"", name)
        os.unlink(os.path.join(self.directory, "hardlink"))
        with self.assertRaises(helper.HelperError):
            self.mailbox.read("secret", limit=1)

    def test_publishing_replaces_symlink_instead_of_writing_its_target(self):
        target = os.path.join(self.directory, "target")
        self.put("target", b"untouched")
        os.symlink(target, os.path.join(self.directory, "reply.json"))
        self.mailbox.write(b"reply", "reply.json")
        with open(target, "rb") as file:
            self.assertEqual(file.read(), b"untouched")
        self.assertEqual(self.mailbox.read("reply.json"), b"reply")

    def test_valid_request_is_returned_and_removed(self):
        request_id, data = request_json("type", {"text": "hello 🌍"})
        self.put(f"request-{request_id}.json", data)
        requests = self.mailbox.requests()
        self.assertEqual(len(requests), 1)
        self.assertEqual(requests[0]["id"], request_id)
        self.assertEqual(requests[0]["arguments"]["text"], "hello 🌍")
        self.assertEqual(os.listdir(self.directory), [])

    def test_expired_mismatched_and_malformed_requests_are_discarded(self):
        expired_id, expired = request_json(timeout=-1)
        self.put(f"request-{expired_id}.json", expired)
        _, mismatched = request_json()
        self.put(f"request-{uuid.uuid4()}.json", mismatched)
        bad_id = str(uuid.uuid4())
        self.put(f"request-{bad_id}.json", json.dumps({"id": bad_id, "action": "click", "arguments": {"x": 1}, "deadline": swift_deadline(5)}).encode())
        boolean_id = str(uuid.uuid4())
        self.put(f"request-{boolean_id}.json", json.dumps({"id": boolean_id, "action": "status", "arguments": {}, "deadline": True}).encode())
        self.put(f"request-{uuid.uuid4()}.json", b"\xff not json")
        self.put("request-not-a-uuid.json", json.dumps({"id": "not-a-uuid", "action": "status", "arguments": {}, "deadline": swift_deadline(5)}).encode())
        self.assertEqual(self.mailbox.requests(), [])
        self.assertEqual(os.listdir(self.directory), [])

    def test_reply_matches_swift_reply_shape(self):
        self.mailbox.respond("ABC", {"width": 1280, "ok": True})
        self.mailbox.respond("DEF", error="boom")
        good = json.loads(self.mailbox.read("reply-ABC.json"))
        bad = json.loads(self.mailbox.read("reply-DEF.json"))
        self.assertEqual(good, {"id": "ABC", "ok": True, "values": {"width": "1280", "ok": "True"}})
        self.assertEqual(bad, {"id": "DEF", "ok": False, "values": {}, "error": "boom"})


class EncoderTests(unittest.TestCase):
    def test_png_is_valid_and_converts_bgrx_to_rgb(self):
        width, height, stride = 3, 2, 3 * 4 + 4  # Row padding must be skipped.
        pixels = b"".join(bytes([1, 2, 3, 0]) * width + b"\xee" * 4 for _ in range(height))
        png = helper.encode_png(pixels, width, height, stride)
        self.assertTrue(png.startswith(b"\x89PNG\r\n\x1a\n"))
        offset, chunks = 8, {}
        while offset < len(png):
            length, kind = struct.unpack(">I4s", png[offset:offset + 8])
            body = png[offset + 8: offset + 8 + length]
            crc, = struct.unpack(">I", png[offset + 8 + length: offset + 12 + length])
            self.assertEqual(crc, zlib.crc32(kind + body) & 0xFFFFFFFF)
            chunks[kind] = body
            offset += 12 + length
        self.assertEqual(struct.unpack(">IIBBBBB", chunks[b"IHDR"]), (3, 2, 8, 2, 0, 0, 0))
        self.assertEqual(zlib.decompress(chunks[b"IDAT"]), (b"\x00" + bytes([3, 2, 1]) * width) * height)
        self.assertIn(b"IEND", chunks)

    def test_raw_deflate_round_trips(self):
        data = frame(32, 16, 7)
        self.assertEqual(zlib.decompress(helper.deflate_raw(data), -15), data)


class KeyboardTests(unittest.TestCase):
    def test_characters_map_to_keysyms(self):
        self.assertEqual(helper.char_to_keysym("a"), 0x61)
        self.assertEqual(helper.char_to_keysym("é"), 0xE9)
        self.assertEqual(helper.char_to_keysym("€"), 0x010020AC)
        self.assertEqual(helper.char_to_keysym("🌍"), 0x0101F30D)
        self.assertEqual(helper.char_to_keysym("\n"), 0xFF0D)
        self.assertEqual(helper.char_to_keysym("\t"), 0xFF09)
        self.assertIsNone(helper.char_to_keysym("\x01"))
        self.assertIsNone(helper.char_to_keysym("\x9b"))  # C1 controls (CSI) are never typed.

    def test_chords(self):
        self.assertEqual(helper.parse_chord("ctrl+alt+t"), ([0xFFE3, 0xFFE9], 0x74))
        self.assertEqual(helper.parse_chord("cmd+c"), ([0xFFE3], 0x63))
        self.assertEqual(helper.parse_chord("super"), ([], 0xFFEB))
        self.assertEqual(helper.parse_chord("Shift+Tab"), ([0xFFE1], 0xFF09))
        self.assertEqual(helper.parse_chord("ctrl++"), ([0xFFE3], 0x2B))
        self.assertEqual(helper.parse_chord("f12"), ([], 0xFFC9))
        for bad in ("", "ctrl+", "hyper+a", "nosuchkey", "ctrl+nosuchkey"):
            with self.assertRaises(helper.HelperError):
                helper.parse_chord(bad)

    def test_scroll_pixels_become_wheel_notches(self):
        self.assertEqual(helper.scroll_clicks(0), 0)
        self.assertEqual(helper.scroll_clicks(10), 1)
        self.assertEqual(helper.scroll_clicks(-120), 2)
        self.assertEqual(helper.scroll_clicks(100000), 30)


class ScreenTests(unittest.TestCase):
    def test_screen_state_combines_screen_saver_and_dpms(self):
        self.assertEqual(helper.screen_state(False, True, 0), "on")
        self.assertEqual(helper.screen_state(True, True, 0), "blanked")
        self.assertEqual(helper.screen_state(False, True, 3), "off")
        self.assertEqual(helper.screen_state(None, True, 1), "standby")
        self.assertEqual(helper.screen_state(None, False, 3), "on")  # DPMS disabled: its level is stale.
        self.assertEqual(helper.screen_state(None, None, None), "unknown")

    def test_blank_heuristic(self):
        self.assertTrue(helper.looks_blank(bytes([0, 0, 0, 255]) * 100))
        self.assertTrue(helper.looks_blank(bytes(400)))
        self.assertFalse(helper.looks_blank(frame(10, 10, 40)))
        self.assertFalse(helper.looks_blank(b""))

    def display(self, state, first_frame):
        """A real Display whose X calls are replaced, to test capture's wake logic."""
        display = helper.Display.__new__(helper.Display)
        display.calls = []
        frames = [first_frame, frame(2, 2, 50)]
        display.screen_state = lambda: state
        display.wake = lambda: display.calls.append("wake")
        display.grab = lambda: (display.calls.append("grab"), (frames.pop(0), 2, 2, 8))[1]
        return display

    def test_capture_wakes_a_blanked_screen_first(self):
        display = self.display("blanked", frame(2, 2, 50))
        display.capture()
        self.assertEqual(display.calls, ["wake", "grab"])

    def test_capture_leaves_a_lit_screen_alone_and_status_never_wakes(self):
        display = self.display("on", bytes(16))
        display.capture()
        self.assertEqual(display.calls, ["grab"])
        display = self.display("off", bytes(16))
        display.capture(wake=False)
        self.assertEqual(display.calls, ["grab"])

    def test_unknown_state_falls_back_to_the_black_frame_heuristic(self):
        display = self.display("unknown", bytes(16))
        pixels, *_ = display.capture()
        self.assertEqual(display.calls, ["grab", "wake", "grab"])
        self.assertEqual(pixels, frame(2, 2, 50))


class EnvironmentTests(unittest.TestCase):
    def write(self, text):
        handle = tempfile.NamedTemporaryFile("w", delete=False)
        handle.write(text)
        handle.close()
        self.addCleanup(os.unlink, handle.name)
        return handle.name

    def test_vm_guard_requires_our_virtiofs_tag(self):
        self.assertTrue(helper.mounted_share(self.write("terminal-linux /mnt/terminal-linux virtiofs rw 0 0\n")))
        self.assertFalse(helper.mounted_share(self.write("other /mnt/x virtiofs rw 0 0\nterminal-linux /mnt/y nfs rw 0 0\n")))
        self.assertFalse(helper.mounted_share("/nonexistent/mounts"))

    def test_live_session_detection(self):
        self.assertTrue(helper.live_session(self.write("BOOT_IMAGE=/casper/vmlinuz boot=casper quiet splash")))
        self.assertTrue(helper.live_session(self.write("boot=live components")))
        self.assertFalse(helper.live_session(self.write("BOOT_IMAGE=/boot/vmlinuz root=UUID=1 ro quiet")))

    def test_wayland_is_reported(self):
        saved = {key: os.environ.get(key) for key in ("XDG_SESSION_TYPE", "WAYLAND_DISPLAY")}
        try:
            os.environ["XDG_SESSION_TYPE"] = "wayland"
            self.assertIn("Wayland", helper.session_problem())
            os.environ["XDG_SESSION_TYPE"] = "x11"
            os.environ.pop("WAYLAND_DISPLAY", None)
            self.assertIsNone(helper.session_problem())
        finally:
            for key, value in saved.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value


class HelperTests(TemporaryDirectory):
    def setUp(self):
        super().setUp()
        os.environ["XDG_SESSION_TYPE"] = "x11"
        os.environ.pop("WAYLAND_DISPLAY", None)
        self.helper = helper.Helper(self.directory)
        self.display = FakeDisplay()
        self.helper.input_display = self.display
        self.helper.frame_display = self.display

    def tearDown(self):
        self.helper.mailbox.close()
        super().tearDown()

    def call(self, action, arguments=None):
        request = {"id": str(uuid.uuid4()).upper(), "action": action, "arguments": arguments or {}, "deadline": time.time() + 5}
        self.helper.answer(request)
        reply = json.loads(self.mailbox.read(f"reply-{request['id']}.json"))
        self.mailbox.remove(f"reply-{request['id']}.json")
        return request["id"], reply

    def test_status_reports_capture_input_and_size(self):
        _, reply = self.call("status")
        self.assertTrue(reply["ok"])
        values = reply["values"]
        self.assertEqual((values["capture"], values["input"], values["width"], values["height"], values["screen"]), ("true", "true", "64", "32", "on"))
        self.assertNotIn("problem", values)

    def test_input_actions_reach_the_display_and_validate_bounds(self):
        self.assertTrue(self.call("click", {"x": "10", "y": "5", "button": "right"})[1]["ok"])
        self.assertTrue(self.call("click", {"x": "10", "y": "5", "double": "true"})[1]["ok"])
        self.assertTrue(self.call("drag", {"x": "1", "y": "2", "x2": "30", "y2": "20"})[1]["ok"])
        self.assertTrue(self.call("scroll", {"x": "5", "y": "5", "dy": "-120"})[1]["ok"])
        self.assertTrue(self.call("type", {"text": "héllo"})[1]["ok"])
        self.assertTrue(self.call("key", {"key": "ctrl+alt+t"})[1]["ok"])
        self.assertEqual(self.display.events, [
            ("click", 10, 5, 3, 1), ("click", 10, 5, 1, 2), ("drag", 1, 2, 30, 20),
            ("move", 5, 5), ("scroll", 0, -120), ("type", "héllo"), ("key", "ctrl+alt+t")])
        for action, arguments in (("click", {"x": "64", "y": "0"}), ("click", {"x": "-1", "y": "0"}), ("move", {"x": "a", "y": "1"}),
                                  ("scroll", {"dy": "5000"}), ("type", {"text": ""}), ("type", {"text": "x" * 40000}),
                                  ("key", {"key": "hyper+a"}), ("explode", {})):
            _, reply = self.call(action, arguments)
            self.assertFalse(reply["ok"], action)
            self.assertTrue(reply["error"])

    def test_screenshot_writes_png_named_after_request(self):
        request_id, reply = self.call("screenshot")
        self.assertTrue(reply["ok"])
        self.assertEqual(reply["values"]["image"], f"image-{request_id}.png")
        self.assertTrue(self.mailbox.read(reply["values"]["image"], 1 << 24).startswith(b"\x89PNG"))

    def test_frames_arrive_only_when_the_screen_changes(self):
        arguments = {"format": "bgra-deflate", "since": "-1", "wait": "0", "maxWidth": "1280", "maxHeight": "800"}
        _, first = self.call("screenshot", arguments)
        values = first["values"]
        self.assertEqual((values["format"], values["width"], values["height"], values["bytesPerRow"]), ("bgra-deflate", "64", "32", "256"))
        self.assertEqual(zlib.decompress(self.mailbox.read(values["image"], 1 << 24), -15), self.display.pixels)
        _, same = self.call("screenshot", dict(arguments, since=values["sequence"], wait="60"))
        self.assertEqual(same["values"].get("unchanged"), "true")
        self.display.pixels = frame(64, 32, 99)
        _, changed = self.call("screenshot", dict(arguments, since=values["sequence"]))
        self.assertEqual(int(changed["values"]["sequence"]), int(values["sequence"]) + 1)

    def test_wayland_blocks_capture_with_an_explanation(self):
        os.environ["XDG_SESSION_TYPE"] = "wayland"
        _, status = self.call("status")
        self.assertEqual(status["values"]["capture"], "false")
        self.assertIn("Wayland", status["values"]["problem"])
        _, shot = self.call("screenshot")
        self.assertFalse(shot["ok"])


if __name__ == "__main__":
    unittest.main()

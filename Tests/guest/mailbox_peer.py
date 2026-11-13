"""Answers mailbox requests with the real helper's Mailbox and encoders, for the Swift cross-language test.

    python3 -I mailbox_peer.py EXCHANGE COUNT

`echo` replies with its arguments. `frame` writes a 16×8 test frame as raw DEFLATE (image-<id>.bin) and PNG
(image-<id>.png). It exits after COUNT requests or 10 seconds.
"""
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "guest"))
import terminal_linux_helper as helper  # noqa: E402

WIDTH, HEIGHT = 16, 8


def test_frame():
    return b"".join(bytes([x * 8, y * 16, 200, 255]) for y in range(HEIGHT) for x in range(WIDTH))


def main():
    mailbox, remaining = helper.Mailbox(sys.argv[1]), int(sys.argv[2])
    deadline = time.time() + 10
    while remaining and time.time() < deadline:
        for request in mailbox.requests():
            remaining -= 1
            if request["action"] == "echo":
                mailbox.respond(request["id"], request["arguments"])
            elif request["action"] == "frame":
                pixels = test_frame()
                mailbox.write(helper.deflate_raw(pixels), f"image-{request['id']}.bin")
                mailbox.write(helper.encode_png(pixels, WIDTH, HEIGHT, WIDTH * 4), f"image-{request['id']}.png")
                mailbox.respond(request["id"], {"width": WIDTH, "height": HEIGHT, "bytesPerRow": WIDTH * 4})
            else:
                mailbox.respond(request["id"], error=f"unknown action {request['action']}")
        time.sleep(0.005)
    return 0 if remaining == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

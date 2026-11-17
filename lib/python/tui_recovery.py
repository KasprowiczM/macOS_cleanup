"""Foreground plain-terminal recovery after curses has restored its terminal.

The caller retains its TerminalJob while this function drains the existing PTY.
It never starts another operation, answers a question or releases a lease.
"""

import codecs
import os
import select
import sys
import termios
import time
import tty


class _DisplayFilter:
    """Strip terminal commands across chunks, retaining printable text only."""

    def __init__(self):
        self.state = "text"

    def feed(self, text):
        result = []
        for char in text:
            if self.state == "text":
                if char == "\033":
                    self.state = "escape"
                elif char == "\x9b":
                    self.state = "csi"
                elif char in ("\x90", "\x9d", "\x9e", "\x9f"):
                    self.state = "string"
                elif char.isprintable() or char in "\n\r\t":
                    result.append(char)
            elif self.state == "escape":
                if char == "[":
                    self.state = "csi"
                elif char in ("]", "P", "^", "_"):
                    self.state = "string"
                elif not " " <= char <= "/":
                    self.state = "text"
            elif self.state == "csi":
                if "@" <= char <= "~":
                    self.state = "text"
                elif char == "\033":
                    self.state = "escape"
            elif self.state == "string":
                if char in ("\a", "\x9c"):
                    self.state = "text"
                elif char == "\033":
                    self.state = "string_escape"
            elif char in ("\\", "\x9c"):
                self.state = "text"
            elif char != "\033":
                self.state = "string"
        return "".join(result)


def _write(stream, text):
    try:
        try:
            stream.write(text)
        except UnicodeEncodeError:
            encoding = getattr(stream, "encoding", None) or "utf-8"
            stream.write(text.encode(encoding, "backslashreplace").decode(encoding))
        stream.flush()
        return True
    except (OSError, ValueError, AttributeError):
        return False


def _terminal_fd(stream):
    try:
        fd = stream.fileno()
        return fd if stream.isatty() and os.isatty(fd) else None
    except (OSError, ValueError, AttributeError):
        return None


def continue_in_terminal(job, message, stream_in=None, stream_out=None):
    """Monitor the same worker and relay fresh explicit input without local echo.

    Call only after curses.wrapper has restored the original parent terminal.
    EOF or a missing terminal disables input; it never terminates the worker.
    A terminal hard close or process SIGKILL cannot be recovered by this helper.
    """
    stream_in = sys.stdin if stream_in is None else stream_in
    stream_out = sys.stdout if stream_out is None else stream_out
    output_ok = _write(stream_out, "\n" + _DisplayFilter().feed(str(message)) + "\n")
    input_fd = _terminal_fd(stream_in) if output_ok else None
    restore_fd, previous = input_fd, None
    decoder = codecs.getincrementaldecoder("utf-8")("replace")
    display = _DisplayFilter()
    broken_pty = False
    try:
        if input_fd is not None:
            try:
                previous = termios.tcgetattr(input_fd)
                # Discard keys queued for the failed UI. Raw mode prevents both
                # password echo and parent-side SIGINT from a typed Ctrl-C.
                tty.setraw(input_fd, when=termios.TCSAFLUSH)
            except (OSError, termios.error):
                input_fd = None
        while True:
            try:
                chunks = job.poll()
            except OSError:
                chunks, broken_pty = [], True
            for chunk in chunks:
                text = display.feed(chunk)
                if output_ok and text:
                    output_ok = _write(stream_out, text)
                    if not output_ok:
                        input_fd = None  # Never relay answers to invisible prompts.
            # Drain the PTY after primary exit too: a still-running owned helper
            # can retain its slave. Closing its master would otherwise send HUP.
            pty_open = not broken_pty and getattr(job, "_master", None) is not None
            if not job.running and not pty_open:
                break
            if input_fd is None:
                time.sleep(0.05)
                continue
            try:
                ready, _, _ = select.select([input_fd], [], [], 0.05)
                if not ready:
                    continue
                raw = os.read(input_fd, 4096)
                if not raw:
                    input_fd = None
                    continue
                answer = decoder.decode(raw)
                if answer:
                    job.send(answer)
            except (OSError, ValueError):
                input_fd = None
    finally:
        if previous is not None and restore_fd is not None:
            try:
                termios.tcsetattr(restore_fd, termios.TCSANOW, previous)
            except (OSError, termios.error):
                pass  # A disconnected input terminal cannot be restored.
    code = job.returncode
    return code if isinstance(code, int) else 1

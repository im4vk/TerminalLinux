import Testing
import TerminalUI

@Suite struct TerminalTextTests {
    @Test func untrustedControlsCannotReachTerminal() {
        let payload = "error \u{1b}[2J\u{1b}]52;c;AAAA\u{7}\u{9b}31m\r\n\t\u{7f}"
        let rendered = [Span(payload)].rendered
        #expect(!rendered.unicodeScalars.contains { $0.value < 0x20 || (0x7f...0x9f).contains($0.value) })
        #expect(rendered.contains("error"))
    }
    @Test func unicodeAndTrustedStylesArePreserved() {
        let text = "中文 café 🐈"
        #expect([Span(text)].rendered == text)
        #expect([Span(text, "\u{1b}[31m")].rendered == "\u{1b}[31m" + text + Theme.reset)
        #expect([Span("a\u{1b}b")].truncated(2).rendered == "a…")
    }
}

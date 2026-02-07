const prelude = @import("prelude.zig");
const std = prelude.std;
const tui = prelude.tui;
const protocol = prelude.protocol;
const Frame = prelude.Frame;
const render = prelude.render;
const renderer_mod = prelude.renderer_mod;
const testing_terminal = prelude.testing_terminal;
const input = prelude.input;
const unicode = prelude.unicode;
const state = prelude.state;
const tree = prelude.tree;
const scheduler_mod = prelude.scheduler_mod;
const mouse = prelude.mouse;
const style = prelude.style;
const markdown = prelude.markdown;
const hover = prelude.hover;
const keys = prelude.keys;
const kd = prelude.kd;
const termcaps = prelude.termcaps;
const clipboard = prelude.clipboard;
const runtime_ui = prelude.runtime_ui;
const pointer = prelude.pointer;

const cellByte = prelude.cellByte;
const cellText = prelude.cellText;
const keyEventMatchesNamed = prelude.keyEventMatchesNamed;

test "clipboard: OSC 52 encoding and wrappers" {
    var term = testing_terminal.Terminal.init(std.testing.allocator, .{ .rows = 10, .cols = 10 });
    defer term.deinit();

    const payload = "hello";
    const want_b64 = "aGVsbG8=";

    var caps: termcaps.Caps = .{};
    caps.ansi = true;
    caps.osc52 = true;

    term.reset();
    try clipboard.writeOsc52(&term, std.testing.allocator, caps, .{ .max_osc52_bytes = 1024 }, payload);
    try std.testing.expect(std.mem.indexOf(u8, term.out.items, "\x1b]52;c;") != null);
    try std.testing.expect(std.mem.indexOf(u8, term.out.items, want_b64) != null);

    caps.tmux = true;
    caps.screen = false;
    term.reset();
    try clipboard.writeOsc52(&term, std.testing.allocator, caps, .{ .max_osc52_bytes = 1024 }, payload);
    try std.testing.expect(std.mem.startsWith(u8, term.out.items, "\x1bPtmux;\x1b"));
    try std.testing.expect(std.mem.endsWith(u8, term.out.items, "\x1b\\"));

    caps.tmux = false;
    caps.screen = true;
    term.reset();
    try clipboard.writeOsc52(&term, std.testing.allocator, caps, .{ .max_osc52_bytes = 1024 }, payload);
    try std.testing.expect(std.mem.startsWith(u8, term.out.items, "\x1bP\x1b"));
    try std.testing.expect(std.mem.endsWith(u8, term.out.items, "\x1b\\"));
}

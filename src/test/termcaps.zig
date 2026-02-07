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

test "termcaps: dumb profile disables ANSI and forces mono" {
    var env = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer env.deinit();
    try env.put("TERM", "dumb");

    const caps = termcaps.detectCapsFromMap(&env, false, .truecolor);
    try std.testing.expect(!caps.ansi);
    try std.testing.expect(!caps.cursor_address);
    try std.testing.expectEqual(termcaps.ColorMode.mono, caps.color);
}

test "termcaps: disable list can force features off" {
    var env = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer env.deinit();
    try env.put("TERM", "xterm-256color");
    try env.put("TUI_CAPS_DISABLE", "mouse,osc52,altscreen");

    const caps = termcaps.detectCapsFromMap(&env, false, .ansi256);
    try std.testing.expect(!caps.mouse_sgr);
    try std.testing.expect(!caps.osc52);
    try std.testing.expect(!caps.alt_screen);
}

pub const std = @import("std");

pub const tui = @import("tui");
pub const protocol = tui.protocol;
pub const Frame = tui.frame.Frame;
pub const render = tui.render;
pub const renderer_mod = tui.renderer;
pub const input = tui.input;
pub const unicode = tui.unicode;
pub const state = tui.state;
pub const tree = tui.tree;
pub const scheduler_mod = tui.scheduler;
pub const mouse = tui.mouse;
pub const style = tui.style;
pub const markdown = tui.markdown;
pub const hover = tui.hover;
pub const keys = tui.keys;
pub const kd = tui.key_decode;
pub const termcaps = tui.termcaps;
pub const clipboard = tui.clipboard;
pub const testing_terminal = @import("testing_terminal.zig");
pub const runtime_ui = @import("runtime_ui");
pub const pointer = runtime_ui.pointer;

pub fn cellByte(frame: *const Frame, row: usize, col: usize) u8 {
    const c = frame.rowSlice(row)[col];
    if (c.len == 0) return ' ';
    return c.bytes[0];
}

pub fn cellText(frame: *const Frame, row: usize, col: usize) []const u8 {
    const c = &frame.rowSlice(row)[col];
    if (c.len == 0) return "";
    return c.slice();
}

pub fn keyEventMatchesNamed(ev: keys.KeyEvent, expected: keys.NamedKey) bool {
    return switch (ev.key) {
        .named => |k| k == expected,
        else => false,
    };
}

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

test "mouse: parse SGR move" {
    const ev = mouse.parseSgrMouseSequence("<32;10;5M") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(mouse.MouseEventKind.move, ev.kind);
    try std.testing.expectEqual(@as(usize, 9), ev.x);
    try std.testing.expectEqual(@as(usize, 4), ev.y);
    try std.testing.expectEqual(@as(u8, 0), ev.mods);
}

test "mouse: parse SGR press left/right/middle" {
    const left = mouse.parseSgrMouseSequence("\x1b[<0;10;5M") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(mouse.MouseEventKind.down, left.kind);
    try std.testing.expectEqual(mouse.MouseButton.left, left.button);
    try std.testing.expectEqual(@as(usize, 9), left.x);
    try std.testing.expectEqual(@as(usize, 4), left.y);

    const middle = mouse.parseSgrMouseSequence("<1;2;3M") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(mouse.MouseEventKind.down, middle.kind);
    try std.testing.expectEqual(mouse.MouseButton.middle, middle.button);
    try std.testing.expectEqual(@as(usize, 1), middle.x);
    try std.testing.expectEqual(@as(usize, 2), middle.y);

    const right = mouse.parseSgrMouseSequence("<2;2;3M") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(mouse.MouseEventKind.down, right.kind);
    try std.testing.expectEqual(mouse.MouseButton.right, right.button);
    try std.testing.expectEqual(@as(usize, 1), right.x);
    try std.testing.expectEqual(@as(usize, 2), right.y);
}

test "mouse: parse SGR release" {
    const up = mouse.parseSgrMouseSequence("<0;10;5m") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(mouse.MouseEventKind.up, up.kind);
    try std.testing.expectEqual(mouse.MouseButton.left, up.button);
    try std.testing.expectEqual(@as(usize, 9), up.x);
    try std.testing.expectEqual(@as(usize, 4), up.y);
}

test "mouse: parse SGR wheel up/down" {
    const up = mouse.parseSgrMouseSequence("\x1b[<64;10;5M") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(mouse.MouseEventKind.wheel, up.kind);
    try std.testing.expectEqual(@as(isize, 0), up.wheel_dx);
    try std.testing.expectEqual(@as(isize, -1), up.wheel_dy);
    try std.testing.expectEqual(@as(usize, 9), up.x);
    try std.testing.expectEqual(@as(usize, 4), up.y);

    const down = mouse.parseSgrMouseSequence("<65;1;1M") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(mouse.MouseEventKind.wheel, down.kind);
    try std.testing.expectEqual(@as(isize, 0), down.wheel_dx);
    try std.testing.expectEqual(@as(isize, 1), down.wheel_dy);
    try std.testing.expectEqual(@as(usize, 0), down.x);
    try std.testing.expectEqual(@as(usize, 0), down.y);
}

test "mouse: parse SGR modifiers" {
    // shift modifier bit (4) should be preserved.
    const ev = mouse.parseSgrMouseSequence("<4;2;3M") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(mouse.MouseEventKind.down, ev.kind);
    try std.testing.expectEqual(mouse.MouseButton.left, ev.button);
    try std.testing.expectEqual(@as(u8, 1), ev.mods);
    try std.testing.expectEqual(@as(usize, 1), ev.x);
    try std.testing.expectEqual(@as(usize, 2), ev.y);

    // shift+alt+ctrl (4+8+16) => 1+2+4 = 7.
    const ev2 = mouse.parseSgrMouseSequence("<28;2;3M") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(mouse.MouseEventKind.down, ev2.kind);
    try std.testing.expectEqual(mouse.MouseButton.left, ev2.button);
    try std.testing.expectEqual(@as(u8, 7), ev2.mods);
}

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

test "state: scrollIntoView brings offscreen node into viewport" {
    var child_children: [10]protocol.Node = undefined;
    for (0..9) |i| {
        child_children[i] = .{ .text = .{ .id = "t", .text = "x" } };
    }
    child_children[9] = .{ .input = .{ .id = "deep", .placeholder = "p" } };

    const child = protocol.Node{ .vbox = .{ .id = "child", .children = child_children[0..] } };

    const viewport_h: usize = 2;
    const width: usize = 10;
    const content_h: usize = render.measureContentHeight(child, width);
    const range = render.findContentYRangeForId(child, width, "deep") orelse return error.TestUnexpectedResult;
    const next = state.scrollIntoView(0, viewport_h, range.y, range.y + range.h, content_h);
    try std.testing.expectEqual(@as(usize, 8), next);
}

test "state: clamp list scroll keeps selection visible" {
    try std.testing.expectEqual(@as(usize, 0), state.clampListScroll(0, null, 5, 20));
    try std.testing.expectEqual(@as(usize, 8), state.clampListScroll(0, 12, 5, 20));
    try std.testing.expectEqual(@as(usize, 12), state.clampListScroll(15, 12, 5, 20));
    try std.testing.expectEqual(@as(usize, 15), state.clampListScroll(999, 19, 5, 20));
    try std.testing.expectEqual(@as(usize, 0), state.clampListScroll(3, 0, 5, 20));
}

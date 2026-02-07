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

test "style: inheritance applies fg to text cells" {
    var frame: Frame = .{};
    defer frame.deinit(std.testing.allocator);
    try frame.resize(std.testing.allocator, 1, 5);
    frame.clear(' ');

    const red: style.StyleOverride = .{ .fg = .{ .rgb = .{ .r = 255, .g = 0, .b = 0 } } };
    var children = [_]protocol.Node{
        .{ .text = .{ .id = "t", .text = "X" } },
    };
    const root = protocol.Node{ .vbox = .{ .id = "root", .style = red, .children = children[0..] } };

    render.renderToFrame(root, .{}, &frame);

    const cell = frame.rowSlice(0)[0];
    try std.testing.expectEqual(@as(u1, 1), cell.style.has_fg);
    try std.testing.expectEqual(@as(u24, 0xff0000), cell.style.fg);
}

test "style: bg fill makes row_max nonzero" {
    var frame: Frame = .{};
    defer frame.deinit(std.testing.allocator);
    try frame.resize(std.testing.allocator, 1, 5);
    frame.clear(' ');

    const bg: style.StyleOverride = .{ .bg = .{ .rgb = .{ .r = 0, .g = 0, .b = 255 } } };
    const root = protocol.Node{ .vbox = .{ .id = "root", .style = bg, .children = &.{} } };

    render.renderToFrame(root, .{}, &frame);
    frame.recomputeRowMax();

    try std.testing.expectEqual(@as(u16, 5), frame.row_max[0]);
    const cell = frame.rowSlice(0)[4];
    try std.testing.expectEqual(@as(u1, 1), cell.style.has_bg);
}

test "style: styled_text span overrides fg on subset" {
    var frame: Frame = .{};
    defer frame.deinit(std.testing.allocator);
    try frame.resize(std.testing.allocator, 1, 2);
    frame.clear(' ');

    const red: style.StyleOverride = .{ .fg = .{ .rgb = .{ .r = 255, .g = 0, .b = 0 } } };
    const green: style.StyleOverride = .{ .fg = .{ .rgb = .{ .r = 0, .g = 255, .b = 0 } } };

    var spans = [_]protocol.Span{
        .{ .text = "A" },
        .{ .text = "B", .style = green },
    };
    var children = [_]protocol.Node{
        .{ .styled_text = .{ .id = "st", .spans = spans[0..] } },
    };
    const root = protocol.Node{ .vbox = .{ .id = "root", .style = red, .children = children[0..] } };

    render.renderToFrame(root, .{}, &frame);

    const a = frame.rowSlice(0)[0];
    try std.testing.expectEqual(@as(u1, 1), a.style.has_fg);
    try std.testing.expectEqual(@as(u24, 0xff0000), a.style.fg);

    const b = frame.rowSlice(0)[1];
    try std.testing.expectEqual(@as(u1, 1), b.style.has_fg);
    try std.testing.expectEqual(@as(u24, 0x00ff00), b.style.fg);
}

test "style: wide styled_text span applies to both cells" {
    var frame: Frame = .{};
    defer frame.deinit(std.testing.allocator);
    try frame.resize(std.testing.allocator, 1, 2);
    frame.clear(' ');

    const green: style.StyleOverride = .{ .fg = .{ .rgb = .{ .r = 0, .g = 255, .b = 0 } } };
    var spans = [_]protocol.Span{
        .{ .text = "漢", .style = green },
    };
    const root = protocol.Node{ .styled_text = .{ .id = "t", .spans = spans[0..] } };

    render.renderToFrame(root, .{}, &frame);

    const left = frame.rowSlice(0)[0];
    const right = frame.rowSlice(0)[1];
    try std.testing.expectEqual(@as(u2, 2), left.width);
    try std.testing.expect(!left.continuation);
    try std.testing.expect(right.continuation);
    try std.testing.expectEqual(@as(u1, 1), left.style.has_fg);
    try std.testing.expectEqual(@as(u1, 1), right.style.has_fg);
    try std.testing.expectEqual(@as(u24, 0x00ff00), left.style.fg);
    try std.testing.expectEqual(@as(u24, 0x00ff00), right.style.fg);
}

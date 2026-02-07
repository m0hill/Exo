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

test "layout: padding offsets child origin" {
    var frame: Frame = .{};
    defer frame.deinit(std.testing.allocator);
    try frame.resize(std.testing.allocator, 3, 5);
    frame.clear(' ');

    var children = [_]protocol.Node{
        .{ .text = .{ .id = "t", .text = "X" } },
    };
    const root = protocol.Node{ .vbox = .{ .id = "root", .pad = 1, .children = children[0..] } };

    render.renderToFrame(root, .{}, &frame);

    try std.testing.expectEqual(@as(u8, 'X'), cellByte(&frame, 1, 1));
}

test "layout: hbox fixed width + flex places siblings" {
    var frame: Frame = .{};
    defer frame.deinit(std.testing.allocator);
    try frame.resize(std.testing.allocator, 3, 30);
    frame.clear(' ');

    var children = [_]protocol.Node{
        .{ .text = .{ .id = "left", .w = 10, .text = "L" } },
        .{ .text = .{ .id = "right", .flex = 1, .text = "R" } },
    };
    const root = protocol.Node{ .hbox = .{ .id = "root", .pad = 1, .children = children[0..] } };

    render.renderToFrame(root, .{}, &frame);

    try std.testing.expectEqual(@as(u8, 'L'), cellByte(&frame, 1, 1));
    // pad=1 => inner.x=1. left.w=10 => right.x=11 (0-based), i.e. column 12 (1-based).
    try std.testing.expectEqual(@as(u8, 'R'), cellByte(&frame, 1, 11));
}

test "layout: clipping prevents hbox child bleed" {
    var frame: Frame = .{};
    defer frame.deinit(std.testing.allocator);
    try frame.resize(std.testing.allocator, 1, 20);
    frame.clear(' ');

    var children = [_]protocol.Node{
        .{ .text = .{ .id = "left", .w = 10, .text = "AAAAAAAAAAAAAAA" } },
        .{ .text = .{ .id = "right", .w = 10, .text = "B" } },
    };
    const root = protocol.Node{ .hbox = .{ .id = "root", .children = children[0..] } };

    render.renderToFrame(root, .{}, &frame);

    try std.testing.expectEqual(@as(u8, 'B'), cellByte(&frame, 0, 10));
    try std.testing.expectEqual(@as(u8, ' '), cellByte(&frame, 0, 11));
    try std.testing.expectEqual(@as(u8, ' '), cellByte(&frame, 0, 19));
}

test "layout: vbox gap offsets siblings" {
    var children = [_]protocol.Node{
        .{ .text = .{ .id = "a", .text = "A" } },
        .{ .text = .{ .id = "b", .text = "B" } },
    };
    const root = protocol.Node{ .vbox = .{ .id = "root", .gap = 1, .children = children[0..] } };
    const r = render.findRectForId(root, 10, 10, "b") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), r.y);
}

test "layout: vbox justify_content center offsets start" {
    var children = [_]protocol.Node{
        .{ .text = .{ .id = "a", .h = 1, .text = "A" } },
    };
    const root = protocol.Node{ .vbox = .{ .id = "root", .justify_content = .center, .children = children[0..] } };
    const r = render.findRectForId(root, 5, 10, "a") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), r.y);
}

test "layout: vbox align_self centers fixed-width child" {
    var children = [_]protocol.Node{
        .{ .text = .{ .id = "a", .w = 4, .align_self = .center, .text = "A" } },
    };
    const root = protocol.Node{ .vbox = .{ .id = "root", .children = children[0..] } };
    const r = render.findRectForId(root, 3, 10, "a") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 3), r.x);
    try std.testing.expectEqual(@as(usize, 4), r.w);
}

test "layout: hbox gap offsets siblings" {
    var children = [_]protocol.Node{
        .{ .text = .{ .id = "a", .w = 2, .text = "AA" } },
        .{ .text = .{ .id = "b", .w = 2, .text = "BB" } },
    };
    const root = protocol.Node{ .hbox = .{ .id = "root", .gap = 1, .children = children[0..] } };
    const r = render.findRectForId(root, 1, 10, "b") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 3), r.x);
}

test "layout: hbox justify_content end offsets start" {
    var children = [_]protocol.Node{
        .{ .text = .{ .id = "a", .w = 2, .text = "AA" } },
        .{ .text = .{ .id = "b", .w = 2, .text = "BB" } },
    };
    const root = protocol.Node{ .hbox = .{ .id = "root", .justify_content = .end, .children = children[0..] } };
    const r = render.findRectForId(root, 1, 10, "a") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 6), r.x);
}

test "layout: hbox align_items end places short child at bottom" {
    var children = [_]protocol.Node{
        .{ .text = .{ .id = "a", .w = 1, .h = 1, .text = "A" } },
    };
    const root = protocol.Node{ .hbox = .{ .id = "root", .align_items = .end, .children = children[0..] } };
    const r = render.findRectForId(root, 3, 5, "a") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), r.y);
    try std.testing.expectEqual(@as(usize, 1), r.h);
}

test "layout: hbox justify space_between distributes extra" {
    var children = [_]protocol.Node{
        .{ .text = .{ .id = "a", .w = 1, .text = "A" } },
        .{ .text = .{ .id = "b", .w = 1, .text = "B" } },
        .{ .text = .{ .id = "c", .w = 1, .text = "C" } },
    };
    const root = protocol.Node{ .hbox = .{ .id = "root", .justify_content = .space_between, .children = children[0..] } };
    const r = render.findRectForId(root, 1, 7, "c") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 6), r.x);
}

test "layout: box adds height for border + pad" {
    var frame: Frame = .{};
    defer frame.deinit(std.testing.allocator);
    try frame.resize(std.testing.allocator, 6, 10);
    frame.clear(' ');

    var box_child = protocol.Node{ .text = .{ .id = "x", .text = "X" } };
    const y = protocol.Node{ .text = .{ .id = "y", .text = "Y" } };
    var children = [_]protocol.Node{
        .{ .box = .{ .id = "b", .pad = 1, .child = &box_child } },
        y,
    };
    const root = protocol.Node{ .vbox = .{ .id = "root", .children = children[0..] } };

    render.renderToFrame(root, .{}, &frame);

    try std.testing.expectEqual(@as(u8, 'Y'), cellByte(&frame, 5, 0));
}

test "layout: box shadow does not affect layout" {
    var frame: Frame = .{};
    defer frame.deinit(std.testing.allocator);
    try frame.resize(std.testing.allocator, 6, 10);
    frame.clear(' ');

    var box_child = protocol.Node{ .text = .{ .id = "x", .text = "X" } };
    const y = protocol.Node{ .text = .{ .id = "y", .text = "Y" } };
    var children = [_]protocol.Node{
        .{ .box = .{ .id = "b", .pad = 1, .shadow = true, .child = &box_child } },
        y,
    };
    const root = protocol.Node{ .vbox = .{ .id = "root", .children = children[0..] } };

    render.renderToFrame(root, .{}, &frame);

    try std.testing.expectEqual(@as(u8, 'Y'), cellByte(&frame, 5, 0));
}

test "layout: overlay layers do not affect base layout height" {
    var base_children = [_]protocol.Node{
        .{ .text = .{ .id = "base-text", .text = "A" } },
    };
    var base = protocol.Node{ .vbox = .{ .id = "base", .children = base_children[0..] } };

    var layer_children = [_]protocol.Node{
        .{ .text = .{ .id = "l1", .text = "L1" } },
        .{ .text = .{ .id = "l2", .text = "L2" } },
        .{ .text = .{ .id = "l3", .text = "L3" } },
    };
    var layer_node = protocol.Node{ .vbox = .{ .id = "layer", .children = layer_children[0..] } };
    var layers = [_]protocol.OverlayLayer{
        .{ .node = &layer_node, .placement = .center, .w = 10 },
    };
    const ov = protocol.Node{ .overlay = .{ .id = "ov", .base = &base, .layers = layers[0..] } };

    var root_children = [_]protocol.Node{
        ov,
        .{ .text = .{ .id = "below", .text = "X" } },
    };
    const root = protocol.Node{ .vbox = .{ .id = "root", .children = root_children[0..] } };

    const r = render.findRectForId(root, 10, 10, "below") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), r.y);
}

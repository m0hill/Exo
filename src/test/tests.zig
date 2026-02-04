const std = @import("std");

const tui = @import("tui");
const protocol = tui.protocol;
const Frame = tui.frame.Frame;
const render = tui.render;
const renderer_mod = tui.renderer;
const testing_terminal = @import("testing_terminal.zig");
const input = tui.input;
const unicode = tui.unicode;
const state = tui.state;
const tree = tui.tree;
const scheduler_mod = tui.scheduler;
const mouse = tui.mouse;
const style = tui.style;
const markdown = tui.markdown;

fn cellByte(frame: *const Frame, row: usize, col: usize) u8 {
    const c = frame.rowSlice(row)[col];
    if (c.len == 0) return ' ';
    return c.bytes[0];
}

fn cellText(frame: *const Frame, row: usize, col: usize) []const u8 {
    const c = &frame.rowSlice(row)[col];
    if (c.len == 0) return "";
    return c.slice();
}

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

test "render: focused input shows cursor + placeholder" {
    var term = testing_terminal.Terminal.init(std.testing.allocator, .{ .rows = 10, .cols = 80 });
    defer term.deinit();

    var renderer = renderer_mod.Renderer.init(std.testing.allocator);
    defer renderer.deinit();

    var children = [_]protocol.Node{
        .{ .text = .{ .id = "title", .text = "Tracer Demo" } },
        .{ .text = .{ .id = "hint", .text = "Tab to focus input" } },
        .{ .text = .{ .id = "clock", .text = "Tick: 0" } },
        .{ .input = .{ .id = "query", .placeholder = "Type here" } },
        .{ .text = .{ .id = "status", .text = "State: OFF" } },
    };
    const root = protocol.Node{ .vbox = .{ .id = "root", .children = children[0..] } };

    try renderer.draw(&term, root, .{
        .focused_id = "query",
        .inputs = &.{.{ .id = "query", .value = "", .cursor = 0, .scroll_x = 0 }},
    });

    const out = term.out.items;
    try std.testing.expect(std.mem.indexOf(u8, out, "Tracer Demo") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "> Type here") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[?25h") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[4;3H") != null);
}

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

test "protocol: parse styled_text spans" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const line =
        "{\"type\":\"patch\",\"root\":{\"type\":\"styled_text\",\"id\":\"t\",\"spans\":[" ++ "{\"text\":\"A\"}," ++ "{\"text\":\"B\",\"style\":{\"fg\":\"#00ff00\"}}," ++ "{\"text\":\"C\",\"style\":{\"fg\":null}}" ++ "]}}";

    const msg = try protocol.parseMsgLeaky(arena.allocator(), line);
    const root = switch (msg) {
        .patch => |p| switch (p) {
            .full => |f| f.root,
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    };

    const st = switch (root) {
        .styled_text => |t| t,
        else => return error.TestUnexpectedResult,
    };

    try std.testing.expectEqualStrings("t", st.id);
    try std.testing.expectEqual(@as(usize, 3), st.spans.len);
    try std.testing.expectEqualStrings("A", st.spans[0].text);

    const b_style = st.spans[1].style orelse return error.TestUnexpectedResult;
    const b_rgb = switch (b_style.fg) {
        .rgb => |c| c,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(u8, 0), b_rgb.r);
    try std.testing.expectEqual(@as(u8, 255), b_rgb.g);
    try std.testing.expectEqual(@as(u8, 0), b_rgb.b);

    const c_style = st.spans[2].style orelse return error.TestUnexpectedResult;
    try std.testing.expect(c_style.fg == .clear);
}

test "protocol: parse scroll node + scroll event" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const line =
        "{\"type\":\"patch\",\"root\":{\"type\":\"scroll\",\"id\":\"sv\",\"child\":{\"type\":\"text\",\"id\":\"t\",\"text\":\"hi\"}}}";

    const msg = try protocol.parseMsgLeaky(arena.allocator(), line);
    const root = switch (msg) {
        .patch => |p| switch (p) {
            .full => |f| f.root,
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    };

    const sv = switch (root) {
        .scroll => |s| s,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("sv", sv.id);
    try std.testing.expect(sv.clip);
    const child = sv.child.*;
    try std.testing.expectEqualStrings("t", child.text.id);
    try std.testing.expectEqualStrings("hi", child.text.text);

    const ev_line = "{\"type\":\"event\",\"name\":\"scroll\",\"id\":\"sv\",\"scroll_y\":42}";
    const ev_msg = try protocol.parseMsgLeaky(arena.allocator(), ev_line);
    switch (ev_msg) {
        .event => |ev| switch (ev) {
            .scroll => |s| {
                try std.testing.expectEqualStrings("sv", s.id);
                try std.testing.expectEqual(@as(usize, 42), s.scroll_y);
            },
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

test "protocol: parse overlay node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const line =
        "{\"type\":\"patch\",\"root\":{\"type\":\"overlay\",\"id\":\"root\",\"base\":{\"type\":\"vbox\",\"id\":\"base\",\"children\":[{\"type\":\"text\",\"id\":\"a\",\"text\":\"A\"}]},\"layers\":[{\"node\":{\"type\":\"text\",\"id\":\"tip\",\"text\":\"T\"},\"anchor\":\"a\",\"placement\":\"below\",\"align\":\"center\",\"offset_x\":1,\"offset_y\":-2,\"w\":10,\"modal\":true}]}}";

    const msg = try protocol.parseMsgLeaky(arena.allocator(), line);
    const root = switch (msg) {
        .patch => |p| switch (p) {
            .full => |f| f.root,
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    };

    const ov = switch (root) {
        .overlay => |o| o,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("root", ov.id);
    try std.testing.expectEqualStrings("base", ov.base.*.vbox.id);
    try std.testing.expectEqual(@as(usize, 1), ov.layers.len);

    const layer = ov.layers[0];
    try std.testing.expectEqualStrings("a", layer.anchor orelse "");
    try std.testing.expectEqual(protocol.OverlayPlacement.below, layer.placement);
    try std.testing.expectEqual(protocol.OverlayAlign.center, layer.align_);
    try std.testing.expectEqual(@as(isize, 1), layer.offset_x);
    try std.testing.expectEqual(@as(isize, -2), layer.offset_y);
    try std.testing.expectEqual(@as(?usize, 10), layer.w);
    try std.testing.expect(layer.modal);
}

test "protocol: parse box node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const line =
        "{\"type\":\"patch\",\"root\":{\"type\":\"box\",\"id\":\"b\",\"child\":{\"type\":\"text\",\"id\":\"t\",\"text\":\"hi\"}}}";

    const msg = try protocol.parseMsgLeaky(arena.allocator(), line);
    const root = switch (msg) {
        .patch => |p| switch (p) {
            .full => |f| f.root,
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    };

    const b = switch (root) {
        .box => |bb| bb,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("b", b.id);
    try std.testing.expect(b.border);
    try std.testing.expect(b.clip);
    try std.testing.expect(!b.shadow);
    try std.testing.expectEqual(@as(usize, 0), b.pad);
    try std.testing.expect(b.title == null);
    try std.testing.expectEqualStrings("t", b.child.*.text.id);
}

test "render: box draws border" {
    var frame: Frame = .{};
    defer frame.deinit(std.testing.allocator);
    try frame.resize(std.testing.allocator, 3, 5);
    frame.clear(' ');

    var child = protocol.Node{ .text = .{ .id = "t", .text = "" } };
    const root = protocol.Node{ .box = .{ .id = "b", .child = &child } };

    render.renderToFrame(root, .{}, &frame);

    try std.testing.expectEqualStrings("┌", cellText(&frame, 0, 0));
    try std.testing.expectEqualStrings("─", cellText(&frame, 0, 1));
    try std.testing.expectEqualStrings("┐", cellText(&frame, 0, 4));
    try std.testing.expectEqualStrings("│", cellText(&frame, 1, 0));
    try std.testing.expectEqualStrings("│", cellText(&frame, 1, 4));
    try std.testing.expectEqualStrings("└", cellText(&frame, 2, 0));
    try std.testing.expectEqualStrings("─", cellText(&frame, 2, 1));
    try std.testing.expectEqualStrings("┘", cellText(&frame, 2, 4));
}

test "render: box title truncates to inner width" {
    var frame: Frame = .{};
    defer frame.deinit(std.testing.allocator);
    try frame.resize(std.testing.allocator, 3, 8);
    frame.clear(' ');

    var child = protocol.Node{ .text = .{ .id = "t", .text = "" } };
    const root = protocol.Node{ .box = .{ .id = "b", .title = "HelloWorld", .child = &child } };

    render.renderToFrame(root, .{}, &frame);

    try std.testing.expectEqualStrings("┌", cellText(&frame, 0, 0));
    try std.testing.expectEqualStrings("┐", cellText(&frame, 0, 7));
    // inner width is 6: " " + "HelloWorld" + " " truncates to " Hello"
    try std.testing.expectEqual(@as(u8, 'H'), cellByte(&frame, 0, 2));
    try std.testing.expectEqual(@as(u8, 'o'), cellByte(&frame, 0, 6));
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

test "render: box shadow dims underlying cells" {
    var frame: Frame = .{};
    defer frame.deinit(std.testing.allocator);
    try frame.resize(std.testing.allocator, 6, 10);
    frame.clear(' ');

    var base = protocol.Node{ .text = .{ .id = "bg", .text = "AAAAAAAAAA\nBBBBBBBBBB\nCCCCCCCCCC\nDDDDDDDDDD\nEEEEEEEEEE\nFFFFFFFFFF" } };
    var inner = protocol.Node{ .text = .{ .id = "t", .text = "" } };
    var box = protocol.Node{ .box = .{ .id = "bx", .shadow = true, .child = &inner } };
    var layers = [_]protocol.OverlayLayer{
        .{ .node = &box, .placement = .center, .w = 4, .h = 3 },
    };
    const root = protocol.Node{ .overlay = .{ .id = "ov", .base = &base, .layers = layers[0..] } };

    render.renderToFrame(root, .{}, &frame);

    // Center placement for 10x6 with w=4 h=3 => (x,y)=(3,1).
    // Bottom shadow row is y+h=4, cols x+1..x+w => cols 4..7.
    try std.testing.expectEqual(@as(u8, ' '), cellByte(&frame, 4, 7));
    const cell = frame.rowSlice(4)[7];
    try std.testing.expect((cell.style.attrs & style.ATTR_DIM) != 0);
}

test "render: scroll viewport shifts visible content" {
    var frame: Frame = .{};
    defer frame.deinit(std.testing.allocator);
    try frame.resize(std.testing.allocator, 2, 4);
    frame.clear(' ');

    var child_children = [_]protocol.Node{
        .{ .text = .{ .id = "a", .text = "A" } },
        .{ .text = .{ .id = "b", .text = "B" } },
        .{ .text = .{ .id = "c", .text = "C" } },
        .{ .text = .{ .id = "d", .text = "D" } },
    };
    var child = protocol.Node{ .vbox = .{ .id = "child", .children = child_children[0..] } };
    const root = protocol.Node{ .scroll = .{ .id = "sv", .child = &child } };

    render.renderToFrame(root, .{
        .scrolls = &.{.{ .id = "sv", .scroll_y = 0, .content_h = 4, .viewport_h = 2 }},
    }, &frame);
    try std.testing.expectEqual(@as(u8, 'A'), cellByte(&frame, 0, 0));
    try std.testing.expectEqual(@as(u8, 'B'), cellByte(&frame, 1, 0));

    frame.clear(' ');
    render.renderToFrame(root, .{
        .scrolls = &.{.{ .id = "sv", .scroll_y = 2, .content_h = 4, .viewport_h = 2 }},
    }, &frame);
    try std.testing.expectEqual(@as(u8, 'C'), cellByte(&frame, 0, 0));
    try std.testing.expectEqual(@as(u8, 'D'), cellByte(&frame, 1, 0));
}

test "render: overlay paints above base" {
    var frame: Frame = .{};
    defer frame.deinit(std.testing.allocator);
    try frame.resize(std.testing.allocator, 1, 1);
    frame.clear(' ');

    var base_children = [_]protocol.Node{
        .{ .text = .{ .id = "a", .text = "A" } },
    };
    var base = protocol.Node{ .vbox = .{ .id = "base", .children = base_children[0..] } };

    var layer_node = protocol.Node{ .text = .{ .id = "b", .text = "B" } };
    var layers = [_]protocol.OverlayLayer{
        .{ .node = &layer_node, .placement = .center, .w = 1 },
    };
    const root = protocol.Node{ .overlay = .{ .id = "root", .base = &base, .layers = layers[0..] } };

    render.renderToFrame(root, .{}, &frame);
    try std.testing.expectEqual(@as(u8, 'B'), cellByte(&frame, 0, 0));
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

test "render.findRectForId: overlay anchored below computes expected rect" {
    var base_children = [_]protocol.Node{
        .{ .text = .{ .id = "anchor", .text = "A" } },
    };
    var base = protocol.Node{ .vbox = .{ .id = "base", .children = base_children[0..] } };

    var layer_node = protocol.Node{ .text = .{ .id = "layer", .text = "B" } };
    var layers = [_]protocol.OverlayLayer{
        .{ .node = &layer_node, .anchor = "anchor", .placement = .below, .w = 4 },
    };
    const root = protocol.Node{ .overlay = .{ .id = "root", .base = &base, .layers = layers[0..] } };

    const r = render.findRectForId(root, 5, 10, "layer") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), r.x);
    try std.testing.expectEqual(@as(usize, 1), r.y);
    try std.testing.expectEqual(@as(usize, 4), r.w);
    try std.testing.expectEqual(@as(usize, 1), r.h);
}

test "render: cursor respects scroll_y for focused input" {
    var frame: Frame = .{};
    defer frame.deinit(std.testing.allocator);
    try frame.resize(std.testing.allocator, 2, 10);
    frame.clear(' ');

    var children = [_]protocol.Node{
        .{ .text = .{ .id = "t0", .text = "A" } },
        .{ .input = .{ .id = "i", .placeholder = "p" } },
        .{ .text = .{ .id = "t2", .text = "C" } },
    };
    var child = protocol.Node{ .vbox = .{ .id = "child", .children = children[0..] } };
    const root = protocol.Node{ .scroll = .{ .id = "sv", .child = &child } };

    render.renderToFrame(root, .{
        .focused_id = "i",
        .inputs = &.{.{ .id = "i", .value = "", .cursor = 0, .scroll_x = 0 }},
        .scrolls = &.{.{ .id = "sv", .scroll_y = 1, .content_h = 3, .viewport_h = 2 }},
    }, &frame);

    const cur = frame.cursor orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), cur.row);
    try std.testing.expectEqual(@as(usize, 3), cur.col);
}

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

test "renderer: emits truecolor SGR for styled text" {
    var term = testing_terminal.Terminal.init(std.testing.allocator, .{ .rows = 3, .cols = 20 });
    defer term.deinit();

    var renderer = renderer_mod.Renderer.initWithMode(std.testing.allocator, .truecolor);
    defer renderer.deinit();

    const red: style.StyleOverride = .{ .fg = .{ .rgb = .{ .r = 255, .g = 0, .b = 0 } } };
    var children = [_]protocol.Node{
        .{ .text = .{ .id = "t", .style = red, .text = "X" } },
    };
    const root = protocol.Node{ .vbox = .{ .id = "root", .children = children[0..] } };

    try renderer.draw(&term, root, .{});

    const out = term.out.items;
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[0;38;2;255;0;0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "X") != null);
}

test "scheduler: target patch preserves style fields" {
    var sched = scheduler_mod.Scheduler.init(std.testing.allocator, 32);
    defer sched.deinit();

    var current_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer current_arena.deinit();

    var root_children = [_]protocol.Node{
        .{ .text = .{ .id = "t", .text = "old" } },
    };
    var current_root: ?protocol.Node = .{ .vbox = .{ .id = "root", .children = root_children[0..] } };

    var next_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer next_arena.deinit();

    const red: style.StyleOverride = .{ .fg = .{ .rgb = .{ .r = 255, .g = 0, .b = 0 } } };
    const patched: protocol.Node = .{ .text = .{ .id = "t", .h = 1, .style = red, .text = "new" } };

    _ = try sched.putTargetLeaky(&next_arena, "t", patched, .replace);
    _ = try sched.flushApplyLeaky(std.testing.allocator, &current_arena, &current_root);

    const root = current_root orelse return error.TestUnexpectedResult;
    const child = root.vbox.children[0].text;
    try std.testing.expectEqualStrings("new", child.text);
    try std.testing.expect(child.style != null);
    const st = child.style.?;
    try std.testing.expect(st.fg == .rgb);
}

test "markdown: inline spans bold + code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const spans = try markdown.compileInlineSpansLeaky(
        arena.allocator(),
        "Status: **Connected** (latency `42ms`)",
        .{},
    );

    try std.testing.expectEqual(@as(usize, 5), spans.len);
    try std.testing.expectEqualStrings("Status: ", spans[0].text);

    const bold_style = spans[1].style orelse return error.TestUnexpectedResult;
    try std.testing.expect((bold_style.attrs_set & style.ATTR_BOLD) != 0);
    try std.testing.expect((bold_style.attrs_values & style.ATTR_BOLD) != 0);
    try std.testing.expectEqualStrings("Connected", spans[1].text);

    try std.testing.expectEqualStrings(" (latency ", spans[2].text);
    try std.testing.expectEqualStrings("42ms", spans[3].text);

    const code_style = spans[3].style orelse return error.TestUnexpectedResult;
    const fg = switch (code_style.fg) {
        .rgb => |c| c,
        else => return error.TestUnexpectedResult,
    };
    const bg = switch (code_style.bg) {
        .rgb => |c| c,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(u8, 0xE5), fg.r);
    try std.testing.expectEqual(@as(u8, 0xE7), fg.g);
    try std.testing.expectEqual(@as(u8, 0xEB), fg.b);
    try std.testing.expectEqual(@as(u8, 0x11), bg.r);
    try std.testing.expectEqual(@as(u8, 0x18), bg.g);
    try std.testing.expectEqual(@as(u8, 0x27), bg.b);
}

test "markdown: unmatched delimiters are literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const spans = try markdown.compileInlineSpansLeaky(arena.allocator(), "`code", .{});
    try std.testing.expectEqual(@as(usize, 1), spans.len);
    try std.testing.expectEqualStrings("`code", spans[0].text);
}

test "markdown: span cap falls back to plain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const md = "a **b** c `d` e";
    const spans = try markdown.compileInlineSpansLeaky(arena.allocator(), md, .{ .max_spans = 2 });
    try std.testing.expectEqual(@as(usize, 1), spans.len);
    try std.testing.expectEqualStrings(md, spans[0].text);
}

test "markdown: ids are stable under append (streaming approach #1)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const a = "- first\n\npara";
    const b = a ++ "\nmore";

    const na = try markdown.compileLeaky(arena.allocator(), a, .{ .id = "md", .id_prefix = "md", .pretty_prefixes = false });
    const nb = try markdown.compileLeaky(arena.allocator(), b, .{ .id = "md", .id_prefix = "md", .pretty_prefixes = false });

    const va = switch (na) {
        .vbox => |v| v,
        else => return error.TestUnexpectedResult,
    };
    const vb = switch (nb) {
        .vbox => |v| v,
        else => return error.TestUnexpectedResult,
    };

    const li_a = switch (va.children[0]) {
        .hbox => |h| h,
        else => return error.TestUnexpectedResult,
    };
    const li_b = switch (vb.children[0]) {
        .hbox => |h| h,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("md-li-0", li_a.id);
    try std.testing.expectEqualStrings("md-li-0", li_b.id);

    const para_a = switch (va.children[2]) {
        .styled_text => |t| t,
        else => return error.TestUnexpectedResult,
    };
    const para_b = switch (vb.children[2]) {
        .styled_text => |t| t,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("md-p-0", para_a.id);
    try std.testing.expectEqualStrings("md-p-0", para_b.id);
}

test "markdown: streamblocks final matches full compile (tracer 19A)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const doc =
        "# Heading\n" ++
        "\n" ++
        "- item\n" ++
        "> quote\n" ++
        "para\n" ++
        "line2\n" ++
        "\n" ++
        "tail";

    var stream = markdown.StreamBlocks.init(
        std.testing.allocator,
        .{ .id = "md", .id_prefix = "md", .pretty_prefixes = false, .own_text = false },
        .{},
        .plain,
    );
    defer stream.deinit();

    var i: usize = 0;
    while (i < doc.len) {
        const step: usize = @min(@as(usize, 7), doc.len - i);
        _ = try stream.push(doc[i .. i + step]);
        i += step;
    }
    _ = try stream.finish();

    const streamed = try stream.snapshotLeaky(arena.allocator());
    const full = try markdown.compileLeaky(
        arena.allocator(),
        doc,
        .{ .id = "md", .id_prefix = "md", .pretty_prefixes = false, .own_text = false },
    );

    var a: std.ArrayList(u8) = .empty;
    defer a.deinit(std.testing.allocator);
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(std.testing.allocator);
    try protocol.writeNodeJson(a.writer(std.testing.allocator), streamed);
    try protocol.writeNodeJson(b.writer(std.testing.allocator), full);
    try std.testing.expectEqualStrings(b.items, a.items);
}

test "markdown: streaminline tail styles appear when delimiters close (tracer 19B)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var stream = markdown.StreamInline.init(
        std.testing.allocator,
        .{ .id = "md", .id_prefix = "md", .pretty_prefixes = false, .own_text = false },
        .{},
    );
    defer stream.deinit();

    _ = try stream.push("**bo");
    {
        const snap = try stream.snapshotLeaky(arena.allocator());
        const v = switch (snap) {
            .vbox => |vv| vv,
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(@as(usize, 1), v.children.len);
        const t = switch (v.children[0]) {
            .styled_text => |st| st,
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(@as(usize, 1), t.spans.len);
        try std.testing.expectEqualStrings("**bo", t.spans[0].text);
        try std.testing.expect(t.spans[0].style == null);
    }

    _ = try stream.push("ld**");
    {
        const snap = try stream.snapshotLeaky(arena.allocator());
        const v = switch (snap) {
            .vbox => |vv| vv,
            else => return error.TestUnexpectedResult,
        };
        const t = switch (v.children[0]) {
            .styled_text => |st| st,
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(@as(usize, 1), t.spans.len);
        try std.testing.expectEqualStrings("bold", t.spans[0].text);
        const st = t.spans[0].style orelse return error.TestUnexpectedResult;
        try std.testing.expect((st.attrs_set & style.ATTR_BOLD) != 0);
        try std.testing.expect((st.attrs_values & style.ATTR_BOLD) != 0);
    }

    stream.reset();
    _ = try stream.push("`co");
    _ = try stream.push("de");
    _ = try stream.push("`");
    {
        const snap = try stream.snapshotLeaky(arena.allocator());
        const v = switch (snap) {
            .vbox => |vv| vv,
            else => return error.TestUnexpectedResult,
        };
        const t = switch (v.children[0]) {
            .styled_text => |st| st,
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(@as(usize, 1), t.spans.len);
        try std.testing.expectEqualStrings("code", t.spans[0].text);
        try std.testing.expect(t.spans[0].style != null);
    }

    stream.reset();
    _ = try stream.push("**bold *it");
    _ = try stream.push("alic* bold**");
    {
        const snap = try stream.snapshotLeaky(arena.allocator());
        const v = switch (snap) {
            .vbox => |vv| vv,
            else => return error.TestUnexpectedResult,
        };
        const t = switch (v.children[0]) {
            .styled_text => |st| st,
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expect(t.spans.len >= 3);
        try std.testing.expectEqualStrings("bold ", t.spans[0].text);
        try std.testing.expectEqualStrings("italic", t.spans[1].text);
        try std.testing.expectEqualStrings(" bold", t.spans[t.spans.len - 1].text);
        const italic_style = t.spans[1].style orelse return error.TestUnexpectedResult;
        try std.testing.expect((italic_style.attrs_set & style.ATTR_ITALIC) != 0);
        try std.testing.expect((italic_style.attrs_values & style.ATTR_ITALIC) != 0);
    }
}

test "markdown: blocks compile to vbox + hbox prefixes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const doc =
        "# Heading\n" ++
        "\n" ++
        "- item\n" ++
        "> quote\n" ++
        "para\n" ++
        "line2";

    const root = try markdown.compileLeaky(arena.allocator(), doc, .{ .id = "md", .id_prefix = "md", .pretty_prefixes = false });
    const v = switch (root) {
        .vbox => |vv| vv,
        else => return error.TestUnexpectedResult,
    };

    try std.testing.expectEqual(@as(usize, 5), v.children.len);

    try std.testing.expect(v.children[0] == .styled_text);
    try std.testing.expect(v.children[1] == .text);
    try std.testing.expect(v.children[2] == .hbox);
    try std.testing.expect(v.children[3] == .hbox);
    try std.testing.expect(v.children[4] == .styled_text);

    const li = switch (v.children[2]) {
        .hbox => |h| h,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 2), li.children.len);
    try std.testing.expect(li.children[0] == .text);
    try std.testing.expect(li.children[1] == .styled_text);
    const li_prefix = switch (li.children[0]) {
        .text => |t| t,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(?usize, 2), li_prefix.w);
    try std.testing.expectEqualStrings("- ", li_prefix.text);
}

test "markdown: list prefix aligns wrapped continuation lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const root = try markdown.compileLeaky(
        arena.allocator(),
        "- abcdefghij",
        .{ .id = "md", .id_prefix = "md", .pretty_prefixes = false },
    );

    var frame: Frame = .{};
    defer frame.deinit(std.testing.allocator);
    try frame.resize(std.testing.allocator, 3, 6);
    frame.clear(' ');

    render.renderToFrame(root, .{}, &frame);

    try std.testing.expectEqual(@as(u8, '-'), cellByte(&frame, 0, 0));
    try std.testing.expectEqual(@as(u8, 'a'), cellByte(&frame, 0, 2));
    try std.testing.expectEqual(@as(u8, ' '), cellByte(&frame, 1, 0));
    try std.testing.expectEqual(@as(u8, 'e'), cellByte(&frame, 1, 2));
}

test "render: unfocused input hides cursor and brackets placeholder" {
    var term = testing_terminal.Terminal.init(std.testing.allocator, .{ .rows = 10, .cols = 80 });
    defer term.deinit();

    var renderer = renderer_mod.Renderer.init(std.testing.allocator);
    defer renderer.deinit();

    var children = [_]protocol.Node{
        .{ .text = .{ .id = "title", .text = "Tracer Demo" } },
        .{ .input = .{ .id = "query", .placeholder = "Type here" } },
    };
    const root = protocol.Node{ .vbox = .{ .id = "root", .children = children[0..] } };

    try renderer.draw(&term, root, .{
        .focused_id = null,
        .inputs = &.{.{ .id = "query", .value = "", .cursor = 0, .scroll_x = 0 }},
    });

    const out = term.out.items;
    try std.testing.expect(std.mem.indexOf(u8, out, "> [Type here]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[?25l") != null);
}

test "render: cursor column tracks input_cursor" {
    var term = testing_terminal.Terminal.init(std.testing.allocator, .{ .rows = 10, .cols = 80 });
    defer term.deinit();

    var renderer = renderer_mod.Renderer.init(std.testing.allocator);
    defer renderer.deinit();

    var children = [_]protocol.Node{
        .{ .text = .{ .id = "title", .text = "Tracer Demo" } },
        .{ .text = .{ .id = "clock", .text = "Tick: 0" } },
        .{ .input = .{ .id = "query", .placeholder = "Type here" } },
    };
    const root = protocol.Node{ .vbox = .{ .id = "root", .children = children[0..] } };

    try renderer.draw(&term, root, .{
        .focused_id = "query",
        .inputs = &.{.{ .id = "query", .value = "hi", .cursor = 2, .scroll_x = 0 }},
    });

    const out = term.out.items;
    // Lines: title(1), clock(2), input(3). prefix is "> " => cursor col = 2 + 2 + 1 = 5.
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[3;5H") != null);
}

test "renderer: second draw is incremental" {
    var term = testing_terminal.Terminal.init(std.testing.allocator, .{ .rows = 10, .cols = 80 });
    defer term.deinit();

    var renderer = renderer_mod.Renderer.init(std.testing.allocator);
    defer renderer.deinit();

    var children1 = [_]protocol.Node{
        .{ .text = .{ .id = "title", .text = "Tracer Demo" } },
        .{ .text = .{ .id = "hint", .text = "Tab to focus input" } },
        .{ .text = .{ .id = "clock", .text = "Tick: 0" } },
        .{ .input = .{ .id = "query", .placeholder = "Type here" } },
        .{ .text = .{ .id = "status", .text = "State: OFF" } },
    };
    const root1 = protocol.Node{ .vbox = .{ .id = "root", .children = children1[0..] } };

    var children2 = [_]protocol.Node{
        .{ .text = .{ .id = "title", .text = "Tracer Demo" } },
        .{ .text = .{ .id = "hint", .text = "Tab to focus input" } },
        .{ .text = .{ .id = "clock", .text = "Tick: 1" } },
        .{ .input = .{ .id = "query", .placeholder = "Type here" } },
        .{ .text = .{ .id = "status", .text = "State: OFF" } },
    };
    const root2 = protocol.Node{ .vbox = .{ .id = "root", .children = children2[0..] } };

    try renderer.draw(&term, root1, .{
        .focused_id = "query",
        .inputs = &.{.{ .id = "query", .value = "", .cursor = 0, .scroll_x = 0 }},
    });
    const out1_len: usize = term.out.items.len;
    try std.testing.expect(std.mem.indexOf(u8, term.out.items, "\x1b[2J") != null);

    term.reset();

    try renderer.draw(&term, root2, .{
        .focused_id = "query",
        .inputs = &.{.{ .id = "query", .value = "", .cursor = 0, .scroll_x = 0 }},
    });

    const out2 = term.out.items;
    try std.testing.expect(std.mem.indexOf(u8, out2, "\x1b[2J") == null);
    try std.testing.expect(out2.len * 5 < out1_len);
    try std.testing.expect(std.mem.indexOf(u8, out2, "\x1b[3;7H") != null);
    try std.testing.expect(std.mem.indexOf(u8, out2, "1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out2, "Tracer Demo") == null);
}

test "renderer: resize forces full repaint" {
    var term = testing_terminal.Terminal.init(std.testing.allocator, .{ .rows = 10, .cols = 80 });
    defer term.deinit();

    var renderer = renderer_mod.Renderer.init(std.testing.allocator);
    defer renderer.deinit();

    var children = [_]protocol.Node{
        .{ .text = .{ .id = "title", .text = "Tracer Demo" } },
        .{ .text = .{ .id = "clock", .text = "Tick: 0" } },
        .{ .input = .{ .id = "query", .placeholder = "Type here" } },
    };
    const root = protocol.Node{ .vbox = .{ .id = "root", .children = children[0..] } };

    try renderer.draw(&term, root, .{
        .focused_id = "query",
        .inputs = &.{.{ .id = "query", .value = "hello", .cursor = 5, .scroll_x = 0 }},
    });
    try std.testing.expect(renderer.last_metrics.full);

    term.reset();
    term.size = .{ .rows = 8, .cols = 80 };

    try renderer.draw(&term, root, .{
        .focused_id = "query",
        .inputs = &.{.{ .id = "query", .value = "hello", .cursor = 5, .scroll_x = 0 }},
    });
    try std.testing.expect(renderer.last_metrics.full);
    try std.testing.expect(std.mem.indexOf(u8, term.out.items, "\x1b[2J") != null);
}

test "render: input horizontal scroll keeps cursor visible" {
    var term = testing_terminal.Terminal.init(std.testing.allocator, .{ .rows = 4, .cols = 10 });
    defer term.deinit();

    var renderer = renderer_mod.Renderer.init(std.testing.allocator);
    defer renderer.deinit();

    var children = [_]protocol.Node{
        .{ .text = .{ .id = "title", .text = "T" } },
        .{ .input = .{ .id = "query", .placeholder = "Type here" } },
    };
    const root = protocol.Node{ .vbox = .{ .id = "root", .children = children[0..] } };

    const value = "abcdefghijklmnop";
    const cursor: usize = value.len;
    var scroll_x: usize = 0;
    _ = input.ensure_cursor_visible(&scroll_x, cursor, value, 8);

    try renderer.draw(&term, root, .{
        .focused_id = "query",
        .inputs = &.{.{ .id = "query", .value = value, .cursor = cursor, .scroll_x = scroll_x }},
    });

    const out = term.out.items;
    try std.testing.expect(std.mem.indexOf(u8, out, "> ijklmnop") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[2;10H") != null);
}

test "render: text wraps and respects hard newlines" {
    var term = testing_terminal.Terminal.init(std.testing.allocator, .{ .rows = 6, .cols = 10 });
    defer term.deinit();

    var renderer = renderer_mod.Renderer.init(std.testing.allocator);
    defer renderer.deinit();

    const root = protocol.Node{ .text = .{ .id = "t", .text = "Hello\nWorldWorldWorld" } };

    try renderer.draw(&term, root, .{});

    const out = term.out.items;
    try std.testing.expect(std.mem.indexOf(u8, out, "Hello\x1b[K\r\nWorldWorld\x1b[K\r\nWorld") != null);
}

test "render: styled_text wraps and respects hard newlines" {
    var term = testing_terminal.Terminal.init(std.testing.allocator, .{ .rows = 6, .cols = 10 });
    defer term.deinit();

    var renderer = renderer_mod.Renderer.init(std.testing.allocator);
    defer renderer.deinit();

    var spans = [_]protocol.Span{
        .{ .text = "Hello\nWorld" },
        .{ .text = "WorldWorld" },
    };
    const root = protocol.Node{ .styled_text = .{ .id = "t", .spans = spans[0..] } };

    try renderer.draw(&term, root, .{});

    const out = term.out.items;
    try std.testing.expect(std.mem.indexOf(u8, out, "Hello\x1b[K\r\nWorldWorld\x1b[K\r\nWorld") != null);
}

test "input: insert and backspace edit buffer" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var cursor: usize = 0;

    try std.testing.expect(try input.handleInputByte(std.testing.allocator, &buf, &cursor, 'h'));
    try std.testing.expect(try input.handleInputByte(std.testing.allocator, &buf, &cursor, 'i'));
    try std.testing.expectEqualStrings("hi", buf.items);
    try std.testing.expectEqual(@as(usize, 2), cursor);

    try std.testing.expect(try input.handleInputByte(std.testing.allocator, &buf, &cursor, 127));
    try std.testing.expectEqualStrings("h", buf.items);
    try std.testing.expectEqual(@as(usize, 1), cursor);
}

test "input: insert utf8 and backspace deletes grapheme" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var cursor: usize = 0;

    try std.testing.expect(try input.insertUtf8Bytes(std.testing.allocator, &buf, &cursor, "漢"));
    try std.testing.expectEqualStrings("漢", buf.items);
    try std.testing.expectEqual(@as(usize, "漢".len), cursor);

    try std.testing.expect(try input.handleInputByte(std.testing.allocator, &buf, &cursor, 127));
    try std.testing.expectEqualStrings("", buf.items);
    try std.testing.expectEqual(@as(usize, 0), cursor);
}

test "input: ensure_cursor_visible scrolls window" {
    const value = "abcdefghijklmnop";
    const visible_cols: usize = 8;
    var scroll_x: usize = 0;

    _ = input.ensure_cursor_visible(&scroll_x, 16, value, visible_cols);
    try std.testing.expectEqual(@as(usize, 8), scroll_x);

    _ = input.ensure_cursor_visible(&scroll_x, 6, value, visible_cols);
    try std.testing.expectEqual(@as(usize, 6), scroll_x);
}

test "input: delete_at_cursor deletes without moving cursor" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try buf.appendSlice(std.testing.allocator, "abcd");
    var cursor: usize = 1;

    try std.testing.expect(input.delete_at_cursor(&buf, &cursor));
    try std.testing.expectEqualStrings("acd", buf.items);
    try std.testing.expectEqual(@as(usize, 1), cursor);
}

test "input: word jumps use ascii word chars" {
    const value = "abc  def_ghi  j";
    try std.testing.expectEqual(@as(usize, 3), input.word_right(value, 0));
    try std.testing.expectEqual(@as(usize, 12), input.word_right(value, 3));
    try std.testing.expectEqual(@as(usize, 5), input.word_left(value, 12));
    try std.testing.expectEqual(@as(usize, 0), input.word_left(value, 5));
}

test "state: clamp list scroll keeps selection visible" {
    try std.testing.expectEqual(@as(usize, 0), state.clampListScroll(0, null, 5, 20));
    try std.testing.expectEqual(@as(usize, 8), state.clampListScroll(0, 12, 5, 20));
    try std.testing.expectEqual(@as(usize, 12), state.clampListScroll(15, 12, 5, 20));
    try std.testing.expectEqual(@as(usize, 15), state.clampListScroll(999, 19, 5, 20));
    try std.testing.expectEqual(@as(usize, 0), state.clampListScroll(3, 0, 5, 20));
}

test "tree: patch-by-id replaces matching node" {
    var children = [_]protocol.Node{
        .{ .text = .{ .id = "clock", .text = "Tick: 0" } },
        .{ .text = .{ .id = "status", .text = "State: OFF" } },
    };
    var root = protocol.Node{ .vbox = .{ .id = "root", .children = children[0..] } };

    const replacement = protocol.Node{ .text = .{ .id = "clock", .text = "Tick: 12" } };
    const found = tree.applyPatchById(&root, "clock", replacement);
    try std.testing.expect(found);

    const v = root.vbox;
    const clock = v.children[0].text;
    try std.testing.expectEqualStrings("Tick: 12", clock.text);
}

test "tree: morph-by-id reorders and inserts children" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var old_children = [_]protocol.Node{
        .{ .text = .{ .id = "title", .text = "Tracer Demo" } },
        .{ .text = .{ .id = "clock", .text = "Tick: 0" } },
        .{ .input = .{ .id = "query", .placeholder = "Type here" } },
        .{ .text = .{ .id = "status", .text = "State: OFF" } },
    };
    var root = protocol.Node{ .vbox = .{ .id = "root", .children = old_children[0..] } };

    var new_children = [_]protocol.Node{
        .{ .text = .{ .id = "title", .text = "Tracer Demo" } },
        .{ .text = .{ .id = "status", .text = "State: ON" } },
        .{ .text = .{ .id = "banner", .text = "Banner!" } },
        .{ .input = .{ .id = "query", .placeholder = "Type here" } },
        .{ .text = .{ .id = "clock", .text = "Tick: 1" } },
    };
    const incoming = protocol.Node{ .vbox = .{ .id = "root", .children = new_children[0..] } };

    var stats: tree.MorphStats = .{};
    const found = try tree.morphPatchByIdLeaky(arena.allocator(), &root, "root", incoming, &stats);
    try std.testing.expect(found);
    try std.testing.expectEqual(@as(usize, 4), stats.reused);
    try std.testing.expectEqual(@as(usize, 1), stats.inserted);
    try std.testing.expectEqual(@as(usize, 0), stats.removed);

    const v = root.vbox;
    try std.testing.expectEqual(@as(usize, 5), v.children.len);
    try std.testing.expectEqualStrings("title", v.children[0].text.id);
    try std.testing.expectEqualStrings("status", v.children[1].text.id);
    try std.testing.expectEqualStrings("banner", v.children[2].text.id);
    try std.testing.expectEqualStrings("query", v.children[3].input.id);
    try std.testing.expectEqualStrings("clock", v.children[4].text.id);
    try std.testing.expectEqualStrings("Tick: 1", v.children[4].text.text);
}

test "render: focused list shows selection marker and hides cursor" {
    var term = testing_terminal.Terminal.init(std.testing.allocator, .{ .rows = 10, .cols = 80 });
    defer term.deinit();

    var renderer = renderer_mod.Renderer.init(std.testing.allocator);
    defer renderer.deinit();

    var list_children = [_]protocol.Node{
        .{ .text = .{ .id = "item-1", .text = "Alpha" } },
        .{ .text = .{ .id = "item-2", .text = "Beta" } },
        .{ .text = .{ .id = "item-3", .text = "Gamma" } },
    };
    var root_children = [_]protocol.Node{
        .{ .list = .{ .id = "results", .height = 3, .children = list_children[0..] } },
    };
    const root = protocol.Node{ .vbox = .{ .id = "root", .children = root_children[0..] } };

    try renderer.draw(&term, root, .{
        .focused_id = "results",
        .lists = &.{.{ .id = "results", .selected_id = "item-2", .scroll = 0 }},
    });

    const out = term.out.items;
    try std.testing.expect(std.mem.indexOf(u8, out, "> Beta") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[?25l") != null);
}

test "unicode: combining mark stays together and width=1" {
    const s = "e\u{0301}";
    const g = unicode.nextGrapheme(s, 0);
    try std.testing.expectEqual(@as(usize, 0), g.start);
    try std.testing.expectEqual(@as(usize, s.len), g.end);
    try std.testing.expectEqual(@as(usize, 1), g.width);
    try std.testing.expectEqual(@as(usize, s.len), unicode.sliceEndByWidth(s, 0, 1));
}

test "unicode: cjk is width 2 and does not render into 1 col" {
    try std.testing.expectEqual(@as(u2, 2), unicode.cellWidth('漢'));

    var term = testing_terminal.Terminal.init(std.testing.allocator, .{ .rows = 1, .cols = 1 });
    defer term.deinit();

    var renderer = renderer_mod.Renderer.init(std.testing.allocator);
    defer renderer.deinit();

    const root = protocol.Node{ .text = .{ .id = "t", .text = "漢" } };
    try renderer.draw(&term, root, .{});
    try std.testing.expect(std.mem.indexOf(u8, term.out.items, "漢") == null);
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

test "unicode: flag cluster treated as one grapheme width 2" {
    const flag = "🇯🇵";
    const g = unicode.nextGrapheme(flag, 0);
    try std.testing.expectEqual(@as(usize, flag.len), g.end);
    try std.testing.expectEqual(@as(usize, 2), g.width);
}

test "render: cursor column uses display width not bytes" {
    var term = testing_terminal.Terminal.init(std.testing.allocator, .{ .rows = 5, .cols = 20 });
    defer term.deinit();

    var renderer = renderer_mod.Renderer.init(std.testing.allocator);
    defer renderer.deinit();

    var children = [_]protocol.Node{
        .{ .text = .{ .id = "title", .text = "T" } },
        .{ .text = .{ .id = "clock", .text = "C" } },
        .{ .input = .{ .id = "query", .placeholder = "Type here" } },
    };
    const root = protocol.Node{ .vbox = .{ .id = "root", .children = children[0..] } };

    const value = "a漢b";
    const cursor: usize = 1 + "漢".len; // after 漢 (byte offset)

    try renderer.draw(&term, root, .{
        .focused_id = "query",
        .inputs = &.{.{ .id = "query", .value = value, .cursor = cursor, .scroll_x = 0 }},
    });

    // Line 3, col = 1 + prefix(2) + (a=1, 漢=2) = 6.
    try std.testing.expect(std.mem.indexOf(u8, term.out.items, "\x1b[3;6H") != null);
}

test "renderer: styled_text emits SGR changes across spans" {
    var term = testing_terminal.Terminal.init(std.testing.allocator, .{ .rows = 1, .cols = 10 });
    defer term.deinit();

    var renderer = renderer_mod.Renderer.initWithMode(std.testing.allocator, .truecolor);
    defer renderer.deinit();

    const red: style.StyleOverride = .{ .fg = .{ .rgb = .{ .r = 255, .g = 0, .b = 0 } } };
    const green: style.StyleOverride = .{ .fg = .{ .rgb = .{ .r = 0, .g = 255, .b = 0 } } };
    var spans = [_]protocol.Span{
        .{ .text = "A", .style = red },
        .{ .text = "B", .style = green },
    };
    const root = protocol.Node{ .styled_text = .{ .id = "t", .spans = spans[0..] } };

    try renderer.draw(&term, root, .{});

    const out = term.out.items;
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[0;38;2;255;0;0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[0;38;2;0;255;0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "A") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "B") != null);
}

test "scheduler: coalesces targets (latest wins)" {
    var sched = scheduler_mod.Scheduler.init(std.testing.allocator, 8);
    defer sched.deinit();

    var current_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer current_arena.deinit();

    var children = [_]protocol.Node{
        .{ .text = .{ .id = "clock", .text = "Tick: 0" } },
    };
    const root = protocol.Node{ .vbox = .{ .id = "root", .children = children[0..] } };
    var current_root: ?protocol.Node = root;

    {
        var a = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer a.deinit();
        _ = try sched.putTargetLeaky(&a, "clock", .{ .text = .{ .id = "clock", .text = "Tick: 1" } }, .replace);
    }
    {
        var a = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer a.deinit();
        _ = try sched.putTargetLeaky(&a, "clock", .{ .text = .{ .id = "clock", .text = "Tick: 2" } }, .replace);
    }

    const c = sched.counts();
    try std.testing.expectEqual(@as(usize, 1), c.pending_targets);
    try std.testing.expectEqual(@as(u64, 1), c.coalesced_targets);

    const res = try sched.flushApplyLeaky(std.testing.allocator, &current_arena, &current_root);
    try std.testing.expectEqual(@as(usize, 1), res.targets_applied);
    try std.testing.expectEqual(@as(usize, 1), res.targets_found);

    const v = current_root.?.vbox;
    try std.testing.expectEqualStrings("Tick: 2", v.children[0].text.text);
}

test "scheduler: full patch supersedes earlier targets and flush applies full then targets" {
    var sched = scheduler_mod.Scheduler.init(std.testing.allocator, 8);
    defer sched.deinit();

    var current_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer current_arena.deinit();

    var old_children = [_]protocol.Node{
        .{ .text = .{ .id = "clock", .text = "Tick: old" } },
    };
    var current_root: ?protocol.Node = .{ .vbox = .{ .id = "root", .children = old_children[0..] } };

    // Target patch that should be dropped by the full snapshot.
    {
        var a = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer a.deinit();
        _ = try sched.putTargetLeaky(&a, "clock", .{ .text = .{ .id = "clock", .text = "Tick: stale" } }, .replace);
    }

    // Full snapshot replaces root.
    var full_children = [_]protocol.Node{
        .{ .text = .{ .id = "clock", .text = "Tick: full" } },
    };
    {
        var a = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer a.deinit();
        try sched.putFullLeaky(&a, .{ .vbox = .{ .id = "root", .children = full_children[0..] } });
    }

    const after_full = sched.counts();
    try std.testing.expect(after_full.pending_full);
    try std.testing.expectEqual(@as(usize, 0), after_full.pending_targets);

    // Target patch after full should win.
    {
        var a = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer a.deinit();
        _ = try sched.putTargetLeaky(&a, "clock", .{ .text = .{ .id = "clock", .text = "Tick: after" } }, .replace);
    }

    const res = try sched.flushApplyLeaky(std.testing.allocator, &current_arena, &current_root);
    try std.testing.expect(res.full_applied);
    try std.testing.expectEqual(@as(usize, 1), res.targets_applied);

    const v = current_root.?.vbox;
    try std.testing.expectEqualStrings("Tick: after", v.children[0].text.text);
}

test "mouse: parse SGR left click" {
    const ev = mouse.parseSgrMouseSequence("\x1b[<0;10;5M") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(mouse.MouseEventKind.down_left, ev.kind);
    try std.testing.expectEqual(@as(usize, 9), ev.x);
    try std.testing.expectEqual(@as(usize, 4), ev.y);
}

test "mouse: parse SGR wheel up/down" {
    const up = mouse.parseSgrMouseSequence("\x1b[<64;10;5M") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(mouse.MouseEventKind.wheel_up, up.kind);
    try std.testing.expectEqual(@as(usize, 9), up.x);
    try std.testing.expectEqual(@as(usize, 4), up.y);

    const down = mouse.parseSgrMouseSequence("<65;1;1M") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(mouse.MouseEventKind.wheel_down, down.kind);
    try std.testing.expectEqual(@as(usize, 0), down.x);
    try std.testing.expectEqual(@as(usize, 0), down.y);
}

test "mouse: modifiers ignored for left click" {
    // shift modifier bit (4) should still decode as left click.
    const ev = mouse.parseSgrMouseSequence("<4;2;3M") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(mouse.MouseEventKind.down_left, ev.kind);
    try std.testing.expectEqual(@as(usize, 1), ev.x);
    try std.testing.expectEqual(@as(usize, 2), ev.y);
}

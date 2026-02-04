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
const hover = tui.hover;
const keys = tui.keys;
const kd = tui.key_decode;
const runtime_ui = @import("runtime_ui");
const pointer = runtime_ui.pointer;

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

test "mouse: parse SGR move" {
    const ev = mouse.parseSgrMouseSequence("<32;10;5M") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(mouse.MouseEventKind.move, ev.kind);
    try std.testing.expectEqual(@as(usize, 9), ev.x);
    try std.testing.expectEqual(@as(usize, 4), ev.y);
    try std.testing.expectEqual(@as(u8, 0), ev.mods);
}

test "protocol: parse hover event (no item)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const line = "{\"type\":\"event\",\"name\":\"hover\",\"id\":\"query\",\"x\":12,\"y\":3}";
    const msg = try protocol.parseMsgLeaky(arena.allocator(), line);
    const ev = switch (msg) {
        .event => |e| e,
        else => return error.TestUnexpectedResult,
    };
    const h = switch (ev) {
        .hover => |hh| hh,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("query", h.id);
    try std.testing.expectEqual(@as(usize, 12), h.x);
    try std.testing.expectEqual(@as(usize, 3), h.y);
    try std.testing.expect(h.item == null);
}

test "protocol: parse hover event (with item)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const line = "{\"type\":\"event\",\"name\":\"hover\",\"id\":\"results\",\"x\":0,\"y\":1,\"item\":\"results-1\"}";
    const msg = try protocol.parseMsgLeaky(arena.allocator(), line);
    const ev = switch (msg) {
        .event => |e| e,
        else => return error.TestUnexpectedResult,
    };
    const h = switch (ev) {
        .hover => |hh| hh,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("results", h.id);
    try std.testing.expectEqual(@as(usize, 0), h.x);
    try std.testing.expectEqual(@as(usize, 1), h.y);
    try std.testing.expectEqualStrings("results-1", h.item orelse return error.TestUnexpectedResult);
}

test "protocol: parse hoverable field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const line = "{\"type\":\"patch\",\"root\":{\"type\":\"text\",\"id\":\"t\",\"hoverable\":true,\"text\":\"hi\"}}";
    const msg = try protocol.parseMsgLeaky(arena.allocator(), line);
    const root = switch (msg) {
        .patch => |p| switch (p) {
            .full => |f| f.root,
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    };
    const t = switch (root) {
        .text => |tt| tt,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(t.hoverable);
}

test "protocol: parse mouseable field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const line = "{\"type\":\"patch\",\"root\":{\"type\":\"text\",\"id\":\"t\",\"mouseable\":true,\"text\":\"hi\"}}";
    const msg = try protocol.parseMsgLeaky(arena.allocator(), line);
    const root = switch (msg) {
        .patch => |p| switch (p) {
            .full => |f| f.root,
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    };
    const t = switch (root) {
        .text => |tt| tt,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(t.mouseable);
}

test "protocol: write+parse widget state fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var child = protocol.Node{ .text = .{ .id = "t", .text = "" } };
    const node = protocol.Node{ .box = .{
        .id = "b",
        .disabled = true,
        .readonly = true,
        .validation = .@"error",
        .focusable = true,
        .child = &child,
    } };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try buf.appendSlice(std.testing.allocator, "{\"type\":\"patch\",\"root\":");
    try protocol.writeNodeJson(buf.writer(std.testing.allocator), node);
    try buf.appendSlice(std.testing.allocator, "}");

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"disabled\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"readonly\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"validation\":\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"focusable\":true") != null);

    const msg = try protocol.parseMsgLeaky(arena.allocator(), buf.items);
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
    try std.testing.expect(b.disabled);
    try std.testing.expect(b.readonly);
    try std.testing.expectEqual(protocol.ValidationState.@"error", b.validation);
    try std.testing.expect(b.focusable);
}

test "protocol: write+parse textarea + list marker" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var children = [_]protocol.Node{.{ .text = .{ .id = "row", .text = "X" } }};
    var root_children = [_]protocol.Node{
        .{ .textarea = .{
            .id = "ta",
            .placeholder = "hello",
            .readonly = true,
            .validation = .warning,
            .focusable = false,
        } },
        .{ .list = .{
            .id = "l",
            .marker = .none,
            .children = children[0..],
        } },
    };
    const node = protocol.Node{ .vbox = .{
        .id = "root",
        .children = root_children[0..],
    } };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try buf.appendSlice(std.testing.allocator, "{\"type\":\"patch\",\"root\":");
    try protocol.writeNodeJson(buf.writer(std.testing.allocator), node);
    try buf.appendSlice(std.testing.allocator, "}");

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"type\":\"textarea\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"validation\":\"warning\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"focusable\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"marker\":\"none\"") != null);

    const msg = try protocol.parseMsgLeaky(arena.allocator(), buf.items);
    const root = switch (msg) {
        .patch => |p| switch (p) {
            .full => |f| f.root,
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    };

    const v = switch (root) {
        .vbox => |vv| vv,
        else => return error.TestUnexpectedResult,
    };
    const ta = v.children[0].textarea;
    try std.testing.expectEqualStrings("ta", ta.id);
    try std.testing.expect(ta.readonly);
    try std.testing.expectEqual(protocol.ValidationState.warning, ta.validation);
    try std.testing.expect(!ta.focusable);

    const l = v.children[1].list;
    try std.testing.expectEqual(protocol.ListMarker.none, l.marker);
}

test "protocol: write+parse pointer event" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try protocol.writePointerEventJsonl(buf.writer(std.testing.allocator), .{
        .kind = .down,
        .id = "btn",
        .x = 10,
        .y = 5,
        .local_x = 1,
        .local_y = 2,
        .button = .left,
        .buttons = 1,
        .mods = 7,
        .clicks = 2,
        .scroll_dx = 0,
        .scroll_dy = 0,
        .item = "row-1",
        .captured = false,
    });

    const line = buf.items[0 .. buf.items.len - 1];
    const msg = try protocol.parseMsgLeaky(arena.allocator(), line);
    const ev = switch (msg) {
        .event => |e| e,
        else => return error.TestUnexpectedResult,
    };
    const p = switch (ev) {
        .pointer => |pp| pp,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(protocol.PointerKind.down, p.kind);
    try std.testing.expectEqualStrings("btn", p.id);
    try std.testing.expectEqual(@as(usize, 10), p.x);
    try std.testing.expectEqual(@as(usize, 5), p.y);
    try std.testing.expectEqual(@as(usize, 1), p.local_x);
    try std.testing.expectEqual(@as(usize, 2), p.local_y);
    try std.testing.expectEqual(protocol.PointerButton.left, p.button);
    try std.testing.expectEqual(@as(u8, 1), p.buttons);
    try std.testing.expectEqual(@as(u8, 7), p.mods);
    try std.testing.expectEqual(@as(u8, 2), p.clicks);
    try std.testing.expectEqual(@as(isize, 0), p.scroll_dx);
    try std.testing.expectEqual(@as(isize, 0), p.scroll_dy);
    try std.testing.expectEqualStrings("row-1", p.item orelse return error.TestUnexpectedResult);
    try std.testing.expect(!p.captured);
}

test "ui: hover hit-test list item" {
    var children = [_]protocol.Node{
        .{ .text = .{ .id = "results-0", .text = "0" } },
        .{ .text = .{ .id = "results-1", .text = "1" } },
        .{ .text = .{ .id = "results-2", .text = "2" } },
        .{ .text = .{ .id = "results-3", .text = "3" } },
    };

    const root = protocol.Node{ .list = .{ .id = "results", .height = 3, .hoverable = true, .children = children[0..] } };
    const list_states = [_]render.ListState{.{ .id = "results", .selected_id = "", .scroll = 0 }};
    const empty_scrolls = [_]render.ScrollState{};
    const hit = try hover.hoverHitTestLeaky(std.testing.allocator, root, 10, 10, 0, 1, empty_scrolls[0..], list_states[0..]);
    try std.testing.expectEqualStrings("results", hit.id orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("results-1", hit.item orelse return error.TestUnexpectedResult);
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

test "protocol: parse alignment fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const line =
        "{\"type\":\"patch\",\"root\":{\"type\":\"vbox\",\"id\":\"root\",\"justify_content\":\"center\",\"align_items\":\"center\",\"gap\":2,\"children\":[" ++
        "{\"type\":\"text\",\"id\":\"t\",\"w\":10,\"h\":3,\"align_self\":\"end\",\"ext_align\":\"right\",\"v_align\":\"center\",\"text\":\"hi\"}," ++
        "{\"type\":\"input\",\"id\":\"i\",\"content_align\":\"center\",\"placeholder\":\"p\"}" ++
        "]}}";

    const msg = try protocol.parseMsgLeaky(arena.allocator(), line);
    const root = switch (msg) {
        .patch => |p| switch (p) {
            .full => |f| f.root,
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    };

    const v = switch (root) {
        .vbox => |vv| vv,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(protocol.JustifyContent.center, v.justify_content);
    try std.testing.expectEqual(protocol.AlignItems.center, v.align_items);
    try std.testing.expectEqual(@as(usize, 2), v.gap);

    const t = switch (v.children[0]) {
        .text => |tt| tt,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(t.align_self != null);
    try std.testing.expectEqual(protocol.AlignItems.end, t.align_self.?);
    try std.testing.expectEqual(protocol.HorizontalAlign.right, t.ext_align);
    try std.testing.expectEqual(protocol.VerticalAlign.center, t.v_align);

    const inp = switch (v.children[1]) {
        .input => |ii| ii,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(protocol.HorizontalAlign.center, inp.content_align);
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

test "render: disabled overlay dims glyph" {
    var frame: Frame = .{};
    defer frame.deinit(std.testing.allocator);
    try frame.resize(std.testing.allocator, 1, 1);
    frame.clear(' ');

    const root = protocol.Node{ .text = .{ .id = "t", .disabled = true, .text = "X" } };
    render.renderToFrame(root, .{}, &frame);
    const cell = frame.rowSlice(0)[0];
    try std.testing.expect((cell.style.attrs & style.ATTR_DIM) != 0);
}

test "render: validation error overlays box border fg" {
    var frame: Frame = .{};
    defer frame.deinit(std.testing.allocator);
    try frame.resize(std.testing.allocator, 3, 3);
    frame.clear(' ');

    var child = protocol.Node{ .text = .{ .id = "t", .text = "" } };
    const root = protocol.Node{ .box = .{ .id = "b", .validation = .@"error", .child = &child } };
    render.renderToFrame(root, .{}, &frame);

    const cell = frame.rowSlice(0)[0];
    try std.testing.expectEqual(@as(u1, 1), cell.style.has_fg);
    try std.testing.expectEqual(@as(u24, 0xef4444), cell.style.fg);
}

test "render: list marker none removes prefix" {
    var frame: Frame = .{};
    defer frame.deinit(std.testing.allocator);
    try frame.resize(std.testing.allocator, 1, 5);
    frame.clear(' ');

    var items = [_]protocol.Node{.{ .text = .{ .id = "row", .text = "X" } }};
    const root = protocol.Node{ .list = .{ .id = "l", .marker = .none, .children = items[0..] } };
    const st: render.ListState = .{ .id = "l", .selected_id = "row", .scroll = 0 };
    render.renderToFrame(root, .{ .focused_id = "l", .lists = &.{st} }, &frame);

    try std.testing.expectEqual(@as(u8, 'X'), cellByte(&frame, 0, 0));
    try std.testing.expect((frame.rowSlice(0)[0].style.attrs & style.ATTR_INVERSE) != 0);
}

test "render: overlay layer can anchor to prior layer node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const base_text = try a.create(protocol.Node);
    base_text.* = .{ .text = .{ .id = "a", .text = "AAA" } };

    var base_children = try a.alloc(protocol.Node, 1);
    base_children[0] = base_text.*;
    const base_vbox = try a.create(protocol.Node);
    base_vbox.* = .{ .vbox = .{ .id = "base", .children = base_children } };

    const layer1_child_text = try a.create(protocol.Node);
    layer1_child_text.* = .{ .text = .{ .id = "in-layer", .text = "X" } };
    var layer1_children = try a.alloc(protocol.Node, 1);
    layer1_children[0] = layer1_child_text.*;
    const layer1_vbox = try a.create(protocol.Node);
    layer1_vbox.* = .{ .vbox = .{ .id = "layer1", .children = layer1_children } };

    const layer2_text = try a.create(protocol.Node);
    layer2_text.* = .{ .text = .{ .id = "layer2", .text = "T" } };

    var layers = try a.alloc(protocol.OverlayLayer, 2);
    layers[0] = .{
        .node = layer1_vbox,
        .anchor = "a",
        .placement = .below,
        .align_ = .start,
        .w = 10,
        .h = 3,
    };
    layers[1] = .{
        .node = layer2_text,
        .anchor = "in-layer",
        .placement = .right,
        .align_ = .start,
        .w = 5,
        .h = 1,
    };

    const root = protocol.Node{ .overlay = .{
        .id = "root",
        .base = base_vbox,
        .layers = layers,
    } };

    const r = render.findRectForId(root, 10, 40, "layer2") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 10), r.x);
    try std.testing.expectEqual(@as(usize, 1), r.y);
}

test "render: textarea renders multiline + cursor" {
    var frame: Frame = .{};
    defer frame.deinit(std.testing.allocator);
    try frame.resize(std.testing.allocator, 2, 3);
    frame.clear(' ');

    const root = protocol.Node{ .textarea = .{ .id = "ta" } };
    const st: render.TextareaState = .{ .id = "ta", .value = "a\nb", .cursor = 2, .scroll_y = 0 };
    render.renderToFrame(root, .{ .focused_id = "ta", .textareas = &.{st} }, &frame);

    try std.testing.expectEqual(@as(u8, 'a'), cellByte(&frame, 0, 0));
    try std.testing.expectEqual(@as(u8, 'b'), cellByte(&frame, 1, 0));
    const c = frame.cursor orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), c.row);
    try std.testing.expectEqual(@as(usize, 1), c.col);
}

test "ui: textarea scroll_y keeps cursor visible" {
    var widgets: std.ArrayList(runtime_ui.WidgetEntry) = .empty;
    defer runtime_ui.deinitWidgetEntries(std.testing.allocator, &widgets);

    const enter_ev: keys.KeyEvent = .{ .key = .{ .named = .enter } };
    _ = try runtime_ui.handleFocusedTextareaKey(
        std.testing.allocator,
        &widgets,
        "ta",
        enter_ev,
        false,
        2,
        10,
    );
    _ = try runtime_ui.handleFocusedTextareaKey(
        std.testing.allocator,
        &widgets,
        "ta",
        enter_ev,
        false,
        2,
        10,
    );
    _ = try runtime_ui.handleFocusedTextareaKey(
        std.testing.allocator,
        &widgets,
        "ta",
        enter_ev,
        false,
        2,
        10,
    );

    var scroll_y: ?usize = null;
    for (widgets.items) |w| {
        if (!std.mem.eql(u8, w.id.items, "ta")) continue;
        scroll_y = w.state.textarea.scroll_y;
        break;
    }
    try std.testing.expect(scroll_y != null);
    try std.testing.expectEqual(@as(usize, 2), scroll_y.?);

    const changed = try runtime_ui.handleFocusedTextareaKey(
        std.testing.allocator,
        &widgets,
        "ta",
        enter_ev,
        true,
        2,
        10,
    );
    try std.testing.expect(!changed);
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

test "render: text ext_align right places glyph at end" {
    var frame: Frame = .{};
    defer frame.deinit(std.testing.allocator);
    try frame.resize(std.testing.allocator, 1, 5);
    frame.clear(' ');

    const root = protocol.Node{ .text = .{ .id = "t", .ext_align = .right, .text = "X" } };
    render.renderToFrame(root, .{}, &frame);
    try std.testing.expectEqual(@as(u8, 'X'), cellByte(&frame, 0, 4));
    try std.testing.expectEqual(@as(u8, ' '), cellByte(&frame, 0, 0));
}

test "render: text v_align center uses middle row" {
    var frame: Frame = .{};
    defer frame.deinit(std.testing.allocator);
    try frame.resize(std.testing.allocator, 3, 5);
    frame.clear(' ');

    const root = protocol.Node{ .text = .{ .id = "t", .v_align = .center, .text = "X" } };
    render.renderToFrame(root, .{}, &frame);
    try std.testing.expectEqual(@as(u8, 'X'), cellByte(&frame, 1, 0));
    try std.testing.expectEqual(@as(u8, ' '), cellByte(&frame, 0, 0));
    try std.testing.expectEqual(@as(u8, ' '), cellByte(&frame, 2, 0));
}

test "render: styled_text ext_align right places glyph at end" {
    var frame: Frame = .{};
    defer frame.deinit(std.testing.allocator);
    try frame.resize(std.testing.allocator, 1, 5);
    frame.clear(' ');

    var spans = [_]protocol.Span{.{ .text = "X" }};
    const root = protocol.Node{ .styled_text = .{ .id = "t", .ext_align = .right, .spans = spans[0..] } };
    render.renderToFrame(root, .{}, &frame);
    try std.testing.expectEqual(@as(u8, 'X'), cellByte(&frame, 0, 4));
}

test "render: input content_align center pads short value" {
    var frame: Frame = .{};
    defer frame.deinit(std.testing.allocator);
    try frame.resize(std.testing.allocator, 1, 12);
    frame.clear(' ');

    const root = protocol.Node{ .input = .{ .id = "i", .content_align = .center, .placeholder = "p" } };
    render.renderToFrame(root, .{
        .focused_id = "i",
        .inputs = &.{.{ .id = "i", .value = "hi", .cursor = 2, .scroll_x = 0 }},
    }, &frame);

    try std.testing.expectEqual(@as(u8, '>'), cellByte(&frame, 0, 0));
    try std.testing.expectEqual(@as(u8, 'h'), cellByte(&frame, 0, 6));
    try std.testing.expectEqual(@as(u8, 'i'), cellByte(&frame, 0, 7));

    const cur = frame.cursor orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), cur.row);
    try std.testing.expectEqual(@as(usize, 9), cur.col);
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

test "pointer: click count + capture + leave" {
    var engine: pointer.PointerEngine = .{};
    defer engine.deinit(std.testing.allocator);

    var children = [_]protocol.Node{
        .{ .text = .{ .id = "t", .h = 1, .mouseable = true, .text = "hi" } },
        .{ .text = .{ .id = "u", .h = 1, .text = "pad" } },
    };
    const root = protocol.Node{ .vbox = .{ .id = "root", .children = children[0..] } };
    const widgets = [_]pointer.widgets.WidgetEntry{};

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    // Hover over the target so leave can be observed later.
    _ = try engine.handleMouseEvent(
        std.testing.allocator,
        buf.writer(std.testing.allocator),
        widgets[0..],
        root,
        3,
        10,
        .{ .kind = .move, .x = 0, .y = 0 },
        0,
    );

    // Click down.
    _ = try engine.handleMouseEvent(
        std.testing.allocator,
        buf.writer(std.testing.allocator),
        widgets[0..],
        root,
        3,
        10,
        .{ .kind = .down, .x = 0, .y = 0, .button = .left },
        1,
    );

    // Drag outside the rect; capture should keep routing.
    _ = try engine.handleMouseEvent(
        std.testing.allocator,
        buf.writer(std.testing.allocator),
        widgets[0..],
        root,
        3,
        10,
        .{ .kind = .move, .x = 0, .y = 2 },
        2,
    );

    // Release.
    _ = try engine.handleMouseEvent(
        std.testing.allocator,
        buf.writer(std.testing.allocator),
        widgets[0..],
        root,
        3,
        10,
        .{ .kind = .up, .x = 0, .y = 2, .button = .left },
        3,
    );

    // Second click within double-click window.
    _ = try engine.handleMouseEvent(
        std.testing.allocator,
        buf.writer(std.testing.allocator),
        widgets[0..],
        root,
        3,
        10,
        .{ .kind = .down, .x = 0, .y = 0, .button = .left },
        200 * std.time.ns_per_ms,
    );

    _ = try engine.handleMouseEvent(
        std.testing.allocator,
        buf.writer(std.testing.allocator),
        widgets[0..],
        root,
        3,
        10,
        .{ .kind = .up, .x = 0, .y = 0, .button = .left },
        201 * std.time.ns_per_ms,
    );

    // Move off any target: emits leave (id="") exactly once.
    _ = try engine.handleMouseEvent(
        std.testing.allocator,
        buf.writer(std.testing.allocator),
        widgets[0..],
        root,
        3,
        10,
        .{ .kind = .move, .x = 0, .y = 2 },
        202 * std.time.ns_per_ms,
    );

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var got_move_over: bool = false;
    var got_down_1: bool = false;
    var got_drag: bool = false;
    var got_up: bool = false;
    var got_down_2: bool = false;
    var got_leave: bool = false;

    var it = std.mem.splitScalar(u8, buf.items, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const msg = try protocol.parseMsgLeaky(arena.allocator(), line);
        const ev = switch (msg) {
            .event => |e| e,
            else => return error.TestUnexpectedResult,
        };
        const p = switch (ev) {
            .pointer => |pp| pp,
            else => continue,
        };
        switch (p.kind) {
            .move => {
                if (std.mem.eql(u8, p.id, "t")) got_move_over = true;
                if (p.id.len == 0) got_leave = true;
            },
            .down => {
                if (p.clicks == 1) got_down_1 = true;
                if (p.clicks == 2) got_down_2 = true;
                try std.testing.expectEqual(protocol.PointerButton.left, p.button);
            },
            .drag => {
                got_drag = true;
                try std.testing.expect(p.captured);
                try std.testing.expectEqualStrings("t", p.id);
            },
            .up => {
                got_up = true;
                try std.testing.expect(p.captured);
                try std.testing.expectEqualStrings("t", p.id);
            },
            else => {},
        }
    }

    try std.testing.expect(got_move_over);
    try std.testing.expect(got_down_1);
    try std.testing.expect(got_drag);
    try std.testing.expect(got_up);
    try std.testing.expect(got_down_2);
    try std.testing.expect(got_leave);
}

fn keyEventMatchesNamed(ev: keys.KeyEvent, k: keys.NamedKey) bool {
    if (ev.mods.toMask() != 0) return false;
    return switch (ev.key) {
        .named => |kk| kk == k,
        else => false,
    };
}

test "key_decode: ESC ambiguity (timeout vs Alt-prefix)" {
    var d = try kd.Decoder.init(std.testing.allocator, .{ .esc_timeout_ns = 10, .csi_timeout_ns = 10 });
    defer d.deinit();

    try std.testing.expect(d.feedByte(0x1b, 0) == null);
    const out1 = d.tick(11) orelse return error.TestUnexpectedResult;
    const ev1 = switch (out1) {
        .key => |e| e,
        else => return error.TestUnexpectedResult,
    };
    const k1 = switch (ev1.key) {
        .named => |k| k,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(keys.NamedKey.escape, k1);
    try std.testing.expectEqual(@as(u8, 0), ev1.mods.toMask());

    try std.testing.expect(d.feedByte(0x1b, 0) == null);
    const out2 = d.feedByte('b', 1) orelse return error.TestUnexpectedResult;
    const ev2 = switch (out2) {
        .key => |e| e,
        else => return error.TestUnexpectedResult,
    };
    const s2 = switch (ev2.key) {
        .text => |s| s,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("b", s2);
    try std.testing.expect(ev2.mods.alt);
    try std.testing.expect(!ev2.mods.ctrl);
    try std.testing.expect(!ev2.mods.shift);
}

test "key_decode: control collisions prioritize named keys" {
    var d = try kd.Decoder.init(std.testing.allocator, .{});
    defer d.deinit();

    const tab = d.feedByte(0x09, 0) orelse return error.TestUnexpectedResult;
    const t_ev = switch (tab) {
        .key => |e| e,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(keyEventMatchesNamed(t_ev, .tab));

    const cr = d.feedByte(0x0d, 0) orelse return error.TestUnexpectedResult;
    const cr_ev = switch (cr) {
        .key => |e| e,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(keyEventMatchesNamed(cr_ev, .enter));

    const lf = d.feedByte(0x0a, 0) orelse return error.TestUnexpectedResult;
    const lf_ev = switch (lf) {
        .key => |e| e,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(keyEventMatchesNamed(lf_ev, .enter));

    const bs = d.feedByte(0x7f, 0) orelse return error.TestUnexpectedResult;
    const bs_ev = switch (bs) {
        .key => |e| e,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(keyEventMatchesNamed(bs_ev, .backspace));
}

test "key_decode: partial CSI timeout emits unknown_escape" {
    var d = try kd.Decoder.init(std.testing.allocator, .{ .esc_timeout_ns = 10, .csi_timeout_ns = 10 });
    defer d.deinit();

    try std.testing.expect(d.feedByte(0x1b, 0) == null);
    try std.testing.expect(d.feedByte('[', 1) == null);
    const out = d.tick(12) orelse return error.TestUnexpectedResult;
    const ev = switch (out) {
        .key => |e| e,
        else => return error.TestUnexpectedResult,
    };
    const seq = switch (ev.key) {
        .unknown_escape => |s| s,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualSlices(u8, "\x1b[", seq);
}

test "key_decode: arrows + modifiers" {
    var d = try kd.Decoder.init(std.testing.allocator, .{});
    defer d.deinit();

    try std.testing.expect(d.feedByte(0x1b, 0) == null);
    try std.testing.expect(d.feedByte('[', 0) == null);
    const out1 = d.feedByte('A', 0) orelse return error.TestUnexpectedResult;
    const ev1 = switch (out1) {
        .key => |e| e,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(keyEventMatchesNamed(ev1, .up));

    try std.testing.expect(d.feedByte(0x1b, 0) == null);
    try std.testing.expect(d.feedByte('[', 0) == null);
    try std.testing.expect(d.feedByte('1', 0) == null);
    try std.testing.expect(d.feedByte(';', 0) == null);
    try std.testing.expect(d.feedByte('5', 0) == null);
    const out2 = d.feedByte('A', 0) orelse return error.TestUnexpectedResult;
    const ev2 = switch (out2) {
        .key => |e| e,
        else => return error.TestUnexpectedResult,
    };
    const k2 = switch (ev2.key) {
        .named => |k| k,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(keys.NamedKey.up, k2);
    try std.testing.expect(ev2.mods.ctrl);
    try std.testing.expect(!ev2.mods.alt);
    try std.testing.expect(!ev2.mods.shift);
}

test "key_decode: function keys (SS3 + CSI ~)" {
    var d = try kd.Decoder.init(std.testing.allocator, .{});
    defer d.deinit();

    try std.testing.expect(d.feedByte(0x1b, 0) == null);
    try std.testing.expect(d.feedByte('O', 0) == null);
    const f1 = d.feedByte('P', 0) orelse return error.TestUnexpectedResult;
    const ev1 = switch (f1) {
        .key => |e| e,
        else => return error.TestUnexpectedResult,
    };
    const n1 = switch (ev1.key) {
        .function => |n| n,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(u8, 1), n1);

    try std.testing.expect(d.feedByte(0x1b, 0) == null);
    try std.testing.expect(d.feedByte('[', 0) == null);
    try std.testing.expect(d.feedByte('1', 0) == null);
    try std.testing.expect(d.feedByte('5', 0) == null);
    const f5 = d.feedByte('~', 0) orelse return error.TestUnexpectedResult;
    const ev5 = switch (f5) {
        .key => |e| e,
        else => return error.TestUnexpectedResult,
    };
    const n5 = switch (ev5.key) {
        .function => |n| n,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(u8, 5), n5);
}

test "key_decode: bracketed paste emits literal body" {
    var d = try kd.Decoder.init(std.testing.allocator, .{});
    defer d.deinit();

    const paste_input = "\x1b[200~hello\x1b[Aworld\x1b[201~";
    var now: u64 = 0;
    var outputs: usize = 0;
    var got: ?[]const u8 = null;
    for (paste_input) |b| {
        if (d.feedByte(b, now)) |out| {
            outputs += 1;
            switch (out) {
                .paste => |p| got = p,
                else => return error.TestUnexpectedResult,
            }
        }
        now += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), outputs);
    try std.testing.expectEqualSlices(u8, "hello\x1b[Aworld", got orelse return error.TestUnexpectedResult);
}

test "key_decode: UTF-8 text emits a single Key.text" {
    var d = try kd.Decoder.init(std.testing.allocator, .{});
    defer d.deinit();

    const han = "漢";
    var out: ?kd.Decoded = null;
    for (han, 0..) |b, i| {
        if (d.feedByte(b, @as(u64, i))) |o| out = o;
    }
    const got = out orelse return error.TestUnexpectedResult;
    const ev = switch (got) {
        .key => |e| e,
        else => return error.TestUnexpectedResult,
    };
    const s = switch (ev.key) {
        .text => |ss| ss,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings(han, s);
    try std.testing.expectEqual(@as(u8, 0), ev.mods.toMask());
}

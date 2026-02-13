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

test "protocol: parse styled_text spans" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const line =
        "{\"type\":\"patch\",\"v\":1,\"root\":{\"type\":\"styled_text\",\"id\":\"t\",\"spans\":[" ++ "{\"text\":\"A\"}," ++ "{\"text\":\"B\",\"style\":{\"fg\":\"#00ff00\"}}," ++ "{\"text\":\"C\",\"style\":{\"fg\":null}}" ++ "]}}";

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
        "{\"type\":\"patch\",\"v\":1,\"root\":{\"type\":\"scroll\",\"id\":\"sv\",\"child\":{\"type\":\"text\",\"id\":\"t\",\"text\":\"hi\"}}}";

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

    const ev_line = "{\"type\":\"event\",\"v\":1,\"name\":\"scroll\",\"id\":\"sv\",\"scroll_y\":42}";
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

test "protocol: parse hover event (no item)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const line = "{\"type\":\"event\",\"v\":1,\"name\":\"hover\",\"id\":\"query\",\"x\":12,\"y\":3}";
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

    const line = "{\"type\":\"event\",\"v\":1,\"name\":\"hover\",\"id\":\"results\",\"x\":0,\"y\":1,\"item\":\"results-1\"}";
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

    const line = "{\"type\":\"patch\",\"v\":1,\"root\":{\"type\":\"text\",\"id\":\"t\",\"hoverable\":true,\"text\":\"hi\"}}";
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

    const line = "{\"type\":\"patch\",\"v\":1,\"root\":{\"type\":\"text\",\"id\":\"t\",\"mouseable\":true,\"text\":\"hi\"}}";
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
        .focus_scope = "panel-a",
        .child = &child,
    } };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try buf.appendSlice(std.testing.allocator, "{\"type\":\"patch\",\"v\":1,\"root\":");
    try protocol.writeNodeJson(buf.writer(std.testing.allocator), node);
    try buf.appendSlice(std.testing.allocator, "}");

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"disabled\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"readonly\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"validation\":\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"focusable\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"focus_scope\":\"panel-a\"") != null);

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
    try std.testing.expectEqualStrings("panel-a", b.focus_scope orelse return error.TestUnexpectedResult);
}

test "protocol: write+parse min/max and percent layout hints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const child = protocol.Node{ .text = .{
        .id = "t",
        .text = "hello",
        .min_w = 2,
        .max_w = 12,
        .min_h = 1,
        .max_h = 3,
        .w_pct = 30,
        .h_pct = 50,
    } };
    var children = [_]protocol.Node{child};
    const node = protocol.Node{ .vbox = .{
        .id = "root",
        .w = 40,
        .h = 10,
        .min_w = 20,
        .max_w = 80,
        .min_h = 5,
        .max_h = 20,
        .w_pct = 60,
        .h_pct = 75,
        .children = children[0..],
    } };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try buf.appendSlice(std.testing.allocator, "{\"type\":\"patch\",\"v\":1,\"root\":");
    try protocol.writeNodeJson(buf.writer(std.testing.allocator), node);
    try buf.appendSlice(std.testing.allocator, "}");

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"min_w\":20") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"max_w\":80") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"min_h\":5") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"max_h\":20") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"w_pct\":60") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"h_pct\":75") != null);

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
    try std.testing.expectEqual(@as(?usize, 20), v.min_w);
    try std.testing.expectEqual(@as(?usize, 80), v.max_w);
    try std.testing.expectEqual(@as(?usize, 5), v.min_h);
    try std.testing.expectEqual(@as(?usize, 20), v.max_h);
    try std.testing.expectEqual(@as(?u8, 60), v.w_pct);
    try std.testing.expectEqual(@as(?u8, 75), v.h_pct);

    const t = switch (v.children[0]) {
        .text => |tt| tt,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(?usize, 2), t.min_w);
    try std.testing.expectEqual(@as(?usize, 12), t.max_w);
    try std.testing.expectEqual(@as(?u8, 30), t.w_pct);
    try std.testing.expectEqual(@as(?u8, 50), t.h_pct);
}

test "protocol: write+parse text overflow field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var spans = [_]protocol.Span{
        .{ .text = "abc" },
    };
    var children = [_]protocol.Node{
        .{ .text = .{ .id = "t", .overflow = .ellipsis, .text = "long text" } },
        .{ .styled_text = .{ .id = "st", .overflow = .ellipsis, .spans = spans[0..] } },
    };
    const node = protocol.Node{ .vbox = .{ .id = "root", .children = children[0..] } };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try buf.appendSlice(std.testing.allocator, "{\"type\":\"patch\",\"v\":1,\"root\":");
    try protocol.writeNodeJson(buf.writer(std.testing.allocator), node);
    try buf.appendSlice(std.testing.allocator, "}");

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"overflow\":\"ellipsis\"") != null);

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
    try std.testing.expectEqual(protocol.TextOverflow.ellipsis, v.children[0].text.overflow);
    try std.testing.expectEqual(protocol.TextOverflow.ellipsis, v.children[1].styled_text.overflow);
}

test "protocol: reject non-canonical focus_group field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const line = "{\"type\":\"patch\",\"v\":1,\"root\":{\"type\":\"input\",\"id\":\"q\",\"focus_group\":\"main\"}}";
    try std.testing.expectError(error.UnknownField, protocol.parseMsgLeaky(arena.allocator(), line));
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
    try buf.appendSlice(std.testing.allocator, "{\"type\":\"patch\",\"v\":1,\"root\":");
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

test "protocol: write+parse controlled state fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var scroll_child = protocol.Node{ .text = .{ .id = "scroll-body", .text = "line1\nline2\nline3" } };
    var list_children = [_]protocol.Node{
        .{ .text = .{ .id = "row-1", .text = "Row 1" } },
        .{ .text = .{ .id = "row-2", .text = "Row 2" } },
    };
    var children = [_]protocol.Node{
        .{ .input = .{
            .id = "in",
            .state_mode = .controlled,
            .value = "hello",
            .cursor = 4,
            .scroll_x = 1,
            .selection_start = 1,
            .selection_end = 4,
        } },
        .{ .textarea = .{
            .id = "ta",
            .state_mode = .init,
            .value = "a\nb",
            .cursor = 2,
            .scroll_y = 1,
            .selection_start = 0,
            .selection_end = 2,
        } },
        .{ .list = .{
            .id = "list",
            .state_mode = .controlled,
            .selected_id = "row-2",
            .scroll = 1,
            .children = list_children[0..],
        } },
        .{ .scroll = .{
            .id = "sv",
            .state_mode = .controlled,
            .scroll_y = 2,
            .child = &scroll_child,
        } },
    };
    const node = protocol.Node{ .vbox = .{ .id = "root", .children = children[0..] } };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try buf.appendSlice(std.testing.allocator, "{\"type\":\"patch\",\"v\":1,\"root\":");
    try protocol.writeNodeJson(buf.writer(std.testing.allocator), node);
    try buf.appendSlice(std.testing.allocator, "}");

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"state_mode\":\"controlled\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"selection_start\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"selected_id\":\"row-2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"scroll_y\":2") != null);

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

    const in = v.children[0].input;
    try std.testing.expectEqual(protocol.StateMode.controlled, in.state_mode);
    try std.testing.expectEqualStrings("hello", in.value orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(@as(usize, 4), in.cursor orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(@as(usize, 1), in.scroll_x orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(@as(usize, 1), in.selection_start orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(@as(usize, 4), in.selection_end orelse return error.TestUnexpectedResult);

    const ta = v.children[1].textarea;
    try std.testing.expectEqual(protocol.StateMode.init, ta.state_mode);
    try std.testing.expectEqualStrings("a\nb", ta.value orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(@as(usize, 1), ta.scroll_y orelse return error.TestUnexpectedResult);

    const l = v.children[2].list;
    try std.testing.expectEqual(protocol.StateMode.controlled, l.state_mode);
    try std.testing.expectEqualStrings("row-2", l.selected_id orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(@as(usize, 1), l.scroll orelse return error.TestUnexpectedResult);

    const sv = v.children[3].scroll;
    try std.testing.expectEqual(protocol.StateMode.controlled, sv.state_mode);
    try std.testing.expectEqual(@as(usize, 2), sv.scroll_y orelse return error.TestUnexpectedResult);
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

test "protocol: write+parse selection event" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try protocol.writeSelectionEventJsonl(buf.writer(std.testing.allocator), .{
        .id = "viewport",
        .kind = .document,
        .x0 = 1,
        .y0 = 2,
        .x1 = 9,
        .y1 = 4,
        .local_x0 = 0,
        .local_y0 = 0,
        .local_x1 = 8,
        .local_y1 = 2,
        .text = "hello\nworld",
        .bytes = 11,
        .truncated = false,
    });

    const line = buf.items[0 .. buf.items.len - 1];
    const msg = try protocol.parseMsgLeaky(arena.allocator(), line);
    const ev = switch (msg) {
        .event => |e| e,
        else => return error.TestUnexpectedResult,
    };
    const sel = switch (ev) {
        .selection => |s| s,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("viewport", sel.id);
    try std.testing.expectEqual(protocol.SelectionKind.document, sel.kind);
    try std.testing.expectEqual(@as(usize, 1), sel.x0);
    try std.testing.expectEqual(@as(usize, 2), sel.y0);
    try std.testing.expectEqual(@as(usize, 9), sel.x1);
    try std.testing.expectEqual(@as(usize, 4), sel.y1);
    try std.testing.expectEqual(@as(usize, 0), sel.local_x0);
    try std.testing.expectEqual(@as(usize, 0), sel.local_y0);
    try std.testing.expectEqual(@as(usize, 8), sel.local_x1);
    try std.testing.expectEqual(@as(usize, 2), sel.local_y1);
    try std.testing.expectEqualStrings("hello\nworld", sel.text);
    try std.testing.expectEqual(@as(usize, 11), sel.bytes);
    try std.testing.expect(!sel.truncated);
}

test "protocol: parse overlay node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const line =
        "{\"type\":\"patch\",\"v\":1,\"root\":{\"type\":\"overlay\",\"id\":\"root\",\"base\":{\"type\":\"vbox\",\"id\":\"base\",\"children\":[{\"type\":\"text\",\"id\":\"a\",\"text\":\"A\"}]},\"layers\":[{\"node\":{\"type\":\"text\",\"id\":\"tip\",\"text\":\"T\"},\"anchor\":\"a\",\"placement\":\"below\",\"align\":\"center\",\"offset_x\":1,\"offset_y\":-2,\"w\":10,\"modal\":true}]}}";

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
        "{\"type\":\"patch\",\"v\":1,\"root\":{\"type\":\"box\",\"id\":\"b\",\"child\":{\"type\":\"text\",\"id\":\"t\",\"text\":\"hi\"}}}";

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
        "{\"type\":\"patch\",\"v\":1,\"root\":{\"type\":\"vbox\",\"id\":\"root\",\"justify_content\":\"center\",\"align_items\":\"center\",\"gap\":2,\"children\":[" ++
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

test "protocol: write+parse clipboard messages and events" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try protocol.writeClipboardWriteJsonl(buf.writer(std.testing.allocator), "hello", .clipboard);
    const line_write = buf.items[0 .. buf.items.len - 1];
    const msg_write = try protocol.parseMsgLeaky(arena.allocator(), line_write);
    switch (msg_write) {
        .clipboard => |c| switch (c) {
            .write => |w| {
                try std.testing.expectEqualStrings("hello", w.data);
                try std.testing.expectEqual(@as(?u64, null), w.seq);
            },
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }

    buf.clearRetainingCapacity();
    try protocol.writeClipboardReadJsonlWithSeq(buf.writer(std.testing.allocator), 7, .clipboard, 99);
    const line_read = buf.items[0 .. buf.items.len - 1];
    const msg_read = try protocol.parseMsgLeaky(arena.allocator(), line_read);
    switch (msg_read) {
        .clipboard => |c| switch (c) {
            .read => |r| {
                try std.testing.expectEqual(@as(u32, 7), r.request_id);
                try std.testing.expectEqual(@as(?u64, 99), r.seq);
            },
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }

    buf.clearRetainingCapacity();
    try protocol.writeClipboardEventJsonl(buf.writer(std.testing.allocator), .read, true, 7, "data", null);
    const line_ev = buf.items[0 .. buf.items.len - 1];
    const msg_ev = try protocol.parseMsgLeaky(arena.allocator(), line_ev);
    const ev = switch (msg_ev) {
        .event => |e| e,
        else => return error.TestUnexpectedResult,
    };
    switch (ev) {
        .clipboard => |ce| {
            try std.testing.expectEqual(protocol.ClipboardOp.read, ce.op);
            try std.testing.expect(ce.ok);
            try std.testing.expectEqual(@as(u32, 7), ce.request_id);
            try std.testing.expectEqualStrings("data", ce.data orelse return error.TestUnexpectedResult);
        },
        else => return error.TestUnexpectedResult,
    }

    buf.clearRetainingCapacity();
    try protocol.writePasteEventJsonl(buf.writer(std.testing.allocator), .clipboard, 123);
    const line_paste = buf.items[0 .. buf.items.len - 1];
    const msg_paste = try protocol.parseMsgLeaky(arena.allocator(), line_paste);
    const ev2 = switch (msg_paste) {
        .event => |e| e,
        else => return error.TestUnexpectedResult,
    };
    switch (ev2) {
        .paste => |p| {
            try std.testing.expectEqual(protocol.PasteSource.clipboard, p.source);
            try std.testing.expectEqual(@as(usize, 123), p.bytes);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "protocol: parse config keybindings message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const line =
        "{\"type\":\"config\",\"v\":1,\"keybindings\":{" ++
        "\"global\":[{\"key\":\"Tab\",\"action\":\"focus_next\"}]," ++
        "\"list\":[{\"key\":\"j\",\"action\":\"list_next\"},{\"key\":\"k\",\"action\":\"list_prev\"}]" ++
        "}}";

    const msg = try protocol.parseMsgLeaky(arena.allocator(), line);
    const cfg = switch (msg) {
        .config => |c| c.keybindings orelse return error.TestUnexpectedResult,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(cfg.global != null);
    try std.testing.expectEqual(@as(usize, 1), cfg.global.?.len);
    try std.testing.expectEqual(protocol.KeyAction.focus_next, cfg.global.?[0].action);
    try std.testing.expect(cfg.list != null);
    try std.testing.expectEqual(@as(usize, 2), cfg.list.?.len);
    try std.testing.expectEqual(protocol.KeyAction.list_next, cfg.list.?[0].action);

    const scope_line =
        "{\"type\":\"config\",\"v\":1,\"keybindings\":{\"global\":[{\"key\":\"n\",\"action\":\"focus_scope_next\"}]}}";
    const scope_msg = try protocol.parseMsgLeaky(arena.allocator(), scope_line);
    const scope_cfg = switch (scope_msg) {
        .config => |c| c.keybindings orelse return error.TestUnexpectedResult,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(protocol.KeyAction.focus_scope_next, scope_cfg.global.?[0].action);
}

test "protocol: reject unknown keybinding action" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const line =
        "{\"type\":\"config\",\"v\":1,\"keybindings\":{\"global\":[{\"key\":\"Tab\",\"action\":\"focus_later\"}]}}";
    try std.testing.expectError(error.UnknownKeyAction, protocol.parseMsgLeaky(arena.allocator(), line));
}

test "protocol: reject malformed keybinding rule" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bad_mods =
        "{\"type\":\"config\",\"v\":1,\"keybindings\":{\"global\":[{\"key\":\"Tab\",\"mods\":99,\"action\":\"focus_next\"}]}}";
    try std.testing.expectError(error.InvalidKeybindingRule, protocol.parseMsgLeaky(arena.allocator(), bad_mods));

    const missing_key =
        "{\"type\":\"config\",\"v\":1,\"keybindings\":{\"global\":[{\"action\":\"focus_next\"}]}}";
    try std.testing.expectError(error.InvalidKeybindingRule, protocol.parseMsgLeaky(arena.allocator(), missing_key));
}

test "protocol: parse config theme_spec-only message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const msg = try protocol.parseMsgLeaky(arena.allocator(), "{\"type\":\"config\",\"v\":1,\"theme_spec\":{\"base\":\"ocean\"}}");
    switch (msg) {
        .config => |cfg| {
            try std.testing.expect(cfg.keybindings == null);
            const spec = cfg.theme_spec orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(protocol.ThemeName.ocean, spec.base orelse return error.TestUnexpectedResult);
            try std.testing.expectEqual(@as(?u64, null), cfg.seq);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "protocol: parse config scrolling-only message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const msg = try protocol.parseMsgLeaky(
        arena.allocator(),
        "{\"type\":\"config\",\"v\":1,\"scrolling\":{\"scrollbars_enabled\":true,\"scrollbar_min_thumb\":2,\"wheel_scroll_lines\":4,\"wheel_list_lines\":2,\"wheel_textarea_lines\":5}}",
    );
    switch (msg) {
        .config => |cfg| {
            try std.testing.expect(cfg.keybindings == null);
            try std.testing.expect(cfg.theme_spec == null);
            const scrolling = cfg.scrolling orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(true, scrolling.scrollbars_enabled orelse false);
            try std.testing.expectEqual(@as(usize, 2), scrolling.scrollbar_min_thumb orelse 0);
            try std.testing.expectEqual(@as(usize, 4), scrolling.wheel_scroll_lines orelse 0);
            try std.testing.expectEqual(@as(usize, 2), scrolling.wheel_list_lines orelse 0);
            try std.testing.expectEqual(@as(usize, 5), scrolling.wheel_textarea_lines orelse 0);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "protocol: write+parse config scrolling message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try protocol.writeConfigJsonl(buf.writer(std.testing.allocator), .{
        .scrolling = .{
            .scrollbars_enabled = false,
            .scrollbar_min_thumb = 3,
            .wheel_scroll_lines = 7,
            .wheel_list_lines = 2,
            .wheel_textarea_lines = 6,
        },
    });

    const msg = try protocol.parseMsgLeaky(arena.allocator(), buf.items);
    switch (msg) {
        .config => |cfg| {
            const scrolling = cfg.scrolling orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(false, scrolling.scrollbars_enabled orelse true);
            try std.testing.expectEqual(@as(usize, 3), scrolling.scrollbar_min_thumb orelse 0);
            try std.testing.expectEqual(@as(usize, 7), scrolling.wheel_scroll_lines orelse 0);
            try std.testing.expectEqual(@as(usize, 2), scrolling.wheel_list_lines orelse 0);
            try std.testing.expectEqual(@as(usize, 6), scrolling.wheel_textarea_lines orelse 0);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "protocol: reject config scrolling out-of-range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(
        error.InvalidScrollingConfig,
        protocol.parseMsgLeaky(
            arena.allocator(),
            "{\"type\":\"config\",\"v\":1,\"scrolling\":{\"wheel_list_lines\":0}}",
        ),
    );
}

test "protocol: parse config seq field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const msg = try protocol.parseMsgLeaky(arena.allocator(), "{\"type\":\"config\",\"v\":1,\"theme_spec\":{\"base\":\"ocean\"},\"seq\":41}");
    switch (msg) {
        .config => |cfg| try std.testing.expectEqual(@as(?u64, 41), cfg.seq),
        else => return error.TestUnexpectedResult,
    }
}

test "protocol: write+parse config seq field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try protocol.writeConfigJsonl(buf.writer(std.testing.allocator), .{
        .theme_spec = .{ .base = .light },
        .seq = 77,
    });
    const msg = try protocol.parseMsgLeaky(arena.allocator(), buf.items);
    switch (msg) {
        .config => |cfg| try std.testing.expectEqual(@as(?u64, 77), cfg.seq),
        else => return error.TestUnexpectedResult,
    }
}

test "protocol: parse style override color var" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const msg = try protocol.parseMsgLeaky(
        arena.allocator(),
        "{\"type\":\"patch\",\"v\":1,\"root\":{\"type\":\"text\",\"id\":\"t\",\"text\":\"x\",\"style\":{\"fg\":\"$accent\",\"bg\":\"$surface\"}}}",
    );
    const root = switch (msg) {
        .patch => |p| switch (p) {
            .full => |f| f.root,
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    };
    const t = switch (root) {
        .text => |tx| tx,
        else => return error.TestUnexpectedResult,
    };
    const st = t.style orelse return error.TestUnexpectedResult;
    try std.testing.expect(st.fg == .@"var");
    try std.testing.expect(st.bg == .@"var");
    try std.testing.expectEqualStrings("accent", st.fg.@"var");
    try std.testing.expectEqualStrings("surface", st.bg.@"var");
}

test "protocol: write style override color var" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try protocol.writeStyleOverrideJson(buf.writer(std.testing.allocator), .{
        .fg = .{ .@"var" = "accent" },
        .bg = .{ .@"var" = "surface" },
    });
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"fg\":\"$accent\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"bg\":\"$surface\"") != null);
}

test "protocol: parse config theme_spec message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const line =
        "{\"type\":\"config\",\"v\":1,\"theme_spec\":{" ++
        "\"base\":\"light\"," ++
        "\"vars\":{\"accent\":\"#38bdf8\"}," ++
        "\"chrome\":{\"input_prefix\":\"# \"}," ++
        "\"overlays\":{\"focused\":{\"underline\":true}}," ++
        "\"rules\":[{\"selector\":\"box.button.primary:hover\",\"style\":{\"bg\":\"$accent\",\"bold\":true}}]" ++
        "}}";
    const msg = try protocol.parseMsgLeaky(arena.allocator(), line);
    switch (msg) {
        .config => |cfg| {
            const spec = cfg.theme_spec orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(protocol.ThemeName.light, spec.base orelse return error.TestUnexpectedResult);
            try std.testing.expectEqual(@as(usize, 1), spec.vars.len);
            try std.testing.expectEqualStrings("accent", spec.vars[0].name);
            try std.testing.expectEqual(@as(usize, 1), spec.rules.len);
            try std.testing.expectEqualStrings("box.button.primary:hover", spec.rules[0].selector);
            try std.testing.expect(spec.rules[0].style.bg == .@"var");
            try std.testing.expectEqualStrings("accent", spec.rules[0].style.bg.@"var");
            try std.testing.expect(spec.chrome.input_prefix != null);
            try std.testing.expect(spec.overlays.focused != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "protocol: reject theme_spec var names with hyphen" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const line =
        "{\"type\":\"config\",\"v\":1,\"theme_spec\":{" ++
        "\"vars\":{\"accent-primary\":\"#38bdf8\"}" ++
        "}}";
    try std.testing.expectError(error.WrongType, protocol.parseMsgLeaky(arena.allocator(), line));
}

test "protocol: write+parse config theme_spec message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var rules = [_]protocol.ThemeRule{
        .{
            .selector = "box.button.primary:hover",
            .style = .{ .bg = .{ .@"var" = "accent" }, .attrs_set = style.ATTR_BOLD, .attrs_values = style.ATTR_BOLD },
        },
    };
    var vars = [_]protocol.ThemeVarEntry{
        .{ .name = "accent", .value = .{ .r = 0x38, .g = 0xbd, .b = 0xf8 } },
    };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try protocol.writeConfigJsonl(buf.writer(std.testing.allocator), .{
        .theme_spec = .{
            .base = .default,
            .vars = vars[0..],
            .rules = rules[0..],
        },
    });
    const msg = try protocol.parseMsgLeaky(arena.allocator(), buf.items);
    switch (msg) {
        .config => |cfg| {
            const spec = cfg.theme_spec orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(usize, 1), spec.rules.len);
            try std.testing.expect(spec.rules[0].style.bg == .@"var");
            try std.testing.expectEqualStrings("accent", spec.rules[0].style.bg.@"var");
        },
        else => return error.TestUnexpectedResult,
    }
}

test "protocol: write config rejects empty payload" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.MissingField,
        protocol.writeConfigJsonl(buf.writer(std.testing.allocator), .{}),
    );
}

test "protocol: class roundtrip via writer+parser" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const root = protocol.Node{ .text = .{
        .id = "title",
        .class = "accent",
        .text = "Hello",
    } };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try buf.appendSlice(std.testing.allocator, "{\"type\":\"patch\",\"v\":1,\"root\":");
    try protocol.writeNodeJson(buf.writer(std.testing.allocator), root);
    try buf.appendSlice(std.testing.allocator, "}");

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"class\":\"accent\"") != null);
    const msg = try protocol.parseMsgLeaky(arena.allocator(), buf.items);
    const parsed = switch (msg) {
        .patch => |p| switch (p) {
            .full => |f| f.root,
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    };
    switch (parsed) {
        .text => |t| try std.testing.expectEqualStrings("accent", t.class orelse return error.TestUnexpectedResult),
        else => return error.TestUnexpectedResult,
    }
}

test "protocol: parse textarea v2 key actions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const line =
        "{\"type\":\"config\",\"v\":1,\"keybindings\":{" ++
        "\"textarea\":[" ++
        "{\"key\":\"ArrowLeft\",\"mods\":1,\"action\":\"textarea_select_left\"}," ++
        "{\"key\":\"a\",\"mods\":2,\"action\":\"textarea_select_all\"}," ++
        "{\"key\":\"z\",\"mods\":2,\"action\":\"textarea_undo\"}" ++
        "]}}";
    const msg = try protocol.parseMsgLeaky(arena.allocator(), line);
    const cfg = switch (msg) {
        .config => |c| c.keybindings orelse return error.TestUnexpectedResult,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(cfg.textarea != null);
    try std.testing.expectEqual(protocol.KeyAction.textarea_select_left, cfg.textarea.?[0].action);
    try std.testing.expectEqual(protocol.KeyAction.textarea_select_all, cfg.textarea.?[1].action);
    try std.testing.expectEqual(protocol.KeyAction.textarea_undo, cfg.textarea.?[2].action);
}

test "protocol: parse input v2 key actions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const line =
        "{\"type\":\"config\",\"v\":1,\"keybindings\":{" ++
        "\"input\":[" ++
        "{\"key\":\"ArrowLeft\",\"mods\":1,\"action\":\"input_select_left\"}," ++
        "{\"key\":\"a\",\"mods\":2,\"action\":\"input_select_all\"}," ++
        "{\"key\":\"z\",\"mods\":2,\"action\":\"input_undo\"}" ++
        "]}}";
    const msg = try protocol.parseMsgLeaky(arena.allocator(), line);
    const cfg = switch (msg) {
        .config => |c| c.keybindings orelse return error.TestUnexpectedResult,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(cfg.input != null);
    try std.testing.expectEqual(protocol.KeyAction.input_select_left, cfg.input.?[0].action);
    try std.testing.expectEqual(protocol.KeyAction.input_select_all, cfg.input.?[1].action);
    try std.testing.expectEqual(protocol.KeyAction.input_undo, cfg.input.?[2].action);
}

test "protocol: parse input selection_style" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const line =
        "{\"type\":\"patch\",\"v\":1,\"root\":{" ++
        "\"type\":\"input\",\"id\":\"in\",\"selection_style\":{\"inverse\":true},\"placeholder\":\"Type\"" ++
        "}}";
    const msg = try protocol.parseMsgLeaky(arena.allocator(), line);
    const patch = switch (msg) {
        .patch => |p| p,
        else => return error.TestUnexpectedResult,
    };
    const root = switch (patch) {
        .full => |f| f.root,
        else => return error.TestUnexpectedResult,
    };
    switch (root) {
        .input => |inp| {
            try std.testing.expect(inp.selection_style != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "protocol: parse grid node with tracks and placement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const line =
        "{\"type\":\"patch\",\"v\":1,\"root\":{" ++
        "\"type\":\"grid\",\"id\":\"g\",\"rows\":[\"auto\",\"1fr\"],\"cols\":[10,\"2fr\"],\"gap_x\":1,\"gap_y\":1," ++
        "\"areas\":[\"header header\",\"sidebar content\"]," ++
        "\"children\":[" ++
        "{\"type\":\"text\",\"id\":\"t1\",\"grid_area\":\"header\",\"text\":\"Header\"}," ++
        "{\"type\":\"text\",\"id\":\"t2\",\"grid_row\":1,\"grid_col\":1,\"row_span\":1,\"col_span\":1,\"text\":\"Body\"}" ++
        "]}}";
    const msg = try protocol.parseMsgLeaky(arena.allocator(), line);
    const patch = switch (msg) {
        .patch => |p| p,
        else => return error.TestUnexpectedResult,
    };
    const root = switch (patch) {
        .full => |f| f.root,
        else => return error.TestUnexpectedResult,
    };
    switch (root) {
        .grid => |g| {
            try std.testing.expectEqual(@as(usize, 2), g.rows.len);
            try std.testing.expectEqual(@as(usize, 2), g.cols.len);
            try std.testing.expectEqual(@as(usize, 2), g.children.len);
            switch (g.rows[0]) {
                .auto => {},
                else => return error.TestUnexpectedResult,
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

test "protocol: parse patch seq field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const full_line = "{\"type\":\"patch\",\"v\":1,\"seq\":12,\"root\":{\"type\":\"text\",\"id\":\"t\",\"text\":\"ok\"}}";
    const full_msg = try protocol.parseMsgLeaky(arena.allocator(), full_line);
    const full_patch = switch (full_msg) {
        .patch => |p| p,
        else => return error.TestUnexpectedResult,
    };
    switch (full_patch) {
        .full => |f| try std.testing.expectEqual(@as(?u64, 12), f.seq),
        else => return error.TestUnexpectedResult,
    }

    const target_line = "{\"type\":\"patch\",\"v\":1,\"seq\":99,\"target\":\"t\",\"mode\":\"replace\",\"node\":{\"type\":\"text\",\"id\":\"t\",\"text\":\"next\"}}";
    const target_msg = try protocol.parseMsgLeaky(arena.allocator(), target_line);
    const target_patch = switch (target_msg) {
        .patch => |p| p,
        else => return error.TestUnexpectedResult,
    };
    switch (target_patch) {
        .target => |t| try std.testing.expectEqual(@as(?u64, 99), t.seq),
        else => return error.TestUnexpectedResult,
    }
}

test "protocol: write+parse rendered and dropped events" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var rendered_buf: std.ArrayList(u8) = .empty;
    defer rendered_buf.deinit(std.testing.allocator);
    try protocol.writeRenderedEventJsonl(rendered_buf.writer(std.testing.allocator), 41, 3, 1024, 88);
    const rendered_msg = try protocol.parseMsgLeaky(arena.allocator(), rendered_buf.items);
    switch (rendered_msg) {
        .event => |ev| switch (ev) {
            .rendered => |r| {
                try std.testing.expectEqual(@as(u64, 41), r.seq);
                try std.testing.expectEqual(@as(u64, 3), r.dropped);
                try std.testing.expectEqual(@as(usize, 1024), r.bytes);
                try std.testing.expectEqual(@as(usize, 88), r.changed_cells);
            },
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }

    var dropped_buf: std.ArrayList(u8) = .empty;
    defer dropped_buf.deinit(std.testing.allocator);
    try protocol.writeDroppedEventJsonl(dropped_buf.writer(std.testing.allocator), 42, "stale_seq");
    const dropped_msg = try protocol.parseMsgLeaky(arena.allocator(), dropped_buf.items);
    switch (dropped_msg) {
        .event => |ev| switch (ev) {
            .dropped => |d| {
                try std.testing.expectEqual(@as(u64, 42), d.seq);
                try std.testing.expectEqualStrings("stale_seq", d.reason);
            },
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

test "protocol: write+parse error event" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try protocol.writeErrorEventJsonl(
        buf.writer(std.testing.allocator),
        "config_rejected",
        "backend config rejected",
        42,
        "InvalidKeybindingRule",
    );

    const msg = try protocol.parseMsgLeaky(arena.allocator(), buf.items);
    switch (msg) {
        .event => |ev| switch (ev) {
            .@"error" => |err_ev| {
                try std.testing.expectEqualStrings("config_rejected", err_ev.code);
                try std.testing.expectEqualStrings("backend config rejected", err_ev.message);
                try std.testing.expectEqual(@as(?u64, 42), err_ev.seq);
                try std.testing.expectEqualStrings("InvalidKeybindingRule", err_ev.context orelse return error.TestUnexpectedResult);
            },
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

test "protocol: parse config_ack event" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const line =
        "{\"type\":\"event\",\"v\":1,\"name\":\"config_ack\",\"applied\":[\"keybindings\"],\"rejected\":[{\"key\":\"theme_spec\",\"reason\":\"UnknownThemeSpecBase\"}]}";
    const msg = try protocol.parseMsgLeaky(arena.allocator(), line);
    switch (msg) {
        .event => |ev| switch (ev) {
            .config_ack => |ack| {
                try std.testing.expectEqual(@as(usize, 1), ack.applied.len);
                try std.testing.expectEqualStrings("keybindings", ack.applied[0]);
                try std.testing.expectEqual(@as(usize, 1), ack.rejected.len);
                try std.testing.expectEqualStrings("theme_spec", ack.rejected[0].key);
                try std.testing.expectEqualStrings("UnknownThemeSpecBase", ack.rejected[0].reason);
            },
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

test "protocol: write+parse config_ack event" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    const applied = [_][]const u8{ "keybindings", "theme_spec" };
    const rejected = [_]protocol.ConfigAckRejected{
        .{ .key = "theme_spec", .reason = "keybindings_rejected" },
    };
    try protocol.writeConfigAckEventJsonl(buf.writer(std.testing.allocator), .{
        .applied = applied[0..],
        .rejected = rejected[0..],
    });

    const msg = try protocol.parseMsgLeaky(arena.allocator(), buf.items);
    switch (msg) {
        .event => |ev| switch (ev) {
            .config_ack => |ack| {
                try std.testing.expectEqual(@as(usize, 2), ack.applied.len);
                try std.testing.expectEqualStrings("keybindings", ack.applied[0]);
                try std.testing.expectEqualStrings("theme_spec", ack.applied[1]);
                try std.testing.expectEqual(@as(usize, 1), ack.rejected.len);
                try std.testing.expectEqualStrings("theme_spec", ack.rejected[0].key);
                try std.testing.expectEqualStrings("keybindings_rejected", ack.rejected[0].reason);
            },
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

test "protocol: parse ack event" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const line = "{\"type\":\"event\",\"v\":1,\"name\":\"ack\",\"seq\":42,\"status\":\"applied\",\"detail\":\"target\"}";
    const msg = try protocol.parseMsgLeaky(arena.allocator(), line);
    switch (msg) {
        .event => |ev| switch (ev) {
            .ack => |ack| {
                try std.testing.expectEqual(@as(u64, 42), ack.seq);
                try std.testing.expectEqual(protocol.AckStatus.applied, ack.status);
                try std.testing.expectEqualStrings("target", ack.detail orelse return error.TestUnexpectedResult);
            },
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

test "protocol: write+parse ack event" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try protocol.writeAckEventJsonl(buf.writer(std.testing.allocator), 88, "dropped_overflow", "queue_overflow");
    const msg = try protocol.parseMsgLeaky(arena.allocator(), buf.items);
    switch (msg) {
        .event => |ev| switch (ev) {
            .ack => |ack| {
                try std.testing.expectEqual(@as(u64, 88), ack.seq);
                try std.testing.expectEqual(protocol.AckStatus.dropped_overflow, ack.status);
                try std.testing.expectEqualStrings("queue_overflow", ack.detail orelse return error.TestUnexpectedResult);
            },
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

test "protocol: write+parse hello event" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try protocol.writeHelloEventJsonl(buf.writer(std.testing.allocator), protocol.PROTOCOL_VERSION, .{
        .ansi = true,
        .alt_screen = true,
        .bracketed_paste = true,
        .mouse_sgr = false,
        .osc52 = true,
        .color = "ansi256",
    }, .{
        .max_fps = 60,
        .frame_interval_ns = 16_666_666,
        .max_pending_targets = 512,
        .max_backend_lines_per_iter = 256,
        .queue_overflow = "drop_oldest",
    });

    const msg = try protocol.parseMsgLeaky(arena.allocator(), buf.items);
    switch (msg) {
        .event => |ev| switch (ev) {
            .hello => |h| {
                try std.testing.expectEqual(protocol.PROTOCOL_VERSION, h.protocol_version);
                try std.testing.expect(h.caps.ansi);
                try std.testing.expect(h.caps.alt_screen);
                try std.testing.expect(h.caps.bracketed_paste);
                try std.testing.expect(!h.caps.mouse_sgr);
                try std.testing.expect(h.caps.osc52);
                try std.testing.expectEqualStrings("ansi256", h.caps.color);
                try std.testing.expectEqual(@as(u32, 60), h.limits.max_fps);
                try std.testing.expectEqual(@as(u64, 16_666_666), h.limits.frame_interval_ns);
                try std.testing.expectEqual(@as(usize, 512), h.limits.max_pending_targets);
                try std.testing.expectEqual(@as(usize, 256), h.limits.max_backend_lines_per_iter);
                try std.testing.expectEqualStrings("drop_oldest", h.limits.queue_overflow);
            },
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

test "protocol: write helpers always emit canonical version field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try protocol.writeFocusEventJsonl(buf.writer(std.testing.allocator), "query");
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"v\":1") != null);
    const canonical_msg = try protocol.parseMsgLeaky(arena.allocator(), buf.items);
    switch (canonical_msg) {
        .event => |ev| switch (ev) {
            .focus => |f| try std.testing.expectEqual(@as(?u32, 1), f.v),
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }

    buf.clearRetainingCapacity();
    try protocol.writeFocusEventJsonlVersion(buf.writer(std.testing.allocator), "query", 1);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"v\":1") != null);
    const with_v_msg = try protocol.parseMsgLeaky(arena.allocator(), buf.items);
    switch (with_v_msg) {
        .event => |ev| switch (ev) {
            .focus => |f| try std.testing.expectEqual(@as(?u32, 1), f.v),
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

test "protocol: reject missing or unsupported top-level version field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(
        error.MissingField,
        protocol.parseMsgLeaky(arena.allocator(), "{\"type\":\"event\",\"name\":\"focus\",\"id\":\"query\"}"),
    );
    try std.testing.expectError(
        error.UnsupportedVersion,
        protocol.parseMsgLeaky(arena.allocator(), "{\"type\":\"event\",\"v\":2,\"name\":\"focus\",\"id\":\"query\"}"),
    );
}

test "protocol: parse top-level version field across message types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const patch_msg = try protocol.parseMsgLeaky(
        arena.allocator(),
        "{\"type\":\"patch\",\"v\":1,\"root\":{\"type\":\"text\",\"id\":\"t\",\"text\":\"ok\"}}",
    );
    switch (patch_msg) {
        .patch => |p| switch (p) {
            .full => |f| try std.testing.expectEqual(@as(?u32, 1), f.v),
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }

    const clipboard_msg = try protocol.parseMsgLeaky(
        arena.allocator(),
        "{\"type\":\"clipboard\",\"v\":1,\"op\":\"read\",\"request_id\":7}",
    );
    switch (clipboard_msg) {
        .clipboard => |c| switch (c) {
            .read => |r| try std.testing.expectEqual(@as(?u32, 1), r.v),
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }

    const config_msg = try protocol.parseMsgLeaky(
        arena.allocator(),
        "{\"type\":\"config\",\"v\":1,\"theme_spec\":{\"base\":\"default\"}}",
    );
    switch (config_msg) {
        .config => |cfg| try std.testing.expectEqual(@as(?u32, 1), cfg.v),
        else => return error.TestUnexpectedResult,
    }
}

test "protocol: reject removed theme message type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(
        error.UnknownMsgType,
        protocol.parseMsgLeaky(arena.allocator(), "{\"type\":\"theme\",\"v\":1,\"name\":\"ocean\"}"),
    );
}

test "protocol: write+parse vlist node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var children = [_]protocol.Node{
        .{ .text = .{ .id = "row-10", .text = "ten" } },
        .{ .text = .{ .id = "row-11", .text = "eleven" } },
    };
    const node = protocol.Node{ .vlist = .{
        .id = "results",
        .height = 5,
        .state_mode = .controlled,
        .selected_index = 11,
        .scroll = 9,
        .total = 1000,
        .window_start = 10,
        .item_id_prefix = "row-",
        .overscan = 10,
        .req = 55,
        .children = children[0..],
    } };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try buf.appendSlice(std.testing.allocator, "{\"type\":\"patch\",\"v\":1,\"root\":");
    try protocol.writeNodeJson(buf.writer(std.testing.allocator), node);
    try buf.appendSlice(std.testing.allocator, "}");

    const msg = try protocol.parseMsgLeaky(arena.allocator(), buf.items);
    const root = switch (msg) {
        .patch => |p| switch (p) {
            .full => |f| f.root,
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    };
    const l = switch (root) {
        .vlist => |vv| vv,
        else => return error.TestUnexpectedResult,
    };

    try std.testing.expectEqualStrings("results", l.id);
    try std.testing.expectEqual(@as(usize, 1000), l.total);
    try std.testing.expectEqual(@as(usize, 10), l.window_start);
    try std.testing.expectEqualStrings("row-", l.item_id_prefix);
    try std.testing.expectEqual(@as(?usize, 11), l.selected_index);
    try std.testing.expectEqual(@as(?usize, 9), l.scroll);
    try std.testing.expectEqual(@as(?usize, 10), l.overscan);
    try std.testing.expectEqual(@as(?u64, 55), l.req);
    try std.testing.expectEqual(@as(usize, 2), l.children.len);
}

test "protocol: parse+write vlist range and optional indices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try protocol.writeVListRangeEventJsonl(buf.writer(std.testing.allocator), .{
        .id = "results",
        .request_id = 123,
        .start = 480,
        .len = 80,
        .scroll = 500,
        .viewport_h = 60,
        .overscan = 10,
        .reason = .scroll,
    });
    const range_msg = try protocol.parseMsgLeaky(arena.allocator(), buf.items);
    switch (range_msg) {
        .event => |ev| switch (ev) {
            .vlist_range => |r| {
                try std.testing.expectEqualStrings("results", r.id);
                try std.testing.expectEqual(@as(u64, 123), r.request_id);
                try std.testing.expectEqual(@as(usize, 480), r.start);
                try std.testing.expectEqual(@as(usize, 80), r.len);
                try std.testing.expectEqual(protocol.VListRangeReason.scroll, r.reason);
            },
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }

    const select_line = "{\"type\":\"event\",\"v\":1,\"name\":\"select\",\"id\":\"results\",\"item\":\"row-99\",\"index\":99}";
    const select_msg = try protocol.parseMsgLeaky(arena.allocator(), select_line);
    switch (select_msg) {
        .event => |ev| switch (ev) {
            .select => |s| try std.testing.expectEqual(@as(?usize, 99), s.index),
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }

    const pointer_line = "{\"type\":\"event\",\"v\":1,\"name\":\"pointer\",\"kind\":\"down\",\"id\":\"results\",\"x\":1,\"y\":2,\"local_x\":0,\"local_y\":0,\"button\":\"left\",\"buttons\":1,\"mods\":0,\"clicks\":1,\"scroll_dx\":0,\"scroll_dy\":0,\"item\":\"row-99\",\"item_index\":99,\"captured\":false}";
    const pointer_msg = try protocol.parseMsgLeaky(arena.allocator(), pointer_line);
    switch (pointer_msg) {
        .event => |ev| switch (ev) {
            .pointer => |p| try std.testing.expectEqual(@as(?usize, 99), p.item_index),
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

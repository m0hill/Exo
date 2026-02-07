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
            .write => |w| try std.testing.expectEqualStrings("hello", w.data),
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }

    buf.clearRetainingCapacity();
    try protocol.writeClipboardReadJsonl(buf.writer(std.testing.allocator), 7, .clipboard);
    const line_read = buf.items[0 .. buf.items.len - 1];
    const msg_read = try protocol.parseMsgLeaky(arena.allocator(), line_read);
    switch (msg_read) {
        .clipboard => |c| switch (c) {
            .read => |r| try std.testing.expectEqual(@as(u32, 7), r.request_id),
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

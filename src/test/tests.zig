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

fn cellByte(frame: *const Frame, row: usize, col: usize) u8 {
    const c = frame.rowSlice(row)[col];
    if (c.len == 0) return ' ';
    return c.bytes[0];
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

const std = @import("std");

const tui = @import("tui");
const protocol = tui.protocol;
const renderer_mod = tui.renderer;
const testing_terminal = @import("testing_terminal.zig");
const input = tui.input;
const state = tui.state;
const tree = tui.tree;

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
        .inputs = &.{.{ .id = "query", .value = "", .cursor = 0 }},
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
        .inputs = &.{.{ .id = "query", .value = "", .cursor = 0 }},
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
        .inputs = &.{.{ .id = "query", .value = "hi", .cursor = 2 }},
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
        .inputs = &.{.{ .id = "query", .value = "", .cursor = 0 }},
    });
    const out1_len: usize = term.out.items.len;
    try std.testing.expect(std.mem.indexOf(u8, term.out.items, "\x1b[2J") != null);

    term.reset();

    try renderer.draw(&term, root2, .{
        .focused_id = "query",
        .inputs = &.{.{ .id = "query", .value = "", .cursor = 0 }},
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
        .inputs = &.{.{ .id = "query", .value = "hello", .cursor = 5 }},
    });
    try std.testing.expect(renderer.last_metrics.full);

    term.reset();
    term.size = .{ .rows = 8, .cols = 80 };

    try renderer.draw(&term, root, .{
        .focused_id = "query",
        .inputs = &.{.{ .id = "query", .value = "hello", .cursor = 5 }},
    });
    try std.testing.expect(renderer.last_metrics.full);
    try std.testing.expect(std.mem.indexOf(u8, term.out.items, "\x1b[2J") != null);
}

test "render: cursor column clamped after resize" {
    var term = testing_terminal.Terminal.init(std.testing.allocator, .{ .rows = 5, .cols = 80 });
    defer term.deinit();

    var renderer = renderer_mod.Renderer.init(std.testing.allocator);
    defer renderer.deinit();

    var children = [_]protocol.Node{
        .{ .text = .{ .id = "title", .text = "Tracer Demo" } },
        .{ .input = .{ .id = "query", .placeholder = "Type here" } },
    };
    const root = protocol.Node{ .vbox = .{ .id = "root", .children = children[0..] } };

    try renderer.draw(&term, root, .{
        .focused_id = "query",
        .inputs = &.{.{ .id = "query", .value = "hello", .cursor = 5 }},
    });
    term.reset();

    term.size = .{ .rows = 5, .cols = 3 };
    try renderer.draw(&term, root, .{
        .focused_id = "query",
        .inputs = &.{.{ .id = "query", .value = "hello", .cursor = 5 }},
    });

    // With wrapping (cols=3), the input becomes multi-row and the cursor is clamped to the last visible cell.
    try std.testing.expect(std.mem.indexOf(u8, term.out.items, "\x1b[5;3H") != null);
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

test "render: input cursor row/col maps after wrap" {
    var term = testing_terminal.Terminal.init(std.testing.allocator, .{ .rows = 6, .cols = 8 });
    defer term.deinit();

    var renderer = renderer_mod.Renderer.init(std.testing.allocator);
    defer renderer.deinit();

    var children = [_]protocol.Node{
        .{ .text = .{ .id = "title", .text = "T" } },
        .{ .input = .{ .id = "query", .placeholder = "Type" } },
    };
    const root = protocol.Node{ .vbox = .{ .id = "root", .children = children[0..] } };

    try renderer.draw(&term, root, .{
        .focused_id = "query",
        .inputs = &.{.{ .id = "query", .value = "abcdefghi", .cursor = 7 }},
    });

    const out = term.out.items;
    try std.testing.expect(std.mem.indexOf(u8, out, "> abcdef") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "  ghi") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[3;4H") != null);
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

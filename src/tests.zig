const std = @import("std");

const protocol = @import("protocol.zig");
const render = @import("render.zig");
const testing_terminal = @import("testing_terminal.zig");
const input = @import("input.zig");
const tree = @import("tree.zig");

test "render: focused input shows cursor + placeholder" {
    var term = testing_terminal.Terminal.init(std.testing.allocator, .{ .rows = 10, .cols = 80 });
    defer term.deinit();

    var children = [_]protocol.Node{
        .{ .text = .{ .id = "title", .text = "Tracer Demo" } },
        .{ .text = .{ .id = "hint", .text = "Tab to focus input" } },
        .{ .text = .{ .id = "clock", .text = "Tick: 0" } },
        .{ .input = .{ .id = "query", .placeholder = "Type here" } },
        .{ .text = .{ .id = "status", .text = "State: OFF" } },
    };
    const root = protocol.Node{ .vbox = .{ .id = "root", .children = children[0..] } };

    try render.render(&term, root, .{
        .focused_id = "query",
        .input_id = "query",
        .input_value = "",
        .input_cursor = 0,
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

    var children = [_]protocol.Node{
        .{ .text = .{ .id = "title", .text = "Tracer Demo" } },
        .{ .input = .{ .id = "query", .placeholder = "Type here" } },
    };
    const root = protocol.Node{ .vbox = .{ .id = "root", .children = children[0..] } };

    try render.render(&term, root, .{
        .focused_id = null,
        .input_id = "query",
        .input_value = "",
        .input_cursor = 0,
    });

    const out = term.out.items;
    try std.testing.expect(std.mem.indexOf(u8, out, "> [Type here]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[?25l") != null);
}

test "render: cursor column tracks input_cursor" {
    var term = testing_terminal.Terminal.init(std.testing.allocator, .{ .rows = 10, .cols = 80 });
    defer term.deinit();

    var children = [_]protocol.Node{
        .{ .text = .{ .id = "title", .text = "Tracer Demo" } },
        .{ .text = .{ .id = "clock", .text = "Tick: 0" } },
        .{ .input = .{ .id = "query", .placeholder = "Type here" } },
    };
    const root = protocol.Node{ .vbox = .{ .id = "root", .children = children[0..] } };

    try render.render(&term, root, .{
        .focused_id = "query",
        .input_id = "query",
        .input_value = "hi",
        .input_cursor = 2,
    });

    const out = term.out.items;
    // Lines: title(1), clock(2), input(3). prefix is "> " => cursor col = 2 + 2 + 1 = 5.
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[3;5H") != null);
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

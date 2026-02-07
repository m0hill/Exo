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

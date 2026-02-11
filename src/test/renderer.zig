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
    try std.testing.expect(std.mem.indexOf(u8, term.out.items, "\x1b[H") != null);

    term.reset();

    try renderer.draw(&term, root2, .{
        .focused_id = "query",
        .inputs = &.{.{ .id = "query", .value = "", .cursor = 0, .scroll_x = 0 }},
    });

    const out2 = term.out.items;
    try std.testing.expect(std.mem.indexOf(u8, out2, "\x1b[H") == null);
    try std.testing.expect(out2.len * 2 < out1_len);
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
    try std.testing.expect(std.mem.indexOf(u8, term.out.items, "\x1b[H") != null);
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

test "renderer: dumb paint emits no escape bytes" {
    var term = testing_terminal.Terminal.init(std.testing.allocator, .{ .rows = 3, .cols = 10 });
    defer term.deinit();

    var renderer = renderer_mod.Renderer.initWithMode(std.testing.allocator, .ansi16);
    defer renderer.deinit();

    var children = [_]protocol.Node{
        .{ .text = .{ .id = "t", .text = "Hello" } },
    };
    const root = protocol.Node{ .vbox = .{
        .id = "root",
        .children = children[0..],
    } };

    var caps: termcaps.Caps = .{};
    caps.ansi = false;
    caps.cursor_address = false;

    try renderer.drawWithCaps(&term, caps, root, .{}, null);
    try std.testing.expect(std.mem.indexOfScalar(u8, term.out.items, 0x1b) == null);
}

test "renderer: screen selection overlay sets inverse attr" {
    var frame: Frame = .{};
    defer frame.deinit(std.testing.allocator);
    try frame.resize(std.testing.allocator, 3, 6);
    frame.putGraphemeStyled(1, 2, "x", 1, .{});
    frame.putGraphemeStyled(1, 3, "y", 1, .{});

    renderer_mod.applyScreenSelection(&frame, .{
        .enabled = true,
        .clip = .{ .x = 1, .y = 1, .w = 4, .h = 1 },
        .a = .{ .x = 2, .y = 1 },
        .b = .{ .x = 4, .y = 1 },
    });

    try std.testing.expect((frame.rowSlice(1)[1].style.attrs & style.ATTR_INVERSE) == 0);
    try std.testing.expect((frame.rowSlice(1)[2].style.attrs & style.ATTR_INVERSE) != 0);
    try std.testing.expect((frame.rowSlice(1)[3].style.attrs & style.ATTR_INVERSE) != 0);
    try std.testing.expect((frame.rowSlice(1)[4].style.attrs & style.ATTR_INVERSE) != 0);
    try std.testing.expect((frame.rowSlice(1)[5].style.attrs & style.ATTR_INVERSE) == 0);
}

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

test "render: class-based theme styles differ across presets" {
    var frame_default: Frame = .{};
    defer frame_default.deinit(std.testing.allocator);
    try frame_default.resize(std.testing.allocator, 1, 8);
    frame_default.clear(' ');

    var frame_light: Frame = .{};
    defer frame_light.deinit(std.testing.allocator);
    try frame_light.resize(std.testing.allocator, 1, 8);
    frame_light.clear(' ');

    const root = protocol.Node{ .text = .{ .id = "t", .class = "accent", .text = "X" } };
    render.renderToFrame(root, .{ .theme = &render.default_theme }, &frame_default);
    render.renderToFrame(root, .{ .theme = &render.light_theme }, &frame_light);

    try std.testing.expectEqual(@as(u1, 1), frame_default.rowSlice(0)[0].style.has_fg);
    try std.testing.expectEqual(@as(u1, 1), frame_light.rowSlice(0)[0].style.has_fg);
    try std.testing.expect(frame_default.rowSlice(0)[0].style.fg != frame_light.rowSlice(0)[0].style.fg);
}

test "render: theme chrome changes input prefix" {
    var frame: Frame = .{};
    defer frame.deinit(std.testing.allocator);
    try frame.resize(std.testing.allocator, 1, 12);
    frame.clear(' ');

    const root = protocol.Node{ .input = .{ .id = "i", .placeholder = "name" } };
    const st: render.InputState = .{ .id = "i", .value = "", .cursor = 0, .scroll_x = 0 };
    render.renderToFrame(root, .{ .theme = &render.ocean_theme, .focused_id = "i", .inputs = &.{st} }, &frame);
    try std.testing.expectEqualStrings("»", cellText(&frame, 0, 0));
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

test "render: grid explicit placement overrides area placement" {
    var rows = [_]protocol.GridTrack{
        .{ .fixed = 2 },
        .{ .fixed = 2 },
    };
    var cols = [_]protocol.GridTrack{
        .{ .fixed = 4 },
        .{ .fixed = 4 },
    };
    const areas = [_][]const u8{
        "left right",
        "left right",
    };
    var children = [_]protocol.Node{
        .{ .text = .{
            .id = "explicit",
            .grid_area = "left",
            .grid_row = 1,
            .grid_col = 1,
            .text = "X",
        } },
    };
    const root = protocol.Node{ .grid = .{
        .id = "g",
        .rows = rows[0..],
        .cols = cols[0..],
        .areas = areas[0..],
        .children = children[0..],
    } };

    const r = render.findRectForId(root, 4, 8, "explicit") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 4), r.x);
    try std.testing.expectEqual(@as(usize, 2), r.y);
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

test "render: input selection paints selected graphemes" {
    var frame: Frame = .{};
    defer frame.deinit(std.testing.allocator);
    try frame.resize(std.testing.allocator, 1, 8);
    frame.clear(' ');

    const root = protocol.Node{ .input = .{ .id = "i" } };
    const st: render.InputState = .{
        .id = "i",
        .value = "abc",
        .cursor = 3,
        .scroll_x = 0,
        .selection_start = 1,
        .selection_end = 3,
    };
    render.renderToFrame(root, .{ .focused_id = "i", .inputs = &.{st} }, &frame);

    try std.testing.expectEqual(@as(u8, 'a'), cellByte(&frame, 0, 2));
    try std.testing.expectEqual(@as(u8, 'b'), cellByte(&frame, 0, 3));
    try std.testing.expectEqual(@as(u8, 'c'), cellByte(&frame, 0, 4));
    try std.testing.expect((frame.rowSlice(0)[3].style.attrs & style.ATTR_INVERSE) != 0);
    try std.testing.expect((frame.rowSlice(0)[4].style.attrs & style.ATTR_INVERSE) != 0);
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
    try std.testing.expect(std.mem.indexOf(u8, out, "Hello\x1b[K\r\nWorldWorld\x1b[3;1HWorld") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, out, "Hello\x1b[K\r\nWorldWorld\x1b[3;1HWorld") != null);
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

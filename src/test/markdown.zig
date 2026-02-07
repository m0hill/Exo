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

const std = @import("std");

const protocol = @import("protocol.zig");
const style = @import("style.zig");

pub const Theme = struct {
    heading: style.StyleOverride = attrStyle(.bold, true),
    bold: style.StyleOverride = attrStyle(.bold, true),
    italic: style.StyleOverride = attrStyle(.italic, true),
    code: style.StyleOverride = .{
        .fg = .{ .rgb = .{ .r = 0xE5, .g = 0xE7, .b = 0xEB } },
        .bg = .{ .rgb = .{ .r = 0x11, .g = 0x18, .b = 0x27 } },
    },
    quote_prefix: style.StyleOverride = attrStyle(.dim, true),
    bullet_prefix: style.StyleOverride = attrStyle(.dim, true),
};

pub const InlineOptions = struct {
    sanitize_control: bool = true,
    /// When false, spans borrow slices from the input markdown buffer when possible.
    /// Caller must keep `md` alive for as long as the spans are used.
    own_text: bool = true,
    /// Defensive cap; if exceeded, compilation falls back to a single plain span for that node.
    max_spans: usize = 4096,
    theme: Theme = .{},
};

pub const Options = struct {
    /// Root node id.
    id: []const u8 = "md",
    /// Prefix used for generated block ids.
    id_prefix: []const u8 = "md",
    /// Emit `hbox` prefix + body for lists/quotes to align wrapped lines.
    prefix_layout: bool = true,
    /// Use pretty prefixes (`• `, `│ `) instead of ASCII (`- `, `> `).
    pretty_prefixes: bool = true,
    sanitize_control: bool = true,
    /// When false, spans borrow slices from the input markdown buffer when possible.
    /// Caller must keep `md` alive for as long as the compiled tree is used.
    own_text: bool = true,
    /// Defensive cap; if exceeded, compilation falls back to a single plain span for that node.
    max_spans: usize = 4096,
    theme: Theme = .{},
};

pub const CompileError = std.mem.Allocator.Error;

pub fn compileInlineSpansLeaky(
    allocator: std.mem.Allocator,
    md: []const u8,
    opts: InlineOptions,
) CompileError![]protocol.Span {
    var spans: std.ArrayList(protocol.Span) = .empty;
    defer spans.deinit(allocator);

    var it = std.mem.splitScalar(u8, md, '\n');
    var first_line = true;
    var overflow: bool = false;
    while (it.next()) |raw_line| {
        const line = trimCr(raw_line);
        if (!first_line) {
            try appendText(
                allocator,
                &spans,
                "\n",
                opts.sanitize_control,
                opts.own_text,
                null,
                opts.max_spans,
                &overflow,
            );
            if (overflow) break;
        }
        first_line = false;
        try parseInlineInto(
            allocator,
            &spans,
            line,
            opts.sanitize_control,
            opts.own_text,
            opts.theme,
            null,
            opts.max_spans,
            &overflow,
        );
        if (overflow) break;
    }

    if (overflow) {
        spans.clearRetainingCapacity();
        const normalized = try normalizeNewlinesLeaky(allocator, md);
        var overflow2: bool = false;
        try appendText(
            allocator,
            &spans,
            normalized,
            opts.sanitize_control,
            true,
            null,
            opts.max_spans,
            &overflow2,
        );
    }

    return spans.toOwnedSlice(allocator);
}

pub fn compileLeaky(
    allocator: std.mem.Allocator,
    md: []const u8,
    opts: Options,
) CompileError!protocol.Node {
    var children: std.ArrayList(protocol.Node) = .empty;
    defer children.deinit(allocator);

    var blank_idx: usize = 0;
    var para_idx: usize = 0;
    var heading_idx: usize = 0;
    var li_idx: usize = 0;
    var bq_idx: usize = 0;

    var lines_it = std.mem.splitScalar(u8, md, '\n');
    var pending_para: std.ArrayList([]const u8) = .empty;
    defer pending_para.deinit(allocator);

    const prefix = if (opts.id_prefix.len == 0) opts.id else opts.id_prefix;

    const flushParagraph = struct {
        fn flush(
            allocator_inner: std.mem.Allocator,
            out_children: *std.ArrayList(protocol.Node),
            pending: *std.ArrayList([]const u8),
            pfx: []const u8,
            idx: *usize,
            sanitize_control: bool,
            own_text: bool,
            max_spans: usize,
            theme: Theme,
        ) CompileError!void {
            if (pending.items.len == 0) return;

            var spans: std.ArrayList(protocol.Span) = .empty;
            defer spans.deinit(allocator_inner);
            var overflow: bool = false;

            for (pending.items, 0..) |line, i| {
                if (i != 0) {
                    try appendText(
                        allocator_inner,
                        &spans,
                        "\n",
                        sanitize_control,
                        own_text,
                        null,
                        max_spans,
                        &overflow,
                    );
                }
                try parseInlineInto(
                    allocator_inner,
                    &spans,
                    line,
                    sanitize_control,
                    own_text,
                    theme,
                    null,
                    max_spans,
                    &overflow,
                );
                if (overflow) break;
            }

            const id = try std.fmt.allocPrint(allocator_inner, "{s}-p-{d}", .{ pfx, idx.* });
            idx.* += 1;

            if (overflow) {
                spans.clearRetainingCapacity();
                const raw = try joinLinesLeaky(allocator_inner, pending.items);
                var overflow2: bool = false;
                try appendText(
                    allocator_inner,
                    &spans,
                    raw,
                    sanitize_control,
                    true,
                    null,
                    max_spans,
                    &overflow2,
                );
            }

            try out_children.append(allocator_inner, .{
                .styled_text = .{
                    .id = id,
                    .spans = try spans.toOwnedSlice(allocator_inner),
                },
            });

            pending.clearRetainingCapacity();
        }
    }.flush;

    while (lines_it.next()) |raw_line| {
        const line = trimCr(raw_line);

        if (isBlank(line)) {
            try flushParagraph(
                allocator,
                &children,
                &pending_para,
                prefix,
                &para_idx,
                opts.sanitize_control,
                opts.own_text,
                opts.max_spans,
                opts.theme,
            );

            const id = try std.fmt.allocPrint(allocator, "{s}-blank-{d}", .{ prefix, blank_idx });
            blank_idx += 1;
            try children.append(allocator, .{ .text = .{ .id = id, .h = 1, .text = "" } });
            continue;
        }

        if (parseHeading(line)) |h| {
            try flushParagraph(
                allocator,
                &children,
                &pending_para,
                prefix,
                &para_idx,
                opts.sanitize_control,
                opts.own_text,
                opts.max_spans,
                opts.theme,
            );

            var spans: std.ArrayList(protocol.Span) = .empty;
            defer spans.deinit(allocator);
            var overflow: bool = false;
            try parseInlineInto(
                allocator,
                &spans,
                h.text,
                opts.sanitize_control,
                opts.own_text,
                opts.theme,
                null,
                opts.max_spans,
                &overflow,
            );
            if (overflow) {
                spans.clearRetainingCapacity();
                var overflow2: bool = false;
                try appendText(
                    allocator,
                    &spans,
                    h.text,
                    opts.sanitize_control,
                    true,
                    null,
                    opts.max_spans,
                    &overflow2,
                );
            }

            const id = try std.fmt.allocPrint(allocator, "{s}-h{d}-{d}", .{ prefix, h.level, heading_idx });
            heading_idx += 1;

            try children.append(allocator, .{
                .styled_text = .{
                    .id = id,
                    .style = opts.theme.heading,
                    .spans = try spans.toOwnedSlice(allocator),
                },
            });
            continue;
        }

        if (parseListItem(line)) |li| {
            try flushParagraph(
                allocator,
                &children,
                &pending_para,
                prefix,
                &para_idx,
                opts.sanitize_control,
                opts.own_text,
                opts.max_spans,
                opts.theme,
            );

            const id = try std.fmt.allocPrint(allocator, "{s}-li-{d}", .{ prefix, li_idx });
            li_idx += 1;

            if (opts.prefix_layout) {
                const prefix_text = if (opts.pretty_prefixes) "• " else "- ";
                var body_spans: std.ArrayList(protocol.Span) = .empty;
                defer body_spans.deinit(allocator);
                var overflow: bool = false;
                try parseInlineInto(
                    allocator,
                    &body_spans,
                    li.text,
                    opts.sanitize_control,
                    opts.own_text,
                    opts.theme,
                    null,
                    opts.max_spans,
                    &overflow,
                );
                if (overflow) {
                    body_spans.clearRetainingCapacity();
                    var overflow2: bool = false;
                    try appendText(
                        allocator,
                        &body_spans,
                        li.text,
                        opts.sanitize_control,
                        true,
                        null,
                        opts.max_spans,
                        &overflow2,
                    );
                }

                const prefix_id = try std.fmt.allocPrint(allocator, "{s}-bullet", .{id});
                const body_id = try std.fmt.allocPrint(allocator, "{s}-body", .{id});

                var h_children = try allocator.alloc(protocol.Node, 2);
                h_children[0] = .{
                    .text = .{
                        .id = prefix_id,
                        .w = 2,
                        .style = opts.theme.bullet_prefix,
                        .text = prefix_text,
                    },
                };
                h_children[1] = .{
                    .styled_text = .{
                        .id = body_id,
                        .flex = 1,
                        .spans = try body_spans.toOwnedSlice(allocator),
                    },
                };

                try children.append(allocator, .{ .hbox = .{ .id = id, .children = h_children } });
            } else {
                var spans: std.ArrayList(protocol.Span) = .empty;
                defer spans.deinit(allocator);

                const prefix_text = if (opts.pretty_prefixes) "• " else "- ";
                var overflow: bool = false;
                try appendText(
                    allocator,
                    &spans,
                    prefix_text,
                    opts.sanitize_control,
                    opts.own_text,
                    opts.theme.bullet_prefix,
                    opts.max_spans,
                    &overflow,
                );
                try parseInlineInto(
                    allocator,
                    &spans,
                    li.text,
                    opts.sanitize_control,
                    opts.own_text,
                    opts.theme,
                    null,
                    opts.max_spans,
                    &overflow,
                );
                if (overflow) {
                    spans.clearRetainingCapacity();
                    const raw = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix_text, li.text });
                    var overflow2: bool = false;
                    try appendText(
                        allocator,
                        &spans,
                        raw,
                        opts.sanitize_control,
                        true,
                        null,
                        opts.max_spans,
                        &overflow2,
                    );
                }

                try children.append(allocator, .{
                    .styled_text = .{
                        .id = id,
                        .spans = try spans.toOwnedSlice(allocator),
                    },
                });
            }
            continue;
        }

        if (parseBlockquote(line)) |bq| {
            try flushParagraph(
                allocator,
                &children,
                &pending_para,
                prefix,
                &para_idx,
                opts.sanitize_control,
                opts.own_text,
                opts.max_spans,
                opts.theme,
            );

            const id = try std.fmt.allocPrint(allocator, "{s}-bq-{d}", .{ prefix, bq_idx });
            bq_idx += 1;

            if (opts.prefix_layout) {
                const prefix_text = if (opts.pretty_prefixes) "│ " else "> ";
                var body_spans: std.ArrayList(protocol.Span) = .empty;
                defer body_spans.deinit(allocator);
                var overflow: bool = false;
                try parseInlineInto(
                    allocator,
                    &body_spans,
                    bq.text,
                    opts.sanitize_control,
                    opts.own_text,
                    opts.theme,
                    null,
                    opts.max_spans,
                    &overflow,
                );
                if (overflow) {
                    body_spans.clearRetainingCapacity();
                    var overflow2: bool = false;
                    try appendText(
                        allocator,
                        &body_spans,
                        bq.text,
                        opts.sanitize_control,
                        true,
                        null,
                        opts.max_spans,
                        &overflow2,
                    );
                }

                const prefix_id = try std.fmt.allocPrint(allocator, "{s}-prefix", .{id});
                const body_id = try std.fmt.allocPrint(allocator, "{s}-body", .{id});

                var h_children = try allocator.alloc(protocol.Node, 2);
                h_children[0] = .{
                    .text = .{
                        .id = prefix_id,
                        .w = 2,
                        .style = opts.theme.quote_prefix,
                        .text = prefix_text,
                    },
                };
                h_children[1] = .{
                    .styled_text = .{
                        .id = body_id,
                        .flex = 1,
                        .spans = try body_spans.toOwnedSlice(allocator),
                    },
                };

                try children.append(allocator, .{ .hbox = .{ .id = id, .children = h_children } });
            } else {
                var spans: std.ArrayList(protocol.Span) = .empty;
                defer spans.deinit(allocator);

                const prefix_text = if (opts.pretty_prefixes) "│ " else "> ";
                var overflow: bool = false;
                try appendText(
                    allocator,
                    &spans,
                    prefix_text,
                    opts.sanitize_control,
                    opts.own_text,
                    opts.theme.quote_prefix,
                    opts.max_spans,
                    &overflow,
                );
                try parseInlineInto(
                    allocator,
                    &spans,
                    bq.text,
                    opts.sanitize_control,
                    opts.own_text,
                    opts.theme,
                    null,
                    opts.max_spans,
                    &overflow,
                );
                if (overflow) {
                    spans.clearRetainingCapacity();
                    const raw = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix_text, bq.text });
                    var overflow2: bool = false;
                    try appendText(
                        allocator,
                        &spans,
                        raw,
                        opts.sanitize_control,
                        true,
                        null,
                        opts.max_spans,
                        &overflow2,
                    );
                }

                try children.append(allocator, .{
                    .styled_text = .{
                        .id = id,
                        .spans = try spans.toOwnedSlice(allocator),
                    },
                });
            }
            continue;
        }

        try pending_para.append(allocator, line);
    }

    try flushParagraph(
        allocator,
        &children,
        &pending_para,
        prefix,
        &para_idx,
        opts.sanitize_control,
        opts.own_text,
        opts.max_spans,
        opts.theme,
    );

    return .{
        .vbox = .{
            .id = opts.id,
            .children = try children.toOwnedSlice(allocator),
        },
    };
}

fn parseInlineInto(
    allocator: std.mem.Allocator,
    spans: *std.ArrayList(protocol.Span),
    text: []const u8,
    sanitize_control: bool,
    own_text: bool,
    theme: Theme,
    active: ?style.StyleOverride,
    max_spans: usize,
    overflow: *bool,
) CompileError!void {
    if (overflow.*) return;
    var seg_start: usize = 0;
    var i: usize = 0;

    while (i < text.len) {
        if (overflow.*) break;
        switch (text[i]) {
            '`' => {
                if (std.mem.indexOfScalarPos(u8, text, i + 1, '`')) |j| {
                    try appendText(
                        allocator,
                        spans,
                        text[seg_start..i],
                        sanitize_control,
                        own_text,
                        active,
                        max_spans,
                        overflow,
                    );
                    if (overflow.*) return;
                    const code_style = mergeOverrides(active, theme.code);
                    try appendText(
                        allocator,
                        spans,
                        text[i + 1 .. j],
                        sanitize_control,
                        own_text,
                        code_style,
                        max_spans,
                        overflow,
                    );
                    if (overflow.*) return;
                    seg_start = j + 1;
                    i = seg_start;
                    continue;
                }
                i += 1;
            },
            '*' => {
                if (i + 1 < text.len and text[i + 1] == '*') {
                    if (std.mem.indexOfPos(u8, text, i + 2, "**")) |j| {
                        try appendText(
                            allocator,
                            spans,
                            text[seg_start..i],
                            sanitize_control,
                            own_text,
                            active,
                            max_spans,
                            overflow,
                        );
                        if (overflow.*) return;
                        const next_style = mergeOverrides(active, theme.bold);
                        try parseInlineInto(
                            allocator,
                            spans,
                            text[i + 2 .. j],
                            sanitize_control,
                            own_text,
                            theme,
                            next_style,
                            max_spans,
                            overflow,
                        );
                        if (overflow.*) return;
                        seg_start = j + 2;
                        i = seg_start;
                        continue;
                    }
                    i += 2;
                } else {
                    if (std.mem.indexOfScalarPos(u8, text, i + 1, '*')) |j| {
                        try appendText(
                            allocator,
                            spans,
                            text[seg_start..i],
                            sanitize_control,
                            own_text,
                            active,
                            max_spans,
                            overflow,
                        );
                        if (overflow.*) return;
                        const next_style = mergeOverrides(active, theme.italic);
                        try parseInlineInto(
                            allocator,
                            spans,
                            text[i + 1 .. j],
                            sanitize_control,
                            own_text,
                            theme,
                            next_style,
                            max_spans,
                            overflow,
                        );
                        if (overflow.*) return;
                        seg_start = j + 1;
                        i = seg_start;
                        continue;
                    }
                    i += 1;
                }
            },
            else => i += 1,
        }
    }

    try appendText(
        allocator,
        spans,
        text[seg_start..],
        sanitize_control,
        own_text,
        active,
        max_spans,
        overflow,
    );
}

fn appendText(
    allocator: std.mem.Allocator,
    spans: *std.ArrayList(protocol.Span),
    text: []const u8,
    sanitize_control: bool,
    own_text: bool,
    st: ?style.StyleOverride,
    max_spans: usize,
    overflow: *bool,
) CompileError!void {
    if (text.len == 0) return;
    if (overflow.*) return;
    if (spans.items.len >= max_spans) {
        overflow.* = true;
        return;
    }

    if (spans.items.len != 0 and styleOptEqual(spans.items[spans.items.len - 1].style, st)) {
        const prev = spans.items[spans.items.len - 1].text;
        const can_merge_borrowed = canMergeBorrowed(prev, text);
        if (can_merge_borrowed) {
            const start = @intFromPtr(prev.ptr);
            const end = @intFromPtr(text.ptr) + text.len;
            spans.items[spans.items.len - 1].text = @as([*]const u8, @ptrFromInt(start))[0 .. end - start];
            return;
        }

        if (own_text and !needsSanitize(text, sanitize_control)) {
            const combined = try concat2(allocator, prev, text);
            spans.items[spans.items.len - 1].text = combined;
            return;
        }
    }

    const mat = try materializeText(allocator, text, sanitize_control, own_text);
    try spans.append(allocator, .{ .text = mat, .style = st });
}

fn materializeText(
    allocator: std.mem.Allocator,
    text: []const u8,
    sanitize_control: bool,
    own_text: bool,
) CompileError![]const u8 {
    if (!needsSanitize(text, sanitize_control)) {
        if (!own_text) return text;
        return allocator.dupe(u8, text);
    }

    var out = try allocator.alloc(u8, text.len);
    for (text, 0..) |b, i| {
        out[i] = if (b < 0x20 and b != '\n' and b != '\t') '?' else b;
    }
    return out;
}

fn needsSanitize(text: []const u8, sanitize_control: bool) bool {
    if (!sanitize_control) return false;
    for (text) |b| {
        if (b < 0x20 and b != '\n' and b != '\t') return true;
    }
    return false;
}

fn concat2(allocator: std.mem.Allocator, a: []const u8, b: []const u8) CompileError![]const u8 {
    var out = try allocator.alloc(u8, a.len + b.len);
    @memcpy(out[0..a.len], a);
    @memcpy(out[a.len..], b);
    return out;
}

fn canMergeBorrowed(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const a_end = @intFromPtr(a.ptr) + a.len;
    return a_end == @intFromPtr(b.ptr);
}

fn styleOptEqual(a: ?style.StyleOverride, b: ?style.StyleOverride) bool {
    return std.meta.eql(a, b);
}

fn trimCr(line: []const u8) []const u8 {
    if (line.len != 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

fn isBlank(line: []const u8) bool {
    for (line) |b| {
        if (b != ' ' and b != '\t' and b != '\r') return false;
    }
    return true;
}

const Heading = struct { level: u8, text: []const u8 };

fn parseHeading(line: []const u8) ?Heading {
    var level: u8 = 0;
    while (level < 6 and level < line.len and line[level] == '#') : (level += 1) {}
    if (level == 0) return null;
    if (level >= line.len or line[level] != ' ') return null;
    const rest = line[level + 1 ..];
    return .{ .level = level, .text = rest };
}

const Item = struct { text: []const u8 };

fn parseListItem(line: []const u8) ?Item {
    if (line.len < 2) return null;
    if ((line[0] == '-' or line[0] == '*' or line[0] == '+') and line[1] == ' ') {
        return .{ .text = line[2..] };
    }
    return null;
}

fn parseBlockquote(line: []const u8) ?Item {
    if (line.len < 2) return null;
    if (line[0] == '>' and line[1] == ' ') {
        return .{ .text = line[2..] };
    }
    return null;
}

fn attrStyle(attr: style.Attr, value: bool) style.StyleOverride {
    var out: style.StyleOverride = .{};
    out.setAttr(attr, value);
    return out;
}

fn mergeOverrides(base: ?style.StyleOverride, overlay: style.StyleOverride) ?style.StyleOverride {
    if (base == null) return overlay;
    var out = base.?;

    out.fg = switch (overlay.fg) {
        .inherit => out.fg,
        else => overlay.fg,
    };
    out.bg = switch (overlay.bg) {
        .inherit => out.bg,
        else => overlay.bg,
    };

    const set_mask = overlay.attrs_set;
    out.attrs_set |= set_mask;
    out.attrs_values = (out.attrs_values & ~set_mask) | (overlay.attrs_values & set_mask);
    return out;
}

fn joinLinesLeaky(allocator: std.mem.Allocator, lines: []const []const u8) CompileError![]const u8 {
    if (lines.len == 0) return allocator.dupe(u8, "");
    if (lines.len == 1) return allocator.dupe(u8, lines[0]);

    var total: usize = 0;
    for (lines) |l| total += l.len;
    total += lines.len - 1;

    var out = try allocator.alloc(u8, total);
    var off: usize = 0;
    for (lines, 0..) |l, i| {
        if (i != 0) {
            out[off] = '\n';
            off += 1;
        }
        @memcpy(out[off .. off + l.len], l);
        off += l.len;
    }
    return out;
}

fn normalizeNewlinesLeaky(allocator: std.mem.Allocator, md: []const u8) CompileError![]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);

    var it = std.mem.splitScalar(u8, md, '\n');
    while (it.next()) |raw_line| {
        try lines.append(allocator, trimCr(raw_line));
    }
    return joinLinesLeaky(allocator, lines.items);
}

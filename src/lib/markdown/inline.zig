const std = @import("std");

const protocol = @import("../protocol/mod.zig");
const style = @import("../style.zig");

const common = @import("common.zig");
const types = @import("types.zig");

pub fn compileInlineSpansLeaky(
    allocator: std.mem.Allocator,
    md: []const u8,
    opts: types.InlineOptions,
) types.CompileError![]protocol.Span {
    var spans: std.ArrayList(protocol.Span) = .empty;
    defer spans.deinit(allocator);

    var it = std.mem.splitScalar(u8, md, '\n');
    var first_line = true;
    var overflow: bool = false;
    while (it.next()) |raw_line| {
        const line = common.trimCr(raw_line);
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
        const normalized = try common.normalizeNewlinesLeaky(allocator, md);
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

pub fn parseInlineInto(
    allocator: std.mem.Allocator,
    spans: *std.ArrayList(protocol.Span),
    text: []const u8,
    sanitize_control: bool,
    own_text: bool,
    theme: types.Theme,
    active: ?style.StyleOverride,
    max_spans: usize,
    overflow: *bool,
) types.CompileError!void {
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

pub fn appendText(
    allocator: std.mem.Allocator,
    spans: *std.ArrayList(protocol.Span),
    text: []const u8,
    sanitize_control: bool,
    own_text: bool,
    st: ?style.StyleOverride,
    max_spans: usize,
    overflow: *bool,
) types.CompileError!void {
    if (overflow.*) return;
    if (text.len == 0) return;
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
) types.CompileError![]const u8 {
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

fn concat2(allocator: std.mem.Allocator, a: []const u8, b: []const u8) types.CompileError![]const u8 {
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

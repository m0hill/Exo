const std = @import("std");

const protocol = @import("../protocol/mod.zig");

const common = @import("common.zig");
const inline_mod = @import("inline.zig");
const types = @import("types.zig");

pub fn compileLeaky(
    allocator: std.mem.Allocator,
    md: []const u8,
    opts: types.Options,
) types.CompileError!protocol.Node {
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
            theme: types.Theme,
        ) types.CompileError!void {
            if (pending.items.len == 0) return;

            var spans: std.ArrayList(protocol.Span) = .empty;
            defer spans.deinit(allocator_inner);
            var overflow: bool = false;

            for (pending.items, 0..) |line, i| {
                if (i != 0) {
                    try inline_mod.appendText(
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
                try inline_mod.parseInlineInto(
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
                const raw = try common.joinLinesLeaky(allocator_inner, pending.items);
                var overflow2: bool = false;
                try inline_mod.appendText(
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
        const line = common.trimCr(raw_line);

        if (common.isBlank(line)) {
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

        if (common.parseHeading(line)) |h| {
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
            try inline_mod.parseInlineInto(
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
                try inline_mod.appendText(
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

        if (common.parseListItem(line)) |li| {
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
                try inline_mod.parseInlineInto(
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
                    try inline_mod.appendText(
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
                try inline_mod.appendText(
                    allocator,
                    &spans,
                    prefix_text,
                    opts.sanitize_control,
                    opts.own_text,
                    opts.theme.bullet_prefix,
                    opts.max_spans,
                    &overflow,
                );
                try inline_mod.parseInlineInto(
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
                    try inline_mod.appendText(
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

        if (common.parseBlockquote(line)) |bq| {
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
                try inline_mod.parseInlineInto(
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
                    try inline_mod.appendText(
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
                try inline_mod.appendText(
                    allocator,
                    &spans,
                    prefix_text,
                    opts.sanitize_control,
                    opts.own_text,
                    opts.theme.quote_prefix,
                    opts.max_spans,
                    &overflow,
                );
                try inline_mod.parseInlineInto(
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
                    try inline_mod.appendText(
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

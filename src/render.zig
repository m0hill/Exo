const std = @import("std");
const protocol = @import("protocol.zig");
const Size = @import("term_size.zig").Size;

pub const RenderState = struct {
    focused_id: ?[]const u8 = null,
    input_id: []const u8 = "",
    input_value: []const u8 = "",
    input_cursor: usize = 0,
};

const CursorPos = struct {
    row: usize,
    col: usize,
};

const RenderCtx = struct {
    cols: u16,
    rows_left: usize,
    row: usize = 1,
    cursor: ?CursorPos = null,
};

pub fn render(term: anytype, root: protocol.Node, state: RenderState) !void {
    try term.writeAll("\x1b[2J\x1b[H");
    const size = term.getSize() catch Size{ .rows = 0, .cols = 0 };
    var ctx: RenderCtx = .{
        .cols = size.cols,
        .rows_left = if (size.rows == 0) std.math.maxInt(usize) else size.rows,
    };
    try renderNode(term, root, &ctx, state);

    if (ctx.cursor) |c| {
        try term.writeAll("\x1b[?25h");
        var esc_buf: [64]u8 = undefined;
        const esc = try std.fmt.bufPrint(&esc_buf, "\x1b[{d};{d}H", .{ c.row, c.col });
        try term.writeAll(esc);
    } else {
        try term.writeAll("\x1b[?25l");
    }
}

fn renderNode(term: anytype, node: protocol.Node, ctx: *RenderCtx, state: RenderState) !void {
    if (ctx.rows_left == 0) return;
    switch (node) {
        .text => |t| {
            try renderLine(term, ctx, t.text);
        },
        .vbox => |v| {
            _ = v.id;
            for (v.children) |child| {
                if (ctx.rows_left == 0) break;
                try renderNode(term, child, ctx, state);
            }
        },
        .input => |i| {
            const focused = state.focused_id != null and std.mem.eql(u8, state.focused_id.?, i.id);
            const prefix = "> ";

            if (focused and ctx.cursor == null) {
                const effective_cursor = @min(state.input_cursor, state.input_value.len);
                var col: usize = prefix.len + effective_cursor + 1;
                if (ctx.cols != 0) {
                    const max_col: usize = @as(usize, ctx.cols);
                    if (col > max_col) col = max_col;
                    if (col == 0) col = 1;
                }
                ctx.cursor = .{ .row = ctx.row, .col = col };
            }

            if (!std.mem.eql(u8, i.id, state.input_id)) {
                // Unknown input id: render placeholder only.
                try renderLine(term, ctx, prefix);
                return;
            }

            if (state.input_value.len > 0) {
                try renderLinePieces(term, ctx, &.{ prefix, state.input_value });
            } else if (i.placeholder != null) {
                if (focused) {
                    try renderLinePieces(term, ctx, &.{ prefix, i.placeholder.? });
                } else {
                    try renderLinePieces(term, ctx, &.{ prefix, "[", i.placeholder.?, "]" });
                }
            } else {
                try renderLine(term, ctx, prefix);
            }
        },
    }
}

fn renderLine(term: anytype, ctx: *RenderCtx, text: []const u8) !void {
    if (ctx.rows_left == 0) return;
    const cols: usize = @as(usize, ctx.cols);
    const line = if (ctx.cols == 0 or text.len <= cols) text else text[0..cols];
    try term.writeAll(line);
    // Raw mode disables output processing; newline is LF-only unless we include CR.
    try term.writeAll("\x1b[K\r\n");
    ctx.rows_left -= 1;
    ctx.row += 1;
}

fn renderLinePieces(term: anytype, ctx: *RenderCtx, pieces: []const []const u8) !void {
    if (ctx.rows_left == 0) return;

    var remaining: usize = if (ctx.cols == 0) std.math.maxInt(usize) else @as(usize, ctx.cols);
    for (pieces) |p| {
        if (remaining == 0) break;
        const chunk = if (p.len <= remaining) p else p[0..remaining];
        try term.writeAll(chunk);
        remaining -= chunk.len;
    }
    // Raw mode disables output processing; newline is LF-only unless we include CR.
    try term.writeAll("\x1b[K\r\n");
    ctx.rows_left -= 1;
    ctx.row += 1;
}

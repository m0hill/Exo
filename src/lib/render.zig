const std = @import("std");
const frame_mod = @import("frame.zig");
const protocol = @import("protocol.zig");

const Frame = frame_mod.Frame;
const CursorPos = frame_mod.CursorPos;

pub const RenderState = struct {
    focused_id: ?[]const u8 = null,
    inputs: []const InputState = &.{},
    lists: []const ListState = &.{},
};

pub const InputState = struct {
    id: []const u8,
    value: []const u8,
    cursor: usize,
};

pub const ListState = struct {
    id: []const u8,
    selected_id: []const u8,
    scroll: usize,
};

const RenderCtx = struct {
    cols: usize,
    rows_left: usize,
    row: usize = 0, // 0-based
    cursor: ?CursorPos = null,
};

pub fn renderToFrame(root: protocol.Node, state: RenderState, frame: *Frame) void {
    var ctx: RenderCtx = .{
        .cols = @as(usize, frame.cols),
        .rows_left = @as(usize, frame.rows),
    };
    renderNode(frame, root, &ctx, state);
    frame.cursor = ctx.cursor;
}

fn renderNode(frame: *Frame, node: protocol.Node, ctx: *RenderCtx, state: RenderState) void {
    if (ctx.rows_left == 0) return;
    switch (node) {
        .text => |t| {
            renderLine(frame, ctx, t.text);
        },
        .vbox => |v| {
            _ = v.id;
            for (v.children) |child| {
                if (ctx.rows_left == 0) break;
                renderNode(frame, child, ctx, state);
            }
        },
        .input => |i| {
            const focused = state.focused_id != null and std.mem.eql(u8, state.focused_id.?, i.id);
            const prefix = "> ";

            const input_state = findInputState(state.inputs, i.id);
            if (focused and ctx.cursor == null and input_state != null) {
                const st = input_state.?;
                const effective_cursor = @min(st.cursor, st.value.len);
                var col: usize = prefix.len + effective_cursor + 1; // 1-based
                if (ctx.cols != 0) {
                    const max_col: usize = ctx.cols;
                    if (col > max_col) col = max_col;
                    if (col == 0) col = 1;
                }
                ctx.cursor = .{ .row = ctx.row + 1, .col = col };
            }

            if (input_state) |st| {
                if (st.value.len > 0) {
                    renderLinePieces(frame, ctx, &.{ prefix, st.value });
                    return;
                }
            }

            if (input_state == null) {
                // Unknown input id: render empty line with prefix only.
                renderLine(frame, ctx, prefix);
                return;
            } else if (i.placeholder != null) {
                if (focused) {
                    renderLinePieces(frame, ctx, &.{ prefix, i.placeholder.? });
                } else {
                    renderLinePieces(frame, ctx, &.{ prefix, "[", i.placeholder.?, "]" });
                }
            } else {
                renderLine(frame, ctx, prefix);
            }
        },
        .list => |l| {
            const focused = state.focused_id != null and std.mem.eql(u8, state.focused_id.?, l.id);
            const list_state = findListState(state.lists, l.id);
            const selected_id = if (list_state) |st| st.selected_id else "";
            const scroll = if (list_state) |st| st.scroll else 0;

            const desired_height: usize = l.height orelse ctx.rows_left;
            const height: usize = @min(desired_height, ctx.rows_left);
            const start: usize = @min(scroll, l.children.len);

            var row_idx: usize = 0;
            while (row_idx < height) : (row_idx += 1) {
                const item_idx = start + row_idx;
                if (item_idx >= l.children.len) {
                    renderBlankLine(ctx);
                    continue;
                }

                const item = l.children[item_idx];
                const item_id = switch (item) {
                    .text => |t| t.id,
                    .input => |i| i.id,
                    .vbox => |v| v.id,
                    .list => |ll| ll.id,
                };
                const is_selected = selected_id.len > 0 and std.mem.eql(u8, selected_id, item_id);

                const prefix = if (is_selected) (if (focused) "> " else "* ") else "  ";
                const label = switch (item) {
                    .text => |t| t.text,
                    else => "",
                };
                renderLinePieces(frame, ctx, &.{ prefix, label });
            }
        },
    }
}

fn findInputState(inputs: []const InputState, id: []const u8) ?InputState {
    var lo: usize = 0;
    var hi: usize = inputs.len;
    while (lo < hi) {
        const mid: usize = lo + (hi - lo) / 2;
        const st = inputs[mid];
        switch (std.mem.order(u8, st.id, id)) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return st,
        }
    }
    return null;
}

fn findListState(lists: []const ListState, id: []const u8) ?ListState {
    var lo: usize = 0;
    var hi: usize = lists.len;
    while (lo < hi) {
        const mid: usize = lo + (hi - lo) / 2;
        const st = lists[mid];
        switch (std.mem.order(u8, st.id, id)) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return st,
        }
    }
    return null;
}

fn renderLine(frame: *Frame, ctx: *RenderCtx, text: []const u8) void {
    if (ctx.rows_left == 0) return;
    const cols: usize = ctx.cols;
    const line = if (cols == 0 or text.len <= cols) text else text[0..cols];
    frame.putText(ctx.row, 0, line);
    ctx.rows_left -= 1;
    ctx.row += 1;
}

fn renderLinePieces(frame: *Frame, ctx: *RenderCtx, pieces: []const []const u8) void {
    if (ctx.rows_left == 0) return;

    var remaining: usize = if (ctx.cols == 0) std.math.maxInt(usize) else ctx.cols;
    var col: usize = 0;
    for (pieces) |p| {
        if (remaining == 0) break;
        const chunk = if (p.len <= remaining) p else p[0..remaining];
        frame.putText(ctx.row, col, chunk);
        remaining -= chunk.len;
        col += chunk.len;
    }
    ctx.rows_left -= 1;
    ctx.row += 1;
}

fn renderBlankLine(ctx: *RenderCtx) void {
    if (ctx.rows_left == 0) return;
    ctx.rows_left -= 1;
    ctx.row += 1;
}

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
    scroll_x: usize,
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
            _ = drawWrappedText(frame, ctx, t.text);
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
            const input_state = findInputState(state.inputs, i.id);
            const prefix = "> ";
            const prefix_len: usize = prefix.len;
            const cols: usize = ctx.cols;
            const visible_cols: usize = if (cols > prefix_len) cols - prefix_len else 0;

            if (input_state == null) {
                // Unknown input id: render empty line with prefix only.
                if (focused and ctx.cursor == null) {
                    ctx.cursor = .{ .row = ctx.row + 1, .col = @min(prefix_len + 1, @max(@as(usize, 1), cols)) };
                }
                renderLinePieces(frame, ctx, &.{prefix});
                return;
            }

            const st = input_state.?;
            const effective_cursor = @min(st.cursor, st.value.len);

            if (st.value.len > 0) {
                var start: usize = @min(st.scroll_x, st.value.len);
                if (visible_cols == 0 or st.value.len <= visible_cols) {
                    start = 0;
                } else {
                    if (effective_cursor < start) start = effective_cursor;
                    if (effective_cursor > start + visible_cols) start = effective_cursor - visible_cols;
                    if (start > st.value.len) start = st.value.len;
                }
                const end: usize = @min(st.value.len, start + visible_cols);
                const visible = if (start < end) st.value[start..end] else "";

                if (focused and ctx.cursor == null) {
                    var col: usize = prefix_len + (effective_cursor - start) + 1; // 1-based
                    if (cols != 0) {
                        if (col > cols) col = cols;
                        if (col == 0) col = 1;
                    }
                    ctx.cursor = .{ .row = ctx.row + 1, .col = col };
                }

                renderLinePieces(frame, ctx, &.{ prefix, visible });
                return;
            }

            if (i.placeholder) |ph| {
                if (focused) {
                    if (ctx.cursor == null) {
                        ctx.cursor = .{ .row = ctx.row + 1, .col = @min(prefix_len + 1, @max(@as(usize, 1), cols)) };
                    }
                    renderLinePieces(frame, ctx, &.{ prefix, ph });
                } else {
                    renderLinePieces(frame, ctx, &.{ prefix, "[", ph, "]" });
                }
            } else {
                if (focused and ctx.cursor == null) {
                    ctx.cursor = .{ .row = ctx.row + 1, .col = @min(prefix_len + 1, @max(@as(usize, 1), cols)) };
                }
                renderLinePieces(frame, ctx, &.{prefix});
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

fn drawWrappedText(frame: *Frame, ctx: *RenderCtx, text: []const u8) usize {
    return drawWrappedTextPieces(frame, ctx, &.{text});
}

fn drawWrappedTextPieces(frame: *Frame, ctx: *RenderCtx, pieces: []const []const u8) usize {
    if (ctx.rows_left == 0) return 0;

    const cols: usize = ctx.cols;
    const start_row: usize = ctx.row;
    const max_rows: usize = ctx.rows_left;

    var row: usize = start_row;
    var col: usize = 0;
    var rows_used: usize = 1;

    var p_idx: usize = 0;
    var p_off: usize = 0;

    while (p_idx < pieces.len) {
        if (rows_used > max_rows) break;
        const p = pieces[p_idx];
        if (p_off >= p.len) {
            p_idx += 1;
            p_off = 0;
            continue;
        }

        if (p[p_off] == '\n') {
            if (rows_used == max_rows) break;
            p_off += 1;
            row += 1;
            col = 0;
            rows_used += 1;
            continue;
        }

        if (cols != 0 and col == cols) {
            if (rows_used == max_rows) break;
            row += 1;
            col = 0;
            rows_used += 1;
            continue;
        }

        const remaining_cols: usize = if (cols == 0) (p.len - p_off) else (cols - col);
        if (remaining_cols == 0) continue;

        const remaining_p: []const u8 = p[p_off..];
        const want: usize = @min(remaining_cols, remaining_p.len);
        const scan = remaining_p[0..want];
        const n = if (std.mem.indexOfScalar(u8, scan, '\n')) |nl| nl else scan.len;
        if (n == 0) continue;

        frame.putText(row, col, remaining_p[0..n]);
        col += n;
        p_off += n;
    }

    const consumed: usize = @min(rows_used, max_rows);
    ctx.row += consumed;
    ctx.rows_left -= consumed;
    return consumed;
}

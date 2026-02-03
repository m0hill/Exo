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
            const prefix_first = "> ";
            const prefix_cont = "  ";

            if (input_state == null) {
                // Unknown input id: render empty line with prefix only.
                _ = drawWrappedInputPieces(frame, ctx, prefix_first, prefix_cont, &.{}, 0, false);
                return;
            }

            const st = input_state.?;
            const effective_cursor = @min(st.cursor, st.value.len);

            if (st.value.len > 0) {
                const res = drawWrappedInput(frame, ctx, prefix_first, prefix_cont, st.value, effective_cursor, focused);
                if (focused and ctx.cursor == null) ctx.cursor = res.cursor;
                return;
            }

            if (i.placeholder) |ph| {
                if (focused) {
                    const res = drawWrappedInput(frame, ctx, prefix_first, prefix_cont, ph, effective_cursor, true);
                    if (ctx.cursor == null) ctx.cursor = res.cursor;
                } else {
                    _ = drawWrappedInputPieces(frame, ctx, prefix_first, prefix_cont, &.{ "[", ph, "]" }, 0, false);
                }
            } else {
                const res = drawWrappedInputPieces(frame, ctx, prefix_first, prefix_cont, &.{}, effective_cursor, focused);
                if (focused and ctx.cursor == null) ctx.cursor = res.cursor;
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

const WrappedInputResult = struct {
    rows_consumed: usize,
    cursor: ?CursorPos = null,
};

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

fn drawWrappedInput(
    frame: *Frame,
    ctx: *RenderCtx,
    prefix_first: []const u8,
    prefix_cont: []const u8,
    value: []const u8,
    cursor_index: usize,
    focused: bool,
) WrappedInputResult {
    return drawWrappedInputPieces(frame, ctx, prefix_first, prefix_cont, &.{value}, cursor_index, focused);
}

fn drawWrappedInputPieces(
    frame: *Frame,
    ctx: *RenderCtx,
    prefix_first: []const u8,
    prefix_cont: []const u8,
    pieces: []const []const u8,
    cursor_index: usize,
    focused: bool,
) WrappedInputResult {
    if (ctx.rows_left == 0) return .{ .rows_consumed = 0, .cursor = null };

    const cols: usize = ctx.cols;
    const start_row: usize = ctx.row;
    const max_rows: usize = ctx.rows_left;

    var row: usize = start_row;
    var col: usize = 0;
    var rows_used: usize = 1;
    var line_idx: usize = 0;

    var logical_idx: usize = 0;
    var cursor: ?CursorPos = null;

    var p_idx: usize = 0;
    var p_off: usize = 0;

    while (true) {
        if (rows_used > max_rows) break;

        // Ensure prefix is drawn at the start of each visual line.
        if (col == 0) {
            const prefix = if (line_idx == 0) prefix_first else prefix_cont;
            const prefix_chunk = if (cols == 0 or prefix.len <= cols) prefix else prefix[0..cols];
            frame.putText(row, 0, prefix_chunk);
            col = prefix_chunk.len;

            if (focused and cursor == null and cursor_index == logical_idx) {
                cursor = clampCursor(row, col, cols);
            }
        }

        if (p_idx >= pieces.len) break;
        const p = pieces[p_idx];
        if (p_off >= p.len) {
            p_idx += 1;
            p_off = 0;
            continue;
        }

        if (p[p_off] == '\n') {
            // Input values shouldn't contain '\n' for tracer 8, but treat it as a forced break anyway.
            if (rows_used == max_rows) break;
            p_off += 1;
            row += 1;
            col = 0;
            rows_used += 1;
            line_idx += 1;
            continue;
        }

        if (cols != 0 and col == cols) {
            if (rows_used == max_rows) break;
            row += 1;
            col = 0;
            rows_used += 1;
            line_idx += 1;
            continue;
        }

        const remaining_cols: usize = if (cols == 0) (p.len - p_off) else (cols - col);
        if (remaining_cols == 0) continue;

        const remaining_p: []const u8 = p[p_off..];
        const want: usize = @min(remaining_cols, remaining_p.len);
        const scan = remaining_p[0..want];
        const n = if (std.mem.indexOfScalar(u8, scan, '\n')) |nl| nl else scan.len;

        if (n == 0) continue;

        if (focused and cursor == null and cursor_index >= logical_idx and cursor_index <= logical_idx + n) {
            const rel = cursor_index - logical_idx;
            cursor = clampCursor(row, col + rel, cols);
        }

        frame.putText(row, col, remaining_p[0..n]);
        col += n;
        p_off += n;
        logical_idx += n;
    }

    if (focused and cursor == null and cursor_index == logical_idx) {
        cursor = clampCursor(row, col, cols);
    }

    if (focused and cursor == null) {
        // Cursor index ended up off-screen due to vertical clipping: clamp to the last visible cell.
        const last_row: usize = start_row + (max_rows - 1);
        const last_col0: usize = if (cols == 0) 0 else (cols - 1);
        cursor = clampCursor(last_row, last_col0, cols);
    }

    const consumed: usize = @min(rows_used, max_rows);
    ctx.row += consumed;
    ctx.rows_left -= consumed;
    return .{ .rows_consumed = consumed, .cursor = cursor };
}

fn clampCursor(row0: usize, col0: usize, cols: usize) CursorPos {
    const row: usize = row0 + 1;
    const col_unclamped: usize = col0 + 1;
    if (cols == 0) return .{ .row = row, .col = 1 };
    const col: usize = @min(@max(@as(usize, 1), col_unclamped), cols);
    return .{ .row = row, .col = col };
}

const std = @import("std");
const frame_mod = @import("frame.zig");
const protocol = @import("protocol.zig");
const style = @import("style.zig");
const unicode = @import("unicode.zig");

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

pub const Rect = struct {
    x: usize,
    y: usize,
    w: usize,
    h: usize,
};

pub fn renderToFrame(root: protocol.Node, state: RenderState, frame: *Frame) void {
    const root_rect: Rect = .{
        .x = 0,
        .y = 0,
        .w = @as(usize, frame.cols),
        .h = @as(usize, frame.rows),
    };
    var cursor: ?CursorPos = null;
    paintNode(frame, root, root_rect, root_rect, state, &cursor, .{});
    frame.cursor = cursor;
}

fn rectIntersect(a: Rect, b: Rect) Rect {
    const ax2 = a.x + a.w;
    const ay2 = a.y + a.h;
    const bx2 = b.x + b.w;
    const by2 = b.y + b.h;

    const x1 = if (a.x > b.x) a.x else b.x;
    const y1 = if (a.y > b.y) a.y else b.y;
    const x2 = if (ax2 < bx2) ax2 else bx2;
    const y2 = if (ay2 < by2) ay2 else by2;

    if (x2 <= x1 or y2 <= y1) return .{ .x = x1, .y = y1, .w = 0, .h = 0 };
    return .{ .x = x1, .y = y1, .w = x2 - x1, .h = y2 - y1 };
}

fn rectDeflate(r: Rect, pad: usize) Rect {
    if (pad == 0) return r;
    if (r.w <= pad * 2 or r.h <= pad * 2) return .{ .x = r.x, .y = r.y, .w = 0, .h = 0 };
    return .{ .x = r.x + pad, .y = r.y + pad, .w = r.w - pad * 2, .h = r.h - pad * 2 };
}

fn nodeId(node: protocol.Node) []const u8 {
    return switch (node) {
        .vbox => |v| v.id,
        .hbox => |h| h.id,
        .text => |t| t.id,
        .styled_text => |t| t.id,
        .input => |i| i.id,
        .list => |l| l.id,
    };
}

fn nodeHintW(node: protocol.Node) ?usize {
    return switch (node) {
        .vbox => |v| v.w,
        .hbox => |h| h.w,
        .text => |t| t.w,
        .styled_text => |t| t.w,
        .input => |i| i.w,
        .list => |l| l.w,
    };
}

fn nodeHintH(node: protocol.Node) ?usize {
    return switch (node) {
        .vbox => |v| v.h,
        .hbox => |h| h.h,
        .text => |t| t.h,
        .styled_text => |t| t.h,
        .input => |i| i.h,
        .list => |l| l.h,
    };
}

fn nodeFlex(node: protocol.Node) usize {
    return switch (node) {
        .vbox => |v| v.flex,
        .hbox => |h| h.flex,
        .text => |t| t.flex,
        .styled_text => |t| t.flex,
        .input => |i| i.flex,
        .list => |l| l.flex,
    };
}

fn nodePad(node: protocol.Node) usize {
    return switch (node) {
        .vbox => |v| v.pad,
        .hbox => |h| h.pad,
        else => 0,
    };
}

fn nodeClip(node: protocol.Node) bool {
    return switch (node) {
        .vbox => |v| v.clip,
        .hbox => |h| h.clip,
        else => false,
    };
}

fn countWrappedLines(text: []const u8, cols: usize) usize {
    var lines: usize = 1;
    var col: usize = 0;

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\n') {
            lines += 1;
            col = 0;
            i += 1;
            continue;
        }

        const g = unicode.nextGrapheme(text, i);
        if (g.end <= i) break;

        if (cols != 0 and g.width > 0 and col > 0 and col + g.width > cols) {
            lines += 1;
            col = 0;
            continue;
        }

        if (g.width <= cols or cols == 0) {
            col += g.width;
        }
        i = g.end;
    }
    return lines;
}

fn countWrappedLinesSpans(spans: []const protocol.Span, cols: usize) usize {
    var lines: usize = 1;
    var col: usize = 0;

    for (spans) |sp| {
        const text = sp.text;
        var i: usize = 0;
        while (i < text.len) {
            if (text[i] == '\n') {
                lines += 1;
                col = 0;
                i += 1;
                continue;
            }

            const g = unicode.nextGrapheme(text, i);
            if (g.end <= i) break;

            if (cols != 0 and g.width > 0 and col > 0 and col + g.width > cols) {
                lines += 1;
                col = 0;
                continue;
            }

            if (g.width <= cols or cols == 0) {
                col += g.width;
            }
            i = g.end;
        }
    }

    return lines;
}

fn measureHeight(node: protocol.Node, avail_w: usize) usize {
    if (nodeHintH(node)) |h| return h;
    switch (node) {
        .text => |t| return countWrappedLines(t.text, avail_w),
        .styled_text => |t| return countWrappedLinesSpans(t.spans, avail_w),
        .input => return 1,
        .list => |l| return l.height orelse l.children.len,
        .vbox => |v| {
            const inner_w: usize = if (avail_w > v.pad * 2) avail_w - v.pad * 2 else 0;
            var total: usize = v.pad * 2;
            for (v.children) |child| {
                total += measureHeight(child, inner_w);
            }
            return total;
        },
        .hbox => |h| {
            const inner_w: usize = if (avail_w > h.pad * 2) avail_w - h.pad * 2 else 0;

            var fixed_sum: usize = 0;
            var total_flex: usize = 0;
            for (h.children) |child| {
                if (nodeHintW(child)) |w| {
                    fixed_sum += w;
                } else if (nodeFlex(child) > 0) {
                    total_flex += nodeFlex(child);
                }
            }

            const remaining: usize = if (inner_w > fixed_sum) inner_w - fixed_sum else 0;

            var max_h: usize = 0;
            var carry: u128 = 0;
            for (h.children) |child| {
                const child_w: usize = if (nodeHintW(child)) |w| w else if (nodeFlex(child) > 0 and total_flex > 0) blk: {
                    const numer: u128 = @as(u128, remaining) * @as(u128, nodeFlex(child)) + carry;
                    const share: usize = @as(usize, @intCast(numer / @as(u128, total_flex)));
                    carry = numer % @as(u128, total_flex);
                    break :blk share;
                } else 0;
                const ch = measureHeight(child, child_w);
                if (ch > max_h) max_h = ch;
            }
            return max_h + h.pad * 2;
        },
    }
}

fn putGraphemeClipped(
    frame: *Frame,
    row: usize,
    col: usize,
    bytes: []const u8,
    width: u2,
    clip: Rect,
    st: style.PackedStyle,
) void {
    if (width == 0) return;
    if (clip.w == 0 or clip.h == 0) return;
    if (row < clip.y or row >= clip.y + clip.h) return;
    if (col < clip.x or col + @as(usize, width) > clip.x + clip.w) return;
    frame.putGraphemeStyled(row, col, bytes, width, st);
}

fn drawWrappedTextInRect(frame: *Frame, rect: Rect, clip: Rect, text: []const u8, st: style.PackedStyle) void {
    if (rect.w == 0 or rect.h == 0) return;

    const max_rows: usize = rect.y + rect.h;
    const cols: usize = rect.w;

    var row: usize = rect.y;
    var col: usize = 0;
    var i: usize = 0;

    while (i < text.len and row < max_rows) {
        if (text[i] == '\n') {
            row += 1;
            col = 0;
            i += 1;
            continue;
        }

        const g = unicode.nextGrapheme(text, i);
        if (g.end <= i) break;

        if (cols != 0 and g.width > 0 and col > 0 and col + g.width > cols) {
            row += 1;
            col = 0;
            continue;
        }

        if (g.width > 0 and cols != 0 and g.width > cols) {
            // Too wide to fit anywhere in this rect; skip without corrupting the grid.
            i = g.end;
            continue;
        }

        if (g.width > 0) {
            const abs_col = rect.x + col;
            putGraphemeClipped(frame, row, abs_col, text[g.start..g.end], @as(u2, @intCast(g.width)), clip, st);
            col += g.width;
        }
        i = g.end;
    }
}

fn drawWrappedStyledSpansInRect(
    frame: *Frame,
    rect: Rect,
    clip: Rect,
    spans: []const protocol.Span,
    base: style.Style,
    attrs_or: u8,
) void {
    if (rect.w == 0 or rect.h == 0) return;

    const max_rows: usize = rect.y + rect.h;
    const cols: usize = rect.w;

    var row: usize = rect.y;
    var col: usize = 0;

    for (spans) |sp| {
        if (row >= max_rows) break;

        const span_style = style.merge(base, sp.style);
        var span_packed = style.pack(span_style);
        span_packed.attrs |= attrs_or;

        const text = sp.text;
        var i: usize = 0;
        while (i < text.len and row < max_rows) {
            if (text[i] == '\n') {
                row += 1;
                col = 0;
                i += 1;
                continue;
            }

            const g = unicode.nextGrapheme(text, i);
            if (g.end <= i) break;

            if (cols != 0 and g.width > 0 and col > 0 and col + g.width > cols) {
                row += 1;
                col = 0;
                continue;
            }

            if (g.width > 0 and cols != 0 and g.width > cols) {
                i = g.end;
                continue;
            }

            if (g.width > 0) {
                const abs_col = rect.x + col;
                putGraphemeClipped(frame, row, abs_col, text[g.start..g.end], @as(u2, @intCast(g.width)), clip, span_packed);
                col += g.width;
            }
            i = g.end;
        }
    }
}

fn drawInlineStyledSpansInRect(
    frame: *Frame,
    row: usize,
    rect: Rect,
    clip: Rect,
    spans: []const protocol.Span,
    base: style.Style,
    start_col: usize,
    attrs_or: u8,
) void {
    if (rect.w == 0) return;
    if (row < rect.y or row >= rect.y + rect.h) return;

    var used: usize = start_col;
    for (spans) |sp| {
        if (used >= rect.w) break;

        const span_style = style.merge(base, sp.style);
        var span_packed = style.pack(span_style);
        span_packed.attrs |= attrs_or;

        const text = sp.text;
        var i: usize = 0;
        while (i < text.len and used < rect.w) {
            if (text[i] == '\n') return;

            const g = unicode.nextGrapheme(text, i);
            if (g.end <= i) break;
            if (g.width > 0 and used + g.width > rect.w) return;
            if (g.width > 0 and rect.w != 0 and g.width > rect.w) {
                i = g.end;
                continue;
            }

            if (g.width > 0) {
                const abs_col = rect.x + used;
                putGraphemeClipped(frame, row, abs_col, text[g.start..g.end], @as(u2, @intCast(g.width)), clip, span_packed);
                used += g.width;
            }
            i = g.end;
        }
    }
}

fn renderLinePiecesInRectStyled(
    frame: *Frame,
    row: usize,
    rect: Rect,
    clip: Rect,
    pieces: []const []const u8,
    styles: []const style.PackedStyle,
) void {
    if (rect.w == 0) return;
    std.debug.assert(pieces.len == styles.len);

    var used: usize = 0;
    for (pieces, 0..) |p, pi| {
        const st = styles[pi];
        if (used >= rect.w) break;
        var i: usize = 0;
        while (i < p.len and used < rect.w) {
            const g = unicode.nextGrapheme(p, i);
            if (g.end <= i) break;
            if (g.width > 0 and used + g.width > rect.w) break;
            if (g.width > 0 and rect.w != 0 and g.width > rect.w) {
                i = g.end;
                continue;
            }

            if (g.width > 0) {
                const abs_col = rect.x + used;
                putGraphemeClipped(frame, row, abs_col, p[g.start..g.end], @as(u2, @intCast(g.width)), clip, st);
                used += g.width;
            }
            i = g.end;
        }
    }
}

fn packedEq(a: style.PackedStyle, b: style.PackedStyle) bool {
    return @as(u64, @bitCast(a)) == @as(u64, @bitCast(b));
}

fn nodeStyleOverride(node: protocol.Node) ?style.StyleOverride {
    return switch (node) {
        .vbox => |v| v.style,
        .hbox => |h| h.style,
        .text => |t| t.style,
        .styled_text => |t| t.style,
        .input => |i| i.style,
        .list => |l| l.style,
    };
}

fn fillRectStyle(frame: *Frame, rect: Rect, clip: Rect, st: style.PackedStyle) void {
    const r = rectIntersect(rect, clip);
    if (r.w == 0 or r.h == 0) return;

    var y: usize = r.y;
    const y_end: usize = r.y + r.h;
    const x0: usize = r.x;
    const x_end: usize = r.x + r.w;
    while (y < y_end) : (y += 1) {
        var row = frame.rowSliceMut(y);
        var x: usize = x0;
        while (x < x_end) : (x += 1) {
            row[x].style = st;
        }
    }
}

fn paintInput(
    frame: *Frame,
    rect: Rect,
    clip: Rect,
    state: RenderState,
    cursor_out: *?CursorPos,
    i: protocol.InputNode,
    inherited: style.Style,
) void {
    if (rect.h == 0) return;
    const row: usize = rect.y;

    const focused = state.focused_id != null and std.mem.eql(u8, state.focused_id.?, i.id);
    const input_state = findInputState(state.inputs, i.id);
    const prefix = "> ";
    const prefix_cols: usize = unicode.displayWidth(prefix);
    const cols: usize = rect.w;
    const visible_cols: usize = if (cols > prefix_cols) cols - prefix_cols else 0;

    const base_style = inherited;
    const base_packed = style.pack(base_style);
    const ph_style = style.merge(base_style, i.placeholder_style);
    const ph_packed = style.pack(ph_style);

    if (input_state == null) {
        if (focused and cursor_out.* == null) {
            if (cols != 0 and row >= clip.y and row < clip.y + clip.h and rect.x < clip.x + clip.w) {
                const col_abs = if (rect.x + prefix_cols < rect.x + cols) rect.x + prefix_cols else (rect.x + cols - 1);
                if (col_abs >= clip.x and col_abs < clip.x + clip.w) {
                    cursor_out.* = .{ .row = row + 1, .col = col_abs + 1 };
                }
            }
        }
        renderLinePiecesInRectStyled(frame, row, rect, clip, &.{prefix}, &.{base_packed});
        return;
    }

    const st = input_state.?;
    const effective_cursor = unicode.clampGraphemeBoundary(st.value, @min(st.cursor, st.value.len));

    if (st.value.len > 0) {
        var start: usize = unicode.clampGraphemeBoundary(st.value, @min(st.scroll_x, st.value.len));
        if (visible_cols == 0 or unicode.displayWidth(st.value) <= visible_cols) start = 0;

        const end: usize = unicode.sliceEndByWidth(st.value, start, visible_cols);
        const visible = if (start < end) st.value[start..end] else "";

        if (focused and cursor_out.* == null and cols != 0) {
            const cursor_cols: usize = if (effective_cursor <= start) 0 else unicode.displayWidth(st.value[start..effective_cursor]);
            var col_abs: usize = rect.x + prefix_cols + cursor_cols;
            if (col_abs >= rect.x + cols) col_abs = rect.x + cols - 1;
            if (row >= clip.y and row < clip.y + clip.h and col_abs >= clip.x and col_abs < clip.x + clip.w) {
                cursor_out.* = .{ .row = row + 1, .col = col_abs + 1 };
            }
        }

        renderLinePiecesInRectStyled(frame, row, rect, clip, &.{ prefix, visible }, &.{ base_packed, base_packed });
        return;
    }

    if (i.placeholder) |ph| {
        if (focused) {
            if (cursor_out.* == null and cols != 0) {
                const col_abs = if (rect.x + prefix_cols < rect.x + cols) rect.x + prefix_cols else (rect.x + cols - 1);
                if (row >= clip.y and row < clip.y + clip.h and col_abs >= clip.x and col_abs < clip.x + clip.w) {
                    cursor_out.* = .{ .row = row + 1, .col = col_abs + 1 };
                }
            }
            renderLinePiecesInRectStyled(frame, row, rect, clip, &.{ prefix, ph }, &.{ base_packed, ph_packed });
        } else {
            renderLinePiecesInRectStyled(frame, row, rect, clip, &.{ prefix, "[", ph, "]" }, &.{ base_packed, base_packed, ph_packed, base_packed });
        }
    } else {
        if (focused and cursor_out.* == null and cols != 0) {
            const col_abs = if (rect.x + prefix_cols < rect.x + cols) rect.x + prefix_cols else (rect.x + cols - 1);
            if (row >= clip.y and row < clip.y + clip.h and col_abs >= clip.x and col_abs < clip.x + clip.w) {
                cursor_out.* = .{ .row = row + 1, .col = col_abs + 1 };
            }
        }
        renderLinePiecesInRectStyled(frame, row, rect, clip, &.{prefix}, &.{base_packed});
    }
}

fn paintList(frame: *Frame, rect: Rect, clip: Rect, state: RenderState, l: protocol.ListNode, inherited: style.Style) void {
    if (rect.h == 0) return;
    const focused = state.focused_id != null and std.mem.eql(u8, state.focused_id.?, l.id);
    const list_state = findListState(state.lists, l.id);
    const selected_id = if (list_state) |st| st.selected_id else "";
    const scroll = if (list_state) |st| st.scroll else 0;

    const list_style = inherited;
    const list_packed = style.pack(list_style);

    const desired_height: usize = l.height orelse rect.h;
    const height: usize = @min(desired_height, rect.h);
    const start: usize = @min(scroll, l.children.len);

    var row_idx: usize = 0;
    while (row_idx < height) : (row_idx += 1) {
        const item_idx = start + row_idx;
        if (item_idx >= l.children.len) continue;

        const item = l.children[item_idx];
        const item_id = nodeId(item);
        const is_selected = selected_id.len > 0 and std.mem.eql(u8, selected_id, item_id);

        const prefix = if (is_selected) (if (focused) "> " else "* ") else "  ";
        const item_style = style.merge(list_style, nodeStyleOverride(item));
        var row_packed = style.pack(item_style);
        if (is_selected) row_packed.attrs |= style.ATTR_INVERSE;

        const row: usize = rect.y + row_idx;
        if (row >= rect.y + rect.h) break;
        const row_rect: Rect = .{ .x = rect.x, .y = row, .w = rect.w, .h = 1 };
        if (!packedEq(row_packed, list_packed) and row_packed.affectsBlank()) {
            fillRectStyle(frame, row_rect, clip, row_packed);
        }

        const prefix_cols: usize = unicode.displayWidth(prefix);

        switch (item) {
            .text => |t| renderLinePiecesInRectStyled(frame, row, row_rect, clip, &.{ prefix, t.text }, &.{ row_packed, row_packed }),
            .styled_text => |t| {
                renderLinePiecesInRectStyled(frame, row, row_rect, clip, &.{prefix}, &.{row_packed});
                drawInlineStyledSpansInRect(
                    frame,
                    row,
                    row_rect,
                    clip,
                    t.spans,
                    item_style,
                    prefix_cols,
                    if (is_selected) style.ATTR_INVERSE else 0,
                );
            },
            else => {},
        }
    }
}

fn paintVBox(
    frame: *Frame,
    rect: Rect,
    clip: Rect,
    state: RenderState,
    cursor_out: *?CursorPos,
    v: protocol.VBoxNode,
    inherited: style.Style,
) void {
    const pad = v.pad;
    const inner = rectDeflate(rect, pad);
    const base_clip = rectIntersect(clip, rect);
    const child_clip = if (v.clip) rectIntersect(base_clip, inner) else base_clip;

    var fixed_sum: usize = 0;
    var total_flex: usize = 0;

    for (v.children) |child| {
        if (nodeHintH(child)) |h| {
            fixed_sum += h;
        } else if (nodeFlex(child) > 0) {
            total_flex += nodeFlex(child);
        } else {
            fixed_sum += measureHeight(child, inner.w);
        }
    }

    const remaining: usize = if (inner.h > fixed_sum) inner.h - fixed_sum else 0;

    var y: usize = inner.y;
    var carry: u128 = 0;

    for (v.children) |child| {
        if (y >= inner.y + inner.h) break;

        const child_h: usize = if (nodeHintH(child)) |h| h else if (nodeFlex(child) > 0 and total_flex > 0) blk: {
            const numer: u128 = @as(u128, remaining) * @as(u128, nodeFlex(child)) + carry;
            const share: usize = @as(usize, @intCast(numer / @as(u128, total_flex)));
            carry = numer % @as(u128, total_flex);
            break :blk share;
        } else measureHeight(child, inner.w);

        const clamped_h: usize = if (y + child_h <= inner.y + inner.h) child_h else (inner.y + inner.h - y);
        const child_rect: Rect = .{ .x = inner.x, .y = y, .w = inner.w, .h = clamped_h };
        paintNode(frame, child, child_rect, child_clip, state, cursor_out, inherited);
        y += clamped_h;
    }
}

fn paintHBox(
    frame: *Frame,
    rect: Rect,
    clip: Rect,
    state: RenderState,
    cursor_out: *?CursorPos,
    h: protocol.HBoxNode,
    inherited: style.Style,
) void {
    const pad = h.pad;
    const inner = rectDeflate(rect, pad);
    const base_clip = rectIntersect(clip, rect);
    const child_clip = if (h.clip) rectIntersect(base_clip, inner) else base_clip;

    var fixed_sum: usize = 0;
    var total_flex: usize = 0;

    for (h.children) |child| {
        if (nodeHintW(child)) |w| {
            fixed_sum += w;
        } else if (nodeFlex(child) > 0) {
            total_flex += nodeFlex(child);
        }
    }

    const remaining: usize = if (inner.w > fixed_sum) inner.w - fixed_sum else 0;

    var x: usize = inner.x;
    var carry: u128 = 0;

    for (h.children) |child| {
        if (x >= inner.x + inner.w) break;

        const child_w: usize = if (nodeHintW(child)) |w| w else if (nodeFlex(child) > 0 and total_flex > 0) blk: {
            const numer: u128 = @as(u128, remaining) * @as(u128, nodeFlex(child)) + carry;
            const share: usize = @as(usize, @intCast(numer / @as(u128, total_flex)));
            carry = numer % @as(u128, total_flex);
            break :blk share;
        } else 0;

        const clamped_w: usize = if (x + child_w <= inner.x + inner.w) child_w else (inner.x + inner.w - x);
        const child_rect: Rect = .{ .x = x, .y = inner.y, .w = clamped_w, .h = inner.h };
        paintNode(frame, child, child_rect, child_clip, state, cursor_out, inherited);
        x += clamped_w;
    }
}

fn paintNode(
    frame: *Frame,
    node: protocol.Node,
    rect: Rect,
    clip: Rect,
    state: RenderState,
    cursor_out: *?CursorPos,
    inherited: style.Style,
) void {
    const node_clip = rectIntersect(clip, rect);
    if (node_clip.w == 0 or node_clip.h == 0) return;

    const own_override = nodeStyleOverride(node);
    const resolved = style.merge(inherited, own_override);
    const inherited_packed = style.pack(inherited);
    const resolved_packed = style.pack(resolved);
    if (!packedEq(resolved_packed, inherited_packed) and resolved_packed.affectsBlank()) {
        fillRectStyle(frame, rect, node_clip, resolved_packed);
    }

    switch (node) {
        .text => |t| drawWrappedTextInRect(frame, rect, node_clip, t.text, resolved_packed),
        .styled_text => |t| drawWrappedStyledSpansInRect(frame, rect, node_clip, t.spans, resolved, 0),
        .input => |i| paintInput(frame, rect, node_clip, state, cursor_out, i, resolved),
        .list => |l| paintList(frame, rect, node_clip, state, l, resolved),
        .vbox => |v| paintVBox(frame, rect, node_clip, state, cursor_out, v, resolved),
        .hbox => |h| paintHBox(frame, rect, node_clip, state, cursor_out, h, resolved),
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

pub fn findRectForId(root: protocol.Node, rows: usize, cols: usize, id: []const u8) ?Rect {
    const root_rect: Rect = .{ .x = 0, .y = 0, .w = cols, .h = rows };
    return findRectInNode(root, root_rect, id);
}

fn findRectInNode(node: protocol.Node, rect: Rect, id: []const u8) ?Rect {
    if (std.mem.eql(u8, nodeId(node), id)) return rect;

    switch (node) {
        .vbox => |v| {
            const inner = rectDeflate(rect, v.pad);

            var fixed_sum: usize = 0;
            var total_flex: usize = 0;

            for (v.children) |child| {
                if (nodeHintH(child)) |h| {
                    fixed_sum += h;
                } else if (nodeFlex(child) > 0) {
                    total_flex += nodeFlex(child);
                } else {
                    fixed_sum += measureHeight(child, inner.w);
                }
            }

            const remaining: usize = if (inner.h > fixed_sum) inner.h - fixed_sum else 0;

            var y: usize = inner.y;
            var carry: u128 = 0;

            for (v.children) |child| {
                if (y >= inner.y + inner.h) break;

                const child_h: usize = if (nodeHintH(child)) |h| h else if (nodeFlex(child) > 0 and total_flex > 0) blk: {
                    const numer: u128 = @as(u128, remaining) * @as(u128, nodeFlex(child)) + carry;
                    const share: usize = @as(usize, @intCast(numer / @as(u128, total_flex)));
                    carry = numer % @as(u128, total_flex);
                    break :blk share;
                } else measureHeight(child, inner.w);

                const clamped_h: usize = if (y + child_h <= inner.y + inner.h) child_h else (inner.y + inner.h - y);
                const child_rect: Rect = .{ .x = inner.x, .y = y, .w = inner.w, .h = clamped_h };
                if (findRectInNode(child, child_rect, id)) |r| return r;
                y += clamped_h;
            }
            return null;
        },
        .hbox => |h| {
            const inner = rectDeflate(rect, h.pad);

            var fixed_sum: usize = 0;
            var total_flex: usize = 0;

            for (h.children) |child| {
                if (nodeHintW(child)) |w| {
                    fixed_sum += w;
                } else if (nodeFlex(child) > 0) {
                    total_flex += nodeFlex(child);
                }
            }

            const remaining: usize = if (inner.w > fixed_sum) inner.w - fixed_sum else 0;

            var x: usize = inner.x;
            var carry: u128 = 0;

            for (h.children) |child| {
                if (x >= inner.x + inner.w) break;

                const child_w: usize = if (nodeHintW(child)) |w| w else if (nodeFlex(child) > 0 and total_flex > 0) blk: {
                    const numer: u128 = @as(u128, remaining) * @as(u128, nodeFlex(child)) + carry;
                    const share: usize = @as(usize, @intCast(numer / @as(u128, total_flex)));
                    carry = numer % @as(u128, total_flex);
                    break :blk share;
                } else 0;

                const clamped_w: usize = if (x + child_w <= inner.x + inner.w) child_w else (inner.x + inner.w - x);
                const child_rect: Rect = .{ .x = x, .y = inner.y, .w = clamped_w, .h = inner.h };
                if (findRectInNode(child, child_rect, id)) |r| return r;
                x += clamped_w;
            }
            return null;
        },
        else => return null,
    }
}

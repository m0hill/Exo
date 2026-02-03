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
    scrolls: []const ScrollState = &.{},
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

pub const ScrollState = struct {
    id: []const u8,
    scroll_y: usize,
    content_h: usize,
    viewport_h: usize,
};

pub const Rect = struct {
    x: usize,
    y: usize,
    w: usize,
    h: usize,
};

const RectI = struct {
    x: isize,
    y: isize,
    w: usize,
    h: usize,
};

const VBoxMode = enum {
    bounded,
    unbounded,
};

fn screenRect(frame: *Frame) RectI {
    return .{ .x = 0, .y = 0, .w = @as(usize, frame.cols), .h = @as(usize, frame.rows) };
}

fn alignStartCenterEnd(anchor_start: isize, anchor_len: usize, child_len: usize, align_mode: protocol.OverlayAlign) isize {
    const a: isize = anchor_start;
    const aw: isize = @as(isize, @intCast(anchor_len));
    const cw: isize = @as(isize, @intCast(child_len));
    return switch (align_mode) {
        .start => a,
        .center => a + @divTrunc(aw - cw, 2),
        .end => a + aw - cw,
    };
}

fn clampOverlayOrigin(screen: RectI, x: isize, y: isize, w: usize, h: usize) struct { x: isize, y: isize } {
    const sx1: isize = screen.x;
    const sy1: isize = screen.y;
    const sx2: isize = screen.x + @as(isize, @intCast(screen.w));
    const sy2: isize = screen.y + @as(isize, @intCast(screen.h));

    const ww: isize = @as(isize, @intCast(w));
    const hh: isize = @as(isize, @intCast(h));

    const max_x: isize = if (ww >= screen.w) sx1 else sx2 - ww;
    const max_y: isize = if (hh >= screen.h) sy1 else sy2 - hh;

    var out_x = x;
    var out_y = y;
    if (out_x < sx1) out_x = sx1;
    if (out_x > max_x) out_x = max_x;
    if (out_y < sy1) out_y = sy1;
    if (out_y > max_y) out_y = max_y;

    return .{ .x = out_x, .y = out_y };
}

pub fn renderToFrame(root: protocol.Node, state: RenderState, frame: *Frame) void {
    const root_rect: RectI = .{
        .x = 0,
        .y = 0,
        .w = @as(usize, frame.cols),
        .h = @as(usize, frame.rows),
    };
    var cursor: ?CursorPos = null;
    paintNode(frame, root, root_rect, root_rect, state, &cursor, .{}, .bounded);
    frame.cursor = cursor;
}

fn rectIntersect(a: RectI, b: RectI) RectI {
    const ax2: isize = a.x + @as(isize, @intCast(a.w));
    const ay2: isize = a.y + @as(isize, @intCast(a.h));
    const bx2: isize = b.x + @as(isize, @intCast(b.w));
    const by2: isize = b.y + @as(isize, @intCast(b.h));

    const x1: isize = if (a.x > b.x) a.x else b.x;
    const y1: isize = if (a.y > b.y) a.y else b.y;
    const x2: isize = if (ax2 < bx2) ax2 else bx2;
    const y2: isize = if (ay2 < by2) ay2 else by2;

    if (x2 <= x1 or y2 <= y1) return .{ .x = x1, .y = y1, .w = 0, .h = 0 };
    return .{
        .x = x1,
        .y = y1,
        .w = @as(usize, @intCast(x2 - x1)),
        .h = @as(usize, @intCast(y2 - y1)),
    };
}

fn rectDeflate(r: RectI, pad: usize) RectI {
    if (pad == 0) return r;
    if (r.w <= pad * 2 or r.h <= pad * 2) return .{ .x = r.x, .y = r.y, .w = 0, .h = 0 };
    const p: isize = @as(isize, @intCast(pad));
    return .{ .x = r.x + p, .y = r.y + p, .w = r.w - pad * 2, .h = r.h - pad * 2 };
}

fn nodeId(node: protocol.Node) []const u8 {
    return switch (node) {
        .vbox => |v| v.id,
        .hbox => |h| h.id,
        .scroll => |s| s.id,
        .overlay => |o| o.id,
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
        .scroll => |s| s.w,
        .overlay => |o| o.w,
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
        .scroll => |s| s.h,
        .overlay => |o| o.h,
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
        .scroll => |s| s.flex,
        .overlay => |o| o.flex,
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
        .scroll => |s| s.pad,
        .overlay => |o| o.pad,
        else => 0,
    };
}

fn nodeClip(node: protocol.Node) bool {
    return switch (node) {
        .vbox => |v| v.clip,
        .hbox => |h| h.clip,
        .scroll => |s| s.clip,
        .overlay => |o| o.clip,
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
        .scroll => |s| {
            const inner_w: usize = if (avail_w > s.pad * 2) avail_w - s.pad * 2 else 0;
            return measureHeight(s.child.*, inner_w) + s.pad * 2;
        },
        .overlay => |o| {
            const inner_w: usize = if (avail_w > o.pad * 2) avail_w - o.pad * 2 else 0;
            return measureHeight(o.base.*, inner_w) + o.pad * 2;
        },
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

pub fn measureContentHeight(node: protocol.Node, avail_w: usize) usize {
    return measureHeight(node, avail_w);
}

pub const YRange = struct {
    y: usize,
    h: usize,
};

pub fn findContentYRangeForId(node: protocol.Node, avail_w: usize, id: []const u8) ?YRange {
    var out: YRange = undefined;
    if (findContentYRangeForIdInto(node, avail_w, id, 0, &out)) return out;
    return null;
}

fn findContentYRangeForIdInto(
    node: protocol.Node,
    avail_w: usize,
    id: []const u8,
    y_offset: usize,
    out: *YRange,
) bool {
    if (std.mem.eql(u8, nodeId(node), id)) {
        out.* = .{ .y = y_offset, .h = measureHeight(node, avail_w) };
        return true;
    }

    switch (node) {
        .vbox => |v| {
            const inner_w: usize = if (avail_w > v.pad * 2) avail_w - v.pad * 2 else 0;
            var y: usize = y_offset + v.pad;
            for (v.children) |child| {
                const child_h: usize = measureHeight(child, inner_w);
                if (findContentYRangeForIdInto(child, inner_w, id, y, out)) return true;
                y += child_h;
            }
            return false;
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
            const y_child: usize = y_offset + h.pad;

            var carry: u128 = 0;
            for (h.children) |child| {
                const child_w: usize = if (nodeHintW(child)) |w| w else if (nodeFlex(child) > 0 and total_flex > 0) blk: {
                    const numer: u128 = @as(u128, remaining) * @as(u128, nodeFlex(child)) + carry;
                    const share: usize = @as(usize, @intCast(numer / @as(u128, total_flex)));
                    carry = numer % @as(u128, total_flex);
                    break :blk share;
                } else 0;

                if (findContentYRangeForIdInto(child, child_w, id, y_child, out)) return true;
            }
            return false;
        },
        .scroll => |s| {
            const inner_w: usize = if (avail_w > s.pad * 2) avail_w - s.pad * 2 else 0;
            return findContentYRangeForIdInto(s.child.*, inner_w, id, y_offset + s.pad, out);
        },
        .overlay => |o| {
            const inner_w: usize = if (avail_w > o.pad * 2) avail_w - o.pad * 2 else 0;
            return findContentYRangeForIdInto(o.base.*, inner_w, id, y_offset + o.pad, out);
        },
        else => return false,
    }
}

fn putGraphemeClipped(
    frame: *Frame,
    row: isize,
    col: isize,
    bytes: []const u8,
    width: u2,
    clip: RectI,
    st: style.PackedStyle,
) void {
    if (width == 0) return;
    if (clip.w == 0 or clip.h == 0) return;
    if (row < clip.y or row >= clip.y + @as(isize, @intCast(clip.h))) return;
    if (col < clip.x or col + @as(isize, @intCast(width)) > clip.x + @as(isize, @intCast(clip.w))) return;
    if (row < 0 or col < 0) return;
    frame.putGraphemeStyled(
        @as(usize, @intCast(row)),
        @as(usize, @intCast(col)),
        bytes,
        width,
        st,
    );
}

fn drawWrappedTextInRect(frame: *Frame, rect: RectI, clip: RectI, text: []const u8, st: style.PackedStyle) void {
    if (rect.w == 0 or rect.h == 0) return;

    const max_rows: isize = rect.y + @as(isize, @intCast(rect.h));
    const cols: usize = rect.w;

    var row: isize = rect.y;
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
            const abs_col: isize = rect.x + @as(isize, @intCast(col));
            putGraphemeClipped(frame, row, abs_col, text[g.start..g.end], @as(u2, @intCast(g.width)), clip, st);
            col += g.width;
        }
        i = g.end;
    }
}

fn drawWrappedStyledSpansInRect(
    frame: *Frame,
    rect: RectI,
    clip: RectI,
    spans: []const protocol.Span,
    base: style.Style,
    attrs_or: u8,
) void {
    if (rect.w == 0 or rect.h == 0) return;

    const max_rows: isize = rect.y + @as(isize, @intCast(rect.h));
    const cols: usize = rect.w;

    var row: isize = rect.y;
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
                const abs_col: isize = rect.x + @as(isize, @intCast(col));
                putGraphemeClipped(frame, row, abs_col, text[g.start..g.end], @as(u2, @intCast(g.width)), clip, span_packed);
                col += g.width;
            }
            i = g.end;
        }
    }
}

fn drawInlineStyledSpansInRect(
    frame: *Frame,
    row: isize,
    rect: RectI,
    clip: RectI,
    spans: []const protocol.Span,
    base: style.Style,
    start_col: usize,
    attrs_or: u8,
) void {
    if (rect.w == 0) return;
    if (row < rect.y or row >= rect.y + @as(isize, @intCast(rect.h))) return;

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
                const abs_col: isize = rect.x + @as(isize, @intCast(used));
                putGraphemeClipped(frame, row, abs_col, text[g.start..g.end], @as(u2, @intCast(g.width)), clip, span_packed);
                used += g.width;
            }
            i = g.end;
        }
    }
}

fn renderLinePiecesInRectStyled(
    frame: *Frame,
    row: isize,
    rect: RectI,
    clip: RectI,
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
                const abs_col: isize = rect.x + @as(isize, @intCast(used));
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
        .scroll => |s| s.style,
        .overlay => |o| o.style,
        .text => |t| t.style,
        .styled_text => |t| t.style,
        .input => |i| i.style,
        .list => |l| l.style,
    };
}

fn fillRectStyle(frame: *Frame, rect: RectI, clip: RectI, st: style.PackedStyle) void {
    const r = rectIntersect(rect, clip);
    if (r.w == 0 or r.h == 0) return;

    if (r.y < 0 or r.x < 0) return;
    const y0: usize = @as(usize, @intCast(r.y));
    const x0: usize = @as(usize, @intCast(r.x));
    const y_end: usize = y0 + r.h;
    const x_end: usize = x0 + r.w;

    var y: usize = y0;
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
    rect: RectI,
    clip: RectI,
    state: RenderState,
    cursor_out: *?CursorPos,
    i: protocol.InputNode,
    inherited: style.Style,
) void {
    if (rect.h == 0) return;
    const row: isize = rect.y;

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
            if (cols != 0 and row >= clip.y and row < clip.y + @as(isize, @intCast(clip.h))) {
                const col_abs: isize = rect.x + @as(isize, @intCast(prefix_cols));
                if (row >= 0 and col_abs >= clip.x and col_abs < clip.x + @as(isize, @intCast(clip.w)) and col_abs >= 0) {
                    cursor_out.* = .{
                        .row = @as(usize, @intCast(row + 1)),
                        .col = @as(usize, @intCast(col_abs + 1)),
                    };
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
            var col_abs: isize = rect.x + @as(isize, @intCast(prefix_cols + cursor_cols));
            const rect_x2: isize = rect.x + @as(isize, @intCast(cols));
            if (col_abs >= rect_x2 and cols != 0) col_abs = rect_x2 - 1;
            if (row >= clip.y and row < clip.y + @as(isize, @intCast(clip.h)) and col_abs >= clip.x and col_abs < clip.x + @as(isize, @intCast(clip.w)) and row >= 0 and col_abs >= 0) {
                cursor_out.* = .{
                    .row = @as(usize, @intCast(row + 1)),
                    .col = @as(usize, @intCast(col_abs + 1)),
                };
            }
        }

        renderLinePiecesInRectStyled(frame, row, rect, clip, &.{ prefix, visible }, &.{ base_packed, base_packed });
        return;
    }

    if (i.placeholder) |ph| {
        if (focused) {
            if (cursor_out.* == null and cols != 0) {
                const col_abs: isize = rect.x + @as(isize, @intCast(prefix_cols));
                if (row >= clip.y and row < clip.y + @as(isize, @intCast(clip.h)) and col_abs >= clip.x and col_abs < clip.x + @as(isize, @intCast(clip.w)) and row >= 0 and col_abs >= 0) {
                    cursor_out.* = .{
                        .row = @as(usize, @intCast(row + 1)),
                        .col = @as(usize, @intCast(col_abs + 1)),
                    };
                }
            }
            renderLinePiecesInRectStyled(frame, row, rect, clip, &.{ prefix, ph }, &.{ base_packed, ph_packed });
        } else {
            renderLinePiecesInRectStyled(frame, row, rect, clip, &.{ prefix, "[", ph, "]" }, &.{ base_packed, base_packed, ph_packed, base_packed });
        }
    } else {
        if (focused and cursor_out.* == null and cols != 0) {
            const col_abs: isize = rect.x + @as(isize, @intCast(prefix_cols));
            if (row >= clip.y and row < clip.y + @as(isize, @intCast(clip.h)) and col_abs >= clip.x and col_abs < clip.x + @as(isize, @intCast(clip.w)) and row >= 0 and col_abs >= 0) {
                cursor_out.* = .{
                    .row = @as(usize, @intCast(row + 1)),
                    .col = @as(usize, @intCast(col_abs + 1)),
                };
            }
        }
        renderLinePiecesInRectStyled(frame, row, rect, clip, &.{prefix}, &.{base_packed});
    }
}

fn paintList(frame: *Frame, rect: RectI, clip: RectI, state: RenderState, l: protocol.ListNode, inherited: style.Style) void {
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

        const row: isize = rect.y + @as(isize, @intCast(row_idx));
        const y_end: isize = rect.y + @as(isize, @intCast(rect.h));
        if (row >= y_end) break;
        const row_rect: RectI = .{ .x = rect.x, .y = row, .w = rect.w, .h = 1 };
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
    rect: RectI,
    clip: RectI,
    state: RenderState,
    cursor_out: *?CursorPos,
    v: protocol.VBoxNode,
    inherited: style.Style,
    mode: VBoxMode,
) void {
    const pad = v.pad;
    const inner = rectDeflate(rect, pad);
    const base_clip = rectIntersect(clip, rect);
    const child_clip = if (v.clip) rectIntersect(base_clip, inner) else base_clip;

    const y_end: isize = inner.y + @as(isize, @intCast(inner.h));
    const clip_y_end: isize = child_clip.y + @as(isize, @intCast(child_clip.h));

    var fixed_sum: usize = 0;
    var total_flex: usize = 0;
    if (mode == .bounded) {
        for (v.children) |child| {
            if (nodeHintH(child)) |h| {
                fixed_sum += h;
            } else if (nodeFlex(child) > 0) {
                total_flex += nodeFlex(child);
            } else {
                fixed_sum += measureHeight(child, inner.w);
            }
        }
    }

    const remaining: usize = if (mode == .bounded and inner.h > fixed_sum) inner.h - fixed_sum else 0;

    var y: isize = inner.y;
    var carry: u128 = 0;

    for (v.children) |child| {
        if (y >= y_end) break;
        if (child_clip.h != 0 and y >= clip_y_end) break;

        const child_h: usize = blk: {
            if (nodeHintH(child)) |h| break :blk h;
            if (mode == .bounded and nodeFlex(child) > 0 and total_flex > 0) {
                const numer: u128 = @as(u128, remaining) * @as(u128, nodeFlex(child)) + carry;
                const share: usize = @as(usize, @intCast(numer / @as(u128, total_flex)));
                carry = numer % @as(u128, total_flex);
                break :blk share;
            }
            break :blk measureHeight(child, inner.w);
        };

        const child_y2: isize = y + @as(isize, @intCast(child_h));
        const clamped_h: usize = if (child_y2 <= y_end) child_h else if (y_end > y) @as(usize, @intCast(y_end - y)) else 0;
        if (clamped_h == 0) break;

        const child_rect: RectI = .{ .x = inner.x, .y = y, .w = inner.w, .h = clamped_h };
        const rect_y2: isize = child_rect.y + @as(isize, @intCast(child_rect.h));

        if (child_clip.h != 0 and rect_y2 <= child_clip.y) {
            y += @as(isize, @intCast(clamped_h));
            continue;
        }

        paintNode(frame, child, child_rect, child_clip, state, cursor_out, inherited, mode);
        y += @as(isize, @intCast(clamped_h));
    }
}

fn paintHBox(
    frame: *Frame,
    rect: RectI,
    clip: RectI,
    state: RenderState,
    cursor_out: *?CursorPos,
    h: protocol.HBoxNode,
    inherited: style.Style,
    mode: VBoxMode,
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

    var x: isize = inner.x;
    var carry: u128 = 0;

    for (h.children) |child| {
        const x_end: isize = inner.x + @as(isize, @intCast(inner.w));
        if (x >= x_end) break;

        const child_w: usize = if (nodeHintW(child)) |w| w else if (nodeFlex(child) > 0 and total_flex > 0) blk: {
            const numer: u128 = @as(u128, remaining) * @as(u128, nodeFlex(child)) + carry;
            const share: usize = @as(usize, @intCast(numer / @as(u128, total_flex)));
            carry = numer % @as(u128, total_flex);
            break :blk share;
        } else 0;

        const child_x2: isize = x + @as(isize, @intCast(child_w));
        const clamped_w: usize = if (child_x2 <= x_end) child_w else if (x_end > x) @as(usize, @intCast(x_end - x)) else 0;
        if (clamped_w == 0) break;
        const child_rect: RectI = .{ .x = x, .y = inner.y, .w = clamped_w, .h = inner.h };
        paintNode(frame, child, child_rect, child_clip, state, cursor_out, inherited, mode);
        x += @as(isize, @intCast(clamped_w));
    }
}

fn paintNode(
    frame: *Frame,
    node: protocol.Node,
    rect: RectI,
    clip: RectI,
    state: RenderState,
    cursor_out: *?CursorPos,
    inherited: style.Style,
    mode: VBoxMode,
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
        .vbox => |v| paintVBox(frame, rect, node_clip, state, cursor_out, v, resolved, mode),
        .hbox => |h| paintHBox(frame, rect, node_clip, state, cursor_out, h, resolved, mode),
        .scroll => |s| paintScroll(frame, rect, node_clip, state, cursor_out, s, resolved),
        .overlay => |o| paintOverlay(frame, rect, node_clip, state, cursor_out, o, resolved, mode),
    }
}

fn paintOverlay(
    frame: *Frame,
    rect: RectI,
    clip: RectI,
    state: RenderState,
    cursor_out: *?CursorPos,
    o: protocol.OverlayNode,
    inherited: style.Style,
    mode: VBoxMode,
) void {
    const pad = o.pad;
    const inner = rectDeflate(rect, pad);
    const base_clip = rectIntersect(clip, rect);
    const child_clip = if (o.clip) rectIntersect(base_clip, inner) else base_clip;

    paintNode(frame, o.base.*, inner, child_clip, state, cursor_out, inherited, mode);

    const screen = screenRect(frame);
    for (o.layers) |layer| {
        const layer_rect = computeOverlayLayerRectForBaseRect(screen, rect, inner, o.base.*, layer, state.scrolls, mode);
        const layer_clip = screen;
        paintNode(frame, layer.node.*, layer_rect, layer_clip, state, cursor_out, inherited, .bounded);
    }
}

fn computeOverlayLayerRectForBaseRect(
    screen: RectI,
    overlay_rect: RectI,
    base_rect: RectI,
    base: protocol.Node,
    layer: protocol.OverlayLayer,
    scrolls: []const ScrollState,
    mode: VBoxMode,
) RectI {
    const anchor_rect: RectI = blk: {
        if (layer.anchor) |aid| {
            if (findRectInNodeIBaseOnly(base, base_rect, aid, scrolls, mode)) |r| break :blk r;
        }
        break :blk .{ .x = overlay_rect.x, .y = overlay_rect.y, .w = 0, .h = 0 };
    };

    const w: usize = layer.w orelse blk: {
        if (layer.anchor != null and layer.placement != .center) break :blk anchor_rect.w;
        break :blk overlay_rect.w;
    };
    const h: usize = layer.h orelse measureHeight(layer.node.*, w);

    var x: isize = 0;
    var y: isize = 0;

    switch (layer.placement) {
        .below => {
            x = alignStartCenterEnd(anchor_rect.x, anchor_rect.w, w, layer.align_);
            y = anchor_rect.y + @as(isize, @intCast(anchor_rect.h));
        },
        .above => {
            x = alignStartCenterEnd(anchor_rect.x, anchor_rect.w, w, layer.align_);
            y = anchor_rect.y - @as(isize, @intCast(h));
        },
        .right => {
            x = anchor_rect.x + @as(isize, @intCast(anchor_rect.w));
            y = alignStartCenterEnd(anchor_rect.y, anchor_rect.h, h, layer.align_);
        },
        .left => {
            x = anchor_rect.x - @as(isize, @intCast(w));
            y = alignStartCenterEnd(anchor_rect.y, anchor_rect.h, h, layer.align_);
        },
        .center => {
            const dx: isize = @as(isize, @intCast(if (overlay_rect.w > w) overlay_rect.w - w else 0));
            const dy: isize = @as(isize, @intCast(if (overlay_rect.h > h) overlay_rect.h - h else 0));
            x = overlay_rect.x + @divTrunc(dx, 2);
            y = overlay_rect.y + @divTrunc(dy, 2);
        },
    }

    x += layer.offset_x;
    y += layer.offset_y;

    const clamped = clampOverlayOrigin(screen, x, y, w, h);
    return .{ .x = clamped.x, .y = clamped.y, .w = w, .h = h };
}

fn paintScroll(
    frame: *Frame,
    rect: RectI,
    clip: RectI,
    state: RenderState,
    cursor_out: *?CursorPos,
    s: protocol.ScrollNode,
    inherited: style.Style,
) void {
    const pad = s.pad;
    const inner = rectDeflate(rect, pad);
    const base_clip = rectIntersect(clip, rect);
    const child_clip = if (s.clip) rectIntersect(base_clip, inner) else base_clip;
    if (inner.w == 0 or inner.h == 0) return;

    const st = findScrollState(state.scrolls, s.id);
    const scroll_y: usize = if (st) |ss| ss.scroll_y else 0;
    const content_h: usize = if (st) |ss| ss.content_h else measureHeight(s.child.*, inner.w);

    const dy: isize = @as(isize, @intCast(@min(scroll_y, @as(usize, std.math.maxInt(isize)))));
    const child_rect: RectI = .{
        .x = inner.x,
        .y = inner.y - dy,
        .w = inner.w,
        .h = content_h,
    };
    paintNode(frame, s.child.*, child_rect, child_clip, state, cursor_out, inherited, .unbounded);
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

fn findScrollState(scrolls: []const ScrollState, id: []const u8) ?ScrollState {
    var lo: usize = 0;
    var hi: usize = scrolls.len;
    while (lo < hi) {
        const mid: usize = lo + (hi - lo) / 2;
        const st = scrolls[mid];
        switch (std.mem.order(u8, st.id, id)) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return st,
        }
    }
    return null;
}

fn findScrollStateUnsorted(scrolls: []const ScrollState, id: []const u8) ?ScrollState {
    for (scrolls) |st| {
        if (std.mem.eql(u8, st.id, id)) return st;
    }
    return null;
}

pub fn findRectForId(root: protocol.Node, rows: usize, cols: usize, id: []const u8) ?Rect {
    return findRectForIdWithScrolls(root, rows, cols, id, &.{});
}

pub fn findRectForIdWithScrolls(
    root: protocol.Node,
    rows: usize,
    cols: usize,
    id: []const u8,
    scrolls: []const ScrollState,
) ?Rect {
    const root_rect: RectI = .{ .x = 0, .y = 0, .w = cols, .h = rows };
    const r = findRectInNodeI(root, root_rect, id, scrolls, .bounded, root_rect) orelse return null;
    const vis = rectIntersect(root_rect, r);
    if (vis.w == 0 or vis.h == 0) return null;
    if (vis.x < 0 or vis.y < 0) return null;
    return .{
        .x = @as(usize, @intCast(vis.x)),
        .y = @as(usize, @intCast(vis.y)),
        .w = vis.w,
        .h = vis.h,
    };
}

fn findRectInNodeI(
    node: protocol.Node,
    rect: RectI,
    id: []const u8,
    scrolls: []const ScrollState,
    mode: VBoxMode,
    screen: RectI,
) ?RectI {
    if (std.mem.eql(u8, nodeId(node), id)) return rect;

    switch (node) {
        .vbox => |v| {
            const inner = rectDeflate(rect, v.pad);
            const y_end: isize = inner.y + @as(isize, @intCast(inner.h));

            var fixed_sum: usize = 0;
            var total_flex: usize = 0;
            if (mode == .bounded) {
                for (v.children) |child| {
                    if (nodeHintH(child)) |h| {
                        fixed_sum += h;
                    } else if (nodeFlex(child) > 0) {
                        total_flex += nodeFlex(child);
                    } else {
                        fixed_sum += measureHeight(child, inner.w);
                    }
                }
            }

            const remaining: usize = if (mode == .bounded and inner.h > fixed_sum) inner.h - fixed_sum else 0;

            var y: isize = inner.y;
            var carry: u128 = 0;

            for (v.children) |child| {
                if (y >= y_end) break;

                const child_h: usize = blk: {
                    if (nodeHintH(child)) |h| break :blk h;
                    if (mode == .bounded and nodeFlex(child) > 0 and total_flex > 0) {
                        const numer: u128 = @as(u128, remaining) * @as(u128, nodeFlex(child)) + carry;
                        const share: usize = @as(usize, @intCast(numer / @as(u128, total_flex)));
                        carry = numer % @as(u128, total_flex);
                        break :blk share;
                    }
                    break :blk measureHeight(child, inner.w);
                };

                const child_y2: isize = y + @as(isize, @intCast(child_h));
                const clamped_h: usize = if (child_y2 <= y_end) child_h else if (y_end > y) @as(usize, @intCast(y_end - y)) else 0;
                if (clamped_h == 0) break;

                const child_rect: RectI = .{ .x = inner.x, .y = y, .w = inner.w, .h = clamped_h };
                if (findRectInNodeI(child, child_rect, id, scrolls, mode, screen)) |r| return r;
                y += @as(isize, @intCast(clamped_h));
            }
            return null;
        },
        .hbox => |h| {
            const inner = rectDeflate(rect, h.pad);
            const x_end: isize = inner.x + @as(isize, @intCast(inner.w));

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

            var x: isize = inner.x;
            var carry: u128 = 0;

            for (h.children) |child| {
                if (x >= x_end) break;

                const child_w: usize = if (nodeHintW(child)) |w| w else if (nodeFlex(child) > 0 and total_flex > 0) blk: {
                    const numer: u128 = @as(u128, remaining) * @as(u128, nodeFlex(child)) + carry;
                    const share: usize = @as(usize, @intCast(numer / @as(u128, total_flex)));
                    carry = numer % @as(u128, total_flex);
                    break :blk share;
                } else 0;

                const child_x2: isize = x + @as(isize, @intCast(child_w));
                const clamped_w: usize = if (child_x2 <= x_end) child_w else if (x_end > x) @as(usize, @intCast(x_end - x)) else 0;
                if (clamped_w == 0) break;

                const child_rect: RectI = .{ .x = x, .y = inner.y, .w = clamped_w, .h = inner.h };
                if (findRectInNodeI(child, child_rect, id, scrolls, mode, screen)) |r| return r;
                x += @as(isize, @intCast(clamped_w));
            }
            return null;
        },
        .scroll => |s| {
            const inner = rectDeflate(rect, s.pad);
            const st = findScrollStateUnsorted(scrolls, s.id);
            const scroll_y: usize = if (st) |ss| ss.scroll_y else 0;
            const content_h: usize = if (st) |ss| ss.content_h else measureHeight(s.child.*, inner.w);

            const dy: isize = @as(isize, @intCast(@min(scroll_y, @as(usize, std.math.maxInt(isize)))));
            const child_rect: RectI = .{
                .x = inner.x,
                .y = inner.y - dy,
                .w = inner.w,
                .h = content_h,
            };
            return findRectInNodeI(s.child.*, child_rect, id, scrolls, .unbounded, screen);
        },
        .overlay => |o| {
            const inner = rectDeflate(rect, o.pad);
            if (findRectInNodeI(o.base.*, inner, id, scrolls, mode, screen)) |r| return r;
            for (o.layers) |layer| {
                const layer_rect = computeOverlayLayerRectForBaseRect(screen, rect, inner, o.base.*, layer, scrolls, mode);
                if (findRectInNodeI(layer.node.*, layer_rect, id, scrolls, .bounded, screen)) |r| return r;
            }
            return null;
        },
        else => return null,
    }
}

fn findRectInNodeIBaseOnly(
    node: protocol.Node,
    rect: RectI,
    id: []const u8,
    scrolls: []const ScrollState,
    mode: VBoxMode,
) ?RectI {
    if (std.mem.eql(u8, nodeId(node), id)) return rect;

    switch (node) {
        .vbox => |v| {
            const inner = rectDeflate(rect, v.pad);
            const y_end: isize = inner.y + @as(isize, @intCast(inner.h));

            var fixed_sum: usize = 0;
            var total_flex: usize = 0;
            if (mode == .bounded) {
                for (v.children) |child| {
                    if (nodeHintH(child)) |h| {
                        fixed_sum += h;
                    } else if (nodeFlex(child) > 0) {
                        total_flex += nodeFlex(child);
                    } else {
                        fixed_sum += measureHeight(child, inner.w);
                    }
                }
            }

            const remaining: usize = if (mode == .bounded and inner.h > fixed_sum) inner.h - fixed_sum else 0;

            var y: isize = inner.y;
            var carry: u128 = 0;

            for (v.children) |child| {
                if (y >= y_end) break;

                const child_h: usize = blk: {
                    if (nodeHintH(child)) |h| break :blk h;
                    if (mode == .bounded and nodeFlex(child) > 0 and total_flex > 0) {
                        const numer: u128 = @as(u128, remaining) * @as(u128, nodeFlex(child)) + carry;
                        const share: usize = @as(usize, @intCast(numer / @as(u128, total_flex)));
                        carry = numer % @as(u128, total_flex);
                        break :blk share;
                    }
                    break :blk measureHeight(child, inner.w);
                };

                const child_y2: isize = y + @as(isize, @intCast(child_h));
                const clamped_h: usize = if (child_y2 <= y_end) child_h else if (y_end > y) @as(usize, @intCast(y_end - y)) else 0;
                if (clamped_h == 0) break;

                const child_rect: RectI = .{ .x = inner.x, .y = y, .w = inner.w, .h = clamped_h };
                if (findRectInNodeIBaseOnly(child, child_rect, id, scrolls, mode)) |r| return r;
                y += @as(isize, @intCast(clamped_h));
            }
            return null;
        },
        .hbox => |h| {
            const inner = rectDeflate(rect, h.pad);
            const x_end: isize = inner.x + @as(isize, @intCast(inner.w));

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

            var x: isize = inner.x;
            var carry: u128 = 0;

            for (h.children) |child| {
                if (x >= x_end) break;

                const child_w: usize = if (nodeHintW(child)) |w| w else if (nodeFlex(child) > 0 and total_flex > 0) blk: {
                    const numer: u128 = @as(u128, remaining) * @as(u128, nodeFlex(child)) + carry;
                    const share: usize = @as(usize, @intCast(numer / @as(u128, total_flex)));
                    carry = numer % @as(u128, total_flex);
                    break :blk share;
                } else 0;

                const child_x2: isize = x + @as(isize, @intCast(child_w));
                const clamped_w: usize = if (child_x2 <= x_end) child_w else if (x_end > x) @as(usize, @intCast(x_end - x)) else 0;
                if (clamped_w == 0) break;

                const child_rect: RectI = .{ .x = x, .y = inner.y, .w = clamped_w, .h = inner.h };
                if (findRectInNodeIBaseOnly(child, child_rect, id, scrolls, mode)) |r| return r;
                x += @as(isize, @intCast(clamped_w));
            }
            return null;
        },
        .scroll => |s| {
            const inner = rectDeflate(rect, s.pad);
            const st = findScrollStateUnsorted(scrolls, s.id);
            const scroll_y: usize = if (st) |ss| ss.scroll_y else 0;
            const content_h: usize = if (st) |ss| ss.content_h else measureHeight(s.child.*, inner.w);

            const dy: isize = @as(isize, @intCast(@min(scroll_y, @as(usize, std.math.maxInt(isize)))));
            const child_rect: RectI = .{
                .x = inner.x,
                .y = inner.y - dy,
                .w = inner.w,
                .h = content_h,
            };
            return findRectInNodeIBaseOnly(s.child.*, child_rect, id, scrolls, .unbounded);
        },
        .overlay => |o| {
            const inner = rectDeflate(rect, o.pad);
            return findRectInNodeIBaseOnly(o.base.*, inner, id, scrolls, mode);
        },
        else => return null,
    }
}

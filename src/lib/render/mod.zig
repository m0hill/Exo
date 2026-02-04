const std = @import("std");
const frame_mod = @import("../frame.zig");
const protocol = @import("../protocol/mod.zig");
const style = @import("../style.zig");
const unicode = @import("../unicode.zig");
const render_text = @import("text.zig");
const theme_mod = @import("theme.zig");

const Frame = frame_mod.Frame;
const CursorPos = frame_mod.CursorPos;
const default_theme = theme_mod.default_theme;

pub const RenderState = struct {
    focused_id: ?[]const u8 = null,
    hovered_id: ?[]const u8 = null,
    hovered_item: ?[]const u8 = null,
    active_id: ?[]const u8 = null,
    inputs: []const InputState = &.{},
    textareas: []const TextareaState = &.{},
    lists: []const ListState = &.{},
    scrolls: []const ScrollState = &.{},
};

pub const InputState = struct {
    id: []const u8,
    value: []const u8,
    cursor: usize,
    scroll_x: usize,
};

pub const TextareaState = struct {
    id: []const u8,
    value: []const u8,
    cursor: usize,
    scroll_y: usize,
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

fn hAlignOffset(avail: usize, content: usize, align_mode: protocol.HorizontalAlign) usize {
    if (content >= avail) return 0;
    const extra: usize = avail - content;
    return switch (align_mode) {
        .left => 0,
        .center => extra / 2,
        .right => extra,
    };
}

fn vAlignOffset(avail: usize, content: usize, align_mode: protocol.VerticalAlign) usize {
    if (content >= avail) return 0;
    const extra: usize = avail - content;
    return switch (align_mode) {
        .top => 0,
        .center => extra / 2,
        .bottom => extra,
    };
}

fn nodeAlignSelf(node: protocol.Node) ?protocol.AlignItems {
    return switch (node) {
        .vbox => |v| v.align_self,
        .hbox => |h| h.align_self,
        .box => |b| b.align_self,
        .scroll => |s| s.align_self,
        .overlay => |o| o.align_self,
        .text => |t| t.align_self,
        .styled_text => |t| t.align_self,
        .input => |i| i.align_self,
        .textarea => |t| t.align_self,
        .list => |l| l.align_self,
    };
}

fn alignItemsEffective(child: protocol.Node, parent: protocol.AlignItems) protocol.AlignItems {
    return nodeAlignSelf(child) orelse parent;
}

fn slotSplit(extra_space: usize, slots: usize) struct { base: usize, rem: usize } {
    if (slots == 0) return .{ .base = 0, .rem = 0 };
    return .{ .base = extra_space / slots, .rem = extra_space % slots };
}

fn slotValue(base: usize, rem: usize, idx: usize) usize {
    return base + @as(usize, @intFromBool(idx < rem));
}

fn justifyStartOffset(justify: protocol.JustifyContent, count: usize, extra_space: usize) usize {
    if (count == 0) return 0;
    return switch (justify) {
        .start => 0,
        .center => extra_space / 2,
        .end => extra_space,
        .space_between => 0,
        .space_evenly => blk: {
            const split = slotSplit(extra_space, count + 1);
            break :blk slotValue(split.base, split.rem, 0);
        },
        .space_around => blk: {
            const split = slotSplit(extra_space, count * 2);
            break :blk slotValue(split.base, split.rem, 0);
        },
    };
}

fn justifyGapExtra(justify: protocol.JustifyContent, count: usize, extra_space: usize, gap_idx: usize) usize {
    if (count < 2) return 0;
    const gap_slots: usize = count - 1;
    if (gap_idx >= gap_slots) return 0;

    return switch (justify) {
        .start, .center, .end => 0,
        .space_between => blk: {
            const split = slotSplit(extra_space, gap_slots);
            break :blk slotValue(split.base, split.rem, gap_idx);
        },
        .space_evenly => blk: {
            const split = slotSplit(extra_space, count + 1);
            // Slot 0 is before first item; slot (gap_idx + 1) is between gap_idx and gap_idx+1.
            break :blk slotValue(split.base, split.rem, gap_idx + 1);
        },
        .space_around => blk: {
            const split = slotSplit(extra_space, count * 2);
            // Slots: [0] before first, [1] after first, [2] before second, [3] after second, ...
            const a = slotValue(split.base, split.rem, gap_idx * 2 + 1);
            const b = slotValue(split.base, split.rem, gap_idx * 2 + 2);
            break :blk a + b;
        },
    };
}

fn vboxChildWidth(inner_w: usize, parent_align: protocol.AlignItems, child: protocol.Node) usize {
    const eff = alignItemsEffective(child, parent_align);
    if (eff == .stretch) return inner_w;
    const hinted: usize = nodeHintW(child) orelse inner_w;
    return if (hinted > inner_w) inner_w else hinted;
}

fn vboxChildX(inner_x: isize, inner_w: usize, child_w: usize, align_mode: protocol.AlignItems) isize {
    const dx: isize = @as(isize, @intCast(if (inner_w > child_w) inner_w - child_w else 0));
    return switch (align_mode) {
        .stretch, .start => inner_x,
        .center => inner_x + @divTrunc(dx, 2),
        .end => inner_x + dx,
    };
}

fn hboxChildHeight(inner_h: usize, parent_align: protocol.AlignItems, child: protocol.Node) usize {
    const eff = alignItemsEffective(child, parent_align);
    if (eff == .stretch) return inner_h;
    const hinted: usize = nodeHintH(child) orelse inner_h;
    return if (hinted > inner_h) inner_h else hinted;
}

fn hboxChildY(inner_y: isize, inner_h: usize, child_h: usize, align_mode: protocol.AlignItems) isize {
    const dy: isize = @as(isize, @intCast(if (inner_h > child_h) inner_h - child_h else 0));
    return switch (align_mode) {
        .stretch, .start => inner_y,
        .center => inner_y + @divTrunc(dy, 2),
        .end => inner_y + dy,
    };
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
        .box => |b| b.id,
        .scroll => |s| s.id,
        .overlay => |o| o.id,
        .text => |t| t.id,
        .styled_text => |t| t.id,
        .input => |i| i.id,
        .textarea => |t| t.id,
        .list => |l| l.id,
    };
}

fn nodeHintW(node: protocol.Node) ?usize {
    return switch (node) {
        .vbox => |v| v.w,
        .hbox => |h| h.w,
        .box => |b| b.w,
        .scroll => |s| s.w,
        .overlay => |o| o.w,
        .text => |t| t.w,
        .styled_text => |t| t.w,
        .input => |i| i.w,
        .textarea => |t| t.w,
        .list => |l| l.w,
    };
}

fn nodeHintH(node: protocol.Node) ?usize {
    return switch (node) {
        .vbox => |v| v.h,
        .hbox => |h| h.h,
        .box => |b| b.h,
        .scroll => |s| s.h,
        .overlay => |o| o.h,
        .text => |t| t.h,
        .styled_text => |t| t.h,
        .input => |i| i.h,
        .textarea => |t| t.h,
        .list => |l| l.h,
    };
}

fn nodeFlex(node: protocol.Node) usize {
    return switch (node) {
        .vbox => |v| v.flex,
        .hbox => |h| h.flex,
        .box => |b| b.flex,
        .scroll => |s| s.flex,
        .overlay => |o| o.flex,
        .text => |t| t.flex,
        .styled_text => |t| t.flex,
        .input => |i| i.flex,
        .textarea => |t| t.flex,
        .list => |l| l.flex,
    };
}

fn nodePad(node: protocol.Node) usize {
    return switch (node) {
        .vbox => |v| v.pad,
        .hbox => |h| h.pad,
        .box => |b| b.pad,
        .scroll => |s| s.pad,
        .overlay => |o| o.pad,
        else => 0,
    };
}

fn nodeClip(node: protocol.Node) bool {
    return switch (node) {
        .vbox => |v| v.clip,
        .hbox => |h| h.clip,
        .box => |b| b.clip,
        .scroll => |s| s.clip,
        .overlay => |o| o.clip,
        else => false,
    };
}

fn measureHeight(node: protocol.Node, avail_w: usize) usize {
    if (nodeHintH(node)) |h| return h;
    switch (node) {
        .text => |t| return render_text.countWrappedLines(t.text, avail_w),
        .styled_text => |t| return render_text.countWrappedLinesSpans(t.spans, avail_w),
        .input => return 1,
        .textarea => return 3,
        .list => |l| return l.height orelse l.children.len,
        .box => |b| {
            const border_thickness: usize = if (b.border and avail_w >= 2) 1 else 0;
            const chrome: usize = border_thickness + b.pad;
            const inner_w: usize = if (avail_w > chrome * 2) avail_w - chrome * 2 else 0;
            return measureHeight(b.child.*, inner_w) + chrome * 2;
        },
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
            if (v.children.len > 1) total += v.gap * (v.children.len - 1);
            for (v.children) |child| {
                const child_w = vboxChildWidth(inner_w, v.align_items, child);
                total += measureHeight(child, child_w);
            }
            return total;
        },
        .hbox => |h| {
            const inner_w_raw: usize = if (avail_w > h.pad * 2) avail_w - h.pad * 2 else 0;
            const gaps_total: usize = if (h.children.len > 1) h.gap * (h.children.len - 1) else 0;
            const inner_w: usize = if (inner_w_raw > gaps_total) inner_w_raw - gaps_total else 0;

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
            for (v.children, 0..) |child, idx| {
                const child_w = vboxChildWidth(inner_w, v.align_items, child);
                const child_h: usize = measureHeight(child, child_w);
                if (findContentYRangeForIdInto(child, child_w, id, y, out)) return true;
                y += child_h;
                if (idx + 1 < v.children.len) y += v.gap;
            }
            return false;
        },
        .hbox => |h| {
            const inner_w_raw: usize = if (avail_w > h.pad * 2) avail_w - h.pad * 2 else 0;
            const gaps_total: usize = if (h.children.len > 1) h.gap * (h.children.len - 1) else 0;
            const inner_w: usize = if (inner_w_raw > gaps_total) inner_w_raw - gaps_total else 0;

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
            const y_base: usize = y_offset + h.pad;

            var inner_h: usize = 0;

            var carry: u128 = 0;
            for (h.children) |child| {
                const child_w: usize = if (nodeHintW(child)) |w| w else if (nodeFlex(child) > 0 and total_flex > 0) blk: {
                    const numer: u128 = @as(u128, remaining) * @as(u128, nodeFlex(child)) + carry;
                    const share: usize = @as(usize, @intCast(numer / @as(u128, total_flex)));
                    carry = numer % @as(u128, total_flex);
                    break :blk share;
                } else 0;

                const ch = measureHeight(child, child_w);
                if (ch > inner_h) inner_h = ch;
            }

            carry = 0;
            for (h.children) |child| {
                const child_w: usize = if (nodeHintW(child)) |w| w else if (nodeFlex(child) > 0 and total_flex > 0) blk: {
                    const numer: u128 = @as(u128, remaining) * @as(u128, nodeFlex(child)) + carry;
                    const share: usize = @as(usize, @intCast(numer / @as(u128, total_flex)));
                    carry = numer % @as(u128, total_flex);
                    break :blk share;
                } else 0;

                const eff = alignItemsEffective(child, h.align_items);
                const child_h = hboxChildHeight(inner_h, h.align_items, child);
                const y_child: usize = y_base + vAlignOffset(inner_h, child_h, switch (eff) {
                    .stretch, .start => .top,
                    .center => .center,
                    .end => .bottom,
                });
                if (findContentYRangeForIdInto(child, child_w, id, y_child, out)) return true;
            }
            return false;
        },
        .scroll => |s| {
            const inner_w: usize = if (avail_w > s.pad * 2) avail_w - s.pad * 2 else 0;
            return findContentYRangeForIdInto(s.child.*, inner_w, id, y_offset + s.pad, out);
        },
        .box => |b| {
            const border_thickness: usize = if (b.border and avail_w >= 2) 1 else 0;
            const chrome: usize = border_thickness + b.pad;
            const inner_w: usize = if (avail_w > chrome * 2) avail_w - chrome * 2 else 0;
            return findContentYRangeForIdInto(b.child.*, inner_w, id, y_offset + chrome, out);
        },
        .overlay => |o| {
            const inner_w: usize = if (avail_w > o.pad * 2) avail_w - o.pad * 2 else 0;
            return findContentYRangeForIdInto(o.base.*, inner_w, id, y_offset + o.pad, out);
        },
        else => return false,
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
                render_text.putGraphemeClipped(frame, row, abs_col, text[g.start..g.end], @as(u2, @intCast(g.width)), clip, span_packed);
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
                render_text.putGraphemeClipped(frame, row, abs_col, p[g.start..g.end], @as(u2, @intCast(g.width)), clip, st);
                used += g.width;
            }
            i = g.end;
        }
    }
}

fn drawInlineTextAt(
    frame: *Frame,
    row: isize,
    col_abs: isize,
    clip: RectI,
    text: []const u8,
    max_w: usize,
    st: style.PackedStyle,
) void {
    var used: usize = 0;
    var i: usize = 0;
    while (i < text.len and used < max_w) {
        const g = unicode.nextGrapheme(text, i);
        if (g.end <= i) break;

        if (g.width > 0 and max_w != 0 and g.width > max_w) {
            i = g.end;
            continue;
        }
        if (g.width > 0 and used + g.width > max_w) break;

        if (g.width > 0) {
            const x: isize = col_abs + @as(isize, @intCast(used));
            render_text.putGraphemeClipped(frame, row, x, text[g.start..g.end], @as(u2, @intCast(g.width)), clip, st);
            used += g.width;
        }
        i = g.end;
    }
}

fn packedEq(a: style.PackedStyle, b: style.PackedStyle) bool {
    return @as(u64, @bitCast(a)) == @as(u64, @bitCast(b));
}

fn applyOverlay(base: style.Style, overlay: theme_mod.Overlay) style.Style {
    var out = base;
    if (overlay.fg) |c| out.fg = c;
    if (overlay.bg) |c| out.bg = c;
    return style.overlayAttrs(out, overlay.attrs_set, overlay.attrs_values);
}

fn nodeDisabled(node: protocol.Node) bool {
    return switch (node) {
        .vbox => |v| v.disabled,
        .hbox => |h| h.disabled,
        .box => |b| b.disabled,
        .scroll => |s| s.disabled,
        .overlay => |o| o.disabled,
        .text => |t| t.disabled,
        .styled_text => |t| t.disabled,
        .input => |i| i.disabled,
        .textarea => |t| t.disabled,
        .list => |l| l.disabled,
    };
}

fn nodeReadonly(node: protocol.Node) bool {
    return switch (node) {
        .vbox => |v| v.readonly,
        .hbox => |h| h.readonly,
        .box => |b| b.readonly,
        .scroll => |s| s.readonly,
        .overlay => |o| o.readonly,
        .text => |t| t.readonly,
        .styled_text => |t| t.readonly,
        .input => |i| i.readonly,
        .textarea => |t| t.readonly,
        .list => |l| l.readonly,
    };
}

fn nodeValidation(node: protocol.Node) protocol.ValidationState {
    return switch (node) {
        .vbox => |v| v.validation,
        .hbox => |h| h.validation,
        .box => |b| b.validation,
        .scroll => |s| s.validation,
        .overlay => |o| o.validation,
        .text => |t| t.validation,
        .styled_text => |t| t.validation,
        .input => |i| i.validation,
        .textarea => |t| t.validation,
        .list => |l| l.validation,
    };
}

fn applyStateOverlays(base: style.Style, node: protocol.Node, state: RenderState) style.Style {
    var out = base;

    const v = nodeValidation(node);
    out = switch (v) {
        .none => out,
        .@"error" => applyOverlay(out, default_theme.validation_error_overlay),
        .warning => applyOverlay(out, default_theme.validation_warning_overlay),
        .success => applyOverlay(out, default_theme.validation_success_overlay),
    };

    if (nodeDisabled(node)) out = applyOverlay(out, default_theme.disabled_overlay);
    if (nodeReadonly(node)) out = applyOverlay(out, default_theme.readonly_overlay);

    const id = nodeId(node);
    if (state.hovered_id != null and std.mem.eql(u8, state.hovered_id.?, id)) {
        // For lists, prefer highlighting the hovered row (via `hovered_item`) rather than
        // painting the whole list rect.
        const is_list = switch (node) {
            .list => true,
            else => false,
        };
        if (!is_list) {
            out = applyOverlay(out, default_theme.hovered_overlay);
        }
    }
    if (state.focused_id != null and std.mem.eql(u8, state.focused_id.?, id)) {
        out = applyOverlay(out, default_theme.focused_overlay);
    }
    if (state.active_id != null and std.mem.eql(u8, state.active_id.?, id)) {
        out = applyOverlay(out, default_theme.active_overlay);
    }

    return out;
}

fn nodeStyleOverride(node: protocol.Node) ?style.StyleOverride {
    return switch (node) {
        .vbox => |v| v.style,
        .hbox => |h| h.style,
        .box => |b| b.style,
        .scroll => |s| s.style,
        .overlay => |o| o.style,
        .text => |t| t.style,
        .styled_text => |t| t.style,
        .input => |i| i.style,
        .textarea => |t| t.style,
        .list => |l| l.style,
    };
}

fn shadowRect(frame: *Frame, rect: RectI, clip: RectI) void {
    var r = rectIntersect(rect, clip);
    r = rectIntersect(r, screenRect(frame));
    if (r.w == 0 or r.h == 0) return;
    if (r.x < 0 or r.y < 0) return;

    const y0: usize = @as(usize, @intCast(r.y));
    const x0: usize = @as(usize, @intCast(r.x));
    const y_end: usize = y0 + r.h;
    const x_end: usize = x0 + r.w;

    var y: usize = y0;
    while (y < y_end) : (y += 1) {
        var x: usize = x0;
        while (x < x_end) : (x += 1) {
            const st = frame.rowSlice(y)[x].style;
            var next = st;
            next.attrs |= style.ATTR_DIM;
            frame.putGraphemeStyled(y, x, "", 1, next);
        }
    }
}

fn fillRectStyle(frame: *Frame, rect: RectI, clip: RectI, st: style.PackedStyle) void {
    var r = rectIntersect(rect, clip);
    r = rectIntersect(r, screenRect(frame));
    if (r.w == 0 or r.h == 0) return;

    const y0: usize = @as(usize, @intCast(r.y));
    const x0: usize = @as(usize, @intCast(r.x));
    const y_end: usize = y0 + r.h;
    const x_end: usize = x0 + r.w;

    var y: usize = y0;
    while (y < y_end) : (y += 1) {
        var x: usize = x0;
        while (x < x_end) : (x += 1) {
            frame.putGraphemeStyled(y, x, "", 1, st);
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
        const full_fits: bool = visible_cols != 0 and unicode.displayWidth(st.value) <= visible_cols;
        if (visible_cols == 0 or full_fits) start = 0;

        const end: usize = unicode.sliceEndByWidth(st.value, start, visible_cols);
        const visible = if (start < end) st.value[start..end] else "";

        const pad_left: usize = if (st.scroll_x == 0 and start == 0 and full_fits)
            hAlignOffset(visible_cols, unicode.displayWidth(visible), i.content_align)
        else
            0;

        if (focused and cursor_out.* == null and cols != 0) {
            const cursor_cols: usize = if (effective_cursor <= start) 0 else unicode.displayWidth(st.value[start..effective_cursor]);
            var col_abs: isize = rect.x + @as(isize, @intCast(prefix_cols + pad_left + cursor_cols));
            const rect_x2: isize = rect.x + @as(isize, @intCast(cols));
            if (col_abs >= rect_x2 and cols != 0) col_abs = rect_x2 - 1;
            if (row >= clip.y and row < clip.y + @as(isize, @intCast(clip.h)) and col_abs >= clip.x and col_abs < clip.x + @as(isize, @intCast(clip.w)) and row >= 0 and col_abs >= 0) {
                cursor_out.* = .{
                    .row = @as(usize, @intCast(row + 1)),
                    .col = @as(usize, @intCast(col_abs + 1)),
                };
            }
        }

        renderLinePiecesInRectStyled(frame, row, rect, clip, &.{prefix}, &.{base_packed});
        if (visible_cols != 0) {
            const col_abs: isize = rect.x + @as(isize, @intCast(prefix_cols + pad_left));
            const max_w: usize = if (visible_cols > pad_left) visible_cols - pad_left else 0;
            drawInlineTextAt(frame, row, col_abs, clip, visible, max_w, base_packed);
        }
        return;
    }

    if (i.placeholder) |ph| {
        const ph_cols: usize = unicode.displayWidth(ph);
        if (focused) {
            if (cursor_out.* == null and cols != 0) {
                const content_cols: usize = ph_cols;
                const pad_left: usize = if (st.scroll_x == 0 and visible_cols != 0 and content_cols <= visible_cols)
                    hAlignOffset(visible_cols, content_cols, i.content_align)
                else
                    0;
                const col_abs: isize = rect.x + @as(isize, @intCast(prefix_cols + pad_left));
                if (row >= clip.y and row < clip.y + @as(isize, @intCast(clip.h)) and col_abs >= clip.x and col_abs < clip.x + @as(isize, @intCast(clip.w)) and row >= 0 and col_abs >= 0) {
                    cursor_out.* = .{
                        .row = @as(usize, @intCast(row + 1)),
                        .col = @as(usize, @intCast(col_abs + 1)),
                    };
                }
            }
            renderLinePiecesInRectStyled(frame, row, rect, clip, &.{prefix}, &.{base_packed});
            if (visible_cols != 0) {
                const content_cols: usize = ph_cols;
                const pad_left: usize = if (st.scroll_x == 0 and content_cols <= visible_cols)
                    hAlignOffset(visible_cols, content_cols, i.content_align)
                else
                    0;
                const col_abs: isize = rect.x + @as(isize, @intCast(prefix_cols + pad_left));
                const max_w: usize = if (visible_cols > pad_left) visible_cols - pad_left else 0;
                drawInlineTextAt(frame, row, col_abs, clip, ph, max_w, ph_packed);
            }
        } else {
            renderLinePiecesInRectStyled(frame, row, rect, clip, &.{prefix}, &.{base_packed});
            if (visible_cols != 0) {
                const content_cols: usize = 2 + ph_cols;
                const pad_left: usize = if (st.scroll_x == 0 and content_cols <= visible_cols)
                    hAlignOffset(visible_cols, content_cols, i.content_align)
                else
                    0;
                const col_abs: isize = rect.x + @as(isize, @intCast(prefix_cols + pad_left));
                const max_w: usize = if (visible_cols > pad_left) visible_cols - pad_left else 0;
                const one: u2 = 1;
                render_text.putGraphemeClipped(frame, row, col_abs, "[", one, clip, base_packed);
                drawInlineTextAt(frame, row, col_abs + 1, clip, ph, if (max_w > 1) max_w - 1 else 0, ph_packed);
                render_text.putGraphemeClipped(frame, row, col_abs + 1 + @as(isize, @intCast(ph_cols)), "]", one, clip, base_packed);
            }
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

fn paintTextarea(
    frame: *Frame,
    rect: RectI,
    clip: RectI,
    state: RenderState,
    cursor_out: *?CursorPos,
    t: protocol.TextareaNode,
    inherited: style.Style,
) void {
    if (rect.w == 0 or rect.h == 0) return;

    const focused = state.focused_id != null and std.mem.eql(u8, state.focused_id.?, t.id);
    const textarea_state = findTextareaState(state.textareas, t.id);

    const base_style = inherited;
    const base_packed = style.pack(base_style);
    const ph_style = style.merge(base_style, t.placeholder_style);
    const ph_packed = style.pack(ph_style);

    const value: []const u8 = if (textarea_state) |st| st.value else "";
    const effective_cursor: usize = unicode.clampGraphemeBoundary(
        value,
        @min(if (textarea_state) |st| st.cursor else 0, value.len),
    );
    const scroll_y: usize = if (textarea_state) |st| st.scroll_y else 0;

    if (value.len == 0 and t.placeholder != null) {
        if (focused and cursor_out.* == null) {
            const row: isize = rect.y;
            const col_abs: isize = rect.x;
            if (row >= clip.y and row < clip.y + @as(isize, @intCast(clip.h)) and col_abs >= clip.x and col_abs < clip.x + @as(isize, @intCast(clip.w)) and row >= 0 and col_abs >= 0) {
                cursor_out.* = .{
                    .row = @as(usize, @intCast(row + 1)),
                    .col = @as(usize, @intCast(col_abs + 1)),
                };
            }
        }
        render_text.drawWrappedTextInRectAligned(frame, rect, clip, t.placeholder.?, ph_packed, .left, .top);
        return;
    }

    const cols: usize = rect.w;
    const rows: usize = rect.h;

    var byte_idx: usize = 0;
    var vis_y: usize = 0;
    var vis_x: usize = 0;

    var cursor_vis_y: usize = 0;
    var cursor_vis_x: usize = 0;
    var cursor_found: bool = false;

    if (effective_cursor == 0) {
        cursor_vis_y = 0;
        cursor_vis_x = 0;
        cursor_found = true;
    }

    while (byte_idx < value.len) {
        if (!cursor_found and byte_idx == effective_cursor) {
            cursor_vis_y = vis_y;
            cursor_vis_x = vis_x;
            cursor_found = true;
        }

        const g = unicode.nextGrapheme(value, byte_idx);
        if (g.end <= byte_idx) break;

        const b0: u8 = value[g.start];
        if (b0 == '\r') {
            byte_idx = g.end;
            continue;
        }
        if (b0 == '\n') {
            vis_y += 1;
            vis_x = 0;
            byte_idx = g.end;
            continue;
        }

        var glyph: []const u8 = value[g.start..g.end];
        var width: usize = g.width;
        if (b0 == '\t') {
            glyph = " ";
            width = 1;
        }

        if (width == 0) {
            byte_idx = g.end;
            continue;
        }

        if (cols == 0) {
            byte_idx = g.end;
            continue;
        }

        if (width > cols) {
            byte_idx = g.end;
            continue;
        }

        if (vis_x + width > cols) {
            vis_y += 1;
            vis_x = 0;
            continue;
        }

        if (vis_y >= scroll_y and vis_y < scroll_y + rows) {
            const row: isize = rect.y + @as(isize, @intCast(vis_y - scroll_y));
            const col_abs: isize = rect.x + @as(isize, @intCast(vis_x));
            render_text.putGraphemeClipped(
                frame,
                row,
                col_abs,
                glyph,
                @as(u2, @intCast(width)),
                clip,
                base_packed,
            );
        }

        vis_x += width;
        byte_idx = g.end;
    }

    if (!cursor_found) {
        cursor_vis_y = vis_y;
        cursor_vis_x = vis_x;
        cursor_found = true;
    }

    if (focused and cursor_out.* == null and cols != 0) {
        if (cursor_vis_y >= scroll_y and cursor_vis_y < scroll_y + rows) {
            const row: isize = rect.y + @as(isize, @intCast(cursor_vis_y - scroll_y));
            var col_abs: isize = rect.x + @as(isize, @intCast(cursor_vis_x));
            const rect_x2: isize = rect.x + @as(isize, @intCast(cols));
            if (col_abs >= rect_x2) col_abs = rect_x2 - 1;

            if (row >= clip.y and row < clip.y + @as(isize, @intCast(clip.h)) and col_abs >= clip.x and col_abs < clip.x + @as(isize, @intCast(clip.w)) and row >= 0 and col_abs >= 0) {
                cursor_out.* = .{
                    .row = @as(usize, @intCast(row + 1)),
                    .col = @as(usize, @intCast(col_abs + 1)),
                };
            }
        }
    }
}

fn paintList(frame: *Frame, rect: RectI, clip: RectI, state: RenderState, l: protocol.ListNode, inherited: style.Style) void {
    if (rect.h == 0) return;
    const focused = state.focused_id != null and std.mem.eql(u8, state.focused_id.?, l.id);
    const list_state = findListState(state.lists, l.id);
    const selected_id = if (list_state) |st| st.selected_id else "";
    const scroll = if (list_state) |st| st.scroll else 0;
    const hovered_item = if (state.hovered_id != null and std.mem.eql(u8, state.hovered_id.?, l.id)) state.hovered_item else null;

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
        const is_hovered = hovered_item != null and std.mem.eql(u8, hovered_item.?, item_id);

        const prefix = switch (l.marker) {
            .none => "",
            .default => if (is_selected) (if (focused) "> " else "* ") else "  ",
        };
        var item_style = style.merge(list_style, nodeStyleOverride(item));
        if (is_hovered and !is_selected) item_style = applyOverlay(item_style, default_theme.hovered_overlay);
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

    const count: usize = v.children.len;
    if (count == 0) return;

    const gaps_total: usize = if (count > 1) v.gap * (count - 1) else 0;

    var fixed_sum: usize = gaps_total;
    var total_flex: usize = 0;
    if (mode == .bounded) {
        for (v.children) |child| {
            if (nodeHintH(child)) |h| {
                fixed_sum += h;
            } else if (nodeFlex(child) > 0) {
                total_flex += nodeFlex(child);
            } else {
                const child_w = vboxChildWidth(inner.w, v.align_items, child);
                fixed_sum += measureHeight(child, child_w);
            }
        }
    }

    const remaining_for_flex: usize = if (mode == .bounded and inner.h > fixed_sum) inner.h - fixed_sum else 0;
    const extra_space: usize = if (mode == .bounded and total_flex == 0) remaining_for_flex else 0;

    var y: isize = inner.y + @as(isize, @intCast(justifyStartOffset(v.justify_content, count, extra_space)));
    var carry: u128 = 0;

    for (v.children, 0..) |child, idx| {
        if (y >= y_end) break;
        if (child_clip.h != 0 and y >= clip_y_end) break;

        const eff_align = alignItemsEffective(child, v.align_items);
        const child_w = vboxChildWidth(inner.w, v.align_items, child);
        const child_x = vboxChildX(inner.x, inner.w, child_w, eff_align);

        const child_h: usize = blk: {
            if (nodeHintH(child)) |h| break :blk h;
            if (mode == .bounded and nodeFlex(child) > 0 and total_flex > 0) {
                const numer: u128 = @as(u128, remaining_for_flex) * @as(u128, nodeFlex(child)) + carry;
                const share: usize = @as(usize, @intCast(numer / @as(u128, total_flex)));
                carry = numer % @as(u128, total_flex);
                break :blk share;
            }
            break :blk measureHeight(child, child_w);
        };

        const child_y2: isize = y + @as(isize, @intCast(child_h));
        const clamped_h: usize = if (child_y2 <= y_end) child_h else if (y_end > y) @as(usize, @intCast(y_end - y)) else 0;
        if (clamped_h == 0) break;

        const child_rect: RectI = .{ .x = child_x, .y = y, .w = child_w, .h = clamped_h };
        const rect_y2: isize = child_rect.y + @as(isize, @intCast(child_rect.h));

        if (child_clip.h != 0 and rect_y2 <= child_clip.y) {
            y += @as(isize, @intCast(clamped_h));
            continue;
        }

        paintNode(frame, child, child_rect, child_clip, state, cursor_out, inherited, mode);
        y += @as(isize, @intCast(clamped_h));

        if (idx + 1 < count) {
            const gap = v.gap + justifyGapExtra(v.justify_content, count, extra_space, idx);
            y += @as(isize, @intCast(gap));
        }
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

    const count: usize = h.children.len;
    if (count == 0) return;

    const gaps_total: usize = if (count > 1) h.gap * (count - 1) else 0;

    var fixed_sum: usize = gaps_total;
    var total_flex: usize = 0;

    for (h.children) |child| {
        if (nodeHintW(child)) |w| {
            fixed_sum += w;
        } else if (nodeFlex(child) > 0) {
            total_flex += nodeFlex(child);
        }
    }

    const remaining_for_flex: usize = if (inner.w > fixed_sum) inner.w - fixed_sum else 0;
    const extra_space: usize = if (mode == .bounded and total_flex == 0) remaining_for_flex else 0;

    var x: isize = inner.x + @as(isize, @intCast(justifyStartOffset(h.justify_content, count, extra_space)));
    var carry: u128 = 0;

    const x_end: isize = inner.x + @as(isize, @intCast(inner.w));
    for (h.children, 0..) |child, idx| {
        if (x >= x_end) break;

        const child_w: usize = if (nodeHintW(child)) |w| w else if (nodeFlex(child) > 0 and total_flex > 0) blk: {
            const numer: u128 = @as(u128, remaining_for_flex) * @as(u128, nodeFlex(child)) + carry;
            const share: usize = @as(usize, @intCast(numer / @as(u128, total_flex)));
            carry = numer % @as(u128, total_flex);
            break :blk share;
        } else 0;

        const child_x2: isize = x + @as(isize, @intCast(child_w));
        const clamped_w: usize = if (child_x2 <= x_end) child_w else if (x_end > x) @as(usize, @intCast(x_end - x)) else 0;
        if (clamped_w == 0) break;

        const eff_align = alignItemsEffective(child, h.align_items);
        const child_h = hboxChildHeight(inner.h, h.align_items, child);
        const child_y = hboxChildY(inner.y, inner.h, child_h, eff_align);

        const child_rect: RectI = .{ .x = x, .y = child_y, .w = clamped_w, .h = child_h };
        paintNode(frame, child, child_rect, child_clip, state, cursor_out, inherited, mode);
        x += @as(isize, @intCast(clamped_w));

        if (idx + 1 < count) {
            const gap = h.gap + justifyGapExtra(h.justify_content, count, extra_space, idx);
            x += @as(isize, @intCast(gap));
        }
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
    const base_resolved = style.merge(inherited, own_override);
    const resolved = applyStateOverlays(base_resolved, node, state);
    const inherited_packed = style.pack(inherited);
    const resolved_packed = style.pack(resolved);
    if (!packedEq(resolved_packed, inherited_packed) and resolved_packed.affectsBlank()) {
        fillRectStyle(frame, rect, node_clip, resolved_packed);
    }

    switch (node) {
        .text => |t| render_text.drawWrappedTextInRectAligned(frame, rect, node_clip, t.text, resolved_packed, t.ext_align, t.v_align),
        .styled_text => |t| render_text.drawWrappedStyledSpansInRectAligned(frame, rect, node_clip, t.spans, resolved, 0, t.ext_align, t.v_align),
        .input => |i| paintInput(frame, rect, node_clip, state, cursor_out, i, resolved),
        .textarea => |t| paintTextarea(frame, rect, node_clip, state, cursor_out, t, resolved),
        .list => |l| paintList(frame, rect, node_clip, state, l, resolved),
        .vbox => |v| paintVBox(frame, rect, node_clip, state, cursor_out, v, resolved, mode),
        .hbox => |h| paintHBox(frame, rect, node_clip, state, cursor_out, h, resolved, mode),
        .box => |b| paintBox(frame, rect, clip, state, cursor_out, b, resolved, mode),
        .scroll => |s| paintScroll(frame, rect, node_clip, state, cursor_out, s, resolved),
        .overlay => |o| paintOverlay(frame, rect, node_clip, state, cursor_out, o, resolved, mode),
    }
}

fn paintBox(
    frame: *Frame,
    rect: RectI,
    parent_clip: RectI,
    state: RenderState,
    cursor_out: *?CursorPos,
    b: protocol.BoxNode,
    inherited: style.Style,
    mode: VBoxMode,
) void {
    const node_clip = rectIntersect(parent_clip, rect);
    if (node_clip.w == 0 or node_clip.h == 0) return;

    const border_thickness: usize = if (b.border and rect.w >= 2 and rect.h >= 2) 1 else 0;
    const chrome: usize = border_thickness + b.pad;

    const inner = rectDeflate(rect, chrome);
    const base_clip = node_clip;
    const child_clip = if (b.clip) rectIntersect(base_clip, inner) else base_clip;

    if (inner.w != 0 and inner.h != 0) {
        paintNode(frame, b.child.*, inner, child_clip, state, cursor_out, inherited, mode);
    }

    const resolved_packed = style.pack(inherited);

    if (border_thickness == 1) {
        const x0: isize = rect.x;
        const y0: isize = rect.y;
        const x1: isize = rect.x + @as(isize, @intCast(rect.w)) - 1;
        const y1: isize = rect.y + @as(isize, @intCast(rect.h)) - 1;

        const one: u2 = 1;
        render_text.putGraphemeClipped(frame, y0, x0, "┌", one, node_clip, resolved_packed);
        render_text.putGraphemeClipped(frame, y0, x1, "┐", one, node_clip, resolved_packed);
        render_text.putGraphemeClipped(frame, y1, x0, "└", one, node_clip, resolved_packed);
        render_text.putGraphemeClipped(frame, y1, x1, "┘", one, node_clip, resolved_packed);

        var x: isize = x0 + 1;
        while (x < x1) : (x += 1) {
            render_text.putGraphemeClipped(frame, y0, x, "─", one, node_clip, resolved_packed);
            render_text.putGraphemeClipped(frame, y1, x, "─", one, node_clip, resolved_packed);
        }

        var y: isize = y0 + 1;
        while (y < y1) : (y += 1) {
            render_text.putGraphemeClipped(frame, y, x0, "│", one, node_clip, resolved_packed);
            render_text.putGraphemeClipped(frame, y, x1, "│", one, node_clip, resolved_packed);
        }

        if (b.title) |title| {
            if (title.len != 0 and rect.w > 2) {
                const title_rect: RectI = .{ .x = x0 + 1, .y = y0, .w = rect.w - 2, .h = 1 };
                const pieces = [_][]const u8{ " ", title, " " };
                const styles = [_]style.PackedStyle{ resolved_packed, resolved_packed, resolved_packed };
                renderLinePiecesInRectStyled(frame, y0, title_rect, node_clip, pieces[0..], styles[0..]);
            }
        }
    }

    if (b.shadow and rect.w != 0 and rect.h != 0) {
        const right_x: isize = rect.x + @as(isize, @intCast(rect.w));
        const bottom_y: isize = rect.y + @as(isize, @intCast(rect.h));

        if (rect.h > 1) {
            const right_shadow: RectI = .{
                .x = right_x,
                .y = rect.y + 1,
                .w = 1,
                .h = rect.h - 1,
            };
            shadowRect(frame, right_shadow, parent_clip);
        }

        const bottom_shadow: RectI = .{
            .x = rect.x + 1,
            .y = bottom_y,
            .w = rect.w,
            .h = 1,
        };
        shadowRect(frame, bottom_shadow, parent_clip);
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
    const max_layer_rects: usize = 32;
    var computed_layer_rects: [max_layer_rects]RectI = undefined;

    var i: usize = 0;
    while (i < o.layers.len and i < max_layer_rects) : (i += 1) {
        const layer = o.layers[i];
        const layer_rect = computeOverlayLayerRectForBaseRect(
            screen,
            rect,
            inner,
            o.base.*,
            o.layers[0..i],
            computed_layer_rects[0..i],
            layer,
            state.scrolls,
            mode,
        );
        computed_layer_rects[i] = layer_rect;
        const layer_clip = screen;
        paintNode(frame, layer.node.*, layer_rect, layer_clip, state, cursor_out, inherited, .bounded);
    }

    // Fallback for rare cases with many layers: compute rects without cross-layer anchors.
    while (i < o.layers.len) : (i += 1) {
        const layer = o.layers[i];
        const layer_rect = computeOverlayLayerRectForBaseRect(
            screen,
            rect,
            inner,
            o.base.*,
            &.{},
            &.{},
            layer,
            state.scrolls,
            mode,
        );
        const layer_clip = screen;
        paintNode(frame, layer.node.*, layer_rect, layer_clip, state, cursor_out, inherited, .bounded);
    }
}

fn computeOverlayLayerRectForBaseRect(
    screen: RectI,
    overlay_rect: RectI,
    base_rect: RectI,
    base: protocol.Node,
    prev_layers: []const protocol.OverlayLayer,
    prev_layer_rects: []const RectI,
    layer: protocol.OverlayLayer,
    scrolls: []const ScrollState,
    mode: VBoxMode,
) RectI {
    const anchor_rect: RectI = blk: {
        if (layer.anchor) |aid| {
            if (findRectInNodeIBaseOnly(base, base_rect, aid, scrolls, mode)) |r| break :blk r;
            var i: usize = 0;
            while (i < prev_layers.len and i < prev_layer_rects.len) : (i += 1) {
                if (findRectInNodeIBaseOnly(prev_layers[i].node.*, prev_layer_rects[i], aid, scrolls, .bounded)) |r| break :blk r;
            }
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

fn findTextareaState(textareas: []const TextareaState, id: []const u8) ?TextareaState {
    var lo: usize = 0;
    var hi: usize = textareas.len;
    while (lo < hi) {
        const mid: usize = lo + (hi - lo) / 2;
        const st = textareas[mid];
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

            const count: usize = v.children.len;
            if (count == 0) return null;

            const gaps_total: usize = if (count > 1) v.gap * (count - 1) else 0;

            var fixed_sum: usize = gaps_total;
            var total_flex: usize = 0;
            if (mode == .bounded) {
                for (v.children) |child| {
                    if (nodeHintH(child)) |h| {
                        fixed_sum += h;
                    } else if (nodeFlex(child) > 0) {
                        total_flex += nodeFlex(child);
                    } else {
                        const child_w = vboxChildWidth(inner.w, v.align_items, child);
                        fixed_sum += measureHeight(child, child_w);
                    }
                }
            }

            const remaining_for_flex: usize = if (mode == .bounded and inner.h > fixed_sum) inner.h - fixed_sum else 0;
            const extra_space: usize = if (mode == .bounded and total_flex == 0) remaining_for_flex else 0;

            var y: isize = inner.y + @as(isize, @intCast(justifyStartOffset(v.justify_content, count, extra_space)));
            var carry: u128 = 0;

            for (v.children, 0..) |child, idx| {
                if (y >= y_end) break;

                const eff_align = alignItemsEffective(child, v.align_items);
                const child_w = vboxChildWidth(inner.w, v.align_items, child);
                const child_x = vboxChildX(inner.x, inner.w, child_w, eff_align);

                const child_h: usize = blk: {
                    if (nodeHintH(child)) |h| break :blk h;
                    if (mode == .bounded and nodeFlex(child) > 0 and total_flex > 0) {
                        const numer: u128 = @as(u128, remaining_for_flex) * @as(u128, nodeFlex(child)) + carry;
                        const share: usize = @as(usize, @intCast(numer / @as(u128, total_flex)));
                        carry = numer % @as(u128, total_flex);
                        break :blk share;
                    }
                    break :blk measureHeight(child, child_w);
                };

                const child_y2: isize = y + @as(isize, @intCast(child_h));
                const clamped_h: usize = if (child_y2 <= y_end) child_h else if (y_end > y) @as(usize, @intCast(y_end - y)) else 0;
                if (clamped_h == 0) break;

                const child_rect: RectI = .{ .x = child_x, .y = y, .w = child_w, .h = clamped_h };
                if (findRectInNodeI(child, child_rect, id, scrolls, mode, screen)) |r| return r;
                y += @as(isize, @intCast(clamped_h));

                if (idx + 1 < count) {
                    const gap = v.gap + justifyGapExtra(v.justify_content, count, extra_space, idx);
                    y += @as(isize, @intCast(gap));
                }
            }
            return null;
        },
        .hbox => |h| {
            const inner = rectDeflate(rect, h.pad);
            const x_end: isize = inner.x + @as(isize, @intCast(inner.w));

            const count: usize = h.children.len;
            if (count == 0) return null;

            const gaps_total: usize = if (count > 1) h.gap * (count - 1) else 0;

            var fixed_sum: usize = gaps_total;
            var total_flex: usize = 0;

            for (h.children) |child| {
                if (nodeHintW(child)) |w| {
                    fixed_sum += w;
                } else if (nodeFlex(child) > 0) {
                    total_flex += nodeFlex(child);
                }
            }

            const remaining_for_flex: usize = if (inner.w > fixed_sum) inner.w - fixed_sum else 0;
            const extra_space: usize = if (mode == .bounded and total_flex == 0) remaining_for_flex else 0;

            var x: isize = inner.x + @as(isize, @intCast(justifyStartOffset(h.justify_content, count, extra_space)));
            var carry: u128 = 0;

            for (h.children, 0..) |child, idx| {
                if (x >= x_end) break;

                const child_w: usize = if (nodeHintW(child)) |w| w else if (nodeFlex(child) > 0 and total_flex > 0) blk: {
                    const numer: u128 = @as(u128, remaining_for_flex) * @as(u128, nodeFlex(child)) + carry;
                    const share: usize = @as(usize, @intCast(numer / @as(u128, total_flex)));
                    carry = numer % @as(u128, total_flex);
                    break :blk share;
                } else 0;

                const child_x2: isize = x + @as(isize, @intCast(child_w));
                const clamped_w: usize = if (child_x2 <= x_end) child_w else if (x_end > x) @as(usize, @intCast(x_end - x)) else 0;
                if (clamped_w == 0) break;

                const eff_align = alignItemsEffective(child, h.align_items);
                const child_h = hboxChildHeight(inner.h, h.align_items, child);
                const child_y = hboxChildY(inner.y, inner.h, child_h, eff_align);

                const child_rect: RectI = .{ .x = x, .y = child_y, .w = clamped_w, .h = child_h };
                if (findRectInNodeI(child, child_rect, id, scrolls, mode, screen)) |r| return r;
                x += @as(isize, @intCast(clamped_w));

                if (idx + 1 < count) {
                    const gap = h.gap + justifyGapExtra(h.justify_content, count, extra_space, idx);
                    x += @as(isize, @intCast(gap));
                }
            }
            return null;
        },
        .box => |b| {
            const border_thickness: usize = if (b.border and rect.w >= 2 and rect.h >= 2) 1 else 0;
            const chrome: usize = border_thickness + b.pad;
            const inner = rectDeflate(rect, chrome);
            return findRectInNodeI(b.child.*, inner, id, scrolls, mode, screen);
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

            const max_layer_rects: usize = 32;
            var computed_layer_rects: [max_layer_rects]RectI = undefined;

            var i: usize = 0;
            while (i < o.layers.len and i < max_layer_rects) : (i += 1) {
                const layer = o.layers[i];
                const layer_rect = computeOverlayLayerRectForBaseRect(
                    screen,
                    rect,
                    inner,
                    o.base.*,
                    o.layers[0..i],
                    computed_layer_rects[0..i],
                    layer,
                    scrolls,
                    mode,
                );
                computed_layer_rects[i] = layer_rect;
                if (findRectInNodeI(layer.node.*, layer_rect, id, scrolls, .bounded, screen)) |r| return r;
            }

            while (i < o.layers.len) : (i += 1) {
                const layer = o.layers[i];
                const layer_rect = computeOverlayLayerRectForBaseRect(
                    screen,
                    rect,
                    inner,
                    o.base.*,
                    &.{},
                    &.{},
                    layer,
                    scrolls,
                    mode,
                );
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

            const count: usize = v.children.len;
            if (count == 0) return null;

            const gaps_total: usize = if (count > 1) v.gap * (count - 1) else 0;

            var fixed_sum: usize = gaps_total;
            var total_flex: usize = 0;
            if (mode == .bounded) {
                for (v.children) |child| {
                    if (nodeHintH(child)) |h| {
                        fixed_sum += h;
                    } else if (nodeFlex(child) > 0) {
                        total_flex += nodeFlex(child);
                    } else {
                        const child_w = vboxChildWidth(inner.w, v.align_items, child);
                        fixed_sum += measureHeight(child, child_w);
                    }
                }
            }

            const remaining_for_flex: usize = if (mode == .bounded and inner.h > fixed_sum) inner.h - fixed_sum else 0;
            const extra_space: usize = if (mode == .bounded and total_flex == 0) remaining_for_flex else 0;

            var y: isize = inner.y + @as(isize, @intCast(justifyStartOffset(v.justify_content, count, extra_space)));
            var carry: u128 = 0;

            for (v.children, 0..) |child, idx| {
                if (y >= y_end) break;

                const eff_align = alignItemsEffective(child, v.align_items);
                const child_w = vboxChildWidth(inner.w, v.align_items, child);
                const child_x = vboxChildX(inner.x, inner.w, child_w, eff_align);

                const child_h: usize = blk: {
                    if (nodeHintH(child)) |h| break :blk h;
                    if (mode == .bounded and nodeFlex(child) > 0 and total_flex > 0) {
                        const numer: u128 = @as(u128, remaining_for_flex) * @as(u128, nodeFlex(child)) + carry;
                        const share: usize = @as(usize, @intCast(numer / @as(u128, total_flex)));
                        carry = numer % @as(u128, total_flex);
                        break :blk share;
                    }
                    break :blk measureHeight(child, child_w);
                };

                const child_y2: isize = y + @as(isize, @intCast(child_h));
                const clamped_h: usize = if (child_y2 <= y_end) child_h else if (y_end > y) @as(usize, @intCast(y_end - y)) else 0;
                if (clamped_h == 0) break;

                const child_rect: RectI = .{ .x = child_x, .y = y, .w = child_w, .h = clamped_h };
                if (findRectInNodeIBaseOnly(child, child_rect, id, scrolls, mode)) |r| return r;
                y += @as(isize, @intCast(clamped_h));

                if (idx + 1 < count) {
                    const gap = v.gap + justifyGapExtra(v.justify_content, count, extra_space, idx);
                    y += @as(isize, @intCast(gap));
                }
            }
            return null;
        },
        .hbox => |h| {
            const inner = rectDeflate(rect, h.pad);
            const x_end: isize = inner.x + @as(isize, @intCast(inner.w));

            const count: usize = h.children.len;
            if (count == 0) return null;

            const gaps_total: usize = if (count > 1) h.gap * (count - 1) else 0;

            var fixed_sum: usize = gaps_total;
            var total_flex: usize = 0;

            for (h.children) |child| {
                if (nodeHintW(child)) |w| {
                    fixed_sum += w;
                } else if (nodeFlex(child) > 0) {
                    total_flex += nodeFlex(child);
                }
            }

            const remaining_for_flex: usize = if (inner.w > fixed_sum) inner.w - fixed_sum else 0;
            const extra_space: usize = if (mode == .bounded and total_flex == 0) remaining_for_flex else 0;

            var x: isize = inner.x + @as(isize, @intCast(justifyStartOffset(h.justify_content, count, extra_space)));
            var carry: u128 = 0;

            for (h.children, 0..) |child, idx| {
                if (x >= x_end) break;

                const child_w: usize = if (nodeHintW(child)) |w| w else if (nodeFlex(child) > 0 and total_flex > 0) blk: {
                    const numer: u128 = @as(u128, remaining_for_flex) * @as(u128, nodeFlex(child)) + carry;
                    const share: usize = @as(usize, @intCast(numer / @as(u128, total_flex)));
                    carry = numer % @as(u128, total_flex);
                    break :blk share;
                } else 0;

                const child_x2: isize = x + @as(isize, @intCast(child_w));
                const clamped_w: usize = if (child_x2 <= x_end) child_w else if (x_end > x) @as(usize, @intCast(x_end - x)) else 0;
                if (clamped_w == 0) break;

                const eff_align = alignItemsEffective(child, h.align_items);
                const child_h = hboxChildHeight(inner.h, h.align_items, child);
                const child_y = hboxChildY(inner.y, inner.h, child_h, eff_align);

                const child_rect: RectI = .{ .x = x, .y = child_y, .w = clamped_w, .h = child_h };
                if (findRectInNodeIBaseOnly(child, child_rect, id, scrolls, mode)) |r| return r;
                x += @as(isize, @intCast(clamped_w));

                if (idx + 1 < count) {
                    const gap = h.gap + justifyGapExtra(h.justify_content, count, extra_space, idx);
                    x += @as(isize, @intCast(gap));
                }
            }
            return null;
        },
        .box => |b| {
            const border_thickness: usize = if (b.border and rect.w >= 2 and rect.h >= 2) 1 else 0;
            const chrome: usize = border_thickness + b.pad;
            const inner = rectDeflate(rect, chrome);
            return findRectInNodeIBaseOnly(b.child.*, inner, id, scrolls, mode);
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

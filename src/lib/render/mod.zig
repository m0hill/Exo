const std = @import("std");
const frame_mod = @import("../frame.zig");
const protocol = @import("../protocol/mod.zig");
const style = @import("../style.zig");
const unicode = @import("../unicode.zig");
const render_text = @import("text.zig");
const theme_mod = @import("theme.zig");
pub const theme_engine = @import("theme_engine.zig");

const Frame = frame_mod.Frame;
const CursorPos = frame_mod.CursorPos;
pub const Theme = theme_mod.Theme;
pub const default_theme = theme_mod.default_theme;
pub const light_theme = theme_mod.light_theme;
pub const ocean_theme = theme_mod.ocean_theme;
pub const themeFromName = theme_mod.themeFromName;
pub const OwnedTheme = theme_mod.OwnedTheme;
pub const buildThemeFromSpec = theme_mod.buildThemeFromSpec;

pub const RenderState = struct {
    theme: *const Theme = &theme_mod.default_theme,
    scrolling: ScrollingRenderConfig = .{},
    focused_id: ?[]const u8 = null,
    hovered_id: ?[]const u8 = null,
    hovered_item: ?[]const u8 = null,
    active_id: ?[]const u8 = null,
    inputs: []const InputState = &.{},
    textareas: []const TextareaState = &.{},
    lists: []const ListState = &.{},
    vlists: []const VListState = &.{},
    scrolls: []const ScrollState = &.{},
};

pub const ScrollingRenderConfig = struct {
    scrollbars_enabled: bool = true,
    scrollbar_min_thumb: usize = 1,
};

pub const InputState = struct {
    id: []const u8,
    value: []const u8,
    cursor: usize,
    scroll_x: usize,
    selection_start: ?usize = null,
    selection_end: ?usize = null,
};

pub const TextareaState = struct {
    id: []const u8,
    value: []const u8,
    cursor: usize,
    scroll_y: usize,
    selection_start: ?usize = null,
    selection_end: ?usize = null,
};

pub const ListState = struct {
    id: []const u8,
    selected_id: []const u8,
    scroll: usize,
};

pub const VListState = struct {
    id: []const u8,
    selected_index: ?usize = null,
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

const CachedRect = struct {
    found: bool,
    rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
};

pub const LayoutCache = struct {
    allocator: std.mem.Allocator,
    root: ?*const protocol.Node = null,
    rows: usize = 0,
    cols: usize = 0,
    scrolls: []const ScrollState = &.{},
    rects: std.StringHashMap(CachedRect),

    pub fn init(allocator: std.mem.Allocator) LayoutCache {
        return .{
            .allocator = allocator,
            .rects = std.StringHashMap(CachedRect).init(allocator),
        };
    }

    pub fn deinit(self: *LayoutCache) void {
        self.clear();
        self.rects.deinit();
    }

    pub fn clear(self: *LayoutCache) void {
        var it = self.rects.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.rects.clearRetainingCapacity();
    }

    pub fn reset(
        self: *LayoutCache,
        root: *const protocol.Node,
        rows: usize,
        cols: usize,
        scrolls: []const ScrollState,
    ) void {
        self.clear();
        self.root = root;
        self.rows = rows;
        self.cols = cols;
        self.scrolls = scrolls;
    }

    pub fn findRect(self: *LayoutCache, id: []const u8) ?Rect {
        const root = self.root orelse return null;
        if (self.rects.get(id)) |cached| {
            return if (cached.found) cached.rect else null;
        }

        const resolved = findRectForIdWithScrolls(root.*, self.rows, self.cols, id, self.scrolls);
        const key = self.allocator.dupe(u8, id) catch return resolved;
        self.rects.put(key, .{
            .found = resolved != null,
            .rect = resolved orelse .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        }) catch {
            self.allocator.free(key);
        };
        return resolved;
    }
};

const RectI = struct {
    x: isize,
    y: isize,
    w: usize,
    h: usize,
};

pub const ScrollbarGeometry = struct {
    thumb_top: usize,
    thumb_h: usize,
};

pub fn computeScrollbar(
    track_h: usize,
    content_h: usize,
    viewport_h: usize,
    scroll_y: usize,
    min_thumb: usize,
) ScrollbarGeometry {
    if (track_h == 0 or content_h == 0 or viewport_h == 0) {
        return .{ .thumb_top = 0, .thumb_h = 0 };
    }
    const min_t = @max(@as(usize, 1), @min(min_thumb, track_h));
    var thumb_h = @max(min_t, (viewport_h * track_h) / content_h);
    if (thumb_h > track_h) thumb_h = track_h;
    const denom = if (content_h > viewport_h) content_h - viewport_h else 0;
    const max_top = track_h - thumb_h;
    const thumb_top = if (denom == 0) 0 else @min(max_top, (scroll_y * max_top) / denom);
    return .{ .thumb_top = thumb_top, .thumb_h = thumb_h };
}

const VBoxMode = enum {
    bounded,
    unbounded,
};

const GridPlacement = struct {
    row: usize,
    col: usize,
    row_span: usize,
    col_span: usize,
};

const max_grid_tracks: usize = 128;
const max_layout_children: usize = 1024;

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
        .grid => |g| g.align_self,
        .box => |b| b.align_self,
        .scroll => |s| s.align_self,
        .overlay => |o| o.align_self,
        .text => |t| t.align_self,
        .styled_text => |t| t.align_self,
        .input => |i| i.align_self,
        .textarea => |t| t.align_self,
        .list => |l| l.align_self,
        .vlist => |l| l.align_self,
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
    const min_w = nodeMinW(child);
    const max_w = nodeMaxW(child);
    const hinted = applyMinMax(computeHintW(child, inner_w), min_w, max_w);
    var width: usize = if (hinted) |h| h else if (eff == .stretch) inner_w else @min(measureMinWidth(child), inner_w);
    width = clampSize(width, min_w, max_w);
    if (width > inner_w) return inner_w;
    return width;
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
    const min_h = nodeMinH(child);
    const max_h = nodeMaxH(child);
    const hinted = applyMinMax(computeHintH(child, inner_h), min_h, max_h);
    var height: usize = if (eff == .stretch) inner_h else hinted orelse inner_h;
    height = clampSize(height, min_h, max_h);
    if (height > inner_h) return inner_h;
    return height;
}

fn hboxChildY(inner_y: isize, inner_h: usize, child_h: usize, align_mode: protocol.AlignItems) isize {
    const dy: isize = @as(isize, @intCast(if (inner_h > child_h) inner_h - child_h else 0));
    return switch (align_mode) {
        .stretch, .start => inner_y,
        .center => inner_y + @divTrunc(dy, 2),
        .end => inner_y + dy,
    };
}

fn singleChildWidthHint(parent_inner_w: usize, child: protocol.Node) usize {
    const hinted = applyMinMax(computeHintW(child, parent_inner_w), nodeMinW(child), nodeMaxW(child)) orelse parent_inner_w;
    if (hinted > parent_inner_w) return parent_inner_w;
    return hinted;
}

fn singleChildHeightHint(parent_inner_h: usize, child: protocol.Node) usize {
    const hinted = applyMinMax(computeHintH(child, parent_inner_h), nodeMinH(child), nodeMaxH(child)) orelse parent_inner_h;
    if (hinted > parent_inner_h) return parent_inner_h;
    return hinted;
}

fn computeVBoxHeights(
    children: []const protocol.Node,
    parent_inner_h: usize,
    gap: usize,
    mode: VBoxMode,
    child_widths: []const usize,
    out: []usize,
) ?usize {
    const count = children.len;
    if (child_widths.len < count or out.len < count) return null;
    if (count == 0) return 0;
    if (count > max_layout_children) return null;

    if (mode == .unbounded) {
        for (children, 0..) |child, idx| {
            const min_h = nodeMinH(child);
            const max_h = nodeMaxH(child);
            var h = applyMinMax(nodeHintH(child), min_h, max_h) orelse measureHeight(child, child_widths[idx]);
            h = clampSize(h, min_h, max_h);
            if (h > parent_inner_h) h = parent_inner_h;
            out[idx] = h;
        }
        return 0;
    }

    const gaps_total: usize = if (count > 1) gap * (count - 1) else 0;
    var fixed_sum: usize = gaps_total;
    var total_flex: usize = 0;

    for (children, 0..) |child, idx| {
        const hinted_h = applyMinMax(computeHintH(child, parent_inner_h), nodeMinH(child), nodeMaxH(child));
        if (hinted_h) |h| {
            fixed_sum += @min(h, parent_inner_h);
        } else if (nodeFlex(child) > 0) {
            total_flex += nodeFlex(child);
        } else {
            fixed_sum += measureHeight(child, child_widths[idx]);
        }
    }

    const remaining_for_flex: usize = if (parent_inner_h > fixed_sum) parent_inner_h - fixed_sum else 0;
    const extra_space: usize = if (total_flex == 0) remaining_for_flex else 0;
    var carry: u128 = 0;

    for (children, 0..) |child, idx| {
        const min_h = nodeMinH(child);
        const max_h = nodeMaxH(child);
        var h: usize = blk: {
            if (applyMinMax(computeHintH(child, parent_inner_h), min_h, max_h)) |hinted| break :blk hinted;
            if (nodeFlex(child) > 0 and total_flex > 0) {
                const numer: u128 = @as(u128, remaining_for_flex) * @as(u128, nodeFlex(child)) + carry;
                const share: usize = @as(usize, @intCast(numer / @as(u128, total_flex)));
                carry = numer % @as(u128, total_flex);
                break :blk share;
            }
            break :blk measureHeight(child, child_widths[idx]);
        };
        h = clampSize(h, min_h, max_h);
        if (h > parent_inner_h) h = parent_inner_h;
        out[idx] = h;
    }

    return extra_space;
}

fn computeHBoxWidths(children: []const protocol.Node, parent_inner_w: usize, gap: usize, out: []usize) bool {
    const count = children.len;
    if (out.len < count) return false;
    if (count == 0) return true;
    if (count > max_layout_children) return false;

    const gaps_total: usize = if (count > 1) gap * (count - 1) else 0;
    const alloc_space: usize = if (parent_inner_w > gaps_total) parent_inner_w - gaps_total else 0;

    var min_arr: [max_layout_children]usize = undefined;
    var max_arr: [max_layout_children]usize = undefined;
    var has_max_arr: [max_layout_children]bool = undefined;
    var flex_arr: [max_layout_children]usize = undefined;
    var pinned_arr: [max_layout_children]bool = undefined;

    var base_sum: usize = 0;
    for (children, 0..) |child, idx| {
        const intrinsic_min = measureMinWidth(child);
        var min_v = nodeMinW(child) orelse 0;
        if (intrinsic_min > min_v) min_v = intrinsic_min;

        var max_v = nodeMaxW(child);
        if (max_v != null and max_v.? < min_v) max_v = min_v;

        const hint_raw = computeHintW(child, parent_inner_w);
        const hint = applyMinMax(hint_raw, min_v, max_v);

        const pinned = nodeHintW(child) != null or nodePctW(child) != null;
        const alloc = hint orelse min_v;

        min_arr[idx] = min_v;
        max_arr[idx] = max_v orelse 0;
        has_max_arr[idx] = max_v != null;
        flex_arr[idx] = nodeFlex(child);
        pinned_arr[idx] = pinned;
        out[idx] = alloc;
        base_sum += alloc;
    }

    if (base_sum < alloc_space) {
        var remaining = alloc_space - base_sum;
        while (remaining > 0) {
            var total_weight: usize = 0;
            var any_eligible = false;
            for (children, 0..) |_, idx| {
                if (flex_arr[idx] == 0) continue;
                const cap = if (has_max_arr[idx]) (if (max_arr[idx] > out[idx]) max_arr[idx] - out[idx] else 0) else remaining;
                if (cap == 0) continue;
                any_eligible = true;
                total_weight += flex_arr[idx];
            }
            if (!any_eligible or total_weight == 0) break;

            var granted_total: usize = 0;
            var carry: u128 = 0;
            for (children, 0..) |_, idx| {
                if (granted_total >= remaining) break;
                if (flex_arr[idx] == 0) continue;
                const cap = if (has_max_arr[idx]) (if (max_arr[idx] > out[idx]) max_arr[idx] - out[idx] else 0) else remaining - granted_total;
                if (cap == 0) continue;

                const numer: u128 = @as(u128, remaining) * @as(u128, flex_arr[idx]) + carry;
                var share: usize = @as(usize, @intCast(numer / @as(u128, total_weight)));
                carry = numer % @as(u128, total_weight);
                if (share == 0) share = 1;

                const give = @min(@min(share, cap), remaining - granted_total);
                if (give == 0) continue;
                out[idx] += give;
                granted_total += give;
            }

            if (granted_total == 0) break;
            remaining -= granted_total;
        }
        return true;
    }

    if (base_sum > alloc_space) {
        var deficit = base_sum - alloc_space;
        while (deficit > 0) {
            var total_weight: usize = 0;
            var any_eligible = false;
            for (children, 0..) |_, idx| {
                if (pinned_arr[idx]) continue;
                const cap = if (out[idx] > min_arr[idx]) out[idx] - min_arr[idx] else 0;
                if (cap == 0) continue;
                any_eligible = true;
                total_weight += if (flex_arr[idx] > 0) flex_arr[idx] else 1;
            }
            if (!any_eligible or total_weight == 0) break;

            var reduced_total: usize = 0;
            var carry: u128 = 0;
            for (children, 0..) |_, idx| {
                if (reduced_total >= deficit) break;
                if (pinned_arr[idx]) continue;
                const cap = if (out[idx] > min_arr[idx]) out[idx] - min_arr[idx] else 0;
                if (cap == 0) continue;
                const weight = if (flex_arr[idx] > 0) flex_arr[idx] else 1;
                const numer: u128 = @as(u128, deficit) * @as(u128, weight) + carry;
                var share: usize = @as(usize, @intCast(numer / @as(u128, total_weight)));
                carry = numer % @as(u128, total_weight);
                if (share == 0) share = 1;

                const take = @min(@min(share, cap), deficit - reduced_total);
                if (take == 0) continue;
                out[idx] -= take;
                reduced_total += take;
            }

            if (reduced_total == 0) break;
            deficit -= reduced_total;
        }

        if (deficit > 0) {
            var idx = count;
            while (idx > 0 and deficit > 0) {
                idx -= 1;
                const take = @min(deficit, out[idx]);
                out[idx] -= take;
                deficit -= take;
            }
        }
    }

    return true;
}

fn nodeGridRow(node: protocol.Node) ?usize {
    return switch (node) {
        .vbox => |v| v.grid_row,
        .hbox => |h| h.grid_row,
        .grid => |g| g.grid_row,
        .box => |b| b.grid_row,
        .scroll => |s| s.grid_row,
        .overlay => |o| o.grid_row,
        .text => |t| t.grid_row,
        .styled_text => |t| t.grid_row,
        .input => |i| i.grid_row,
        .textarea => |t| t.grid_row,
        .list => |l| l.grid_row,
        .vlist => |l| l.grid_row,
    };
}

fn nodeGridCol(node: protocol.Node) ?usize {
    return switch (node) {
        .vbox => |v| v.grid_col,
        .hbox => |h| h.grid_col,
        .grid => |g| g.grid_col,
        .box => |b| b.grid_col,
        .scroll => |s| s.grid_col,
        .overlay => |o| o.grid_col,
        .text => |t| t.grid_col,
        .styled_text => |t| t.grid_col,
        .input => |i| i.grid_col,
        .textarea => |t| t.grid_col,
        .list => |l| l.grid_col,
        .vlist => |l| l.grid_col,
    };
}

fn nodeRowSpan(node: protocol.Node) usize {
    const raw = switch (node) {
        .vbox => |v| v.row_span,
        .hbox => |h| h.row_span,
        .grid => |g| g.row_span,
        .box => |b| b.row_span,
        .scroll => |s| s.row_span,
        .overlay => |o| o.row_span,
        .text => |t| t.row_span,
        .styled_text => |t| t.row_span,
        .input => |i| i.row_span,
        .textarea => |t| t.row_span,
        .list => |l| l.row_span,
        .vlist => |l| l.row_span,
    };
    return if (raw == 0) 1 else raw;
}

fn nodeColSpan(node: protocol.Node) usize {
    const raw = switch (node) {
        .vbox => |v| v.col_span,
        .hbox => |h| h.col_span,
        .grid => |g| g.col_span,
        .box => |b| b.col_span,
        .scroll => |s| s.col_span,
        .overlay => |o| o.col_span,
        .text => |t| t.col_span,
        .styled_text => |t| t.col_span,
        .input => |i| i.col_span,
        .textarea => |t| t.col_span,
        .list => |l| l.col_span,
        .vlist => |l| l.col_span,
    };
    return if (raw == 0) 1 else raw;
}

fn nodeGridArea(node: protocol.Node) ?[]const u8 {
    return switch (node) {
        .vbox => |v| v.grid_area,
        .hbox => |h| h.grid_area,
        .grid => |g| g.grid_area,
        .box => |b| b.grid_area,
        .scroll => |s| s.grid_area,
        .overlay => |o| o.grid_area,
        .text => |t| t.grid_area,
        .styled_text => |t| t.grid_area,
        .input => |i| i.grid_area,
        .textarea => |t| t.grid_area,
        .list => |l| l.grid_area,
        .vlist => |l| l.grid_area,
    };
}

fn nextAreaToken(row: []const u8, cursor: *usize) ?[]const u8 {
    var i = cursor.*;
    while (i < row.len and std.ascii.isWhitespace(row[i])) : (i += 1) {}
    if (i >= row.len) {
        cursor.* = i;
        return null;
    }
    const start = i;
    while (i < row.len and !std.ascii.isWhitespace(row[i])) : (i += 1) {}
    cursor.* = i;
    return row[start..i];
}

fn resolveGridAreaBounds(g: protocol.GridNode, area_name: []const u8, rows_n: usize, cols_n: usize) ?GridPlacement {
    const areas = g.areas orelse return null;
    if (area_name.len == 0) return null;
    if (std.mem.eql(u8, area_name, ".")) return null;

    var found = false;
    var min_r: usize = 0;
    var max_r: usize = 0;
    var min_c: usize = 0;
    var max_c: usize = 0;

    const lim_rows = @min(rows_n, areas.len);
    var r: usize = 0;
    while (r < lim_rows) : (r += 1) {
        var cursor: usize = 0;
        var c: usize = 0;
        while (c < cols_n) : (c += 1) {
            const tok = nextAreaToken(areas[r], &cursor) orelse break;
            if (!std.mem.eql(u8, tok, area_name)) continue;
            if (!found) {
                found = true;
                min_r = r;
                max_r = r;
                min_c = c;
                max_c = c;
            } else {
                if (r < min_r) min_r = r;
                if (r > max_r) max_r = r;
                if (c < min_c) min_c = c;
                if (c > max_c) max_c = c;
            }
        }
    }

    if (!found) return null;
    return .{
        .row = min_r,
        .col = min_c,
        .row_span = max_r - min_r + 1,
        .col_span = max_c - min_c + 1,
    };
}

fn resolveGridPlacement(g: protocol.GridNode, child: protocol.Node, idx: usize, rows_n: usize, cols_n: usize) GridPlacement {
    if (rows_n == 0 or cols_n == 0) return .{ .row = 0, .col = 0, .row_span = 1, .col_span = 1 };

    const explicit_row = nodeGridRow(child);
    const explicit_col = nodeGridCol(child);

    if (explicit_row == null and explicit_col == null) {
        if (nodeGridArea(child)) |area| {
            if (resolveGridAreaBounds(g, area, rows_n, cols_n)) |p| return p;
        }
    }

    const row_fallback = @min(idx / cols_n, rows_n - 1);
    const col_fallback = @min(idx % cols_n, cols_n - 1);
    const row = @min(explicit_row orelse row_fallback, rows_n - 1);
    const col = @min(explicit_col orelse col_fallback, cols_n - 1);

    const row_span = @max(@min(nodeRowSpan(child), rows_n - row), 1);
    const col_span = @max(@min(nodeColSpan(child), cols_n - col), 1);
    return .{ .row = row, .col = col, .row_span = row_span, .col_span = col_span };
}

fn trackOffset(track_sizes: []const usize, gap: usize, idx: usize) usize {
    if (idx == 0) return 0;
    var out: usize = 0;
    var i: usize = 0;
    while (i < idx and i < track_sizes.len) : (i += 1) {
        out += track_sizes[i];
        if (i + 1 <= idx) out += gap;
    }
    return out;
}

fn spanSize(track_sizes: []const usize, gap: usize, start: usize, span: usize) usize {
    var out: usize = 0;
    var i: usize = 0;
    const lim = @min(start + span, track_sizes.len);
    var t = start;
    while (t < lim) : (t += 1) {
        out += track_sizes[t];
        i += 1;
    }
    if (i > 1) out += gap * (i - 1);
    return out;
}

fn computeTrackSizes(
    tracks: []const protocol.GridTrack,
    autos: []const usize,
    total_space: usize,
    gap: usize,
    out: []usize,
) void {
    if (tracks.len == 0) return;
    const count = @min(@min(tracks.len, autos.len), out.len);
    @memset(out[0..count], 0);

    const gaps_total: usize = if (count > 1) gap * (count - 1) else 0;
    const avail: usize = if (total_space > gaps_total) total_space - gaps_total else 0;

    var base_sum: usize = 0;
    var total_fr: usize = 0;
    for (tracks[0..count], 0..) |t, idx| {
        switch (t) {
            .fixed => |v| {
                out[idx] = v;
                base_sum += v;
            },
            .auto => {
                out[idx] = autos[idx];
                base_sum += autos[idx];
            },
            .fr => |f| total_fr += if (f == 0) 1 else f,
        }
    }

    const remaining: usize = if (avail > base_sum) avail - base_sum else 0;
    if (total_fr == 0 or remaining == 0) return;

    var carry: u128 = 0;
    for (tracks[0..count], 0..) |t, idx| {
        switch (t) {
            .fr => |f| {
                const fv: usize = if (f == 0) 1 else f;
                const numer: u128 = @as(u128, remaining) * @as(u128, fv) + carry;
                out[idx] = @as(usize, @intCast(numer / @as(u128, total_fr)));
                carry = numer % @as(u128, total_fr);
            },
            else => {},
        }
    }
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

fn clampRectToNodeMax(rect: RectI, node: protocol.Node) RectI {
    var out = rect;
    if (nodeMaxW(node)) |max_w| {
        if (out.w > max_w) out.w = max_w;
    }
    if (nodeMaxH(node)) |max_h| {
        if (out.h > max_h) out.h = max_h;
    }
    return out;
}

fn nodeId(node: protocol.Node) []const u8 {
    return switch (node) {
        .vbox => |v| v.id,
        .hbox => |h| h.id,
        .grid => |g| g.id,
        .box => |b| b.id,
        .scroll => |s| s.id,
        .overlay => |o| o.id,
        .text => |t| t.id,
        .styled_text => |t| t.id,
        .input => |i| i.id,
        .textarea => |t| t.id,
        .list => |l| l.id,
        .vlist => |l| l.id,
    };
}

fn nodeHintW(node: protocol.Node) ?usize {
    return switch (node) {
        .vbox => |v| v.w,
        .hbox => |h| h.w,
        .grid => |g| g.w,
        .box => |b| b.w,
        .scroll => |s| s.w,
        .overlay => |o| o.w,
        .text => |t| t.w,
        .styled_text => |t| t.w,
        .input => |i| i.w,
        .textarea => |t| t.w,
        .list => |l| l.w,
        .vlist => |l| l.w,
    };
}

fn nodeHintH(node: protocol.Node) ?usize {
    return switch (node) {
        .vbox => |v| v.h,
        .hbox => |h| h.h,
        .grid => |g| g.h,
        .box => |b| b.h,
        .scroll => |s| s.h,
        .overlay => |o| o.h,
        .text => |t| t.h,
        .styled_text => |t| t.h,
        .input => |i| i.h,
        .textarea => |t| t.h,
        .list => |l| l.h,
        .vlist => |l| l.h,
    };
}

fn nodeMinW(node: protocol.Node) ?usize {
    return switch (node) {
        .vbox => |v| v.min_w,
        .hbox => |h| h.min_w,
        .grid => |g| g.min_w,
        .box => |b| b.min_w,
        .scroll => |s| s.min_w,
        .overlay => |o| o.min_w,
        .text => |t| t.min_w,
        .styled_text => |t| t.min_w,
        .input => |i| i.min_w,
        .textarea => |t| t.min_w,
        .list => |l| l.min_w,
        .vlist => |l| l.min_w,
    };
}

fn nodeMaxW(node: protocol.Node) ?usize {
    return switch (node) {
        .vbox => |v| v.max_w,
        .hbox => |h| h.max_w,
        .grid => |g| g.max_w,
        .box => |b| b.max_w,
        .scroll => |s| s.max_w,
        .overlay => |o| o.max_w,
        .text => |t| t.max_w,
        .styled_text => |t| t.max_w,
        .input => |i| i.max_w,
        .textarea => |t| t.max_w,
        .list => |l| l.max_w,
        .vlist => |l| l.max_w,
    };
}

fn nodeMinH(node: protocol.Node) ?usize {
    return switch (node) {
        .vbox => |v| v.min_h,
        .hbox => |h| h.min_h,
        .grid => |g| g.min_h,
        .box => |b| b.min_h,
        .scroll => |s| s.min_h,
        .overlay => |o| o.min_h,
        .text => |t| t.min_h,
        .styled_text => |t| t.min_h,
        .input => |i| i.min_h,
        .textarea => |t| t.min_h,
        .list => |l| l.min_h,
        .vlist => |l| l.min_h,
    };
}

fn nodeMaxH(node: protocol.Node) ?usize {
    return switch (node) {
        .vbox => |v| v.max_h,
        .hbox => |h| h.max_h,
        .grid => |g| g.max_h,
        .box => |b| b.max_h,
        .scroll => |s| s.max_h,
        .overlay => |o| o.max_h,
        .text => |t| t.max_h,
        .styled_text => |t| t.max_h,
        .input => |i| i.max_h,
        .textarea => |t| t.max_h,
        .list => |l| l.max_h,
        .vlist => |l| l.max_h,
    };
}

fn nodePctW(node: protocol.Node) ?u8 {
    return switch (node) {
        .vbox => |v| v.w_pct,
        .hbox => |h| h.w_pct,
        .grid => |g| g.w_pct,
        .box => |b| b.w_pct,
        .scroll => |s| s.w_pct,
        .overlay => |o| o.w_pct,
        .text => |t| t.w_pct,
        .styled_text => |t| t.w_pct,
        .input => |i| i.w_pct,
        .textarea => |t| t.w_pct,
        .list => |l| l.w_pct,
        .vlist => |l| l.w_pct,
    };
}

fn nodePctH(node: protocol.Node) ?u8 {
    return switch (node) {
        .vbox => |v| v.h_pct,
        .hbox => |h| h.h_pct,
        .grid => |g| g.h_pct,
        .box => |b| b.h_pct,
        .scroll => |s| s.h_pct,
        .overlay => |o| o.h_pct,
        .text => |t| t.h_pct,
        .styled_text => |t| t.h_pct,
        .input => |i| i.h_pct,
        .textarea => |t| t.h_pct,
        .list => |l| l.h_pct,
        .vlist => |l| l.h_pct,
    };
}

fn computeHintW(node: protocol.Node, parent_inner_w: usize) ?usize {
    if (nodeHintW(node)) |w| return w;
    if (nodePctW(node)) |pct| return (parent_inner_w * @as(usize, pct)) / 100;
    return null;
}

fn computeHintH(node: protocol.Node, parent_inner_h: usize) ?usize {
    if (nodeHintH(node)) |h| return h;
    if (nodePctH(node)) |pct| return (parent_inner_h * @as(usize, pct)) / 100;
    return null;
}

fn clampSize(value: usize, min_opt: ?usize, max_opt: ?usize) usize {
    const lo = min_opt orelse 0;
    const hi_raw = max_opt orelse std.math.maxInt(usize);
    const hi = if (hi_raw < lo) lo else hi_raw;
    if (value < lo) return lo;
    if (value > hi) return hi;
    return value;
}

fn applyMinMax(value_opt: ?usize, min_opt: ?usize, max_opt: ?usize) ?usize {
    if (value_opt) |value| return clampSize(value, min_opt, max_opt);
    return null;
}

fn nodeFlex(node: protocol.Node) usize {
    return switch (node) {
        .vbox => |v| v.flex,
        .hbox => |h| h.flex,
        .grid => |g| g.flex,
        .box => |b| b.flex,
        .scroll => |s| s.flex,
        .overlay => |o| o.flex,
        .text => |t| t.flex,
        .styled_text => |t| t.flex,
        .input => |i| i.flex,
        .textarea => |t| t.flex,
        .list => |l| l.flex,
        .vlist => |l| l.flex,
    };
}

fn nodePad(node: protocol.Node) usize {
    return switch (node) {
        .vbox => |v| v.pad,
        .hbox => |h| h.pad,
        .grid => |g| g.pad,
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
        .grid => |g| g.clip,
        .box => |b| b.clip,
        .scroll => |s| s.clip,
        .overlay => |o| o.clip,
        else => false,
    };
}

fn measureMinWidth(node: protocol.Node) usize {
    const min_w = nodeMinW(node);
    const max_w_opt = nodeMaxW(node);
    if (nodeHintW(node)) |w| return clampSize(w, min_w, max_w_opt);

    const intrinsic = switch (node) {
        .text => |t| blk: {
            var max_line_w: usize = 0;
            var start: usize = 0;
            var i: usize = 0;
            while (i <= t.text.len) : (i += 1) {
                if (i == t.text.len or t.text[i] == '\n') {
                    const w = unicode.displayWidth(t.text[start..i]);
                    if (w > max_line_w) max_line_w = w;
                    start = i + 1;
                }
            }
            break :blk max_line_w;
        },
        .styled_text => |t| blk: {
            var total: usize = 0;
            for (t.spans) |sp| total += unicode.displayWidth(sp.text);
            break :blk total;
        },
        .input => 3,
        .textarea => 8,
        .list => |l| blk: {
            var max_w: usize = 0;
            for (l.children) |child| {
                const w = measureMinWidth(child);
                if (w > max_w) max_w = w;
            }
            break :blk max_w;
        },
        .vlist => |l| blk: {
            var max_w: usize = 0;
            for (l.children) |child| {
                const w = measureMinWidth(child);
                if (w > max_w) max_w = w;
            }
            break :blk max_w;
        },
        .vbox => |v| blk: {
            var max_w: usize = 0;
            for (v.children) |child| {
                const w = measureMinWidth(child);
                if (w > max_w) max_w = w;
            }
            break :blk max_w + v.pad * 2;
        },
        .hbox => |h| blk: {
            var sum: usize = h.pad * 2;
            if (h.children.len > 1) sum += h.gap * (h.children.len - 1);
            for (h.children) |child| sum += measureMinWidth(child);
            break :blk sum;
        },
        .grid => |g| blk: {
            var sum: usize = g.pad * 2;
            if (g.cols.len > 1) sum += g.gap_x * (g.cols.len - 1);
            for (g.cols) |c| {
                sum += switch (c) {
                    .fixed => |v| v,
                    .auto => 1,
                    .fr => 1,
                };
            }
            break :blk sum;
        },
        .box => |b| blk: {
            const chrome: usize = @as(usize, @intFromBool(b.border)) + b.pad;
            break :blk measureMinWidth(b.child.*) + chrome * 2;
        },
        .scroll => |s| measureMinWidth(s.child.*) + s.pad * 2,
        .overlay => |o| measureMinWidth(o.base.*) + o.pad * 2,
    };
    return clampSize(intrinsic, min_w, max_w_opt);
}

fn measureHeight(node: protocol.Node, avail_w: usize) usize {
    const min_h = nodeMinH(node);
    const max_h_opt = nodeMaxH(node);
    if (nodeHintH(node)) |h| return clampSize(h, min_h, max_h_opt);

    const measured = switch (node) {
        .text => |t| render_text.countWrappedLines(t.text, avail_w),
        .styled_text => |t| render_text.countWrappedLinesSpans(t.spans, avail_w),
        .input => 1,
        .textarea => 3,
        .list => |l| l.height orelse l.children.len,
        .vlist => |l| l.height orelse l.total,
        .box => |b| blk: {
            const border_thickness: usize = if (b.border and avail_w >= 2) 1 else 0;
            const chrome: usize = border_thickness + b.pad;
            const inner_w: usize = if (avail_w > chrome * 2) avail_w - chrome * 2 else 0;
            const child_w = singleChildWidthHint(inner_w, b.child.*);
            break :blk measureHeight(b.child.*, child_w) + chrome * 2;
        },
        .scroll => |s| blk: {
            const inner_w: usize = if (avail_w > s.pad * 2) avail_w - s.pad * 2 else 0;
            const child_w = singleChildWidthHint(inner_w, s.child.*);
            break :blk measureHeight(s.child.*, child_w) + s.pad * 2;
        },
        .overlay => |o| blk: {
            const inner_w: usize = if (avail_w > o.pad * 2) avail_w - o.pad * 2 else 0;
            const child_w = singleChildWidthHint(inner_w, o.base.*);
            break :blk measureHeight(o.base.*, child_w) + o.pad * 2;
        },
        .vbox => |v| blk: {
            const inner_w: usize = if (avail_w > v.pad * 2) avail_w - v.pad * 2 else 0;
            var total: usize = v.pad * 2;
            if (v.children.len > 1) total += v.gap * (v.children.len - 1);
            for (v.children) |child| {
                const child_w = vboxChildWidth(inner_w, v.align_items, child);
                total += measureHeight(child, child_w);
            }
            break :blk total;
        },
        .hbox => |h| blk: {
            const inner_w = if (avail_w > h.pad * 2) avail_w - h.pad * 2 else 0;
            var max_child_h: usize = 0;
            if (h.children.len <= max_layout_children) {
                var widths: [max_layout_children]usize = undefined;
                if (computeHBoxWidths(h.children, inner_w, h.gap, widths[0..h.children.len])) {
                    for (h.children, 0..) |child, idx| {
                        const ch = measureHeight(child, widths[idx]);
                        if (ch > max_child_h) max_child_h = ch;
                    }
                    break :blk max_child_h + h.pad * 2;
                }
            }
            for (h.children) |child| {
                const child_w = singleChildWidthHint(inner_w, child);
                const ch = measureHeight(child, child_w);
                if (ch > max_child_h) max_child_h = ch;
            }
            break :blk max_child_h + h.pad * 2;
        },
        .grid => |g| blk: {
            // Use configured row tracks for intrinsic height; auto/fr are treated as 1 row each here.
            var rows_h: usize = 0;
            for (g.rows) |r| {
                rows_h += switch (r) {
                    .fixed => |v| v,
                    .auto => 1,
                    .fr => 1,
                };
            }
            if (g.rows.len > 1) rows_h += g.gap_y * (g.rows.len - 1);
            break :blk rows_h + g.pad * 2;
        },
    };
    return clampSize(measured, min_h, max_h_opt);
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
            const inner_w = if (avail_w > h.pad * 2) avail_w - h.pad * 2 else 0;
            const y_base: usize = y_offset + h.pad;

            var inner_h: usize = 0;
            var widths: [max_layout_children]usize = undefined;
            var width_slice: []usize = &.{};
            if (h.children.len <= max_layout_children and computeHBoxWidths(h.children, inner_w, h.gap, widths[0..h.children.len])) {
                width_slice = widths[0..h.children.len];
            }
            for (h.children, 0..) |child, idx| {
                const child_w = if (width_slice.len == h.children.len) width_slice[idx] else singleChildWidthHint(inner_w, child);
                const ch = measureHeight(child, child_w);
                if (ch > inner_h) inner_h = ch;
            }

            for (h.children, 0..) |child, idx| {
                const child_w = if (width_slice.len == h.children.len) width_slice[idx] else singleChildWidthHint(inner_w, child);
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
        .grid => |g| {
            const rows_n = @min(g.rows.len, max_grid_tracks);
            const cols_n = @min(g.cols.len, max_grid_tracks);
            if (rows_n == 0 or cols_n == 0) return false;
            const inner_w: usize = if (avail_w > g.pad * 2) avail_w - g.pad * 2 else 0;
            const inner_h_est: usize = measureHeight(.{ .grid = g }, avail_w);

            var col_auto: [max_grid_tracks]usize = undefined;
            var row_auto: [max_grid_tracks]usize = undefined;
            var col_sizes: [max_grid_tracks]usize = undefined;
            var row_sizes: [max_grid_tracks]usize = undefined;
            @memset(col_auto[0..cols_n], 1);
            @memset(row_auto[0..rows_n], 1);
            @memset(col_sizes[0..cols_n], 0);
            @memset(row_sizes[0..rows_n], 0);

            for (g.children, 0..) |child, idx| {
                const p = resolveGridPlacement(g, child, idx, rows_n, cols_n);
                if (p.col_span == 1 and p.col < cols_n) {
                    const w = applyMinMax(computeHintW(child, inner_w), nodeMinW(child), nodeMaxW(child)) orelse measureMinWidth(child);
                    if (w > col_auto[p.col]) col_auto[p.col] = w;
                }
            }
            computeTrackSizes(g.cols[0..cols_n], col_auto[0..cols_n], inner_w, g.gap_x, col_sizes[0..cols_n]);

            for (g.children, 0..) |child, idx| {
                const p = resolveGridPlacement(g, child, idx, rows_n, cols_n);
                if (p.row_span == 1 and p.row < rows_n) {
                    const cw = spanSize(col_sizes[0..cols_n], g.gap_x, p.col, p.col_span);
                    const h = applyMinMax(computeHintH(child, inner_h_est), nodeMinH(child), nodeMaxH(child)) orelse measureHeight(child, cw);
                    if (h > row_auto[p.row]) row_auto[p.row] = h;
                }
            }
            computeTrackSizes(g.rows[0..rows_n], row_auto[0..rows_n], inner_h_est, g.gap_y, row_sizes[0..rows_n]);

            for (g.children, 0..) |child, idx| {
                const p = resolveGridPlacement(g, child, idx, rows_n, cols_n);
                const y_child = y_offset + g.pad + trackOffset(row_sizes[0..rows_n], g.gap_y, p.row);
                const cw = spanSize(col_sizes[0..cols_n], g.gap_x, p.col, p.col_span);
                if (findContentYRangeForIdInto(child, cw, id, y_child, out)) return true;
            }
            return false;
        },
        .scroll => |s| {
            const inner_w: usize = if (avail_w > s.pad * 2) avail_w - s.pad * 2 else 0;
            const child_w = singleChildWidthHint(inner_w, s.child.*);
            return findContentYRangeForIdInto(s.child.*, child_w, id, y_offset + s.pad, out);
        },
        .box => |b| {
            const border_thickness: usize = if (b.border and avail_w >= 2) 1 else 0;
            const chrome: usize = border_thickness + b.pad;
            const inner_w: usize = if (avail_w > chrome * 2) avail_w - chrome * 2 else 0;
            const child_w = singleChildWidthHint(inner_w, b.child.*);
            return findContentYRangeForIdInto(b.child.*, child_w, id, y_offset + chrome, out);
        },
        .overlay => |o| {
            const inner_w: usize = if (avail_w > o.pad * 2) avail_w - o.pad * 2 else 0;
            const child_w = singleChildWidthHint(inner_w, o.base.*);
            return findContentYRangeForIdInto(o.base.*, child_w, id, y_offset + o.pad, out);
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
    const metrics = unicode.defaultTextMetrics();

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

            const g = metrics.nextGrapheme(text, i);
            if (g.end <= i) break;
            const b0: u8 = text[g.start];
            if (b0 == '\r') {
                i = g.end;
                continue;
            }
            const width = metrics.graphemeWidthAtCol(text, g, used);
            if (width > 0 and used + width > rect.w) return;
            if (width > 0 and rect.w != 0 and width > rect.w) {
                i = g.end;
                continue;
            }

            if (width > 0) {
                const abs_col: isize = rect.x + @as(isize, @intCast(used));
                render_text.putGraphemeClipped(frame, row, abs_col, text[g.start..g.end], width, clip, span_packed);
                used += width;
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
    const metrics = unicode.defaultTextMetrics();

    var used: usize = 0;
    for (pieces, 0..) |p, pi| {
        const st = styles[pi];
        if (used >= rect.w) break;
        var i: usize = 0;
        while (i < p.len and used < rect.w) {
            const g = metrics.nextGrapheme(p, i);
            if (g.end <= i) break;
            const b0: u8 = p[g.start];
            if (b0 == '\r') {
                i = g.end;
                continue;
            }
            const width = metrics.graphemeWidthAtCol(p, g, used);
            if (width > 0 and used + width > rect.w) break;
            if (width > 0 and rect.w != 0 and width > rect.w) {
                i = g.end;
                continue;
            }

            if (width > 0) {
                const abs_col: isize = rect.x + @as(isize, @intCast(used));
                render_text.putGraphemeClipped(frame, row, abs_col, p[g.start..g.end], width, clip, st);
                used += width;
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
    const metrics = unicode.defaultTextMetrics();
    var used: usize = 0;
    var i: usize = 0;
    while (i < text.len and used < max_w) {
        const g = metrics.nextGrapheme(text, i);
        if (g.end <= i) break;
        const b0: u8 = text[g.start];
        if (b0 == '\r') {
            i = g.end;
            continue;
        }
        const width = metrics.graphemeWidthAtCol(text, g, used);

        if (width > 0 and max_w != 0 and width > max_w) {
            i = g.end;
            continue;
        }
        if (width > 0 and used + width > max_w) break;

        if (width > 0) {
            const x: isize = col_abs + @as(isize, @intCast(used));
            render_text.putGraphemeClipped(frame, row, x, text[g.start..g.end], width, clip, st);
            used += width;
        }
        i = g.end;
    }
}

fn drawInlineTextWithOverflowAt(
    frame: *Frame,
    row: isize,
    col_abs: isize,
    clip: RectI,
    text: []const u8,
    max_w: usize,
    overflow: protocol.TextOverflow,
    st: style.PackedStyle,
) void {
    if (max_w == 0) return;
    if (overflow == .clip) {
        drawInlineTextAt(frame, row, col_abs, clip, text, max_w, st);
        return;
    }
    const fit = render_text.fitWithEllipsis(text, max_w);
    if (!fit.use_ellipsis) {
        drawInlineTextAt(frame, row, col_abs, clip, text, max_w, st);
        return;
    }

    if (fit.slice_end_byte > 0) {
        drawInlineTextAt(frame, row, col_abs, clip, text[0..fit.slice_end_byte], max_w, st);
    }
    if (fit.suffix.width > 0) {
        const used = unicode.displayWidth(text[0..fit.slice_end_byte]);
        drawInlineTextAt(
            frame,
            row,
            col_abs + @as(isize, @intCast(used)),
            clip,
            fit.suffix.text,
            fit.suffix.width,
            st,
        );
    }
}

fn drawInlineStyledSpansInRectWithEllipsis(
    frame: *Frame,
    row: isize,
    rect: RectI,
    clip: RectI,
    spans: []const protocol.Span,
    base: style.Style,
    start_col: usize,
    attrs_or: u8,
    max_cols: usize,
    overflow: protocol.TextOverflow,
) void {
    if (max_cols == 0) return;
    if (overflow == .clip) {
        drawInlineStyledSpansInRect(frame, row, rect, clip, spans, base, start_col, attrs_or);
        return;
    }

    var total_w: usize = 0;
    for (spans) |sp| total_w += unicode.displayWidth(sp.text);
    if (total_w <= max_cols) {
        drawInlineStyledSpansInRect(frame, row, rect, clip, spans, base, start_col, attrs_or);
        return;
    }

    const suffix = render_text.ellipsisSuffixForWidth(max_cols);
    const content_cols: usize = if (max_cols > suffix.width) max_cols - suffix.width else 0;

    var content_rect = rect;
    content_rect.w = @min(rect.w, start_col + content_cols);
    drawInlineStyledSpansInRect(frame, row, content_rect, clip, spans, base, start_col, attrs_or);

    if (suffix.width > 0) {
        var suffix_style = style.pack(base);
        suffix_style.attrs |= attrs_or;
        drawInlineTextAt(
            frame,
            row,
            rect.x + @as(isize, @intCast(start_col + content_cols)),
            clip,
            suffix.text,
            suffix.width,
            suffix_style,
        );
    }
}

fn drawInlineTextWithSelectionAt(
    frame: *Frame,
    row: isize,
    col_abs: isize,
    clip: RectI,
    text: []const u8,
    base_offset: usize,
    selection_start: ?usize,
    selection_end: ?usize,
    max_w: usize,
    base_style: style.PackedStyle,
    selected_style: style.PackedStyle,
) void {
    const metrics = unicode.defaultTextMetrics();
    var used: usize = 0;
    var i: usize = 0;
    while (i < text.len and used < max_w) {
        const g = metrics.nextGrapheme(text, i);
        if (g.end <= i) break;
        const b0: u8 = text[g.start];
        if (b0 == '\r') {
            i = g.end;
            continue;
        }
        const width = metrics.graphemeWidthAtCol(text, g, used);

        if (width > 0 and max_w != 0 and width > max_w) {
            i = g.end;
            continue;
        }
        if (width > 0 and used + width > max_w) break;

        if (width > 0) {
            const x: isize = col_abs + @as(isize, @intCast(used));
            const abs_start = base_offset + g.start;
            const selected = selection_start != null and selection_end != null and abs_start >= selection_start.? and abs_start < selection_end.?;
            render_text.putGraphemeClipped(
                frame,
                row,
                x,
                text[g.start..g.end],
                width,
                clip,
                if (selected) selected_style else base_style,
            );
            used += width;
        }
        i = g.end;
    }
}

fn packedEq(a: style.PackedStyle, b: style.PackedStyle) bool {
    return @as(u64, @bitCast(a)) == @as(u64, @bitCast(b));
}

fn stateFlagsForNode(
    node: protocol.Node,
    state: RenderState,
    id: []const u8,
    suppress_list_hover: bool,
    force_hovered: bool,
    allow_hovered_id_match: bool,
) theme_mod.StateFlags {
    var flags: theme_mod.StateFlags = .{};
    if (nodeDisabled(node)) flags.bits |= theme_mod.StateFlags.disabled;
    if (nodeReadonly(node)) flags.bits |= theme_mod.StateFlags.readonly;
    switch (nodeValidation(node)) {
        .none => {},
        .@"error" => flags.bits |= theme_mod.StateFlags.validation_error,
        .warning => flags.bits |= theme_mod.StateFlags.validation_warning,
        .success => flags.bits |= theme_mod.StateFlags.validation_success,
    }
    if (force_hovered) {
        flags.bits |= theme_mod.StateFlags.hovered;
    } else if (allow_hovered_id_match and state.hovered_id != null and std.mem.eql(u8, state.hovered_id.?, id) and !suppress_list_hover) {
        flags.bits |= theme_mod.StateFlags.hovered;
    }
    if (state.focused_id != null and std.mem.eql(u8, state.focused_id.?, id)) flags.bits |= theme_mod.StateFlags.focused;
    if (state.active_id != null and std.mem.eql(u8, state.active_id.?, id)) flags.bits |= theme_mod.StateFlags.active;
    return flags;
}

fn nodeDisabled(node: protocol.Node) bool {
    return switch (node) {
        .vbox => |v| v.disabled,
        .hbox => |h| h.disabled,
        .grid => |g| g.disabled,
        .box => |b| b.disabled,
        .scroll => |s| s.disabled,
        .overlay => |o| o.disabled,
        .text => |t| t.disabled,
        .styled_text => |t| t.disabled,
        .input => |i| i.disabled,
        .textarea => |t| t.disabled,
        .list => |l| l.disabled,
        .vlist => |l| l.disabled,
    };
}

fn nodeReadonly(node: protocol.Node) bool {
    return switch (node) {
        .vbox => |v| v.readonly,
        .hbox => |h| h.readonly,
        .grid => |g| g.readonly,
        .box => |b| b.readonly,
        .scroll => |s| s.readonly,
        .overlay => |o| o.readonly,
        .text => |t| t.readonly,
        .styled_text => |t| t.readonly,
        .input => |i| i.readonly,
        .textarea => |t| t.readonly,
        .list => |l| l.readonly,
        .vlist => |l| l.readonly,
    };
}

fn nodeValidation(node: protocol.Node) protocol.ValidationState {
    return switch (node) {
        .vbox => |v| v.validation,
        .hbox => |h| h.validation,
        .grid => |g| g.validation,
        .box => |b| b.validation,
        .scroll => |s| s.validation,
        .overlay => |o| o.validation,
        .text => |t| t.validation,
        .styled_text => |t| t.validation,
        .input => |i| i.validation,
        .textarea => |t| t.validation,
        .list => |l| l.validation,
        .vlist => |l| l.validation,
    };
}

fn resolveThemedOverride(
    node: protocol.Node,
    state: RenderState,
    id: []const u8,
    suppress_list_hover: bool,
    force_hovered: bool,
    allow_hovered_id_match: bool,
) ?style.StyleOverride {
    const theme = state.theme.*;
    const flags = stateFlagsForNode(node, state, id, suppress_list_hover, force_hovered, allow_hovered_id_match);
    return theme.resolveEngineOverride(nodeKind(node), id, nodeClass(node), flags);
}

fn nodeStyleOverride(node: protocol.Node) ?style.StyleOverride {
    return switch (node) {
        .vbox => |v| v.style,
        .hbox => |h| h.style,
        .grid => |g| g.style,
        .box => |b| b.style,
        .scroll => |s| s.style,
        .overlay => |o| o.style,
        .text => |t| t.style,
        .styled_text => |t| t.style,
        .input => |i| i.style,
        .textarea => |t| t.style,
        .list => |l| l.style,
        .vlist => |l| l.style,
    };
}

fn nodeClass(node: protocol.Node) ?[]const u8 {
    return switch (node) {
        .vbox => |v| v.class,
        .hbox => |h| h.class,
        .grid => |g| g.class,
        .box => |b| b.class,
        .scroll => |s| s.class,
        .overlay => |o| o.class,
        .text => |t| t.class,
        .styled_text => |t| t.class,
        .input => |i| i.class,
        .textarea => |t| t.class,
        .list => |l| l.class,
        .vlist => |l| l.class,
    };
}

fn nodeKind(node: protocol.Node) theme_mod.NodeKind {
    return switch (node) {
        .vbox => .vbox,
        .hbox => .hbox,
        .grid => .grid,
        .box => .box,
        .scroll => .scroll,
        .overlay => .overlay,
        .text => .text,
        .styled_text => .styled_text,
        .input => .input,
        .textarea => .textarea,
        .list, .vlist => .list,
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

fn shouldShowScrollbar(enabled: bool, avail_w: usize, viewport_h: usize, content_h: usize) bool {
    return enabled and avail_w >= 2 and viewport_h > 0 and content_h > viewport_h;
}

fn scrollbarGlyphOrFallback(glyph: []const u8, fallback: []const u8) []const u8 {
    if (unicode.displayWidth(glyph) == 1) return glyph;
    return fallback;
}

fn scrollbarStyles(state: RenderState, inherited: style.Style) struct { track: style.PackedStyle, thumb: style.PackedStyle } {
    const base = inherited;
    const track_ov = state.theme.resolveEngineOverride(.text, "", "scrollbar.track", .{});
    const thumb_ov = state.theme.resolveEngineOverride(.text, "", "scrollbar.thumb", .{});
    return .{
        .track = style.pack(style.merge(base, track_ov)),
        .thumb = style.pack(style.merge(base, thumb_ov)),
    };
}

fn paintScrollbarColumn(
    frame: *Frame,
    track_rect: RectI,
    clip: RectI,
    thumb_top: usize,
    thumb_h: usize,
    track_style: style.PackedStyle,
    thumb_style: style.PackedStyle,
    track_glyph: []const u8,
    thumb_glyph: []const u8,
) void {
    if (track_rect.w == 0 or track_rect.h == 0) return;
    var row_i: usize = 0;
    while (row_i < track_rect.h) : (row_i += 1) {
        const row = track_rect.y + @as(isize, @intCast(row_i));
        const in_thumb = row_i >= thumb_top and row_i < thumb_top + thumb_h;
        render_text.putGraphemeClipped(
            frame,
            row,
            track_rect.x,
            if (in_thumb) thumb_glyph else track_glyph,
            1,
            clip,
            if (in_thumb) thumb_style else track_style,
        );
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
    const chrome = state.theme.chrome;
    const prefix = chrome.input_prefix;
    const prefix_cols: usize = unicode.displayWidth(prefix);
    const cols: usize = rect.w;
    const visible_cols: usize = if (cols > prefix_cols) cols - prefix_cols else 0;

    const base_style = inherited;
    const base_packed = style.pack(base_style);
    const ph_style = style.merge(base_style, i.placeholder_style);
    const ph_packed = style.pack(ph_style);
    const sel_style = if (i.selection_style) |ov|
        style.merge(base_style, ov)
    else
        style.overlayAttrs(base_style, style.ATTR_INVERSE, style.ATTR_INVERSE);
    const sel_packed = style.pack(sel_style);

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
    const sel_start: ?usize = st.selection_start;
    const sel_end: ?usize = st.selection_end;

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
            drawInlineTextWithSelectionAt(
                frame,
                row,
                col_abs,
                clip,
                visible,
                start,
                sel_start,
                sel_end,
                max_w,
                base_packed,
                sel_packed,
            );
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
                const left_bracket_w = unicode.displayWidth(chrome.input_placeholder_left);
                const right_bracket_w = unicode.displayWidth(chrome.input_placeholder_right);
                const content_cols: usize = left_bracket_w + right_bracket_w + ph_cols;
                const pad_left: usize = if (st.scroll_x == 0 and content_cols <= visible_cols)
                    hAlignOffset(visible_cols, content_cols, i.content_align)
                else
                    0;
                const col_abs: isize = rect.x + @as(isize, @intCast(prefix_cols + pad_left));
                const max_w: usize = if (visible_cols > pad_left) visible_cols - pad_left else 0;
                const one: u2 = 1;
                render_text.putGraphemeClipped(frame, row, col_abs, chrome.input_placeholder_left, one, clip, base_packed);
                drawInlineTextAt(frame, row, col_abs + @as(isize, @intCast(left_bracket_w)), clip, ph, if (max_w > left_bracket_w) max_w - left_bracket_w else 0, ph_packed);
                render_text.putGraphemeClipped(frame, row, col_abs + @as(isize, @intCast(left_bracket_w + ph_cols)), chrome.input_placeholder_right, one, clip, base_packed);
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
    const metrics = unicode.defaultTextMetrics();

    const focused = state.focused_id != null and std.mem.eql(u8, state.focused_id.?, t.id);
    const textarea_state = findTextareaState(state.textareas, t.id);

    const base_style = inherited;
    const base_packed = style.pack(base_style);
    const ph_style = style.merge(base_style, t.placeholder_style);
    const ph_packed = style.pack(ph_style);
    const sel_style = if (t.selection_style) |ov|
        style.merge(base_style, ov)
    else
        style.overlayAttrs(base_style, style.ATTR_INVERSE, style.ATTR_INVERSE);
    const sel_packed = style.pack(sel_style);

    const value: []const u8 = if (textarea_state) |st| st.value else "";
    const effective_cursor: usize = unicode.clampGraphemeBoundary(
        value,
        @min(if (textarea_state) |st| st.cursor else 0, value.len),
    );
    const scroll_y: usize = if (textarea_state) |st| st.scroll_y else 0;
    const sel_start: ?usize = if (textarea_state) |st| st.selection_start else null;
    const sel_end: ?usize = if (textarea_state) |st| st.selection_end else null;

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

    const content_h_no_bar = unicode.defaultTextMetrics().visualPosForByte(value, value.len, rect.w).y + 1;
    var show_bar = shouldShowScrollbar(state.scrolling.scrollbars_enabled, rect.w, rect.h, content_h_no_bar);
    var cols: usize = if (show_bar) rect.w - 1 else rect.w;
    const content_h = if (show_bar) unicode.defaultTextMetrics().visualPosForByte(value, value.len, cols).y + 1 else content_h_no_bar;
    if (show_bar and content_h <= rect.h) {
        show_bar = false;
        cols = rect.w;
    }
    const rows: usize = rect.h;
    const content_rect: RectI = .{
        .x = rect.x,
        .y = rect.y,
        .w = cols,
        .h = rect.h,
    };

    var cursor_vis_y: usize = 0;
    var cursor_vis_x: usize = 0;
    var cursor_found: bool = false;
    var last_vis_y: usize = 0;
    var last_vis_x: usize = 0;

    var wrap = metrics.wrapIter(value, cols);
    while (wrap.next()) |item| {
        if (!cursor_found and item.grapheme.start >= effective_cursor) {
            cursor_vis_y = item.row;
            cursor_vis_x = item.col;
            cursor_found = true;
        }

        if (item.row >= scroll_y and item.row < scroll_y + rows) {
            const b0: u8 = value[item.grapheme.start];
            const glyph: []const u8 = if (b0 == '\t') " " else value[item.grapheme.start..item.grapheme.end];
            const row: isize = content_rect.y + @as(isize, @intCast(item.row - scroll_y));
            const col_abs: isize = content_rect.x + @as(isize, @intCast(item.col));
            const selected = sel_start != null and sel_end != null and item.grapheme.start >= sel_start.? and item.grapheme.start < sel_end.?;
            render_text.putGraphemeClipped(
                frame,
                row,
                col_abs,
                glyph,
                item.width,
                clip,
                if (selected) sel_packed else base_packed,
            );
        }

        last_vis_y = item.row;
        last_vis_x = item.col + item.width;
    }

    if (!cursor_found) {
        const pos = metrics.visualPosForByte(value, effective_cursor, cols);
        cursor_vis_y = if (effective_cursor == value.len) @max(pos.y, last_vis_y) else pos.y;
        cursor_vis_x = if (effective_cursor == value.len and pos.y == last_vis_y) @max(pos.x, last_vis_x) else pos.x;
        cursor_found = true;
    }

    if (focused and cursor_out.* == null and cols != 0) {
        if (cursor_vis_y >= scroll_y and cursor_vis_y < scroll_y + rows) {
            const row: isize = content_rect.y + @as(isize, @intCast(cursor_vis_y - scroll_y));
            var col_abs: isize = content_rect.x + @as(isize, @intCast(cursor_vis_x));
            const rect_x2: isize = content_rect.x + @as(isize, @intCast(cols));
            if (col_abs >= rect_x2) col_abs = rect_x2 - 1;

            if (row >= clip.y and row < clip.y + @as(isize, @intCast(clip.h)) and col_abs >= clip.x and col_abs < clip.x + @as(isize, @intCast(clip.w)) and row >= 0 and col_abs >= 0) {
                cursor_out.* = .{
                    .row = @as(usize, @intCast(row + 1)),
                    .col = @as(usize, @intCast(col_abs + 1)),
                };
            }
        }
    }

    if (show_bar) {
        const min_thumb = @max(@as(usize, 1), @min(state.scrolling.scrollbar_min_thumb, rect.h));
        const geom = computeScrollbar(rect.h, content_h, rect.h, scroll_y, min_thumb);
        const styles = scrollbarStyles(state, inherited);
        const track_rect: RectI = .{
            .x = rect.x + @as(isize, @intCast(cols)),
            .y = rect.y,
            .w = 1,
            .h = rect.h,
        };
        const track_glyph = scrollbarGlyphOrFallback(state.theme.chrome.scrollbar_track_glyph, "|");
        const thumb_glyph = scrollbarGlyphOrFallback(state.theme.chrome.scrollbar_thumb_glyph, "#");
        paintScrollbarColumn(
            frame,
            track_rect,
            clip,
            geom.thumb_top,
            geom.thumb_h,
            styles.track,
            styles.thumb,
            track_glyph,
            thumb_glyph,
        );
    }
}

fn paintList(frame: *Frame, rect: RectI, clip: RectI, state: RenderState, l: protocol.ListNode, inherited: style.Style) void {
    if (rect.h == 0) return;
    const focused = state.focused_id != null and std.mem.eql(u8, state.focused_id.?, l.id);
    const list_state = findListState(state.lists, l.id);
    const selected_id = if (list_state) |st| st.selected_id else "";
    const scroll = if (list_state) |st| st.scroll else 0;
    const hovered_item = if (state.hovered_id != null and std.mem.eql(u8, state.hovered_id.?, l.id)) state.hovered_item else null;
    const chrome = state.theme.chrome;

    const list_style = inherited;
    const list_packed = style.pack(list_style);

    const desired_height: usize = l.height orelse rect.h;
    const height: usize = @min(desired_height, rect.h);
    const show_bar = shouldShowScrollbar(state.scrolling.scrollbars_enabled, rect.w, height, l.children.len);
    const content_w: usize = if (show_bar) rect.w - 1 else rect.w;
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
            .default => if (is_selected) (if (focused) chrome.list_selected_focused_marker else chrome.list_selected_marker) else chrome.list_unselected_marker,
        };
        var item_style = style.merge(list_style, resolveThemedOverride(item, state, item_id, true, is_hovered and !is_selected, false));
        item_style = style.merge(item_style, state.theme.resolveStyleOverrideVars(nodeStyleOverride(item)));
        var row_packed = style.pack(item_style);
        if (is_selected and chrome.list_selected_inverse) row_packed.attrs |= style.ATTR_INVERSE;

        const row: isize = rect.y + @as(isize, @intCast(row_idx));
        const y_end: isize = rect.y + @as(isize, @intCast(rect.h));
        if (row >= y_end) break;
        const row_rect: RectI = .{ .x = rect.x, .y = row, .w = content_w, .h = 1 };
        if (!packedEq(row_packed, list_packed) and row_packed.affectsBlank()) {
            fillRectStyle(frame, row_rect, clip, row_packed);
        }

        const prefix_cols: usize = unicode.displayWidth(prefix);
        const text_w: usize = if (row_rect.w > prefix_cols) row_rect.w - prefix_cols else 0;
        const content_x: isize = row_rect.x + @as(isize, @intCast(prefix_cols));

        switch (item) {
            .text => |t| {
                renderLinePiecesInRectStyled(frame, row, row_rect, clip, &.{prefix}, &.{row_packed});
                drawInlineTextWithOverflowAt(
                    frame,
                    row,
                    content_x,
                    clip,
                    t.text,
                    text_w,
                    t.overflow,
                    row_packed,
                );
            },
            .styled_text => |t| {
                renderLinePiecesInRectStyled(frame, row, row_rect, clip, &.{prefix}, &.{row_packed});
                drawInlineStyledSpansInRectWithEllipsis(
                    frame,
                    row,
                    row_rect,
                    clip,
                    t.spans,
                    item_style,
                    prefix_cols,
                    if (is_selected) style.ATTR_INVERSE else 0,
                    text_w,
                    t.overflow,
                );
            },
            else => {},
        }
    }

    if (show_bar) {
        const min_thumb = @max(@as(usize, 1), @min(state.scrolling.scrollbar_min_thumb, height));
        const geom = computeScrollbar(height, l.children.len, height, scroll, min_thumb);
        const styles = scrollbarStyles(state, inherited);
        const track_rect: RectI = .{
            .x = rect.x + @as(isize, @intCast(content_w)),
            .y = rect.y,
            .w = 1,
            .h = height,
        };
        const track_glyph = scrollbarGlyphOrFallback(state.theme.chrome.scrollbar_track_glyph, "|");
        const thumb_glyph = scrollbarGlyphOrFallback(state.theme.chrome.scrollbar_thumb_glyph, "#");
        paintScrollbarColumn(
            frame,
            track_rect,
            clip,
            geom.thumb_top,
            geom.thumb_h,
            styles.track,
            styles.thumb,
            track_glyph,
            thumb_glyph,
        );
    }
}

fn paintVList(frame: *Frame, rect: RectI, clip: RectI, state: RenderState, l: protocol.VListNode, inherited: style.Style) void {
    if (rect.h == 0 or l.total == 0) return;
    const focused = state.focused_id != null and std.mem.eql(u8, state.focused_id.?, l.id);
    const vlist_state = findVListState(state.vlists, l.id);
    const selected_index = if (vlist_state) |st| st.selected_index else l.selected_index;
    const scroll = if (vlist_state) |st| st.scroll else 0;
    const hovered_item = if (state.hovered_id != null and std.mem.eql(u8, state.hovered_id.?, l.id)) state.hovered_item else null;
    const chrome = state.theme.chrome;

    const list_style = inherited;
    const list_packed = style.pack(list_style);

    const desired_height: usize = l.height orelse rect.h;
    const height: usize = @min(desired_height, rect.h);
    const start: usize = @min(scroll, l.total);

    var row_idx: usize = 0;
    while (row_idx < height) : (row_idx += 1) {
        const index = start + row_idx;
        if (index >= l.total) break;

        var item_buf: [128]u8 = undefined;
        const item_id = std.fmt.bufPrint(&item_buf, "{s}{d}", .{ l.item_id_prefix, index }) catch "";
        const is_selected = selected_index != null and selected_index.? == index;
        const is_hovered = hovered_item != null and item_id.len > 0 and std.mem.eql(u8, hovered_item.?, item_id);

        const prefix = switch (l.marker) {
            .none => "",
            .default => if (is_selected) (if (focused) chrome.list_selected_focused_marker else chrome.list_selected_marker) else chrome.list_unselected_marker,
        };
        const row_style = style.merge(
            list_style,
            resolveThemedOverride(.{ .text = .{ .id = item_id, .text = "" } }, state, item_id, true, is_hovered and !is_selected, false),
        );
        var row_packed = style.pack(row_style);
        if (is_selected and chrome.list_selected_inverse) row_packed.attrs |= style.ATTR_INVERSE;

        const row: isize = rect.y + @as(isize, @intCast(row_idx));
        const y_end: isize = rect.y + @as(isize, @intCast(rect.h));
        if (row >= y_end) break;
        const row_rect: RectI = .{ .x = rect.x, .y = row, .w = rect.w, .h = 1 };
        if (!packedEq(row_packed, list_packed) and row_packed.affectsBlank()) {
            fillRectStyle(frame, row_rect, clip, row_packed);
        }

        const local_idx_opt: ?usize = if (index >= l.window_start and index < l.window_start + l.children.len) (index - l.window_start) else null;
        if (local_idx_opt == null) {
            renderLinePiecesInRectStyled(frame, row, row_rect, clip, &.{prefix}, &.{row_packed});
            continue;
        }

        const item = l.children[local_idx_opt.?];
        var item_style = style.merge(row_style, resolveThemedOverride(item, state, nodeId(item), true, is_hovered and !is_selected, false));
        item_style = style.merge(item_style, state.theme.resolveStyleOverrideVars(nodeStyleOverride(item)));
        switch (item) {
            .text => |t| {
                const item_packed = style.pack(item_style);
                const prefix_cols: usize = unicode.displayWidth(prefix);
                const content_w: usize = if (row_rect.w > prefix_cols) row_rect.w - prefix_cols else 0;
                renderLinePiecesInRectStyled(frame, row, row_rect, clip, &.{prefix}, &.{item_packed});
                drawInlineTextWithOverflowAt(
                    frame,
                    row,
                    row_rect.x + @as(isize, @intCast(prefix_cols)),
                    clip,
                    t.text,
                    content_w,
                    t.overflow,
                    item_packed,
                );
            },
            .styled_text => |t| {
                const item_packed = style.pack(item_style);
                const prefix_cols: usize = unicode.displayWidth(prefix);
                const content_w: usize = if (row_rect.w > prefix_cols) row_rect.w - prefix_cols else 0;
                renderLinePiecesInRectStyled(frame, row, row_rect, clip, &.{prefix}, &.{item_packed});
                drawInlineStyledSpansInRectWithEllipsis(
                    frame,
                    row,
                    row_rect,
                    clip,
                    t.spans,
                    item_style,
                    prefix_cols,
                    if (is_selected) style.ATTR_INVERSE else 0,
                    content_w,
                    t.overflow,
                );
            },
            else => renderLinePiecesInRectStyled(frame, row, row_rect, clip, &.{prefix}, &.{row_packed}),
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
    if (count > max_layout_children) {
        var y_fallback: isize = inner.y;
        for (v.children, 0..) |child, idx| {
            if (y_fallback >= y_end) break;
            if (child_clip.h != 0 and y_fallback >= clip_y_end) break;

            const eff_align = alignItemsEffective(child, v.align_items);
            const child_w = vboxChildWidth(inner.w, v.align_items, child);
            const child_x = vboxChildX(inner.x, inner.w, child_w, eff_align);
            var child_h = clampSize(measureHeight(child, child_w), nodeMinH(child), nodeMaxH(child));
            if (child_h > inner.h) child_h = inner.h;

            const child_y2: isize = y_fallback + @as(isize, @intCast(child_h));
            const clamped_h: usize = if (child_y2 <= y_end) child_h else if (y_end > y_fallback) @as(usize, @intCast(y_end - y_fallback)) else 0;
            if (clamped_h == 0) break;

            const child_rect: RectI = .{ .x = child_x, .y = y_fallback, .w = child_w, .h = clamped_h };
            const rect_y2: isize = child_rect.y + @as(isize, @intCast(child_rect.h));
            if (child_clip.h != 0 and rect_y2 <= child_clip.y) {
                y_fallback += @as(isize, @intCast(clamped_h));
            } else {
                paintNode(frame, child, child_rect, child_clip, state, cursor_out, inherited, mode);
                y_fallback += @as(isize, @intCast(clamped_h));
            }
            if (idx + 1 < count) y_fallback += @as(isize, @intCast(v.gap));
        }
        return;
    }
    var child_widths: [max_layout_children]usize = undefined;
    var child_heights: [max_layout_children]usize = undefined;
    var extra_space: usize = 0;
    var have_alloc = false;
    if (count <= max_layout_children) {
        for (v.children, 0..) |child, idx| {
            child_widths[idx] = vboxChildWidth(inner.w, v.align_items, child);
        }
        if (computeVBoxHeights(
            v.children,
            inner.h,
            v.gap,
            mode,
            child_widths[0..count],
            child_heights[0..count],
        )) |extra| {
            extra_space = extra;
            have_alloc = true;
        }
    }
    if (!have_alloc) {
        for (v.children, 0..) |child, idx| {
            child_widths[idx] = vboxChildWidth(inner.w, v.align_items, child);
            child_heights[idx] = clampSize(measureHeight(child, child_widths[idx]), nodeMinH(child), nodeMaxH(child));
            if (child_heights[idx] > inner.h) child_heights[idx] = inner.h;
        }
    }

    var y: isize = inner.y + @as(isize, @intCast(justifyStartOffset(v.justify_content, count, extra_space)));

    for (v.children, 0..) |child, idx| {
        if (y >= y_end) break;
        if (child_clip.h != 0 and y >= clip_y_end) break;

        const eff_align = alignItemsEffective(child, v.align_items);
        const child_w = child_widths[idx];
        const child_x = vboxChildX(inner.x, inner.w, child_w, eff_align);
        const child_h = child_heights[idx];

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
    var child_widths: [max_layout_children]usize = undefined;
    if (!computeHBoxWidths(h.children, inner.w, h.gap, child_widths[0..count])) {
        for (h.children, 0..) |child, idx| {
            child_widths[idx] = singleChildWidthHint(inner.w, child);
        }
    }

    var used_w: usize = gaps_total;
    var total_flex: usize = 0;
    for (h.children, 0..) |child, idx| {
        used_w += child_widths[idx];
        total_flex += nodeFlex(child);
    }
    const remaining_for_justify: usize = if (inner.w > used_w) inner.w - used_w else 0;
    const extra_space: usize = if (mode == .bounded and total_flex == 0) remaining_for_justify else 0;

    var x: isize = inner.x + @as(isize, @intCast(justifyStartOffset(h.justify_content, count, extra_space)));
    for (h.children, 0..) |child, idx| {
        const child_w = child_widths[idx];
        const eff_align = alignItemsEffective(child, h.align_items);
        const child_h = hboxChildHeight(inner.h, h.align_items, child);
        const child_y = hboxChildY(inner.y, inner.h, child_h, eff_align);

        const child_rect: RectI = .{ .x = x, .y = child_y, .w = child_w, .h = child_h };
        paintNode(frame, child, child_rect, child_clip, state, cursor_out, inherited, mode);
        x += @as(isize, @intCast(child_w));

        if (idx + 1 < count) {
            const gap = h.gap + justifyGapExtra(h.justify_content, count, extra_space, idx);
            x += @as(isize, @intCast(gap));
        }
    }
}

fn paintGrid(
    frame: *Frame,
    rect: RectI,
    clip: RectI,
    state: RenderState,
    cursor_out: *?CursorPos,
    g: protocol.GridNode,
    inherited: style.Style,
    mode: VBoxMode,
) void {
    _ = mode;
    const inner = rectDeflate(rect, g.pad);
    if (inner.w == 0 or inner.h == 0) return;
    const base_clip = rectIntersect(clip, rect);
    const child_clip = if (g.clip) rectIntersect(base_clip, inner) else base_clip;

    const rows_n = @min(g.rows.len, max_grid_tracks);
    const cols_n = @min(g.cols.len, max_grid_tracks);
    if (rows_n == 0 or cols_n == 0) return;

    var col_auto: [max_grid_tracks]usize = undefined;
    var row_auto: [max_grid_tracks]usize = undefined;
    var col_sizes: [max_grid_tracks]usize = undefined;
    var row_sizes: [max_grid_tracks]usize = undefined;
    @memset(col_auto[0..cols_n], 1);
    @memset(row_auto[0..rows_n], 1);
    @memset(col_sizes[0..cols_n], 0);
    @memset(row_sizes[0..rows_n], 0);

    for (g.children, 0..) |child, idx| {
        const p = resolveGridPlacement(g, child, idx, rows_n, cols_n);
        if (p.col_span == 1 and p.col < cols_n) {
            const w = applyMinMax(computeHintW(child, inner.w), nodeMinW(child), nodeMaxW(child)) orelse measureMinWidth(child);
            if (w > col_auto[p.col]) col_auto[p.col] = w;
        }
    }
    computeTrackSizes(g.cols[0..cols_n], col_auto[0..cols_n], inner.w, g.gap_x, col_sizes[0..cols_n]);

    for (g.children, 0..) |child, idx| {
        const p = resolveGridPlacement(g, child, idx, rows_n, cols_n);
        if (p.row_span == 1 and p.row < rows_n) {
            const cw = spanSize(col_sizes[0..cols_n], g.gap_x, p.col, p.col_span);
            const h = applyMinMax(computeHintH(child, inner.h), nodeMinH(child), nodeMaxH(child)) orelse measureHeight(child, cw);
            if (h > row_auto[p.row]) row_auto[p.row] = h;
        }
    }
    computeTrackSizes(g.rows[0..rows_n], row_auto[0..rows_n], inner.h, g.gap_y, row_sizes[0..rows_n]);

    for (g.children, 0..) |child, idx| {
        const p = resolveGridPlacement(g, child, idx, rows_n, cols_n);
        const x = inner.x + @as(isize, @intCast(trackOffset(col_sizes[0..cols_n], g.gap_x, p.col)));
        const y = inner.y + @as(isize, @intCast(trackOffset(row_sizes[0..rows_n], g.gap_y, p.row)));
        const w = spanSize(col_sizes[0..cols_n], g.gap_x, p.col, p.col_span);
        const h = spanSize(row_sizes[0..rows_n], g.gap_y, p.row, p.row_span);
        if (w == 0 or h == 0) continue;
        paintNode(frame, child, .{ .x = x, .y = y, .w = w, .h = h }, child_clip, state, cursor_out, inherited, .bounded);
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
    const node_rect = clampRectToNodeMax(rect, node);
    const node_clip = rectIntersect(clip, node_rect);
    if (node_clip.w == 0 or node_clip.h == 0) return;

    const own_override = state.theme.resolveStyleOverrideVars(nodeStyleOverride(node));
    const suppress_list_hover = switch (node) {
        .list, .vlist => true,
        else => false,
    };
    const themed_override = resolveThemedOverride(node, state, nodeId(node), suppress_list_hover, false, true);
    const base_resolved = style.merge(inherited, themed_override);
    const resolved = style.merge(base_resolved, own_override);
    const inherited_packed = style.pack(inherited);
    const resolved_packed = style.pack(resolved);
    if (!packedEq(resolved_packed, inherited_packed) and resolved_packed.affectsBlank()) {
        fillRectStyle(frame, node_rect, node_clip, resolved_packed);
    }

    switch (node) {
        .text => |t| render_text.drawWrappedTextInRectAligned(frame, node_rect, node_clip, t.text, resolved_packed, t.ext_align, t.v_align),
        .styled_text => |t| render_text.drawWrappedStyledSpansInRectAligned(frame, node_rect, node_clip, t.spans, resolved, 0, t.ext_align, t.v_align),
        .input => |i| paintInput(frame, node_rect, node_clip, state, cursor_out, i, resolved),
        .textarea => |t| paintTextarea(frame, node_rect, node_clip, state, cursor_out, t, resolved),
        .list => |l| paintList(frame, node_rect, node_clip, state, l, resolved),
        .vlist => |l| paintVList(frame, node_rect, node_clip, state, l, resolved),
        .vbox => |v| paintVBox(frame, node_rect, node_clip, state, cursor_out, v, resolved, mode),
        .hbox => |h| paintHBox(frame, node_rect, node_clip, state, cursor_out, h, resolved, mode),
        .grid => |g| paintGrid(frame, node_rect, node_clip, state, cursor_out, g, resolved, mode),
        .box => |b| paintBox(frame, node_rect, clip, state, cursor_out, b, resolved, mode),
        .scroll => |s| paintScroll(frame, node_rect, node_clip, state, cursor_out, s, resolved),
        .overlay => |o| paintOverlay(frame, node_rect, node_clip, state, cursor_out, o, resolved, mode),
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
    const inset: usize = border_thickness + b.pad;

    const inner = rectDeflate(rect, inset);
    const base_clip = node_clip;
    const child_clip = if (b.clip) rectIntersect(base_clip, inner) else base_clip;

    if (inner.w != 0 and inner.h != 0) {
        const child_w = singleChildWidthHint(inner.w, b.child.*);
        const child_h = singleChildHeightHint(inner.h, b.child.*);
        const child_rect: RectI = .{ .x = inner.x, .y = inner.y, .w = child_w, .h = child_h };
        paintNode(frame, b.child.*, child_rect, child_clip, state, cursor_out, inherited, mode);
    }

    const resolved_packed = style.pack(inherited);

    if (border_thickness == 1) {
        const x0: isize = rect.x;
        const y0: isize = rect.y;
        const x1: isize = rect.x + @as(isize, @intCast(rect.w)) - 1;
        const y1: isize = rect.y + @as(isize, @intCast(rect.h)) - 1;

        const one: u2 = 1;
        const chrome_cfg = state.theme.chrome;
        render_text.putGraphemeClipped(frame, y0, x0, chrome_cfg.box_top_left, one, node_clip, resolved_packed);
        render_text.putGraphemeClipped(frame, y0, x1, chrome_cfg.box_top_right, one, node_clip, resolved_packed);
        render_text.putGraphemeClipped(frame, y1, x0, chrome_cfg.box_bottom_left, one, node_clip, resolved_packed);
        render_text.putGraphemeClipped(frame, y1, x1, chrome_cfg.box_bottom_right, one, node_clip, resolved_packed);

        var x: isize = x0 + 1;
        while (x < x1) : (x += 1) {
            render_text.putGraphemeClipped(frame, y0, x, chrome_cfg.box_horizontal, one, node_clip, resolved_packed);
            render_text.putGraphemeClipped(frame, y1, x, chrome_cfg.box_horizontal, one, node_clip, resolved_packed);
        }

        var y: isize = y0 + 1;
        while (y < y1) : (y += 1) {
            render_text.putGraphemeClipped(frame, y, x0, chrome_cfg.box_vertical, one, node_clip, resolved_packed);
            render_text.putGraphemeClipped(frame, y, x1, chrome_cfg.box_vertical, one, node_clip, resolved_packed);
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

    const base_w = singleChildWidthHint(inner.w, o.base.*);
    const base_h = singleChildHeightHint(inner.h, o.base.*);
    const base_rect: RectI = .{ .x = inner.x, .y = inner.y, .w = base_w, .h = base_h };
    paintNode(frame, o.base.*, base_rect, child_clip, state, cursor_out, inherited, mode);

    const screen = screenRect(frame);
    const max_layer_rects: usize = 32;
    var computed_layer_rects: [max_layer_rects]RectI = undefined;

    var i: usize = 0;
    while (i < o.layers.len and i < max_layer_rects) : (i += 1) {
        const layer = o.layers[i];
        const layer_rect = computeOverlayLayerRectForBaseRect(
            screen,
            rect,
            base_rect,
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
            base_rect,
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
    const content_h_no_bar: usize = if (st) |ss| ss.content_h else measureHeight(s.child.*, singleChildWidthHint(inner.w, s.child.*));
    var show_bar = shouldShowScrollbar(state.scrolling.scrollbars_enabled, inner.w, inner.h, content_h_no_bar);
    var content_w: usize = if (show_bar) inner.w - 1 else inner.w;
    var content_h: usize = if (show_bar) measureHeight(s.child.*, singleChildWidthHint(content_w, s.child.*)) else content_h_no_bar;
    if (show_bar and content_h <= inner.h) {
        show_bar = false;
        content_w = inner.w;
        content_h = content_h_no_bar;
    }

    const dy: isize = @as(isize, @intCast(@min(scroll_y, @as(usize, std.math.maxInt(isize)))));
    const child_w = singleChildWidthHint(content_w, s.child.*);
    const child_rect: RectI = .{
        .x = inner.x,
        .y = inner.y - dy,
        .w = child_w,
        .h = content_h,
    };
    paintNode(frame, s.child.*, child_rect, child_clip, state, cursor_out, inherited, .unbounded);

    if (show_bar) {
        const min_thumb = @max(@as(usize, 1), @min(state.scrolling.scrollbar_min_thumb, inner.h));
        const geom = computeScrollbar(inner.h, content_h, inner.h, scroll_y, min_thumb);
        const styles = scrollbarStyles(state, inherited);
        const track_rect: RectI = .{
            .x = inner.x + @as(isize, @intCast(content_w)),
            .y = inner.y,
            .w = 1,
            .h = inner.h,
        };
        const track_glyph = scrollbarGlyphOrFallback(state.theme.chrome.scrollbar_track_glyph, "|");
        const thumb_glyph = scrollbarGlyphOrFallback(state.theme.chrome.scrollbar_thumb_glyph, "#");
        paintScrollbarColumn(
            frame,
            track_rect,
            child_clip,
            geom.thumb_top,
            geom.thumb_h,
            styles.track,
            styles.thumb,
            track_glyph,
            thumb_glyph,
        );
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

fn findVListState(vlists: []const VListState, id: []const u8) ?VListState {
    var lo: usize = 0;
    var hi: usize = vlists.len;
    while (lo < hi) {
        const mid: usize = lo + (hi - lo) / 2;
        const st = vlists[mid];
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
    const node_rect = clampRectToNodeMax(rect, node);
    if (node_rect.w == 0 or node_rect.h == 0) return null;
    if (std.mem.eql(u8, nodeId(node), id)) return node_rect;

    switch (node) {
        .vbox => |v| {
            const inner = rectDeflate(node_rect, v.pad);
            const y_end: isize = inner.y + @as(isize, @intCast(inner.h));

            const count: usize = v.children.len;
            if (count == 0) return null;
            if (count > max_layout_children) {
                var y_fallback: isize = inner.y;
                for (v.children, 0..) |child, idx| {
                    if (y_fallback >= y_end) break;
                    const eff_align = alignItemsEffective(child, v.align_items);
                    const child_w = vboxChildWidth(inner.w, v.align_items, child);
                    const child_x = vboxChildX(inner.x, inner.w, child_w, eff_align);
                    var child_h = clampSize(measureHeight(child, child_w), nodeMinH(child), nodeMaxH(child));
                    if (child_h > inner.h) child_h = inner.h;
                    const child_y2: isize = y_fallback + @as(isize, @intCast(child_h));
                    const clamped_h: usize = if (child_y2 <= y_end) child_h else if (y_end > y_fallback) @as(usize, @intCast(y_end - y_fallback)) else 0;
                    if (clamped_h == 0) break;
                    const child_rect: RectI = .{ .x = child_x, .y = y_fallback, .w = child_w, .h = clamped_h };
                    if (findRectInNodeI(child, child_rect, id, scrolls, mode, screen)) |r| return r;
                    y_fallback += @as(isize, @intCast(clamped_h));
                    if (idx + 1 < count) y_fallback += @as(isize, @intCast(v.gap));
                }
                return null;
            }

            var child_widths: [max_layout_children]usize = undefined;
            var child_heights: [max_layout_children]usize = undefined;
            for (v.children, 0..) |child, idx| {
                child_widths[idx] = vboxChildWidth(inner.w, v.align_items, child);
            }
            const extra_space = computeVBoxHeights(
                v.children,
                inner.h,
                v.gap,
                mode,
                child_widths[0..count],
                child_heights[0..count],
            ) orelse 0;

            var y: isize = inner.y + @as(isize, @intCast(justifyStartOffset(v.justify_content, count, extra_space)));
            for (v.children, 0..) |child, idx| {
                if (y >= y_end) break;

                const eff_align = alignItemsEffective(child, v.align_items);
                const child_w = child_widths[idx];
                const child_x = vboxChildX(inner.x, inner.w, child_w, eff_align);
                const child_h = child_heights[idx];

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
            const inner = rectDeflate(node_rect, h.pad);
            const x_end: isize = inner.x + @as(isize, @intCast(inner.w));

            const count: usize = h.children.len;
            if (count == 0) return null;

            if (count > max_layout_children) {
                var x_fallback: isize = inner.x;
                for (h.children, 0..) |child, idx| {
                    if (x_fallback >= x_end) break;
                    const child_w = singleChildWidthHint(inner.w, child);
                    const child_x2: isize = x_fallback + @as(isize, @intCast(child_w));
                    const clamped_w: usize = if (child_x2 <= x_end) child_w else if (x_end > x_fallback) @as(usize, @intCast(x_end - x_fallback)) else 0;
                    if (clamped_w == 0) break;
                    const eff_align = alignItemsEffective(child, h.align_items);
                    const child_h = hboxChildHeight(inner.h, h.align_items, child);
                    const child_y = hboxChildY(inner.y, inner.h, child_h, eff_align);
                    const child_rect: RectI = .{ .x = x_fallback, .y = child_y, .w = clamped_w, .h = child_h };
                    if (findRectInNodeI(child, child_rect, id, scrolls, mode, screen)) |r| return r;
                    x_fallback += @as(isize, @intCast(clamped_w));
                    if (idx + 1 < count) x_fallback += @as(isize, @intCast(h.gap));
                }
                return null;
            }

            const gaps_total: usize = if (count > 1) h.gap * (count - 1) else 0;
            var child_widths: [max_layout_children]usize = undefined;
            if (!computeHBoxWidths(h.children, inner.w, h.gap, child_widths[0..count])) {
                for (h.children, 0..) |child, idx| child_widths[idx] = singleChildWidthHint(inner.w, child);
            }

            var used_w: usize = gaps_total;
            var total_flex: usize = 0;
            for (h.children, 0..) |child, idx| {
                used_w += child_widths[idx];
                total_flex += nodeFlex(child);
            }
            const remaining_for_justify: usize = if (inner.w > used_w) inner.w - used_w else 0;
            const extra_space: usize = if (mode == .bounded and total_flex == 0) remaining_for_justify else 0;

            var x: isize = inner.x + @as(isize, @intCast(justifyStartOffset(h.justify_content, count, extra_space)));
            for (h.children, 0..) |child, idx| {
                if (x >= x_end) break;
                const child_w = child_widths[idx];
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
        .grid => |g| {
            const inner = rectDeflate(node_rect, g.pad);
            const rows_n = @min(g.rows.len, max_grid_tracks);
            const cols_n = @min(g.cols.len, max_grid_tracks);
            if (rows_n == 0 or cols_n == 0) return null;

            var col_auto: [max_grid_tracks]usize = undefined;
            var row_auto: [max_grid_tracks]usize = undefined;
            var col_sizes: [max_grid_tracks]usize = undefined;
            var row_sizes: [max_grid_tracks]usize = undefined;
            @memset(col_auto[0..cols_n], 1);
            @memset(row_auto[0..rows_n], 1);
            @memset(col_sizes[0..cols_n], 0);
            @memset(row_sizes[0..rows_n], 0);

            for (g.children, 0..) |child, idx| {
                const p = resolveGridPlacement(g, child, idx, rows_n, cols_n);
                if (p.col_span == 1 and p.col < cols_n) {
                    const w = applyMinMax(computeHintW(child, inner.w), nodeMinW(child), nodeMaxW(child)) orelse measureMinWidth(child);
                    if (w > col_auto[p.col]) col_auto[p.col] = w;
                }
            }
            computeTrackSizes(g.cols[0..cols_n], col_auto[0..cols_n], inner.w, g.gap_x, col_sizes[0..cols_n]);

            for (g.children, 0..) |child, idx| {
                const p = resolveGridPlacement(g, child, idx, rows_n, cols_n);
                if (p.row_span == 1 and p.row < rows_n) {
                    const cw = spanSize(col_sizes[0..cols_n], g.gap_x, p.col, p.col_span);
                    const h = applyMinMax(computeHintH(child, inner.h), nodeMinH(child), nodeMaxH(child)) orelse measureHeight(child, cw);
                    if (h > row_auto[p.row]) row_auto[p.row] = h;
                }
            }
            computeTrackSizes(g.rows[0..rows_n], row_auto[0..rows_n], inner.h, g.gap_y, row_sizes[0..rows_n]);

            for (g.children, 0..) |child, idx| {
                const p = resolveGridPlacement(g, child, idx, rows_n, cols_n);
                const child_rect: RectI = .{
                    .x = inner.x + @as(isize, @intCast(trackOffset(col_sizes[0..cols_n], g.gap_x, p.col))),
                    .y = inner.y + @as(isize, @intCast(trackOffset(row_sizes[0..rows_n], g.gap_y, p.row))),
                    .w = spanSize(col_sizes[0..cols_n], g.gap_x, p.col, p.col_span),
                    .h = spanSize(row_sizes[0..rows_n], g.gap_y, p.row, p.row_span),
                };
                if (findRectInNodeI(child, child_rect, id, scrolls, .bounded, screen)) |r| return r;
            }
            return null;
        },
        .box => |b| {
            const border_thickness: usize = if (b.border and node_rect.w >= 2 and node_rect.h >= 2) 1 else 0;
            const chrome: usize = border_thickness + b.pad;
            const inner = rectDeflate(node_rect, chrome);
            const child_rect: RectI = .{
                .x = inner.x,
                .y = inner.y,
                .w = singleChildWidthHint(inner.w, b.child.*),
                .h = singleChildHeightHint(inner.h, b.child.*),
            };
            return findRectInNodeI(b.child.*, child_rect, id, scrolls, mode, screen);
        },
        .scroll => |s| {
            const inner = rectDeflate(node_rect, s.pad);
            const st = findScrollStateUnsorted(scrolls, s.id);
            const scroll_y: usize = if (st) |ss| ss.scroll_y else 0;
            const child_w = singleChildWidthHint(inner.w, s.child.*);
            const content_h: usize = if (st) |ss| ss.content_h else measureHeight(s.child.*, child_w);

            const dy: isize = @as(isize, @intCast(@min(scroll_y, @as(usize, std.math.maxInt(isize)))));
            const child_rect: RectI = .{
                .x = inner.x,
                .y = inner.y - dy,
                .w = child_w,
                .h = content_h,
            };
            return findRectInNodeI(s.child.*, child_rect, id, scrolls, .unbounded, screen);
        },
        .overlay => |o| {
            const inner = rectDeflate(node_rect, o.pad);
            const base_rect: RectI = .{
                .x = inner.x,
                .y = inner.y,
                .w = singleChildWidthHint(inner.w, o.base.*),
                .h = singleChildHeightHint(inner.h, o.base.*),
            };
            if (findRectInNodeI(o.base.*, base_rect, id, scrolls, mode, screen)) |r| return r;

            const max_layer_rects: usize = 32;
            var computed_layer_rects: [max_layer_rects]RectI = undefined;

            var i: usize = 0;
            while (i < o.layers.len and i < max_layer_rects) : (i += 1) {
                const layer = o.layers[i];
                const layer_rect = computeOverlayLayerRectForBaseRect(
                    screen,
                    node_rect,
                    base_rect,
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
                    node_rect,
                    base_rect,
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
    const node_rect = clampRectToNodeMax(rect, node);
    if (node_rect.w == 0 or node_rect.h == 0) return null;
    if (std.mem.eql(u8, nodeId(node), id)) return node_rect;

    switch (node) {
        .vbox => |v| {
            const inner = rectDeflate(node_rect, v.pad);
            const y_end: isize = inner.y + @as(isize, @intCast(inner.h));

            const count: usize = v.children.len;
            if (count == 0) return null;
            if (count > max_layout_children) {
                var y_fallback: isize = inner.y;
                for (v.children, 0..) |child, idx| {
                    if (y_fallback >= y_end) break;
                    const eff_align = alignItemsEffective(child, v.align_items);
                    const child_w = vboxChildWidth(inner.w, v.align_items, child);
                    const child_x = vboxChildX(inner.x, inner.w, child_w, eff_align);
                    var child_h = clampSize(measureHeight(child, child_w), nodeMinH(child), nodeMaxH(child));
                    if (child_h > inner.h) child_h = inner.h;
                    const child_y2: isize = y_fallback + @as(isize, @intCast(child_h));
                    const clamped_h: usize = if (child_y2 <= y_end) child_h else if (y_end > y_fallback) @as(usize, @intCast(y_end - y_fallback)) else 0;
                    if (clamped_h == 0) break;
                    const child_rect: RectI = .{ .x = child_x, .y = y_fallback, .w = child_w, .h = clamped_h };
                    if (findRectInNodeIBaseOnly(child, child_rect, id, scrolls, mode)) |r| return r;
                    y_fallback += @as(isize, @intCast(clamped_h));
                    if (idx + 1 < count) y_fallback += @as(isize, @intCast(v.gap));
                }
                return null;
            }

            var child_widths: [max_layout_children]usize = undefined;
            var child_heights: [max_layout_children]usize = undefined;
            for (v.children, 0..) |child, idx| {
                child_widths[idx] = vboxChildWidth(inner.w, v.align_items, child);
            }
            const extra_space = computeVBoxHeights(
                v.children,
                inner.h,
                v.gap,
                mode,
                child_widths[0..count],
                child_heights[0..count],
            ) orelse 0;

            var y: isize = inner.y + @as(isize, @intCast(justifyStartOffset(v.justify_content, count, extra_space)));
            for (v.children, 0..) |child, idx| {
                if (y >= y_end) break;

                const eff_align = alignItemsEffective(child, v.align_items);
                const child_w = child_widths[idx];
                const child_x = vboxChildX(inner.x, inner.w, child_w, eff_align);
                const child_h = child_heights[idx];

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
            const inner = rectDeflate(node_rect, h.pad);
            const x_end: isize = inner.x + @as(isize, @intCast(inner.w));

            const count: usize = h.children.len;
            if (count == 0) return null;

            if (count > max_layout_children) {
                var x_fallback: isize = inner.x;
                for (h.children, 0..) |child, idx| {
                    if (x_fallback >= x_end) break;
                    const child_w = singleChildWidthHint(inner.w, child);
                    const child_x2: isize = x_fallback + @as(isize, @intCast(child_w));
                    const clamped_w: usize = if (child_x2 <= x_end) child_w else if (x_end > x_fallback) @as(usize, @intCast(x_end - x_fallback)) else 0;
                    if (clamped_w == 0) break;
                    const eff_align = alignItemsEffective(child, h.align_items);
                    const child_h = hboxChildHeight(inner.h, h.align_items, child);
                    const child_y = hboxChildY(inner.y, inner.h, child_h, eff_align);
                    const child_rect: RectI = .{ .x = x_fallback, .y = child_y, .w = clamped_w, .h = child_h };
                    if (findRectInNodeIBaseOnly(child, child_rect, id, scrolls, mode)) |r| return r;
                    x_fallback += @as(isize, @intCast(clamped_w));
                    if (idx + 1 < count) x_fallback += @as(isize, @intCast(h.gap));
                }
                return null;
            }

            const gaps_total: usize = if (count > 1) h.gap * (count - 1) else 0;
            var child_widths: [max_layout_children]usize = undefined;
            if (!computeHBoxWidths(h.children, inner.w, h.gap, child_widths[0..count])) {
                for (h.children, 0..) |child, idx| child_widths[idx] = singleChildWidthHint(inner.w, child);
            }

            var used_w: usize = gaps_total;
            var total_flex: usize = 0;
            for (h.children, 0..) |child, idx| {
                used_w += child_widths[idx];
                total_flex += nodeFlex(child);
            }
            const remaining_for_justify: usize = if (inner.w > used_w) inner.w - used_w else 0;
            const extra_space: usize = if (mode == .bounded and total_flex == 0) remaining_for_justify else 0;

            var x: isize = inner.x + @as(isize, @intCast(justifyStartOffset(h.justify_content, count, extra_space)));
            for (h.children, 0..) |child, idx| {
                if (x >= x_end) break;
                const child_w = child_widths[idx];
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
        .grid => |g| {
            const inner = rectDeflate(node_rect, g.pad);
            const rows_n = @min(g.rows.len, max_grid_tracks);
            const cols_n = @min(g.cols.len, max_grid_tracks);
            if (rows_n == 0 or cols_n == 0) return null;

            var col_auto: [max_grid_tracks]usize = undefined;
            var row_auto: [max_grid_tracks]usize = undefined;
            var col_sizes: [max_grid_tracks]usize = undefined;
            var row_sizes: [max_grid_tracks]usize = undefined;
            @memset(col_auto[0..cols_n], 1);
            @memset(row_auto[0..rows_n], 1);
            @memset(col_sizes[0..cols_n], 0);
            @memset(row_sizes[0..rows_n], 0);

            for (g.children, 0..) |child, idx| {
                const p = resolveGridPlacement(g, child, idx, rows_n, cols_n);
                if (p.col_span == 1 and p.col < cols_n) {
                    const w = applyMinMax(computeHintW(child, inner.w), nodeMinW(child), nodeMaxW(child)) orelse measureMinWidth(child);
                    if (w > col_auto[p.col]) col_auto[p.col] = w;
                }
            }
            computeTrackSizes(g.cols[0..cols_n], col_auto[0..cols_n], inner.w, g.gap_x, col_sizes[0..cols_n]);

            for (g.children, 0..) |child, idx| {
                const p = resolveGridPlacement(g, child, idx, rows_n, cols_n);
                if (p.row_span == 1 and p.row < rows_n) {
                    const cw = spanSize(col_sizes[0..cols_n], g.gap_x, p.col, p.col_span);
                    const h = applyMinMax(computeHintH(child, inner.h), nodeMinH(child), nodeMaxH(child)) orelse measureHeight(child, cw);
                    if (h > row_auto[p.row]) row_auto[p.row] = h;
                }
            }
            computeTrackSizes(g.rows[0..rows_n], row_auto[0..rows_n], inner.h, g.gap_y, row_sizes[0..rows_n]);

            for (g.children, 0..) |child, idx| {
                const p = resolveGridPlacement(g, child, idx, rows_n, cols_n);
                const child_rect: RectI = .{
                    .x = inner.x + @as(isize, @intCast(trackOffset(col_sizes[0..cols_n], g.gap_x, p.col))),
                    .y = inner.y + @as(isize, @intCast(trackOffset(row_sizes[0..rows_n], g.gap_y, p.row))),
                    .w = spanSize(col_sizes[0..cols_n], g.gap_x, p.col, p.col_span),
                    .h = spanSize(row_sizes[0..rows_n], g.gap_y, p.row, p.row_span),
                };
                if (findRectInNodeIBaseOnly(child, child_rect, id, scrolls, .bounded)) |r| return r;
            }
            return null;
        },
        .box => |b| {
            const border_thickness: usize = if (b.border and node_rect.w >= 2 and node_rect.h >= 2) 1 else 0;
            const chrome: usize = border_thickness + b.pad;
            const inner = rectDeflate(node_rect, chrome);
            const child_rect: RectI = .{
                .x = inner.x,
                .y = inner.y,
                .w = singleChildWidthHint(inner.w, b.child.*),
                .h = singleChildHeightHint(inner.h, b.child.*),
            };
            return findRectInNodeIBaseOnly(b.child.*, child_rect, id, scrolls, mode);
        },
        .scroll => |s| {
            const inner = rectDeflate(node_rect, s.pad);
            const st = findScrollStateUnsorted(scrolls, s.id);
            const scroll_y: usize = if (st) |ss| ss.scroll_y else 0;
            const child_w = singleChildWidthHint(inner.w, s.child.*);
            const content_h: usize = if (st) |ss| ss.content_h else measureHeight(s.child.*, child_w);

            const dy: isize = @as(isize, @intCast(@min(scroll_y, @as(usize, std.math.maxInt(isize)))));
            const child_rect: RectI = .{
                .x = inner.x,
                .y = inner.y - dy,
                .w = child_w,
                .h = content_h,
            };
            return findRectInNodeIBaseOnly(s.child.*, child_rect, id, scrolls, .unbounded);
        },
        .overlay => |o| {
            const inner = rectDeflate(node_rect, o.pad);
            const base_rect: RectI = .{
                .x = inner.x,
                .y = inner.y,
                .w = singleChildWidthHint(inner.w, o.base.*),
                .h = singleChildHeightHint(inner.h, o.base.*),
            };
            return findRectInNodeIBaseOnly(o.base.*, base_rect, id, scrolls, mode);
        },
        else => return null,
    }
}

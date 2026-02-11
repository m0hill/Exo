const std = @import("std");

const tui = @import("tui");
const protocol = tui.protocol;
const render = tui.render;
const renderer = tui.renderer;
const Frame = tui.frame.Frame;

pub const max_selection_bytes: usize = 16 * 1024;

pub const SelectionText = struct {
    bytes: []u8,
    truncated: bool,
};

pub const CommitResult = struct {
    consumed: bool = false,
    changed: bool = false,
    text: ?SelectionText = null,
    event: ?protocol.SelectionEvent = null,
};

const Point = struct {
    x: usize,
    y: usize,
};

const Hit = struct {
    id: []const u8,
    rect: render.Rect,
    clip_id: []const u8,
    clip_rect: render.Rect,
};

pub const DocumentSelectionEngine = struct {
    active: bool = false,
    has_selection: bool = false,
    clip_id_buf: std.ArrayList(u8) = .empty,
    clip_rect: render.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    a: Point = .{ .x = 0, .y = 0 },
    b: Point = .{ .x = 0, .y = 0 },

    last_commit_hash: u64 = 0,
    last_commit_len: usize = 0,
    has_last_commit: bool = false,

    last_click_ns: u64 = 0,
    last_click_count: u8 = 0,
    last_click_x: usize = 0,
    last_click_y: usize = 0,
    last_click_clip_hash: u64 = 0,

    pub fn deinit(self: *DocumentSelectionEngine, allocator: std.mem.Allocator) void {
        self.clip_id_buf.deinit(allocator);
    }

    pub fn clear(self: *DocumentSelectionEngine) void {
        self.active = false;
        self.has_selection = false;
        self.clip_id_buf.clearRetainingCapacity();
    }

    pub fn clipId(self: *const DocumentSelectionEngine) []const u8 {
        return self.clip_id_buf.items;
    }

    pub fn beginFromMouseDown(
        self: *DocumentSelectionEngine,
        allocator: std.mem.Allocator,
        root: protocol.Node,
        rows: usize,
        cols: usize,
        scrolls: []const render.ScrollState,
        x: usize,
        y: usize,
        now_ns: u64,
        frame: *const Frame,
    ) !bool {
        var layout_cache = render.LayoutCache.init(allocator);
        defer layout_cache.deinit();
        layout_cache.reset(&root, rows, cols, scrolls);

        const current_scroll: ?[]const u8 = null;
        var hit: ?Hit = null;
        findTextHit(root, false, current_scroll, &layout_cache, x, y, &hit);
        if (hit == null) return false;

        const h = hit.?;
        self.active = true;
        self.has_selection = true;
        self.clip_rect = h.clip_rect;
        self.clip_id_buf.clearRetainingCapacity();
        try self.clip_id_buf.appendSlice(allocator, h.clip_id);

        const p = clampToRect(.{ .x = x, .y = y }, h.clip_rect);
        self.a = p;
        self.b = p;

        const click_count = self.updateClickCount(now_ns, x, y, h.clip_id);
        if (click_count == 2) {
            self.expandWordAt(frame, p);
        } else if (click_count >= 3) {
            self.expandRow(p.y);
        }
        return true;
    }

    pub fn updateFromMouseMove(self: *DocumentSelectionEngine, x: usize, y: usize) bool {
        if (!self.active) return false;
        const next = clampToRect(.{ .x = x, .y = y }, self.clip_rect);
        if (next.x == self.b.x and next.y == self.b.y) return false;
        self.b = next;
        return true;
    }

    pub fn endOnMouseUpAndCommit(
        self: *DocumentSelectionEngine,
        allocator: std.mem.Allocator,
        frame: *const Frame,
    ) !CommitResult {
        if (!self.active) return .{};
        self.active = false;

        var out: CommitResult = .{ .consumed = true };
        const selected = try self.selectedTextAllocFromFrame(allocator, frame) orelse return out;

        const hash = std.hash.Wyhash.hash(0, selected.bytes);
        if (self.has_last_commit and self.last_commit_len == selected.bytes.len and self.last_commit_hash == hash) {
            allocator.free(selected.bytes);
            return out;
        }

        self.has_last_commit = true;
        self.last_commit_len = selected.bytes.len;
        self.last_commit_hash = hash;

        const local_x0 = self.a.x - self.clip_rect.x;
        const local_y0 = self.a.y - self.clip_rect.y;
        const local_x1 = self.b.x - self.clip_rect.x;
        const local_y1 = self.b.y - self.clip_rect.y;

        out.changed = true;
        out.event = .{
            .id = self.clip_id_buf.items,
            .kind = .document,
            .x0 = self.a.x,
            .y0 = self.a.y,
            .x1 = self.b.x,
            .y1 = self.b.y,
            .local_x0 = local_x0,
            .local_y0 = local_y0,
            .local_x1 = local_x1,
            .local_y1 = local_y1,
            .text = selected.bytes,
            .bytes = selected.bytes.len,
            .truncated = selected.truncated,
        };
        out.text = selected;
        return out;
    }

    pub fn toScreenSelection(self: *const DocumentSelectionEngine) ?renderer.ScreenSelection {
        if (!self.has_selection) return null;
        return .{
            .enabled = true,
            .clip = .{
                .x = self.clip_rect.x,
                .y = self.clip_rect.y,
                .w = self.clip_rect.w,
                .h = self.clip_rect.h,
            },
            .a = .{ .x = self.a.x, .y = self.a.y },
            .b = .{ .x = self.b.x, .y = self.b.y },
        };
    }

    pub fn selectedTextAllocFromFrame(self: *const DocumentSelectionEngine, allocator: std.mem.Allocator, frame: *const Frame) !?SelectionText {
        if (!self.has_selection) return null;
        if (self.clip_rect.w == 0 or self.clip_rect.h == 0) return null;
        if (frame.rows == 0 or frame.cols == 0) return null;

        const bounds = orderedEndpoints(self.a, self.b, self.clip_rect);

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        var y: usize = bounds.start.y;
        while (y <= bounds.end.y) : (y += 1) {
            const row_start: usize = if (y == bounds.start.y) bounds.start.x else self.clip_rect.x;
            const row_end: usize = if (y == bounds.end.y) bounds.end.x else self.clip_rect.x + self.clip_rect.w - 1;

            var line: std.ArrayList(u8) = .empty;
            defer line.deinit(allocator);

            var x: usize = row_start;
            while (x <= row_end) : (x += 1) {
                if (y >= @as(usize, frame.rows) or x >= @as(usize, frame.cols)) continue;
                const cell = frame.rowSlice(y)[x];
                if (cell.continuation) continue;
                if (cell.len == 0) {
                    try line.append(allocator, ' ');
                } else {
                    try line.appendSlice(allocator, cell.slice());
                }
            }

            while (line.items.len > 0 and line.items[line.items.len - 1] == ' ') {
                line.items.len -= 1;
            }

            if (y != bounds.start.y) try out.append(allocator, '\n');
            try out.appendSlice(allocator, line.items);
            if (y == bounds.end.y) break;
        }

        if (out.items.len == 0) return null;

        var truncated = false;
        if (out.items.len > max_selection_bytes) {
            out.items.len = utf8SafePrefixLen(out.items, max_selection_bytes);
            truncated = true;
        }

        return .{ .bytes = try out.toOwnedSlice(allocator), .truncated = truncated };
    }

    fn updateClickCount(self: *DocumentSelectionEngine, now_ns: u64, x: usize, y: usize, clip_id: []const u8) u8 {
        const clip_hash = std.hash.Wyhash.hash(0, clip_id);
        const multi_window_ns: u64 = 500 * std.time.ns_per_ms;
        const same_spot = self.last_click_x == x and self.last_click_y == y;
        const same_clip = self.last_click_clip_hash == clip_hash;
        const in_window = self.last_click_ns != 0 and now_ns <= self.last_click_ns + multi_window_ns;

        if (same_spot and same_clip and in_window) {
            self.last_click_count = if (self.last_click_count >= 3) 3 else self.last_click_count + 1;
        } else {
            self.last_click_count = 1;
        }
        self.last_click_ns = now_ns;
        self.last_click_x = x;
        self.last_click_y = y;
        self.last_click_clip_hash = clip_hash;
        return self.last_click_count;
    }

    fn expandRow(self: *DocumentSelectionEngine, y: usize) void {
        const cy = clampY(y, self.clip_rect);
        self.a = .{ .x = self.clip_rect.x, .y = cy };
        self.b = .{ .x = self.clip_rect.x + self.clip_rect.w - 1, .y = cy };
    }

    fn expandWordAt(self: *DocumentSelectionEngine, frame: *const Frame, p: Point) void {
        if (p.y >= @as(usize, frame.rows) or p.x >= @as(usize, frame.cols)) return;

        const min_x = self.clip_rect.x;
        const max_x = self.clip_rect.x + self.clip_rect.w - 1;

        var center = p.x;
        while (center > min_x and !isWordCell(frame, p.y, center)) : (center -= 1) {}
        if (!isWordCell(frame, p.y, center)) {
            if (center < max_x and isWordCell(frame, p.y, center + 1)) {
                center += 1;
            } else {
                self.a = p;
                self.b = p;
                return;
            }
        }

        var left = center;
        while (left > min_x and isWordCell(frame, p.y, left - 1)) : (left -= 1) {}

        var right = center;
        while (right < max_x and isWordCell(frame, p.y, right + 1)) : (right += 1) {}

        self.a = .{ .x = left, .y = p.y };
        self.b = .{ .x = right, .y = p.y };
    }
};

fn findTextHit(
    node: protocol.Node,
    disabled_ancestor: bool,
    current_scroll: ?[]const u8,
    layout_cache: *render.LayoutCache,
    x: usize,
    y: usize,
    out: *?Hit,
) void {
    const disabled = disabled_ancestor or switch (node) {
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
    };
    if (disabled) return;

    switch (node) {
        .text => |t| {
            if (!t.mouseable) return;
            const rect = layout_cache.findRect(t.id) orelse return;
            if (!rectContains(rect, x, y)) return;
            const clip_id = current_scroll orelse t.id;
            const clip_rect = layout_cache.findRect(clip_id) orelse rect;
            out.* = .{ .id = t.id, .rect = rect, .clip_id = clip_id, .clip_rect = clip_rect };
        },
        .styled_text => |t| {
            if (!t.mouseable) return;
            const rect = layout_cache.findRect(t.id) orelse return;
            if (!rectContains(rect, x, y)) return;
            const clip_id = current_scroll orelse t.id;
            const clip_rect = layout_cache.findRect(clip_id) orelse rect;
            out.* = .{ .id = t.id, .rect = rect, .clip_id = clip_id, .clip_rect = clip_rect };
        },
        .vbox => |v| for (v.children) |child| findTextHit(child, disabled, current_scroll, layout_cache, x, y, out),
        .hbox => |h| for (h.children) |child| findTextHit(child, disabled, current_scroll, layout_cache, x, y, out),
        .grid => |g| for (g.children) |child| findTextHit(child, disabled, current_scroll, layout_cache, x, y, out),
        .box => |b| findTextHit(b.child.*, disabled, current_scroll, layout_cache, x, y, out),
        .scroll => |s| findTextHit(s.child.*, disabled, if (s.id.len > 0) s.id else current_scroll, layout_cache, x, y, out),
        .overlay => |o| {
            findTextHit(o.base.*, disabled, current_scroll, layout_cache, x, y, out);
            for (o.layers) |layer| findTextHit(layer.node.*, disabled, current_scroll, layout_cache, x, y, out);
        },
        .list => |l| for (l.children) |child| findTextHit(child, disabled, current_scroll, layout_cache, x, y, out),
        .input, .textarea => {},
    }
}

fn utf8SafePrefixLen(bytes: []const u8, limit: usize) usize {
    if (limit >= bytes.len) return bytes.len;
    var cut = limit;
    while (cut > 0 and (bytes[cut] & 0b1100_0000) == 0b1000_0000) : (cut -= 1) {}
    return cut;
}

fn rectContains(r: render.Rect, x: usize, y: usize) bool {
    if (r.w == 0 or r.h == 0) return false;
    if (x < r.x or y < r.y) return false;
    if (x >= r.x + r.w) return false;
    if (y >= r.y + r.h) return false;
    return true;
}

fn clampToRect(p: Point, r: render.Rect) Point {
    if (r.w == 0 or r.h == 0) return .{ .x = r.x, .y = r.y };
    const max_x = r.x + r.w - 1;
    const max_y = r.y + r.h - 1;
    return .{
        .x = @min(@max(p.x, r.x), max_x),
        .y = @min(@max(p.y, r.y), max_y),
    };
}

fn clampY(y: usize, r: render.Rect) usize {
    if (r.h == 0) return r.y;
    const max_y = r.y + r.h - 1;
    return @min(@max(y, r.y), max_y);
}

const Ordered = struct {
    start: Point,
    end: Point,
};

fn orderedEndpoints(a_in: Point, b_in: Point, clip: render.Rect) Ordered {
    const a = clampToRect(a_in, clip);
    const b = clampToRect(b_in, clip);
    if (a.y < b.y) return .{ .start = a, .end = b };
    if (a.y > b.y) return .{ .start = b, .end = a };
    if (a.x <= b.x) return .{ .start = a, .end = b };
    return .{ .start = b, .end = a };
}

fn isWordCell(frame: *const Frame, y: usize, x: usize) bool {
    if (y >= @as(usize, frame.rows) or x >= @as(usize, frame.cols)) return false;
    const row = frame.rowSlice(y);
    const cell = row[x];
    if (cell.continuation) {
        if (x == 0) return false;
        return isWordCell(frame, y, x - 1);
    }
    if (cell.len == 0) return false;
    const first = cell.slice()[0];
    if (first >= 0x80) return true;
    return (first >= 'a' and first <= 'z') or
        (first >= 'A' and first <= 'Z') or
        (first >= '0' and first <= '9') or
        first == '_';
}

test "text selection: utf8 truncation keeps boundary" {
    const s = "abc😀def";
    // Byte boundary inside the emoji sequence should snap back before it.
    try std.testing.expectEqual(@as(usize, 3), utf8SafePrefixLen(s, 6));
    // Exact boundary after the emoji should be preserved.
    try std.testing.expectEqual(@as(usize, 7), utf8SafePrefixLen(s, 7));
}

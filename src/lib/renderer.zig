const std = @import("std");

const frame_mod = @import("frame.zig");
const protocol = @import("protocol/mod.zig");
const render = @import("render/mod.zig");
const color = @import("color.zig");
const style = @import("style.zig");
const Size = @import("term_size.zig").Size;
const termcaps = @import("termcaps.zig");

const Frame = frame_mod.Frame;
const CursorPos = frame_mod.CursorPos;
const Cell = frame_mod.Cell;

pub const Pos = struct {
    x: usize,
    y: usize,
};

pub const Rect = struct {
    x: usize,
    y: usize,
    w: usize,
    h: usize,
};

pub const ScreenSelection = struct {
    enabled: bool = false,
    clip: Rect,
    a: Pos,
    b: Pos,
};

pub const DrawMetrics = struct {
    full: bool = false,
    bytes: usize = 0,
    changed_cells: usize = 0,
    cursor_moves: usize = 0,
    render_to_frame_ns: u64 = 0,
    diff_flush_ns: u64 = 0,
};

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    color_mode: color.ColorMode,
    prev: Frame = .{},
    next: Frame = .{},
    has_prev: bool = false,
    last_metrics: DrawMetrics = .{},
    out: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) Renderer {
        return initWithMode(allocator, color.detectColorMode());
    }

    pub fn initWithMode(allocator: std.mem.Allocator, mode: color.ColorMode) Renderer {
        return .{ .allocator = allocator, .color_mode = mode };
    }

    pub fn deinit(self: *Renderer) void {
        self.prev.deinit(self.allocator);
        self.next.deinit(self.allocator);
        self.out.deinit(self.allocator);
        self.has_prev = false;
        self.last_metrics = .{};
    }

    pub fn draw(self: *Renderer, term: anytype, root: protocol.Node, state: render.RenderState) !void {
        return self.drawWithCaps(term, .{}, root, state, null);
    }

    pub fn drawWithCaps(self: *Renderer, term: anytype, caps: termcaps.Caps, root: protocol.Node, state: render.RenderState, selection_opt: ?ScreenSelection) !void {
        const size = term.getSize() catch Size{ .rows = 0, .cols = 0 };
        const eff = effectiveSize(size);

        if (self.prev.rows != eff.rows or self.prev.cols != eff.cols) {
            try self.prev.resize(self.allocator, eff.rows, eff.cols);
            try self.next.resize(self.allocator, eff.rows, eff.cols);
            self.has_prev = false;
        }

        const render_start_ns = monotonicNowNs();
        self.next.clear(' ');
        render.renderToFrame(root, state, &self.next);
        if (selection_opt) |sel| applyScreenSelection(&self.next, sel);
        self.next.recomputeRowMax();
        const render_end_ns = monotonicNowNs();

        var metrics: DrawMetrics = .{};
        metrics.render_to_frame_ns = elapsedNs(render_start_ns, render_end_ns);
        var cur_style: style.PackedStyle = .{};

        self.out.clearRetainingCapacity();
        const flush_start_ns = monotonicNowNs();

        if (caps.ansi and caps.sync_output) {
            try outWriteAll(self.allocator, &self.out, &metrics, "\x1b[?2026h");
        }
        if (caps.ansi and caps.cursor_visibility) {
            // Hide cursor during rendering to avoid visible cursor jumps.
            try outWriteAll(self.allocator, &self.out, &metrics, "\x1b[?25l");
        }

        if (!caps.ansi or !caps.cursor_address) {
            metrics.full = true;
            try dumbPaint(self.allocator, &self.out, &metrics, &self.next);
            if (caps.ansi and caps.sync_output) {
                try outWriteAll(self.allocator, &self.out, &metrics, "\x1b[?2026l");
            }
            try term.writeAll(self.out.items);
            self.has_prev = false;
            metrics.diff_flush_ns = elapsedNs(flush_start_ns, monotonicNowNs());
            self.last_metrics = metrics;
            return;
        }

        // Start from a known SGR state; cursor moves don't reset style.
        try outWriteAll(self.allocator, &self.out, &metrics, "\x1b[0m");

        if (!self.has_prev) {
            metrics.full = true;
            try fullPaint(self.allocator, &self.out, &metrics, &cur_style, self.color_mode, caps, &self.next);
            self.has_prev = true;
        } else {
            metrics.full = false;
            try diffAndFlush(self.allocator, &self.out, &metrics, &cur_style, self.color_mode, caps, &self.prev, &self.next);
        }

        try applyCursor(self.allocator, &self.out, &metrics, caps, self.next.cursor);
        if (caps.ansi and caps.sync_output) {
            try outWriteAll(self.allocator, &self.out, &metrics, "\x1b[?2026l");
        }
        try term.writeAll(self.out.items);
        metrics.diff_flush_ns = elapsedNs(flush_start_ns, monotonicNowNs());
        self.last_metrics = metrics;

        std.mem.swap(Frame, &self.prev, &self.next);
    }
};

pub fn applyScreenSelection(frame: *Frame, selection: ScreenSelection) void {
    if (!selection.enabled) return;
    if (selection.clip.w == 0 or selection.clip.h == 0) return;
    if (frame.rows == 0 or frame.cols == 0) return;

    const frame_rows: usize = @as(usize, frame.rows);
    const frame_cols: usize = @as(usize, frame.cols);
    const clip_x0: usize = @min(selection.clip.x, frame_cols);
    const clip_y0: usize = @min(selection.clip.y, frame_rows);
    const clip_x1: usize = @min(selection.clip.x + selection.clip.w, frame_cols);
    const clip_y1: usize = @min(selection.clip.y + selection.clip.h, frame_rows);
    if (clip_x1 <= clip_x0 or clip_y1 <= clip_y0) return;

    const a_i: usize = selection.a.y * frame_cols + selection.a.x;
    const b_i: usize = selection.b.y * frame_cols + selection.b.x;
    const lo_i = @min(a_i, b_i);
    const hi_i = @max(a_i, b_i);

    var y: usize = clip_y0;
    while (y < clip_y1) : (y += 1) {
        var row = frame.rowSliceMut(y);
        var x: usize = clip_x0;
        while (x < clip_x1) : (x += 1) {
            const idx = y * frame_cols + x;
            if (idx < lo_i or idx > hi_i) continue;
            row[x].style.attrs |= style.ATTR_INVERSE;
        }
    }
}

fn effectiveSize(size: Size) Size {
    var rows = size.rows;
    var cols = size.cols;
    if (rows == 0) rows = 24;
    if (cols == 0) cols = 80;
    return .{ .rows = rows, .cols = cols };
}

fn monotonicNowNs() u64 {
    const t = std.time.nanoTimestamp();
    return if (t <= 0) 0 else @as(u64, @intCast(t));
}

fn elapsedNs(start: u64, end: u64) u64 {
    return if (end >= start) end - start else 0;
}

fn outWriteAll(allocator: std.mem.Allocator, out: *std.ArrayList(u8), metrics: *DrawMetrics, bytes: []const u8) !void {
    try out.appendSlice(allocator, bytes);
    metrics.bytes += bytes.len;
}

fn emitCursorMove(allocator: std.mem.Allocator, out: *std.ArrayList(u8), metrics: *DrawMetrics, row: usize, col: usize) !void {
    var esc_buf: [64]u8 = undefined;
    const esc = try std.fmt.bufPrint(&esc_buf, "\x1b[{d};{d}H", .{ row, col });
    try outWriteAll(allocator, out, metrics, esc);
    metrics.cursor_moves += 1;
}

fn applyStyle(allocator: std.mem.Allocator, out: *std.ArrayList(u8), metrics: *DrawMetrics, cur: *style.PackedStyle, mode: color.ColorMode, next: style.PackedStyle) !void {
    if (@as(u64, @bitCast(cur.*)) == @as(u64, @bitCast(next))) return;

    var buf: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    try w.writeAll("\x1b[0");

    const attrs = next.attrs;
    if ((attrs & style.ATTR_BOLD) != 0) try w.writeAll(";1");
    if ((attrs & style.ATTR_DIM) != 0) try w.writeAll(";2");
    if ((attrs & style.ATTR_ITALIC) != 0) try w.writeAll(";3");
    if ((attrs & style.ATTR_UNDERLINE) != 0) try w.writeAll(";4");
    if ((attrs & style.ATTR_BLINK) != 0) try w.writeAll(";5");
    if ((attrs & style.ATTR_INVERSE) != 0) try w.writeAll(";7");
    if ((attrs & style.ATTR_HIDDEN) != 0) try w.writeAll(";8");
    if ((attrs & style.ATTR_STRIKETHROUGH) != 0) try w.writeAll(";9");

    if (mode != .mono) {
        if (next.has_fg == 1) {
            const rgb = color.u24ToRgb(next.fg);
            switch (mode) {
                .truecolor => try w.print(";38;2;{d};{d};{d}", .{ rgb.r, rgb.g, rgb.b }),
                .ansi256 => try w.print(";38;5;{d}", .{color.rgbToXterm256(rgb)}),
                .ansi16 => {
                    const idx: u4 = color.rgbToAnsi16(rgb);
                    const code: u8 = if (idx < 8) (30 + @as(u8, idx)) else (90 + (@as(u8, idx) - 8));
                    try w.print(";{d}", .{code});
                },
                .mono => {},
            }
        }
        if (next.has_bg == 1) {
            const rgb = color.u24ToRgb(next.bg);
            switch (mode) {
                .truecolor => try w.print(";48;2;{d};{d};{d}", .{ rgb.r, rgb.g, rgb.b }),
                .ansi256 => try w.print(";48;5;{d}", .{color.rgbToXterm256(rgb)}),
                .ansi16 => {
                    const idx: u4 = color.rgbToAnsi16(rgb);
                    const code: u8 = if (idx < 8) (40 + @as(u8, idx)) else (100 + (@as(u8, idx) - 8));
                    try w.print(";{d}", .{code});
                },
                .mono => {},
            }
        }
    }

    try w.writeByte('m');
    try outWriteAll(allocator, out, metrics, fbs.getWritten());
    cur.* = next;
}

fn dumbPaint(allocator: std.mem.Allocator, out: *std.ArrayList(u8), metrics: *DrawMetrics, next: *const Frame) !void {
    const rows: usize = @as(usize, next.rows);
    const cols: usize = @as(usize, next.cols);

    var r: usize = 0;
    while (r < rows) : (r += 1) {
        const row = next.rowSlice(r);
        var c: usize = 0;
        while (c < cols) : (c += 1) {
            const cell = row[c];
            if (cell.continuation) continue;
            if (cell.len == 0) {
                try outWriteAll(allocator, out, metrics, " ");
            } else {
                try outWriteAll(allocator, out, metrics, cell.slice());
            }
        }
        if (r + 1 < rows) try outWriteAll(allocator, out, metrics, "\r\n");
    }
}

fn fullPaint(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    metrics: *DrawMetrics,
    cur_style: *style.PackedStyle,
    mode: color.ColorMode,
    caps: termcaps.Caps,
    next: *const Frame,
) !void {
    // Prefer avoiding full-screen clears when we can reliably clear each line.
    // This reduces visible flicker on repaints (e.g. during resize) on terminals
    // without synchronized output support.
    if (caps.clear_screen and !caps.erase_eol) {
        try outWriteAll(allocator, out, metrics, "\x1b[2J\x1b[H");
    } else {
        try outWriteAll(allocator, out, metrics, "\x1b[H");
    }

    const rows: usize = @as(usize, next.rows);
    const cols: usize = @as(usize, next.cols);

    var r: usize = 0;
    while (r < rows) : (r += 1) {
        const max: usize = @as(usize, next.row_max[r]);
        if (max > 0) {
            const row = next.rowSlice(r);
            var c: usize = 0;
            while (c < max) : (c += 1) {
                const cell = row[c];
                if (cell.continuation) continue;
                try applyStyle(allocator, out, metrics, cur_style, mode, cell.style);
                if (cell.len == 0) {
                    try outWriteAll(allocator, out, metrics, " ");
                } else {
                    try outWriteAll(allocator, out, metrics, cell.slice());
                }
            }
        }
        if (caps.erase_eol and max < cols) {
            try applyStyle(allocator, out, metrics, cur_style, mode, .{});
            try outWriteAll(allocator, out, metrics, "\x1b[K");
        }
        if (r + 1 < rows) {
            if (max == cols) {
                // Avoid relying on terminal wrap behavior at the last column.
                try emitCursorMove(allocator, out, metrics, r + 2, 1);
            } else {
                try outWriteAll(allocator, out, metrics, "\r\n");
            }
        }
    }
}

fn cellsEqual(a: Cell, b: Cell) bool {
    if (a.continuation != b.continuation) return false;
    if (a.width != b.width) return false;
    if (a.len != b.len) return false;
    if (@as(u64, @bitCast(a.style)) != @as(u64, @bitCast(b.style))) return false;
    return std.mem.eql(u8, a.slice(), b.slice());
}

fn diffAndFlush(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    metrics: *DrawMetrics,
    cur_style: *style.PackedStyle,
    mode: color.ColorMode,
    caps: termcaps.Caps,
    prev: *const Frame,
    next: *const Frame,
) !void {
    const rows: usize = @as(usize, next.rows);
    _ = @as(usize, next.cols);

    var r: usize = 0;
    while (r < rows) : (r += 1) {
        const prev_max: usize = @as(usize, prev.row_max[r]);
        const next_max: usize = @as(usize, next.row_max[r]);

        const compare_end: usize = next_max;
        if (compare_end > 0) {
            const prev_row = prev.rowSlice(r);
            const next_row = next.rowSlice(r);

            var c: usize = 0;
            while (c < compare_end) {
                if (cellsEqual(prev_row[c], next_row[c])) {
                    c += 1;
                    continue;
                }

                var start = c;
                if (start > 0 and (prev_row[start].continuation or next_row[start].continuation)) {
                    start -= 1;
                }
                c += 1;
                while (c < compare_end and !cellsEqual(prev_row[c], next_row[c])) : (c += 1) {}

                try emitCursorMove(allocator, out, metrics, r + 1, start + 1);
                var col: usize = start;
                while (col < c) : (col += 1) {
                    const cell = next_row[col];
                    if (cell.continuation) continue;
                    try applyStyle(allocator, out, metrics, cur_style, mode, cell.style);
                    if (cell.len == 0) {
                        try outWriteAll(allocator, out, metrics, " ");
                    } else {
                        try outWriteAll(allocator, out, metrics, cell.slice());
                    }
                }
                metrics.changed_cells += c - start;
            }
        }

        if (next_max < prev_max) {
            const erase_col = next_max + 1;
            try emitCursorMove(allocator, out, metrics, r + 1, erase_col);
            try applyStyle(allocator, out, metrics, cur_style, mode, .{});
            if (caps.erase_eol) {
                try outWriteAll(allocator, out, metrics, "\x1b[K");
            } else {
                var i: usize = 0;
                while (i < (prev_max - next_max)) : (i += 1) {
                    try outWriteAll(allocator, out, metrics, " ");
                }
            }
            metrics.changed_cells += prev_max - next_max;
        }
    }
}

fn applyCursor(allocator: std.mem.Allocator, out: *std.ArrayList(u8), metrics: *DrawMetrics, caps: termcaps.Caps, cursor: ?CursorPos) !void {
    if (!caps.cursor_visibility) return;
    if (cursor) |c| {
        try outWriteAll(allocator, out, metrics, "\x1b[?25h");
        try emitCursorMove(allocator, out, metrics, c.row, c.col);
    } else {
        try outWriteAll(allocator, out, metrics, "\x1b[?25l");
    }
}

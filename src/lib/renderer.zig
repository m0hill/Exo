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

pub const DrawMetrics = struct {
    full: bool = false,
    bytes: usize = 0,
    changed_cells: usize = 0,
    cursor_moves: usize = 0,
};

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    color_mode: color.ColorMode,
    prev: Frame = .{},
    next: Frame = .{},
    has_prev: bool = false,
    last_metrics: DrawMetrics = .{},

    pub fn init(allocator: std.mem.Allocator) Renderer {
        return initWithMode(allocator, color.detectColorMode());
    }

    pub fn initWithMode(allocator: std.mem.Allocator, mode: color.ColorMode) Renderer {
        return .{ .allocator = allocator, .color_mode = mode };
    }

    pub fn deinit(self: *Renderer) void {
        self.prev.deinit(self.allocator);
        self.next.deinit(self.allocator);
        self.has_prev = false;
        self.last_metrics = .{};
    }

    pub fn draw(self: *Renderer, term: anytype, root: protocol.Node, state: render.RenderState) !void {
        return self.drawWithCaps(term, .{}, root, state);
    }

    pub fn drawWithCaps(self: *Renderer, term: anytype, caps: termcaps.Caps, root: protocol.Node, state: render.RenderState) !void {
        const size = term.getSize() catch Size{ .rows = 0, .cols = 0 };
        const eff = effectiveSize(size);

        if (self.prev.rows != eff.rows or self.prev.cols != eff.cols) {
            try self.prev.resize(self.allocator, eff.rows, eff.cols);
            try self.next.resize(self.allocator, eff.rows, eff.cols);
            self.has_prev = false;
        }

        self.next.clear(' ');
        render.renderToFrame(root, state, &self.next);
        self.next.recomputeRowMax();

        var metrics: DrawMetrics = .{};
        var cur_style: style.PackedStyle = .{};

        if (!caps.ansi or !caps.cursor_address) {
            metrics.full = true;
            try dumbPaint(term, &metrics, &self.next);
            self.has_prev = false;
            self.last_metrics = metrics;
            return;
        }

        // Start from a known SGR state; cursor moves don't reset style.
        try termWriteAll(term, &metrics, "\x1b[0m");

        if (!self.has_prev) {
            metrics.full = true;
            try fullPaint(term, &metrics, &cur_style, self.color_mode, caps, &self.next);
            self.has_prev = true;
        } else {
            metrics.full = false;
            try diffAndFlush(term, &metrics, &cur_style, self.color_mode, caps, &self.prev, &self.next);
        }

        try applyCursor(term, &metrics, caps, self.next.cursor);
        self.last_metrics = metrics;

        std.mem.swap(Frame, &self.prev, &self.next);
    }
};

fn effectiveSize(size: Size) Size {
    var rows = size.rows;
    var cols = size.cols;
    if (rows == 0) rows = 24;
    if (cols == 0) cols = 80;
    return .{ .rows = rows, .cols = cols };
}

fn termWriteAll(term: anytype, metrics: *DrawMetrics, bytes: []const u8) !void {
    try term.writeAll(bytes);
    metrics.bytes += bytes.len;
}

fn emitCursorMove(term: anytype, metrics: *DrawMetrics, row: usize, col: usize) !void {
    var esc_buf: [64]u8 = undefined;
    const esc = try std.fmt.bufPrint(&esc_buf, "\x1b[{d};{d}H", .{ row, col });
    try termWriteAll(term, metrics, esc);
    metrics.cursor_moves += 1;
}

fn applyStyle(term: anytype, metrics: *DrawMetrics, cur: *style.PackedStyle, mode: color.ColorMode, next: style.PackedStyle) !void {
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
    try termWriteAll(term, metrics, fbs.getWritten());
    cur.* = next;
}

fn dumbPaint(term: anytype, metrics: *DrawMetrics, next: *const Frame) !void {
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
                try termWriteAll(term, metrics, " ");
            } else {
                try termWriteAll(term, metrics, cell.slice());
            }
        }
        if (r + 1 < rows) try termWriteAll(term, metrics, "\r\n");
    }
}

fn fullPaint(
    term: anytype,
    metrics: *DrawMetrics,
    cur_style: *style.PackedStyle,
    mode: color.ColorMode,
    caps: termcaps.Caps,
    next: *const Frame,
) !void {
    if (caps.clear_screen) {
        try termWriteAll(term, metrics, "\x1b[2J\x1b[H");
    } else {
        try termWriteAll(term, metrics, "\x1b[H");
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
                try applyStyle(term, metrics, cur_style, mode, cell.style);
                if (cell.len == 0) {
                    try termWriteAll(term, metrics, " ");
                } else {
                    try termWriteAll(term, metrics, cell.slice());
                }
            }
        }
        if (caps.erase_eol and max < cols) {
            try applyStyle(term, metrics, cur_style, mode, .{});
            try termWriteAll(term, metrics, "\x1b[K");
        }
        if (r + 1 < rows) {
            if (max == cols) {
                // Avoid relying on terminal wrap behavior at the last column.
                try emitCursorMove(term, metrics, r + 2, 1);
            } else {
                try termWriteAll(term, metrics, "\r\n");
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
    term: anytype,
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

                try emitCursorMove(term, metrics, r + 1, start + 1);
                var col: usize = start;
                while (col < c) : (col += 1) {
                    const cell = next_row[col];
                    if (cell.continuation) continue;
                    try applyStyle(term, metrics, cur_style, mode, cell.style);
                    if (cell.len == 0) {
                        try termWriteAll(term, metrics, " ");
                    } else {
                        try termWriteAll(term, metrics, cell.slice());
                    }
                }
                metrics.changed_cells += c - start;
            }
        }

        if (next_max < prev_max) {
            const erase_col = next_max + 1;
            try emitCursorMove(term, metrics, r + 1, erase_col);
            try applyStyle(term, metrics, cur_style, mode, .{});
            if (caps.erase_eol) {
                try termWriteAll(term, metrics, "\x1b[K");
            } else {
                var i: usize = 0;
                while (i < (prev_max - next_max)) : (i += 1) {
                    try termWriteAll(term, metrics, " ");
                }
            }
            metrics.changed_cells += prev_max - next_max;
        }
    }
}

fn applyCursor(term: anytype, metrics: *DrawMetrics, caps: termcaps.Caps, cursor: ?CursorPos) !void {
    if (!caps.cursor_visibility) return;
    if (cursor) |c| {
        try termWriteAll(term, metrics, "\x1b[?25h");
        try emitCursorMove(term, metrics, c.row, c.col);
    } else {
        try termWriteAll(term, metrics, "\x1b[?25l");
    }
}

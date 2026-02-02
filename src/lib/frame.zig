const std = @import("std");

pub const CursorPos = struct {
    row: usize, // 1-based
    col: usize, // 1-based
};

pub const Frame = struct {
    rows: u16 = 0,
    cols: u16 = 0,
    cells: []u8 = &.{},
    row_max: []u16 = &.{},
    cursor: ?CursorPos = null,

    pub fn deinit(self: *Frame, allocator: std.mem.Allocator) void {
        if (self.cells.len > 0) allocator.free(self.cells);
        if (self.row_max.len > 0) allocator.free(self.row_max);
        self.* = .{};
    }

    pub fn resize(self: *Frame, allocator: std.mem.Allocator, rows: u16, cols: u16) !void {
        if (rows == self.rows and cols == self.cols) return;

        if (self.cells.len > 0) allocator.free(self.cells);
        if (self.row_max.len > 0) allocator.free(self.row_max);

        self.rows = rows;
        self.cols = cols;
        self.cells = if (rows == 0 or cols == 0) &.{} else try allocator.alloc(u8, @as(usize, rows) * @as(usize, cols));
        self.row_max = if (rows == 0) &.{} else try allocator.alloc(u16, @as(usize, rows));
        self.clear(' ');
    }

    pub fn clear(self: *Frame, fill: u8) void {
        if (self.cells.len > 0) @memset(self.cells, fill);
        if (self.row_max.len > 0) @memset(self.row_max, 0);
        self.cursor = null;
    }

    pub fn rowSlice(self: *const Frame, row: usize) []const u8 {
        const cols: usize = @as(usize, self.cols);
        const off: usize = row * cols;
        return self.cells[off .. off + cols];
    }

    pub fn rowSliceMut(self: *Frame, row: usize) []u8 {
        const cols: usize = @as(usize, self.cols);
        const off: usize = row * cols;
        return self.cells[off .. off + cols];
    }

    pub fn putText(self: *Frame, row: usize, col: usize, text: []const u8) void {
        if (row >= @as(usize, self.rows)) return;
        const cols: usize = @as(usize, self.cols);
        if (cols == 0 or col >= cols) return;

        const available: usize = cols - col;
        const n: usize = @min(text.len, available);
        if (n == 0) return;

        const dst = self.rowSliceMut(row)[col .. col + n];
        @memcpy(dst, text[0..n]);
    }

    pub fn recomputeRowMax(self: *Frame) void {
        const rows: usize = @as(usize, self.rows);
        const cols: usize = @as(usize, self.cols);
        if (rows == 0 or cols == 0) return;

        var r: usize = 0;
        while (r < rows) : (r += 1) {
            const row = self.rowSlice(r);
            var max: usize = 0;
            var c: usize = cols;
            while (c > 0) : (c -= 1) {
                if (row[c - 1] != ' ') {
                    max = c;
                    break;
                }
            }
            self.row_max[r] = @intCast(max);
        }
    }
};

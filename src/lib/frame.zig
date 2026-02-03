const std = @import("std");
const style = @import("style.zig");

pub const CursorPos = struct {
    row: usize, // 1-based
    col: usize, // 1-based
};

pub const MAX_GRAPHEME_BYTES: usize = 32;

pub const Cell = struct {
    bytes: [MAX_GRAPHEME_BYTES]u8 = undefined,
    len: u8 = 0,
    width: u2 = 1,
    continuation: bool = false,
    style: style.PackedStyle = .{},

    pub fn isBlank(self: Cell) bool {
        return !self.continuation and self.len == 0;
    }

    pub fn slice(self: *const Cell) []const u8 {
        return self.bytes[0..@as(usize, self.len)];
    }
};

pub const Frame = struct {
    rows: u16 = 0,
    cols: u16 = 0,
    cells: []Cell = &.{},
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
        self.cells = if (rows == 0 or cols == 0) &.{} else try allocator.alloc(Cell, @as(usize, rows) * @as(usize, cols));
        self.row_max = if (rows == 0) &.{} else try allocator.alloc(u16, @as(usize, rows));
        self.clear(' ');
    }

    pub fn clear(self: *Frame, fill: u8) void {
        _ = fill;
        if (self.cells.len > 0) {
            var i: usize = 0;
            while (i < self.cells.len) : (i += 1) {
                self.cells[i] = .{};
            }
        }
        if (self.row_max.len > 0) @memset(self.row_max, 0);
        self.cursor = null;
    }

    pub fn rowSlice(self: *const Frame, row: usize) []const Cell {
        const cols: usize = @as(usize, self.cols);
        const off: usize = row * cols;
        return self.cells[off .. off + cols];
    }

    pub fn rowSliceMut(self: *Frame, row: usize) []Cell {
        const cols: usize = @as(usize, self.cols);
        const off: usize = row * cols;
        return self.cells[off .. off + cols];
    }

    pub fn cellAt(self: *const Frame, row: usize, col: usize) ?*const Cell {
        if (row >= @as(usize, self.rows)) return null;
        const cols: usize = @as(usize, self.cols);
        if (cols == 0 or col >= cols) return null;
        return &self.rowSlice(row)[col];
    }

    fn blankCell(st: style.PackedStyle) Cell {
        return .{ .len = 0, .width = 1, .continuation = false, .style = st };
    }

    fn continuationCell(st: style.PackedStyle) Cell {
        return .{ .len = 0, .width = 0, .continuation = true, .style = st };
    }

    fn breakWideAt(self: *Frame, row: usize, col: usize) void {
        const cols: usize = @as(usize, self.cols);
        if (row >= @as(usize, self.rows) or col >= cols) return;

        var row_cells = self.rowSliceMut(row);
        const cell = row_cells[col];

        if (cell.continuation) {
            row_cells[col] = blankCell(.{});
            if (col > 0) {
                const left = row_cells[col - 1];
                if (!left.continuation and left.width == 2) {
                    row_cells[col - 1] = blankCell(.{});
                }
            }
            return;
        }

        if (!cell.continuation and cell.width == 2) {
            if (col + 1 < cols) row_cells[col + 1] = blankCell(.{});
        }
    }

    pub fn putGrapheme(self: *Frame, row: usize, col: usize, bytes: []const u8, width: u2) void {
        self.putGraphemeStyled(row, col, bytes, width, .{});
    }

    pub fn putGraphemeStyled(
        self: *Frame,
        row: usize,
        col: usize,
        bytes: []const u8,
        width: u2,
        st: style.PackedStyle,
    ) void {
        if (row >= @as(usize, self.rows)) return;
        const cols: usize = @as(usize, self.cols);
        if (cols == 0 or col >= cols) return;
        if (width == 0) return;
        if (width == 2 and col + 1 >= cols) return;

        // Ensure we don't leave orphaned halves of wide glyphs behind.
        self.breakWideAt(row, col);
        if (width == 2) self.breakWideAt(row, col + 1);

        var row_cells = self.rowSliceMut(row);

        var cell: Cell = .{};
        if (bytes.len == 0) {
            cell = blankCell(st);
        } else if (bytes.len > MAX_GRAPHEME_BYTES) {
            cell.len = 1;
            cell.bytes[0] = '?';
            cell.width = 1;
            cell.continuation = false;
            cell.style = st;
        } else {
            cell.len = @as(u8, @intCast(bytes.len));
            @memcpy(cell.bytes[0..bytes.len], bytes);
            cell.width = width;
            cell.continuation = false;
            cell.style = st;
        }
        row_cells[col] = cell;

        if (width == 2) {
            row_cells[col + 1] = continuationCell(st);
        }
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
                const cell = row[c - 1];
                if (!cell.isBlank() or (cell.style.affectsBlank() and !cell.style.isDefault())) {
                    max = c;
                    break;
                }
            }
            self.row_max[r] = @intCast(max);
        }
    }
};

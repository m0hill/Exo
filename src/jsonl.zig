const std = @import("std");

pub const LineReader = struct {
    reader: *std.Io.Reader,
    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8),
    max_bytes: usize,
    eof: bool = false,
    start: usize = 0,

    pub const Error = error{
        LineTooLong,
    } || std.Io.Reader.Error || std.mem.Allocator.Error;

    pub fn init(allocator: std.mem.Allocator, reader: *std.Io.Reader, max_bytes: usize) LineReader {
        return .{
            .reader = reader,
            .allocator = allocator,
            .buf = .empty,
            .max_bytes = max_bytes,
        };
    }

    pub fn deinit(self: *LineReader) void {
        self.buf.deinit(self.allocator);
    }

    pub fn readMore(self: *LineReader) Error!usize {
        if (self.eof) return 0;

        // Compact only here (safe because callers should only call readMore
        // after they've finished using the last line slice).
        if (self.start > 0 and (self.start > 4096 or self.start > self.buf.items.len / 2)) {
            const remaining = self.buf.items.len - self.start;
            std.mem.copyForwards(u8, self.buf.items[0..remaining], self.buf.items[self.start..]);
            self.buf.shrinkRetainingCapacity(remaining);
            self.start = 0;
        }

        var tmp: [4096]u8 = undefined;
        var slices = [_][]u8{tmp[0..]};
        const n = self.reader.readVec(&slices) catch |e| switch (e) {
            error.EndOfStream => {
                self.eof = true;
                return 0;
            },
            error.ReadFailed => return error.ReadFailed,
        };

        const live = self.buf.items.len - self.start;
        if (live + n > self.max_bytes) {
            self.buf.clearRetainingCapacity();
            self.start = 0;
            return error.LineTooLong;
        }
        try self.buf.appendSlice(self.allocator, tmp[0..n]);
        return n;
    }

    /// Returns next line (without trailing '\n' / optional '\r').
    /// Slice is valid until the next `readMore()` call.
    pub fn nextLine(self: *LineReader) ?[]const u8 {
        const hay = self.buf.items[self.start..];
        if (std.mem.indexOfScalar(u8, hay, '\n')) |rel_idx| {
            const idx = self.start + rel_idx;
            const line_full = self.buf.items[self.start..idx];
            self.start = idx + 1;

            if (line_full.len > 0 and line_full[line_full.len - 1] == '\r') {
                return line_full[0 .. line_full.len - 1];
            }
            return line_full;
        }

        if (self.eof and self.start < self.buf.items.len) {
            const line_full = self.buf.items[self.start..];
            self.start = self.buf.items.len;
            return line_full;
        }

        // Optional cleanup
        if (self.eof and self.start == self.buf.items.len) {
            self.buf.clearRetainingCapacity();
            self.start = 0;
        }

        return null;
    }
};

const std = @import("std");

pub const Size = @import("term_size.zig").Size;

pub const Terminal = struct {
    allocator: std.mem.Allocator,
    size: Size,
    out: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator, size: Size) Terminal {
        return .{ .allocator = allocator, .size = size };
    }

    pub fn deinit(self: *Terminal) void {
        self.out.deinit(self.allocator);
    }

    pub fn getSize(self: *Terminal) !Size {
        return self.size;
    }

    pub fn writeAll(self: *Terminal, bytes: []const u8) !void {
        try self.out.appendSlice(self.allocator, bytes);
    }

    pub fn reset(self: *Terminal) void {
        self.out.clearRetainingCapacity();
    }
};

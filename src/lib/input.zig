const std = @import("std");

pub fn handleInputByte(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    cursor: *usize,
    b: u8,
) !bool {
    switch (b) {
        8, 127 => {
            if (cursor.* == 0) return false;
            cursor.* -= 1;
            _ = buf.orderedRemove(cursor.*);
            return true;
        },
        else => {},
    }

    if (b < 0x20 or b == 0x7f) return false;
    // Tracer #2: ASCII only.
    if (b >= 0x80) return false;

    if (cursor.* > buf.items.len) cursor.* = buf.items.len;
    if (cursor.* == buf.items.len) {
        try buf.append(allocator, b);
        cursor.* += 1;
        return true;
    }

    try buf.insert(allocator, cursor.*, b);
    cursor.* += 1;
    return true;
}

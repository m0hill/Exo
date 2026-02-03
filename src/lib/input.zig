const std = @import("std");

pub fn ensure_cursor_visible(scroll_x: *usize, cursor: usize, value_len: usize, visible_cols: usize) bool {
    var next = scroll_x.*;
    if (visible_cols == 0 or value_len <= visible_cols) {
        next = 0;
    } else {
        if (cursor < next) next = cursor;
        if (cursor > next + visible_cols) next = cursor - visible_cols;
        if (next > value_len) next = value_len;
    }
    const changed = next != scroll_x.*;
    scroll_x.* = next;
    return changed;
}

pub fn delete_at_cursor(buf: *std.ArrayList(u8), cursor: *usize) bool {
    if (cursor.* > buf.items.len) cursor.* = buf.items.len;
    if (cursor.* >= buf.items.len) return false;
    _ = buf.orderedRemove(cursor.*);
    return true;
}

pub fn is_word_char(b: u8) bool {
    return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9') or b == '_';
}

pub fn word_left(value: []const u8, cursor: usize) usize {
    var i: usize = @min(cursor, value.len);
    while (i > 0 and !is_word_char(value[i - 1])) : (i -= 1) {}
    while (i > 0 and is_word_char(value[i - 1])) : (i -= 1) {}
    return i;
}

pub fn word_right(value: []const u8, cursor: usize) usize {
    var i: usize = @min(cursor, value.len);
    while (i < value.len and !is_word_char(value[i])) : (i += 1) {}
    while (i < value.len and is_word_char(value[i])) : (i += 1) {}
    return i;
}

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

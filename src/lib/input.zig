const std = @import("std");
const unicode = @import("unicode.zig");

pub fn ensure_cursor_visible(scroll_byte: *usize, cursor_byte: usize, value: []const u8, visible_cols: usize) bool {
    var next = unicode.clampGraphemeBoundary(value, @min(scroll_byte.*, value.len));
    const cursor = unicode.clampGraphemeBoundary(value, @min(cursor_byte, value.len));

    if (visible_cols == 0 or unicode.displayWidth(value) <= visible_cols) {
        next = 0;
    } else {
        if (cursor < next) next = cursor;
        while (next < value.len) {
            const cursor_cols = if (cursor <= next) 0 else unicode.displayWidth(value[next..cursor]);
            if (cursor_cols <= visible_cols) break;
            const g = unicode.nextGrapheme(value, next);
            if (g.end <= next) break;
            next = g.end;
        }
        if (next > value.len) next = value.len;
    }

    const changed = next != scroll_byte.*;
    scroll_byte.* = next;
    return changed;
}

fn deleteRange(buf: *std.ArrayList(u8), start: usize, end: usize) void {
    if (start >= end or start >= buf.items.len) return;
    const e = @min(end, buf.items.len);
    const n = e - start;
    if (n == 0) return;

    std.mem.copyForwards(u8, buf.items[start .. buf.items.len - n], buf.items[e..]);
    buf.items = buf.items[0 .. buf.items.len - n];
}

pub fn delete_at_cursor(buf: *std.ArrayList(u8), cursor: *usize) bool {
    if (cursor.* > buf.items.len) cursor.* = buf.items.len;
    const start = unicode.clampGraphemeBoundary(buf.items, cursor.*);
    const end = unicode.nextGraphemeBoundary(buf.items, start);
    if (start >= buf.items.len or end <= start) return false;

    deleteRange(buf, start, end);
    cursor.* = start;
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
            if (cursor.* > buf.items.len) cursor.* = buf.items.len;
            const end = cursor.*;
            const start = unicode.prevGraphemeBoundary(buf.items, end);
            deleteRange(buf, start, end);
            cursor.* = start;
            return true;
        },
        else => {},
    }

    if (b < 0x20 or b == 0x7f) return false;
    // Note: non-ASCII UTF-8 insertion is handled by insertUtf8Bytes() in the runtime.
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

pub fn insertUtf8Bytes(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    cursor: *usize,
    bytes: []const u8,
) !bool {
    if (bytes.len == 0) return false;
    if (bytes[0] < 0x80) return false;
    if (bytes.len > 4) return false;

    const expect = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return false;
    if (@as(usize, expect) != bytes.len) return false;
    _ = std.unicode.utf8Decode(bytes) catch return false;

    if (cursor.* > buf.items.len) cursor.* = buf.items.len;
    cursor.* = unicode.clampGraphemeBoundary(buf.items, cursor.*);

    if (cursor.* == buf.items.len) {
        try buf.appendSlice(allocator, bytes);
        cursor.* += bytes.len;
        return true;
    }

    try buf.insertSlice(allocator, cursor.*, bytes);
    cursor.* += bytes.len;
    return true;
}

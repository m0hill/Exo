const std = @import("std");

pub const MouseEventKind = enum {
    down_left,
    wheel_up,
    wheel_down,
};

pub const MouseEvent = struct {
    kind: MouseEventKind,
    /// 0-based terminal column.
    x: usize,
    /// 0-based terminal row.
    y: usize,
};

pub fn parseSgrMouseSequence(bytes: []const u8) ?MouseEvent {
    var i: usize = 0;
    if (bytes.len >= 3 and bytes[0] == 0x1b and bytes[1] == '[' and bytes[2] == '<') {
        i = 3;
    } else if (bytes.len >= 1 and bytes[0] == '<') {
        i = 1;
    } else {
        return null;
    }

    const b = parseU32(bytes, &i) orelse return null;
    if (!eat(bytes, &i, ';')) return null;
    const x1 = parseU32(bytes, &i) orelse return null;
    if (!eat(bytes, &i, ';')) return null;
    const y1 = parseU32(bytes, &i) orelse return null;

    if (i >= bytes.len) return null;
    const final = bytes[i];
    i += 1;
    if (i != bytes.len) return null;

    if (final != 'M') return null; // Tracer 13 ignores releases ('m') and everything else.

    const b_nomod: u32 = b & ~@as(u32, 4 | 8 | 16);
    const kind: MouseEventKind = switch (b_nomod) {
        0 => .down_left,
        64 => .wheel_up,
        65 => .wheel_down,
        else => return null,
    };

    const x0: usize = if (x1 > 0) @as(usize, x1 - 1) else 0;
    const y0: usize = if (y1 > 0) @as(usize, y1 - 1) else 0;
    return .{ .kind = kind, .x = x0, .y = y0 };
}

fn eat(bytes: []const u8, i: *usize, ch: u8) bool {
    if (i.* >= bytes.len) return false;
    if (bytes[i.*] != ch) return false;
    i.* += 1;
    return true;
}

fn parseU32(bytes: []const u8, i: *usize) ?u32 {
    if (i.* >= bytes.len) return null;
    var v: u32 = 0;
    var any: bool = false;
    while (i.* < bytes.len) {
        const c = bytes[i.*];
        if (c < '0' or c > '9') break;
        any = true;
        const digit: u32 = @as(u32, c - '0');
        if (v > (std.math.maxInt(u32) - digit) / 10) return null;
        v = v * 10 + digit;
        i.* += 1;
    }
    return if (any) v else null;
}

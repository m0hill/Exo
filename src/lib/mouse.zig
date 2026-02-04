const std = @import("std");

pub const MouseEventKind = enum {
    down,
    up,
    move,
    wheel,
};

pub const MouseButton = enum {
    left,
    middle,
    right,
    none,
};

pub const MouseEvent = struct {
    kind: MouseEventKind,
    /// 0-based terminal column.
    x: usize,
    /// 0-based terminal row.
    y: usize,
    button: MouseButton = .none,
    /// Bitset: shift=1, alt=2, ctrl=4.
    mods: u8 = 0,
    wheel_dx: isize = 0,
    wheel_dy: isize = 0,
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

    if (final != 'M' and final != 'm') return null;

    const x0: usize = if (x1 > 0) @as(usize, x1 - 1) else 0;
    const y0: usize = if (y1 > 0) @as(usize, y1 - 1) else 0;

    var mods: u8 = 0;
    if ((b & 4) != 0) mods |= 1; // shift
    if ((b & 8) != 0) mods |= 2; // alt
    if ((b & 16) != 0) mods |= 4; // ctrl

    const is_motion: bool = (b & 32) != 0;
    const is_wheel: bool = (b & 64) != 0;
    const button_code: u32 = b & 3;

    if (is_wheel) {
        var dx: isize = 0;
        var dy: isize = 0;
        switch (button_code) {
            0 => dy = -1,
            1 => dy = 1,
            2 => dx = -1,
            3 => dx = 1,
            else => {},
        }
        return .{
            .kind = .wheel,
            .x = x0,
            .y = y0,
            .mods = mods,
            .wheel_dx = dx,
            .wheel_dy = dy,
        };
    }

    if (is_motion) {
        return .{ .kind = .move, .x = x0, .y = y0, .mods = mods };
    }

    const button: MouseButton = switch (button_code) {
        0 => .left,
        1 => .middle,
        2 => .right,
        else => .none,
    };

    if (final == 'm') {
        return .{ .kind = .up, .x = x0, .y = y0, .button = button, .mods = mods };
    }

    if (button == .none) return null;
    return .{ .kind = .down, .x = x0, .y = y0, .button = button, .mods = mods };
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

const std = @import("std");

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,
};

pub const ColorMode = enum {
    /// No colors; attributes may still be emitted.
    mono,
    ansi16,
    ansi256,
    truecolor,
};

pub const ParseColorError = error{
    InvalidColor,
};

pub fn rgbToU24(c: Rgb) u24 {
    return (@as(u24, c.r) << 16) | (@as(u24, c.g) << 8) | @as(u24, c.b);
}

pub fn u24ToRgb(v: u24) Rgb {
    return .{
        .r = @as(u8, @intCast((v >> 16) & 0xff)),
        .g = @as(u8, @intCast((v >> 8) & 0xff)),
        .b = @as(u8, @intCast(v & 0xff)),
    };
}

fn fromHexNibble(b: u8) ?u8 {
    return switch (b) {
        '0'...'9' => b - '0',
        'a'...'f' => 10 + (b - 'a'),
        'A'...'F' => 10 + (b - 'A'),
        else => null,
    };
}

fn parseHexByte2(two: []const u8) ?u8 {
    if (two.len != 2) return null;
    const hi = fromHexNibble(two[0]) orelse return null;
    const lo = fromHexNibble(two[1]) orelse return null;
    return (hi << 4) | lo;
}

fn parseHexColor(s: []const u8) ?Rgb {
    if (s.len != 7 or s[0] != '#') return null;
    const r = parseHexByte2(s[1..3]) orelse return null;
    const g = parseHexByte2(s[3..5]) orelse return null;
    const b = parseHexByte2(s[5..7]) orelse return null;
    return .{ .r = r, .g = g, .b = b };
}

const css_color_names = std.StaticStringMap(u24).initComptime(.{
    .{ "black", 0x000000 },
    .{ "white", 0xffffff },
    .{ "red", 0xff0000 },
    .{ "green", 0x008000 },
    .{ "blue", 0x0000ff },
    .{ "yellow", 0xffff00 },
    .{ "cyan", 0x00ffff },
    .{ "magenta", 0xff00ff },
    .{ "silver", 0xc0c0c0 },
    .{ "gray", 0x808080 },
    .{ "grey", 0x808080 },
    .{ "maroon", 0x800000 },
    .{ "olive", 0x808000 },
    .{ "lime", 0x00ff00 },
    .{ "aqua", 0x00ffff },
    .{ "teal", 0x008080 },
    .{ "navy", 0x000080 },
    .{ "fuchsia", 0xff00ff },
    .{ "purple", 0x800080 },
    .{ "orange", 0xffa500 },
    .{ "brightblack", 0x666666 },
    .{ "brightred", 0xff6666 },
    .{ "brightgreen", 0x66ff66 },
    .{ "brightblue", 0x6666ff },
    .{ "brightyellow", 0xffff66 },
    .{ "brightcyan", 0x66ffff },
    .{ "brightmagenta", 0xff66ff },
    .{ "brightwhite", 0xffffff },
});

fn parseCssName(s: []const u8) ?Rgb {
    if (s.len == 0 or s.len > 64) return null;
    var lower_buf: [64]u8 = undefined;
    for (s, 0..) |b, i| {
        lower_buf[i] = std.ascii.toLower(b);
    }
    const lower = lower_buf[0..s.len];
    const v = css_color_names.get(lower) orelse return null;
    return u24ToRgb(@as(u24, @intCast(v)));
}

pub fn parseColorSpec(s: []const u8) ParseColorError!Rgb {
    if (parseHexColor(s)) |c| return c;
    if (parseCssName(s)) |c| return c;
    return error.InvalidColor;
}

fn nearestIndex16(c: Rgb) u4 {
    const palette = [_]Rgb{
        .{ .r = 0, .g = 0, .b = 0 }, // 0 black
        .{ .r = 205, .g = 0, .b = 0 }, // 1 red
        .{ .r = 0, .g = 205, .b = 0 }, // 2 green
        .{ .r = 205, .g = 205, .b = 0 }, // 3 yellow
        .{ .r = 0, .g = 0, .b = 238 }, // 4 blue
        .{ .r = 205, .g = 0, .b = 205 }, // 5 magenta
        .{ .r = 0, .g = 205, .b = 205 }, // 6 cyan
        .{ .r = 229, .g = 229, .b = 229 }, // 7 white (light gray)
        .{ .r = 127, .g = 127, .b = 127 }, // 8 bright black (dark gray)
        .{ .r = 255, .g = 0, .b = 0 }, // 9 bright red
        .{ .r = 0, .g = 255, .b = 0 }, // 10 bright green
        .{ .r = 255, .g = 255, .b = 0 }, // 11 bright yellow
        .{ .r = 92, .g = 92, .b = 255 }, // 12 bright blue
        .{ .r = 255, .g = 0, .b = 255 }, // 13 bright magenta
        .{ .r = 0, .g = 255, .b = 255 }, // 14 bright cyan
        .{ .r = 255, .g = 255, .b = 255 }, // 15 bright white
    };

    var best: u4 = 0;
    var best_dist: u32 = 0xffffffff;
    for (palette, 0..) |p, idx| {
        const dr: i32 = @as(i32, c.r) - @as(i32, p.r);
        const dg: i32 = @as(i32, c.g) - @as(i32, p.g);
        const db: i32 = @as(i32, c.b) - @as(i32, p.b);
        const dist: u32 = @as(u32, @intCast(dr * dr + dg * dg + db * db));
        if (dist < best_dist) {
            best_dist = dist;
            best = @as(u4, @intCast(idx));
        }
    }
    return best;
}

pub fn rgbToAnsi16(c: Rgb) u4 {
    return nearestIndex16(c);
}

fn cubeIndex(v: u8) u3 {
    // 0..255 -> 0..5, rounded to nearest.
    return @as(u3, @intCast((@as(u16, v) + 25) / 51));
}

fn cubeValue(i: u3) u8 {
    const levels = [_]u8{ 0, 95, 135, 175, 215, 255 };
    return levels[@as(usize, i)];
}

fn grayIndex(v: u8) u5 {
    if (v < 8) return 0;
    if (v > 248) return 23;
    return @as(u5, @intCast((@as(u16, v) - 8) / 10));
}

pub fn rgbToXterm256(c: Rgb) u8 {
    const ri = cubeIndex(c.r);
    const gi = cubeIndex(c.g);
    const bi = cubeIndex(c.b);

    const cube_r = cubeValue(ri);
    const cube_g = cubeValue(gi);
    const cube_b = cubeValue(bi);
    const cube_index: u8 = 16 + 36 * @as(u8, @intCast(ri)) + 6 * @as(u8, @intCast(gi)) + @as(u8, @intCast(bi));

    const gray_i = grayIndex(@as(u8, @intCast((@as(u16, c.r) + @as(u16, c.g) + @as(u16, c.b)) / 3)));
    const gray_v: u8 = 8 + 10 * @as(u8, @intCast(gray_i));
    const gray_index: u8 = 232 + @as(u8, @intCast(gray_i));

    const cube_dr: i32 = @as(i32, c.r) - @as(i32, cube_r);
    const cube_dg: i32 = @as(i32, c.g) - @as(i32, cube_g);
    const cube_db: i32 = @as(i32, c.b) - @as(i32, cube_b);
    const cube_dist: u32 = @as(u32, @intCast(cube_dr * cube_dr + cube_dg * cube_dg + cube_db * cube_db));

    const gray_dr: i32 = @as(i32, c.r) - @as(i32, gray_v);
    const gray_dg: i32 = @as(i32, c.g) - @as(i32, gray_v);
    const gray_db: i32 = @as(i32, c.b) - @as(i32, gray_v);
    const gray_dist: u32 = @as(u32, @intCast(gray_dr * gray_dr + gray_dg * gray_dg + gray_db * gray_db));

    return if (gray_dist < cube_dist) gray_index else cube_index;
}

fn getenvOwned(name: []const u8) ?[]u8 {
    return std.process.getEnvVarOwned(std.heap.page_allocator, name) catch |e| switch (e) {
        error.EnvironmentVariableNotFound => null,
        else => null,
    };
}

fn envBoolPresent(name: []const u8) bool {
    const v = getenvOwned(name) orelse return false;
    std.heap.page_allocator.free(v);
    return true;
}

fn containsInsensitive(haystack: []const u8, needle: []const u8) bool {
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var ok = true;
        for (needle, 0..) |b, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(b)) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

fn parseModeOverride(s: []const u8) ?ColorMode {
    if (containsInsensitive(s, "truecolor") or containsInsensitive(s, "24bit")) return .truecolor;
    if (std.mem.eql(u8, s, "256") or containsInsensitive(s, "256")) return .ansi256;
    if (std.mem.eql(u8, s, "16") or containsInsensitive(s, "16")) return .ansi16;
    if (containsInsensitive(s, "mono") or containsInsensitive(s, "none") or containsInsensitive(s, "off")) return .mono;
    return null;
}

pub fn detectColorMode() ColorMode {
    if (envBoolPresent("NO_COLOR")) return .mono;

    if (getenvOwned("TUI_COLOR_MODE")) |v| {
        defer std.heap.page_allocator.free(v);
        if (parseModeOverride(v)) |m| return m;
    }

    if (getenvOwned("COLORTERM")) |v| {
        defer std.heap.page_allocator.free(v);
        if (containsInsensitive(v, "truecolor") or containsInsensitive(v, "24bit")) return .truecolor;
    }

    if (getenvOwned("TERM")) |v| {
        defer std.heap.page_allocator.free(v);
        if (containsInsensitive(v, "256color")) return .ansi256;
    }

    return .ansi16;
}

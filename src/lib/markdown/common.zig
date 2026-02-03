const std = @import("std");

pub fn trimCr(line: []const u8) []const u8 {
    if (line.len != 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

pub fn isBlank(line: []const u8) bool {
    for (line) |b| {
        if (b != ' ' and b != '\t' and b != '\r') return false;
    }
    return true;
}

pub const Heading = struct { level: u8, text: []const u8 };

pub fn parseHeading(line: []const u8) ?Heading {
    var level: u8 = 0;
    while (level < 6 and level < line.len and line[level] == '#') : (level += 1) {}
    if (level == 0) return null;
    if (level >= line.len or line[level] != ' ') return null;
    const rest = line[level + 1 ..];
    return .{ .level = level, .text = rest };
}

pub const Item = struct { text: []const u8 };

pub fn parseListItem(line: []const u8) ?Item {
    if (line.len < 2) return null;
    if ((line[0] == '-' or line[0] == '*' or line[0] == '+') and line[1] == ' ') {
        return .{ .text = line[2..] };
    }
    return null;
}

pub fn parseBlockquote(line: []const u8) ?Item {
    if (line.len < 2) return null;
    if (line[0] == '>' and line[1] == ' ') {
        return .{ .text = line[2..] };
    }
    return null;
}

pub fn joinLinesLeaky(allocator: std.mem.Allocator, lines: []const []const u8) std.mem.Allocator.Error![]const u8 {
    if (lines.len == 0) return allocator.dupe(u8, "");
    if (lines.len == 1) return allocator.dupe(u8, lines[0]);

    var total: usize = 0;
    for (lines) |l| total += l.len;
    total += lines.len - 1;

    var out = try allocator.alloc(u8, total);
    var off: usize = 0;
    for (lines, 0..) |l, i| {
        if (i != 0) {
            out[off] = '\n';
            off += 1;
        }
        @memcpy(out[off .. off + l.len], l);
        off += l.len;
    }
    return out;
}

pub fn normalizeNewlinesLeaky(allocator: std.mem.Allocator, md: []const u8) std.mem.Allocator.Error![]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);

    var it = std.mem.splitScalar(u8, md, '\n');
    while (it.next()) |raw_line| {
        try lines.append(allocator, trimCr(raw_line));
    }
    return joinLinesLeaky(allocator, lines.items);
}

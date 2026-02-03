const std = @import("std");

pub const Grapheme = struct {
    start: usize, // byte offset
    end: usize, // byte offset (exclusive)
    width: usize, // display cells (0/1/2)
};

const Decoded = struct {
    cp: u21,
    len: usize,
};

fn decodeAt(bytes: []const u8, i: usize) Decoded {
    if (i >= bytes.len) return .{ .cp = 0, .len = 0 };

    const first = bytes[i];
    const seq_len = std.unicode.utf8ByteSequenceLength(first) catch return .{
        .cp = std.unicode.replacement_character,
        .len = 1,
    };

    if (i + seq_len > bytes.len) return .{ .cp = std.unicode.replacement_character, .len = 1 };

    const cp = std.unicode.utf8Decode(bytes[i .. i + seq_len]) catch std.unicode.replacement_character;
    return .{ .cp = cp, .len = seq_len };
}

fn inRange(cp: u21, start: u21, end: u21) bool {
    return cp >= start and cp <= end;
}

fn isVariationSelector(cp: u21) bool {
    return inRange(cp, 0xFE00, 0xFE0F) or inRange(cp, 0xE0100, 0xE01EF);
}

fn isZwJ(cp: u21) bool {
    return cp == 0x200D;
}

fn isSkinToneModifier(cp: u21) bool {
    return inRange(cp, 0x1F3FB, 0x1F3FF);
}

fn isRegionalIndicator(cp: u21) bool {
    return inRange(cp, 0x1F1E6, 0x1F1FF);
}

fn isCombiningMark(cp: u21) bool {
    // This is a deliberately incomplete approximation (good enough for tracer UX).
    return inRange(cp, 0x0300, 0x036F) or // Combining Diacritical Marks
        inRange(cp, 0x1AB0, 0x1AFF) or // Combining Diacritical Marks Extended
        inRange(cp, 0x1DC0, 0x1DFF) or // Combining Diacritical Marks Supplement
        inRange(cp, 0x20D0, 0x20FF) or // Combining Diacritical Marks for Symbols
        inRange(cp, 0xFE20, 0xFE2F); // Combining Half Marks
}

const Interval = struct { start: u21, end: u21 };

const wide_intervals = [_]Interval{
    // Rough wcwidth-ish wide set (not locale/EA-ambiguous aware).
    .{ .start = 0x1100, .end = 0x115F }, // Hangul Jamo init. consonants
    .{ .start = 0x2329, .end = 0x232A }, // angle brackets
    .{ .start = 0x2E80, .end = 0xA4CF }, // CJK Radicals .. Yi (approx)
    .{ .start = 0xAC00, .end = 0xD7A3 }, // Hangul syllables
    .{ .start = 0xF900, .end = 0xFAFF }, // CJK Compatibility Ideographs
    .{ .start = 0xFE10, .end = 0xFE19 }, // Vertical forms
    .{ .start = 0xFE30, .end = 0xFE6F }, // CJK Compatibility Forms .. Small Form Variants
    .{ .start = 0xFF01, .end = 0xFF60 }, // Fullwidth ASCII variants
    .{ .start = 0xFFE0, .end = 0xFFE6 }, // Fullwidth symbol variants
    .{ .start = 0x2600, .end = 0x27BF }, // Misc symbols / dingbats (emoji-ish)
    .{ .start = 0x1F1E6, .end = 0x1F1FF }, // Regional indicators (flags)
    .{ .start = 0x1F300, .end = 0x1FAFF }, // Emoji blocks (approx)
};

fn isWide(cp: u21) bool {
    var lo: usize = 0;
    var hi: usize = wide_intervals.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const it = wide_intervals[mid];
        if (cp < it.start) {
            hi = mid;
        } else if (cp > it.end) {
            lo = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}

pub fn cellWidth(cp: u21) u2 {
    if (isCombiningMark(cp) or isVariationSelector(cp) or isZwJ(cp)) return 0;
    if (isWide(cp)) return 2;
    return 1;
}

pub fn nextGrapheme(bytes: []const u8, start_byte: usize) Grapheme {
    const start: usize = @min(start_byte, bytes.len);
    if (start == bytes.len) return .{ .start = start, .end = start, .width = 0 };

    const d0 = decodeAt(bytes, start);
    if (d0.len == 0) return .{ .start = start, .end = start, .width = 0 };

    var end: usize = start + d0.len;
    var width: usize = @as(usize, cellWidth(d0.cp));

    // Regional indicator pair => one grapheme (flag), width=2.
    if (isRegionalIndicator(d0.cp)) {
        const d1 = decodeAt(bytes, end);
        if (d1.len > 0 and isRegionalIndicator(d1.cp)) {
            end += d1.len;
            width = 2;
        }
        return .{ .start = start, .end = end, .width = width };
    }

    var i: usize = end;
    while (i < bytes.len) {
        const d = decodeAt(bytes, i);
        if (d.len == 0) break;

        if (isCombiningMark(d.cp) or isVariationSelector(d.cp)) {
            i += d.len;
            end = i;
            continue;
        }

        if (isSkinToneModifier(d.cp)) {
            i += d.len;
            end = i;
            continue;
        }

        if (isZwJ(d.cp)) {
            // Include ZWJ + next codepoint (and its extenders).
            const after_zwj = i + d.len;
            const d_next = decodeAt(bytes, after_zwj);
            if (d_next.len == 0) break;
            i = after_zwj + d_next.len;
            end = i;
            const w = @as(usize, cellWidth(d_next.cp));
            if (w > width) width = w;
            continue;
        }

        break;
    }

    return .{ .start = start, .end = end, .width = width };
}

pub fn displayWidth(bytes: []const u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const g = nextGrapheme(bytes, i);
        if (g.end <= i) break;
        w += g.width;
        i = g.end;
    }
    return w;
}

pub fn sliceEndByWidth(bytes: []const u8, start_byte: usize, max_cols: usize) usize {
    const start: usize = @min(start_byte, bytes.len);
    if (max_cols == 0 or start == bytes.len) return start;

    var used: usize = 0;
    var i: usize = start;
    while (i < bytes.len) {
        const g = nextGrapheme(bytes, i);
        if (g.end <= i) break;
        if (g.width > 0 and used + g.width > max_cols) break;
        used += g.width;
        i = g.end;
    }
    return i;
}

pub fn prevGraphemeBoundary(bytes: []const u8, cursor_byte: usize) usize {
    const cursor: usize = @min(cursor_byte, bytes.len);
    if (cursor == 0) return 0;

    var i: usize = 0;
    var prev: usize = 0;
    while (i < cursor) {
        prev = i;
        const g = nextGrapheme(bytes, i);
        if (g.end <= i) break;
        i = g.end;
    }
    return prev;
}

pub fn clampGraphemeBoundary(bytes: []const u8, offset_byte: usize) usize {
    const offset: usize = @min(offset_byte, bytes.len);
    if (offset == 0 or offset == bytes.len) return offset;

    var i: usize = 0;
    var last_boundary: usize = 0;
    while (i < bytes.len) {
        if (i == offset) return offset;
        if (i > offset) return last_boundary;

        last_boundary = i;
        const g = nextGrapheme(bytes, i);
        if (g.end <= i) break;
        i = g.end;

        if (i == offset) return offset;
        if (i > offset) return last_boundary;
    }
    return offset;
}

pub fn nextGraphemeBoundary(bytes: []const u8, cursor_byte: usize) usize {
    const cursor: usize = @min(cursor_byte, bytes.len);
    if (cursor == bytes.len) return bytes.len;

    var i: usize = 0;
    while (i < bytes.len) {
        const g = nextGrapheme(bytes, i);
        if (g.end <= i) break;
        if (cursor <= g.start) return g.end;
        if (cursor < g.end) return g.end;
        i = g.end;
    }
    return bytes.len;
}

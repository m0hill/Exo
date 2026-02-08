const std = @import("std");
const builtin = @import("builtin");

pub const Grapheme = struct {
    start: usize,
    end: usize,
    width: usize,
};

pub const WidthAmbiguousPolicy = enum {
    narrow,
    wide,
};

pub const Options = struct {
    ambiguous_width: WidthAmbiguousPolicy = .narrow,
    tab_width: usize = 4,
    fast_approx: bool = false,
};

pub const VisualPos = struct {
    y: usize,
    x: usize,
};

const Decoded = struct {
    cp: u21,
    len: usize,
};

const Interval = struct {
    start: u21,
    end: u21,
};

const GraphemeClass = enum {
    other,
    cr,
    lf,
    control,
    extend,
    zwj,
    regional_indicator,
    prepend,
    spacing_mark,
    l,
    v,
    t,
    lv,
    lvt,
};

pub const WrappedGrapheme = struct {
    grapheme: Grapheme,
    row: usize,
    col: usize,
    width: usize,
};

pub const WrapIter = struct {
    metrics: *const TextMetrics,
    bytes: []const u8,
    cols: usize,
    idx: usize,
    row: usize,
    col: usize,

    pub fn next(self: *WrapIter) ?WrappedGrapheme {
        while (self.idx < self.bytes.len) {
            const g = self.metrics.nextGrapheme(self.bytes, self.idx);
            if (g.end <= self.idx) return null;

            const b0: u8 = self.bytes[g.start];
            if (b0 == '\r') {
                self.idx = g.end;
                continue;
            }
            if (b0 == '\n') {
                self.idx = g.end;
                self.row += 1;
                self.col = 0;
                continue;
            }

            var width = g.width;
            if (b0 == '\t') {
                width = self.metrics.tabAdvance(self.col);
            }
            if (width == 0) {
                self.idx = g.end;
                continue;
            }

            if (self.cols == 0) {
                self.idx = g.end;
                continue;
            }

            if (width > self.cols) {
                self.idx = g.end;
                continue;
            }

            if (self.col > 0 and self.col + width > self.cols) {
                self.row += 1;
                self.col = 0;
                continue;
            }

            const out: WrappedGrapheme = .{
                .grapheme = g,
                .row = self.row,
                .col = self.col,
                .width = width,
            };
            self.idx = g.end;
            self.col += width;
            return out;
        }

        return null;
    }
};

pub const TextMetrics = struct {
    options: Options,

    pub fn init(options: Options) TextMetrics {
        var out = options;
        if (out.tab_width == 0) out.tab_width = 4;
        return .{ .options = out };
    }

    pub fn nextGrapheme(self: *const TextMetrics, bytes: []const u8, start_byte: usize) Grapheme {
        const start: usize = @min(start_byte, bytes.len);
        if (start == bytes.len) return .{ .start = start, .end = start, .width = 0 };
        // Fast path for common ASCII runs. Keep CRLF handling on the slow path.
        if (bytes[start] < 0x80 and
            (start + 1 >= bytes.len or bytes[start + 1] < 0x80) and
            !(bytes[start] == '\r' and start + 1 < bytes.len and bytes[start + 1] == '\n'))
        {
            return .{
                .start = start,
                .end = start + 1,
                .width = asciiCellWidth(bytes[start]),
            };
        }

        if (self.options.fast_approx) return nextGraphemeApprox(self, bytes, start_byte);

        const d0 = decodeAt(bytes, start);
        if (d0.len == 0) return .{ .start = start, .end = start, .width = 0 };

        var end: usize = start + d0.len;
        var prev_class = graphemeClass(d0.cp);
        var prev_non_extend_is_ep = isExtendedPictographic(d0.cp);
        var zwj_links_ep: bool = false;
        var prev_was_zwj: bool = false;
        var ri_run: usize = if (prev_class == .regional_indicator) 1 else 0;

        while (end < bytes.len) {
            const d = decodeAt(bytes, end);
            if (d.len == 0) break;

            const next_class = graphemeClass(d.cp);

            if (!shouldBreak(prev_class, next_class, ri_run, prev_was_zwj, zwj_links_ep, d.cp)) {
                end += d.len;

                if (next_class == .regional_indicator) {
                    ri_run += 1;
                } else {
                    ri_run = 0;
                }

                if (next_class == .zwj) {
                    prev_was_zwj = true;
                    zwj_links_ep = prev_non_extend_is_ep;
                } else if (next_class != .extend and next_class != .spacing_mark) {
                    prev_was_zwj = false;
                    zwj_links_ep = false;
                    prev_non_extend_is_ep = isExtendedPictographic(d.cp);
                }

                prev_class = next_class;
                continue;
            }

            break;
        }

        const width = self.graphemeWidth(bytes[start..end]);
        return .{ .start = start, .end = end, .width = width };
    }

    pub fn cellWidth(self: *const TextMetrics, cp: u21) u2 {
        return cellWidthWithMetrics(self, cp);
    }

    pub fn prevGraphemeBoundary(self: *const TextMetrics, bytes: []const u8, cursor_byte: usize) usize {
        const cursor: usize = @min(cursor_byte, bytes.len);
        if (cursor == 0) return 0;

        var i: usize = 0;
        var prev: usize = 0;
        while (i < cursor) {
            prev = i;
            const g = self.nextGrapheme(bytes, i);
            if (g.end <= i) break;
            i = g.end;
        }
        return prev;
    }

    pub fn nextGraphemeBoundary(self: *const TextMetrics, bytes: []const u8, cursor_byte: usize) usize {
        const cursor: usize = @min(cursor_byte, bytes.len);
        if (cursor == bytes.len) return bytes.len;

        var i: usize = 0;
        while (i < bytes.len) {
            const g = self.nextGrapheme(bytes, i);
            if (g.end <= i) break;
            if (cursor <= g.start) return g.end;
            if (cursor < g.end) return g.end;
            i = g.end;
        }
        return bytes.len;
    }

    pub fn clampGraphemeBoundary(self: *const TextMetrics, bytes: []const u8, offset_byte: usize) usize {
        const offset: usize = @min(offset_byte, bytes.len);
        if (offset == 0 or offset == bytes.len) return offset;

        var i: usize = 0;
        var last_boundary: usize = 0;
        while (i < bytes.len) {
            if (i == offset) return offset;
            if (i > offset) return last_boundary;

            last_boundary = i;
            const g = self.nextGrapheme(bytes, i);
            if (g.end <= i) break;
            i = g.end;

            if (i == offset) return offset;
            if (i > offset) return last_boundary;
        }
        return offset;
    }

    pub fn displayWidth(self: *const TextMetrics, bytes: []const u8) usize {
        var w: usize = 0;
        var line_col: usize = 0;
        var i: usize = 0;
        while (i < bytes.len) {
            const g = self.nextGrapheme(bytes, i);
            if (g.end <= i) break;

            const b0 = bytes[g.start];
            if (b0 == '\r') {
                i = g.end;
                continue;
            }
            if (b0 == '\n') {
                line_col = 0;
                i = g.end;
                continue;
            }
            if (b0 == '\t') {
                const adv = self.tabAdvance(line_col);
                w += adv;
                line_col += adv;
                i = g.end;
                continue;
            }

            w += g.width;
            line_col += g.width;
            i = g.end;
        }
        return w;
    }

    pub fn sliceByWidth(self: *const TextMetrics, bytes: []const u8, start_byte: usize, max_cols: usize) usize {
        const start: usize = @min(start_byte, bytes.len);
        if (max_cols == 0 or start == bytes.len) return start;

        var used: usize = 0;
        var i: usize = start;
        while (i < bytes.len) {
            const g = self.nextGrapheme(bytes, i);
            if (g.end <= i) break;

            const b0: u8 = bytes[g.start];
            if (b0 == '\r' or b0 == '\n') break;

            var w = g.width;
            if (b0 == '\t') w = self.tabAdvance(used);
            if (w > 0 and used + w > max_cols) break;

            used += w;
            i = g.end;
        }
        return i;
    }

    pub fn wrapIter(self: *const TextMetrics, bytes: []const u8, cols: usize) WrapIter {
        return .{
            .metrics = self,
            .bytes = bytes,
            .cols = cols,
            .idx = 0,
            .row = 0,
            .col = 0,
        };
    }

    pub fn visualPosForByte(self: *const TextMetrics, bytes: []const u8, cursor_byte: usize, cols: usize) VisualPos {
        const cursor = self.clampGraphemeBoundary(bytes, @min(cursor_byte, bytes.len));
        var i: usize = 0;
        var y: usize = 0;
        var x: usize = 0;

        while (i < bytes.len) {
            if (i >= cursor) return .{ .y = y, .x = x };

            const g = self.nextGrapheme(bytes, i);
            if (g.end <= i) break;

            const b0: u8 = bytes[g.start];
            if (b0 == '\r') {
                i = g.end;
                continue;
            }
            if (b0 == '\n') {
                i = g.end;
                y += 1;
                x = 0;
                continue;
            }

            const width = self.graphemeWidthAtCol(bytes, g, x);
            if (width == 0 or cols == 0 or width > cols) {
                i = g.end;
                continue;
            }
            if (x > 0 and x + width > cols) {
                y += 1;
                x = 0;
                continue;
            }

            x += width;
            i = g.end;
        }

        return .{ .y = y, .x = x };
    }

    pub fn byteForVisualPos(self: *const TextMetrics, bytes: []const u8, target_y: usize, target_x: usize, cols: usize) usize {
        var i: usize = 0;
        var y: usize = 0;
        var x: usize = 0;
        var found: bool = false;
        var best_byte: usize = 0;
        var best_x: usize = 0;

        while (true) {
            if (y == target_y) {
                if (!found) {
                    found = true;
                    best_byte = i;
                    best_x = x;
                } else if (x <= target_x and x >= best_x) {
                    best_x = x;
                    best_byte = i;
                }
            }

            if (i >= bytes.len) break;

            const g = self.nextGrapheme(bytes, i);
            if (g.end <= i) break;

            const b0: u8 = bytes[g.start];
            if (b0 == '\r') {
                i = g.end;
                continue;
            }
            if (b0 == '\n') {
                i = g.end;
                y += 1;
                x = 0;
                continue;
            }

            const width = self.graphemeWidthAtCol(bytes, g, x);
            if (width == 0 or cols == 0 or width > cols) {
                i = g.end;
                continue;
            }
            if (x > 0 and x + width > cols) {
                y += 1;
                x = 0;
                continue;
            }

            i = g.end;
            x += width;
        }

        if (!found) return @min(bytes.len, self.clampGraphemeBoundary(bytes, bytes.len));
        return self.clampGraphemeBoundary(bytes, best_byte);
    }

    pub fn graphemeWidthAtCol(self: *const TextMetrics, bytes: []const u8, g: Grapheme, col: usize) usize {
        const b0 = bytes[g.start];
        if (b0 == '\t') return self.tabAdvance(col);
        if (b0 == '\r' or b0 == '\n') return 0;
        return g.width;
    }

    fn tabAdvance(self: *const TextMetrics, col: usize) usize {
        const tabw = self.options.tab_width;
        const rem = col % tabw;
        return if (rem == 0) tabw else tabw - rem;
    }

    fn graphemeWidth(self: *const TextMetrics, bytes: []const u8) usize {
        if (bytes.len == 0) return 0;

        var i: usize = 0;
        var max_width: usize = 0;
        var has_zwj: bool = false;
        var has_vs16: bool = false;
        var has_vs15: bool = false;
        var ri_count: usize = 0;
        var has_ep: bool = false;
        var has_non_zero_base: bool = false;

        while (i < bytes.len) {
            const d = decodeAt(bytes, i);
            if (d.len == 0) break;

            if (d.cp == 0x200D) has_zwj = true;
            if (d.cp == 0xFE0F) has_vs16 = true;
            if (d.cp == 0xFE0E) has_vs15 = true;
            if (isRegionalIndicator(d.cp)) ri_count += 1;
            if (isExtendedPictographic(d.cp)) has_ep = true;

            const w = cellWidthWithMetrics(self, d.cp);
            if (w > 0) {
                has_non_zero_base = true;
                if (w > max_width) max_width = w;
            }
            i += d.len;
        }

        if (!has_non_zero_base) return 0;

        if (ri_count >= 2) return 2;
        if ((has_zwj and has_ep) or has_vs16) return 2;
        if (has_vs15 and max_width > 1) return 1;
        return max_width;
    }
};

fn asciiCellWidth(b: u8) usize {
    if (b == '\r' or b == '\n' or b == '\t' or b < 0x20 or b == 0x7F) return 0;
    return 1;
}

fn nextGraphemeApprox(self: *const TextMetrics, bytes: []const u8, start_byte: usize) Grapheme {
    const start: usize = @min(start_byte, bytes.len);
    if (start == bytes.len) return .{ .start = start, .end = start, .width = 0 };

    const d0 = decodeAt(bytes, start);
    if (d0.len == 0) return .{ .start = start, .end = start, .width = 0 };

    var end: usize = start + d0.len;
    var width: usize = @as(usize, cellWidthWithMetrics(self, d0.cp));

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

        const gc = graphemeClass(d.cp);
        if (gc == .extend or gc == .spacing_mark) {
            i += d.len;
            end = i;
            continue;
        }

        if (isSkinToneModifier(d.cp)) {
            i += d.len;
            end = i;
            continue;
        }

        if (d.cp == 0x200D) {
            const after_zwj = i + d.len;
            const d_next = decodeAt(bytes, after_zwj);
            if (d_next.len == 0) break;
            i = after_zwj + d_next.len;
            end = i;
            const w = @as(usize, cellWidthWithMetrics(self, d_next.cp));
            if (w > width) width = w;
            continue;
        }

        break;
    }

    return .{ .start = start, .end = end, .width = width };
}

fn defaultOptionsFromEnv() Options {
    var out = Options{};
    if (builtin.is_test) return out;
    const allocator = std.heap.page_allocator;

    if (std.process.getEnvVarOwned(allocator, "TUI_UNICODE_AMBIGUOUS_WIDTH")) |value| {
        defer allocator.free(value);
        if (std.ascii.eqlIgnoreCase(value, "2") or std.ascii.eqlIgnoreCase(value, "wide")) {
            out.ambiguous_width = .wide;
        } else if (std.ascii.eqlIgnoreCase(value, "1") or std.ascii.eqlIgnoreCase(value, "narrow")) {
            out.ambiguous_width = .narrow;
        }
    } else |_| {}

    if (std.process.getEnvVarOwned(allocator, "TUI_TAB_WIDTH")) |value| {
        defer allocator.free(value);
        const parsed = std.fmt.parseInt(usize, value, 10) catch out.tab_width;
        if (parsed > 0 and parsed <= 64) out.tab_width = parsed;
    } else |_| {}

    if (std.process.getEnvVarOwned(allocator, "TUI_UNICODE_FAST_APPROX")) |value| {
        defer allocator.free(value);
        out.fast_approx = std.ascii.eqlIgnoreCase(value, "1") or
            std.ascii.eqlIgnoreCase(value, "true") or
            std.ascii.eqlIgnoreCase(value, "yes");
    } else |_| {}

    return out;
}

var default_text_metrics_initialized: bool = false;
var default_text_metrics_storage: TextMetrics = TextMetrics.init(.{});

pub fn defaultTextMetrics() *const TextMetrics {
    if (!default_text_metrics_initialized) {
        default_text_metrics_storage = TextMetrics.init(defaultOptionsFromEnv());
        default_text_metrics_initialized = true;
    }
    return &default_text_metrics_storage;
}

pub fn textMetrics(options: Options) TextMetrics {
    return TextMetrics.init(options);
}

pub fn cellWidth(cp: u21) u2 {
    return cellWidthWithMetrics(defaultTextMetrics(), cp);
}

fn cellWidthWithMetrics(metrics: *const TextMetrics, cp: u21) u2 {
    if (cp == 0) return 0;
    if (isControl(cp) or isZeroWidth(cp) or cp == 0x200D or isVariationSelector(cp)) return 0;
    if (isWide(cp) or isExtendedPictographic(cp)) return 2;
    if (isAmbiguous(cp)) {
        return if (metrics.options.ambiguous_width == .wide) 2 else 1;
    }
    return 1;
}

pub fn nextGrapheme(bytes: []const u8, start_byte: usize) Grapheme {
    return defaultTextMetrics().nextGrapheme(bytes, start_byte);
}

pub fn displayWidth(bytes: []const u8) usize {
    return defaultTextMetrics().displayWidth(bytes);
}

pub fn sliceEndByWidth(bytes: []const u8, start_byte: usize, max_cols: usize) usize {
    return defaultTextMetrics().sliceByWidth(bytes, start_byte, max_cols);
}

pub fn prevGraphemeBoundary(bytes: []const u8, cursor_byte: usize) usize {
    return defaultTextMetrics().prevGraphemeBoundary(bytes, cursor_byte);
}

pub fn clampGraphemeBoundary(bytes: []const u8, offset_byte: usize) usize {
    return defaultTextMetrics().clampGraphemeBoundary(bytes, offset_byte);
}

pub fn nextGraphemeBoundary(bytes: []const u8, cursor_byte: usize) usize {
    return defaultTextMetrics().nextGraphemeBoundary(bytes, cursor_byte);
}

pub fn wrapIterator(bytes: []const u8, cols: usize) WrapIter {
    return defaultTextMetrics().wrapIter(bytes, cols);
}

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

fn inIntervals(cp: u21, table: []const Interval) bool {
    var lo: usize = 0;
    var hi: usize = table.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const it = table[mid];
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

fn isControl(cp: u21) bool {
    return cp <= 0x1F or inRange(cp, 0x7F, 0x9F);
}

fn isVariationSelector(cp: u21) bool {
    return inRange(cp, 0xFE00, 0xFE0F) or inRange(cp, 0xE0100, 0xE01EF);
}

fn isZeroWidth(cp: u21) bool {
    return inIntervals(cp, &zero_width_intervals);
}

fn isAmbiguous(cp: u21) bool {
    return inIntervals(cp, &ambiguous_intervals);
}

fn isWide(cp: u21) bool {
    return inIntervals(cp, &wide_intervals);
}

fn isRegionalIndicator(cp: u21) bool {
    return inRange(cp, 0x1F1E6, 0x1F1FF);
}

fn isSkinToneModifier(cp: u21) bool {
    return inRange(cp, 0x1F3FB, 0x1F3FF);
}

fn isExtendedPictographic(cp: u21) bool {
    return inIntervals(cp, &extended_pictographic_intervals);
}

fn isHangulL(cp: u21) bool {
    return inRange(cp, 0x1100, 0x115F) or inRange(cp, 0xA960, 0xA97C);
}

fn isHangulV(cp: u21) bool {
    return inRange(cp, 0x1160, 0x11A7) or inRange(cp, 0xD7B0, 0xD7C6);
}

fn isHangulT(cp: u21) bool {
    return inRange(cp, 0x11A8, 0x11FF) or inRange(cp, 0xD7CB, 0xD7FB);
}

fn isHangulSyllable(cp: u21) bool {
    return inRange(cp, 0xAC00, 0xD7A3);
}

fn graphemeClass(cp: u21) GraphemeClass {
    if (cp == '\r') return .cr;
    if (cp == '\n') return .lf;
    if (cp == 0x200D) return .zwj;
    if (isControl(cp)) return .control;
    if (isRegionalIndicator(cp)) return .regional_indicator;

    if (isHangulL(cp)) return .l;
    if (isHangulV(cp)) return .v;
    if (isHangulT(cp)) return .t;
    if (isHangulSyllable(cp)) {
        const sindex = cp - 0xAC00;
        if (sindex % 28 == 0) return .lv;
        return .lvt;
    }

    if (inIntervals(cp, &prepend_intervals)) return .prepend;
    if (inIntervals(cp, &spacing_mark_intervals)) return .spacing_mark;
    if (isVariationSelector(cp) or cp == 0x200C or inIntervals(cp, &extend_intervals) or inRange(cp, 0x1F3FB, 0x1F3FF)) {
        return .extend;
    }

    return .other;
}

fn shouldBreak(prev: GraphemeClass, next: GraphemeClass, ri_run: usize, prev_was_zwj: bool, zwj_links_ep: bool, next_cp: u21) bool {
    if (prev == .cr and next == .lf) return false;

    if (prev == .cr or prev == .lf or prev == .control) return true;
    if (next == .cr or next == .lf or next == .control) return true;

    if (prev == .l and (next == .l or next == .v or next == .lv or next == .lvt)) return false;
    if ((prev == .lv or prev == .v) and (next == .v or next == .t)) return false;
    if ((prev == .lvt or prev == .t) and next == .t) return false;

    if (next == .extend or next == .zwj or next == .spacing_mark) return false;
    if (prev == .prepend) return false;

    if (next == .regional_indicator and prev == .regional_indicator) {
        return (ri_run % 2) == 0;
    }

    if (next_cp != 0 and isExtendedPictographic(next_cp) and prev_was_zwj and zwj_links_ep) {
        return false;
    }

    return true;
}

const zero_width_intervals = [_]Interval{
    .{ .start = 0x0300, .end = 0x036F },
    .{ .start = 0x0483, .end = 0x0489 },
    .{ .start = 0x0591, .end = 0x05BD },
    .{ .start = 0x05BF, .end = 0x05BF },
    .{ .start = 0x05C1, .end = 0x05C2 },
    .{ .start = 0x05C4, .end = 0x05C5 },
    .{ .start = 0x05C7, .end = 0x05C7 },
    .{ .start = 0x0610, .end = 0x061A },
    .{ .start = 0x064B, .end = 0x065F },
    .{ .start = 0x0670, .end = 0x0670 },
    .{ .start = 0x06D6, .end = 0x06DC },
    .{ .start = 0x06DF, .end = 0x06E4 },
    .{ .start = 0x06E7, .end = 0x06E8 },
    .{ .start = 0x06EA, .end = 0x06ED },
    .{ .start = 0x0711, .end = 0x0711 },
    .{ .start = 0x0730, .end = 0x074A },
    .{ .start = 0x07A6, .end = 0x07B0 },
    .{ .start = 0x07EB, .end = 0x07F3 },
    .{ .start = 0x07FD, .end = 0x07FD },
    .{ .start = 0x0816, .end = 0x0819 },
    .{ .start = 0x081B, .end = 0x0823 },
    .{ .start = 0x0825, .end = 0x0827 },
    .{ .start = 0x0829, .end = 0x082D },
    .{ .start = 0x0859, .end = 0x085B },
    .{ .start = 0x0890, .end = 0x0891 },
    .{ .start = 0x0898, .end = 0x089F },
    .{ .start = 0x08CA, .end = 0x0902 },
    .{ .start = 0x093A, .end = 0x093A },
    .{ .start = 0x093C, .end = 0x093C },
    .{ .start = 0x0941, .end = 0x0948 },
    .{ .start = 0x094D, .end = 0x094D },
    .{ .start = 0x0951, .end = 0x0957 },
    .{ .start = 0x0962, .end = 0x0963 },
    .{ .start = 0x0981, .end = 0x0981 },
    .{ .start = 0x09BC, .end = 0x09BC },
    .{ .start = 0x09C1, .end = 0x09C4 },
    .{ .start = 0x09CD, .end = 0x09CD },
    .{ .start = 0x09E2, .end = 0x09E3 },
    .{ .start = 0x09FE, .end = 0x09FE },
    .{ .start = 0x0A01, .end = 0x0A02 },
    .{ .start = 0x0A3C, .end = 0x0A3C },
    .{ .start = 0x0A41, .end = 0x0A42 },
    .{ .start = 0x0A47, .end = 0x0A48 },
    .{ .start = 0x0A4B, .end = 0x0A4D },
    .{ .start = 0x0A51, .end = 0x0A51 },
    .{ .start = 0x0A70, .end = 0x0A71 },
    .{ .start = 0x0A75, .end = 0x0A75 },
    .{ .start = 0x0A81, .end = 0x0A82 },
    .{ .start = 0x0ABC, .end = 0x0ABC },
    .{ .start = 0x0AC1, .end = 0x0AC5 },
    .{ .start = 0x0AC7, .end = 0x0AC8 },
    .{ .start = 0x0ACD, .end = 0x0ACD },
    .{ .start = 0x0AE2, .end = 0x0AE3 },
    .{ .start = 0x0AFA, .end = 0x0AFF },
    .{ .start = 0x0B01, .end = 0x0B01 },
    .{ .start = 0x0B3C, .end = 0x0B3C },
    .{ .start = 0x0B3F, .end = 0x0B3F },
    .{ .start = 0x0B41, .end = 0x0B44 },
    .{ .start = 0x0B4D, .end = 0x0B4D },
    .{ .start = 0x0B55, .end = 0x0B56 },
    .{ .start = 0x0B62, .end = 0x0B63 },
    .{ .start = 0x0B82, .end = 0x0B82 },
    .{ .start = 0x0BC0, .end = 0x0BC0 },
    .{ .start = 0x0BCD, .end = 0x0BCD },
    .{ .start = 0x0C00, .end = 0x0C00 },
    .{ .start = 0x0C04, .end = 0x0C04 },
    .{ .start = 0x0C3C, .end = 0x0C3C },
    .{ .start = 0x0C3E, .end = 0x0C40 },
    .{ .start = 0x0C46, .end = 0x0C48 },
    .{ .start = 0x0C4A, .end = 0x0C4D },
    .{ .start = 0x0C55, .end = 0x0C56 },
    .{ .start = 0x0C62, .end = 0x0C63 },
    .{ .start = 0x0C81, .end = 0x0C81 },
    .{ .start = 0x0CBC, .end = 0x0CBC },
    .{ .start = 0x0CBF, .end = 0x0CBF },
    .{ .start = 0x0CC6, .end = 0x0CC6 },
    .{ .start = 0x0CCC, .end = 0x0CCD },
    .{ .start = 0x0CE2, .end = 0x0CE3 },
    .{ .start = 0x0D00, .end = 0x0D01 },
    .{ .start = 0x0D3B, .end = 0x0D3C },
    .{ .start = 0x0D41, .end = 0x0D44 },
    .{ .start = 0x0D4D, .end = 0x0D4D },
    .{ .start = 0x0D62, .end = 0x0D63 },
    .{ .start = 0x0D81, .end = 0x0D81 },
    .{ .start = 0x0DCA, .end = 0x0DCA },
    .{ .start = 0x0DD2, .end = 0x0DD4 },
    .{ .start = 0x0DD6, .end = 0x0DD6 },
    .{ .start = 0x0E31, .end = 0x0E31 },
    .{ .start = 0x0E34, .end = 0x0E3A },
    .{ .start = 0x0E47, .end = 0x0E4E },
    .{ .start = 0x0EB1, .end = 0x0EB1 },
    .{ .start = 0x0EB4, .end = 0x0EBC },
    .{ .start = 0x0EC8, .end = 0x0ECD },
    .{ .start = 0x0F18, .end = 0x0F19 },
    .{ .start = 0x0F35, .end = 0x0F35 },
    .{ .start = 0x0F37, .end = 0x0F37 },
    .{ .start = 0x0F39, .end = 0x0F39 },
    .{ .start = 0x0F71, .end = 0x0F7E },
    .{ .start = 0x0F80, .end = 0x0F84 },
    .{ .start = 0x0F86, .end = 0x0F87 },
    .{ .start = 0x0F8D, .end = 0x0F97 },
    .{ .start = 0x0F99, .end = 0x0FBC },
    .{ .start = 0x0FC6, .end = 0x0FC6 },
    .{ .start = 0x102D, .end = 0x1030 },
    .{ .start = 0x1032, .end = 0x1037 },
    .{ .start = 0x1039, .end = 0x103A },
    .{ .start = 0x103D, .end = 0x103E },
    .{ .start = 0x1058, .end = 0x1059 },
    .{ .start = 0x105E, .end = 0x1060 },
    .{ .start = 0x1071, .end = 0x1074 },
    .{ .start = 0x1082, .end = 0x1082 },
    .{ .start = 0x1085, .end = 0x1086 },
    .{ .start = 0x108D, .end = 0x108D },
    .{ .start = 0x109D, .end = 0x109D },
    .{ .start = 0x135D, .end = 0x135F },
    .{ .start = 0x1712, .end = 0x1714 },
    .{ .start = 0x1732, .end = 0x1734 },
    .{ .start = 0x1752, .end = 0x1753 },
    .{ .start = 0x1772, .end = 0x1773 },
    .{ .start = 0x17B4, .end = 0x17B5 },
    .{ .start = 0x17B7, .end = 0x17BD },
    .{ .start = 0x17C6, .end = 0x17C6 },
    .{ .start = 0x17C9, .end = 0x17D3 },
    .{ .start = 0x17DD, .end = 0x17DD },
    .{ .start = 0x180B, .end = 0x180D },
    .{ .start = 0x1885, .end = 0x1886 },
    .{ .start = 0x18A9, .end = 0x18A9 },
    .{ .start = 0x1920, .end = 0x1922 },
    .{ .start = 0x1927, .end = 0x1928 },
    .{ .start = 0x1932, .end = 0x1932 },
    .{ .start = 0x1939, .end = 0x193B },
    .{ .start = 0x1A17, .end = 0x1A18 },
    .{ .start = 0x1A1B, .end = 0x1A1B },
    .{ .start = 0x1A56, .end = 0x1A56 },
    .{ .start = 0x1A58, .end = 0x1A5E },
    .{ .start = 0x1A60, .end = 0x1A60 },
    .{ .start = 0x1A62, .end = 0x1A62 },
    .{ .start = 0x1A65, .end = 0x1A6C },
    .{ .start = 0x1A73, .end = 0x1A7C },
    .{ .start = 0x1A7F, .end = 0x1A7F },
    .{ .start = 0x1AB0, .end = 0x1ACE },
    .{ .start = 0x1B00, .end = 0x1B03 },
    .{ .start = 0x1B34, .end = 0x1B34 },
    .{ .start = 0x1B36, .end = 0x1B3A },
    .{ .start = 0x1B3C, .end = 0x1B3C },
    .{ .start = 0x1B42, .end = 0x1B42 },
    .{ .start = 0x1B6B, .end = 0x1B73 },
    .{ .start = 0x1B80, .end = 0x1B81 },
    .{ .start = 0x1BA2, .end = 0x1BA5 },
    .{ .start = 0x1BA8, .end = 0x1BA9 },
    .{ .start = 0x1BAB, .end = 0x1BAD },
    .{ .start = 0x1BE6, .end = 0x1BE6 },
    .{ .start = 0x1BE8, .end = 0x1BE9 },
    .{ .start = 0x1BED, .end = 0x1BED },
    .{ .start = 0x1BEF, .end = 0x1BF1 },
    .{ .start = 0x1C2C, .end = 0x1C33 },
    .{ .start = 0x1C36, .end = 0x1C37 },
    .{ .start = 0x1CD0, .end = 0x1CD2 },
    .{ .start = 0x1CD4, .end = 0x1CE0 },
    .{ .start = 0x1CE2, .end = 0x1CE8 },
    .{ .start = 0x1CED, .end = 0x1CED },
    .{ .start = 0x1CF4, .end = 0x1CF4 },
    .{ .start = 0x1CF8, .end = 0x1CF9 },
    .{ .start = 0x1DC0, .end = 0x1DFF },
    .{ .start = 0x200B, .end = 0x200F },
    .{ .start = 0x202A, .end = 0x202E },
    .{ .start = 0x2060, .end = 0x2064 },
    .{ .start = 0x2066, .end = 0x206F },
    .{ .start = 0x20D0, .end = 0x20F0 },
    .{ .start = 0x2CEF, .end = 0x2CF1 },
    .{ .start = 0x2D7F, .end = 0x2D7F },
    .{ .start = 0x2DE0, .end = 0x2DFF },
    .{ .start = 0x302A, .end = 0x302F },
    .{ .start = 0x3099, .end = 0x309A },
    .{ .start = 0xA66F, .end = 0xA672 },
    .{ .start = 0xA674, .end = 0xA67D },
    .{ .start = 0xA69E, .end = 0xA69F },
    .{ .start = 0xA6F0, .end = 0xA6F1 },
    .{ .start = 0xA802, .end = 0xA802 },
    .{ .start = 0xA806, .end = 0xA806 },
    .{ .start = 0xA80B, .end = 0xA80B },
    .{ .start = 0xA825, .end = 0xA826 },
    .{ .start = 0xA8C4, .end = 0xA8C5 },
    .{ .start = 0xA8E0, .end = 0xA8F1 },
    .{ .start = 0xA926, .end = 0xA92D },
    .{ .start = 0xA947, .end = 0xA951 },
    .{ .start = 0xA980, .end = 0xA982 },
    .{ .start = 0xA9B3, .end = 0xA9B3 },
    .{ .start = 0xA9B6, .end = 0xA9B9 },
    .{ .start = 0xA9BC, .end = 0xA9BC },
    .{ .start = 0xA9E5, .end = 0xA9E5 },
    .{ .start = 0xAA29, .end = 0xAA2E },
    .{ .start = 0xAA31, .end = 0xAA32 },
    .{ .start = 0xAA35, .end = 0xAA36 },
    .{ .start = 0xAA43, .end = 0xAA43 },
    .{ .start = 0xAA4C, .end = 0xAA4C },
    .{ .start = 0xAA7C, .end = 0xAA7C },
    .{ .start = 0xAAB0, .end = 0xAAB0 },
    .{ .start = 0xAAB2, .end = 0xAAB4 },
    .{ .start = 0xAAB7, .end = 0xAAB8 },
    .{ .start = 0xAABE, .end = 0xAABF },
    .{ .start = 0xAAC1, .end = 0xAAC1 },
    .{ .start = 0xAAEC, .end = 0xAAED },
    .{ .start = 0xAAF6, .end = 0xAAF6 },
    .{ .start = 0xABE5, .end = 0xABE5 },
    .{ .start = 0xABE8, .end = 0xABE8 },
    .{ .start = 0xABED, .end = 0xABED },
    .{ .start = 0xFB1E, .end = 0xFB1E },
    .{ .start = 0xFE00, .end = 0xFE0F },
    .{ .start = 0xFE20, .end = 0xFE2F },
    .{ .start = 0xFEFF, .end = 0xFEFF },
    .{ .start = 0xFFF9, .end = 0xFFFB },
    .{ .start = 0x101FD, .end = 0x101FD },
    .{ .start = 0x102E0, .end = 0x102E0 },
    .{ .start = 0x10376, .end = 0x1037A },
    .{ .start = 0x10A01, .end = 0x10A03 },
    .{ .start = 0x10A05, .end = 0x10A06 },
    .{ .start = 0x10A0C, .end = 0x10A0F },
    .{ .start = 0x10A38, .end = 0x10A3A },
    .{ .start = 0x10A3F, .end = 0x10A3F },
    .{ .start = 0x10AE5, .end = 0x10AE6 },
    .{ .start = 0x10D24, .end = 0x10D27 },
    .{ .start = 0x10EAB, .end = 0x10EAC },
    .{ .start = 0x10F46, .end = 0x10F50 },
    .{ .start = 0x10F82, .end = 0x10F85 },
    .{ .start = 0x11001, .end = 0x11001 },
    .{ .start = 0x11038, .end = 0x11046 },
    .{ .start = 0x11070, .end = 0x11070 },
    .{ .start = 0x11073, .end = 0x11074 },
    .{ .start = 0x1107F, .end = 0x11081 },
    .{ .start = 0x110B3, .end = 0x110B6 },
    .{ .start = 0x110B9, .end = 0x110BA },
    .{ .start = 0x11100, .end = 0x11102 },
    .{ .start = 0x11127, .end = 0x1112B },
    .{ .start = 0x1112D, .end = 0x11134 },
    .{ .start = 0x11173, .end = 0x11173 },
    .{ .start = 0x11180, .end = 0x11181 },
    .{ .start = 0x111B6, .end = 0x111BE },
    .{ .start = 0x111C9, .end = 0x111CC },
    .{ .start = 0x1122F, .end = 0x11231 },
    .{ .start = 0x11234, .end = 0x11234 },
    .{ .start = 0x11236, .end = 0x11237 },
    .{ .start = 0x1123E, .end = 0x1123E },
    .{ .start = 0x112DF, .end = 0x112DF },
    .{ .start = 0x112E3, .end = 0x112EA },
    .{ .start = 0x11300, .end = 0x11301 },
    .{ .start = 0x1133B, .end = 0x1133C },
    .{ .start = 0x11340, .end = 0x11340 },
    .{ .start = 0x11366, .end = 0x1136C },
    .{ .start = 0x11370, .end = 0x11374 },
    .{ .start = 0x11438, .end = 0x1143F },
    .{ .start = 0x11442, .end = 0x11444 },
    .{ .start = 0x11446, .end = 0x11446 },
    .{ .start = 0x1145E, .end = 0x1145E },
    .{ .start = 0x114B3, .end = 0x114B8 },
    .{ .start = 0x114BA, .end = 0x114BA },
    .{ .start = 0x114BF, .end = 0x114C0 },
    .{ .start = 0x114C2, .end = 0x114C3 },
    .{ .start = 0x115B2, .end = 0x115B5 },
    .{ .start = 0x115BC, .end = 0x115BD },
    .{ .start = 0x115BF, .end = 0x115C0 },
    .{ .start = 0x115DC, .end = 0x115DD },
    .{ .start = 0x11633, .end = 0x1163A },
    .{ .start = 0x1163D, .end = 0x1163D },
    .{ .start = 0x1163F, .end = 0x11640 },
    .{ .start = 0x116AB, .end = 0x116AB },
    .{ .start = 0x116AD, .end = 0x116AD },
    .{ .start = 0x116B0, .end = 0x116B5 },
    .{ .start = 0x116B7, .end = 0x116B7 },
    .{ .start = 0x1171D, .end = 0x1171F },
    .{ .start = 0x11722, .end = 0x11725 },
    .{ .start = 0x11727, .end = 0x1172B },
    .{ .start = 0x1182F, .end = 0x11837 },
    .{ .start = 0x11839, .end = 0x1183A },
    .{ .start = 0x1193B, .end = 0x1193C },
    .{ .start = 0x1193E, .end = 0x1193E },
    .{ .start = 0x11943, .end = 0x11943 },
    .{ .start = 0x119D4, .end = 0x119D7 },
    .{ .start = 0x119DA, .end = 0x119DB },
    .{ .start = 0x119E0, .end = 0x119E0 },
    .{ .start = 0x11A01, .end = 0x11A0A },
    .{ .start = 0x11A33, .end = 0x11A38 },
    .{ .start = 0x11A3B, .end = 0x11A3E },
    .{ .start = 0x11A47, .end = 0x11A47 },
    .{ .start = 0x11A51, .end = 0x11A56 },
    .{ .start = 0x11A59, .end = 0x11A5B },
    .{ .start = 0x11A8A, .end = 0x11A96 },
    .{ .start = 0x11A98, .end = 0x11A99 },
    .{ .start = 0x11C30, .end = 0x11C36 },
    .{ .start = 0x11C38, .end = 0x11C3D },
    .{ .start = 0x11C3F, .end = 0x11C3F },
    .{ .start = 0x11C92, .end = 0x11CA7 },
    .{ .start = 0x11CAA, .end = 0x11CB0 },
    .{ .start = 0x11CB2, .end = 0x11CB3 },
    .{ .start = 0x11CB5, .end = 0x11CB6 },
    .{ .start = 0x11D31, .end = 0x11D36 },
    .{ .start = 0x11D3A, .end = 0x11D3A },
    .{ .start = 0x11D3C, .end = 0x11D3D },
    .{ .start = 0x11D3F, .end = 0x11D45 },
    .{ .start = 0x11D47, .end = 0x11D47 },
    .{ .start = 0x11D90, .end = 0x11D91 },
    .{ .start = 0x11D95, .end = 0x11D95 },
    .{ .start = 0x11D97, .end = 0x11D97 },
    .{ .start = 0x11EF3, .end = 0x11EF4 },
    .{ .start = 0x13430, .end = 0x13438 },
    .{ .start = 0x16AF0, .end = 0x16AF4 },
    .{ .start = 0x16B30, .end = 0x16B36 },
    .{ .start = 0x16F4F, .end = 0x16F4F },
    .{ .start = 0x16F8F, .end = 0x16F92 },
    .{ .start = 0x16FE4, .end = 0x16FE4 },
    .{ .start = 0x1BC9D, .end = 0x1BC9E },
    .{ .start = 0x1CF00, .end = 0x1CF2D },
    .{ .start = 0x1CF30, .end = 0x1CF46 },
    .{ .start = 0x1D167, .end = 0x1D169 },
    .{ .start = 0x1D17B, .end = 0x1D182 },
    .{ .start = 0x1D185, .end = 0x1D18B },
    .{ .start = 0x1D1AA, .end = 0x1D1AD },
    .{ .start = 0x1D242, .end = 0x1D244 },
    .{ .start = 0x1DA00, .end = 0x1DA36 },
    .{ .start = 0x1DA3B, .end = 0x1DA6C },
    .{ .start = 0x1DA75, .end = 0x1DA75 },
    .{ .start = 0x1DA84, .end = 0x1DA84 },
    .{ .start = 0x1DA9B, .end = 0x1DA9F },
    .{ .start = 0x1DAA1, .end = 0x1DAAF },
    .{ .start = 0x1E000, .end = 0x1E006 },
    .{ .start = 0x1E008, .end = 0x1E018 },
    .{ .start = 0x1E01B, .end = 0x1E021 },
    .{ .start = 0x1E023, .end = 0x1E024 },
    .{ .start = 0x1E026, .end = 0x1E02A },
    .{ .start = 0x1E08F, .end = 0x1E08F },
    .{ .start = 0x1E130, .end = 0x1E136 },
    .{ .start = 0x1E2AE, .end = 0x1E2AE },
    .{ .start = 0x1E2EC, .end = 0x1E2EF },
    .{ .start = 0x1E4EC, .end = 0x1E4EF },
    .{ .start = 0x1E8D0, .end = 0x1E8D6 },
    .{ .start = 0x1E944, .end = 0x1E94A },
    .{ .start = 0xE0001, .end = 0xE0001 },
    .{ .start = 0xE0020, .end = 0xE007F },
    .{ .start = 0xE0100, .end = 0xE01EF },
};

const extend_intervals = zero_width_intervals;

const prepend_intervals = [_]Interval{
    .{ .start = 0x0600, .end = 0x0605 },
    .{ .start = 0x06DD, .end = 0x06DD },
    .{ .start = 0x070F, .end = 0x070F },
    .{ .start = 0x0890, .end = 0x0891 },
    .{ .start = 0x08E2, .end = 0x08E2 },
    .{ .start = 0x110BD, .end = 0x110BD },
    .{ .start = 0x110CD, .end = 0x110CD },
};

const spacing_mark_intervals = [_]Interval{
    .{ .start = 0x0903, .end = 0x0903 },
    .{ .start = 0x093B, .end = 0x093B },
    .{ .start = 0x093E, .end = 0x0940 },
    .{ .start = 0x0949, .end = 0x094C },
    .{ .start = 0x094E, .end = 0x094F },
    .{ .start = 0x0982, .end = 0x0983 },
    .{ .start = 0x09BE, .end = 0x09C0 },
    .{ .start = 0x09C7, .end = 0x09C8 },
    .{ .start = 0x09CB, .end = 0x09CC },
    .{ .start = 0x0A03, .end = 0x0A03 },
    .{ .start = 0x0A3E, .end = 0x0A40 },
    .{ .start = 0x0A83, .end = 0x0A83 },
    .{ .start = 0x0ABE, .end = 0x0AC0 },
    .{ .start = 0x0AC9, .end = 0x0AC9 },
    .{ .start = 0x0ACB, .end = 0x0ACC },
    .{ .start = 0x0B02, .end = 0x0B03 },
    .{ .start = 0x0B3E, .end = 0x0B3E },
    .{ .start = 0x0B40, .end = 0x0B40 },
    .{ .start = 0x0B47, .end = 0x0B48 },
    .{ .start = 0x0B4B, .end = 0x0B4C },
    .{ .start = 0x0BBE, .end = 0x0BBF },
    .{ .start = 0x0BC1, .end = 0x0BC2 },
    .{ .start = 0x0BC6, .end = 0x0BC8 },
    .{ .start = 0x0BCA, .end = 0x0BCC },
    .{ .start = 0x0C01, .end = 0x0C03 },
    .{ .start = 0x0C41, .end = 0x0C44 },
    .{ .start = 0x0C82, .end = 0x0C83 },
    .{ .start = 0x0CBE, .end = 0x0CC4 },
    .{ .start = 0x0CC7, .end = 0x0CC8 },
    .{ .start = 0x0CCA, .end = 0x0CCB },
    .{ .start = 0x0D02, .end = 0x0D03 },
    .{ .start = 0x0D3E, .end = 0x0D40 },
    .{ .start = 0x0D46, .end = 0x0D48 },
    .{ .start = 0x0D4A, .end = 0x0D4C },
    .{ .start = 0x0D82, .end = 0x0D83 },
    .{ .start = 0x0DD0, .end = 0x0DD1 },
    .{ .start = 0x0DD8, .end = 0x0DDE },
    .{ .start = 0x0DF2, .end = 0x0DF3 },
    .{ .start = 0x0F3E, .end = 0x0F3F },
    .{ .start = 0x0F7F, .end = 0x0F7F },
    .{ .start = 0x102B, .end = 0x102C },
    .{ .start = 0x1031, .end = 0x1031 },
    .{ .start = 0x1038, .end = 0x1038 },
    .{ .start = 0x103B, .end = 0x103C },
    .{ .start = 0x1056, .end = 0x1057 },
    .{ .start = 0x1062, .end = 0x1064 },
    .{ .start = 0x1067, .end = 0x106D },
    .{ .start = 0x1083, .end = 0x1084 },
    .{ .start = 0x1087, .end = 0x108C },
    .{ .start = 0x108F, .end = 0x108F },
    .{ .start = 0x109A, .end = 0x109C },
    .{ .start = 0x17B6, .end = 0x17B6 },
    .{ .start = 0x17BE, .end = 0x17C5 },
    .{ .start = 0x17C7, .end = 0x17C8 },
    .{ .start = 0x1923, .end = 0x1926 },
    .{ .start = 0x1929, .end = 0x192B },
    .{ .start = 0x1930, .end = 0x1931 },
    .{ .start = 0x1933, .end = 0x1938 },
    .{ .start = 0x1A19, .end = 0x1A1A },
    .{ .start = 0x1A55, .end = 0x1A55 },
    .{ .start = 0x1A57, .end = 0x1A57 },
    .{ .start = 0x1A61, .end = 0x1A61 },
    .{ .start = 0x1A63, .end = 0x1A64 },
    .{ .start = 0x1A6D, .end = 0x1A72 },
    .{ .start = 0x1B04, .end = 0x1B04 },
    .{ .start = 0x1B35, .end = 0x1B35 },
    .{ .start = 0x1B3B, .end = 0x1B3B },
    .{ .start = 0x1B3D, .end = 0x1B41 },
    .{ .start = 0x1B43, .end = 0x1B44 },
    .{ .start = 0x1B82, .end = 0x1B82 },
    .{ .start = 0x1BA1, .end = 0x1BA1 },
    .{ .start = 0x1BA6, .end = 0x1BA7 },
    .{ .start = 0x1BAA, .end = 0x1BAA },
    .{ .start = 0x1BE7, .end = 0x1BE7 },
    .{ .start = 0x1BEA, .end = 0x1BEC },
    .{ .start = 0x1BEE, .end = 0x1BEE },
    .{ .start = 0x1BF2, .end = 0x1BF3 },
    .{ .start = 0x1C24, .end = 0x1C2B },
    .{ .start = 0x1C34, .end = 0x1C35 },
    .{ .start = 0x1CE1, .end = 0x1CE1 },
    .{ .start = 0x1CF7, .end = 0x1CF7 },
    .{ .start = 0x302E, .end = 0x302F },
    .{ .start = 0xA823, .end = 0xA824 },
    .{ .start = 0xA827, .end = 0xA827 },
    .{ .start = 0xA880, .end = 0xA881 },
    .{ .start = 0xA8B4, .end = 0xA8C3 },
    .{ .start = 0xA952, .end = 0xA953 },
    .{ .start = 0xA983, .end = 0xA983 },
    .{ .start = 0xA9B4, .end = 0xA9B5 },
    .{ .start = 0xA9BA, .end = 0xA9BB },
    .{ .start = 0xA9BD, .end = 0xA9C0 },
    .{ .start = 0xAA2F, .end = 0xAA30 },
    .{ .start = 0xAA33, .end = 0xAA34 },
    .{ .start = 0xAA4D, .end = 0xAA4D },
    .{ .start = 0xAA7B, .end = 0xAA7B },
    .{ .start = 0xAA7D, .end = 0xAA7D },
    .{ .start = 0xAAEB, .end = 0xAAEB },
    .{ .start = 0xAAEE, .end = 0xAAEF },
    .{ .start = 0xAAF5, .end = 0xAAF5 },
    .{ .start = 0xABE3, .end = 0xABE4 },
    .{ .start = 0xABE6, .end = 0xABE7 },
    .{ .start = 0xABE9, .end = 0xABEA },
    .{ .start = 0xABEC, .end = 0xABEC },
    .{ .start = 0x11000, .end = 0x11000 },
    .{ .start = 0x11002, .end = 0x11002 },
    .{ .start = 0x11082, .end = 0x11082 },
    .{ .start = 0x110B0, .end = 0x110B2 },
    .{ .start = 0x110B7, .end = 0x110B8 },
    .{ .start = 0x1112C, .end = 0x1112C },
    .{ .start = 0x11145, .end = 0x11146 },
    .{ .start = 0x11182, .end = 0x11182 },
    .{ .start = 0x111B3, .end = 0x111B5 },
    .{ .start = 0x111BF, .end = 0x111C0 },
    .{ .start = 0x1122C, .end = 0x1122E },
    .{ .start = 0x11232, .end = 0x11233 },
    .{ .start = 0x11235, .end = 0x11235 },
    .{ .start = 0x112E0, .end = 0x112E2 },
    .{ .start = 0x11302, .end = 0x11303 },
    .{ .start = 0x1133E, .end = 0x1133F },
    .{ .start = 0x11341, .end = 0x11344 },
    .{ .start = 0x11347, .end = 0x11348 },
    .{ .start = 0x1134B, .end = 0x1134D },
    .{ .start = 0x11357, .end = 0x11357 },
    .{ .start = 0x11362, .end = 0x11363 },
    .{ .start = 0x11435, .end = 0x11437 },
    .{ .start = 0x11440, .end = 0x11441 },
    .{ .start = 0x11445, .end = 0x11445 },
    .{ .start = 0x114B0, .end = 0x114B2 },
    .{ .start = 0x114B9, .end = 0x114B9 },
    .{ .start = 0x114BB, .end = 0x114BE },
    .{ .start = 0x114C1, .end = 0x114C1 },
    .{ .start = 0x115AF, .end = 0x115B1 },
    .{ .start = 0x115B8, .end = 0x115BB },
    .{ .start = 0x115BE, .end = 0x115BE },
    .{ .start = 0x11630, .end = 0x11632 },
    .{ .start = 0x1163B, .end = 0x1163C },
    .{ .start = 0x1163E, .end = 0x1163E },
    .{ .start = 0x116AC, .end = 0x116AC },
    .{ .start = 0x116AE, .end = 0x116AF },
    .{ .start = 0x116B6, .end = 0x116B6 },
    .{ .start = 0x11720, .end = 0x11721 },
    .{ .start = 0x11726, .end = 0x11726 },
    .{ .start = 0x1182C, .end = 0x1182E },
    .{ .start = 0x11838, .end = 0x11838 },
    .{ .start = 0x11930, .end = 0x11935 },
    .{ .start = 0x11937, .end = 0x11938 },
    .{ .start = 0x1193D, .end = 0x1193D },
    .{ .start = 0x11940, .end = 0x11940 },
    .{ .start = 0x11942, .end = 0x11942 },
    .{ .start = 0x119D1, .end = 0x119D3 },
    .{ .start = 0x119DC, .end = 0x119DF },
    .{ .start = 0x119E4, .end = 0x119E4 },
    .{ .start = 0x11A39, .end = 0x11A39 },
    .{ .start = 0x11A57, .end = 0x11A58 },
    .{ .start = 0x11A97, .end = 0x11A97 },
    .{ .start = 0x11C2F, .end = 0x11C2F },
    .{ .start = 0x11C3E, .end = 0x11C3E },
    .{ .start = 0x11CA9, .end = 0x11CA9 },
    .{ .start = 0x11CB1, .end = 0x11CB1 },
    .{ .start = 0x11CB4, .end = 0x11CB4 },
    .{ .start = 0x11D8A, .end = 0x11D8E },
    .{ .start = 0x11D93, .end = 0x11D94 },
    .{ .start = 0x11D96, .end = 0x11D96 },
    .{ .start = 0x11EF5, .end = 0x11EF6 },
};

const wide_intervals = [_]Interval{
    .{ .start = 0x1100, .end = 0x115F },
    .{ .start = 0x231A, .end = 0x231B },
    .{ .start = 0x2329, .end = 0x232A },
    .{ .start = 0x23E9, .end = 0x23EC },
    .{ .start = 0x23F0, .end = 0x23F0 },
    .{ .start = 0x23F3, .end = 0x23F3 },
    .{ .start = 0x25FD, .end = 0x25FE },
    .{ .start = 0x2614, .end = 0x2615 },
    .{ .start = 0x2648, .end = 0x2653 },
    .{ .start = 0x267F, .end = 0x267F },
    .{ .start = 0x2693, .end = 0x2693 },
    .{ .start = 0x26A1, .end = 0x26A1 },
    .{ .start = 0x26AA, .end = 0x26AB },
    .{ .start = 0x26BD, .end = 0x26BE },
    .{ .start = 0x26C4, .end = 0x26C5 },
    .{ .start = 0x26CE, .end = 0x26CE },
    .{ .start = 0x26D4, .end = 0x26D4 },
    .{ .start = 0x26EA, .end = 0x26EA },
    .{ .start = 0x26F2, .end = 0x26F3 },
    .{ .start = 0x26F5, .end = 0x26F5 },
    .{ .start = 0x26FA, .end = 0x26FA },
    .{ .start = 0x26FD, .end = 0x26FD },
    .{ .start = 0x2705, .end = 0x2705 },
    .{ .start = 0x270A, .end = 0x270B },
    .{ .start = 0x2728, .end = 0x2728 },
    .{ .start = 0x274C, .end = 0x274C },
    .{ .start = 0x274E, .end = 0x274E },
    .{ .start = 0x2753, .end = 0x2755 },
    .{ .start = 0x2757, .end = 0x2757 },
    .{ .start = 0x2795, .end = 0x2797 },
    .{ .start = 0x27B0, .end = 0x27B0 },
    .{ .start = 0x27BF, .end = 0x27BF },
    .{ .start = 0x2B1B, .end = 0x2B1C },
    .{ .start = 0x2B50, .end = 0x2B50 },
    .{ .start = 0x2B55, .end = 0x2B55 },
    .{ .start = 0x2E80, .end = 0x2E99 },
    .{ .start = 0x2E9B, .end = 0x2EF3 },
    .{ .start = 0x2F00, .end = 0x2FD5 },
    .{ .start = 0x2FF0, .end = 0x2FFB },
    .{ .start = 0x3000, .end = 0x303E },
    .{ .start = 0x3041, .end = 0x3096 },
    .{ .start = 0x3099, .end = 0x30FF },
    .{ .start = 0x3105, .end = 0x312F },
    .{ .start = 0x3131, .end = 0x318E },
    .{ .start = 0x3190, .end = 0x31E3 },
    .{ .start = 0x31F0, .end = 0x321E },
    .{ .start = 0x3220, .end = 0x3247 },
    .{ .start = 0x3250, .end = 0x32FE },
    .{ .start = 0x3300, .end = 0x4DBF },
    .{ .start = 0x4E00, .end = 0xA48C },
    .{ .start = 0xA490, .end = 0xA4C6 },
    .{ .start = 0xA960, .end = 0xA97C },
    .{ .start = 0xAC00, .end = 0xD7A3 },
    .{ .start = 0xF900, .end = 0xFAFF },
    .{ .start = 0xFE10, .end = 0xFE19 },
    .{ .start = 0xFE30, .end = 0xFE52 },
    .{ .start = 0xFE54, .end = 0xFE66 },
    .{ .start = 0xFE68, .end = 0xFE6B },
    .{ .start = 0xFF01, .end = 0xFF60 },
    .{ .start = 0xFFE0, .end = 0xFFE6 },
    .{ .start = 0x16FE0, .end = 0x16FE4 },
    .{ .start = 0x16FF0, .end = 0x16FF1 },
    .{ .start = 0x17000, .end = 0x187F7 },
    .{ .start = 0x18800, .end = 0x18CD5 },
    .{ .start = 0x18D00, .end = 0x18D08 },
    .{ .start = 0x1AFF0, .end = 0x1AFF3 },
    .{ .start = 0x1AFF5, .end = 0x1AFFB },
    .{ .start = 0x1AFFD, .end = 0x1AFFE },
    .{ .start = 0x1B000, .end = 0x1B122 },
    .{ .start = 0x1B132, .end = 0x1B132 },
    .{ .start = 0x1B150, .end = 0x1B152 },
    .{ .start = 0x1B155, .end = 0x1B155 },
    .{ .start = 0x1B164, .end = 0x1B167 },
    .{ .start = 0x1B170, .end = 0x1B2FB },
    .{ .start = 0x1D300, .end = 0x1D356 },
    .{ .start = 0x1D360, .end = 0x1D376 },
    .{ .start = 0x1F200, .end = 0x1F202 },
    .{ .start = 0x1F210, .end = 0x1F23B },
    .{ .start = 0x1F240, .end = 0x1F248 },
    .{ .start = 0x1F250, .end = 0x1F251 },
    .{ .start = 0x1F260, .end = 0x1F265 },
    .{ .start = 0x1F300, .end = 0x1F7FF },
    .{ .start = 0x1F900, .end = 0x1FAFF },
    .{ .start = 0x20000, .end = 0x2FFFD },
    .{ .start = 0x30000, .end = 0x3FFFD },
};

const ambiguous_intervals = [_]Interval{
    .{ .start = 0x00A1, .end = 0x00A1 },
    .{ .start = 0x00A4, .end = 0x00A4 },
    .{ .start = 0x00A7, .end = 0x00A8 },
    .{ .start = 0x00AA, .end = 0x00AA },
    .{ .start = 0x00AD, .end = 0x00AE },
    .{ .start = 0x00B0, .end = 0x00B4 },
    .{ .start = 0x00B6, .end = 0x00BA },
    .{ .start = 0x00BC, .end = 0x00BF },
    .{ .start = 0x00C6, .end = 0x00C6 },
    .{ .start = 0x00D0, .end = 0x00D0 },
    .{ .start = 0x00D7, .end = 0x00D8 },
    .{ .start = 0x00DE, .end = 0x00E1 },
    .{ .start = 0x00E6, .end = 0x00E6 },
    .{ .start = 0x00E8, .end = 0x00EA },
    .{ .start = 0x00EC, .end = 0x00ED },
    .{ .start = 0x00F0, .end = 0x00F0 },
    .{ .start = 0x00F2, .end = 0x00F3 },
    .{ .start = 0x00F7, .end = 0x00FA },
    .{ .start = 0x00FC, .end = 0x00FC },
    .{ .start = 0x00FE, .end = 0x00FE },
    .{ .start = 0x0101, .end = 0x0101 },
    .{ .start = 0x0111, .end = 0x0111 },
    .{ .start = 0x0113, .end = 0x0113 },
    .{ .start = 0x011B, .end = 0x011B },
    .{ .start = 0x0126, .end = 0x0127 },
    .{ .start = 0x012B, .end = 0x012B },
    .{ .start = 0x0131, .end = 0x0133 },
    .{ .start = 0x0138, .end = 0x0138 },
    .{ .start = 0x013F, .end = 0x0142 },
    .{ .start = 0x0144, .end = 0x0144 },
    .{ .start = 0x0148, .end = 0x014B },
    .{ .start = 0x014D, .end = 0x014D },
    .{ .start = 0x0152, .end = 0x0153 },
    .{ .start = 0x0166, .end = 0x0167 },
    .{ .start = 0x016B, .end = 0x016B },
    .{ .start = 0x01CE, .end = 0x01CE },
    .{ .start = 0x01D0, .end = 0x01D0 },
    .{ .start = 0x01D2, .end = 0x01D2 },
    .{ .start = 0x01D4, .end = 0x01D4 },
    .{ .start = 0x01D6, .end = 0x01D6 },
    .{ .start = 0x01D8, .end = 0x01D8 },
    .{ .start = 0x01DA, .end = 0x01DA },
    .{ .start = 0x01DC, .end = 0x01DC },
    .{ .start = 0x0251, .end = 0x0251 },
    .{ .start = 0x0261, .end = 0x0261 },
    .{ .start = 0x02C4, .end = 0x02C4 },
    .{ .start = 0x02C7, .end = 0x02C7 },
    .{ .start = 0x02C9, .end = 0x02CB },
    .{ .start = 0x02CD, .end = 0x02CD },
    .{ .start = 0x02D0, .end = 0x02D0 },
    .{ .start = 0x02D8, .end = 0x02DB },
    .{ .start = 0x02DD, .end = 0x02DD },
    .{ .start = 0x02DF, .end = 0x02DF },
    .{ .start = 0x0300, .end = 0x036F },
    .{ .start = 0x0391, .end = 0x03A1 },
    .{ .start = 0x03A3, .end = 0x03A9 },
    .{ .start = 0x03B1, .end = 0x03C1 },
    .{ .start = 0x03C3, .end = 0x03C9 },
    .{ .start = 0x0401, .end = 0x0401 },
    .{ .start = 0x0410, .end = 0x044F },
    .{ .start = 0x0451, .end = 0x0451 },
    .{ .start = 0x2010, .end = 0x2010 },
    .{ .start = 0x2013, .end = 0x2016 },
    .{ .start = 0x2018, .end = 0x2019 },
    .{ .start = 0x201C, .end = 0x201D },
    .{ .start = 0x2020, .end = 0x2022 },
    .{ .start = 0x2024, .end = 0x2027 },
    .{ .start = 0x2030, .end = 0x2030 },
    .{ .start = 0x2032, .end = 0x2033 },
    .{ .start = 0x2035, .end = 0x2035 },
    .{ .start = 0x203B, .end = 0x203B },
    .{ .start = 0x203E, .end = 0x203E },
    .{ .start = 0x2074, .end = 0x2074 },
    .{ .start = 0x207F, .end = 0x207F },
    .{ .start = 0x2081, .end = 0x2084 },
    .{ .start = 0x20AC, .end = 0x20AC },
    .{ .start = 0x2103, .end = 0x2103 },
    .{ .start = 0x2105, .end = 0x2105 },
    .{ .start = 0x2109, .end = 0x2109 },
    .{ .start = 0x2113, .end = 0x2113 },
    .{ .start = 0x2116, .end = 0x2116 },
    .{ .start = 0x2121, .end = 0x2122 },
    .{ .start = 0x2126, .end = 0x2126 },
    .{ .start = 0x212B, .end = 0x212B },
    .{ .start = 0x2153, .end = 0x2154 },
    .{ .start = 0x215B, .end = 0x215E },
    .{ .start = 0x2160, .end = 0x216B },
    .{ .start = 0x2170, .end = 0x2179 },
    .{ .start = 0x2189, .end = 0x2189 },
    .{ .start = 0x2190, .end = 0x2199 },
    .{ .start = 0x21B8, .end = 0x21B9 },
    .{ .start = 0x21D2, .end = 0x21D2 },
    .{ .start = 0x21D4, .end = 0x21D4 },
    .{ .start = 0x21E7, .end = 0x21E7 },
    .{ .start = 0x2200, .end = 0x2200 },
    .{ .start = 0x2202, .end = 0x2203 },
    .{ .start = 0x2207, .end = 0x2208 },
    .{ .start = 0x220B, .end = 0x220B },
    .{ .start = 0x220F, .end = 0x220F },
    .{ .start = 0x2211, .end = 0x2211 },
    .{ .start = 0x2215, .end = 0x2215 },
    .{ .start = 0x221A, .end = 0x221A },
    .{ .start = 0x221D, .end = 0x2220 },
    .{ .start = 0x2223, .end = 0x2223 },
    .{ .start = 0x2225, .end = 0x2225 },
    .{ .start = 0x2227, .end = 0x222C },
    .{ .start = 0x222E, .end = 0x222E },
    .{ .start = 0x2234, .end = 0x2237 },
    .{ .start = 0x223C, .end = 0x223D },
    .{ .start = 0x2248, .end = 0x2248 },
    .{ .start = 0x224C, .end = 0x224C },
    .{ .start = 0x2252, .end = 0x2252 },
    .{ .start = 0x2260, .end = 0x2261 },
    .{ .start = 0x2264, .end = 0x2267 },
    .{ .start = 0x226A, .end = 0x226B },
    .{ .start = 0x226E, .end = 0x226F },
    .{ .start = 0x2282, .end = 0x2283 },
    .{ .start = 0x2286, .end = 0x2287 },
    .{ .start = 0x2295, .end = 0x2295 },
    .{ .start = 0x2299, .end = 0x2299 },
    .{ .start = 0x22A5, .end = 0x22A5 },
    .{ .start = 0x22BF, .end = 0x22BF },
    .{ .start = 0x2312, .end = 0x2312 },
    .{ .start = 0x2460, .end = 0x24E9 },
    .{ .start = 0x24EB, .end = 0x254B },
    .{ .start = 0x2550, .end = 0x2573 },
    .{ .start = 0x2580, .end = 0x258F },
    .{ .start = 0x2592, .end = 0x2595 },
    .{ .start = 0x25A0, .end = 0x25A1 },
    .{ .start = 0x25A3, .end = 0x25A9 },
    .{ .start = 0x25B2, .end = 0x25B3 },
    .{ .start = 0x25B6, .end = 0x25B7 },
    .{ .start = 0x25BC, .end = 0x25BD },
    .{ .start = 0x25C0, .end = 0x25C1 },
    .{ .start = 0x25C6, .end = 0x25C8 },
    .{ .start = 0x25CB, .end = 0x25CB },
    .{ .start = 0x25CE, .end = 0x25D1 },
    .{ .start = 0x25E2, .end = 0x25E5 },
    .{ .start = 0x25EF, .end = 0x25EF },
    .{ .start = 0x2605, .end = 0x2606 },
    .{ .start = 0x2609, .end = 0x2609 },
    .{ .start = 0x260E, .end = 0x260F },
    .{ .start = 0x2614, .end = 0x2615 },
    .{ .start = 0x261C, .end = 0x261C },
    .{ .start = 0x261E, .end = 0x261E },
    .{ .start = 0x2640, .end = 0x2640 },
    .{ .start = 0x2642, .end = 0x2642 },
    .{ .start = 0x2660, .end = 0x2661 },
    .{ .start = 0x2663, .end = 0x2665 },
    .{ .start = 0x2667, .end = 0x266A },
    .{ .start = 0x266C, .end = 0x266D },
    .{ .start = 0x266F, .end = 0x266F },
    .{ .start = 0x269E, .end = 0x269F },
    .{ .start = 0x26BF, .end = 0x26BF },
    .{ .start = 0x26C6, .end = 0x26CD },
    .{ .start = 0x26CF, .end = 0x26D3 },
    .{ .start = 0x26D5, .end = 0x26E1 },
    .{ .start = 0x26E3, .end = 0x26E3 },
    .{ .start = 0x26E8, .end = 0x26E9 },
    .{ .start = 0x26EB, .end = 0x26F1 },
    .{ .start = 0x26F4, .end = 0x26F4 },
    .{ .start = 0x26F6, .end = 0x26F9 },
    .{ .start = 0x26FB, .end = 0x26FC },
    .{ .start = 0x26FE, .end = 0x26FF },
    .{ .start = 0x273D, .end = 0x273D },
    .{ .start = 0x2776, .end = 0x277F },
    .{ .start = 0x2B56, .end = 0x2B59 },
    .{ .start = 0x3248, .end = 0x324F },
    .{ .start = 0xE000, .end = 0xF8FF },
    .{ .start = 0xFE00, .end = 0xFE0F },
    .{ .start = 0xFFFD, .end = 0xFFFD },
    .{ .start = 0x1F100, .end = 0x1F10A },
    .{ .start = 0x1F110, .end = 0x1F12D },
    .{ .start = 0x1F130, .end = 0x1F169 },
    .{ .start = 0x1F170, .end = 0x1F18D },
    .{ .start = 0x1F18F, .end = 0x1F190 },
    .{ .start = 0x1F19B, .end = 0x1F1AC },
    .{ .start = 0xE0100, .end = 0xE01EF },
};

const extended_pictographic_intervals = [_]Interval{
    .{ .start = 0x00A9, .end = 0x00A9 },
    .{ .start = 0x00AE, .end = 0x00AE },
    .{ .start = 0x203C, .end = 0x203C },
    .{ .start = 0x2049, .end = 0x2049 },
    .{ .start = 0x2122, .end = 0x2122 },
    .{ .start = 0x2139, .end = 0x2139 },
    .{ .start = 0x2194, .end = 0x2199 },
    .{ .start = 0x21A9, .end = 0x21AA },
    .{ .start = 0x231A, .end = 0x231B },
    .{ .start = 0x2328, .end = 0x2328 },
    .{ .start = 0x23CF, .end = 0x23CF },
    .{ .start = 0x23E9, .end = 0x23F3 },
    .{ .start = 0x23F8, .end = 0x23FA },
    .{ .start = 0x24C2, .end = 0x24C2 },
    .{ .start = 0x25AA, .end = 0x25AB },
    .{ .start = 0x25B6, .end = 0x25B6 },
    .{ .start = 0x25C0, .end = 0x25C0 },
    .{ .start = 0x25FB, .end = 0x25FE },
    .{ .start = 0x2600, .end = 0x2604 },
    .{ .start = 0x260E, .end = 0x260E },
    .{ .start = 0x2611, .end = 0x2611 },
    .{ .start = 0x2614, .end = 0x2615 },
    .{ .start = 0x2618, .end = 0x2618 },
    .{ .start = 0x261D, .end = 0x261D },
    .{ .start = 0x2620, .end = 0x2620 },
    .{ .start = 0x2622, .end = 0x2623 },
    .{ .start = 0x2626, .end = 0x2626 },
    .{ .start = 0x262A, .end = 0x262A },
    .{ .start = 0x262E, .end = 0x262F },
    .{ .start = 0x2638, .end = 0x263A },
    .{ .start = 0x2640, .end = 0x2640 },
    .{ .start = 0x2642, .end = 0x2642 },
    .{ .start = 0x2648, .end = 0x2653 },
    .{ .start = 0x265F, .end = 0x2660 },
    .{ .start = 0x2663, .end = 0x2663 },
    .{ .start = 0x2665, .end = 0x2666 },
    .{ .start = 0x2668, .end = 0x2668 },
    .{ .start = 0x267B, .end = 0x267B },
    .{ .start = 0x267E, .end = 0x267F },
    .{ .start = 0x2692, .end = 0x2697 },
    .{ .start = 0x2699, .end = 0x2699 },
    .{ .start = 0x269B, .end = 0x269C },
    .{ .start = 0x26A0, .end = 0x26A1 },
    .{ .start = 0x26A7, .end = 0x26A7 },
    .{ .start = 0x26AA, .end = 0x26AB },
    .{ .start = 0x26B0, .end = 0x26B1 },
    .{ .start = 0x26BD, .end = 0x26BE },
    .{ .start = 0x26C4, .end = 0x26C5 },
    .{ .start = 0x26C8, .end = 0x26C8 },
    .{ .start = 0x26CE, .end = 0x26CF },
    .{ .start = 0x26D1, .end = 0x26D1 },
    .{ .start = 0x26D3, .end = 0x26D4 },
    .{ .start = 0x26E9, .end = 0x26EA },
    .{ .start = 0x26F0, .end = 0x26F5 },
    .{ .start = 0x26F7, .end = 0x26FA },
    .{ .start = 0x26FD, .end = 0x26FD },
    .{ .start = 0x2702, .end = 0x2702 },
    .{ .start = 0x2705, .end = 0x2705 },
    .{ .start = 0x2708, .end = 0x270D },
    .{ .start = 0x270F, .end = 0x270F },
    .{ .start = 0x2712, .end = 0x2712 },
    .{ .start = 0x2714, .end = 0x2714 },
    .{ .start = 0x2716, .end = 0x2716 },
    .{ .start = 0x271D, .end = 0x271D },
    .{ .start = 0x2721, .end = 0x2721 },
    .{ .start = 0x2728, .end = 0x2728 },
    .{ .start = 0x2733, .end = 0x2734 },
    .{ .start = 0x2744, .end = 0x2744 },
    .{ .start = 0x2747, .end = 0x2747 },
    .{ .start = 0x274C, .end = 0x274C },
    .{ .start = 0x274E, .end = 0x274E },
    .{ .start = 0x2753, .end = 0x2755 },
    .{ .start = 0x2757, .end = 0x2757 },
    .{ .start = 0x2763, .end = 0x2764 },
    .{ .start = 0x2795, .end = 0x2797 },
    .{ .start = 0x27A1, .end = 0x27A1 },
    .{ .start = 0x27B0, .end = 0x27B0 },
    .{ .start = 0x27BF, .end = 0x27BF },
    .{ .start = 0x2934, .end = 0x2935 },
    .{ .start = 0x2B05, .end = 0x2B07 },
    .{ .start = 0x2B1B, .end = 0x2B1C },
    .{ .start = 0x2B50, .end = 0x2B50 },
    .{ .start = 0x2B55, .end = 0x2B55 },
    .{ .start = 0x3030, .end = 0x3030 },
    .{ .start = 0x303D, .end = 0x303D },
    .{ .start = 0x3297, .end = 0x3297 },
    .{ .start = 0x3299, .end = 0x3299 },
    .{ .start = 0x1F000, .end = 0x1FAFF },
};

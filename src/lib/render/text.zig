const frame_mod = @import("../frame.zig");
const protocol = @import("../protocol/mod.zig");
const style = @import("../style.zig");
const unicode = @import("../unicode.zig");

const Frame = frame_mod.Frame;

pub const EllipsisSuffix = struct {
    text: []const u8,
    width: usize,
};

pub const EllipsisFit = struct {
    slice_end_byte: usize,
    use_ellipsis: bool,
    suffix: EllipsisSuffix,
};

pub fn countWrappedLines(text: []const u8, cols: usize) usize {
    const metrics = unicode.defaultTextMetrics();
    var lines: usize = 1;
    var col: usize = 0;

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\n') {
            lines += 1;
            col = 0;
            i += 1;
            continue;
        }

        const g = metrics.nextGrapheme(text, i);
        if (g.end <= i) break;
        const b0: u8 = text[g.start];
        if (b0 == '\r') {
            i = g.end;
            continue;
        }

        const width = metrics.graphemeWidthAtCol(text, g, col);
        if (cols != 0 and width > 0 and col > 0 and col + width > cols) {
            lines += 1;
            col = 0;
            continue;
        }

        if (width <= cols or cols == 0) {
            col += width;
        }
        i = g.end;
    }
    return lines;
}

pub fn countWrappedLinesSpans(spans: []const protocol.Span, cols: usize) usize {
    const metrics = unicode.defaultTextMetrics();
    var lines: usize = 1;
    var col: usize = 0;

    for (spans) |sp| {
        const text = sp.text;
        var i: usize = 0;
        while (i < text.len) {
            if (text[i] == '\n') {
                lines += 1;
                col = 0;
                i += 1;
                continue;
            }

            const g = metrics.nextGrapheme(text, i);
            if (g.end <= i) break;
            const b0: u8 = text[g.start];
            if (b0 == '\r') {
                i = g.end;
                continue;
            }
            const width = metrics.graphemeWidthAtCol(text, g, col);

            if (cols != 0 and width > 0 and col > 0 and col + width > cols) {
                lines += 1;
                col = 0;
                continue;
            }

            if (width <= cols or cols == 0) {
                col += width;
            }
            i = g.end;
        }
    }

    return lines;
}

pub fn ellipsisSuffixForWidth(max_cols: usize) EllipsisSuffix {
    if (max_cols == 0) return .{ .text = "", .width = 0 };

    const ellipsis = "…";
    const ellipsis_w = unicode.displayWidth(ellipsis);
    if (max_cols == 1) {
        if (ellipsis_w == 1) return .{ .text = ellipsis, .width = 1 };
        return .{ .text = ".", .width = 1 };
    }
    if (ellipsis_w > 0 and ellipsis_w <= max_cols) {
        return .{ .text = ellipsis, .width = ellipsis_w };
    }

    const dots = if (max_cols >= 3) "..." else if (max_cols == 2) ".." else ".";
    return .{ .text = dots, .width = unicode.displayWidth(dots) };
}

pub fn fitWithEllipsis(bytes: []const u8, max_cols: usize) EllipsisFit {
    if (max_cols == 0) {
        return .{
            .slice_end_byte = 0,
            .use_ellipsis = false,
            .suffix = .{ .text = "", .width = 0 },
        };
    }
    if (unicode.displayWidth(bytes) <= max_cols) {
        return .{
            .slice_end_byte = bytes.len,
            .use_ellipsis = false,
            .suffix = .{ .text = "", .width = 0 },
        };
    }

    const suffix = ellipsisSuffixForWidth(max_cols);
    const content_cols: usize = if (max_cols > suffix.width) max_cols - suffix.width else 0;
    const end = unicode.sliceEndByWidth(bytes, 0, content_cols);
    return .{
        .slice_end_byte = end,
        .use_ellipsis = true,
        .suffix = suffix,
    };
}

pub fn putGraphemeClipped(
    frame: *Frame,
    row: isize,
    col: isize,
    bytes: []const u8,
    width: usize,
    clip: anytype,
    st: style.PackedStyle,
) void {
    if (width == 0) return;
    if (clip.w == 0 or clip.h == 0) return;
    if (row < clip.y or row >= clip.y + @as(isize, @intCast(clip.h))) return;
    if (col < clip.x or col + @as(isize, @intCast(width)) > clip.x + @as(isize, @intCast(clip.w))) return;
    if (row < 0 or col < 0) return;
    if (width <= 2) {
        frame.putGraphemeStyled(
            @as(usize, @intCast(row)),
            @as(usize, @intCast(col)),
            bytes,
            @as(u2, @intCast(width)),
            st,
        );
        return;
    }

    // Frame cells encode width 0/1/2 only. Expand wider measured runs (e.g. tabs)
    // into plain spaces so column accounting remains correct.
    var dx: usize = 0;
    while (dx < width) : (dx += 1) {
        frame.putGraphemeStyled(
            @as(usize, @intCast(row)),
            @as(usize, @intCast(col + @as(isize, @intCast(dx)))),
            " ",
            1,
            st,
        );
    }
}

pub fn drawWrappedTextInRect(frame: *Frame, rect: anytype, clip: anytype, text: []const u8, st: style.PackedStyle) void {
    if (rect.w == 0 or rect.h == 0) return;
    const metrics = unicode.defaultTextMetrics();

    const max_rows: isize = rect.y + @as(isize, @intCast(rect.h));
    const cols: usize = rect.w;

    var row: isize = rect.y;
    var col: usize = 0;
    var i: usize = 0;

    while (i < text.len and row < max_rows) {
        if (text[i] == '\n') {
            row += 1;
            col = 0;
            i += 1;
            continue;
        }

        const g = metrics.nextGrapheme(text, i);
        if (g.end <= i) break;
        const b0: u8 = text[g.start];
        if (b0 == '\r') {
            i = g.end;
            continue;
        }
        const width = metrics.graphemeWidthAtCol(text, g, col);

        if (cols != 0 and width > 0 and col > 0 and col + width > cols) {
            row += 1;
            col = 0;
            continue;
        }

        if (width > 0 and cols != 0 and width > cols) {
            // Too wide to fit anywhere in this rect; skip without corrupting the grid.
            i = g.end;
            continue;
        }

        if (width > 0) {
            const abs_col: isize = rect.x + @as(isize, @intCast(col));
            putGraphemeClipped(frame, row, abs_col, text[g.start..g.end], width, clip, st);
            col += width;
        }
        i = g.end;
    }
}

pub fn drawWrappedStyledSpansInRect(
    frame: *Frame,
    rect: anytype,
    clip: anytype,
    spans: []const protocol.Span,
    base: style.Style,
    attrs_or: u8,
) void {
    if (rect.w == 0 or rect.h == 0) return;
    const metrics = unicode.defaultTextMetrics();

    const max_rows: isize = rect.y + @as(isize, @intCast(rect.h));
    const cols: usize = rect.w;

    var row: isize = rect.y;
    var col: usize = 0;

    for (spans) |sp| {
        if (row >= max_rows) break;

        const span_style = style.merge(base, sp.style);
        var span_packed = style.pack(span_style);
        span_packed.attrs |= attrs_or;

        const text = sp.text;
        var i: usize = 0;
        while (i < text.len and row < max_rows) {
            if (text[i] == '\n') {
                row += 1;
                col = 0;
                i += 1;
                continue;
            }

            const g = metrics.nextGrapheme(text, i);
            if (g.end <= i) break;
            const b0: u8 = text[g.start];
            if (b0 == '\r') {
                i = g.end;
                continue;
            }
            const width = metrics.graphemeWidthAtCol(text, g, col);

            if (cols != 0 and width > 0 and col > 0 and col + width > cols) {
                row += 1;
                col = 0;
                continue;
            }

            if (width > 0 and cols != 0 and width > cols) {
                i = g.end;
                continue;
            }

            if (width > 0) {
                const abs_col: isize = rect.x + @as(isize, @intCast(col));
                putGraphemeClipped(frame, row, abs_col, text[g.start..g.end], width, clip, span_packed);
                col += width;
            }
            i = g.end;
        }
    }
}

pub fn drawWrappedTextInRectAligned(
    frame: *Frame,
    rect: anytype,
    clip: anytype,
    text: []const u8,
    st: style.PackedStyle,
    ext_align: protocol.HorizontalAlign,
    v_align: protocol.VerticalAlign,
) void {
    if (rect.w == 0 or rect.h == 0) return;
    const metrics = unicode.defaultTextMetrics();

    const cols: usize = rect.w;
    const total_lines: usize = countWrappedLines(text, cols);
    const visible_lines: usize = @min(total_lines, rect.h);
    const start_row: isize = rect.y + @as(isize, @intCast(vAlignOffset(rect.h, visible_lines, v_align)));
    const max_rows: isize = start_row + @as(isize, @intCast(visible_lines));

    var row: isize = start_row;
    var i: usize = 0;

    while (i < text.len and row < max_rows) : (row += 1) {
        var j: usize = i;
        var col: usize = 0;

        while (j < text.len) {
            if (text[j] == '\n') break;

            const g = metrics.nextGrapheme(text, j);
            if (g.end <= j) break;
            const b0: u8 = text[g.start];
            if (b0 == '\r') {
                j = g.end;
                continue;
            }
            const width = metrics.graphemeWidthAtCol(text, g, col);

            if (cols != 0 and width > 0 and col > 0 and col + width > cols) {
                break;
            }

            if (width > 0 and cols != 0 and width > cols) {
                j = g.end;
                continue;
            }

            if (width > 0) col += width;
            j = g.end;
        }

        const x_off: usize = hAlignOffset(cols, col, ext_align);

        var draw_col: usize = 0;
        var k: usize = i;
        while (k < j and draw_col < cols) {
            const g = metrics.nextGrapheme(text, k);
            if (g.end <= k) break;
            const b0: u8 = text[g.start];
            if (b0 == '\r') {
                k = g.end;
                continue;
            }
            const width = metrics.graphemeWidthAtCol(text, g, draw_col);

            if (width > 0 and cols != 0 and width > cols) {
                k = g.end;
                continue;
            }

            if (width > 0 and draw_col + width > cols) break;

            if (width > 0) {
                const abs_col: isize = rect.x + @as(isize, @intCast(x_off + draw_col));
                putGraphemeClipped(frame, row, abs_col, text[g.start..g.end], width, clip, st);
                draw_col += width;
            }
            k = g.end;
        }

        if (j < text.len and text[j] == '\n') {
            i = j + 1;
        } else {
            i = j;
        }
    }
}

pub fn drawWrappedStyledSpansInRectAligned(
    frame: *Frame,
    rect: anytype,
    clip: anytype,
    spans: []const protocol.Span,
    base: style.Style,
    attrs_or: u8,
    ext_align: protocol.HorizontalAlign,
    v_align: protocol.VerticalAlign,
) void {
    if (rect.w == 0 or rect.h == 0) return;
    const metrics = unicode.defaultTextMetrics();

    const cols: usize = rect.w;
    const total_lines: usize = countWrappedLinesSpans(spans, cols);
    const visible_lines: usize = @min(total_lines, rect.h);
    const start_row: isize = rect.y + @as(isize, @intCast(vAlignOffset(rect.h, visible_lines, v_align)));
    const max_rows: isize = start_row + @as(isize, @intCast(visible_lines));

    const SpanPos = struct { span: usize, idx: usize };
    const eql = struct {
        fn pos(a: SpanPos, b: SpanPos) bool {
            return a.span == b.span and a.idx == b.idx;
        }
    }.pos;

    var row: isize = start_row;
    var pos: SpanPos = .{ .span = 0, .idx = 0 };

    while (pos.span < spans.len and row < max_rows) : (row += 1) {
        var scan: SpanPos = pos;
        var col: usize = 0;
        var end_pos: SpanPos = scan;
        var next_pos: SpanPos = scan;

        while (scan.span < spans.len) {
            const s = spans[scan.span].text;
            if (scan.idx >= s.len) {
                scan.span += 1;
                scan.idx = 0;
                continue;
            }
            if (s[scan.idx] == '\n') {
                end_pos = scan;
                next_pos = .{ .span = scan.span, .idx = scan.idx + 1 };
                break;
            }

            const g = metrics.nextGrapheme(s, scan.idx);
            if (g.end <= scan.idx) break;
            const b0: u8 = s[g.start];
            if (b0 == '\r') {
                scan.idx = g.end;
                continue;
            }
            const width = metrics.graphemeWidthAtCol(s, g, col);

            if (cols != 0 and width > 0 and col > 0 and col + width > cols) {
                end_pos = scan;
                next_pos = scan;
                break;
            }

            if (width > 0 and cols != 0 and width > cols) {
                scan.idx = g.end;
                continue;
            }

            if (width > 0) col += width;
            scan.idx = g.end;
            end_pos = scan;
            next_pos = scan;
        }

        const x_off: usize = hAlignOffset(cols, col, ext_align);

        var draw_col: usize = 0;
        var draw: SpanPos = pos;
        while (!eql(draw, end_pos) and draw.span < spans.len and draw_col < cols) {
            const sp = spans[draw.span];
            const span_style = style.merge(base, sp.style);
            var span_packed = style.pack(span_style);
            span_packed.attrs |= attrs_or;

            const s = sp.text;
            while (draw.idx < s.len and draw_col < cols) {
                if (eql(draw, end_pos)) break;
                if (s[draw.idx] == '\n') break;

                const g = metrics.nextGrapheme(s, draw.idx);
                if (g.end <= draw.idx) break;
                const b0: u8 = s[g.start];
                if (b0 == '\r') {
                    draw.idx = g.end;
                    continue;
                }
                const width = metrics.graphemeWidthAtCol(s, g, draw_col);

                if (width > 0 and cols != 0 and width > cols) {
                    draw.idx = g.end;
                    continue;
                }

                if (width > 0 and draw_col + width > cols) break;

                if (width > 0) {
                    const abs_col: isize = rect.x + @as(isize, @intCast(x_off + draw_col));
                    putGraphemeClipped(frame, row, abs_col, s[g.start..g.end], width, clip, span_packed);
                    draw_col += width;
                }

                draw.idx = g.end;
            }

            if (eql(draw, end_pos)) break;
            if (draw.idx >= s.len) {
                draw.span += 1;
                draw.idx = 0;
            } else {
                break;
            }
        }

        pos = next_pos;
        while (pos.span < spans.len and pos.idx >= spans[pos.span].text.len) {
            pos.span += 1;
            pos.idx = 0;
        }
    }
}

fn hAlignOffset(avail: usize, content: usize, align_mode: protocol.HorizontalAlign) usize {
    if (content >= avail) return 0;
    const extra: usize = avail - content;
    return switch (align_mode) {
        .left => 0,
        .center => extra / 2,
        .right => extra,
    };
}

fn vAlignOffset(avail: usize, content: usize, align_mode: protocol.VerticalAlign) usize {
    if (content >= avail) return 0;
    const extra: usize = avail - content;
    return switch (align_mode) {
        .top => 0,
        .center => extra / 2,
        .bottom => extra,
    };
}

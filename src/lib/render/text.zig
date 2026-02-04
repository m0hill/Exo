const frame_mod = @import("../frame.zig");
const protocol = @import("../protocol/mod.zig");
const style = @import("../style.zig");
const unicode = @import("../unicode.zig");

const Frame = frame_mod.Frame;

pub fn countWrappedLines(text: []const u8, cols: usize) usize {
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

        const g = unicode.nextGrapheme(text, i);
        if (g.end <= i) break;

        if (cols != 0 and g.width > 0 and col > 0 and col + g.width > cols) {
            lines += 1;
            col = 0;
            continue;
        }

        if (g.width <= cols or cols == 0) {
            col += g.width;
        }
        i = g.end;
    }
    return lines;
}

pub fn countWrappedLinesSpans(spans: []const protocol.Span, cols: usize) usize {
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

            const g = unicode.nextGrapheme(text, i);
            if (g.end <= i) break;

            if (cols != 0 and g.width > 0 and col > 0 and col + g.width > cols) {
                lines += 1;
                col = 0;
                continue;
            }

            if (g.width <= cols or cols == 0) {
                col += g.width;
            }
            i = g.end;
        }
    }

    return lines;
}

pub fn putGraphemeClipped(
    frame: *Frame,
    row: isize,
    col: isize,
    bytes: []const u8,
    width: u2,
    clip: anytype,
    st: style.PackedStyle,
) void {
    if (width == 0) return;
    if (clip.w == 0 or clip.h == 0) return;
    if (row < clip.y or row >= clip.y + @as(isize, @intCast(clip.h))) return;
    if (col < clip.x or col + @as(isize, @intCast(width)) > clip.x + @as(isize, @intCast(clip.w))) return;
    if (row < 0 or col < 0) return;
    frame.putGraphemeStyled(
        @as(usize, @intCast(row)),
        @as(usize, @intCast(col)),
        bytes,
        width,
        st,
    );
}

pub fn drawWrappedTextInRect(frame: *Frame, rect: anytype, clip: anytype, text: []const u8, st: style.PackedStyle) void {
    if (rect.w == 0 or rect.h == 0) return;

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

        const g = unicode.nextGrapheme(text, i);
        if (g.end <= i) break;

        if (cols != 0 and g.width > 0 and col > 0 and col + g.width > cols) {
            row += 1;
            col = 0;
            continue;
        }

        if (g.width > 0 and cols != 0 and g.width > cols) {
            // Too wide to fit anywhere in this rect; skip without corrupting the grid.
            i = g.end;
            continue;
        }

        if (g.width > 0) {
            const abs_col: isize = rect.x + @as(isize, @intCast(col));
            putGraphemeClipped(frame, row, abs_col, text[g.start..g.end], @as(u2, @intCast(g.width)), clip, st);
            col += g.width;
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

            const g = unicode.nextGrapheme(text, i);
            if (g.end <= i) break;

            if (cols != 0 and g.width > 0 and col > 0 and col + g.width > cols) {
                row += 1;
                col = 0;
                continue;
            }

            if (g.width > 0 and cols != 0 and g.width > cols) {
                i = g.end;
                continue;
            }

            if (g.width > 0) {
                const abs_col: isize = rect.x + @as(isize, @intCast(col));
                putGraphemeClipped(frame, row, abs_col, text[g.start..g.end], @as(u2, @intCast(g.width)), clip, span_packed);
                col += g.width;
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

            const g = unicode.nextGrapheme(text, j);
            if (g.end <= j) break;

            if (cols != 0 and g.width > 0 and col > 0 and col + g.width > cols) {
                break;
            }

            if (g.width > 0 and cols != 0 and g.width > cols) {
                j = g.end;
                continue;
            }

            if (g.width > 0) col += g.width;
            j = g.end;
        }

        const x_off: usize = hAlignOffset(cols, col, ext_align);

        var draw_col: usize = 0;
        var k: usize = i;
        while (k < j and draw_col < cols) {
            const g = unicode.nextGrapheme(text, k);
            if (g.end <= k) break;

            if (g.width > 0 and cols != 0 and g.width > cols) {
                k = g.end;
                continue;
            }

            if (g.width > 0 and draw_col + g.width > cols) break;

            if (g.width > 0) {
                const abs_col: isize = rect.x + @as(isize, @intCast(x_off + draw_col));
                putGraphemeClipped(frame, row, abs_col, text[g.start..g.end], @as(u2, @intCast(g.width)), clip, st);
                draw_col += g.width;
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

            const g = unicode.nextGrapheme(s, scan.idx);
            if (g.end <= scan.idx) break;

            if (cols != 0 and g.width > 0 and col > 0 and col + g.width > cols) {
                end_pos = scan;
                next_pos = scan;
                break;
            }

            if (g.width > 0 and cols != 0 and g.width > cols) {
                scan.idx = g.end;
                continue;
            }

            if (g.width > 0) col += g.width;
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

                const g = unicode.nextGrapheme(s, draw.idx);
                if (g.end <= draw.idx) break;

                if (g.width > 0 and cols != 0 and g.width > cols) {
                    draw.idx = g.end;
                    continue;
                }

                if (g.width > 0 and draw_col + g.width > cols) break;

                if (g.width > 0) {
                    const abs_col: isize = rect.x + @as(isize, @intCast(x_off + draw_col));
                    putGraphemeClipped(frame, row, abs_col, s[g.start..g.end], @as(u2, @intCast(g.width)), clip, span_packed);
                    draw_col += g.width;
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

const std = @import("std");

pub fn clampListScroll(scroll: usize, selected_index: ?usize, visible_height: usize, total_items: usize) usize {
    if (total_items == 0) return 0;

    const max_scroll: usize = if (total_items > visible_height) total_items - visible_height else 0;
    var out: usize = if (scroll > max_scroll) max_scroll else scroll;

    if (visible_height == 0) return out;
    const sel = selected_index orelse return out;

    if (sel < out) out = sel;
    if (sel >= out + visible_height) out = sel - visible_height + 1;
    if (out > max_scroll) out = max_scroll;
    return out;
}

pub fn clampScrollY(scroll_y: usize, viewport_h: usize, content_h: usize) usize {
    if (viewport_h == 0 or content_h == 0) return 0;
    const max_scroll: usize = if (content_h > viewport_h) content_h - viewport_h else 0;
    return if (scroll_y > max_scroll) max_scroll else scroll_y;
}

pub fn scrollIntoView(scroll_y: usize, viewport_h: usize, y0: usize, y1: usize, content_h: usize) usize {
    var out = scroll_y;
    if (viewport_h == 0) return 0;

    if (y0 < out) {
        out = y0;
    } else if (y1 > out + viewport_h) {
        out = y1 - viewport_h;
    }

    return clampScrollY(out, viewport_h, content_h);
}

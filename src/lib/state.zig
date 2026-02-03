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

const std = @import("std");
const tui = @import("tui");
const render = tui.render;

pub const ScrollbarTargetKind = enum {
    scroll,
    list,
    textarea,
};

pub const ScrollbarDrag = struct {
    active: bool = false,
    kind: ScrollbarTargetKind = .scroll,
    id_buf: std.ArrayList(u8) = .empty,
    id: []const u8 = "",
    drag_offset_y: usize = 0,

    pub fn deinit(self: *ScrollbarDrag, allocator: std.mem.Allocator) void {
        self.id_buf.deinit(allocator);
    }

    pub fn setActive(
        self: *ScrollbarDrag,
        allocator: std.mem.Allocator,
        kind: ScrollbarTargetKind,
        id: []const u8,
        drag_offset_y: usize,
    ) !void {
        self.active = true;
        self.kind = kind;
        self.drag_offset_y = drag_offset_y;
        self.id_buf.clearRetainingCapacity();
        try self.id_buf.appendSlice(allocator, id);
        self.id = self.id_buf.items;
    }

    pub fn clear(self: *ScrollbarDrag) void {
        self.active = false;
        self.drag_offset_y = 0;
        self.id_buf.clearRetainingCapacity();
        self.id = "";
    }
};

pub const InteractionResult = struct {
    changed: bool = false,
    suppress_pointer: bool = false,
};

pub fn shouldShow(enabled: bool, avail_w: usize, viewport_h: usize, content_h: usize) bool {
    return enabled and avail_w >= 2 and viewport_h > 0 and content_h > viewport_h;
}

pub fn computeThumb(
    track_h: usize,
    content_h: usize,
    viewport_h: usize,
    scroll_y: usize,
    min_thumb: usize,
) render.ScrollbarGeometry {
    return render.computeScrollbar(track_h, content_h, viewport_h, scroll_y, min_thumb);
}

pub fn maxScroll(content_h: usize, viewport_h: usize) usize {
    return if (content_h > viewport_h) content_h - viewport_h else 0;
}

pub fn scrollFromThumbTop(
    track_h: usize,
    content_h: usize,
    viewport_h: usize,
    thumb_top: usize,
    min_thumb: usize,
) usize {
    if (track_h == 0 or content_h == 0 or viewport_h == 0) return 0;
    const geom = render.computeScrollbar(track_h, content_h, viewport_h, 0, min_thumb);
    const travel = if (track_h > geom.thumb_h) track_h - geom.thumb_h else 0;
    const max_scroll = maxScroll(content_h, viewport_h);
    if (travel == 0 or max_scroll == 0) return 0;
    return @min(max_scroll, (thumb_top * max_scroll) / travel);
}

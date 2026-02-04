const std = @import("std");

const tui = @import("tui");
const mouse = tui.mouse;
const protocol = tui.protocol;
const render = tui.render;

const widgets_mod = @import("widgets.zig");
pub const widgets = widgets_mod;
const node_util = @import("node_util.zig");

const PointerKind = protocol.PointerKind;
const PointerButton = protocol.PointerButton;
const PointerEvent = protocol.PointerEvent;

const double_click_ns: u64 = 400 * std.time.ns_per_ms;
const drag_threshold_cells: usize = 1;

const Capture = struct {
    id_buf: std.ArrayList(u8) = .empty,
    id: ?[]const u8 = null,
    item_buf: std.ArrayList(u8) = .empty,
    item: ?[]const u8 = null,
    down_x: usize = 0,
    down_y: usize = 0,
    dragging: bool = false,
};

pub const PointerEngine = struct {
    pressed_buttons: u8 = 0,

    // Per-button capture: left/middle/right.
    captures: [3]Capture = .{ .{}, .{}, .{} },

    last_over_id_buf: std.ArrayList(u8) = .empty,
    last_over_id: ?[]const u8 = null,

    last_click_ns: u64 = 0,
    last_click_id_buf: std.ArrayList(u8) = .empty,
    last_click_id: ?[]const u8 = null,
    last_click_button: PointerButton = .none,
    last_click_x: usize = 0,
    last_click_y: usize = 0,
    last_clicks: u8 = 0,

    last_move_sent_id_buf: std.ArrayList(u8) = .empty,
    last_move_sent_id: ?[]const u8 = null,
    last_move_sent_kind: ?PointerKind = null,
    last_move_sent_x: usize = 0,
    last_move_sent_y: usize = 0,
    last_move_sent_buttons: u8 = 0,
    last_move_sent_mods: u8 = 0,

    pub fn deinit(self: *PointerEngine, allocator: std.mem.Allocator) void {
        self.last_over_id_buf.deinit(allocator);
        self.last_click_id_buf.deinit(allocator);
        self.last_move_sent_id_buf.deinit(allocator);
        for (&self.captures) |*c| {
            c.id_buf.deinit(allocator);
            c.item_buf.deinit(allocator);
        }
    }

    pub fn pruneAfterPatch(self: *PointerEngine, root: protocol.Node) void {
        for (&self.captures) |*c| {
            const id = c.id orelse continue;
            if (treeContainsId(root, id)) continue;
            clearOptId(&c.id_buf, &c.id);
            clearOptId(&c.item_buf, &c.item);
            c.dragging = false;
        }

        if (self.last_over_id) |id| {
            if (!treeContainsId(root, id)) clearOptId(&self.last_over_id_buf, &self.last_over_id);
        }
    }

    pub fn refreshAfterPatch(
        self: *PointerEngine,
        allocator: std.mem.Allocator,
        backend_in: anytype,
        widget_entries: []const widgets_mod.WidgetEntry,
        root: protocol.Node,
        rows: usize,
        cols: usize,
        x_opt: ?usize,
        y_opt: ?usize,
    ) !bool {
        if (x_opt == null or y_opt == null or !tui.mouseable.treeHasMouseables(root)) {
            if (self.last_over_id == null) return false;
            clearOptId(&self.last_over_id_buf, &self.last_over_id);
            self.resetMoveCoalesce();
            try protocol.writePointerEventJsonl(backend_in, .{
                .kind = .move,
                .id = "",
                .x = x_opt orelse 0,
                .y = y_opt orelse 0,
                .local_x = 0,
                .local_y = 0,
                .button = .none,
                .buttons = self.pressed_buttons,
                .mods = 0,
                .clicks = 1,
                .scroll_dx = 0,
                .scroll_dy = 0,
                .item = null,
                .captured = false,
            });
            return true;
        }

        const hit_root: protocol.Node = if (findTopmostModalLayer(root)) |modal_ptr| modal_ptr.* else root;
        var scroll_states = try collectRenderScrollStates(allocator, widget_entries);
        defer scroll_states.deinit(allocator);

        const x = x_opt.?;
        const y = y_opt.?;
        const hit = try hitTestMouseables(allocator, hit_root, root, rows, cols, x, y, scroll_states.items, widget_entries);
        if (hit.id == null) {
            if (self.last_over_id == null) return false;
            clearOptId(&self.last_over_id_buf, &self.last_over_id);
            self.resetMoveCoalesce();
            try protocol.writePointerEventJsonl(backend_in, .{
                .kind = .move,
                .id = "",
                .x = x,
                .y = y,
                .local_x = 0,
                .local_y = 0,
                .button = .none,
                .buttons = self.pressed_buttons,
                .mods = 0,
                .clicks = 1,
                .scroll_dx = 0,
                .scroll_dy = 0,
                .item = null,
                .captured = false,
            });
            return true;
        }

        if (self.last_over_id != null and std.mem.eql(u8, self.last_over_id.?, hit.id.?)) return false;
        try setOptId(allocator, &self.last_over_id_buf, &self.last_over_id, hit.id);
        const out: PointerEvent = .{
            .kind = .move,
            .id = hit.id.?,
            .x = x,
            .y = y,
            .local_x = hit.local_x,
            .local_y = hit.local_y,
            .button = .none,
            .buttons = self.pressed_buttons,
            .mods = 0,
            .clicks = 1,
            .scroll_dx = 0,
            .scroll_dy = 0,
            .item = hit.item,
            .captured = false,
        };
        return try self.writeMoveCoalesced(allocator, backend_in, out);
    }

    pub fn handleMouseEvent(
        self: *PointerEngine,
        allocator: std.mem.Allocator,
        backend_in: anytype,
        widget_entries: []const widgets_mod.WidgetEntry,
        root: protocol.Node,
        rows: usize,
        cols: usize,
        ev: mouse.MouseEvent,
        now_ns: u64,
    ) !bool {
        if (!tui.mouseable.treeHasMouseables(root)) {
            // Still emit a single leave event if we were previously over a mouseable.
            if (self.last_over_id != null) {
                clearOptId(&self.last_over_id_buf, &self.last_over_id);
                self.resetMoveCoalesce();
                try protocol.writePointerEventJsonl(backend_in, .{
                    .kind = .move,
                    .id = "",
                    .x = ev.x,
                    .y = ev.y,
                    .local_x = 0,
                    .local_y = 0,
                    .button = .none,
                    .buttons = self.pressed_buttons,
                    .mods = ev.mods,
                    .clicks = 1,
                    .scroll_dx = 0,
                    .scroll_dy = 0,
                    .item = null,
                    .captured = false,
                });
                return true;
            }
            return false;
        }

        const hit_root: protocol.Node = if (findTopmostModalLayer(root)) |modal_ptr| modal_ptr.* else root;

        var scroll_states = try collectRenderScrollStates(allocator, widget_entries);
        defer scroll_states.deinit(allocator);

        // Resolve primary capture (left > middle > right).
        const primary_pressed = primaryPressedButton(self.pressed_buttons);
        const primary_capture = if (primary_pressed != null)
            &self.captures[@as(usize, @intFromEnum(primary_pressed.?))]
        else
            null;

        switch (ev.kind) {
            .down => {
                const pb = pointerButtonFromMouse(ev.button) orelse return false;
                self.pressed_buttons |= buttonBit(pb);

                const hit = try hitTestMouseables(
                    allocator,
                    hit_root,
                    root,
                    rows,
                    cols,
                    ev.x,
                    ev.y,
                    scroll_states.items,
                    widget_entries,
                );
                if (hit.id == null) return false;

                const cap = &self.captures[@as(usize, @intFromEnum(pb))];
                try setOptId(allocator, &cap.id_buf, &cap.id, hit.id);
                try setOptId(allocator, &cap.item_buf, &cap.item, hit.item);
                cap.down_x = ev.x;
                cap.down_y = ev.y;
                cap.dragging = false;

                const clicks = self.computeClickCount(allocator, now_ns, hit.id.?, pb, ev.x, ev.y);
                const out: PointerEvent = .{
                    .kind = .down,
                    .id = hit.id.?,
                    .x = ev.x,
                    .y = ev.y,
                    .local_x = hit.local_x,
                    .local_y = hit.local_y,
                    .button = pb,
                    .buttons = self.pressed_buttons,
                    .mods = ev.mods,
                    .clicks = clicks,
                    .scroll_dx = 0,
                    .scroll_dy = 0,
                    .item = hit.item,
                    .captured = false,
                };
                try protocol.writePointerEventJsonl(backend_in, out);
                return true;
            },
            .up => {
                const pb = pointerButtonFromMouse(ev.button) orelse return false;
                self.pressed_buttons &= ~buttonBit(pb);

                const cap = &self.captures[@as(usize, @intFromEnum(pb))];
                const captured_id = cap.id;
                const captured_item = cap.item;

                var need_tx: bool = false;
                if (captured_id != null) {
                    const hit = try hitTestId(
                        root,
                        rows,
                        cols,
                        captured_id.?,
                        ev.x,
                        ev.y,
                        scroll_states.items,
                        widget_entries,
                    );
                    if (hit) |hh| {
                        try protocol.writePointerEventJsonl(backend_in, .{
                            .kind = .up,
                            .id = captured_id.?,
                            .x = ev.x,
                            .y = ev.y,
                            .local_x = hh.local_x,
                            .local_y = hh.local_y,
                            .button = pb,
                            .buttons = self.pressed_buttons,
                            .mods = ev.mods,
                            .clicks = 1,
                            .scroll_dx = 0,
                            .scroll_dy = 0,
                            .item = captured_item,
                            .captured = true,
                        });
                        need_tx = true;
                    }
                }

                clearOptId(&cap.id_buf, &cap.id);
                clearOptId(&cap.item_buf, &cap.item);
                cap.dragging = false;
                return need_tx;
            },
            .move => {
                const buttons = self.pressed_buttons;

                if (buttons != 0 and primary_capture != null and primary_capture.?.id != null) {
                    const cap = primary_capture.?;
                    const moved = movedBeyondThreshold(ev.x, ev.y, cap.down_x, cap.down_y, drag_threshold_cells);
                    if (!cap.dragging and moved) cap.dragging = true;
                    if (!cap.dragging) return false;

                    const id = cap.id.?;
                    const hit = try hitTestId(root, rows, cols, id, ev.x, ev.y, scroll_states.items, widget_entries) orelse return false;
                    const out: PointerEvent = .{
                        .kind = .drag,
                        .id = id,
                        .x = ev.x,
                        .y = ev.y,
                        .local_x = hit.local_x,
                        .local_y = hit.local_y,
                        .button = .none,
                        .buttons = buttons,
                        .mods = ev.mods,
                        .clicks = 1,
                        .scroll_dx = 0,
                        .scroll_dy = 0,
                        .item = cap.item,
                        .captured = true,
                    };
                    return try self.writeMoveCoalesced(allocator, backend_in, out);
                }

                const hit = try hitTestMouseables(
                    allocator,
                    hit_root,
                    root,
                    rows,
                    cols,
                    ev.x,
                    ev.y,
                    scroll_states.items,
                    widget_entries,
                );

                if (hit.id == null) {
                    // Emit a leave event once when transitioning from a target to empty space.
                    if (self.last_over_id != null) {
                        clearOptId(&self.last_over_id_buf, &self.last_over_id);
                        self.resetMoveCoalesce();
                        try protocol.writePointerEventJsonl(backend_in, .{
                            .kind = .move,
                            .id = "",
                            .x = ev.x,
                            .y = ev.y,
                            .local_x = 0,
                            .local_y = 0,
                            .button = .none,
                            .buttons = buttons,
                            .mods = ev.mods,
                            .clicks = 1,
                            .scroll_dx = 0,
                            .scroll_dy = 0,
                            .item = null,
                            .captured = false,
                        });
                        return true;
                    }
                    return false;
                }

                try setOptId(allocator, &self.last_over_id_buf, &self.last_over_id, hit.id);
                const out: PointerEvent = .{
                    .kind = .move,
                    .id = hit.id.?,
                    .x = ev.x,
                    .y = ev.y,
                    .local_x = hit.local_x,
                    .local_y = hit.local_y,
                    .button = .none,
                    .buttons = buttons,
                    .mods = ev.mods,
                    .clicks = 1,
                    .scroll_dx = 0,
                    .scroll_dy = 0,
                    .item = hit.item,
                    .captured = false,
                };
                return try self.writeMoveCoalesced(allocator, backend_in, out);
            },
            .wheel => {
                const hit = try hitTestMouseables(
                    allocator,
                    hit_root,
                    root,
                    rows,
                    cols,
                    ev.x,
                    ev.y,
                    scroll_states.items,
                    widget_entries,
                );
                if (hit.id == null) return false;
                const out: PointerEvent = .{
                    .kind = .scroll,
                    .id = hit.id.?,
                    .x = ev.x,
                    .y = ev.y,
                    .local_x = hit.local_x,
                    .local_y = hit.local_y,
                    .button = .none,
                    .buttons = self.pressed_buttons,
                    .mods = ev.mods,
                    .clicks = 1,
                    .scroll_dx = ev.wheel_dx,
                    .scroll_dy = ev.wheel_dy,
                    .item = hit.item,
                    .captured = false,
                };
                try protocol.writePointerEventJsonl(backend_in, out);
                return true;
            },
        }
    }

    fn resetMoveCoalesce(self: *PointerEngine) void {
        clearOptId(&self.last_move_sent_id_buf, &self.last_move_sent_id);
        self.last_move_sent_kind = null;
        self.last_move_sent_x = 0;
        self.last_move_sent_y = 0;
        self.last_move_sent_buttons = 0;
        self.last_move_sent_mods = 0;
    }

    fn writeMoveCoalesced(
        self: *PointerEngine,
        allocator: std.mem.Allocator,
        backend_in: anytype,
        ev: PointerEvent,
    ) !bool {
        if (self.last_move_sent_kind != null and self.last_move_sent_kind.? == ev.kind and
            self.last_move_sent_x == ev.x and self.last_move_sent_y == ev.y and
            self.last_move_sent_buttons == ev.buttons and self.last_move_sent_mods == ev.mods and
            optEql(self.last_move_sent_id, ev.id))
        {
            return false;
        }

        try setOptId(allocator, &self.last_move_sent_id_buf, &self.last_move_sent_id, ev.id);
        self.last_move_sent_kind = ev.kind;
        self.last_move_sent_x = ev.x;
        self.last_move_sent_y = ev.y;
        self.last_move_sent_buttons = ev.buttons;
        self.last_move_sent_mods = ev.mods;

        try protocol.writePointerEventJsonl(backend_in, ev);
        return true;
    }

    fn computeClickCount(
        self: *PointerEngine,
        allocator: std.mem.Allocator,
        now_ns: u64,
        id: []const u8,
        button: PointerButton,
        x: usize,
        y: usize,
    ) u8 {
        if (self.last_click_ns != 0 and now_ns <= self.last_click_ns + double_click_ns and
            self.last_click_button == button and optEql(self.last_click_id, id) and
            self.last_click_x == x and self.last_click_y == y)
        {
            const next = @min(@as(u8, 3), self.last_clicks + 1);
            self.last_clicks = next;
            self.last_click_ns = now_ns;
            return next;
        }

        self.last_clicks = 1;
        self.last_click_ns = now_ns;
        self.last_click_button = button;
        self.last_click_x = x;
        self.last_click_y = y;
        _ = setOptId(allocator, &self.last_click_id_buf, &self.last_click_id, id) catch {};
        return 1;
    }
};

const Hit = struct {
    id: ?[]const u8,
    local_x: usize = 0,
    local_y: usize = 0,
    item: ?[]const u8 = null,
};

fn collectRenderScrollStates(allocator: std.mem.Allocator, widget_entries: []const widgets_mod.WidgetEntry) !std.ArrayList(render.ScrollState) {
    var out: std.ArrayList(render.ScrollState) = .empty;
    errdefer out.deinit(allocator);
    for (widget_entries) |w| {
        if (w.state != .scroll) continue;
        const st = w.state.scroll;
        try out.append(allocator, .{
            .id = w.id.items,
            .scroll_y = st.scroll_y,
            .content_h = st.content_h,
            .viewport_h = st.viewport_h,
        });
    }
    return out;
}

fn hitTestMouseables(
    allocator: std.mem.Allocator,
    hit_root: protocol.Node,
    root: protocol.Node,
    rows: usize,
    cols: usize,
    x: usize,
    y: usize,
    scroll_states: []const render.ScrollState,
    widget_entries: []const widgets_mod.WidgetEntry,
) !Hit {
    var ids = try tui.mouseable.collectMouseables(allocator, hit_root);
    defer ids.deinit(allocator);

    var hit_id: ?[]const u8 = null;
    var hit_rect: render.Rect = undefined;

    for (ids.items) |id| {
        const r = render.findRectForIdWithScrolls(root, rows, cols, id, scroll_states) orelse continue;
        if (rectContains(r, x, y)) {
            hit_id = id;
            hit_rect = r;
        }
    }

    if (hit_id == null) return .{ .id = null };

    const lx = clampLocal(x, hit_rect.x, hit_rect.w);
    const ly = clampLocal(y, hit_rect.y, hit_rect.h);
    const item = listItemAtPoint(root, widget_entries, hit_id.?, hit_rect, y);
    return .{ .id = hit_id, .local_x = lx, .local_y = ly, .item = item };
}

fn hitTestId(
    root: protocol.Node,
    rows: usize,
    cols: usize,
    id: []const u8,
    x: usize,
    y: usize,
    scroll_states: []const render.ScrollState,
    widget_entries: []const widgets_mod.WidgetEntry,
) !?Hit {
    const r = render.findRectForIdWithScrolls(root, rows, cols, id, scroll_states) orelse return null;
    const lx = clampLocal(x, r.x, r.w);
    const ly = clampLocal(y, r.y, r.h);
    const item = listItemAtPoint(root, widget_entries, id, r, y);
    return .{ .id = id, .local_x = lx, .local_y = ly, .item = item };
}

fn listItemAtPoint(root: protocol.Node, widget_entries: []const widgets_mod.WidgetEntry, id: []const u8, rect: render.Rect, y: usize) ?[]const u8 {
    const l = node_util.findListNodeById(root, id) orelse return null;
    const visible_height = listVisibleHeight(rect, l);
    if (visible_height == 0) return null;
    const scroll_y = findListScroll(widget_entries, id);

    if (y < rect.y) return null;
    const row_idx: usize = y - rect.y;
    if (row_idx >= visible_height) return null;

    const start: usize = @min(scroll_y, l.children.len);
    const item_idx: usize = start + row_idx;
    if (item_idx >= l.children.len) return null;
    return node_util.nodeId(l.children[item_idx]);
}

fn listVisibleHeight(rect: render.Rect, l: protocol.ListNode) usize {
    const desired = l.height orelse rect.h;
    return @min(desired, rect.h);
}

fn findListScroll(widget_entries: []const widgets_mod.WidgetEntry, id: []const u8) usize {
    for (widget_entries) |w| {
        if (w.state != .list) continue;
        if (!std.mem.eql(u8, w.id.items, id)) continue;
        return w.state.list.scroll;
    }
    return 0;
}

fn clampLocal(abs: usize, origin: usize, span: usize) usize {
    if (span == 0) return 0;
    if (abs <= origin) return 0;
    const rel = abs - origin;
    if (rel >= span) return span - 1;
    return rel;
}

fn rectContains(r: render.Rect, x: usize, y: usize) bool {
    return x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h;
}

fn movedBeyondThreshold(x: usize, y: usize, start_x: usize, start_y: usize, threshold: usize) bool {
    const dx = if (x > start_x) x - start_x else start_x - x;
    const dy = if (y > start_y) y - start_y else start_y - y;
    return dx >= threshold or dy >= threshold;
}

fn buttonBit(button: PointerButton) u8 {
    return switch (button) {
        .left => 1,
        .middle => 2,
        .right => 4,
        .none => 0,
    };
}

fn primaryPressedButton(buttons: u8) ?PointerButton {
    if ((buttons & 1) != 0) return .left;
    if ((buttons & 2) != 0) return .middle;
    if ((buttons & 4) != 0) return .right;
    return null;
}

fn pointerButtonFromMouse(b: mouse.MouseButton) ?PointerButton {
    return switch (b) {
        .left => .left,
        .middle => .middle,
        .right => .right,
        .none => null,
    };
}

fn findTopmostModalLayer(root: protocol.Node) ?*const protocol.Node {
    var out: ?*const protocol.Node = null;
    findTopmostModalLayerInto(root, &out);
    return out;
}

fn findTopmostModalLayerInto(node: protocol.Node, out: *?*const protocol.Node) void {
    switch (node) {
        .overlay => |o| {
            findTopmostModalLayerInto(o.base.*, out);
            for (o.layers) |layer| {
                if (layer.modal) out.* = layer.node;
                findTopmostModalLayerInto(layer.node.*, out);
            }
        },
        .vbox => |v| for (v.children) |child| findTopmostModalLayerInto(child, out),
        .hbox => |h| for (h.children) |child| findTopmostModalLayerInto(child, out),
        .box => |b| findTopmostModalLayerInto(b.child.*, out),
        .scroll => |s| findTopmostModalLayerInto(s.child.*, out),
        .list => |l| for (l.children) |child| findTopmostModalLayerInto(child, out),
        else => {},
    }
}

fn treeContainsId(node: protocol.Node, id: []const u8) bool {
    if (std.mem.eql(u8, node_util.nodeId(node), id)) return true;
    return switch (node) {
        .vbox => |v| blk: {
            for (v.children) |child| {
                if (treeContainsId(child, id)) break :blk true;
            }
            break :blk false;
        },
        .hbox => |h| blk: {
            for (h.children) |child| {
                if (treeContainsId(child, id)) break :blk true;
            }
            break :blk false;
        },
        .box => |b| treeContainsId(b.child.*, id),
        .scroll => |s| treeContainsId(s.child.*, id),
        .overlay => |o| blk: {
            if (treeContainsId(o.base.*, id)) break :blk true;
            for (o.layers) |layer| {
                if (treeContainsId(layer.node.*, id)) break :blk true;
            }
            break :blk false;
        },
        .list => |l| blk: {
            for (l.children) |child| {
                if (treeContainsId(child, id)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn optEql(a: ?[]const u8, b: []const u8) bool {
    if (a == null) return false;
    return std.mem.eql(u8, a.?, b);
}

fn clearOptId(buf: *std.ArrayList(u8), out: *?[]const u8) void {
    buf.clearRetainingCapacity();
    out.* = null;
}

fn setOptId(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    out: *?[]const u8,
    next: ?[]const u8,
) !void {
    if (next == null or next.?.len == 0) {
        buf.clearRetainingCapacity();
        out.* = null;
        return;
    }
    if (out.* != null and std.mem.eql(u8, out.*.?, next.?)) return;
    buf.clearRetainingCapacity();
    try buf.appendSlice(allocator, next.?);
    out.* = buf.items;
}

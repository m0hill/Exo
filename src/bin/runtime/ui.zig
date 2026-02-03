const std = @import("std");

const tui = @import("tui");
const protocol = tui.protocol;
const render = tui.render;
const input = tui.input;
const mouse = tui.mouse;
const state = tui.state;
const terminal = tui.terminal;
const unicode = tui.unicode;

const key_decode = @import("key_decode.zig");
const log = @import("log.zig");

pub fn effectiveTermSize(sz: terminal.Size) terminal.Size {
    var rows = sz.rows;
    var cols = sz.cols;
    if (rows == 0) rows = 24;
    if (cols == 0) cols = 80;
    return .{ .rows = rows, .cols = cols };
}

pub fn inputVisibleCols(cols: usize) usize {
    const prefix_len: usize = 2;
    if (cols <= prefix_len) return 0;
    return cols - prefix_len;
}

pub fn clampLocalStateForResize(widgets: *std.ArrayList(WidgetEntry), root: protocol.Node, size: terminal.Size) void {
    const eff = effectiveTermSize(size);
    const rows: usize = @as(usize, eff.rows);
    const cols: usize = @as(usize, eff.cols);

    for (widgets.items) |*e| {
        switch (e.state) {
            .input => |*s| {
                s.cursor = @min(s.cursor, s.value.items.len);
                if (s.scroll_x > s.value.items.len) s.scroll_x = s.value.items.len;

                var visible_cols: usize = inputVisibleCols(cols);
                if (render.findRectForId(root, rows, cols, e.id.items)) |r| {
                    visible_cols = inputVisibleCols(r.w);
                }
                _ = input.ensure_cursor_visible(&s.scroll_x, s.cursor, s.value.items, visible_cols);
            },
            .list => {},
        }
    }

    for (widgets.items) |*e| {
        switch (e.state) {
            .list => {
                const list_id = e.id.items;
                const l = findListNodeById(root, list_id) orelse continue;
                var visible_height: usize = 0;

                if (render.findRectForId(root, rows, cols, list_id)) |r| {
                    visible_height = r.h;
                    const desired: usize = l.height orelse visible_height;
                    visible_height = @min(desired, visible_height);
                } else {
                    visible_height = l.height orelse rows;
                }

                clampListScrollForNode(widgets, l, visible_height);
            },
            else => {},
        }
    }
}

fn clampListScrollForNode(widgets: *std.ArrayList(WidgetEntry), l: protocol.ListNode, visible_height: usize) void {
    const idx = findWidgetIndex(widgets.items, l.id) orelse return;
    var st = &widgets.items[idx].state.list;

    var selected_index: ?usize = null;
    if (st.selected_id.items.len > 0) {
        for (l.children, 0..) |child, child_idx| {
            if (std.mem.eql(u8, nodeId(child), st.selected_id.items)) {
                selected_index = child_idx;
                break;
            }
        }
    }

    st.scroll = state.clampListScroll(st.scroll, selected_index, visible_height, l.children.len);
}

fn cloneNodeLeaky(allocator: std.mem.Allocator, node: protocol.Node) !protocol.Node {
    return switch (node) {
        .text => |t| .{ .text = .{
            .id = try allocator.dupe(u8, t.id),
            .w = t.w,
            .h = t.h,
            .flex = t.flex,
            .style = t.style,
            .text = try allocator.dupe(u8, t.text),
        } },
        .input => |i| .{ .input = .{
            .id = try allocator.dupe(u8, i.id),
            .w = i.w,
            .h = i.h,
            .flex = i.flex,
            .style = i.style,
            .placeholder_style = i.placeholder_style,
            .placeholder = if (i.placeholder) |p| try allocator.dupe(u8, p) else null,
        } },
        .vbox => |v| blk: {
            var children = try allocator.alloc(protocol.Node, v.children.len);
            for (v.children, 0..) |child, idx| {
                children[idx] = try cloneNodeLeaky(allocator, child);
            }
            break :blk .{ .vbox = .{
                .id = try allocator.dupe(u8, v.id),
                .w = v.w,
                .h = v.h,
                .flex = v.flex,
                .pad = v.pad,
                .clip = v.clip,
                .style = v.style,
                .children = children,
            } };
        },
        .hbox => |h| blk: {
            var children = try allocator.alloc(protocol.Node, h.children.len);
            for (h.children, 0..) |child, idx| {
                children[idx] = try cloneNodeLeaky(allocator, child);
            }
            break :blk .{ .hbox = .{
                .id = try allocator.dupe(u8, h.id),
                .w = h.w,
                .h = h.h,
                .flex = h.flex,
                .pad = h.pad,
                .clip = h.clip,
                .style = h.style,
                .children = children,
            } };
        },
        .list => |l| blk: {
            var children = try allocator.alloc(protocol.Node, l.children.len);
            for (l.children, 0..) |child, idx| {
                children[idx] = try cloneNodeLeaky(allocator, child);
            }
            break :blk .{ .list = .{
                .id = try allocator.dupe(u8, l.id),
                .w = l.w,
                .h = l.h,
                .flex = l.flex,
                .height = l.height,
                .style = l.style,
                .children = children,
            } };
        },
    };
}

fn nodeId(node: protocol.Node) []const u8 {
    return switch (node) {
        .vbox => |v| v.id,
        .hbox => |h| h.id,
        .text => |t| t.id,
        .input => |i| i.id,
        .list => |l| l.id,
    };
}

pub const FocusKind = enum {
    input,
    list,
};

const Focusable = struct {
    id: []const u8,
    kind: FocusKind,
};

const InputWidgetState = struct {
    value: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    scroll_x: usize = 0,
};

const ListWidgetState = struct {
    selected_id: std.ArrayList(u8) = .empty,
    scroll: usize = 0,
};

const WidgetState = union(enum) {
    input: InputWidgetState,
    list: ListWidgetState,
};

pub const WidgetEntry = struct {
    id: std.ArrayList(u8) = .empty,
    state: WidgetState,
};

pub fn deinitWidgetEntries(allocator: std.mem.Allocator, widgets: *std.ArrayList(WidgetEntry)) void {
    for (widgets.items) |*e| {
        e.id.deinit(allocator);
        switch (e.state) {
            .input => |*s| s.value.deinit(allocator),
            .list => |*s| s.selected_id.deinit(allocator),
        }
    }
    widgets.deinit(allocator);
}

pub fn buildRenderState(
    allocator: std.mem.Allocator,
    widgets: []const WidgetEntry,
    render_inputs: *std.ArrayList(render.InputState),
    render_lists: *std.ArrayList(render.ListState),
    focused_id: ?[]const u8,
) !render.RenderState {
    render_inputs.clearRetainingCapacity();
    render_lists.clearRetainingCapacity();

    for (widgets) |e| {
        switch (e.state) {
            .input => |s| {
                try render_inputs.append(allocator, .{
                    .id = e.id.items,
                    .value = s.value.items,
                    .cursor = s.cursor,
                    .scroll_x = s.scroll_x,
                });
            },
            .list => |s| {
                try render_lists.append(allocator, .{
                    .id = e.id.items,
                    .selected_id = s.selected_id.items,
                    .scroll = s.scroll,
                });
            },
        }
    }

    std.sort.pdq(render.InputState, render_inputs.items, {}, struct {
        fn lessThan(_: void, a: render.InputState, b: render.InputState) bool {
            return std.mem.order(u8, a.id, b.id) == .lt;
        }
    }.lessThan);
    std.sort.pdq(render.ListState, render_lists.items, {}, struct {
        fn lessThan(_: void, a: render.ListState, b: render.ListState) bool {
            return std.mem.order(u8, a.id, b.id) == .lt;
        }
    }.lessThan);

    return .{
        .focused_id = focused_id,
        .inputs = render_inputs.items,
        .lists = render_lists.items,
    };
}

fn collectFocusables(allocator: std.mem.Allocator, root: protocol.Node) !std.ArrayList(Focusable) {
    var out: std.ArrayList(Focusable) = .empty;
    errdefer out.deinit(allocator);
    try collectFocusablesInto(allocator, &out, root);
    return out;
}

fn collectFocusablesInto(allocator: std.mem.Allocator, out: *std.ArrayList(Focusable), node: protocol.Node) !void {
    switch (node) {
        .input => |i| {
            try out.append(allocator, .{ .id = i.id, .kind = .input });
        },
        .list => |l| {
            try out.append(allocator, .{ .id = l.id, .kind = .list });
        },
        .vbox => |v| {
            for (v.children) |child| try collectFocusablesInto(allocator, out, child);
        },
        .hbox => |h| {
            for (h.children) |child| try collectFocusablesInto(allocator, out, child);
        },
        .text => {},
    }
}

pub fn cycleFocusInTree(allocator: std.mem.Allocator, root: protocol.Node, current: ?[]const u8) !?[]const u8 {
    var focusables = try collectFocusables(allocator, root);
    defer focusables.deinit(allocator);

    if (focusables.items.len == 0) return null;
    if (current == null) return focusables.items[0].id;

    var current_idx: ?usize = null;
    for (focusables.items, 0..) |f, idx| {
        if (std.mem.eql(u8, f.id, current.?)) {
            current_idx = idx;
            break;
        }
    }

    if (current_idx == null) return focusables.items[0].id;
    const idx = current_idx.?;
    if (idx + 1 < focusables.items.len) return focusables.items[idx + 1].id;
    return null;
}

pub fn focusedKindInTree(allocator: std.mem.Allocator, root: protocol.Node, id: []const u8) !?FocusKind {
    var focusables = try collectFocusables(allocator, root);
    defer focusables.deinit(allocator);
    for (focusables.items) |f| {
        if (std.mem.eql(u8, f.id, id)) return f.kind;
    }
    return null;
}

pub fn setFocusId(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    focused_id: *?[]const u8,
    next: ?[]const u8,
) !void {
    if (next == null) {
        buf.clearRetainingCapacity();
        focused_id.* = null;
        return;
    }
    buf.clearRetainingCapacity();
    try buf.appendSlice(allocator, next.?);
    focused_id.* = buf.items;
}

pub fn syncUiAfterPatch(
    allocator: std.mem.Allocator,
    log_sink: *log.LogSink,
    backend_in: anytype,
    widgets: *std.ArrayList(WidgetEntry),
    focused_id_buf: *std.ArrayList(u8),
    focused_id: *?[]const u8,
    auto_focus_done: *bool,
    root: protocol.Node,
) !void {
    var focusables = try collectFocusables(allocator, root);
    defer focusables.deinit(allocator);

    pruneWidgetsNotInFocusables(allocator, widgets, focusables.items);
    try ensureWidgetsForFocusables(allocator, widgets, focusables.items);

    if (focused_id.* == null) {
        if (!auto_focus_done.* and focusables.items.len > 0) {
            try setFocusId(allocator, focused_id_buf, focused_id, focusables.items[0].id);
            auto_focus_done.* = true;
            log.logPrint(log_sink, "EVENT_TX name=focus id={s}\n", .{focused_id.* orelse ""});
            try protocol.writeFocusEventJsonl(backend_in, focused_id.* orelse "");
        }
    } else {
        if (!focusablesContainsId(focusables.items, focused_id.*.?)) {
            const next = if (focusables.items.len > 0) focusables.items[0].id else null;
            try setFocusId(allocator, focused_id_buf, focused_id, next);
            log.logPrint(log_sink, "EVENT_TX name=focus id={s}\n", .{focused_id.* orelse ""});
            try protocol.writeFocusEventJsonl(backend_in, focused_id.* orelse "");
        }
    }

    for (focusables.items) |f| {
        if (f.kind != .list) continue;
        try syncListForId(allocator, log_sink, backend_in, widgets, root, f.id);
    }
}

fn optEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn rectContains(r: render.Rect, x: usize, y: usize) bool {
    if (r.w == 0 or r.h == 0) return false;
    if (x < r.x or y < r.y) return false;
    if (x >= r.x + r.w) return false;
    if (y >= r.y + r.h) return false;
    return true;
}

fn listVisibleHeight(rect: render.Rect, l: protocol.ListNode) usize {
    const desired = l.height orelse rect.h;
    return @min(desired, rect.h);
}

fn findSelectedIndexInList(l: protocol.ListNode, selected_id: []const u8) ?usize {
    if (selected_id.len == 0) return null;
    for (l.children, 0..) |child, idx| {
        if (std.mem.eql(u8, nodeId(child), selected_id)) return idx;
    }
    return null;
}

pub fn handleMouseEvent(
    allocator: std.mem.Allocator,
    log_sink: *log.LogSink,
    backend_in: anytype,
    widgets: *std.ArrayList(WidgetEntry),
    focused_id_buf: *std.ArrayList(u8),
    focused_id: *?[]const u8,
    root: protocol.Node,
    rows: usize,
    cols: usize,
    ev: mouse.MouseEvent,
) !bool {
    switch (ev.kind) {
        .down_left => return try handleMouseDownLeft(
            allocator,
            log_sink,
            backend_in,
            widgets,
            focused_id_buf,
            focused_id,
            root,
            rows,
            cols,
            ev.x,
            ev.y,
        ),
        .wheel_up => return try handleMouseWheel(
            allocator,
            log_sink,
            widgets,
            root,
            rows,
            cols,
            ev.x,
            ev.y,
            -1,
        ),
        .wheel_down => return try handleMouseWheel(
            allocator,
            log_sink,
            widgets,
            root,
            rows,
            cols,
            ev.x,
            ev.y,
            1,
        ),
    }
}

fn handleMouseDownLeft(
    allocator: std.mem.Allocator,
    log_sink: *log.LogSink,
    backend_in: anytype,
    widgets: *std.ArrayList(WidgetEntry),
    focused_id_buf: *std.ArrayList(u8),
    focused_id: *?[]const u8,
    root: protocol.Node,
    rows: usize,
    cols: usize,
    x: usize,
    y: usize,
) !bool {
    var hit_idx: ?usize = null;
    var hit_rect: render.Rect = undefined;

    for (widgets.items, 0..) |w, idx| {
        const r = render.findRectForId(root, rows, cols, w.id.items) orelse continue;
        if (rectContains(r, x, y)) {
            hit_idx = idx;
            hit_rect = r;
            break;
        }
    }

    const idx = hit_idx orelse return false;
    const id = widgets.items[idx].id.items;

    var changed: bool = false;
    var need_flush: bool = false;

    if (!optEql(focused_id.*, id)) {
        try setFocusId(allocator, focused_id_buf, focused_id, id);
        log.logPrint(log_sink, "EVENT_TX name=focus id={s}\n", .{id});
        try protocol.writeFocusEventJsonl(backend_in, id);
        need_flush = true;
        changed = true;
    }

    switch (widgets.items[idx].state) {
        .input => |*st| {
            const visible_cols = inputVisibleCols(hit_rect.w);
            const before_cursor = st.cursor;
            const before_scroll = st.scroll_x;
            st.cursor = st.value.items.len;
            if (st.cursor > st.value.items.len) st.cursor = st.value.items.len;
            if (st.scroll_x > st.value.items.len) st.scroll_x = st.value.items.len;
            _ = input.ensure_cursor_visible(&st.scroll_x, st.cursor, st.value.items, visible_cols);
            if (st.cursor != before_cursor or st.scroll_x != before_scroll) changed = true;
        },
        .list => |*st| {
            const l = findListNodeById(root, id) orelse {
                if (need_flush) try backend_in.flush();
                return changed;
            };

            const visible_height = listVisibleHeight(hit_rect, l);
            if (visible_height == 0) {
                if (need_flush) try backend_in.flush();
                return changed;
            }

            const start: usize = @min(st.scroll, l.children.len);
            if (y < hit_rect.y) {
                if (need_flush) try backend_in.flush();
                return changed;
            }
            const row_idx: usize = y - hit_rect.y;
            if (row_idx >= visible_height) {
                if (need_flush) try backend_in.flush();
                return changed;
            }

            const item_idx: usize = start + row_idx;
            if (item_idx >= l.children.len) {
                if (need_flush) try backend_in.flush();
                return changed;
            }

            const next_id = nodeId(l.children[item_idx]);
            const selection_changed = !(st.selected_id.items.len > 0 and std.mem.eql(u8, st.selected_id.items, next_id));
            if (selection_changed) {
                st.selected_id.clearRetainingCapacity();
                try st.selected_id.appendSlice(allocator, next_id);
                log.logPrint(
                    log_sink,
                    "LIST_SELECT id={s} item={s} index={d} scroll={d}\n",
                    .{ id, next_id, item_idx, st.scroll },
                );
                log.logPrint(log_sink, "EVENT_TX name=select id={s} item={s}\n", .{ id, next_id });
                try protocol.writeSelectEventJsonl(backend_in, id, next_id);
                need_flush = true;
                changed = true;
            }

            const selected_index = findSelectedIndexInList(l, st.selected_id.items);
            const before_scroll = st.scroll;
            st.scroll = state.clampListScroll(st.scroll, selected_index, visible_height, l.children.len);
            if (st.scroll != before_scroll) changed = true;
        },
    }

    if (need_flush) try backend_in.flush();
    return changed;
}

fn handleMouseWheel(
    allocator: std.mem.Allocator,
    log_sink: *log.LogSink,
    widgets: *std.ArrayList(WidgetEntry),
    root: protocol.Node,
    rows: usize,
    cols: usize,
    x: usize,
    y: usize,
    delta: isize,
) !bool {
    _ = allocator;
    _ = log_sink;

    for (widgets.items) |*w| {
        if (w.state != .list) continue;
        const list_id = w.id.items;

        const r = render.findRectForId(root, rows, cols, list_id) orelse continue;
        if (!rectContains(r, x, y)) continue;

        const l = findListNodeById(root, list_id) orelse return false;
        const visible_height = listVisibleHeight(r, l);
        if (visible_height == 0) return false;

        const stw = &w.state.list;
        const max_scroll: usize = if (l.children.len > visible_height) l.children.len - visible_height else 0;

        var next: usize = stw.scroll;
        if (delta > 0) {
            if (next < max_scroll) next += 1;
        } else if (delta < 0) {
            if (next > 0) next -= 1;
        }

        const selected_index = findSelectedIndexInList(l, stw.selected_id.items);
        next = state.clampListScroll(next, selected_index, visible_height, l.children.len);
        if (next == stw.scroll) return false;
        stw.scroll = next;
        return true;
    }

    return false;
}

fn pruneWidgetsNotInFocusables(
    allocator: std.mem.Allocator,
    widgets: *std.ArrayList(WidgetEntry),
    focusables: []const Focusable,
) void {
    var i: usize = widgets.items.len;
    while (i > 0) {
        i -= 1;
        const id = widgets.items[i].id.items;
        if (focusablesContainsId(focusables, id)) continue;
        deinitWidgetEntry(allocator, &widgets.items[i]);
        _ = widgets.swapRemove(i);
    }
}

fn deinitWidgetEntry(allocator: std.mem.Allocator, e: *WidgetEntry) void {
    e.id.deinit(allocator);
    switch (e.state) {
        .input => |*s| s.value.deinit(allocator),
        .list => |*s| s.selected_id.deinit(allocator),
    }
}

fn focusablesContainsId(focusables: []const Focusable, id: []const u8) bool {
    for (focusables) |f| {
        if (std.mem.eql(u8, f.id, id)) return true;
    }
    return false;
}

fn ensureWidgetsForFocusables(
    allocator: std.mem.Allocator,
    widgets: *std.ArrayList(WidgetEntry),
    focusables: []const Focusable,
) !void {
    for (focusables) |f| {
        _ = try ensureWidgetKind(allocator, widgets, f.id, f.kind);
    }
}

fn ensureWidgetKind(
    allocator: std.mem.Allocator,
    widgets: *std.ArrayList(WidgetEntry),
    id: []const u8,
    kind: FocusKind,
) !usize {
    if (findWidgetIndex(widgets.items, id)) |idx| {
        switch (widgets.items[idx].state) {
            .input => if (kind == .input) return idx else {},
            .list => if (kind == .list) return idx else {},
        }
        deinitWidgetEntryState(allocator, &widgets.items[idx]);
        widgets.items[idx].state = initWidgetState(kind);
        return idx;
    }

    var id_buf: std.ArrayList(u8) = .empty;
    errdefer id_buf.deinit(allocator);
    try id_buf.appendSlice(allocator, id);
    try widgets.append(allocator, .{ .id = id_buf, .state = initWidgetState(kind) });
    return widgets.items.len - 1;
}

fn deinitWidgetEntryState(allocator: std.mem.Allocator, e: *WidgetEntry) void {
    switch (e.state) {
        .input => |*s| s.value.deinit(allocator),
        .list => |*s| s.selected_id.deinit(allocator),
    }
}

fn initWidgetState(kind: FocusKind) WidgetState {
    return switch (kind) {
        .input => .{ .input = .{} },
        .list => .{ .list = .{} },
    };
}

fn findWidgetIndex(widgets: []const WidgetEntry, id: []const u8) ?usize {
    for (widgets, 0..) |e, idx| {
        if (std.mem.eql(u8, e.id.items, id)) return idx;
    }
    return null;
}

fn findListNodeById(root: protocol.Node, id: []const u8) ?protocol.ListNode {
    if (std.mem.eql(u8, nodeId(root), id)) {
        return switch (root) {
            .list => |l| l,
            else => null,
        };
    }

    return switch (root) {
        .vbox => |v| blk: {
            for (v.children) |child| {
                if (findListNodeById(child, id)) |l| break :blk l;
            }
            break :blk null;
        },
        .hbox => |h| blk: {
            for (h.children) |child| {
                if (findListNodeById(child, id)) |l| break :blk l;
            }
            break :blk null;
        },
        .list => |l| blk: {
            for (l.children) |child| {
                if (findListNodeById(child, id)) |ll| break :blk ll;
            }
            break :blk null;
        },
        else => null,
    };
}

fn syncListForId(
    allocator: std.mem.Allocator,
    log_sink: *log.LogSink,
    backend_in: anytype,
    widgets: *std.ArrayList(WidgetEntry),
    root: protocol.Node,
    list_id: []const u8,
) !void {
    const l = findListNodeById(root, list_id) orelse return;
    if (l.children.len == 0) {
        if (findWidgetIndex(widgets.items, list_id)) |idx| {
            const st = &widgets.items[idx].state.list;
            st.selected_id.clearRetainingCapacity();
            st.scroll = 0;
        }
        return;
    }

    const idx = try ensureWidgetKind(allocator, widgets, list_id, .list);
    var st = &widgets.items[idx].state.list;

    var selected_index: ?usize = null;
    if (st.selected_id.items.len > 0) {
        for (l.children, 0..) |child, child_idx| {
            if (std.mem.eql(u8, nodeId(child), st.selected_id.items)) {
                selected_index = child_idx;
                break;
            }
        }
    }

    var selection_changed = false;
    if (selected_index == null) {
        const new_id = nodeId(l.children[0]);
        st.selected_id.clearRetainingCapacity();
        try st.selected_id.appendSlice(allocator, new_id);
        selected_index = 0;
        selection_changed = true;
    }

    const height = l.height orelse l.children.len;
    const effective_height = if (height == 0) l.children.len else height;

    const sel_idx = selected_index.?;
    const max_scroll = if (l.children.len > effective_height) l.children.len - effective_height else 0;
    if (st.scroll > max_scroll) st.scroll = max_scroll;
    if (sel_idx < st.scroll) st.scroll = sel_idx;
    if (sel_idx >= st.scroll + effective_height) st.scroll = sel_idx - effective_height + 1;

    log.logPrint(
        log_sink,
        "LIST_SELECT id={s} item={s} index={d} scroll={d}\n",
        .{ list_id, st.selected_id.items, sel_idx, st.scroll },
    );
    if (selection_changed) {
        log.logPrint(log_sink, "EVENT_TX name=select id={s} item={s}\n", .{ list_id, st.selected_id.items });
        try protocol.writeSelectEventJsonl(backend_in, list_id, st.selected_id.items);
    }
}

pub fn moveListSelectionForId(
    allocator: std.mem.Allocator,
    log_sink: *log.LogSink,
    backend_in: anytype,
    widgets: *std.ArrayList(WidgetEntry),
    root: protocol.Node,
    list_id: []const u8,
    delta: isize,
) !bool {
    const l = findListNodeById(root, list_id) orelse return false;
    if (l.children.len == 0) return false;

    const idx = try ensureWidgetKind(allocator, widgets, list_id, .list);
    var st = &widgets.items[idx].state.list;

    var current_idx: usize = 0;
    if (st.selected_id.items.len > 0) {
        for (l.children, 0..) |child, child_idx| {
            if (std.mem.eql(u8, nodeId(child), st.selected_id.items)) {
                current_idx = child_idx;
                break;
            }
        }
    }

    const len: isize = @as(isize, @intCast(l.children.len));
    const next_idx_signed = @min(@max(@as(isize, @intCast(current_idx)) + delta, 0), len - 1);
    const next_idx: usize = @as(usize, @intCast(next_idx_signed));
    const next_id = nodeId(l.children[next_idx]);
    if (st.selected_id.items.len > 0 and std.mem.eql(u8, st.selected_id.items, next_id)) return false;

    st.selected_id.clearRetainingCapacity();
    try st.selected_id.appendSlice(allocator, next_id);

    const height = l.height orelse l.children.len;
    const effective_height = if (height == 0) l.children.len else height;
    const max_scroll = if (l.children.len > effective_height) l.children.len - effective_height else 0;
    if (st.scroll > max_scroll) st.scroll = max_scroll;
    if (next_idx < st.scroll) st.scroll = next_idx;
    if (next_idx >= st.scroll + effective_height) st.scroll = next_idx - effective_height + 1;

    log.logPrint(
        log_sink,
        "LIST_SELECT id={s} item={s} index={d} scroll={d}\n",
        .{ list_id, next_id, next_idx, st.scroll },
    );
    log.logPrint(log_sink, "EVENT_TX name=select id={s} item={s}\n", .{ list_id, next_id });
    try protocol.writeSelectEventJsonl(backend_in, list_id, next_id);
    return true;
}

pub fn activateListForId(log_sink: *log.LogSink, backend_in: anytype, widgets: []const WidgetEntry, list_id: []const u8) !void {
    const idx = findWidgetIndex(widgets, list_id) orelse return;
    const st = widgets[idx].state.list;
    if (st.selected_id.items.len == 0) return;
    log.logPrint(log_sink, "EVENT_TX name=activate id={s} item={s}\n", .{ list_id, st.selected_id.items });
    try protocol.writeActivateEventJsonl(backend_in, list_id, st.selected_id.items);
}

pub fn handleFocusedInputKey(
    allocator: std.mem.Allocator,
    widgets: *std.ArrayList(WidgetEntry),
    input_id: []const u8,
    key: key_decode.DecodedKey,
    visible_cols: usize,
) !bool {
    const idx = try ensureWidgetKind(allocator, widgets, input_id, .input);
    var st = &widgets.items[idx].state.input;

    const before_cursor: usize = st.cursor;
    const before_len: usize = st.value.items.len;
    const before_scroll: usize = st.scroll_x;

    var changed: bool = false;
    switch (key) {
        .byte => |b| changed = try input.handleInputByte(allocator, &st.value, &st.cursor, b),
        .utf8 => |u| changed = try input.insertUtf8Bytes(allocator, &st.value, &st.cursor, u.slice()),
        .left => {
            const next = unicode.prevGraphemeBoundary(st.value.items, st.cursor);
            if (next != st.cursor) {
                st.cursor = next;
                changed = true;
            }
        },
        .right => {
            const next = unicode.nextGraphemeBoundary(st.value.items, st.cursor);
            if (next != st.cursor) {
                st.cursor = next;
                changed = true;
            }
        },
        .home => if (st.cursor != 0) {
            st.cursor = 0;
            changed = true;
        },
        .end => if (st.cursor != st.value.items.len) {
            st.cursor = st.value.items.len;
            changed = true;
        },
        .delete => changed = input.delete_at_cursor(&st.value, &st.cursor),
        .word_left => {
            const next = input.word_left(st.value.items, st.cursor);
            const clamped = unicode.clampGraphemeBoundary(st.value.items, next);
            if (clamped != st.cursor) {
                st.cursor = clamped;
                changed = true;
            }
        },
        .word_right => {
            const next = input.word_right(st.value.items, st.cursor);
            const clamped = unicode.clampGraphemeBoundary(st.value.items, next);
            if (clamped != st.cursor) {
                st.cursor = clamped;
                changed = true;
            }
        },
        else => return false,
    }

    if (!changed and before_cursor == st.cursor and before_len == st.value.items.len and before_scroll == st.scroll_x) return false;

    if (st.cursor > st.value.items.len) st.cursor = st.value.items.len;
    if (st.scroll_x > st.value.items.len) st.scroll_x = st.value.items.len;
    const scroll_changed = input.ensure_cursor_visible(&st.scroll_x, st.cursor, st.value.items, visible_cols);
    return changed or scroll_changed;
}

pub fn emitInputEventForId(log_sink: *log.LogSink, backend_in: anytype, widgets: []const WidgetEntry, input_id: []const u8) !void {
    const idx = findWidgetIndex(widgets, input_id) orelse return;
    const st = widgets[idx].state.input;
    log.logPrint(
        log_sink,
        "EVENT_TX name=input id={s} len={d} cursor={d}\n",
        .{ input_id, st.value.items.len, st.cursor },
    );
    try protocol.writeInputEventJsonl(backend_in, input_id, st.value.items, st.cursor);
}

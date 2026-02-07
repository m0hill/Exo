const std = @import("std");
const builtin = @import("builtin");

const tui = @import("tui");
const protocol = tui.protocol;
const render = tui.render;
const input = tui.input;
const mouse = tui.mouse;
const state = tui.state;
const terminal = tui.terminal;
const hover = tui.hover;
const unicode = tui.unicode;
const keys = tui.keys;

const log = if (builtin.is_test)
    struct {
        pub const LogSink = struct {};
        pub fn logPrint(_: *LogSink, comptime _: []const u8, _: anytype) void {}
    }
else
    @import("../log.zig");
const node_util = @import("node_util.zig");

pub const pointer = @import("pointer.zig");

pub fn makeNoopLogSink() log.LogSink {
    return .{};
}

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

fn textareaCursorVisualY(value: []const u8, cursor: usize, cols: usize) usize {
    const effective_cursor = unicode.clampGraphemeBoundary(value, @min(cursor, value.len));
    if (effective_cursor == 0) return 0;

    var byte_idx: usize = 0;
    var y: usize = 0;
    var x: usize = 0;

    while (byte_idx < effective_cursor) {
        const g = unicode.nextGrapheme(value, byte_idx);
        if (g.end <= byte_idx) break;

        const b0: u8 = value[g.start];
        if (b0 == '\r') {
            byte_idx = g.end;
            continue;
        }
        if (b0 == '\n') {
            y += 1;
            x = 0;
            byte_idx = g.end;
            continue;
        }

        var width: usize = g.width;
        if (b0 == '\t') width = 1;
        if (width == 0) {
            byte_idx = g.end;
            continue;
        }

        if (cols == 0) {
            byte_idx = g.end;
            continue;
        }

        if (width > cols) {
            byte_idx = g.end;
            continue;
        }

        if (x + width > cols) {
            y += 1;
            x = 0;
            continue;
        }

        x += width;
        byte_idx = g.end;
    }

    return y;
}

fn textareaVisualLines(value: []const u8, cols: usize) usize {
    var byte_idx: usize = 0;
    var y: usize = 0;
    var x: usize = 0;

    while (byte_idx < value.len) {
        const g = unicode.nextGrapheme(value, byte_idx);
        if (g.end <= byte_idx) break;

        const b0: u8 = value[g.start];
        if (b0 == '\r') {
            byte_idx = g.end;
            continue;
        }
        if (b0 == '\n') {
            y += 1;
            x = 0;
            byte_idx = g.end;
            continue;
        }

        var width: usize = g.width;
        if (b0 == '\t') width = 1;
        if (width == 0) {
            byte_idx = g.end;
            continue;
        }

        if (cols == 0) {
            byte_idx = g.end;
            continue;
        }

        if (width > cols) {
            byte_idx = g.end;
            continue;
        }

        if (x + width > cols) {
            y += 1;
            x = 0;
            continue;
        }

        x += width;
        byte_idx = g.end;
    }

    return y + 1;
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
            .textarea => |*s| {
                s.cursor = @min(s.cursor, s.value.items.len);

                var visible_rows: usize = rows;
                var visible_cols: usize = cols;
                if (render.findRectForId(root, rows, cols, e.id.items)) |r| {
                    visible_rows = r.h;
                    visible_cols = r.w;
                }

                const cursor_y = textareaCursorVisualY(s.value.items, s.cursor, visible_cols);
                const content_h = textareaVisualLines(s.value.items, visible_cols);
                s.scroll_y = state.scrollIntoView(s.scroll_y, visible_rows, cursor_y, cursor_y + 1, content_h);
            },
            .list => {},
            .scroll => {},
            .action => {},
        }
    }

    for (widgets.items) |*e| {
        switch (e.state) {
            .list => {
                const list_id = e.id.items;
                const l = node_util.findListNodeById(root, list_id) orelse continue;
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
            .scroll => {
                syncScrollForId(widgets, root, rows, cols, e.id.items);
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
            if (std.mem.eql(u8, node_util.nodeId(child), st.selected_id.items)) {
                selected_index = child_idx;
                break;
            }
        }
    }

    st.scroll = state.clampListScroll(st.scroll, selected_index, visible_height, l.children.len);
}

// cloneNodeLeaky/nodeId moved to ui_node_util.zig

const widgets_mod = @import("widgets.zig");
pub const FocusKind = widgets_mod.FocusKind;
pub const WidgetEntry = widgets_mod.WidgetEntry;
const WidgetState = widgets_mod.WidgetState;

pub const HoverHit = hover.HoverHit;

const Focusable = struct {
    id: []const u8,
    kind: FocusKind,
    scope: ?[]const u8,
};

pub fn deinitWidgetEntries(allocator: std.mem.Allocator, widgets: *std.ArrayList(WidgetEntry)) void {
    for (widgets.items) |*e| {
        e.id.deinit(allocator);
        switch (e.state) {
            .input => |*s| s.value.deinit(allocator),
            .textarea => |*s| s.value.deinit(allocator),
            .list => |*s| s.selected_id.deinit(allocator),
            .scroll => {},
            .action => {},
        }
    }
    widgets.deinit(allocator);
}

pub fn buildRenderState(
    allocator: std.mem.Allocator,
    widgets: []const WidgetEntry,
    render_inputs: *std.ArrayList(render.InputState),
    render_textareas: *std.ArrayList(render.TextareaState),
    render_lists: *std.ArrayList(render.ListState),
    render_scrolls: *std.ArrayList(render.ScrollState),
    focused_id: ?[]const u8,
    hovered_id: ?[]const u8,
    hovered_item: ?[]const u8,
    active_id: ?[]const u8,
) !render.RenderState {
    render_inputs.clearRetainingCapacity();
    render_textareas.clearRetainingCapacity();
    render_lists.clearRetainingCapacity();
    render_scrolls.clearRetainingCapacity();

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
            .textarea => |s| {
                try render_textareas.append(allocator, .{
                    .id = e.id.items,
                    .value = s.value.items,
                    .cursor = s.cursor,
                    .scroll_y = s.scroll_y,
                });
            },
            .list => |s| {
                try render_lists.append(allocator, .{
                    .id = e.id.items,
                    .selected_id = s.selected_id.items,
                    .scroll = s.scroll,
                });
            },
            .scroll => |s| {
                try render_scrolls.append(allocator, .{
                    .id = e.id.items,
                    .scroll_y = s.scroll_y,
                    .content_h = s.content_h,
                    .viewport_h = s.viewport_h,
                });
            },
            .action => {},
        }
    }

    std.sort.pdq(render.InputState, render_inputs.items, {}, struct {
        fn lessThan(_: void, a: render.InputState, b: render.InputState) bool {
            return std.mem.order(u8, a.id, b.id) == .lt;
        }
    }.lessThan);
    std.sort.pdq(render.TextareaState, render_textareas.items, {}, struct {
        fn lessThan(_: void, a: render.TextareaState, b: render.TextareaState) bool {
            return std.mem.order(u8, a.id, b.id) == .lt;
        }
    }.lessThan);
    std.sort.pdq(render.ListState, render_lists.items, {}, struct {
        fn lessThan(_: void, a: render.ListState, b: render.ListState) bool {
            return std.mem.order(u8, a.id, b.id) == .lt;
        }
    }.lessThan);
    std.sort.pdq(render.ScrollState, render_scrolls.items, {}, struct {
        fn lessThan(_: void, a: render.ScrollState, b: render.ScrollState) bool {
            return std.mem.order(u8, a.id, b.id) == .lt;
        }
    }.lessThan);

    return .{
        .focused_id = focused_id,
        .hovered_id = hovered_id,
        .hovered_item = hovered_item,
        .active_id = active_id,
        .inputs = render_inputs.items,
        .textareas = render_textareas.items,
        .lists = render_lists.items,
        .scrolls = render_scrolls.items,
    };
}

fn collectFocusables(allocator: std.mem.Allocator, root: protocol.Node) !std.ArrayList(Focusable) {
    var out: std.ArrayList(Focusable) = .empty;
    errdefer out.deinit(allocator);
    try collectFocusablesInto(allocator, &out, root, false, null);
    return out;
}

fn nodeFocusScope(node: protocol.Node) ?[]const u8 {
    return switch (node) {
        .vbox => |v| v.focus_scope,
        .hbox => |h| h.focus_scope,
        .box => |b| b.focus_scope,
        .scroll => |s| s.focus_scope,
        .overlay => |o| o.focus_scope,
        .text => |t| t.focus_scope,
        .styled_text => |t| t.focus_scope,
        .input => |i| i.focus_scope,
        .textarea => |t| t.focus_scope,
        .list => |l| l.focus_scope,
    };
}

fn collectFocusablesInto(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(Focusable),
    node: protocol.Node,
    disabled_ancestor: bool,
    inherited_scope: ?[]const u8,
) !void {
    const disabled = disabled_ancestor or switch (node) {
        .vbox => |v| v.disabled,
        .hbox => |h| h.disabled,
        .box => |b| b.disabled,
        .scroll => |s| s.disabled,
        .overlay => |o| o.disabled,
        .text => |t| t.disabled,
        .styled_text => |t| t.disabled,
        .input => |i| i.disabled,
        .textarea => |t| t.disabled,
        .list => |l| l.disabled,
    };
    if (disabled) return;
    const local_scope = nodeFocusScope(node);
    const scope = if (local_scope != null and local_scope.?.len > 0) local_scope else inherited_scope;

    switch (node) {
        .input => |i| {
            if (!i.focusable) return;
            try out.append(allocator, .{ .id = i.id, .kind = .input, .scope = scope });
        },
        .textarea => |t| {
            if (!t.focusable) return;
            try out.append(allocator, .{ .id = t.id, .kind = .textarea, .scope = scope });
        },
        .list => |l| {
            if (!l.focusable) return;
            try out.append(allocator, .{ .id = l.id, .kind = .list, .scope = scope });
        },
        .box => |b| {
            if (b.focusable) try out.append(allocator, .{ .id = b.id, .kind = .action, .scope = scope });
            try collectFocusablesInto(allocator, out, b.child.*, false, scope);
        },
        .scroll => |s| {
            // Prefer leaf focusables (inputs/lists) under the pointer before the viewport itself.
            try collectFocusablesInto(allocator, out, s.child.*, false, scope);
            if (s.focusable) try out.append(allocator, .{ .id = s.id, .kind = .scroll, .scope = scope });
        },
        .overlay => |o| {
            if (o.focusable) try out.append(allocator, .{ .id = o.id, .kind = .action, .scope = scope });
            try collectFocusablesInto(allocator, out, o.base.*, false, scope);
            for (o.layers) |layer| {
                try collectFocusablesInto(allocator, out, layer.node.*, false, scope);
            }
        },
        .vbox => |v| {
            if (v.focusable) try out.append(allocator, .{ .id = v.id, .kind = .action, .scope = scope });
            for (v.children) |child| try collectFocusablesInto(allocator, out, child, false, scope);
        },
        .hbox => |h| {
            if (h.focusable) try out.append(allocator, .{ .id = h.id, .kind = .action, .scope = scope });
            for (h.children) |child| try collectFocusablesInto(allocator, out, child, false, scope);
        },
        .styled_text => |t| {
            if (t.focusable) try out.append(allocator, .{ .id = t.id, .kind = .action, .scope = scope });
        },
        .text => |t| {
            if (t.focusable) try out.append(allocator, .{ .id = t.id, .kind = .action, .scope = scope });
        },
    }
}

fn scopeEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn findFocusableIndexById(focusables: []const Focusable, id: ?[]const u8) ?usize {
    const current = id orelse return null;
    for (focusables, 0..) |f, idx| {
        if (std.mem.eql(u8, f.id, current)) return idx;
    }
    return null;
}

fn cycleFocusInCandidates(focusables: []const Focusable, current: ?[]const u8, dir: isize) ?[]const u8 {
    if (focusables.len == 0) return null;

    const current_idx = findFocusableIndexById(focusables, current);
    if (current_idx == null) {
        return if (dir >= 0) focusables[0].id else focusables[focusables.len - 1].id;
    }

    const scope = focusables[current_idx.?].scope;
    if (dir >= 0) {
        for (1..focusables.len + 1) |step| {
            const idx = (current_idx.? + step) % focusables.len;
            if (scopeEql(focusables[idx].scope, scope)) return focusables[idx].id;
        }
    } else {
        for (1..focusables.len + 1) |step| {
            const wrapped = (current_idx.? + focusables.len - (step % focusables.len)) % focusables.len;
            if (scopeEql(focusables[wrapped].scope, scope)) return focusables[wrapped].id;
        }
    }
    return focusables[current_idx.?].id;
}

fn cycleFocusScopeInCandidates(focusables: []const Focusable, current: ?[]const u8, dir: isize) ?[]const u8 {
    if (focusables.len == 0) return null;

    const current_idx = findFocusableIndexById(focusables, current);
    if (current_idx == null) {
        return if (dir >= 0) focusables[0].id else focusables[focusables.len - 1].id;
    }

    const current_scope = focusables[current_idx.?].scope;
    if (dir >= 0) {
        for (1..focusables.len + 1) |step| {
            const idx = (current_idx.? + step) % focusables.len;
            if (!scopeEql(focusables[idx].scope, current_scope)) return focusables[idx].id;
        }
    } else {
        for (1..focusables.len + 1) |step| {
            const wrapped = (current_idx.? + focusables.len - (step % focusables.len)) % focusables.len;
            if (!scopeEql(focusables[wrapped].scope, current_scope)) return focusables[wrapped].id;
        }
    }
    return focusables[current_idx.?].id;
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

fn findTopmostModalLayer(root: protocol.Node) ?*const protocol.Node {
    var out: ?*const protocol.Node = null;
    findTopmostModalLayerInto(root, &out);
    return out;
}

pub fn treeHasHoverables(node: protocol.Node) bool {
    return hover.treeHasHoverables(node);
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

fn collectHitTestables(allocator: std.mem.Allocator, root: protocol.Node) !std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);
    try collectHitTestablesInto(allocator, &out, root);
    return out;
}

fn collectHitTestablesInto(allocator: std.mem.Allocator, out: *std.ArrayList([]const u8), node: protocol.Node) !void {
    const disabled = switch (node) {
        .vbox => |v| v.disabled,
        .hbox => |h| h.disabled,
        .box => |b| b.disabled,
        .scroll => |s| s.disabled,
        .overlay => |o| o.disabled,
        .text => |t| t.disabled,
        .styled_text => |t| t.disabled,
        .input => |i| i.disabled,
        .textarea => |t| t.disabled,
        .list => |l| l.disabled,
    };
    if (disabled) return;

    switch (node) {
        .input => |i| if (i.mouseable) try out.append(allocator, i.id),
        .textarea => |t| if (t.mouseable) try out.append(allocator, t.id),
        .list => |l| if (l.mouseable) try out.append(allocator, l.id),
        .text => |t| if (t.mouseable) try out.append(allocator, t.id),
        .styled_text => |t| if (t.mouseable) try out.append(allocator, t.id),
        .vbox => |v| {
            if (v.mouseable) try out.append(allocator, v.id);
            for (v.children) |child| try collectHitTestablesInto(allocator, out, child);
        },
        .hbox => |h| {
            if (h.mouseable) try out.append(allocator, h.id);
            for (h.children) |child| try collectHitTestablesInto(allocator, out, child);
        },
        .box => |b| {
            if (b.mouseable) try out.append(allocator, b.id);
            try collectHitTestablesInto(allocator, out, b.child.*);
        },
        .scroll => |s| {
            // Put scroll before its children so leaf focusables win when hit-testing "topmost".
            if (s.mouseable) try out.append(allocator, s.id);
            try collectHitTestablesInto(allocator, out, s.child.*);
        },
        .overlay => |o| {
            if (o.mouseable) try out.append(allocator, o.id);
            try collectHitTestablesInto(allocator, out, o.base.*);
            for (o.layers) |layer| {
                try collectHitTestablesInto(allocator, out, layer.node.*);
            }
        },
    }
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

pub fn hoverHitTest(
    allocator: std.mem.Allocator,
    widgets: []const WidgetEntry,
    root: protocol.Node,
    rows: usize,
    cols: usize,
    x: usize,
    y: usize,
) !HoverHit {
    if (!treeHasHoverables(root)) return .{ .id = null, .item = null };

    var scroll_states = try collectRenderScrollStates(allocator, widgets);
    defer scroll_states.deinit(allocator);

    var list_states = try collectHoverListStates(allocator, widgets);
    defer list_states.deinit(allocator);

    return try hover.hoverHitTestLeaky(
        allocator,
        root,
        rows,
        cols,
        x,
        y,
        scroll_states.items,
        list_states.items,
    );
}

fn updateHoverForCoords(
    allocator: std.mem.Allocator,
    log_sink: *log.LogSink,
    backend_in: anytype,
    widgets: []const WidgetEntry,
    hover_id_buf: *std.ArrayList(u8),
    hover_id: *?[]const u8,
    hover_item_buf: *std.ArrayList(u8),
    hover_item: *?[]const u8,
    root: protocol.Node,
    rows: usize,
    cols: usize,
    x: usize,
    y: usize,
) !bool {
    const hit = try hoverHitTest(allocator, widgets, root, rows, cols, x, y);
    if (optEql(hover_id.*, hit.id) and optEql(hover_item.*, hit.item)) return false;

    try setOptId(allocator, hover_id_buf, hover_id, hit.id);
    try setOptId(allocator, hover_item_buf, hover_item, hit.item);

    log.logPrint(
        log_sink,
        "EVENT_TX name=hover id={s} x={d} y={d} item={s}\n",
        .{ hover_id.* orelse "", x, y, hover_item.* orelse "" },
    );
    try protocol.writeHoverEventJsonl(backend_in, hover_id.* orelse "", x, y, hover_item.*);
    return true;
}

pub fn refreshHoverAfterPatch(
    allocator: std.mem.Allocator,
    log_sink: *log.LogSink,
    backend_in: anytype,
    widgets: []const WidgetEntry,
    hover_id_buf: *std.ArrayList(u8),
    hover_id: *?[]const u8,
    hover_item_buf: *std.ArrayList(u8),
    hover_item: *?[]const u8,
    root: protocol.Node,
    rows: usize,
    cols: usize,
    x_opt: ?usize,
    y_opt: ?usize,
) !bool {
    if (x_opt == null or y_opt == null) {
        if (hover_id.* == null and hover_item.* == null) return false;
        try setOptId(allocator, hover_id_buf, hover_id, null);
        try setOptId(allocator, hover_item_buf, hover_item, null);
        log.logPrint(log_sink, "EVENT_TX name=hover id= x=0 y=0 item=\n", .{});
        try protocol.writeHoverEventJsonl(backend_in, "", 0, 0, null);
        return true;
    }
    return try updateHoverForCoords(
        allocator,
        log_sink,
        backend_in,
        widgets,
        hover_id_buf,
        hover_id,
        hover_item_buf,
        hover_item,
        root,
        rows,
        cols,
        x_opt.?,
        y_opt.?,
    );
}

pub fn cycleFocusInTree(allocator: std.mem.Allocator, root: protocol.Node, current: ?[]const u8) !?[]const u8 {
    return cycleFocusInTreeDir(allocator, root, current, 1);
}

pub fn cycleFocusInTreeDir(
    allocator: std.mem.Allocator,
    root: protocol.Node,
    current: ?[]const u8,
    dir: isize,
) !?[]const u8 {
    if (findTopmostModalLayer(root)) |modal_ptr| {
        var modal_focusables = try collectFocusables(allocator, modal_ptr.*);
        defer modal_focusables.deinit(allocator);
        return cycleFocusInCandidates(modal_focusables.items, current, dir);
    }

    var focusables = try collectFocusables(allocator, root);
    defer focusables.deinit(allocator);
    return cycleFocusInCandidates(focusables.items, current, dir);
}

pub fn cycleFocusScopeInTreeDir(
    allocator: std.mem.Allocator,
    root: protocol.Node,
    current: ?[]const u8,
    dir: isize,
) !?[]const u8 {
    if (findTopmostModalLayer(root)) |modal_ptr| {
        var modal_focusables = try collectFocusables(allocator, modal_ptr.*);
        defer modal_focusables.deinit(allocator);
        return cycleFocusScopeInCandidates(modal_focusables.items, current, dir);
    }

    var focusables = try collectFocusables(allocator, root);
    defer focusables.deinit(allocator);
    return cycleFocusScopeInCandidates(focusables.items, current, dir);
}

pub fn focusedKindInTree(allocator: std.mem.Allocator, root: protocol.Node, id: []const u8) !?FocusKind {
    var focusables = try collectFocusables(allocator, root);
    defer focusables.deinit(allocator);
    for (focusables.items) |f| {
        if (std.mem.eql(u8, f.id, id)) return f.kind;
    }
    return null;
}

pub fn nodeReadonlyInTree(root: protocol.Node, id: []const u8) bool {
    var out: bool = false;
    _ = nodeReadonlyInTreeInto(root, id, &out);
    return out;
}

fn nodeReadonlyInTreeInto(node: protocol.Node, id: []const u8, out: *bool) bool {
    if (std.mem.eql(u8, node_util.nodeId(node), id)) {
        out.* = switch (node) {
            .vbox => |v| v.readonly,
            .hbox => |h| h.readonly,
            .box => |b| b.readonly,
            .scroll => |s| s.readonly,
            .overlay => |o| o.readonly,
            .text => |t| t.readonly,
            .styled_text => |t| t.readonly,
            .input => |i| i.readonly,
            .textarea => |t| t.readonly,
            .list => |l| l.readonly,
        };
        return true;
    }

    switch (node) {
        .vbox => |v| for (v.children) |child| if (nodeReadonlyInTreeInto(child, id, out)) return true,
        .hbox => |h| for (h.children) |child| if (nodeReadonlyInTreeInto(child, id, out)) return true,
        .box => |b| return nodeReadonlyInTreeInto(b.child.*, id, out),
        .scroll => |s| return nodeReadonlyInTreeInto(s.child.*, id, out),
        .overlay => |o| {
            if (nodeReadonlyInTreeInto(o.base.*, id, out)) return true;
            for (o.layers) |layer| {
                if (nodeReadonlyInTreeInto(layer.node.*, id, out)) return true;
            }
            return false;
        },
        .list => |l| for (l.children) |child| if (nodeReadonlyInTreeInto(child, id, out)) return true,
        else => return false,
    }

    return false;
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
    rows: usize,
    cols: usize,
) !void {
    const before_focus = focused_id.*; // pointer-backed slice; compare via optEql below

    var focusables = try collectFocusables(allocator, root);
    defer focusables.deinit(allocator);

    pruneWidgetsNotInFocusables(allocator, widgets, focusables.items);
    try ensureWidgetsForFocusables(allocator, widgets, focusables.items);

    if (findTopmostModalLayer(root)) |modal_ptr| {
        var modal_focusables = try collectFocusables(allocator, modal_ptr.*);
        defer modal_focusables.deinit(allocator);

        if (modal_focusables.items.len > 0) {
            const fid = focused_id.* orelse "";
            const in_modal = focused_id.* != null and treeContainsId(modal_ptr.*, focused_id.*.?);
            if (!in_modal) {
                try setFocusId(allocator, focused_id_buf, focused_id, modal_focusables.items[0].id);
                auto_focus_done.* = true;
                log.logPrint(log_sink, "EVENT_TX name=focus id={s}\n", .{focused_id.* orelse ""});
                try protocol.writeFocusEventJsonl(backend_in, focused_id.* orelse "");
            } else if (focused_id.* != null and !focusablesContainsId(modal_focusables.items, fid)) {
                try setFocusId(allocator, focused_id_buf, focused_id, modal_focusables.items[0].id);
                auto_focus_done.* = true;
                log.logPrint(log_sink, "EVENT_TX name=focus id={s}\n", .{focused_id.* orelse ""});
                try protocol.writeFocusEventJsonl(backend_in, focused_id.* orelse "");
            }
        }
    } else {
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
    }

    for (focusables.items) |f| {
        if (f.kind != .list) continue;
        try syncListForId(allocator, log_sink, backend_in, widgets, root, f.id);
    }

    for (focusables.items) |f| {
        if (f.kind != .scroll) continue;
        syncScrollForId(widgets, root, rows, cols, f.id);
    }

    if (!optEql(before_focus, focused_id.*)) {
        if (focused_id.*) |fid| {
            _ = try ensureVisibleForFocusImpl(allocator, log_sink, backend_in, widgets, root, rows, cols, fid);
        }
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

fn collectRenderScrollStates(allocator: std.mem.Allocator, widgets: []const WidgetEntry) !std.ArrayList(render.ScrollState) {
    var out: std.ArrayList(render.ScrollState) = .empty;
    errdefer out.deinit(allocator);
    for (widgets) |w| {
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

fn collectHoverListStates(allocator: std.mem.Allocator, widgets: []const WidgetEntry) !std.ArrayList(render.ListState) {
    var out: std.ArrayList(render.ListState) = .empty;
    errdefer out.deinit(allocator);
    for (widgets) |w| {
        if (w.state != .list) continue;
        const st = w.state.list;
        try out.append(allocator, .{
            .id = w.id.items,
            .selected_id = st.selected_id.items,
            .scroll = st.scroll,
        });
    }
    return out;
}

fn listVisibleHeight(rect: render.Rect, l: protocol.ListNode) usize {
    const desired = l.height orelse rect.h;
    return @min(desired, rect.h);
}

fn findSelectedIndexInList(l: protocol.ListNode, selected_id: []const u8) ?usize {
    if (selected_id.len == 0) return null;
    for (l.children, 0..) |child, idx| {
        if (std.mem.eql(u8, node_util.nodeId(child), selected_id)) return idx;
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
    hover_id_buf: *std.ArrayList(u8),
    hover_id: *?[]const u8,
    hover_item_buf: *std.ArrayList(u8),
    hover_item: *?[]const u8,
    root: protocol.Node,
    rows: usize,
    cols: usize,
    ev: mouse.MouseEvent,
) !bool {
    var changed: bool = false;
    switch (ev.kind) {
        .down => {
            if (ev.button == .left) {
                changed = try handleMouseDownLeft(
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
                );
            }
        },
        .wheel => {
            // Local wheel scrolling is strict opt-in via `mouseable:true`.
            if (ev.wheel_dy != 0) {
                changed = try handleMouseWheel(
                    allocator,
                    log_sink,
                    backend_in,
                    widgets,
                    root,
                    rows,
                    cols,
                    ev.x,
                    ev.y,
                    ev.wheel_dy,
                );
            }
        },
        .move, .up => {},
    }
    if (treeHasHoverables(root)) {
        // Only flush on hover changes; motion tracking makes `.move` events frequent.
        if (try updateHoverForCoords(
            allocator,
            log_sink,
            backend_in,
            widgets.items,
            hover_id_buf,
            hover_id,
            hover_item_buf,
            hover_item,
            root,
            rows,
            cols,
            ev.x,
            ev.y,
        )) try backend_in.flush();
    } else {
        if (hover_id.* != null or hover_item.* != null) {
            try setOptId(allocator, hover_id_buf, hover_id, null);
            try setOptId(allocator, hover_item_buf, hover_item, null);
            log.logPrint(log_sink, "EVENT_TX name=hover id= x={d} y={d} item=\n", .{ ev.x, ev.y });
            try protocol.writeHoverEventJsonl(backend_in, "", ev.x, ev.y, null);
            try backend_in.flush();
        }
    }
    return changed;
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
    var scroll_states = try collectRenderScrollStates(allocator, widgets.items);
    defer scroll_states.deinit(allocator);

    const hit_root: protocol.Node = if (findTopmostModalLayer(root)) |modal_ptr| modal_ptr.* else root;
    var ids = try collectHitTestables(allocator, hit_root);
    defer ids.deinit(allocator);

    var hit_id: ?[]const u8 = null;
    var hit_rect: render.Rect = undefined;

    for (ids.items) |id| {
        const r = render.findRectForIdWithScrolls(root, rows, cols, id, scroll_states.items) orelse continue;
        if (rectContains(r, x, y)) {
            hit_id = id;
            hit_rect = r;
        }
    }

    const id = hit_id orelse return false;
    const idx = findWidgetIndex(widgets.items, id) orelse return false;

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
        .textarea => |*st| {
            const before_cursor = st.cursor;
            const before_scroll_y = st.scroll_y;
            st.cursor = st.value.items.len;
            if (st.cursor > st.value.items.len) st.cursor = st.value.items.len;

            const cursor_y = textareaCursorVisualY(st.value.items, st.cursor, hit_rect.w);
            const content_h = textareaVisualLines(st.value.items, hit_rect.w);
            st.scroll_y = state.scrollIntoView(st.scroll_y, hit_rect.h, cursor_y, cursor_y + 1, content_h);
            if (st.cursor != before_cursor or st.scroll_y != before_scroll_y) changed = true;
        },
        .list => |*st| {
            const l = node_util.findListNodeById(root, id) orelse {
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

            const next_id = node_util.nodeId(l.children[item_idx]);
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
            } else {
                // Clicking an already-selected row acts as activation (helps "button-like" lists).
                log.logPrint(log_sink, "EVENT_TX name=activate id={s} item={s}\n", .{ id, next_id });
                try protocol.writeActivateEventJsonl(backend_in, id, next_id);
                need_flush = true;
                changed = true;
            }

            const selected_index = findSelectedIndexInList(l, st.selected_id.items);
            const before_scroll = st.scroll;
            st.scroll = state.clampListScroll(st.scroll, selected_index, visible_height, l.children.len);
            if (st.scroll != before_scroll) changed = true;
        },
        .scroll => {},
        .action => {
            try activateActionForId(log_sink, backend_in, id);
            need_flush = true;
            changed = true;
        },
    }

    if (need_flush) try backend_in.flush();
    return changed;
}

fn handleMouseWheel(
    allocator: std.mem.Allocator,
    log_sink: *log.LogSink,
    backend_in: anytype,
    widgets: *std.ArrayList(WidgetEntry),
    root: protocol.Node,
    rows: usize,
    cols: usize,
    x: usize,
    y: usize,
    delta: isize,
) !bool {
    var scroll_states = try collectRenderScrollStates(allocator, widgets.items);
    defer scroll_states.deinit(allocator);

    const hit_root: protocol.Node = if (findTopmostModalLayer(root)) |modal_ptr| modal_ptr.* else root;
    var ids = try collectHitTestables(allocator, hit_root);
    defer ids.deinit(allocator);

    // Wheel priority:
    // 1) Topmost list under pointer (local scroll)
    // 2) Topmost/deepest scroll viewport under pointer
    var list_hit: ?[]const u8 = null;
    var list_hit_rect: render.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    for (ids.items) |id| {
        const widx = findWidgetIndex(widgets.items, id) orelse continue;
        if (widgets.items[widx].state != .list) continue;

        const r = render.findRectForIdWithScrolls(root, rows, cols, id, scroll_states.items) orelse continue;
        if (!rectContains(r, x, y)) continue;
        list_hit = id;
        list_hit_rect = r;
    }

    if (list_hit) |list_id| {
        const widx = findWidgetIndex(widgets.items, list_id) orelse return false;
        const l = node_util.findListNodeById(root, list_id) orelse return false;
        const visible_height = listVisibleHeight(list_hit_rect, l);
        if (visible_height == 0) return false;

        const stw = &widgets.items[widx].state.list;
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

    const step: usize = 3;
    const dir: isize = if (delta > 0) 1 else if (delta < 0) -1 else 0;
    if (dir == 0) return false;

    var scroll_hit: ?[]const u8 = null;
    for (ids.items) |id| {
        const widx = findWidgetIndex(widgets.items, id) orelse continue;
        if (widgets.items[widx].state != .scroll) continue;

        const r = render.findRectForIdWithScrolls(root, rows, cols, id, scroll_states.items) orelse continue;
        if (!rectContains(r, x, y)) continue;
        scroll_hit = id;
    }

    if (scroll_hit) |scroll_id| {
        return try scrollViewportById(
            allocator,
            log_sink,
            backend_in,
            widgets,
            root,
            rows,
            cols,
            scroll_id,
            dir * @as(isize, @intCast(step)),
        );
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
        .textarea => |*s| s.value.deinit(allocator),
        .list => |*s| s.selected_id.deinit(allocator),
        .scroll => {},
        .action => {},
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
            .scroll => if (kind == .scroll) return idx else {},
            .textarea => if (kind == .textarea) return idx else {},
            .action => if (kind == .action) return idx else {},
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
        .textarea => |*s| s.value.deinit(allocator),
        .list => |*s| s.selected_id.deinit(allocator),
        .scroll => {},
        .action => {},
    }
}

fn initWidgetState(kind: FocusKind) WidgetState {
    return switch (kind) {
        .input => .{ .input = .{} },
        .list => .{ .list = .{} },
        .scroll => .{ .scroll = .{} },
        .textarea => .{ .textarea = .{} },
        .action => .{ .action = .{} },
    };
}

fn findWidgetIndex(widgets: []const WidgetEntry, id: []const u8) ?usize {
    for (widgets, 0..) |e, idx| {
        if (std.mem.eql(u8, e.id.items, id)) return idx;
    }
    return null;
}

fn clampScrollState(st: anytype) void {
    st.scroll_y = state.clampScrollY(st.scroll_y, st.viewport_h, st.content_h);
}

fn syncScrollForId(widgets: *std.ArrayList(WidgetEntry), root: protocol.Node, rows: usize, cols: usize, scroll_id: []const u8) void {
    const s = node_util.findScrollNodeById(root, scroll_id) orelse return;
    const idx = findWidgetIndex(widgets.items, scroll_id) orelse return;
    var st = &widgets.items[idx].state.scroll;

    const r = render.findRectForIdWithScrolls(root, rows, cols, scroll_id, &.{}) orelse return;
    const inner_w: usize = if (r.w > s.pad * 2) r.w - s.pad * 2 else 0;
    const inner_h: usize = if (r.h > s.pad * 2) r.h - s.pad * 2 else 0;

    st.viewport_h = inner_h;
    st.content_h = render.measureContentHeight(s.child.*, inner_w);
    clampScrollState(st);
}

fn scrollViewportById(
    allocator: std.mem.Allocator,
    log_sink: *log.LogSink,
    backend_in: anytype,
    widgets: *std.ArrayList(WidgetEntry),
    root: protocol.Node,
    rows: usize,
    cols: usize,
    scroll_id: []const u8,
    delta_rows: isize,
) !bool {
    const s = node_util.findScrollNodeById(root, scroll_id) orelse return false;
    const idx = try ensureWidgetKind(allocator, widgets, scroll_id, .scroll);
    var st = &widgets.items[idx].state.scroll;

    syncScrollForId(widgets, root, rows, cols, scroll_id);

    const before = st.scroll_y;
    if (delta_rows > 0) {
        const add: usize = @as(usize, @intCast(delta_rows));
        st.scroll_y = st.scroll_y + add;
    } else if (delta_rows < 0) {
        const sub: usize = @as(usize, @intCast(-delta_rows));
        st.scroll_y = if (st.scroll_y > sub) st.scroll_y - sub else 0;
    }
    clampScrollState(st);

    if (st.scroll_y == before) return false;
    log.logPrint(
        log_sink,
        "SCROLL_SET id={s} scroll_y={d} content_h={d} viewport_h={d}\n",
        .{ s.id, st.scroll_y, st.content_h, st.viewport_h },
    );
    try protocol.writeScrollEventJsonl(backend_in, s.id, st.scroll_y);
    return true;
}

pub fn ensureVisibleForFocusId(
    allocator: std.mem.Allocator,
    log_sink: *log.LogSink,
    backend_in: anytype,
    widgets: *std.ArrayList(WidgetEntry),
    root: protocol.Node,
    rows: usize,
    cols: usize,
    focus_id: []const u8,
) !bool {
    return ensureVisibleForFocusImpl(allocator, log_sink, backend_in, widgets, root, rows, cols, focus_id);
}

fn ensureVisibleForFocusImpl(
    allocator: std.mem.Allocator,
    log_sink: *log.LogSink,
    backend_in: anytype,
    widgets: *std.ArrayList(WidgetEntry),
    root: protocol.Node,
    rows: usize,
    cols: usize,
    focus_id: []const u8,
) !bool {
    const nearest = findNearestScrollAncestor(root, focus_id) orelse return false;
    const s = node_util.findScrollNodeById(root, nearest) orelse return false;
    const idx = try ensureWidgetKind(allocator, widgets, nearest, .scroll);
    var st = &widgets.items[idx].state.scroll;

    syncScrollForId(widgets, root, rows, cols, nearest);

    const r = render.findRectForIdWithScrolls(root, rows, cols, nearest, &.{}) orelse return false;
    const inner_w: usize = if (r.w > s.pad * 2) r.w - s.pad * 2 else 0;
    const range = render.findContentYRangeForId(s.child.*, inner_w, focus_id) orelse return false;

    const y0 = range.y;
    const y1 = range.y + range.h;

    const before = st.scroll_y;
    st.scroll_y = state.scrollIntoView(st.scroll_y, st.viewport_h, y0, y1, st.content_h);

    if (st.scroll_y == before) return false;
    log.logPrint(
        log_sink,
        "SCROLL_INTO_VIEW viewport={s} focus={s} scroll_y={d} y0={d} y1={d} viewport_h={d}\n",
        .{ nearest, focus_id, st.scroll_y, y0, y1, st.viewport_h },
    );
    try protocol.writeScrollEventJsonl(backend_in, nearest, st.scroll_y);
    return true;
}

fn findNearestScrollAncestor(root: protocol.Node, target_id: []const u8) ?[]const u8 {
    var out: ?[]const u8 = null;
    _ = findNearestScrollAncestorInto(root, target_id, &out);
    return out;
}

fn findNearestScrollAncestorInto(node: protocol.Node, target_id: []const u8, out: *?[]const u8) bool {
    if (std.mem.eql(u8, node_util.nodeId(node), target_id)) return true;

    switch (node) {
        .scroll => |s| {
            if (findNearestScrollAncestorInto(s.child.*, target_id, out)) {
                if (out.* == null) out.* = s.id;
                return true;
            }
            return false;
        },
        .box => |b| {
            return findNearestScrollAncestorInto(b.child.*, target_id, out);
        },
        .overlay => |o| {
            if (findNearestScrollAncestorInto(o.base.*, target_id, out)) return true;
            for (o.layers) |layer| {
                if (findNearestScrollAncestorInto(layer.node.*, target_id, out)) return true;
            }
            return false;
        },
        .vbox => |v| {
            for (v.children) |child| {
                if (findNearestScrollAncestorInto(child, target_id, out)) return true;
            }
            return false;
        },
        .hbox => |h| {
            for (h.children) |child| {
                if (findNearestScrollAncestorInto(child, target_id, out)) return true;
            }
            return false;
        },
        .list => |l| {
            for (l.children) |child| {
                if (findNearestScrollAncestorInto(child, target_id, out)) return true;
            }
            return false;
        },
        else => return false,
    }
}

fn syncListForId(
    allocator: std.mem.Allocator,
    log_sink: *log.LogSink,
    backend_in: anytype,
    widgets: *std.ArrayList(WidgetEntry),
    root: protocol.Node,
    list_id: []const u8,
) !void {
    const l = node_util.findListNodeById(root, list_id) orelse return;
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
            if (std.mem.eql(u8, node_util.nodeId(child), st.selected_id.items)) {
                selected_index = child_idx;
                break;
            }
        }
    }

    var selection_changed = false;
    if (selected_index == null) {
        const new_id = node_util.nodeId(l.children[0]);
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
    const l = node_util.findListNodeById(root, list_id) orelse return false;
    if (l.children.len == 0) return false;

    const idx = try ensureWidgetKind(allocator, widgets, list_id, .list);
    var st = &widgets.items[idx].state.list;

    var current_idx: usize = 0;
    if (st.selected_id.items.len > 0) {
        for (l.children, 0..) |child, child_idx| {
            if (std.mem.eql(u8, node_util.nodeId(child), st.selected_id.items)) {
                current_idx = child_idx;
                break;
            }
        }
    }

    const len: isize = @as(isize, @intCast(l.children.len));
    const next_idx_signed = @min(@max(@as(isize, @intCast(current_idx)) + delta, 0), len - 1);
    const next_idx: usize = @as(usize, @intCast(next_idx_signed));
    const next_id = node_util.nodeId(l.children[next_idx]);
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

fn mapListKeyToAction(ev: keys.KeyEvent) ?protocol.KeyAction {
    if (ev.mods.ctrl or ev.mods.alt or ev.mods.shift) return null;
    return switch (ev.key) {
        .named => |k| switch (k) {
            .up => .list_prev,
            .down => .list_next,
            .enter => .list_activate,
            else => null,
        },
        .text => |s| blk: {
            if (s.len != 1) break :blk null;
            if (s[0] == 'k') break :blk .list_prev;
            if (s[0] == 'j') break :blk .list_next;
            break :blk null;
        },
        else => null,
    };
}

pub fn applyListAction(
    allocator: std.mem.Allocator,
    log_sink: *log.LogSink,
    backend_in: anytype,
    widgets: *std.ArrayList(WidgetEntry),
    root: protocol.Node,
    rows: usize,
    cols: usize,
    list_id: []const u8,
    action: protocol.KeyAction,
) !bool {
    switch (action) {
        .list_activate => {
            try activateListForId(log_sink, backend_in, widgets.items, list_id);
            return true;
        },
        .list_prev, .list_next => {},
        else => return false,
    }

    const delta: isize = if (action == .list_prev) -1 else 1;
    const changed = try moveListSelectionForId(allocator, log_sink, backend_in, widgets, root, list_id, delta);

    const l = node_util.findListNodeById(root, list_id) orelse return changed;
    var scroll_states = try collectRenderScrollStates(allocator, widgets.items);
    defer scroll_states.deinit(allocator);
    const rect = render.findRectForIdWithScrolls(root, rows, cols, list_id, scroll_states.items) orelse return changed;
    const visible_height = listVisibleHeight(rect, l);
    if (visible_height == 0) return changed;

    const widx = findWidgetIndex(widgets.items, list_id) orelse return changed;
    if (widgets.items[widx].state != .list) return changed;
    const stw = &widgets.items[widx].state.list;
    const selected_index = findSelectedIndexInList(l, stw.selected_id.items);
    const before_scroll = stw.scroll;
    stw.scroll = state.clampListScroll(stw.scroll, selected_index, visible_height, l.children.len);
    return changed or (stw.scroll != before_scroll);
}

pub fn handleFocusedListKey(
    allocator: std.mem.Allocator,
    log_sink: *log.LogSink,
    backend_in: anytype,
    widgets: *std.ArrayList(WidgetEntry),
    root: protocol.Node,
    rows: usize,
    cols: usize,
    list_id: []const u8,
    ev: keys.KeyEvent,
) !bool {
    const action = mapListKeyToAction(ev) orelse return false;
    return applyListAction(allocator, log_sink, backend_in, widgets, root, rows, cols, list_id, action);
}

pub fn activateActionForId(log_sink: *log.LogSink, backend_in: anytype, id: []const u8) !void {
    log.logPrint(log_sink, "EVENT_TX name=activate id={s} item=\n", .{id});
    try protocol.writeActivateEventJsonl(backend_in, id, "");
}

pub fn applyActionWidgetAction(
    log_sink: *log.LogSink,
    backend_in: anytype,
    id: []const u8,
    action: protocol.KeyAction,
) !bool {
    if (action != .action_activate) return false;
    try activateActionForId(log_sink, backend_in, id);
    return true;
}

pub fn handleFocusedInputKey(
    allocator: std.mem.Allocator,
    widgets: *std.ArrayList(WidgetEntry),
    input_id: []const u8,
    ev: keys.KeyEvent,
    readonly: bool,
    visible_cols: usize,
) !bool {
    const action_opt = mapInputKeyToAction(ev);
    if (action_opt) |action| {
        return applyInputAction(allocator, widgets, input_id, action, readonly, visible_cols);
    }

    const s = switch (ev.key) {
        .text => |txt| txt,
        else => return false,
    };
    if (ev.mods.ctrl or ev.mods.shift or ev.mods.alt) return false;
    if (s.len == 0) return false;

    const max_input_bytes: usize = 16 * 1024;
    const idx = try ensureWidgetKind(allocator, widgets, input_id, .input);
    var st = &widgets.items[idx].state.input;
    if (readonly) return false;

    if (st.value.items.len + s.len > max_input_bytes) return false;
    var changed: bool = false;
    if (s.len == 1 and s[0] < 0x80) {
        changed = try input.handleInputByte(allocator, &st.value, &st.cursor, s[0]);
    } else {
        changed = try input.insertUtf8Bytes(allocator, &st.value, &st.cursor, s);
    }

    if (st.cursor > st.value.items.len) st.cursor = st.value.items.len;
    if (st.scroll_x > st.value.items.len) st.scroll_x = st.value.items.len;
    const scroll_changed = input.ensure_cursor_visible(&st.scroll_x, st.cursor, st.value.items, visible_cols);
    return changed or scroll_changed;
}

fn mapInputKeyToAction(ev: keys.KeyEvent) ?protocol.KeyAction {
    return switch (ev.key) {
        .text => |s| blk: {
            if (ev.mods.ctrl or ev.mods.shift) break :blk null;
            if (ev.mods.alt and s.len == 1) {
                if (s[0] == 'b') break :blk .input_word_left;
                if (s[0] == 'f') break :blk .input_word_right;
            }
            break :blk null;
        },
        .named => |k| switch (k) {
            .left => if (ev.mods.alt and !ev.mods.ctrl and !ev.mods.shift) .input_word_left else if (!ev.mods.ctrl and !ev.mods.shift) .input_left else null,
            .right => if (ev.mods.alt and !ev.mods.ctrl and !ev.mods.shift) .input_word_right else if (!ev.mods.ctrl and !ev.mods.shift) .input_right else null,
            .home => if (!ev.mods.ctrl and !ev.mods.shift and !ev.mods.alt) .input_home else null,
            .end => if (!ev.mods.ctrl and !ev.mods.shift and !ev.mods.alt) .input_end else null,
            .delete => if (!ev.mods.ctrl and !ev.mods.shift and !ev.mods.alt) .input_delete else null,
            .backspace => if (!ev.mods.ctrl and !ev.mods.shift and !ev.mods.alt) .input_backspace else null,
            else => null,
        },
        else => null,
    };
}

pub fn applyInputAction(
    allocator: std.mem.Allocator,
    widgets: *std.ArrayList(WidgetEntry),
    input_id: []const u8,
    action: protocol.KeyAction,
    readonly: bool,
    visible_cols: usize,
) !bool {
    const idx = try ensureWidgetKind(allocator, widgets, input_id, .input);
    var st = &widgets.items[idx].state.input;

    const before_cursor: usize = st.cursor;
    const before_len: usize = st.value.items.len;
    const before_scroll: usize = st.scroll_x;

    var changed: bool = false;
    switch (action) {
        .input_left => {
            const next = unicode.prevGraphemeBoundary(st.value.items, st.cursor);
            if (next != st.cursor) {
                st.cursor = next;
                changed = true;
            }
        },
        .input_right => {
            const next = unicode.nextGraphemeBoundary(st.value.items, st.cursor);
            if (next != st.cursor) {
                st.cursor = next;
                changed = true;
            }
        },
        .input_word_left => {
            const next = input.word_left(st.value.items, st.cursor);
            const clamped = unicode.clampGraphemeBoundary(st.value.items, next);
            if (clamped != st.cursor) {
                st.cursor = clamped;
                changed = true;
            }
        },
        .input_word_right => {
            const next = input.word_right(st.value.items, st.cursor);
            const clamped = unicode.clampGraphemeBoundary(st.value.items, next);
            if (clamped != st.cursor) {
                st.cursor = clamped;
                changed = true;
            }
        },
        .input_home => if (st.cursor != 0) {
            st.cursor = 0;
            changed = true;
        },
        .input_end => if (st.cursor != st.value.items.len) {
            st.cursor = st.value.items.len;
            changed = true;
        },
        .input_delete => {
            if (readonly) return false;
            changed = input.delete_at_cursor(&st.value, &st.cursor);
        },
        .input_backspace => {
            if (readonly) return false;
            if (st.cursor != 0) {
                changed = try input.handleInputByte(allocator, &st.value, &st.cursor, 127);
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

pub fn handleFocusedInputPaste(
    allocator: std.mem.Allocator,
    widgets: *std.ArrayList(WidgetEntry),
    input_id: []const u8,
    payload: []const u8,
    readonly: bool,
    visible_cols: usize,
) !bool {
    const max_input_bytes: usize = 16 * 1024;
    if (readonly) return false;
    const idx = try ensureWidgetKind(allocator, widgets, input_id, .input);
    var st = &widgets.items[idx].state.input;

    const before_cursor: usize = st.cursor;
    const before_len: usize = st.value.items.len;
    const before_scroll: usize = st.scroll_x;

    var sanitized: std.ArrayList(u8) = .empty;
    defer sanitized.deinit(allocator);
    try sanitized.ensureTotalCapacity(allocator, @min(payload.len, 4096));

    var i: usize = 0;
    while (i < payload.len) {
        if (st.value.items.len + sanitized.items.len >= max_input_bytes) break;

        const b = payload[i];
        if (b == '\r' or b == '\n' or b == '\t' or b < 0x20 or b == 0x7f) {
            try sanitized.append(allocator, ' ');
            i += 1;
            continue;
        }

        if (b < 0x80) {
            try sanitized.append(allocator, b);
            i += 1;
            continue;
        }

        const expect = std.unicode.utf8ByteSequenceLength(b) catch {
            i += 1;
            continue;
        };
        if (expect <= 1 or expect > 4) {
            i += 1;
            continue;
        }
        const n: usize = @as(usize, @intCast(expect));
        if (i + n > payload.len) break;

        const slice = payload[i .. i + n];
        _ = std.unicode.utf8Decode(slice) catch {
            i += 1;
            continue;
        };
        if (st.value.items.len + sanitized.items.len + slice.len > max_input_bytes) break;
        try sanitized.appendSlice(allocator, slice);
        i += n;
    }

    if (sanitized.items.len == 0) return false;

    if (st.cursor > st.value.items.len) st.cursor = st.value.items.len;
    st.cursor = unicode.clampGraphemeBoundary(st.value.items, st.cursor);

    if (st.cursor == st.value.items.len) {
        try st.value.appendSlice(allocator, sanitized.items);
    } else {
        try st.value.insertSlice(allocator, st.cursor, sanitized.items);
    }
    st.cursor += sanitized.items.len;

    if (st.cursor > st.value.items.len) st.cursor = st.value.items.len;
    if (st.scroll_x > st.value.items.len) st.scroll_x = st.value.items.len;
    const scroll_changed = input.ensure_cursor_visible(&st.scroll_x, st.cursor, st.value.items, visible_cols);

    const changed = before_cursor != st.cursor or before_len != st.value.items.len or before_scroll != st.scroll_x;
    return changed or scroll_changed;
}

const VisualPos = struct {
    y: usize,
    x: usize,
};

fn textareaCursorVisualPos(value: []const u8, cursor: usize, cols: usize) VisualPos {
    const effective_cursor = unicode.clampGraphemeBoundary(value, @min(cursor, value.len));
    if (effective_cursor == 0) return .{ .y = 0, .x = 0 };

    var byte_idx: usize = 0;
    var y: usize = 0;
    var x: usize = 0;

    while (byte_idx < effective_cursor) {
        const g = unicode.nextGrapheme(value, byte_idx);
        if (g.end <= byte_idx) break;

        const b0: u8 = value[g.start];
        if (b0 == '\r') {
            byte_idx = g.end;
            continue;
        }
        if (b0 == '\n') {
            y += 1;
            x = 0;
            byte_idx = g.end;
            continue;
        }

        var width: usize = g.width;
        if (b0 == '\t') width = 1;
        if (width == 0) {
            byte_idx = g.end;
            continue;
        }

        if (cols == 0) {
            byte_idx = g.end;
            continue;
        }

        if (width > cols) {
            byte_idx = g.end;
            continue;
        }

        if (x + width > cols) {
            y += 1;
            x = 0;
            continue;
        }

        x += width;
        byte_idx = g.end;
    }

    return .{ .y = y, .x = x };
}

fn textareaByteIndexForVisualPos(value: []const u8, target_y: usize, target_x: usize, cols: usize) usize {
    var byte_idx: usize = 0;
    var y: usize = 0;
    var x: usize = 0;

    var found: bool = false;
    var best_byte: usize = 0;
    var best_x: usize = 0;

    while (true) {
        if (y == target_y) {
            if (!found) {
                found = true;
                best_byte = byte_idx;
                best_x = x;
            } else if (x <= target_x and x >= best_x) {
                best_byte = byte_idx;
                best_x = x;
            }
        }

        if (byte_idx >= value.len) break;

        const g = unicode.nextGrapheme(value, byte_idx);
        if (g.end <= byte_idx) break;

        const b0: u8 = value[g.start];
        if (b0 == '\r') {
            byte_idx = g.end;
            continue;
        }
        if (b0 == '\n') {
            y += 1;
            x = 0;
            byte_idx = g.end;
            continue;
        }

        var width: usize = g.width;
        if (b0 == '\t') width = 1;
        if (width == 0) {
            byte_idx = g.end;
            continue;
        }

        if (cols == 0) {
            byte_idx = g.end;
            continue;
        }

        if (width > cols) {
            byte_idx = g.end;
            continue;
        }

        if (x + width > cols) {
            y += 1;
            x = 0;
            continue;
        }

        x += width;
        byte_idx = g.end;
    }

    if (!found) return @min(value.len, unicode.clampGraphemeBoundary(value, value.len));
    return unicode.clampGraphemeBoundary(value, best_byte);
}

pub fn handleFocusedTextareaKey(
    allocator: std.mem.Allocator,
    widgets: *std.ArrayList(WidgetEntry),
    textarea_id: []const u8,
    ev: keys.KeyEvent,
    readonly: bool,
    visible_rows: usize,
    visible_cols: usize,
) !bool {
    const action_opt = mapTextareaKeyToAction(ev);
    if (action_opt) |action| {
        return applyTextareaAction(allocator, widgets, textarea_id, action, readonly, visible_rows, visible_cols);
    }

    const s = switch (ev.key) {
        .text => |txt| txt,
        else => return false,
    };
    if (ev.mods.ctrl or ev.mods.shift or ev.mods.alt) return false;
    if (s.len == 0) return false;

    const max_textarea_bytes: usize = 64 * 1024;
    const idx = try ensureWidgetKind(allocator, widgets, textarea_id, .textarea);
    var st = &widgets.items[idx].state.textarea;
    if (readonly) return false;

    if (st.value.items.len + s.len > max_textarea_bytes) return false;
    var changed: bool = false;
    if (s.len == 1 and s[0] < 0x80) {
        changed = try input.handleInputByte(allocator, &st.value, &st.cursor, s[0]);
    } else {
        changed = try input.insertUtf8Bytes(allocator, &st.value, &st.cursor, s);
    }

    if (st.cursor > st.value.items.len) st.cursor = st.value.items.len;
    const cursor_y = textareaCursorVisualY(st.value.items, st.cursor, visible_cols);
    const content_h = textareaVisualLines(st.value.items, visible_cols);
    const next_scroll_y = state.scrollIntoView(st.scroll_y, visible_rows, cursor_y, cursor_y + 1, content_h);
    const scroll_changed = next_scroll_y != st.scroll_y;
    st.scroll_y = next_scroll_y;
    return changed or scroll_changed;
}

fn mapTextareaKeyToAction(ev: keys.KeyEvent) ?protocol.KeyAction {
    return switch (ev.key) {
        .text => |s| blk: {
            if (ev.mods.ctrl or ev.mods.shift) break :blk null;
            if (ev.mods.alt and s.len == 1) {
                if (s[0] == 'b') break :blk .textarea_word_left;
                if (s[0] == 'f') break :blk .textarea_word_right;
            }
            break :blk null;
        },
        .named => |k| switch (k) {
            .left => if (ev.mods.alt and !ev.mods.ctrl and !ev.mods.shift) .textarea_word_left else if (!ev.mods.ctrl and !ev.mods.shift) .textarea_left else null,
            .right => if (ev.mods.alt and !ev.mods.ctrl and !ev.mods.shift) .textarea_word_right else if (!ev.mods.ctrl and !ev.mods.shift) .textarea_right else null,
            .up => if (!ev.mods.ctrl and !ev.mods.shift and !ev.mods.alt) .textarea_up else null,
            .down => if (!ev.mods.ctrl and !ev.mods.shift and !ev.mods.alt) .textarea_down else null,
            .home => if (!ev.mods.ctrl and !ev.mods.shift and !ev.mods.alt) .textarea_home else null,
            .end => if (!ev.mods.ctrl and !ev.mods.shift and !ev.mods.alt) .textarea_end else null,
            .page_up => if (!ev.mods.ctrl and !ev.mods.shift and !ev.mods.alt) .textarea_page_up else null,
            .page_down => if (!ev.mods.ctrl and !ev.mods.shift and !ev.mods.alt) .textarea_page_down else null,
            .delete => if (!ev.mods.ctrl and !ev.mods.shift and !ev.mods.alt) .textarea_delete else null,
            .backspace => if (!ev.mods.ctrl and !ev.mods.shift and !ev.mods.alt) .textarea_backspace else null,
            .enter => if (!ev.mods.ctrl and !ev.mods.shift and !ev.mods.alt) .textarea_newline else null,
            else => null,
        },
        else => null,
    };
}

pub fn applyTextareaAction(
    allocator: std.mem.Allocator,
    widgets: *std.ArrayList(WidgetEntry),
    textarea_id: []const u8,
    action: protocol.KeyAction,
    readonly: bool,
    visible_rows: usize,
    visible_cols: usize,
) !bool {
    const max_textarea_bytes: usize = 64 * 1024;
    const idx = try ensureWidgetKind(allocator, widgets, textarea_id, .textarea);
    var st = &widgets.items[idx].state.textarea;

    const before_cursor: usize = st.cursor;
    const before_len: usize = st.value.items.len;
    const before_scroll_y: usize = st.scroll_y;

    var changed: bool = false;
    switch (action) {
        .textarea_left => {
            const next = unicode.prevGraphemeBoundary(st.value.items, st.cursor);
            if (next != st.cursor) {
                st.cursor = next;
                changed = true;
            }
        },
        .textarea_right => {
            const next = unicode.nextGraphemeBoundary(st.value.items, st.cursor);
            if (next != st.cursor) {
                st.cursor = next;
                changed = true;
            }
        },
        .textarea_word_left => {
            const next = input.word_left(st.value.items, st.cursor);
            const clamped = unicode.clampGraphemeBoundary(st.value.items, next);
            if (clamped != st.cursor) {
                st.cursor = clamped;
                changed = true;
            }
        },
        .textarea_word_right => {
            const next = input.word_right(st.value.items, st.cursor);
            const clamped = unicode.clampGraphemeBoundary(st.value.items, next);
            if (clamped != st.cursor) {
                st.cursor = clamped;
                changed = true;
            }
        },
        .textarea_up, .textarea_down => {
            const pos = textareaCursorVisualPos(st.value.items, st.cursor, visible_cols);
            const content_h = textareaVisualLines(st.value.items, visible_cols);
            if (content_h == 0) return false;
            const target_y: usize = if (action == .textarea_up)
                (if (pos.y > 0) pos.y - 1 else 0)
            else
                @min(pos.y + 1, content_h - 1);
            const next = textareaByteIndexForVisualPos(st.value.items, target_y, pos.x, visible_cols);
            if (next != st.cursor) {
                st.cursor = next;
                changed = true;
            }
        },
        .textarea_home => {
            const pos = textareaCursorVisualPos(st.value.items, st.cursor, visible_cols);
            const next = textareaByteIndexForVisualPos(st.value.items, pos.y, 0, visible_cols);
            if (next != st.cursor) {
                st.cursor = next;
                changed = true;
            }
        },
        .textarea_end => {
            const pos = textareaCursorVisualPos(st.value.items, st.cursor, visible_cols);
            const next = textareaByteIndexForVisualPos(st.value.items, pos.y, std.math.maxInt(usize), visible_cols);
            if (next != st.cursor) {
                st.cursor = next;
                changed = true;
            }
        },
        .textarea_page_up, .textarea_page_down => {
            const pos = textareaCursorVisualPos(st.value.items, st.cursor, visible_cols);
            const content_h = textareaVisualLines(st.value.items, visible_cols);
            if (content_h == 0) return false;
            const step: usize = if (visible_rows > 1) visible_rows - 1 else 1;
            const target_y: usize = if (action == .textarea_page_up)
                (if (pos.y > step) pos.y - step else 0)
            else
                @min(pos.y + step, content_h - 1);
            const next = textareaByteIndexForVisualPos(st.value.items, target_y, pos.x, visible_cols);
            if (next != st.cursor) {
                st.cursor = next;
                changed = true;
            }
        },
        .textarea_delete => {
            if (readonly) return false;
            changed = input.delete_at_cursor(&st.value, &st.cursor);
        },
        .textarea_backspace => {
            if (readonly) return false;
            if (st.cursor != 0) {
                changed = try input.handleInputByte(allocator, &st.value, &st.cursor, 127);
            }
        },
        .textarea_newline => {
            if (readonly) return false;
            if (st.value.items.len + 1 > max_textarea_bytes) return false;
            if (st.cursor > st.value.items.len) st.cursor = st.value.items.len;
            st.cursor = unicode.clampGraphemeBoundary(st.value.items, st.cursor);
            if (st.cursor == st.value.items.len) {
                try st.value.append(allocator, '\n');
            } else {
                try st.value.insert(allocator, st.cursor, '\n');
            }
            st.cursor += 1;
            changed = true;
        },
        else => return false,
    }

    if (!changed and before_cursor == st.cursor and before_len == st.value.items.len and before_scroll_y == st.scroll_y) return false;

    if (st.cursor > st.value.items.len) st.cursor = st.value.items.len;
    const cursor_y = textareaCursorVisualY(st.value.items, st.cursor, visible_cols);
    const content_h = textareaVisualLines(st.value.items, visible_cols);
    const next_scroll_y = state.scrollIntoView(st.scroll_y, visible_rows, cursor_y, cursor_y + 1, content_h);
    const scroll_changed = next_scroll_y != st.scroll_y;
    st.scroll_y = next_scroll_y;
    return changed or scroll_changed;
}

pub fn handleFocusedTextareaPaste(
    allocator: std.mem.Allocator,
    widgets: *std.ArrayList(WidgetEntry),
    textarea_id: []const u8,
    payload: []const u8,
    readonly: bool,
    visible_rows: usize,
    visible_cols: usize,
) !bool {
    const max_textarea_bytes: usize = 64 * 1024;
    if (readonly) return false;
    const idx = try ensureWidgetKind(allocator, widgets, textarea_id, .textarea);
    var st = &widgets.items[idx].state.textarea;

    const before_cursor: usize = st.cursor;
    const before_len: usize = st.value.items.len;
    const before_scroll_y: usize = st.scroll_y;

    var sanitized: std.ArrayList(u8) = .empty;
    defer sanitized.deinit(allocator);
    try sanitized.ensureTotalCapacity(allocator, @min(payload.len, 4096));

    var i: usize = 0;
    while (i < payload.len) {
        if (st.value.items.len + sanitized.items.len >= max_textarea_bytes) break;

        const b = payload[i];
        if (b == '\r') {
            try sanitized.append(allocator, '\n');
            i += 1;
            continue;
        }
        if (b == '\n') {
            try sanitized.append(allocator, '\n');
            i += 1;
            continue;
        }
        if (b == '\t' or b < 0x20 or b == 0x7f) {
            try sanitized.append(allocator, ' ');
            i += 1;
            continue;
        }

        if (b < 0x80) {
            try sanitized.append(allocator, b);
            i += 1;
            continue;
        }

        const expect = std.unicode.utf8ByteSequenceLength(b) catch {
            i += 1;
            continue;
        };
        if (expect <= 1 or expect > 4) {
            i += 1;
            continue;
        }
        const n: usize = @as(usize, @intCast(expect));
        if (i + n > payload.len) break;

        const slice = payload[i .. i + n];
        _ = std.unicode.utf8Decode(slice) catch {
            i += 1;
            continue;
        };
        if (st.value.items.len + sanitized.items.len + slice.len > max_textarea_bytes) break;
        try sanitized.appendSlice(allocator, slice);
        i += n;
    }

    if (sanitized.items.len == 0) return false;

    if (st.cursor > st.value.items.len) st.cursor = st.value.items.len;
    st.cursor = unicode.clampGraphemeBoundary(st.value.items, st.cursor);

    if (st.cursor == st.value.items.len) {
        try st.value.appendSlice(allocator, sanitized.items);
    } else {
        try st.value.insertSlice(allocator, st.cursor, sanitized.items);
    }
    st.cursor += sanitized.items.len;
    if (st.cursor > st.value.items.len) st.cursor = st.value.items.len;

    const cursor_y = textareaCursorVisualY(st.value.items, st.cursor, visible_cols);
    const content_h = textareaVisualLines(st.value.items, visible_cols);
    st.scroll_y = state.scrollIntoView(st.scroll_y, visible_rows, cursor_y, cursor_y + 1, content_h);

    const changed = before_cursor != st.cursor or before_len != st.value.items.len or before_scroll_y != st.scroll_y;
    return changed;
}

fn setScrollViewportYById(
    allocator: std.mem.Allocator,
    log_sink: *log.LogSink,
    backend_in: anytype,
    widgets: *std.ArrayList(WidgetEntry),
    root: protocol.Node,
    rows: usize,
    cols: usize,
    scroll_id: []const u8,
    next_scroll_y: usize,
) !bool {
    const s = node_util.findScrollNodeById(root, scroll_id) orelse return false;
    const idx = try ensureWidgetKind(allocator, widgets, scroll_id, .scroll);
    var st = &widgets.items[idx].state.scroll;

    syncScrollForId(widgets, root, rows, cols, scroll_id);

    const before = st.scroll_y;
    st.scroll_y = next_scroll_y;
    clampScrollState(st);

    if (st.scroll_y == before) return false;
    log.logPrint(
        log_sink,
        "SCROLL_SET id={s} scroll_y={d} content_h={d} viewport_h={d}\n",
        .{ s.id, st.scroll_y, st.content_h, st.viewport_h },
    );
    try protocol.writeScrollEventJsonl(backend_in, s.id, st.scroll_y);
    return true;
}

pub fn handleFocusedScrollKey(
    allocator: std.mem.Allocator,
    log_sink: *log.LogSink,
    backend_in: anytype,
    widgets: *std.ArrayList(WidgetEntry),
    root: protocol.Node,
    rows: usize,
    cols: usize,
    scroll_id: []const u8,
    ev: keys.KeyEvent,
) !bool {
    const action = mapScrollKeyToAction(ev) orelse return false;
    return applyScrollAction(allocator, log_sink, backend_in, widgets, root, rows, cols, scroll_id, action);
}

fn mapScrollKeyToAction(ev: keys.KeyEvent) ?protocol.KeyAction {
    return switch (ev.key) {
        .text => |s| blk: {
            if (ev.mods.ctrl or ev.mods.alt or ev.mods.shift) break :blk null;
            if (s.len != 1) break :blk null;
            if (s[0] == 'j') break :blk .scroll_line_down;
            if (s[0] == 'k') break :blk .scroll_line_up;
            break :blk null;
        },
        .named => |k| switch (k) {
            .page_down => if (!ev.mods.ctrl and !ev.mods.alt and !ev.mods.shift) .scroll_page_down else null,
            .page_up => if (!ev.mods.ctrl and !ev.mods.alt and !ev.mods.shift) .scroll_page_up else null,
            .home => if (!ev.mods.ctrl and !ev.mods.alt and !ev.mods.shift) .scroll_home else null,
            .end => if (!ev.mods.ctrl and !ev.mods.alt and !ev.mods.shift) .scroll_end else null,
            else => null,
        },
        else => null,
    };
}

pub fn applyScrollAction(
    allocator: std.mem.Allocator,
    log_sink: *log.LogSink,
    backend_in: anytype,
    widgets: *std.ArrayList(WidgetEntry),
    root: protocol.Node,
    rows: usize,
    cols: usize,
    scroll_id: []const u8,
    action: protocol.KeyAction,
) !bool {
    const idx = try ensureWidgetKind(allocator, widgets, scroll_id, .scroll);
    const st = &widgets.items[idx].state.scroll;

    // Make sure page-scrolling uses the current viewport size.
    syncScrollForId(widgets, root, rows, cols, scroll_id);

    switch (action) {
        .scroll_line_down => return try scrollViewportById(allocator, log_sink, backend_in, widgets, root, rows, cols, scroll_id, 1),
        .scroll_line_up => return try scrollViewportById(allocator, log_sink, backend_in, widgets, root, rows, cols, scroll_id, -1),
        .scroll_page_down => {
            const step: isize = if (st.viewport_h > 1) @as(isize, @intCast(st.viewport_h - 1)) else 1;
            return try scrollViewportById(allocator, log_sink, backend_in, widgets, root, rows, cols, scroll_id, step);
        },
        .scroll_page_up => {
            const step: isize = if (st.viewport_h > 1) @as(isize, @intCast(st.viewport_h - 1)) else 1;
            return try scrollViewportById(allocator, log_sink, backend_in, widgets, root, rows, cols, scroll_id, -step);
        },
        .scroll_home => return try setScrollViewportYById(allocator, log_sink, backend_in, widgets, root, rows, cols, scroll_id, 0),
        .scroll_end => {
            const max_scroll: usize = if (st.content_h > st.viewport_h) st.content_h - st.viewport_h else 0;
            return try setScrollViewportYById(allocator, log_sink, backend_in, widgets, root, rows, cols, scroll_id, max_scroll);
        },
        else => return false,
    }
}

pub fn emitInputEventForId(log_sink: *log.LogSink, backend_in: anytype, widgets: []const WidgetEntry, input_id: []const u8) !void {
    const idx = findWidgetIndex(widgets, input_id) orelse return;
    switch (widgets[idx].state) {
        .input => |st| {
            log.logPrint(
                log_sink,
                "EVENT_TX name=input id={s} len={d} cursor={d}\n",
                .{ input_id, st.value.items.len, st.cursor },
            );
            try protocol.writeInputEventJsonl(backend_in, input_id, st.value.items, st.cursor);
        },
        .textarea => |st| {
            log.logPrint(
                log_sink,
                "EVENT_TX name=input id={s} len={d} cursor={d}\n",
                .{ input_id, st.value.items.len, st.cursor },
            );
            try protocol.writeInputEventJsonl(backend_in, input_id, st.value.items, st.cursor);
        },
        else => {},
    }
}

const std = @import("std");

const protocol = @import("protocol/mod.zig");
const render = @import("render/mod.zig");
const tree = @import("tree.zig");

pub const HoverHit = struct {
    id: ?[]const u8,
    item: ?[]const u8,
};

fn nodeDisabled(node: protocol.Node) bool {
    return switch (node) {
        .vbox => |v| v.disabled,
        .hbox => |h| h.disabled,
        .grid => |g| g.disabled,
        .box => |b| b.disabled,
        .scroll => |s| s.disabled,
        .overlay => |o| o.disabled,
        .text => |t| t.disabled,
        .styled_text => |t| t.disabled,
        .input => |i| i.disabled,
        .textarea => |t| t.disabled,
        .list => |l| l.disabled,
    };
}

fn nodeHoverable(node: protocol.Node) bool {
    if (nodeDisabled(node)) return false;
    return switch (node) {
        .vbox => |v| v.hoverable,
        .hbox => |h| h.hoverable,
        .grid => |g| g.hoverable,
        .box => |b| b.hoverable,
        .scroll => |s| s.hoverable,
        .overlay => |o| o.hoverable,
        .text => |t| t.hoverable,
        .styled_text => |t| t.hoverable,
        .input => |i| i.hoverable,
        .textarea => |t| t.hoverable,
        .list => |l| l.hoverable,
    };
}

pub fn treeHasHoverables(node: protocol.Node) bool {
    if (nodeDisabled(node)) return false;
    if (nodeHoverable(node)) return true;
    return switch (node) {
        .overlay => |o| {
            if (treeHasHoverables(o.base.*)) return true;
            for (o.layers) |layer| {
                if (treeHasHoverables(layer.node.*)) return true;
            }
            return false;
        },
        .vbox => |v| {
            for (v.children) |child| {
                if (treeHasHoverables(child)) return true;
            }
            return false;
        },
        .hbox => |h| {
            for (h.children) |child| {
                if (treeHasHoverables(child)) return true;
            }
            return false;
        },
        .grid => |g| {
            for (g.children) |child| {
                if (treeHasHoverables(child)) return true;
            }
            return false;
        },
        .box => |b| treeHasHoverables(b.child.*),
        .scroll => |s| treeHasHoverables(s.child.*),
        .list => |l| {
            for (l.children) |child| {
                if (treeHasHoverables(child)) return true;
            }
            return false;
        },
        else => false,
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
        .grid => |g| for (g.children) |child| findTopmostModalLayerInto(child, out),
        .box => |b| findTopmostModalLayerInto(b.child.*, out),
        .scroll => |s| findTopmostModalLayerInto(s.child.*, out),
        .list => |l| for (l.children) |child| findTopmostModalLayerInto(child, out),
        else => {},
    }
}

fn collectHoverables(allocator: std.mem.Allocator, root: protocol.Node) !std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);
    try collectHoverablesInto(allocator, &out, root);
    return out;
}

fn collectHoverablesInto(allocator: std.mem.Allocator, out: *std.ArrayList([]const u8), node: protocol.Node) !void {
    if (nodeDisabled(node)) return;
    if (nodeHoverable(node)) try out.append(allocator, tree.nodeId(node));

    switch (node) {
        .box => |b| try collectHoverablesInto(allocator, out, b.child.*),
        .scroll => |s| try collectHoverablesInto(allocator, out, s.child.*),
        .overlay => |o| {
            try collectHoverablesInto(allocator, out, o.base.*);
            for (o.layers) |layer| {
                try collectHoverablesInto(allocator, out, layer.node.*);
            }
        },
        .vbox => |v| for (v.children) |child| try collectHoverablesInto(allocator, out, child),
        .hbox => |h| for (h.children) |child| try collectHoverablesInto(allocator, out, child),
        .grid => |g| for (g.children) |child| try collectHoverablesInto(allocator, out, child),
        .list => |l| for (l.children) |child| try collectHoverablesInto(allocator, out, child),
        else => {},
    }
}

fn rectContains(r: render.Rect, x: usize, y: usize) bool {
    if (r.w == 0 or r.h == 0) return false;
    if (x < r.x or y < r.y) return false;
    if (x >= r.x + r.w) return false;
    if (y >= r.y + r.h) return false;
    return true;
}

fn findListNodeById(root: protocol.Node, id: []const u8) ?protocol.ListNode {
    if (std.mem.eql(u8, tree.nodeId(root), id)) {
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
        .grid => |g| blk: {
            for (g.children) |child| {
                if (findListNodeById(child, id)) |l| break :blk l;
            }
            break :blk null;
        },
        .box => |b| findListNodeById(b.child.*, id),
        .scroll => |s| findListNodeById(s.child.*, id),
        .overlay => |o| blk: {
            if (findListNodeById(o.base.*, id)) |l| break :blk l;
            for (o.layers) |layer| {
                if (findListNodeById(layer.node.*, id)) |l| break :blk l;
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

fn listVisibleHeight(rect: render.Rect, l: protocol.ListNode) usize {
    const desired = l.height orelse rect.h;
    return @min(desired, rect.h);
}

fn listScrollForId(lists: []const render.ListState, id: []const u8) usize {
    for (lists) |st| {
        if (std.mem.eql(u8, st.id, id)) return st.scroll;
    }
    return 0;
}

pub fn hoverHitTestLeaky(
    allocator: std.mem.Allocator,
    root: protocol.Node,
    rows: usize,
    cols: usize,
    x: usize,
    y: usize,
    scrolls: []const render.ScrollState,
    lists: []const render.ListState,
) !HoverHit {
    const hit_root: protocol.Node = if (findTopmostModalLayer(root)) |modal_ptr| modal_ptr.* else root;
    if (!treeHasHoverables(hit_root)) return .{ .id = null, .item = null };

    var layout_cache = render.LayoutCache.init(allocator);
    defer layout_cache.deinit();
    layout_cache.reset(&root, rows, cols, scrolls);

    var ids = try collectHoverables(allocator, hit_root);
    defer ids.deinit(allocator);

    var hit_id: ?[]const u8 = null;
    var hit_rect: render.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    for (ids.items) |id| {
        const r = layout_cache.findRect(id) orelse continue;
        if (rectContains(r, x, y)) {
            hit_id = id;
            hit_rect = r;
        }
    }

    const id = hit_id orelse return .{ .id = null, .item = null };
    const l = findListNodeById(root, id) orelse return .{ .id = id, .item = null };

    const scroll = listScrollForId(lists, id);
    const visible_height = listVisibleHeight(hit_rect, l);
    if (visible_height == 0) return .{ .id = id, .item = null };
    if (y < hit_rect.y) return .{ .id = id, .item = null };

    const start: usize = @min(scroll, l.children.len);
    const row_idx: usize = y - hit_rect.y;
    if (row_idx >= visible_height) return .{ .id = id, .item = null };
    const item_idx: usize = start + row_idx;
    if (item_idx >= l.children.len) return .{ .id = id, .item = null };

    return .{ .id = id, .item = tree.nodeId(l.children[item_idx]) };
}

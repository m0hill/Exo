const std = @import("std");

const protocol = @import("protocol/mod.zig");
const tree = @import("tree.zig");

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

fn nodeMouseable(node: protocol.Node) bool {
    if (nodeDisabled(node)) return false;
    return switch (node) {
        .vbox => |v| v.mouseable,
        .hbox => |h| h.mouseable,
        .grid => |g| g.mouseable,
        .box => |b| b.mouseable,
        .scroll => |s| s.mouseable,
        .overlay => |o| o.mouseable,
        .text => |t| t.mouseable,
        .styled_text => |t| t.mouseable,
        .input => |i| i.mouseable,
        .textarea => |t| t.mouseable,
        .list => |l| l.mouseable,
    };
}

pub fn treeHasMouseables(node: protocol.Node) bool {
    if (nodeDisabled(node)) return false;
    if (nodeMouseable(node)) return true;
    return switch (node) {
        .overlay => |o| blk: {
            if (treeHasMouseables(o.base.*)) break :blk true;
            for (o.layers) |layer| {
                if (treeHasMouseables(layer.node.*)) break :blk true;
            }
            break :blk false;
        },
        .vbox => |v| blk: {
            for (v.children) |child| {
                if (treeHasMouseables(child)) break :blk true;
            }
            break :blk false;
        },
        .hbox => |h| blk: {
            for (h.children) |child| {
                if (treeHasMouseables(child)) break :blk true;
            }
            break :blk false;
        },
        .grid => |g| blk: {
            for (g.children) |child| {
                if (treeHasMouseables(child)) break :blk true;
            }
            break :blk false;
        },
        .box => |b| treeHasMouseables(b.child.*),
        .scroll => |s| treeHasMouseables(s.child.*),
        .list => |l| blk: {
            for (l.children) |child| {
                if (treeHasMouseables(child)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

pub fn collectMouseables(allocator: std.mem.Allocator, root: protocol.Node) !std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);
    try collectMouseablesInto(allocator, &out, root);
    return out;
}

fn collectMouseablesInto(
    allocator: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
    node: protocol.Node,
) !void {
    if (nodeDisabled(node)) return;
    if (nodeMouseable(node)) try out.append(allocator, tree.nodeId(node));
    switch (node) {
        .overlay => |o| {
            try collectMouseablesInto(allocator, out, o.base.*);
            for (o.layers) |layer| try collectMouseablesInto(allocator, out, layer.node.*);
        },
        .vbox => |v| for (v.children) |child| try collectMouseablesInto(allocator, out, child),
        .hbox => |h| for (h.children) |child| try collectMouseablesInto(allocator, out, child),
        .grid => |g| for (g.children) |child| try collectMouseablesInto(allocator, out, child),
        .box => |b| try collectMouseablesInto(allocator, out, b.child.*),
        .scroll => |s| try collectMouseablesInto(allocator, out, s.child.*),
        .list => |l| for (l.children) |child| try collectMouseablesInto(allocator, out, child),
        else => {},
    }
}

const std = @import("std");

const protocol = @import("protocol/mod.zig");
const tree = @import("tree.zig");

fn nodeMouseable(node: protocol.Node) bool {
    return switch (node) {
        .vbox => |v| v.mouseable,
        .hbox => |h| h.mouseable,
        .box => |b| b.mouseable,
        .scroll => |s| s.mouseable,
        .overlay => |o| o.mouseable,
        .text => |t| t.mouseable,
        .styled_text => |t| t.mouseable,
        .input => |i| i.mouseable,
        .list => |l| l.mouseable,
    };
}

pub fn treeHasMouseables(node: protocol.Node) bool {
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
    if (nodeMouseable(node)) try out.append(allocator, tree.nodeId(node));
    switch (node) {
        .overlay => |o| {
            try collectMouseablesInto(allocator, out, o.base.*);
            for (o.layers) |layer| try collectMouseablesInto(allocator, out, layer.node.*);
        },
        .vbox => |v| for (v.children) |child| try collectMouseablesInto(allocator, out, child),
        .hbox => |h| for (h.children) |child| try collectMouseablesInto(allocator, out, child),
        .box => |b| try collectMouseablesInto(allocator, out, b.child.*),
        .scroll => |s| try collectMouseablesInto(allocator, out, s.child.*),
        .list => |l| for (l.children) |child| try collectMouseablesInto(allocator, out, child),
        else => {},
    }
}

const std = @import("std");
const protocol = @import("protocol.zig");

pub fn nodeId(node: protocol.Node) []const u8 {
    return switch (node) {
        .vbox => |v| v.id,
        .text => |t| t.id,
        .input => |i| i.id,
    };
}

pub fn treeContainsId(node: protocol.Node, id: []const u8) bool {
    if (std.mem.eql(u8, nodeId(node), id)) return true;
    return switch (node) {
        .vbox => |v| {
            for (v.children) |child| {
                if (treeContainsId(child, id)) return true;
            }
            return false;
        },
        else => false,
    };
}

pub fn applyPatchById(root: *protocol.Node, target: []const u8, replacement: protocol.Node) bool {
    if (std.mem.eql(u8, nodeId(root.*), target)) {
        root.* = replacement;
        return true;
    }

    return switch (root.*) {
        .vbox => |*v| {
            for (v.children) |*child| {
                if (applyPatchById(child, target, replacement)) return true;
            }
            return false;
        },
        else => false,
    };
}

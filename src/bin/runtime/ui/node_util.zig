const std = @import("std");

const tui = @import("tui");
const protocol = tui.protocol;

pub fn cloneNodeLeaky(allocator: std.mem.Allocator, node: protocol.Node) !protocol.Node {
    return switch (node) {
        .text => |t| .{ .text = .{
            .id = try allocator.dupe(u8, t.id),
            .w = t.w,
            .h = t.h,
            .flex = t.flex,
            .style = t.style,
            .text = try allocator.dupe(u8, t.text),
        } },
        .styled_text => |t| blk: {
            var spans = try allocator.alloc(protocol.Span, t.spans.len);
            for (t.spans, 0..) |sp, idx| {
                spans[idx] = .{
                    .text = try allocator.dupe(u8, sp.text),
                    .style = sp.style,
                };
            }
            break :blk .{ .styled_text = .{
                .id = try allocator.dupe(u8, t.id),
                .w = t.w,
                .h = t.h,
                .flex = t.flex,
                .style = t.style,
                .spans = spans,
            } };
        },
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
        .box => |b| .{ .box = .{
            .id = try allocator.dupe(u8, b.id),
            .w = b.w,
            .h = b.h,
            .flex = b.flex,
            .title = if (b.title) |t| try allocator.dupe(u8, t) else null,
            .border = b.border,
            .pad = b.pad,
            .clip = b.clip,
            .shadow = b.shadow,
            .style = b.style,
            .child = blk: {
                const child_node = try cloneNodeLeaky(allocator, b.child.*);
                const child = try allocator.create(protocol.Node);
                child.* = child_node;
                break :blk child;
            },
        } },
        .scroll => |s| .{ .scroll = .{
            .id = try allocator.dupe(u8, s.id),
            .w = s.w,
            .h = s.h,
            .flex = s.flex,
            .pad = s.pad,
            .clip = s.clip,
            .style = s.style,
            .child = blk: {
                const child_node = try cloneNodeLeaky(allocator, s.child.*);
                const child = try allocator.create(protocol.Node);
                child.* = child_node;
                break :blk child;
            },
        } },
        .overlay => |o| blk: {
            const base_node = try cloneNodeLeaky(allocator, o.base.*);
            const base = try allocator.create(protocol.Node);
            base.* = base_node;

            var layers = try allocator.alloc(protocol.OverlayLayer, o.layers.len);
            for (o.layers, 0..) |layer, idx| {
                const node_node = try cloneNodeLeaky(allocator, layer.node.*);
                const layer_node = try allocator.create(protocol.Node);
                layer_node.* = node_node;
                layers[idx] = .{
                    .node = layer_node,
                    .anchor = if (layer.anchor) |a| try allocator.dupe(u8, a) else null,
                    .placement = layer.placement,
                    .align_ = layer.align_,
                    .offset_x = layer.offset_x,
                    .offset_y = layer.offset_y,
                    .w = layer.w,
                    .h = layer.h,
                    .clip = layer.clip,
                    .modal = layer.modal,
                };
            }

            break :blk .{ .overlay = .{
                .id = try allocator.dupe(u8, o.id),
                .w = o.w,
                .h = o.h,
                .flex = o.flex,
                .pad = o.pad,
                .clip = o.clip,
                .style = o.style,
                .base = base,
                .layers = layers,
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

pub fn nodeId(node: protocol.Node) []const u8 {
    return switch (node) {
        .vbox => |v| v.id,
        .hbox => |h| h.id,
        .box => |b| b.id,
        .scroll => |s| s.id,
        .overlay => |o| o.id,
        .text => |t| t.id,
        .styled_text => |t| t.id,
        .input => |i| i.id,
        .list => |l| l.id,
    };
}

pub fn findListNodeById(root: protocol.Node, id: []const u8) ?protocol.ListNode {
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
        .box => |b| return findListNodeById(b.child.*, id),
        .scroll => |s| return findListNodeById(s.child.*, id),
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

pub fn findScrollNodeById(root: protocol.Node, id: []const u8) ?protocol.ScrollNode {
    if (std.mem.eql(u8, nodeId(root), id)) {
        return switch (root) {
            .scroll => |s| s,
            else => null,
        };
    }

    return switch (root) {
        .vbox => |v| blk: {
            for (v.children) |child| {
                if (findScrollNodeById(child, id)) |s| break :blk s;
            }
            break :blk null;
        },
        .hbox => |h| blk: {
            for (h.children) |child| {
                if (findScrollNodeById(child, id)) |s| break :blk s;
            }
            break :blk null;
        },
        .box => |b| return findScrollNodeById(b.child.*, id),
        .scroll => |s| return findScrollNodeById(s.child.*, id),
        .overlay => |o| blk: {
            if (findScrollNodeById(o.base.*, id)) |s| break :blk s;
            for (o.layers) |layer| {
                if (findScrollNodeById(layer.node.*, id)) |s| break :blk s;
            }
            break :blk null;
        },
        .list => |l| blk: {
            for (l.children) |child| {
                if (findScrollNodeById(child, id)) |s| break :blk s;
            }
            break :blk null;
        },
        else => null,
    };
}

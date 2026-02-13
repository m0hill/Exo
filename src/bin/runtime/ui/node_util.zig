const std = @import("std");

const tui = @import("tui");
const protocol = tui.protocol;

pub fn cloneNodeLeaky(allocator: std.mem.Allocator, node: protocol.Node) !protocol.Node {
    return switch (node) {
        .text => |t| .{ .text = .{
            .id = try allocator.dupe(u8, t.id),
            .class = if (t.class) |class| try allocator.dupe(u8, class) else null,
            .w = t.w,
            .h = t.h,
            .min_w = t.min_w,
            .max_w = t.max_w,
            .min_h = t.min_h,
            .max_h = t.max_h,
            .w_pct = t.w_pct,
            .h_pct = t.h_pct,
            .flex = t.flex,
            .hoverable = t.hoverable,
            .style = t.style,
            .overflow = t.overflow,
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
                .class = if (t.class) |class| try allocator.dupe(u8, class) else null,
                .w = t.w,
                .h = t.h,
                .min_w = t.min_w,
                .max_w = t.max_w,
                .min_h = t.min_h,
                .max_h = t.max_h,
                .w_pct = t.w_pct,
                .h_pct = t.h_pct,
                .flex = t.flex,
                .hoverable = t.hoverable,
                .style = t.style,
                .overflow = t.overflow,
                .spans = spans,
            } };
        },
        .input => |i| .{ .input = .{
            .id = try allocator.dupe(u8, i.id),
            .class = if (i.class) |class| try allocator.dupe(u8, class) else null,
            .w = i.w,
            .h = i.h,
            .min_w = i.min_w,
            .max_w = i.max_w,
            .min_h = i.min_h,
            .max_h = i.max_h,
            .w_pct = i.w_pct,
            .h_pct = i.h_pct,
            .flex = i.flex,
            .hoverable = i.hoverable,
            .mouseable = i.mouseable,
            .disabled = i.disabled,
            .readonly = i.readonly,
            .validation = i.validation,
            .focusable = i.focusable,
            .style = i.style,
            .selection_style = i.selection_style,
            .placeholder_style = i.placeholder_style,
            .placeholder = if (i.placeholder) |p| try allocator.dupe(u8, p) else null,
            .state_mode = i.state_mode,
            .value = if (i.value) |v| try allocator.dupe(u8, v) else null,
            .cursor = i.cursor,
            .scroll_x = i.scroll_x,
            .selection_start = i.selection_start,
            .selection_end = i.selection_end,
        } },
        .textarea => |t| .{ .textarea = .{
            .id = try allocator.dupe(u8, t.id),
            .class = if (t.class) |class| try allocator.dupe(u8, class) else null,
            .w = t.w,
            .h = t.h,
            .min_w = t.min_w,
            .max_w = t.max_w,
            .min_h = t.min_h,
            .max_h = t.max_h,
            .w_pct = t.w_pct,
            .h_pct = t.h_pct,
            .flex = t.flex,
            .align_self = t.align_self,
            .hoverable = t.hoverable,
            .mouseable = t.mouseable,
            .disabled = t.disabled,
            .readonly = t.readonly,
            .validation = t.validation,
            .focusable = t.focusable,
            .style = t.style,
            .selection_style = t.selection_style,
            .placeholder_style = t.placeholder_style,
            .placeholder = if (t.placeholder) |p| try allocator.dupe(u8, p) else null,
            .state_mode = t.state_mode,
            .value = if (t.value) |v| try allocator.dupe(u8, v) else null,
            .cursor = t.cursor,
            .scroll_y = t.scroll_y,
            .selection_start = t.selection_start,
            .selection_end = t.selection_end,
        } },
        .vbox => |v| blk: {
            var children = try allocator.alloc(protocol.Node, v.children.len);
            for (v.children, 0..) |child, idx| {
                children[idx] = try cloneNodeLeaky(allocator, child);
            }
            break :blk .{ .vbox = .{
                .id = try allocator.dupe(u8, v.id),
                .class = if (v.class) |class| try allocator.dupe(u8, class) else null,
                .w = v.w,
                .h = v.h,
                .min_w = v.min_w,
                .max_w = v.max_w,
                .min_h = v.min_h,
                .max_h = v.max_h,
                .w_pct = v.w_pct,
                .h_pct = v.h_pct,
                .flex = v.flex,
                .pad = v.pad,
                .clip = v.clip,
                .hoverable = v.hoverable,
                .mouseable = v.mouseable,
                .disabled = v.disabled,
                .readonly = v.readonly,
                .validation = v.validation,
                .focusable = v.focusable,
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
                .class = if (h.class) |class| try allocator.dupe(u8, class) else null,
                .w = h.w,
                .h = h.h,
                .min_w = h.min_w,
                .max_w = h.max_w,
                .min_h = h.min_h,
                .max_h = h.max_h,
                .w_pct = h.w_pct,
                .h_pct = h.h_pct,
                .flex = h.flex,
                .pad = h.pad,
                .clip = h.clip,
                .hoverable = h.hoverable,
                .mouseable = h.mouseable,
                .disabled = h.disabled,
                .readonly = h.readonly,
                .validation = h.validation,
                .focusable = h.focusable,
                .style = h.style,
                .children = children,
            } };
        },
        .grid => |g| blk: {
            var children = try allocator.alloc(protocol.Node, g.children.len);
            for (g.children, 0..) |child, idx| {
                children[idx] = try cloneNodeLeaky(allocator, child);
            }
            const rows = try allocator.alloc(protocol.GridTrack, g.rows.len);
            @memcpy(rows, g.rows);
            const cols = try allocator.alloc(protocol.GridTrack, g.cols.len);
            @memcpy(cols, g.cols);
            break :blk .{ .grid = .{
                .id = try allocator.dupe(u8, g.id),
                .class = if (g.class) |class| try allocator.dupe(u8, class) else null,
                .w = g.w,
                .h = g.h,
                .min_w = g.min_w,
                .max_w = g.max_w,
                .min_h = g.min_h,
                .max_h = g.max_h,
                .w_pct = g.w_pct,
                .h_pct = g.h_pct,
                .flex = g.flex,
                .pad = g.pad,
                .clip = g.clip,
                .hoverable = g.hoverable,
                .mouseable = g.mouseable,
                .disabled = g.disabled,
                .readonly = g.readonly,
                .validation = g.validation,
                .focusable = g.focusable,
                .style = g.style,
                .gap_x = g.gap_x,
                .gap_y = g.gap_y,
                .rows = rows,
                .cols = cols,
                .areas = g.areas,
                .children = children,
            } };
        },
        .box => |b| .{ .box = .{
            .id = try allocator.dupe(u8, b.id),
            .class = if (b.class) |class| try allocator.dupe(u8, class) else null,
            .w = b.w,
            .h = b.h,
            .min_w = b.min_w,
            .max_w = b.max_w,
            .min_h = b.min_h,
            .max_h = b.max_h,
            .w_pct = b.w_pct,
            .h_pct = b.h_pct,
            .flex = b.flex,
            .title = if (b.title) |t| try allocator.dupe(u8, t) else null,
            .border = b.border,
            .pad = b.pad,
            .clip = b.clip,
            .shadow = b.shadow,
            .hoverable = b.hoverable,
            .mouseable = b.mouseable,
            .disabled = b.disabled,
            .readonly = b.readonly,
            .validation = b.validation,
            .focusable = b.focusable,
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
            .class = if (s.class) |class| try allocator.dupe(u8, class) else null,
            .w = s.w,
            .h = s.h,
            .min_w = s.min_w,
            .max_w = s.max_w,
            .min_h = s.min_h,
            .max_h = s.max_h,
            .w_pct = s.w_pct,
            .h_pct = s.h_pct,
            .flex = s.flex,
            .pad = s.pad,
            .clip = s.clip,
            .hoverable = s.hoverable,
            .mouseable = s.mouseable,
            .disabled = s.disabled,
            .readonly = s.readonly,
            .validation = s.validation,
            .focusable = s.focusable,
            .style = s.style,
            .state_mode = s.state_mode,
            .scroll_y = s.scroll_y,
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
                .class = if (o.class) |class| try allocator.dupe(u8, class) else null,
                .w = o.w,
                .h = o.h,
                .min_w = o.min_w,
                .max_w = o.max_w,
                .min_h = o.min_h,
                .max_h = o.max_h,
                .w_pct = o.w_pct,
                .h_pct = o.h_pct,
                .flex = o.flex,
                .pad = o.pad,
                .clip = o.clip,
                .hoverable = o.hoverable,
                .mouseable = o.mouseable,
                .disabled = o.disabled,
                .readonly = o.readonly,
                .validation = o.validation,
                .focusable = o.focusable,
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
                .class = if (l.class) |class| try allocator.dupe(u8, class) else null,
                .w = l.w,
                .h = l.h,
                .min_w = l.min_w,
                .max_w = l.max_w,
                .min_h = l.min_h,
                .max_h = l.max_h,
                .w_pct = l.w_pct,
                .h_pct = l.h_pct,
                .flex = l.flex,
                .height = l.height,
                .hoverable = l.hoverable,
                .mouseable = l.mouseable,
                .disabled = l.disabled,
                .readonly = l.readonly,
                .validation = l.validation,
                .focusable = l.focusable,
                .marker = l.marker,
                .style = l.style,
                .state_mode = l.state_mode,
                .selected_id = if (l.selected_id) |v| try allocator.dupe(u8, v) else null,
                .scroll = l.scroll,
                .children = children,
            } };
        },
        .vlist => |l| blk: {
            var children = try allocator.alloc(protocol.Node, l.children.len);
            for (l.children, 0..) |child, idx| {
                children[idx] = try cloneNodeLeaky(allocator, child);
            }
            break :blk .{ .vlist = .{
                .id = try allocator.dupe(u8, l.id),
                .class = if (l.class) |class| try allocator.dupe(u8, class) else null,
                .w = l.w,
                .h = l.h,
                .min_w = l.min_w,
                .max_w = l.max_w,
                .min_h = l.min_h,
                .max_h = l.max_h,
                .w_pct = l.w_pct,
                .h_pct = l.h_pct,
                .flex = l.flex,
                .height = l.height,
                .hoverable = l.hoverable,
                .mouseable = l.mouseable,
                .disabled = l.disabled,
                .readonly = l.readonly,
                .validation = l.validation,
                .focusable = l.focusable,
                .marker = l.marker,
                .style = l.style,
                .state_mode = l.state_mode,
                .selected_index = l.selected_index,
                .scroll = l.scroll,
                .total = l.total,
                .window_start = l.window_start,
                .item_id_prefix = try allocator.dupe(u8, l.item_id_prefix),
                .overscan = l.overscan,
                .req = l.req,
                .children = children,
            } };
        },
    };
}

pub fn nodeId(node: protocol.Node) []const u8 {
    return switch (node) {
        .vbox => |v| v.id,
        .hbox => |h| h.id,
        .grid => |g| g.id,
        .box => |b| b.id,
        .scroll => |s| s.id,
        .overlay => |o| o.id,
        .text => |t| t.id,
        .styled_text => |t| t.id,
        .input => |i| i.id,
        .textarea => |t| t.id,
        .list => |l| l.id,
        .vlist => |l| l.id,
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
        .grid => |g| blk: {
            for (g.children) |child| {
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
        .vlist => |l| blk: {
            for (l.children) |child| {
                if (findListNodeById(child, id)) |ll| break :blk ll;
            }
            break :blk null;
        },
        else => null,
    };
}

pub fn findVListNodeById(root: protocol.Node, id: []const u8) ?protocol.VListNode {
    if (std.mem.eql(u8, nodeId(root), id)) {
        return switch (root) {
            .vlist => |l| l,
            else => null,
        };
    }

    return switch (root) {
        .vbox => |v| blk: {
            for (v.children) |child| {
                if (findVListNodeById(child, id)) |l| break :blk l;
            }
            break :blk null;
        },
        .hbox => |h| blk: {
            for (h.children) |child| {
                if (findVListNodeById(child, id)) |l| break :blk l;
            }
            break :blk null;
        },
        .grid => |g| blk: {
            for (g.children) |child| {
                if (findVListNodeById(child, id)) |l| break :blk l;
            }
            break :blk null;
        },
        .box => |b| return findVListNodeById(b.child.*, id),
        .scroll => |s| return findVListNodeById(s.child.*, id),
        .overlay => |o| blk: {
            if (findVListNodeById(o.base.*, id)) |l| break :blk l;
            for (o.layers) |layer| {
                if (findVListNodeById(layer.node.*, id)) |l| break :blk l;
            }
            break :blk null;
        },
        .list => |l| blk: {
            for (l.children) |child| {
                if (findVListNodeById(child, id)) |ll| break :blk ll;
            }
            break :blk null;
        },
        .vlist => |l| blk: {
            for (l.children) |child| {
                if (findVListNodeById(child, id)) |ll| break :blk ll;
            }
            break :blk null;
        },
        else => null,
    };
}

pub fn findInputNodeById(root: protocol.Node, id: []const u8) ?protocol.InputNode {
    if (std.mem.eql(u8, nodeId(root), id)) {
        return switch (root) {
            .input => |i| i,
            else => null,
        };
    }

    return switch (root) {
        .vbox => |v| blk: {
            for (v.children) |child| {
                if (findInputNodeById(child, id)) |i| break :blk i;
            }
            break :blk null;
        },
        .hbox => |h| blk: {
            for (h.children) |child| {
                if (findInputNodeById(child, id)) |i| break :blk i;
            }
            break :blk null;
        },
        .grid => |g| blk: {
            for (g.children) |child| {
                if (findInputNodeById(child, id)) |i| break :blk i;
            }
            break :blk null;
        },
        .box => |b| return findInputNodeById(b.child.*, id),
        .scroll => |s| return findInputNodeById(s.child.*, id),
        .overlay => |o| blk: {
            if (findInputNodeById(o.base.*, id)) |i| break :blk i;
            for (o.layers) |layer| {
                if (findInputNodeById(layer.node.*, id)) |i| break :blk i;
            }
            break :blk null;
        },
        .list => |l| blk: {
            for (l.children) |child| {
                if (findInputNodeById(child, id)) |i| break :blk i;
            }
            break :blk null;
        },
        .vlist => |l| blk: {
            for (l.children) |child| {
                if (findInputNodeById(child, id)) |i| break :blk i;
            }
            break :blk null;
        },
        else => null,
    };
}

pub fn findTextareaNodeById(root: protocol.Node, id: []const u8) ?protocol.TextareaNode {
    if (std.mem.eql(u8, nodeId(root), id)) {
        return switch (root) {
            .textarea => |t| t,
            else => null,
        };
    }

    return switch (root) {
        .vbox => |v| blk: {
            for (v.children) |child| {
                if (findTextareaNodeById(child, id)) |t| break :blk t;
            }
            break :blk null;
        },
        .hbox => |h| blk: {
            for (h.children) |child| {
                if (findTextareaNodeById(child, id)) |t| break :blk t;
            }
            break :blk null;
        },
        .grid => |g| blk: {
            for (g.children) |child| {
                if (findTextareaNodeById(child, id)) |t| break :blk t;
            }
            break :blk null;
        },
        .box => |b| return findTextareaNodeById(b.child.*, id),
        .scroll => |s| return findTextareaNodeById(s.child.*, id),
        .overlay => |o| blk: {
            if (findTextareaNodeById(o.base.*, id)) |t| break :blk t;
            for (o.layers) |layer| {
                if (findTextareaNodeById(layer.node.*, id)) |t| break :blk t;
            }
            break :blk null;
        },
        .list => |l| blk: {
            for (l.children) |child| {
                if (findTextareaNodeById(child, id)) |t| break :blk t;
            }
            break :blk null;
        },
        .vlist => |l| blk: {
            for (l.children) |child| {
                if (findTextareaNodeById(child, id)) |t| break :blk t;
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
        .grid => |g| blk: {
            for (g.children) |child| {
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
        .vlist => |l| blk: {
            for (l.children) |child| {
                if (findScrollNodeById(child, id)) |s| break :blk s;
            }
            break :blk null;
        },
        else => null,
    };
}

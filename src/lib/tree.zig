const std = @import("std");
const protocol = @import("protocol/mod.zig");

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
        .textarea => |t| t.id,
        .list => |l| l.id,
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
        .hbox => |h| {
            for (h.children) |child| {
                if (treeContainsId(child, id)) return true;
            }
            return false;
        },
        .box => |b| treeContainsId(b.child.*, id),
        .scroll => |s| treeContainsId(s.child.*, id),
        .overlay => |o| {
            if (treeContainsId(o.base.*, id)) return true;
            for (o.layers) |layer| {
                if (treeContainsId(layer.node.*, id)) return true;
            }
            return false;
        },
        .list => |l| {
            for (l.children) |child| {
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
        .hbox => |*h| {
            for (h.children) |*child| {
                if (applyPatchById(child, target, replacement)) return true;
            }
            return false;
        },
        .box => |*b| return applyPatchById(b.child, target, replacement),
        .scroll => |*s| return applyPatchById(s.child, target, replacement),
        .overlay => |*o| {
            if (applyPatchById(o.base, target, replacement)) return true;
            for (o.layers) |layer| {
                if (applyPatchById(layer.node, target, replacement)) return true;
            }
            return false;
        },
        .list => |*l| {
            for (l.children) |*child| {
                if (applyPatchById(child, target, replacement)) return true;
            }
            return false;
        },
        else => false,
    };
}

pub const MorphStats = struct {
    reused: usize = 0,
    inserted: usize = 0,
    removed: usize = 0,
    replaced: usize = 0,
    type_mismatch: usize = 0,
};

pub fn morphPatchByIdLeaky(
    allocator: std.mem.Allocator,
    root: *protocol.Node,
    target: []const u8,
    incoming: protocol.Node,
    stats: *MorphStats,
) std.mem.Allocator.Error!bool {
    if (std.mem.eql(u8, nodeId(root.*), target)) {
        try morphNodeLeaky(allocator, root, incoming, stats);
        return true;
    }

    return switch (root.*) {
        .vbox => |*v| {
            for (v.children) |*child| {
                if (try morphPatchByIdLeaky(allocator, child, target, incoming, stats)) return true;
            }
            return false;
        },
        .hbox => |*h| {
            for (h.children) |*child| {
                if (try morphPatchByIdLeaky(allocator, child, target, incoming, stats)) return true;
            }
            return false;
        },
        .box => |*b| return try morphPatchByIdLeaky(allocator, b.child, target, incoming, stats),
        .scroll => |*s| return try morphPatchByIdLeaky(allocator, s.child, target, incoming, stats),
        .overlay => |*o| {
            if (try morphPatchByIdLeaky(allocator, o.base, target, incoming, stats)) return true;
            for (o.layers) |layer| {
                if (try morphPatchByIdLeaky(allocator, layer.node, target, incoming, stats)) return true;
            }
            return false;
        },
        .list => |*l| {
            for (l.children) |*child| {
                if (try morphPatchByIdLeaky(allocator, child, target, incoming, stats)) return true;
            }
            return false;
        },
        else => false,
    };
}

fn morphNodeLeaky(
    allocator: std.mem.Allocator,
    existing: *protocol.Node,
    incoming: protocol.Node,
    stats: *MorphStats,
) std.mem.Allocator.Error!void {
    if (std.meta.activeTag(existing.*) != std.meta.activeTag(incoming)) {
        stats.type_mismatch += 1;
        stats.replaced += 1;
        existing.* = incoming;
        return;
    }

    switch (existing.*) {
        .text => |*t| {
            const inc = incoming.text;
            t.w = inc.w;
            t.h = inc.h;
            t.flex = inc.flex;
            t.align_self = inc.align_self;
            t.hoverable = inc.hoverable;
            t.mouseable = inc.mouseable;
            t.disabled = inc.disabled;
            t.readonly = inc.readonly;
            t.validation = inc.validation;
            t.focusable = inc.focusable;
            t.focus_scope = inc.focus_scope;
            t.ext_align = inc.ext_align;
            t.v_align = inc.v_align;
            t.style = inc.style;
            t.text = inc.text;
        },
        .styled_text => |*t| {
            const inc = incoming.styled_text;
            t.w = inc.w;
            t.h = inc.h;
            t.flex = inc.flex;
            t.align_self = inc.align_self;
            t.hoverable = inc.hoverable;
            t.mouseable = inc.mouseable;
            t.disabled = inc.disabled;
            t.readonly = inc.readonly;
            t.validation = inc.validation;
            t.focusable = inc.focusable;
            t.focus_scope = inc.focus_scope;
            t.ext_align = inc.ext_align;
            t.v_align = inc.v_align;
            t.style = inc.style;
            t.spans = inc.spans;
        },
        .input => |*i| {
            const inc = incoming.input;
            i.w = inc.w;
            i.h = inc.h;
            i.flex = inc.flex;
            i.align_self = inc.align_self;
            i.hoverable = inc.hoverable;
            i.mouseable = inc.mouseable;
            i.disabled = inc.disabled;
            i.readonly = inc.readonly;
            i.validation = inc.validation;
            i.focusable = inc.focusable;
            i.focus_scope = inc.focus_scope;
            i.content_align = inc.content_align;
            i.style = inc.style;
            i.placeholder_style = inc.placeholder_style;
            i.placeholder = inc.placeholder;
        },
        .textarea => |*t| {
            const inc = incoming.textarea;
            t.w = inc.w;
            t.h = inc.h;
            t.flex = inc.flex;
            t.align_self = inc.align_self;
            t.hoverable = inc.hoverable;
            t.mouseable = inc.mouseable;
            t.disabled = inc.disabled;
            t.readonly = inc.readonly;
            t.validation = inc.validation;
            t.focusable = inc.focusable;
            t.focus_scope = inc.focus_scope;
            t.style = inc.style;
            t.placeholder_style = inc.placeholder_style;
            t.placeholder = inc.placeholder;
        },
        .vbox => |*v| {
            const inc = incoming.vbox;
            const existing_children = v.children;

            v.w = inc.w;
            v.h = inc.h;
            v.flex = inc.flex;
            v.pad = inc.pad;
            v.clip = inc.clip;
            v.hoverable = inc.hoverable;
            v.mouseable = inc.mouseable;
            v.disabled = inc.disabled;
            v.readonly = inc.readonly;
            v.validation = inc.validation;
            v.focusable = inc.focusable;
            v.focus_scope = inc.focus_scope;
            v.justify_content = inc.justify_content;
            v.align_items = inc.align_items;
            v.gap = inc.gap;
            v.align_self = inc.align_self;
            v.style = inc.style;

            var used = try allocator.alloc(bool, existing_children.len);
            @memset(used, false);

            var next_children = try allocator.alloc(protocol.Node, inc.children.len);
            var matched: usize = 0;

            for (inc.children, 0..) |inc_child, out_idx| {
                const inc_id = nodeId(inc_child);
                var found_idx: ?usize = null;

                for (existing_children, 0..) |ex_child, ex_idx| {
                    if (used[ex_idx]) continue;
                    if (std.mem.eql(u8, nodeId(ex_child), inc_id)) {
                        found_idx = ex_idx;
                        break;
                    }
                }

                if (found_idx) |ex_idx| {
                    used[ex_idx] = true;
                    matched += 1;

                    const ex_child = existing_children[ex_idx];
                    if (std.meta.activeTag(ex_child) == std.meta.activeTag(inc_child)) {
                        stats.reused += 1;
                        var next_child = ex_child;
                        try morphNodeLeaky(allocator, &next_child, inc_child, stats);
                        next_children[out_idx] = next_child;
                    } else {
                        stats.type_mismatch += 1;
                        stats.replaced += 1;
                        next_children[out_idx] = inc_child;
                    }
                } else {
                    stats.inserted += 1;
                    next_children[out_idx] = inc_child;
                }
            }

            stats.removed += existing_children.len - matched;
            v.children = next_children;
        },
        .hbox => |*h| {
            const inc = incoming.hbox;
            const existing_children = h.children;

            h.w = inc.w;
            h.h = inc.h;
            h.flex = inc.flex;
            h.pad = inc.pad;
            h.clip = inc.clip;
            h.hoverable = inc.hoverable;
            h.mouseable = inc.mouseable;
            h.disabled = inc.disabled;
            h.readonly = inc.readonly;
            h.validation = inc.validation;
            h.focusable = inc.focusable;
            h.focus_scope = inc.focus_scope;
            h.justify_content = inc.justify_content;
            h.align_items = inc.align_items;
            h.gap = inc.gap;
            h.align_self = inc.align_self;
            h.style = inc.style;

            var used = try allocator.alloc(bool, existing_children.len);
            @memset(used, false);

            var next_children = try allocator.alloc(protocol.Node, inc.children.len);
            var matched: usize = 0;

            for (inc.children, 0..) |inc_child, out_idx| {
                const inc_id = nodeId(inc_child);
                var found_idx: ?usize = null;

                for (existing_children, 0..) |ex_child, ex_idx| {
                    if (used[ex_idx]) continue;
                    if (std.mem.eql(u8, nodeId(ex_child), inc_id)) {
                        found_idx = ex_idx;
                        break;
                    }
                }

                if (found_idx) |ex_idx| {
                    used[ex_idx] = true;
                    matched += 1;

                    const ex_child = existing_children[ex_idx];
                    if (std.meta.activeTag(ex_child) == std.meta.activeTag(inc_child)) {
                        stats.reused += 1;
                        var next_child = ex_child;
                        try morphNodeLeaky(allocator, &next_child, inc_child, stats);
                        next_children[out_idx] = next_child;
                    } else {
                        stats.type_mismatch += 1;
                        stats.replaced += 1;
                        next_children[out_idx] = inc_child;
                    }
                } else {
                    stats.inserted += 1;
                    next_children[out_idx] = inc_child;
                }
            }

            stats.removed += existing_children.len - matched;
            h.children = next_children;
        },
        .box => |*b| {
            const inc = incoming.box;
            b.w = inc.w;
            b.h = inc.h;
            b.flex = inc.flex;
            b.title = inc.title;
            b.border = inc.border;
            b.pad = inc.pad;
            b.clip = inc.clip;
            b.shadow = inc.shadow;
            b.hoverable = inc.hoverable;
            b.mouseable = inc.mouseable;
            b.disabled = inc.disabled;
            b.readonly = inc.readonly;
            b.validation = inc.validation;
            b.focusable = inc.focusable;
            b.focus_scope = inc.focus_scope;
            b.align_self = inc.align_self;
            b.style = inc.style;

            if (std.meta.activeTag(b.child.*) == std.meta.activeTag(inc.child.*)) {
                try morphNodeLeaky(allocator, b.child, inc.child.*, stats);
            } else {
                stats.type_mismatch += 1;
                stats.replaced += 1;
                b.child = inc.child;
            }
        },
        .scroll => |*s| {
            const inc = incoming.scroll;
            s.w = inc.w;
            s.h = inc.h;
            s.flex = inc.flex;
            s.pad = inc.pad;
            s.clip = inc.clip;
            s.hoverable = inc.hoverable;
            s.mouseable = inc.mouseable;
            s.disabled = inc.disabled;
            s.readonly = inc.readonly;
            s.validation = inc.validation;
            s.focusable = inc.focusable;
            s.focus_scope = inc.focus_scope;
            s.align_self = inc.align_self;
            s.style = inc.style;

            if (std.meta.activeTag(s.child.*) == std.meta.activeTag(inc.child.*)) {
                try morphNodeLeaky(allocator, s.child, inc.child.*, stats);
            } else {
                stats.type_mismatch += 1;
                stats.replaced += 1;
                s.child = inc.child;
            }
        },
        .overlay => |*o| {
            const inc = incoming.overlay;
            const existing_layers = o.layers;

            o.w = inc.w;
            o.h = inc.h;
            o.flex = inc.flex;
            o.pad = inc.pad;
            o.clip = inc.clip;
            o.hoverable = inc.hoverable;
            o.mouseable = inc.mouseable;
            o.disabled = inc.disabled;
            o.readonly = inc.readonly;
            o.validation = inc.validation;
            o.focusable = inc.focusable;
            o.focus_scope = inc.focus_scope;
            o.align_self = inc.align_self;
            o.style = inc.style;

            if (std.meta.activeTag(o.base.*) == std.meta.activeTag(inc.base.*)) {
                try morphNodeLeaky(allocator, o.base, inc.base.*, stats);
            } else {
                stats.type_mismatch += 1;
                stats.replaced += 1;
                o.base = inc.base;
            }

            var used = try allocator.alloc(bool, existing_layers.len);
            @memset(used, false);

            var next_layers = try allocator.alloc(protocol.OverlayLayer, inc.layers.len);
            var matched: usize = 0;

            for (inc.layers, 0..) |inc_layer, out_idx| {
                const inc_id = nodeId(inc_layer.node.*);
                var found_idx: ?usize = null;

                for (existing_layers, 0..) |ex_layer, ex_idx| {
                    if (used[ex_idx]) continue;
                    if (std.mem.eql(u8, nodeId(ex_layer.node.*), inc_id)) {
                        found_idx = ex_idx;
                        break;
                    }
                }

                if (found_idx) |ex_idx| {
                    used[ex_idx] = true;
                    matched += 1;

                    const ex_layer = existing_layers[ex_idx];
                    if (std.meta.activeTag(ex_layer.node.*) == std.meta.activeTag(inc_layer.node.*)) {
                        stats.reused += 1;
                        try morphNodeLeaky(allocator, ex_layer.node, inc_layer.node.*, stats);
                        next_layers[out_idx] = .{
                            .node = ex_layer.node,
                            .anchor = inc_layer.anchor,
                            .placement = inc_layer.placement,
                            .align_ = inc_layer.align_,
                            .offset_x = inc_layer.offset_x,
                            .offset_y = inc_layer.offset_y,
                            .w = inc_layer.w,
                            .h = inc_layer.h,
                            .clip = inc_layer.clip,
                            .modal = inc_layer.modal,
                        };
                    } else {
                        stats.type_mismatch += 1;
                        stats.replaced += 1;
                        next_layers[out_idx] = inc_layer;
                    }
                } else {
                    stats.inserted += 1;
                    next_layers[out_idx] = inc_layer;
                }
            }

            stats.removed += existing_layers.len - matched;
            o.layers = next_layers;
        },
        .list => |*l| {
            const inc = incoming.list;
            const existing_children = l.children;

            l.w = inc.w;
            l.h = inc.h;
            l.flex = inc.flex;
            l.height = inc.height;
            l.align_self = inc.align_self;
            l.hoverable = inc.hoverable;
            l.mouseable = inc.mouseable;
            l.disabled = inc.disabled;
            l.readonly = inc.readonly;
            l.validation = inc.validation;
            l.focusable = inc.focusable;
            l.focus_scope = inc.focus_scope;
            l.marker = inc.marker;
            l.style = inc.style;

            var used = try allocator.alloc(bool, existing_children.len);
            @memset(used, false);

            var next_children = try allocator.alloc(protocol.Node, inc.children.len);
            var matched: usize = 0;

            for (inc.children, 0..) |inc_child, out_idx| {
                const inc_id = nodeId(inc_child);
                var found_idx: ?usize = null;

                for (existing_children, 0..) |ex_child, ex_idx| {
                    if (used[ex_idx]) continue;
                    if (std.mem.eql(u8, nodeId(ex_child), inc_id)) {
                        found_idx = ex_idx;
                        break;
                    }
                }

                if (found_idx) |ex_idx| {
                    used[ex_idx] = true;
                    matched += 1;

                    const ex_child = existing_children[ex_idx];
                    if (std.meta.activeTag(ex_child) == std.meta.activeTag(inc_child)) {
                        stats.reused += 1;
                        var next_child = ex_child;
                        try morphNodeLeaky(allocator, &next_child, inc_child, stats);
                        next_children[out_idx] = next_child;
                    } else {
                        stats.type_mismatch += 1;
                        stats.replaced += 1;
                        next_children[out_idx] = inc_child;
                    }
                } else {
                    stats.inserted += 1;
                    next_children[out_idx] = inc_child;
                }
            }

            stats.removed += existing_children.len - matched;
            l.children = next_children;
        },
    }
}

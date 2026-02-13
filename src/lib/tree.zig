const std = @import("std");
const protocol = @import("protocol/mod.zig");

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

const PathStepKind = enum(u8) {
    vbox_child,
    hbox_child,
    grid_child,
    list_child,
    box_child,
    scroll_child,
    overlay_base,
    overlay_layer,
};

const PathStep = struct {
    kind: PathStepKind,
    index: usize = 0,
};

const IndexedPath = struct {
    steps: []PathStep,
};

pub const IdIndex = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap(IndexedPath),

    pub fn init(allocator: std.mem.Allocator) IdIndex {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap(IndexedPath).init(allocator),
        };
    }

    pub fn deinit(self: *IdIndex) void {
        self.clear();
        self.entries.deinit();
    }

    pub fn clear(self: *IdIndex) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.steps);
        }
        self.entries.clearRetainingCapacity();
    }

    pub fn rebuild(self: *IdIndex, root: *protocol.Node) !void {
        self.clear();
        var stack: std.ArrayList(PathStep) = .empty;
        defer stack.deinit(self.allocator);
        try self.collect(root, &stack);
    }

    pub fn contains(self: *const IdIndex, id: []const u8) bool {
        return self.entries.contains(id);
    }

    pub fn findNodePtr(self: *const IdIndex, root: *protocol.Node, id: []const u8) ?*protocol.Node {
        const path = self.entries.get(id) orelse return findNodePtrById(root, id);
        if (resolvePath(root, path.steps)) |ptr| {
            if (std.mem.eql(u8, nodeId(ptr.*), id)) return ptr;
        }
        return findNodePtrById(root, id);
    }

    fn collect(self: *IdIndex, node: *protocol.Node, stack: *std.ArrayList(PathStep)) !void {
        const path_copy = try self.allocator.dupe(PathStep, stack.items);
        try self.entries.put(nodeId(node.*), .{ .steps = path_copy });

        switch (node.*) {
            .vbox => |*v| {
                for (v.children, 0..) |*child, idx| {
                    try stack.append(self.allocator, .{
                        .kind = .vbox_child,
                        .index = idx,
                    });
                    try self.collect(child, stack);
                    _ = stack.pop();
                }
            },
            .hbox => |*h| {
                for (h.children, 0..) |*child, idx| {
                    try stack.append(self.allocator, .{
                        .kind = .hbox_child,
                        .index = idx,
                    });
                    try self.collect(child, stack);
                    _ = stack.pop();
                }
            },
            .grid => |*g| {
                for (g.children, 0..) |*child, idx| {
                    try stack.append(self.allocator, .{
                        .kind = .grid_child,
                        .index = idx,
                    });
                    try self.collect(child, stack);
                    _ = stack.pop();
                }
            },
            .list => |*l| {
                for (l.children, 0..) |*child, idx| {
                    try stack.append(self.allocator, .{
                        .kind = .list_child,
                        .index = idx,
                    });
                    try self.collect(child, stack);
                    _ = stack.pop();
                }
            },
            .vlist => |*l| {
                for (l.children, 0..) |*child, idx| {
                    try stack.append(self.allocator, .{
                        .kind = .list_child,
                        .index = idx,
                    });
                    try self.collect(child, stack);
                    _ = stack.pop();
                }
            },
            .box => |*b| {
                try stack.append(self.allocator, .{ .kind = .box_child });
                try self.collect(b.child, stack);
                _ = stack.pop();
            },
            .scroll => |*s| {
                try stack.append(self.allocator, .{ .kind = .scroll_child });
                try self.collect(s.child, stack);
                _ = stack.pop();
            },
            .overlay => |*o| {
                try stack.append(self.allocator, .{ .kind = .overlay_base });
                try self.collect(o.base, stack);
                _ = stack.pop();
                for (o.layers, 0..) |*layer, idx| {
                    try stack.append(self.allocator, .{
                        .kind = .overlay_layer,
                        .index = idx,
                    });
                    try self.collect(layer.node, stack);
                    _ = stack.pop();
                }
            },
            else => {},
        }
    }
};

pub fn applyPatchByIdIndexed(
    root: *protocol.Node,
    index: *const IdIndex,
    target: []const u8,
    replacement: protocol.Node,
) bool {
    if (index.findNodePtr(root, target)) |ptr| {
        ptr.* = replacement;
        return true;
    }
    return applyPatchById(root, target, replacement);
}

pub fn morphPatchByIdLeakyIndexed(
    allocator: std.mem.Allocator,
    root: *protocol.Node,
    index: *const IdIndex,
    target: []const u8,
    incoming: protocol.Node,
    stats: *MorphStats,
) std.mem.Allocator.Error!bool {
    if (index.findNodePtr(root, target)) |ptr| {
        try morphNodeLeaky(allocator, ptr, incoming, stats);
        return true;
    }
    return morphPatchByIdLeaky(allocator, root, target, incoming, stats);
}

fn resolvePath(root: *protocol.Node, steps: []const PathStep) ?*protocol.Node {
    var cur = root;
    for (steps) |step| {
        switch (step.kind) {
            .vbox_child => {
                switch (cur.*) {
                    .vbox => |*v| {
                        const idx = step.index;
                        if (idx >= v.children.len) return null;
                        cur = &v.children[idx];
                    },
                    else => return null,
                }
            },
            .hbox_child => {
                switch (cur.*) {
                    .hbox => |*h| {
                        const idx = step.index;
                        if (idx >= h.children.len) return null;
                        cur = &h.children[idx];
                    },
                    else => return null,
                }
            },
            .grid_child => {
                switch (cur.*) {
                    .grid => |*g| {
                        const idx = step.index;
                        if (idx >= g.children.len) return null;
                        cur = &g.children[idx];
                    },
                    else => return null,
                }
            },
            .list_child => {
                switch (cur.*) {
                    .list => |*l| {
                        const idx = step.index;
                        if (idx >= l.children.len) return null;
                        cur = &l.children[idx];
                    },
                    .vlist => |*l| {
                        const idx = step.index;
                        if (idx >= l.children.len) return null;
                        cur = &l.children[idx];
                    },
                    else => return null,
                }
            },
            .box_child => {
                switch (cur.*) {
                    .box => |*b| cur = b.child,
                    else => return null,
                }
            },
            .scroll_child => {
                switch (cur.*) {
                    .scroll => |*s| cur = s.child,
                    else => return null,
                }
            },
            .overlay_base => {
                switch (cur.*) {
                    .overlay => |*o| cur = o.base,
                    else => return null,
                }
            },
            .overlay_layer => {
                switch (cur.*) {
                    .overlay => |*o| {
                        const idx = step.index;
                        if (idx >= o.layers.len) return null;
                        cur = o.layers[idx].node;
                    },
                    else => return null,
                }
            },
        }
    }
    return cur;
}

fn findNodePtrById(root: *protocol.Node, id: []const u8) ?*protocol.Node {
    if (std.mem.eql(u8, nodeId(root.*), id)) return root;
    return switch (root.*) {
        .vbox => |*v| blk: {
            for (v.children) |*child| {
                if (findNodePtrById(child, id)) |ptr| break :blk ptr;
            }
            break :blk null;
        },
        .hbox => |*h| blk: {
            for (h.children) |*child| {
                if (findNodePtrById(child, id)) |ptr| break :blk ptr;
            }
            break :blk null;
        },
        .grid => |*g| blk: {
            for (g.children) |*child| {
                if (findNodePtrById(child, id)) |ptr| break :blk ptr;
            }
            break :blk null;
        },
        .box => |*b| findNodePtrById(b.child, id),
        .scroll => |*s| findNodePtrById(s.child, id),
        .overlay => |*o| blk: {
            if (findNodePtrById(o.base, id)) |ptr| break :blk ptr;
            for (o.layers) |*layer| {
                if (findNodePtrById(layer.node, id)) |ptr| break :blk ptr;
            }
            break :blk null;
        },
        .list => |*l| blk: {
            for (l.children) |*child| {
                if (findNodePtrById(child, id)) |ptr| break :blk ptr;
            }
            break :blk null;
        },
        .vlist => |*l| blk: {
            for (l.children) |*child| {
                if (findNodePtrById(child, id)) |ptr| break :blk ptr;
            }
            break :blk null;
        },
        else => null,
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
        .grid => |g| {
            for (g.children) |child| {
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
        .vlist => |l| {
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
        .grid => |*g| {
            for (g.children) |*child| {
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
        .vlist => |*l| {
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
        .grid => |*g| {
            for (g.children) |*child| {
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
        .vlist => |*l| {
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
            t.class = inc.class;
            t.w = inc.w;
            t.h = inc.h;
            t.min_w = inc.min_w;
            t.max_w = inc.max_w;
            t.min_h = inc.min_h;
            t.max_h = inc.max_h;
            t.w_pct = inc.w_pct;
            t.h_pct = inc.h_pct;
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
            t.grid_row = inc.grid_row;
            t.grid_col = inc.grid_col;
            t.row_span = inc.row_span;
            t.col_span = inc.col_span;
            t.grid_area = inc.grid_area;
            t.style = inc.style;
            t.overflow = inc.overflow;
            t.text = inc.text;
        },
        .styled_text => |*t| {
            const inc = incoming.styled_text;
            t.class = inc.class;
            t.w = inc.w;
            t.h = inc.h;
            t.min_w = inc.min_w;
            t.max_w = inc.max_w;
            t.min_h = inc.min_h;
            t.max_h = inc.max_h;
            t.w_pct = inc.w_pct;
            t.h_pct = inc.h_pct;
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
            t.grid_row = inc.grid_row;
            t.grid_col = inc.grid_col;
            t.row_span = inc.row_span;
            t.col_span = inc.col_span;
            t.grid_area = inc.grid_area;
            t.style = inc.style;
            t.overflow = inc.overflow;
            t.spans = inc.spans;
        },
        .input => |*i| {
            const inc = incoming.input;
            i.class = inc.class;
            i.w = inc.w;
            i.h = inc.h;
            i.min_w = inc.min_w;
            i.max_w = inc.max_w;
            i.min_h = inc.min_h;
            i.max_h = inc.max_h;
            i.w_pct = inc.w_pct;
            i.h_pct = inc.h_pct;
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
            i.grid_row = inc.grid_row;
            i.grid_col = inc.grid_col;
            i.row_span = inc.row_span;
            i.col_span = inc.col_span;
            i.grid_area = inc.grid_area;
            i.style = inc.style;
            i.placeholder_style = inc.placeholder_style;
            i.placeholder = inc.placeholder;
        },
        .textarea => |*t| {
            const inc = incoming.textarea;
            t.class = inc.class;
            t.w = inc.w;
            t.h = inc.h;
            t.min_w = inc.min_w;
            t.max_w = inc.max_w;
            t.min_h = inc.min_h;
            t.max_h = inc.max_h;
            t.w_pct = inc.w_pct;
            t.h_pct = inc.h_pct;
            t.flex = inc.flex;
            t.align_self = inc.align_self;
            t.hoverable = inc.hoverable;
            t.mouseable = inc.mouseable;
            t.disabled = inc.disabled;
            t.readonly = inc.readonly;
            t.validation = inc.validation;
            t.focusable = inc.focusable;
            t.focus_scope = inc.focus_scope;
            t.grid_row = inc.grid_row;
            t.grid_col = inc.grid_col;
            t.row_span = inc.row_span;
            t.col_span = inc.col_span;
            t.grid_area = inc.grid_area;
            t.style = inc.style;
            t.selection_style = inc.selection_style;
            t.placeholder_style = inc.placeholder_style;
            t.placeholder = inc.placeholder;
        },
        .vbox => |*v| {
            const inc = incoming.vbox;
            const existing_children = v.children;

            v.class = inc.class;
            v.w = inc.w;
            v.h = inc.h;
            v.min_w = inc.min_w;
            v.max_w = inc.max_w;
            v.min_h = inc.min_h;
            v.max_h = inc.max_h;
            v.w_pct = inc.w_pct;
            v.h_pct = inc.h_pct;
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
            v.grid_row = inc.grid_row;
            v.grid_col = inc.grid_col;
            v.row_span = inc.row_span;
            v.col_span = inc.col_span;
            v.grid_area = inc.grid_area;
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

            h.class = inc.class;
            h.w = inc.w;
            h.h = inc.h;
            h.min_w = inc.min_w;
            h.max_w = inc.max_w;
            h.min_h = inc.min_h;
            h.max_h = inc.max_h;
            h.w_pct = inc.w_pct;
            h.h_pct = inc.h_pct;
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
            h.grid_row = inc.grid_row;
            h.grid_col = inc.grid_col;
            h.row_span = inc.row_span;
            h.col_span = inc.col_span;
            h.grid_area = inc.grid_area;
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
        .grid => |*g| {
            const inc = incoming.grid;
            const existing_children = g.children;

            g.class = inc.class;
            g.w = inc.w;
            g.h = inc.h;
            g.min_w = inc.min_w;
            g.max_w = inc.max_w;
            g.min_h = inc.min_h;
            g.max_h = inc.max_h;
            g.w_pct = inc.w_pct;
            g.h_pct = inc.h_pct;
            g.flex = inc.flex;
            g.pad = inc.pad;
            g.clip = inc.clip;
            g.hoverable = inc.hoverable;
            g.mouseable = inc.mouseable;
            g.disabled = inc.disabled;
            g.readonly = inc.readonly;
            g.validation = inc.validation;
            g.focusable = inc.focusable;
            g.focus_scope = inc.focus_scope;
            g.align_self = inc.align_self;
            g.grid_row = inc.grid_row;
            g.grid_col = inc.grid_col;
            g.row_span = inc.row_span;
            g.col_span = inc.col_span;
            g.grid_area = inc.grid_area;
            g.gap_x = inc.gap_x;
            g.gap_y = inc.gap_y;
            g.rows = inc.rows;
            g.cols = inc.cols;
            g.areas = inc.areas;
            g.style = inc.style;

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
            g.children = next_children;
        },
        .box => |*b| {
            const inc = incoming.box;
            b.class = inc.class;
            b.w = inc.w;
            b.h = inc.h;
            b.min_w = inc.min_w;
            b.max_w = inc.max_w;
            b.min_h = inc.min_h;
            b.max_h = inc.max_h;
            b.w_pct = inc.w_pct;
            b.h_pct = inc.h_pct;
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
            b.grid_row = inc.grid_row;
            b.grid_col = inc.grid_col;
            b.row_span = inc.row_span;
            b.col_span = inc.col_span;
            b.grid_area = inc.grid_area;
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
            s.class = inc.class;
            s.w = inc.w;
            s.h = inc.h;
            s.min_w = inc.min_w;
            s.max_w = inc.max_w;
            s.min_h = inc.min_h;
            s.max_h = inc.max_h;
            s.w_pct = inc.w_pct;
            s.h_pct = inc.h_pct;
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
            s.grid_row = inc.grid_row;
            s.grid_col = inc.grid_col;
            s.row_span = inc.row_span;
            s.col_span = inc.col_span;
            s.grid_area = inc.grid_area;
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

            o.class = inc.class;
            o.w = inc.w;
            o.h = inc.h;
            o.min_w = inc.min_w;
            o.max_w = inc.max_w;
            o.min_h = inc.min_h;
            o.max_h = inc.max_h;
            o.w_pct = inc.w_pct;
            o.h_pct = inc.h_pct;
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
            o.grid_row = inc.grid_row;
            o.grid_col = inc.grid_col;
            o.row_span = inc.row_span;
            o.col_span = inc.col_span;
            o.grid_area = inc.grid_area;
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

            l.class = inc.class;
            l.w = inc.w;
            l.h = inc.h;
            l.min_w = inc.min_w;
            l.max_w = inc.max_w;
            l.min_h = inc.min_h;
            l.max_h = inc.max_h;
            l.w_pct = inc.w_pct;
            l.h_pct = inc.h_pct;
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
            l.grid_row = inc.grid_row;
            l.grid_col = inc.grid_col;
            l.row_span = inc.row_span;
            l.col_span = inc.col_span;
            l.grid_area = inc.grid_area;
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
        .vlist => |*l| {
            const inc = incoming.vlist;
            const existing_children = l.children;

            l.class = inc.class;
            l.w = inc.w;
            l.h = inc.h;
            l.min_w = inc.min_w;
            l.max_w = inc.max_w;
            l.min_h = inc.min_h;
            l.max_h = inc.max_h;
            l.w_pct = inc.w_pct;
            l.h_pct = inc.h_pct;
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
            l.grid_row = inc.grid_row;
            l.grid_col = inc.grid_col;
            l.row_span = inc.row_span;
            l.col_span = inc.col_span;
            l.grid_area = inc.grid_area;
            l.style = inc.style;
            l.state_mode = inc.state_mode;
            l.selected_index = inc.selected_index;
            l.scroll = inc.scroll;
            l.total = inc.total;
            l.window_start = inc.window_start;
            l.item_id_prefix = inc.item_id_prefix;
            l.overscan = inc.overscan;
            l.req = inc.req;

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

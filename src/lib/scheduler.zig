const std = @import("std");
const protocol = @import("protocol/mod.zig");
const tree = @import("tree.zig");

pub const Counts = struct {
    pending_full: bool,
    pending_targets: usize,
    coalesced_full: u64,
    coalesced_targets: u64,
    dropped_targets: u64,
};

pub const FlushResult = struct {
    full_applied: bool = false,
    targets_pending: usize = 0,
    targets_applied: usize = 0,
    targets_found: usize = 0,
    targets_not_found: usize = 0,
    replace_count: usize = 0,
    morph_count: usize = 0,
    morph_stats: tree.MorphStats = .{},
    dropped_targets: u64 = 0,
};

pub const PutResult = enum {
    stored_new,
    stored_overwrite,
    dropped_overflow,
};

const PendingFull = struct {
    arena: std.heap.ArenaAllocator,
    root: protocol.Node,
};

const PendingTarget = struct {
    arena: std.heap.ArenaAllocator,
    target: []const u8,
    node: protocol.Node,
    mode: protocol.PatchMode,
};

pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    max_pending_targets: usize,
    pending_full: ?*PendingFull = null,
    pending_targets: std.StringHashMap(*PendingTarget),
    coalesced_full: u64 = 0,
    coalesced_targets: u64 = 0,
    dropped_targets: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, max_pending_targets: usize) Scheduler {
        return .{
            .allocator = allocator,
            .max_pending_targets = max_pending_targets,
            .pending_targets = std.StringHashMap(*PendingTarget).init(allocator),
        };
    }

    pub fn deinit(self: *Scheduler) void {
        self.clearPendingTargets();
        self.pending_targets.deinit();
        if (self.pending_full) |p| {
            p.arena.deinit();
            self.allocator.destroy(p);
            self.pending_full = null;
        }
    }

    pub fn counts(self: *const Scheduler) Counts {
        return .{
            .pending_full = self.pending_full != null,
            .pending_targets = self.pending_targets.count(),
            .coalesced_full = self.coalesced_full,
            .coalesced_targets = self.coalesced_targets,
            .dropped_targets = self.dropped_targets,
        };
    }

    pub fn hasPending(self: *const Scheduler) bool {
        return self.pending_full != null or self.pending_targets.count() > 0;
    }

    pub fn hasPendingFull(self: *const Scheduler) bool {
        return self.pending_full != null;
    }

    pub fn putFullLeaky(self: *Scheduler, arena: *std.heap.ArenaAllocator, root: protocol.Node) !void {
        if (self.pending_full) |p| {
            self.coalesced_full += 1;
            p.arena.deinit();
            self.allocator.destroy(p);
            self.pending_full = null;
        }

        // Full snapshot supersedes any pending targets.
        self.clearPendingTargets();

        const p = try self.allocator.create(PendingFull);
        p.* = .{
            .arena = takeArena(self.allocator, arena),
            .root = root,
        };
        self.pending_full = p;
    }

    pub fn putTargetLeaky(
        self: *Scheduler,
        arena: *std.heap.ArenaAllocator,
        target: []const u8,
        node: protocol.Node,
        mode: protocol.PatchMode,
    ) !PutResult {
        if (self.pending_targets.contains(target)) {
            self.coalesced_targets += 1;
            const old = self.pending_targets.fetchRemove(target).?.value;
            destroyTarget(self.allocator, old);
            const p = try self.allocator.create(PendingTarget);
            p.* = .{
                .arena = takeArena(self.allocator, arena),
                .target = target,
                .node = node,
                .mode = mode,
            };
            try self.pending_targets.put(target, p);
            return .stored_overwrite;
        }

        if (self.pending_targets.count() >= self.max_pending_targets) {
            self.dropped_targets += 1;
            return .dropped_overflow;
        }

        const p = try self.allocator.create(PendingTarget);
        p.* = .{
            .arena = takeArena(self.allocator, arena),
            .target = target,
            .node = node,
            .mode = mode,
        };
        try self.pending_targets.put(target, p);
        return .stored_new;
    }

    pub fn flushApplyLeaky(
        self: *Scheduler,
        allocator: std.mem.Allocator,
        current_arena: *std.heap.ArenaAllocator,
        current_root: *?protocol.Node,
    ) !FlushResult {
        var res: FlushResult = .{
            .dropped_targets = self.dropped_targets,
            .targets_pending = self.pending_targets.count(),
        };

        if (self.pending_full) |p| {
            current_arena.deinit();
            current_arena.* = p.arena;
            p.arena = std.heap.ArenaAllocator.init(self.allocator);
            current_root.* = p.root;
            self.allocator.destroy(p);
            self.pending_full = null;
            res.full_applied = true;
        }

        if (self.pending_targets.count() == 0) return res;

        if (current_root.* == null) {
            res.targets_not_found = self.pending_targets.count();
            self.clearPendingTargets();
            return res;
        }

        var keys: std.ArrayList([]const u8) = .empty;
        defer keys.deinit(allocator);
        try keys.ensureTotalCapacityPrecise(allocator, self.pending_targets.count());
        var it = self.pending_targets.iterator();
        while (it.next()) |entry| {
            try keys.append(allocator, entry.key_ptr.*);
        }

        std.sort.pdq([]const u8, keys.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        for (keys.items) |key| {
            const kv = self.pending_targets.fetchRemove(key) orelse continue;
            const p = kv.value;
            defer destroyTarget(self.allocator, p);

            const cloned = try cloneNodeLeaky(current_arena.allocator(), p.node);
            var found: bool = false;
            switch (p.mode) {
                .replace => {
                    found = tree.applyPatchById(&current_root.*.?, p.target, cloned);
                    res.replace_count += 1;
                },
                .morph => {
                    var stats: tree.MorphStats = .{};
                    found = try tree.morphPatchByIdLeaky(
                        current_arena.allocator(),
                        &current_root.*.?,
                        p.target,
                        cloned,
                        &stats,
                    );
                    res.morph_count += 1;
                    res.morph_stats.reused += stats.reused;
                    res.morph_stats.inserted += stats.inserted;
                    res.morph_stats.removed += stats.removed;
                    res.morph_stats.replaced += stats.replaced;
                    res.morph_stats.type_mismatch += stats.type_mismatch;
                },
            }

            res.targets_applied += 1;
            if (found) {
                res.targets_found += 1;
            } else {
                res.targets_not_found += 1;
            }
        }

        return res;
    }

    fn clearPendingTargets(self: *Scheduler) void {
        while (self.pending_targets.count() > 0) {
            var it = self.pending_targets.iterator();
            const entry = it.next() orelse break;
            const key = entry.key_ptr.*;
            const removed = self.pending_targets.fetchRemove(key) orelse break;
            destroyTarget(self.allocator, removed.value);
        }
    }
};

fn takeArena(parent: std.mem.Allocator, arena: *std.heap.ArenaAllocator) std.heap.ArenaAllocator {
    const moved = arena.*;
    arena.* = std.heap.ArenaAllocator.init(parent);
    return moved;
}

fn destroyTarget(allocator: std.mem.Allocator, p: *PendingTarget) void {
    p.arena.deinit();
    allocator.destroy(p);
}

fn cloneNodeLeaky(allocator: std.mem.Allocator, node: protocol.Node) !protocol.Node {
    return switch (node) {
        .text => |t| .{ .text = .{
            .id = try allocator.dupe(u8, t.id),
            .w = t.w,
            .h = t.h,
            .flex = t.flex,
            .align_self = t.align_self,
            .hoverable = t.hoverable,
            .ext_align = t.ext_align,
            .v_align = t.v_align,
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
                .align_self = t.align_self,
                .hoverable = t.hoverable,
                .ext_align = t.ext_align,
                .v_align = t.v_align,
                .style = t.style,
                .spans = spans,
            } };
        },
        .input => |i| .{ .input = .{
            .id = try allocator.dupe(u8, i.id),
            .w = i.w,
            .h = i.h,
            .flex = i.flex,
            .align_self = i.align_self,
            .hoverable = i.hoverable,
            .content_align = i.content_align,
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
                .hoverable = v.hoverable,
                .justify_content = v.justify_content,
                .align_items = v.align_items,
                .gap = v.gap,
                .align_self = v.align_self,
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
                .hoverable = h.hoverable,
                .justify_content = h.justify_content,
                .align_items = h.align_items,
                .gap = h.gap,
                .align_self = h.align_self,
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
            .hoverable = b.hoverable,
            .align_self = b.align_self,
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
            .hoverable = s.hoverable,
            .align_self = s.align_self,
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
                .hoverable = o.hoverable,
                .align_self = o.align_self,
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
                .align_self = l.align_self,
                .hoverable = l.hoverable,
                .style = l.style,
                .children = children,
            } };
        },
    };
}

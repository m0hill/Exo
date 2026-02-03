const std = @import("std");

const protocol = @import("../protocol.zig");

const common = @import("common.zig");
const inline_mod = @import("inline.zig");
const types = @import("types.zig");

pub const StreamBlocks = struct {
    pub const TailPolicy = enum {
        /// A2.1: render the in-progress block as plain text.
        plain,
        /// A2.2-ish: render the in-progress block using inline parsing.
        inline_parse,
    };

    pub const Caps = struct {
        max_doc_bytes: usize = 256 * 1024,
        max_blocks: usize = 5000,
    };

    pub const PushResult = struct {
        blocks_committed: usize = 0,
        tail_key_changed: bool = false,
        truncated: bool = false,
    };

    pub const TailKind = enum {
        none,
        paragraph,
        heading,
        list_item,
        blockquote,
    };

    pub const TailKey = struct {
        kind: TailKind = .none,
        level: u8 = 0,
        idx: usize = 0,
    };

    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    opts: types.Options,
    caps: Caps,
    tail_policy: TailPolicy,

    // Deterministic counters match compileLeaky.
    blank_idx: usize = 0,
    para_idx: usize = 0,
    heading_idx: usize = 0,
    li_idx: usize = 0,
    bq_idx: usize = 0,

    // Committed blocks are compiled and stored in the arena allocator.
    committed: std.ArrayList(protocol.Node) = .empty,

    // Pending paragraph lines (completed lines not yet flushed into a paragraph node).
    pending_para: std.ArrayList([]const u8) = .empty,

    // Current in-progress line (no trailing '\n').
    current_line: std.ArrayList(u8) = .empty,

    // Caps/backpressure state.
    doc_bytes: usize = 0,
    truncated: bool = false,

    // Tail identity for patch strategies.
    tail_key: TailKey = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        opts: types.Options,
        caps: Caps,
        tail_policy: TailPolicy,
    ) StreamBlocks {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .opts = opts,
            .caps = caps,
            .tail_policy = tail_policy,
        };
    }

    pub fn deinit(self: *StreamBlocks) void {
        self.committed.deinit(self.arena.allocator());
        self.pending_para.deinit(self.allocator);
        self.current_line.deinit(self.allocator);
        self.arena.deinit();
    }

    pub fn reset(self: *StreamBlocks) void {
        self.blank_idx = 0;
        self.para_idx = 0;
        self.heading_idx = 0;
        self.li_idx = 0;
        self.bq_idx = 0;
        self.doc_bytes = 0;
        self.truncated = false;
        self.tail_key = .{};

        _ = self.arena.reset(.retain_capacity);
        self.committed = .empty;
        self.pending_para.clearRetainingCapacity();
        self.current_line.clearRetainingCapacity();
    }

    pub fn tailKey(self: *const StreamBlocks) TailKey {
        return self.tail_key;
    }

    pub fn push(self: *StreamBlocks, chunk: []const u8) types.CompileError!PushResult {
        var res: PushResult = .{};
        if (self.truncated) {
            res.truncated = true;
            return res;
        }

        const old_tail = self.tail_key;

        for (chunk) |b| {
            if (self.truncated) break;
            if (self.doc_bytes >= self.caps.max_doc_bytes) {
                self.truncated = true;
                res.truncated = true;
                break;
            }

            if (b == '\n') {
                // Finalize line.
                const line_raw = common.trimCr(self.current_line.items);
                try self.processCompletedLine(&res, line_raw);
                self.current_line.clearRetainingCapacity();
                continue;
            }

            try self.current_line.append(self.allocator, b);
            self.doc_bytes += 1;

            // If we're in a paragraph and the next line clearly starts a non-paragraph block,
            // flush the paragraph early so the tail doesn't temporarily "eat" the next block.
            if (self.pending_para.items.len != 0) {
                if (detectSpecialLineKind(self.current_line.items)) |_| {
                    if (try self.flushParagraph()) {
                        res.blocks_committed += 1;
                    }
                }
            }
        }

        self.updateTailKey();
        res.tail_key_changed = !std.meta.eql(old_tail, self.tail_key);
        res.truncated = res.truncated or self.truncated;
        return res;
    }

    pub fn finish(self: *StreamBlocks) types.CompileError!PushResult {
        var res: PushResult = .{};
        if (self.truncated) {
            res.truncated = true;
            return res;
        }

        const old_tail = self.tail_key;

        // Treat the current line as completed without requiring a trailing '\n'.
        if (self.current_line.items.len != 0) {
            const line_raw = common.trimCr(self.current_line.items);
            try self.processCompletedLine(&res, line_raw);
            self.current_line.clearRetainingCapacity();
        }

        if (try self.flushParagraph()) res.blocks_committed += 1;

        self.updateTailKey();
        res.tail_key_changed = !std.meta.eql(old_tail, self.tail_key);
        res.truncated = res.truncated or self.truncated;
        return res;
    }

    pub fn snapshotLeaky(self: *const StreamBlocks, arena_tx: std.mem.Allocator) types.CompileError!protocol.Node {
        var children: std.ArrayList(protocol.Node) = .empty;
        defer children.deinit(arena_tx);

        try children.appendSlice(arena_tx, self.committed.items);

        if (self.tailNodeLeaky(arena_tx)) |tail| {
            try children.append(arena_tx, tail);
        }

        return .{
            .vbox = .{
                .id = self.opts.id,
                .children = try children.toOwnedSlice(arena_tx),
            },
        };
    }

    pub fn tailNodeLeaky(self: *const StreamBlocks, arena_tx: std.mem.Allocator) ?protocol.Node {
        const tail = self.computeTailKind();
        if (tail.kind == .none) return null;

        const prefix = if (self.opts.id_prefix.len == 0) self.opts.id else self.opts.id_prefix;

        switch (tail.kind) {
            .paragraph => {
                const id = std.fmt.allocPrint(arena_tx, "{s}-p-{d}", .{ prefix, tail.idx }) catch return null;
                if (self.tail_policy == .plain) {
                    const raw = self.pendingParagraphRawLeaky(arena_tx) catch return null;
                    return .{ .text = .{ .id = id, .text = raw } };
                }

                const spans = self.pendingParagraphSpansLeaky(arena_tx) catch return null;
                return .{ .styled_text = .{ .id = id, .spans = spans } };
            },
            .heading => {
                const id = std.fmt.allocPrint(arena_tx, "{s}-h{d}-{d}", .{ prefix, tail.level, tail.idx }) catch return null;
                if (self.tail_policy == .plain) {
                    const raw = std.fmt.allocPrint(arena_tx, "{s}", .{common.trimCr(self.current_line.items)}) catch return null;
                    return .{ .text = .{ .id = id, .text = raw } };
                }

                const line = common.trimCr(self.current_line.items);
                const h = common.parseHeading(line) orelse return .{ .text = .{ .id = id, .text = line } };
                const spans = inline_mod.compileInlineSpansLeaky(arena_tx, h.text, .{
                    .sanitize_control = self.opts.sanitize_control,
                    .own_text = self.opts.own_text,
                    .max_spans = self.opts.max_spans,
                    .theme = self.opts.theme,
                }) catch return null;

                return .{
                    .styled_text = .{
                        .id = id,
                        .style = self.opts.theme.heading,
                        .spans = spans,
                    },
                };
            },
            .list_item => {
                const id = std.fmt.allocPrint(arena_tx, "{s}-li-{d}", .{ prefix, tail.idx }) catch return null;
                if (self.tail_policy == .plain) {
                    const raw = std.fmt.allocPrint(arena_tx, "{s}", .{common.trimCr(self.current_line.items)}) catch return null;
                    return .{ .text = .{ .id = id, .text = raw } };
                }

                const line = common.trimCr(self.current_line.items);
                const li = common.parseListItem(line) orelse return .{ .text = .{ .id = id, .text = line } };
                return compileListItemNodeLeaky(arena_tx, id, li.text, self.opts) catch return null;
            },
            .blockquote => {
                const id = std.fmt.allocPrint(arena_tx, "{s}-bq-{d}", .{ prefix, tail.idx }) catch return null;
                if (self.tail_policy == .plain) {
                    const raw = std.fmt.allocPrint(arena_tx, "{s}", .{common.trimCr(self.current_line.items)}) catch return null;
                    return .{ .text = .{ .id = id, .text = raw } };
                }

                const line = common.trimCr(self.current_line.items);
                const bq = common.parseBlockquote(line) orelse return .{ .text = .{ .id = id, .text = line } };
                return compileBlockquoteNodeLeaky(arena_tx, id, bq.text, self.opts) catch return null;
            },
            .none => return null,
        }
    }

    fn updateTailKey(self: *StreamBlocks) void {
        self.tail_key = self.computeTailKind();
    }

    fn computeTailKind(self: *const StreamBlocks) TailKey {
        if (self.pending_para.items.len != 0) {
            return .{ .kind = .paragraph, .idx = self.para_idx };
        }

        const line = common.trimCr(self.current_line.items);
        if (line.len == 0) return .{};

        if (common.parseHeading(line)) |h| return .{ .kind = .heading, .level = h.level, .idx = self.heading_idx };
        if (common.parseListItem(line)) |_| return .{ .kind = .list_item, .idx = self.li_idx };
        if (common.parseBlockquote(line)) |_| return .{ .kind = .blockquote, .idx = self.bq_idx };
        return .{ .kind = .paragraph, .idx = self.para_idx };
    }

    fn processCompletedLine(self: *StreamBlocks, res: *PushResult, line_raw: []const u8) types.CompileError!void {
        // Enforce max blocks conservatively: if we're at/over the cap, stop accepting more.
        if (self.committed.items.len >= self.caps.max_blocks) {
            self.truncated = true;
            res.truncated = true;
            return;
        }

        if (common.isBlank(line_raw)) {
            if (try self.flushParagraph()) res.blocks_committed += 1;
            try self.commitBlank();
            res.blocks_committed += 1;
            return;
        }

        if (common.parseHeading(line_raw)) |h| {
            if (try self.flushParagraph()) res.blocks_committed += 1;
            const text_copy = try self.arena.allocator().dupe(u8, h.text);
            try self.commitHeading(h.level, text_copy);
            res.blocks_committed += 1;
            return;
        }

        if (common.parseListItem(line_raw)) |li| {
            if (try self.flushParagraph()) res.blocks_committed += 1;
            const text_copy = try self.arena.allocator().dupe(u8, li.text);
            try self.commitListItem(text_copy);
            res.blocks_committed += 1;
            return;
        }

        if (common.parseBlockquote(line_raw)) |bq| {
            if (try self.flushParagraph()) res.blocks_committed += 1;
            const text_copy = try self.arena.allocator().dupe(u8, bq.text);
            try self.commitBlockquote(text_copy);
            res.blocks_committed += 1;
            return;
        }

        const line_copy = try self.arena.allocator().dupe(u8, line_raw);
        try self.pending_para.append(self.allocator, line_copy);
    }

    fn flushParagraph(self: *StreamBlocks) types.CompileError!bool {
        if (self.pending_para.items.len == 0) return false;
        if (self.committed.items.len >= self.caps.max_blocks) {
            self.truncated = true;
            return false;
        }

        const arena_alloc = self.arena.allocator();
        const prefix = if (self.opts.id_prefix.len == 0) self.opts.id else self.opts.id_prefix;
        const id = try std.fmt.allocPrint(arena_alloc, "{s}-p-{d}", .{ prefix, self.para_idx });
        self.para_idx += 1;

        const spans = try compileParagraphSpansLeaky(
            arena_alloc,
            self.pending_para.items,
            self.opts.sanitize_control,
            self.opts.own_text,
            self.opts.max_spans,
            self.opts.theme,
        );
        try self.committed.append(arena_alloc, .{ .styled_text = .{ .id = id, .spans = spans } });
        self.pending_para.clearRetainingCapacity();
        return true;
    }

    fn commitBlank(self: *StreamBlocks) types.CompileError!void {
        const arena_alloc = self.arena.allocator();
        const prefix = if (self.opts.id_prefix.len == 0) self.opts.id else self.opts.id_prefix;
        const id = try std.fmt.allocPrint(arena_alloc, "{s}-blank-{d}", .{ prefix, self.blank_idx });
        self.blank_idx += 1;
        try self.committed.append(arena_alloc, .{ .text = .{ .id = id, .h = 1, .text = "" } });
    }

    fn commitHeading(self: *StreamBlocks, level: u8, text: []const u8) types.CompileError!void {
        const arena_alloc = self.arena.allocator();
        const prefix = if (self.opts.id_prefix.len == 0) self.opts.id else self.opts.id_prefix;
        const id = try std.fmt.allocPrint(arena_alloc, "{s}-h{d}-{d}", .{ prefix, level, self.heading_idx });
        self.heading_idx += 1;
        const spans = try inline_mod.compileInlineSpansLeaky(arena_alloc, text, .{
            .sanitize_control = self.opts.sanitize_control,
            .own_text = self.opts.own_text,
            .max_spans = self.opts.max_spans,
            .theme = self.opts.theme,
        });
        try self.committed.append(arena_alloc, .{
            .styled_text = .{
                .id = id,
                .style = self.opts.theme.heading,
                .spans = spans,
            },
        });
    }

    fn commitListItem(self: *StreamBlocks, text: []const u8) types.CompileError!void {
        const arena_alloc = self.arena.allocator();
        const prefix = if (self.opts.id_prefix.len == 0) self.opts.id else self.opts.id_prefix;
        const id = try std.fmt.allocPrint(arena_alloc, "{s}-li-{d}", .{ prefix, self.li_idx });
        self.li_idx += 1;
        const node = try compileListItemNodeLeaky(arena_alloc, id, text, self.opts);
        try self.committed.append(arena_alloc, node);
    }

    fn commitBlockquote(self: *StreamBlocks, text: []const u8) types.CompileError!void {
        const arena_alloc = self.arena.allocator();
        const prefix = if (self.opts.id_prefix.len == 0) self.opts.id else self.opts.id_prefix;
        const id = try std.fmt.allocPrint(arena_alloc, "{s}-bq-{d}", .{ prefix, self.bq_idx });
        self.bq_idx += 1;
        const node = try compileBlockquoteNodeLeaky(arena_alloc, id, text, self.opts);
        try self.committed.append(arena_alloc, node);
    }

    fn pendingParagraphRawLeaky(self: *const StreamBlocks, arena_tx: std.mem.Allocator) types.CompileError![]const u8 {
        if (self.pending_para.items.len == 0) {
            return std.fmt.allocPrint(arena_tx, "{s}", .{common.trimCr(self.current_line.items)});
        }

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(arena_tx);

        for (self.pending_para.items, 0..) |l, i| {
            if (i != 0) try out.append(arena_tx, '\n');
            try out.appendSlice(arena_tx, l);
        }
        const cur = common.trimCr(self.current_line.items);
        if (cur.len != 0) {
            try out.append(arena_tx, '\n');
            try out.appendSlice(arena_tx, cur);
        }
        return out.toOwnedSlice(arena_tx);
    }

    fn pendingParagraphSpansLeaky(self: *const StreamBlocks, arena_tx: std.mem.Allocator) types.CompileError![]protocol.Span {
        var spans: std.ArrayList(protocol.Span) = .empty;
        defer spans.deinit(arena_tx);
        var overflow: bool = false;

        for (self.pending_para.items, 0..) |line, i| {
            if (i != 0) {
                try inline_mod.appendText(
                    arena_tx,
                    &spans,
                    "\n",
                    self.opts.sanitize_control,
                    self.opts.own_text,
                    null,
                    self.opts.max_spans,
                    &overflow,
                );
                if (overflow) break;
            }
            try inline_mod.parseInlineInto(
                arena_tx,
                &spans,
                line,
                self.opts.sanitize_control,
                self.opts.own_text,
                self.opts.theme,
                null,
                self.opts.max_spans,
                &overflow,
            );
            if (overflow) break;
        }

        const cur = common.trimCr(self.current_line.items);
        if (!overflow and cur.len != 0) {
            if (self.pending_para.items.len != 0) {
                try inline_mod.appendText(
                    arena_tx,
                    &spans,
                    "\n",
                    self.opts.sanitize_control,
                    self.opts.own_text,
                    null,
                    self.opts.max_spans,
                    &overflow,
                );
            }
            if (!overflow) {
                try inline_mod.parseInlineInto(
                    arena_tx,
                    &spans,
                    cur,
                    self.opts.sanitize_control,
                    self.opts.own_text,
                    self.opts.theme,
                    null,
                    self.opts.max_spans,
                    &overflow,
                );
            }
        }

        if (overflow) {
            spans.clearRetainingCapacity();
            const raw = try self.pendingParagraphRawLeaky(arena_tx);
            var overflow2: bool = false;
            try inline_mod.appendText(
                arena_tx,
                &spans,
                raw,
                self.opts.sanitize_control,
                true,
                null,
                self.opts.max_spans,
                &overflow2,
            );
        }

        return spans.toOwnedSlice(arena_tx);
    }
};

pub const StreamInline = struct {
    inner: StreamBlocks,

    pub fn init(allocator: std.mem.Allocator, opts: types.Options, caps: StreamBlocks.Caps) StreamInline {
        return .{ .inner = StreamBlocks.init(allocator, opts, caps, .inline_parse) };
    }

    pub fn deinit(self: *StreamInline) void {
        self.inner.deinit();
    }

    pub fn reset(self: *StreamInline) void {
        self.inner.reset();
    }

    pub fn push(self: *StreamInline, chunk: []const u8) types.CompileError!StreamBlocks.PushResult {
        return self.inner.push(chunk);
    }

    pub fn finish(self: *StreamInline) types.CompileError!StreamBlocks.PushResult {
        return self.inner.finish();
    }

    pub fn snapshotLeaky(self: *const StreamInline, arena_tx: std.mem.Allocator) types.CompileError!protocol.Node {
        return self.inner.snapshotLeaky(arena_tx);
    }

    pub fn tailNodeLeaky(self: *const StreamInline, arena_tx: std.mem.Allocator) ?protocol.Node {
        return self.inner.tailNodeLeaky(arena_tx);
    }

    pub fn tailKey(self: *const StreamInline) StreamBlocks.TailKey {
        return self.inner.tailKey();
    }
};

fn compileParagraphSpansLeaky(
    allocator: std.mem.Allocator,
    lines: []const []const u8,
    sanitize_control: bool,
    own_text: bool,
    max_spans: usize,
    theme: types.Theme,
) types.CompileError![]protocol.Span {
    var spans: std.ArrayList(protocol.Span) = .empty;
    defer spans.deinit(allocator);
    var overflow: bool = false;

    for (lines, 0..) |line, i| {
        if (i != 0) {
            try inline_mod.appendText(
                allocator,
                &spans,
                "\n",
                sanitize_control,
                own_text,
                null,
                max_spans,
                &overflow,
            );
            if (overflow) break;
        }
        try inline_mod.parseInlineInto(
            allocator,
            &spans,
            line,
            sanitize_control,
            own_text,
            theme,
            null,
            max_spans,
            &overflow,
        );
        if (overflow) break;
    }

    if (overflow) {
        spans.clearRetainingCapacity();
        const raw = try common.joinLinesLeaky(allocator, lines);
        var overflow2: bool = false;
        try inline_mod.appendText(
            allocator,
            &spans,
            raw,
            sanitize_control,
            true,
            null,
            max_spans,
            &overflow2,
        );
    }

    return spans.toOwnedSlice(allocator);
}

fn compileListItemNodeLeaky(
    allocator: std.mem.Allocator,
    id: []const u8,
    text: []const u8,
    opts: types.Options,
) types.CompileError!protocol.Node {
    if (opts.prefix_layout) {
        const prefix_text = if (opts.pretty_prefixes) "• " else "- ";
        var body_spans: std.ArrayList(protocol.Span) = .empty;
        defer body_spans.deinit(allocator);
        var overflow: bool = false;
        try inline_mod.parseInlineInto(
            allocator,
            &body_spans,
            text,
            opts.sanitize_control,
            opts.own_text,
            opts.theme,
            null,
            opts.max_spans,
            &overflow,
        );
        if (overflow) {
            body_spans.clearRetainingCapacity();
            var overflow2: bool = false;
            try inline_mod.appendText(
                allocator,
                &body_spans,
                text,
                opts.sanitize_control,
                true,
                null,
                opts.max_spans,
                &overflow2,
            );
        }

        const prefix_id = try std.fmt.allocPrint(allocator, "{s}-bullet", .{id});
        const body_id = try std.fmt.allocPrint(allocator, "{s}-body", .{id});

        var h_children = try allocator.alloc(protocol.Node, 2);
        h_children[0] = .{
            .text = .{
                .id = prefix_id,
                .w = 2,
                .style = opts.theme.bullet_prefix,
                .text = prefix_text,
            },
        };
        h_children[1] = .{
            .styled_text = .{
                .id = body_id,
                .flex = 1,
                .spans = try body_spans.toOwnedSlice(allocator),
            },
        };

        return .{ .hbox = .{ .id = id, .children = h_children } };
    }

    var spans: std.ArrayList(protocol.Span) = .empty;
    defer spans.deinit(allocator);

    const prefix_text = if (opts.pretty_prefixes) "• " else "- ";
    var overflow: bool = false;
    try inline_mod.appendText(
        allocator,
        &spans,
        prefix_text,
        opts.sanitize_control,
        opts.own_text,
        opts.theme.bullet_prefix,
        opts.max_spans,
        &overflow,
    );
    try inline_mod.parseInlineInto(
        allocator,
        &spans,
        text,
        opts.sanitize_control,
        opts.own_text,
        opts.theme,
        null,
        opts.max_spans,
        &overflow,
    );
    if (overflow) {
        spans.clearRetainingCapacity();
        const raw = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix_text, text });
        var overflow2: bool = false;
        try inline_mod.appendText(
            allocator,
            &spans,
            raw,
            opts.sanitize_control,
            true,
            null,
            opts.max_spans,
            &overflow2,
        );
    }

    return .{ .styled_text = .{ .id = id, .spans = try spans.toOwnedSlice(allocator) } };
}

fn compileBlockquoteNodeLeaky(
    allocator: std.mem.Allocator,
    id: []const u8,
    text: []const u8,
    opts: types.Options,
) types.CompileError!protocol.Node {
    if (opts.prefix_layout) {
        const prefix_text = if (opts.pretty_prefixes) "│ " else "> ";
        var body_spans: std.ArrayList(protocol.Span) = .empty;
        defer body_spans.deinit(allocator);
        var overflow: bool = false;
        try inline_mod.parseInlineInto(
            allocator,
            &body_spans,
            text,
            opts.sanitize_control,
            opts.own_text,
            opts.theme,
            null,
            opts.max_spans,
            &overflow,
        );
        if (overflow) {
            body_spans.clearRetainingCapacity();
            var overflow2: bool = false;
            try inline_mod.appendText(
                allocator,
                &body_spans,
                text,
                opts.sanitize_control,
                true,
                null,
                opts.max_spans,
                &overflow2,
            );
        }

        const prefix_id = try std.fmt.allocPrint(allocator, "{s}-prefix", .{id});
        const body_id = try std.fmt.allocPrint(allocator, "{s}-body", .{id});

        var h_children = try allocator.alloc(protocol.Node, 2);
        h_children[0] = .{
            .text = .{
                .id = prefix_id,
                .w = 2,
                .style = opts.theme.quote_prefix,
                .text = prefix_text,
            },
        };
        h_children[1] = .{
            .styled_text = .{
                .id = body_id,
                .flex = 1,
                .spans = try body_spans.toOwnedSlice(allocator),
            },
        };

        return .{ .hbox = .{ .id = id, .children = h_children } };
    }

    var spans: std.ArrayList(protocol.Span) = .empty;
    defer spans.deinit(allocator);

    const prefix_text = if (opts.pretty_prefixes) "│ " else "> ";
    var overflow: bool = false;
    try inline_mod.appendText(
        allocator,
        &spans,
        prefix_text,
        opts.sanitize_control,
        opts.own_text,
        opts.theme.quote_prefix,
        opts.max_spans,
        &overflow,
    );
    try inline_mod.parseInlineInto(
        allocator,
        &spans,
        text,
        opts.sanitize_control,
        opts.own_text,
        opts.theme,
        null,
        opts.max_spans,
        &overflow,
    );
    if (overflow) {
        spans.clearRetainingCapacity();
        const raw = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix_text, text });
        var overflow2: bool = false;
        try inline_mod.appendText(
            allocator,
            &spans,
            raw,
            opts.sanitize_control,
            true,
            null,
            opts.max_spans,
            &overflow2,
        );
    }

    return .{ .styled_text = .{ .id = id, .spans = try spans.toOwnedSlice(allocator) } };
}

fn detectSpecialLineKind(line: []const u8) ?StreamBlocks.TailKey {
    const l = common.trimCr(line);
    if (l.len == 0) return null;
    if (common.parseListItem(l)) |_| return .{ .kind = .list_item };
    if (common.parseBlockquote(l)) |_| return .{ .kind = .blockquote };
    if (common.parseHeading(l)) |h| return .{ .kind = .heading, .level = h.level };
    return null;
}

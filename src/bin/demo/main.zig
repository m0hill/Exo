const std = @import("std");

const tui = @import("tui");
const jsonl = tui.jsonl;
const protocol = tui.protocol;
const markdown = tui.markdown;

const args_mod = @import("args.zig");
const render = @import("render.zig");
const state = @import("state.zig");

const MD_STREAM_ID: []const u8 = "md-stream";
const MD_PROMPT_ID: []const u8 = "md-prompt";
const MD_ACTIONS_ID: []const u8 = "md-actions";
const MD_ACTION_START: []const u8 = "md-actions-start";
const MD_ACTION_PAUSE: []const u8 = "md-actions-pause";
const MD_ACTION_RESET: []const u8 = "md-actions-reset";
const MD_MODE_ID: []const u8 = "md-mode";
const MD_MODE_18: []const u8 = "md-mode-18";
const MD_MODE_19A: []const u8 = "md-mode-19a";
const MD_MODE_19B: []const u8 = "md-mode-19b";
const MD_SPEED_ID: []const u8 = "md-speed";
const MD_SPEED_FASTER: []const u8 = "md-speed-faster";
const MD_SPEED_SLOWER: []const u8 = "md-speed-slower";
const MD_SPEED_CHUNK_SMALLER: []const u8 = "md-speed-chunk-smaller";
const MD_SPEED_CHUNK_LARGER: []const u8 = "md-speed-chunk-larger";

const POPUPS_ID: []const u8 = "popups";
const POPUP_OPEN_MODAL: []const u8 = "popup-open-modal";
const POPUP_OPEN_DROPDOWN: []const u8 = "popup-open-dropdown";
const POPUP_TOGGLE_TOOLTIP: []const u8 = "popup-toggle-tooltip";

const DROPDOWN_ID: []const u8 = "dropdown";
const MODAL_ACTIONS_ID: []const u8 = "modal-actions";
const MODAL_CLOSE: []const u8 = "modal-close";

const W_BTN: []const u8 = "w-btn";
const W_BTN_DISABLED: []const u8 = "w-btn-disabled";
const W_BTN_ERROR: []const u8 = "w-btn-error";
const W_CHECKBOX: []const u8 = "w-checkbox";
const W_TOGGLE: []const u8 = "w-toggle";
const W_RADIO: []const u8 = "w-radio";
const W_TAB_ONE: []const u8 = "w-tab-one";
const W_TAB_TWO: []const u8 = "w-tab-two";
const W_TAB_THREE: []const u8 = "w-tab-three";
const W_MENU_FILE: []const u8 = "w-menu-file";
const W_MENU_HELP: []const u8 = "w-menu-help";
const W_MENU_LIST: []const u8 = "w-menu-list";
const W_MENU_NEW: []const u8 = "w-menu-new";
const W_MENU_OPEN: []const u8 = "w-menu-open";
const W_MENU_QUIT: []const u8 = "w-menu-quit";
const W_MENU_ABOUT: []const u8 = "w-menu-about";
const W_MENU_CLOSE: []const u8 = "w-menu-close";
const W_TREE: []const u8 = "w-tree";
const W_TREE_ROOT: []const u8 = "w-tree-root";
const W_TREE_SRC: []const u8 = "w-tree-src";
const W_TREE_LIB: []const u8 = "w-tree-lib";
const W_TREE_TESTS: []const u8 = "w-tree-tests";
const DEMO_PROTOCOL_VERSION: u32 = 1;

const MdMode = enum { tracer18, tracer19a, tracer19b };

fn modeName(mode: MdMode) []const u8 {
    return switch (mode) {
        .tracer18 => "Tracer 18 (full recompile)",
        .tracer19a => "Tracer 19A (finalize blocks)",
        .tracer19b => "Tracer 19B (inline tail)",
    };
}

fn mdStreamTitle(buf: []u8, mode: MdMode) ![]const u8 {
    return std.fmt.bufPrint(buf, "Streaming Markdown — {s}", .{modeName(mode)});
}

fn mdStreamHint(buf: []u8, mode: MdMode, tick_every: usize, chunk_len: usize) ![]const u8 {
    return std.fmt.bufPrint(
        buf,
        "Type markdown into the prompt input, then start.\n" ++
            "md-actions: click/Enter. md-mode switches strategies (resets). md-speed adjusts cadence.\n" ++
            "Current: mode={s} cadence=every {d} ticks chunk={d} bytes",
        .{ modeName(mode), tick_every, chunk_len },
    );
}

fn mdSpeedFasterLabel(buf: []u8, tick_every: usize) ![]const u8 {
    return std.fmt.bufPrint(buf, "Cadence: faster (currently every {d} ticks)", .{tick_every});
}

fn mdSpeedSlowerLabel(buf: []u8, tick_every: usize) ![]const u8 {
    return std.fmt.bufPrint(buf, "Cadence: slower (currently every {d} ticks)", .{tick_every});
}

fn mdChunkSmallerLabel(buf: []u8, chunk_len: usize) ![]const u8 {
    return std.fmt.bufPrint(buf, "Chunk: smaller (currently {d} bytes)", .{chunk_len});
}

fn mdChunkLargerLabel(buf: []u8, chunk_len: usize) ![]const u8 {
    return std.fmt.bufPrint(buf, "Chunk: larger (currently {d} bytes)", .{chunk_len});
}

fn nodeId(node: protocol.Node) []const u8 {
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
    };
}

fn popupsInfo(
    modal_open: bool,
    dropdown_open: bool,
    tooltip_on: bool,
    tooltip_anchor: []const u8,
    hover_id: []const u8,
    hover_item: []const u8,
) state.PopupInfo {
    return .{
        .modal_open = modal_open,
        .dropdown_open = dropdown_open,
        .tooltip_on = tooltip_on,
        .tooltip_anchor = tooltip_anchor,
        .hover_id = hover_id,
        .hover_item = hover_item,
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    const cfg = try args_mod.parseArgs(args);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_w = std.fs.File.stdout().writerStreaming(&stdout_buf);
    const out = &stdout_w.interface;

    var focus_id: std.ArrayList(u8) = .empty;
    defer focus_id.deinit(allocator);

    var scroll_id: std.ArrayList(u8) = .empty;
    defer scroll_id.deinit(allocator);
    var scroll_y: usize = 0;

    var hover_id: std.ArrayList(u8) = .empty;
    defer hover_id.deinit(allocator);
    var hover_item: std.ArrayList(u8) = .empty;
    defer hover_item.deinit(allocator);

    var pointer_have: bool = false;
    var pointer_kind: protocol.PointerKind = .move;
    var pointer_id: std.ArrayList(u8) = .empty;
    defer pointer_id.deinit(allocator);
    var pointer_item: std.ArrayList(u8) = .empty;
    defer pointer_item.deinit(allocator);
    var pointer_x: usize = 0;
    var pointer_y: usize = 0;
    var pointer_buttons: u8 = 0;
    var pointer_mods: u8 = 0;
    var pointer_clicks: u8 = 1;
    var pointer_captured: bool = false;
    var pointer_last_patch_ns: u64 = 0;

    var inputs = [_]state.InputSlot{
        .{ .id = "query-a" },
        .{ .id = "query-b" },
        .{ .id = MD_PROMPT_ID },
    };
    defer {
        for (&inputs) |*s| s.last.deinit(allocator);
    }

    var lists = [_]state.ListSlot{
        .{ .id = "results-a", .next_item_id = 21 },
        .{ .id = "results-b", .next_item_id = 1021 },
    };
    defer {
        for (&lists) |*s| {
            s.selected.deinit(allocator);
            s.activated.deinit(allocator);
            s.items.deinit(allocator);
        }
    }

    var status_buf: std.ArrayList(u8) = .empty;
    defer status_buf.deinit(allocator);

    var md_buf: std.ArrayList(u8) = .empty;
    defer md_buf.deinit(allocator);
    var md_source: std.ArrayList(u8) = .empty;
    defer md_source.deinit(allocator);
    var md_cursor: usize = 0;
    var md_active: bool = false;
    var md_paused: bool = false;
    var md_mode: MdMode = .tracer18;
    var md_tick_every: usize = 1;
    var md_chunk_len: usize = 24;

    var popup_modal_open: bool = false;
    var popup_dropdown_open: bool = false;
    var popup_tooltip_on: bool = false;

    var widgets: state.WidgetsState = .{
        .checkbox_checked = true,
        .toggle_on = false,
        .radio_choice = .alpha,
        .active_tab = .one,
    };
    const theme_cycle = [_]protocol.ThemeName{ .default, .light, .ocean };
    var theme_idx: usize = 0;

    var md_blocks: ?tui.markdown.StreamBlocks = null;
    defer if (md_blocks) |*s| s.deinit();
    var md_inline: ?tui.markdown.StreamInline = null;
    defer if (md_inline) |*s| s.deinit();

    const md_default =
        "# Streaming markdown demo\n" ++
        "\n" ++
        "Backend appends chunks to a buffer, recompiles the whole document, and sends a `mode=morph` patch.\n" ++
        "\n" ++
        "- **Bold** and *italic* work once delimiters close\n" ++
        "- Inline `code` stays literal inside backticks\n" ++
        "> This is how Claude/Codex-style TUIs can render streaming responses.\n";

    var term_rows: ?usize = null;
    var term_cols: ?usize = null;
    const list_height: usize = 8;

    var arena_tx = std.heap.ArenaAllocator.init(allocator);
    defer arena_tx.deinit();

    try state.initItems(allocator, &lists[0].items, 1, 20);
    try state.initItems(allocator, &lists[1].items, 1001, 1020);

    var state_on = false;
    var tick: u64 = 0;
    {
        var tick_buf: [64]u8 = undefined;
        const tick_text = try std.fmt.bufPrint(&tick_buf, "Tick: {d}", .{tick});
        const status_text = try state.buildStatusText(
            allocator,
            &status_buf,
            state_on,
            inputs[0..],
            lists[0..],
            focus_id.items,
            term_rows,
            term_cols,
            if (scroll_id.items.len > 0) .{ .id = scroll_id.items, .scroll_y = scroll_y } else null,
            popupsInfo(popup_modal_open, popup_dropdown_open, popup_tooltip_on, focus_id.items, hover_id.items, hover_item.items),
            null,
        );
        var title_buf: [128]u8 = undefined;
        var hint_buf: [512]u8 = undefined;
        var faster_buf: [96]u8 = undefined;
        var slower_buf: [96]u8 = undefined;
        var chunk_smaller_buf: [96]u8 = undefined;
        var chunk_larger_buf: [96]u8 = undefined;
        const md_title = try mdStreamTitle(&title_buf, md_mode);
        const md_hint = try mdStreamHint(&hint_buf, md_mode, md_tick_every, md_chunk_len);
        const md_faster = try mdSpeedFasterLabel(&faster_buf, md_tick_every);
        const md_slower = try mdSpeedSlowerLabel(&slower_buf, md_tick_every);
        const md_chunk_smaller = try mdChunkSmallerLabel(&chunk_smaller_buf, md_chunk_len);
        const md_chunk_larger = try mdChunkLargerLabel(&chunk_larger_buf, md_chunk_len);
        _ = arena_tx.reset(.retain_capacity);
        const md_stream_node = try markdown.compileLeaky(
            arena_tx.allocator(),
            md_buf.items,
            .{ .id = MD_STREAM_ID, .id_prefix = MD_STREAM_ID, .own_text = false },
        );
        try render.emitInitialFull(
            arena_tx.allocator(),
            out,
            tick_text,
            status_text,
            md_stream_node,
            md_title,
            md_hint,
            md_faster,
            md_slower,
            md_chunk_smaller,
            md_chunk_larger,
            inputs[0..],
            lists[0..],
            list_height,
            popupsInfo(popup_modal_open, popup_dropdown_open, popup_tooltip_on, focus_id.items, hover_id.items, hover_item.items),
            widgets,
            tick,
        );

        // Demo defaults: keep Tab scoped, and use '['/']' to jump between scopes.
        var global_rules = [_]protocol.KeybindingRule{
            .{ .key = "Tab", .mods = 0, .action = .focus_next },
            .{ .key = "Tab", .mods = 1, .action = .focus_prev },
            .{ .key = "Escape", .mods = 0, .action = .focus_clear },
            .{ .key = "[", .mods = 0, .action = .focus_scope_prev },
            .{ .key = "]", .mods = 0, .action = .focus_scope_next },
        };
        try protocol.writeConfigJsonlVersion(out, .{
            .keybindings = .{
                .global = global_rules[0..],
            },
        }, DEMO_PROTOCOL_VERSION);
    }
    try out.flush();

    const InEv = union(enum) {
        line: []u8,
        eof,
    };

    const InQueue = struct {
        allocator: std.mem.Allocator,
        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},
        buf: []InEv,
        head: usize = 0,
        len: usize = 0,
        closed: bool = false,

        fn init(alloc: std.mem.Allocator, cap: usize) !@This() {
            return .{ .allocator = alloc, .buf = try alloc.alloc(InEv, cap) };
        }

        fn deinit(self: *@This()) void {
            self.allocator.free(self.buf);
            self.buf = &.{};
        }

        fn close(self: *@This()) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.closed = true;
            self.cond.broadcast();
        }

        fn push(self: *@This(), ev: InEv) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.closed) return false;
            if (self.len == self.buf.len) return false; // drop on overflow
            const idx = (self.head + self.len) % self.buf.len;
            self.buf[idx] = ev;
            self.len += 1;
            self.cond.signal();
            return true;
        }

        fn popTimeout(self: *@This(), timeout_ms: i32) ?InEv {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (timeout_ms < 0) {
                while (self.len == 0 and !self.closed) self.cond.wait(&self.mutex);
            } else {
                var t = std.time.Timer.start() catch null;
                while (self.len == 0 and !self.closed) {
                    if (t) |*timer| {
                        const elapsed_ms: u64 = timer.read() / std.time.ns_per_ms;
                        if (elapsed_ms >= @as(u64, @intCast(timeout_ms))) break;
                        const remain_ms: u64 = @as(u64, @intCast(timeout_ms)) - elapsed_ms;
                        self.cond.timedWait(&self.mutex, remain_ms * std.time.ns_per_ms) catch break;
                    } else {
                        self.cond.timedWait(&self.mutex, @as(u64, @intCast(timeout_ms)) * std.time.ns_per_ms) catch break;
                        break;
                    }
                }
            }

            if (self.len == 0) return null;
            const ev = self.buf[self.head];
            self.head = (self.head + 1) % self.buf.len;
            self.len -= 1;
            return ev;
        }
    };

    var inq = try InQueue.init(allocator, 256);
    defer inq.close();
    defer inq.deinit();

    const InThread = struct {
        allocator: std.mem.Allocator,
        inq: *InQueue,

        fn main(self: *@This()) void {
            var stdin_buf: [4096]u8 = undefined;
            var stdin_r = std.fs.File.stdin().readerStreaming(&stdin_buf);
            var lr = jsonl.LineReader.init(self.allocator, &stdin_r.interface, 1024 * 1024);
            defer lr.deinit();

            while (true) {
                const n = lr.readMore() catch |e| {
                    if (e == error.LineTooLong) {
                        std.debug.print("backend_demo: EVENT_ERR line_too_long\n", .{});
                        continue;
                    }
                    _ = self.inq.push(.eof);
                    return;
                };
                while (lr.nextLine()) |line| {
                    const owned = self.allocator.dupe(u8, line) catch return;
                    if (!self.inq.push(.{ .line = owned })) {
                        self.allocator.free(owned);
                    }
                }
                if (n == 0 and lr.eof) {
                    _ = self.inq.push(.eof);
                    return;
                }
            }
        }
    };

    var in_thread_ctx: InThread = .{ .allocator = allocator, .inq = &inq };
    var stdin_thread = try std.Thread.spawn(.{}, InThread.main, .{&in_thread_ctx});
    stdin_thread.detach();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    while (true) {
        const inev_opt = inq.popTimeout(cfg.tick_interval_ms);
        if (inev_opt == null) {
            var tick_buf: [64]u8 = undefined;
            var tick_text: []const u8 = "";
            {
                var i: usize = 0;
                while (i < cfg.flood_burst) : (i += 1) {
                    tick += 1;
                    if (!cfg.quiet_tx) std.debug.print("PATCH_TX target=clock tick={d}\n", .{tick});
                    tick_text = try std.fmt.bufPrint(&tick_buf, "Tick: {d}", .{tick});
                    try render.emitTextPatchByIdStyled(out, "clock", tick_text, "{\"fg\":\"#22c55e\",\"bold\":true}");

                    state.updateItems(allocator, &lists[0], tick);
                    state.updateItems(allocator, &lists[1], tick + 2);

                    if (!cfg.quiet_tx) {
                        std.debug.print(
                            "PATCH_TX target={s} mode=morph items={d} tick={d}\n",
                            .{ lists[0].id, lists[0].items.items.len, tick },
                        );
                    }
                    try render.emitListMorphPatch(out, lists[0].id, lists[0].items.items, list_height);

                    if (!cfg.quiet_tx) {
                        std.debug.print(
                            "PATCH_TX target={s} mode=morph items={d} tick={d}\n",
                            .{ lists[1].id, lists[1].items.items.len, tick },
                        );
                    }
                    try render.emitListMorphPatch(out, lists[1].id, lists[1].items.items, list_height);
                }
            }

            const status_text = try state.buildStatusText(
                allocator,
                &status_buf,
                state_on,
                inputs[0..],
                lists[0..],
                focus_id.items,
                term_rows,
                term_cols,
                if (scroll_id.items.len > 0) .{ .id = scroll_id.items, .scroll_y = scroll_y } else null,
                popupsInfo(popup_modal_open, popup_dropdown_open, popup_tooltip_on, focus_id.items, hover_id.items, hover_item.items),
                if (pointer_have) .{
                    .kind = pointer_kind,
                    .id = pointer_id.items,
                    .item = pointer_item.items,
                    .x = pointer_x,
                    .y = pointer_y,
                    .buttons = pointer_buttons,
                    .mods = pointer_mods,
                    .clicks = pointer_clicks,
                    .captured = pointer_captured,
                } else null,
            );

            if ((tick % 4) == 0) {
                if (!cfg.quiet_tx) std.debug.print("PATCH_TX target=root mode=morph tick={d}\n", .{tick});
                const layout_alt = false;
                _ = arena_tx.reset(.retain_capacity);
                const md_stream_node = switch (md_mode) {
                    .tracer18 => try markdown.compileLeaky(
                        arena_tx.allocator(),
                        md_buf.items,
                        .{ .id = MD_STREAM_ID, .id_prefix = MD_STREAM_ID, .own_text = false },
                    ),
                    .tracer19a => if (md_blocks) |*s| try s.snapshotLeaky(arena_tx.allocator()) else try markdown.compileLeaky(
                        arena_tx.allocator(),
                        "",
                        .{ .id = MD_STREAM_ID, .id_prefix = MD_STREAM_ID, .own_text = false },
                    ),
                    .tracer19b => if (md_inline) |*s| try s.snapshotLeaky(arena_tx.allocator()) else try markdown.compileLeaky(
                        arena_tx.allocator(),
                        "",
                        .{ .id = MD_STREAM_ID, .id_prefix = MD_STREAM_ID, .own_text = false },
                    ),
                };
                var title_buf: [128]u8 = undefined;
                var hint_buf: [512]u8 = undefined;
                var faster_buf: [96]u8 = undefined;
                var slower_buf: [96]u8 = undefined;
                var chunk_smaller_buf: [96]u8 = undefined;
                var chunk_larger_buf: [96]u8 = undefined;
                const md_title = try mdStreamTitle(&title_buf, md_mode);
                const md_hint = try mdStreamHint(&hint_buf, md_mode, md_tick_every, md_chunk_len);
                const md_faster = try mdSpeedFasterLabel(&faster_buf, md_tick_every);
                const md_slower = try mdSpeedSlowerLabel(&slower_buf, md_tick_every);
                const md_chunk_smaller = try mdChunkSmallerLabel(&chunk_smaller_buf, md_chunk_len);
                const md_chunk_larger = try mdChunkLargerLabel(&chunk_larger_buf, md_chunk_len);
                try render.emitRootMorphPatch(
                    arena_tx.allocator(),
                    out,
                    tick_text,
                    status_text,
                    md_stream_node,
                    md_title,
                    md_hint,
                    md_faster,
                    md_slower,
                    md_chunk_smaller,
                    md_chunk_larger,
                    inputs[0..],
                    lists[0..],
                    layout_alt,
                    list_height,
                    popupsInfo(popup_modal_open, popup_dropdown_open, popup_tooltip_on, focus_id.items, hover_id.items, hover_item.items),
                    widgets,
                    tick,
                );
            }

            if (!cfg.quiet_tx) std.debug.print("PATCH_TX target=status\n", .{});
            try render.emitTextPatchByIdStyled(out, "status", status_text, "{\"fg\":\"#fbbf24\"}");

            if (md_active and !md_paused and md_cursor < md_source.items.len and (md_tick_every == 1 or (tick % md_tick_every) == 0)) {
                const next = @min(md_source.items.len, md_cursor + md_chunk_len);
                if (next > md_cursor) {
                    const chunk = md_source.items[md_cursor..next];
                    md_cursor = next;

                    switch (md_mode) {
                        .tracer18 => {
                            try md_buf.appendSlice(allocator, chunk);
                            _ = arena_tx.reset(.retain_capacity);
                            if (!cfg.quiet_tx) std.debug.print(
                                "PATCH_TX target={s} mode=morph bytes={d}\n",
                                .{ MD_STREAM_ID, md_buf.items.len },
                            );
                            try render.emitMarkdownMorphPatch(arena_tx.allocator(), out, MD_STREAM_ID, md_buf.items);
                        },
                        .tracer19a => {
                            if (md_blocks == null) {
                                md_blocks = tui.markdown.StreamBlocks.init(
                                    allocator,
                                    .{ .id = MD_STREAM_ID, .id_prefix = MD_STREAM_ID, .own_text = false },
                                    .{},
                                    .plain,
                                );
                            }
                            const r = try md_blocks.?.push(chunk);
                            _ = arena_tx.reset(.retain_capacity);
                            if (r.blocks_committed != 0 or r.tail_key_changed) {
                                const node = try md_blocks.?.snapshotLeaky(arena_tx.allocator());
                                if (!cfg.quiet_tx) std.debug.print("PATCH_TX target={s} mode=morph\n", .{MD_STREAM_ID});
                                try render.emitNodeMorphPatch(out, MD_STREAM_ID, node);
                            } else if (md_blocks.?.tailNodeLeaky(arena_tx.allocator())) |tail| {
                                if (!cfg.quiet_tx) std.debug.print("PATCH_TX target={s} leaf\n", .{nodeId(tail)});
                                try render.emitNodePatchById(out, nodeId(tail), tail);
                            }
                        },
                        .tracer19b => {
                            if (md_inline == null) {
                                md_inline = tui.markdown.StreamInline.init(
                                    allocator,
                                    .{ .id = MD_STREAM_ID, .id_prefix = MD_STREAM_ID, .own_text = false },
                                    .{},
                                );
                            }
                            const r = try md_inline.?.push(chunk);
                            _ = arena_tx.reset(.retain_capacity);
                            if (r.blocks_committed != 0 or r.tail_key_changed) {
                                const node = try md_inline.?.snapshotLeaky(arena_tx.allocator());
                                if (!cfg.quiet_tx) std.debug.print("PATCH_TX target={s} mode=morph\n", .{MD_STREAM_ID});
                                try render.emitNodeMorphPatch(out, MD_STREAM_ID, node);
                            } else if (md_inline.?.tailNodeLeaky(arena_tx.allocator())) |tail| {
                                if (!cfg.quiet_tx) std.debug.print("PATCH_TX target={s} leaf\n", .{nodeId(tail)});
                                try render.emitNodePatchById(out, nodeId(tail), tail);
                            }
                        },
                    }
                }
                if (md_cursor >= md_source.items.len) {
                    md_active = false;
                    if (md_mode == .tracer19a and md_blocks != null) {
                        _ = arena_tx.reset(.retain_capacity);
                        _ = try md_blocks.?.finish();
                        const node = try md_blocks.?.snapshotLeaky(arena_tx.allocator());
                        try render.emitNodeMorphPatch(out, MD_STREAM_ID, node);
                    } else if (md_mode == .tracer19b and md_inline != null) {
                        _ = arena_tx.reset(.retain_capacity);
                        _ = try md_inline.?.finish();
                        const node = try md_inline.?.snapshotLeaky(arena_tx.allocator());
                        try render.emitNodeMorphPatch(out, MD_STREAM_ID, node);
                    }
                }
            }

            try out.flush();
            continue;
        }

        const inev = inev_opt.?;
        switch (inev) {
            .eof => std.process.exit(0),
            .line => |line| {
                defer allocator.free(line);
                _ = arena.reset(.retain_capacity);
                const msg = protocol.parseMsgLeaky(arena.allocator(), line) catch |e| {
                    std.debug.print("backend_demo: EVENT_ERR {s}\n", .{@errorName(e)});
                    continue;
                };

                switch (msg) {
                    .event => |ev| switch (ev) {
                        .hello => |h| {
                            std.debug.print(
                                "EVENT_RX name=hello protocol_version={d} color={s} max_fps={d} max_pending_targets={d} max_backend_lines={d} overflow={s}\n",
                                .{
                                    h.protocol_version,
                                    h.caps.color,
                                    h.limits.max_fps,
                                    h.limits.max_pending_targets,
                                    h.limits.max_backend_lines_per_iter,
                                    h.limits.queue_overflow,
                                },
                            );
                        },
                        .key => |k| {
                            if (k.seq) |s| {
                                std.debug.print("EVENT_RX name=key key={s} mods={d} seq_len={d}\n", .{ k.key, k.mods, s.len });
                            } else if (k.mods != 0) {
                                std.debug.print("EVENT_RX name=key key={s} mods={d}\n", .{ k.key, k.mods });
                            } else {
                                std.debug.print("EVENT_RX name=key key={s}\n", .{k.key});
                            }

                            if (std.mem.eql(u8, k.key, "q") and k.mods == 0) {
                                state_on = !state_on;
                                const status_text = try state.buildStatusText(
                                    allocator,
                                    &status_buf,
                                    state_on,
                                    inputs[0..],
                                    lists[0..],
                                    focus_id.items,
                                    term_rows,
                                    term_cols,
                                    if (scroll_id.items.len > 0) .{ .id = scroll_id.items, .scroll_y = scroll_y } else null,
                                    popupsInfo(popup_modal_open, popup_dropdown_open, popup_tooltip_on, focus_id.items, hover_id.items, hover_item.items),
                                    if (pointer_have) .{
                                        .kind = pointer_kind,
                                        .id = pointer_id.items,
                                        .item = pointer_item.items,
                                        .x = pointer_x,
                                        .y = pointer_y,
                                        .buttons = pointer_buttons,
                                        .mods = pointer_mods,
                                        .clicks = pointer_clicks,
                                        .captured = pointer_captured,
                                    } else null,
                                );
                                std.debug.print("PATCH_TX target=status\n", .{});
                                try render.emitTextPatchByIdStyled(out, "status", status_text, "{\"fg\":\"#fbbf24\"}");
                                try out.flush();
                            } else if (std.mem.eql(u8, k.key, "t") and k.mods == 0) {
                                theme_idx = (theme_idx + 1) % theme_cycle.len;
                                const next_theme = theme_cycle[theme_idx];
                                std.debug.print("CONFIG_TX kind=theme name={s}\n", .{@tagName(next_theme)});
                                try protocol.writeThemeJsonlVersion(out, next_theme, DEMO_PROTOCOL_VERSION);
                                try out.flush();
                            } else if ((std.mem.eql(u8, k.key, "x") and k.mods == 0) or
                                std.mem.eql(u8, k.key, "ctrl-c") or
                                (std.mem.eql(u8, k.key, "c") and (k.mods & 2) != 0))
                            {
                                std.process.exit(0);
                            }
                        },
                        .focus => |f| {
                            std.debug.print("EVENT_RX name=focus id={s}\n", .{f.id});
                            focus_id.clearRetainingCapacity();
                            if (f.id.len > 0) try focus_id.appendSlice(allocator, f.id);
                            const status_text = try state.buildStatusText(
                                allocator,
                                &status_buf,
                                state_on,
                                inputs[0..],
                                lists[0..],
                                focus_id.items,
                                term_rows,
                                term_cols,
                                if (scroll_id.items.len > 0) .{ .id = scroll_id.items, .scroll_y = scroll_y } else null,
                                popupsInfo(popup_modal_open, popup_dropdown_open, popup_tooltip_on, focus_id.items, hover_id.items, hover_item.items),
                                if (pointer_have) .{
                                    .kind = pointer_kind,
                                    .id = pointer_id.items,
                                    .item = pointer_item.items,
                                    .x = pointer_x,
                                    .y = pointer_y,
                                    .buttons = pointer_buttons,
                                    .mods = pointer_mods,
                                    .clicks = pointer_clicks,
                                    .captured = pointer_captured,
                                } else null,
                            );
                            std.debug.print("PATCH_TX target=status\n", .{});
                            try render.emitTextPatchByIdStyled(out, "status", status_text, "{\"fg\":\"#fbbf24\"}");
                            try out.flush();
                        },
                        .input => |inp| {
                            std.debug.print(
                                "EVENT_RX name=input id={s} len={d} cursor={d}\n",
                                .{ inp.id, inp.value.len, inp.cursor },
                            );
                            if (state.findInputSlot(inputs[0..], inp.id)) |slot| {
                                slot.last.clearRetainingCapacity();
                                slot.last_len = inp.value.len;
                                const cap: usize = if (std.mem.eql(u8, inp.id, MD_PROMPT_ID)) 32 * 1024 else 256;
                                const n = @min(inp.value.len, cap);

                                // Keep status output single-line and bounded.
                                if (!std.mem.eql(u8, inp.id, MD_PROMPT_ID)) {
                                    var i: usize = 0;
                                    while (i < n) : (i += 1) {
                                        const b = inp.value[i];
                                        const out_b: u8 = if (b < 0x20 or b == 0x7f) ' ' else b;
                                        try slot.last.append(allocator, out_b);
                                    }
                                } else {
                                    try slot.last.appendSlice(allocator, inp.value[0..n]);
                                }
                            }

                            const status_text = try state.buildStatusText(
                                allocator,
                                &status_buf,
                                state_on,
                                inputs[0..],
                                lists[0..],
                                focus_id.items,
                                term_rows,
                                term_cols,
                                if (scroll_id.items.len > 0) .{ .id = scroll_id.items, .scroll_y = scroll_y } else null,
                                popupsInfo(popup_modal_open, popup_dropdown_open, popup_tooltip_on, focus_id.items, hover_id.items, hover_item.items),
                                if (pointer_have) .{
                                    .kind = pointer_kind,
                                    .id = pointer_id.items,
                                    .item = pointer_item.items,
                                    .x = pointer_x,
                                    .y = pointer_y,
                                    .buttons = pointer_buttons,
                                    .mods = pointer_mods,
                                    .clicks = pointer_clicks,
                                    .captured = pointer_captured,
                                } else null,
                            );
                            std.debug.print("PATCH_TX target=status\n", .{});
                            try render.emitTextPatchByIdStyled(out, "status", status_text, "{\"fg\":\"#fbbf24\"}");
                            try out.flush();
                        },
                        .select => |s| {
                            std.debug.print("EVENT_RX name=select id={s} item={s}\n", .{ s.id, s.item });
                            if (state.findListSlot(lists[0..], s.id)) |slot| {
                                slot.selected.clearRetainingCapacity();
                                if (s.item.len > 0) try slot.selected.appendSlice(allocator, s.item);
                            }
                            const status_text = try state.buildStatusText(
                                allocator,
                                &status_buf,
                                state_on,
                                inputs[0..],
                                lists[0..],
                                focus_id.items,
                                term_rows,
                                term_cols,
                                if (scroll_id.items.len > 0) .{ .id = scroll_id.items, .scroll_y = scroll_y } else null,
                                popupsInfo(popup_modal_open, popup_dropdown_open, popup_tooltip_on, focus_id.items, hover_id.items, hover_item.items),
                                if (pointer_have) .{
                                    .kind = pointer_kind,
                                    .id = pointer_id.items,
                                    .item = pointer_item.items,
                                    .x = pointer_x,
                                    .y = pointer_y,
                                    .buttons = pointer_buttons,
                                    .mods = pointer_mods,
                                    .clicks = pointer_clicks,
                                    .captured = pointer_captured,
                                } else null,
                            );
                            std.debug.print("PATCH_TX target=status\n", .{});
                            try render.emitTextPatchByIdStyled(out, "status", status_text, "{\"fg\":\"#fbbf24\"}");
                            try out.flush();
                        },
                        .scroll => |s| {
                            std.debug.print("EVENT_RX name=scroll id={s} scroll_y={d}\n", .{ s.id, s.scroll_y });
                            scroll_id.clearRetainingCapacity();
                            if (s.id.len > 0) try scroll_id.appendSlice(allocator, s.id);
                            scroll_y = s.scroll_y;
                            const status_text = try state.buildStatusText(
                                allocator,
                                &status_buf,
                                state_on,
                                inputs[0..],
                                lists[0..],
                                focus_id.items,
                                term_rows,
                                term_cols,
                                if (scroll_id.items.len > 0) .{ .id = scroll_id.items, .scroll_y = scroll_y } else null,
                                popupsInfo(popup_modal_open, popup_dropdown_open, popup_tooltip_on, focus_id.items, hover_id.items, hover_item.items),
                                if (pointer_have) .{
                                    .kind = pointer_kind,
                                    .id = pointer_id.items,
                                    .item = pointer_item.items,
                                    .x = pointer_x,
                                    .y = pointer_y,
                                    .buttons = pointer_buttons,
                                    .mods = pointer_mods,
                                    .clicks = pointer_clicks,
                                    .captured = pointer_captured,
                                } else null,
                            );
                            std.debug.print("PATCH_TX target=status\n", .{});
                            try render.emitTextPatchByIdStyled(out, "status", status_text, "{\"fg\":\"#fbbf24\"}");
                            try out.flush();
                        },
                        .pointer => |p| {
                            if (p.kind != .move and p.kind != .drag) {
                                std.debug.print(
                                    "EVENT_RX name=pointer kind={s} id={s} item={s} x={d} y={d} buttons={d} mods={d} clicks={d} captured={s}\n",
                                    .{
                                        switch (p.kind) {
                                            .down => "down",
                                            .up => "up",
                                            .move => "move",
                                            .drag => "drag",
                                            .scroll => "scroll",
                                        },
                                        p.id,
                                        p.item orelse "",
                                        p.x,
                                        p.y,
                                        p.buttons,
                                        p.mods,
                                        p.clicks,
                                        if (p.captured) "true" else "false",
                                    },
                                );
                            }

                            pointer_have = true;
                            pointer_kind = p.kind;
                            pointer_x = p.x;
                            pointer_y = p.y;
                            pointer_buttons = p.buttons;
                            pointer_mods = p.mods;
                            pointer_clicks = p.clicks;
                            pointer_captured = p.captured;
                            pointer_id.clearRetainingCapacity();
                            if (p.id.len > 0) try pointer_id.appendSlice(allocator, p.id);
                            pointer_item.clearRetainingCapacity();
                            if (p.item) |it| {
                                if (it.len > 0) try pointer_item.appendSlice(allocator, it);
                            }

                            const now_i = std.time.nanoTimestamp();
                            const now_ns: u64 = if (now_i > 0) @as(u64, @intCast(now_i)) else 0;
                            const debounce_ns: u64 = 50 * std.time.ns_per_ms;
                            const should_patch =
                                (p.kind != .move and p.kind != .drag) or pointer_last_patch_ns == 0 or
                                now_ns > pointer_last_patch_ns + debounce_ns;
                            if (!should_patch) continue;
                            pointer_last_patch_ns = now_ns;

                            const status_text = try state.buildStatusText(
                                allocator,
                                &status_buf,
                                state_on,
                                inputs[0..],
                                lists[0..],
                                focus_id.items,
                                term_rows,
                                term_cols,
                                if (scroll_id.items.len > 0) .{ .id = scroll_id.items, .scroll_y = scroll_y } else null,
                                popupsInfo(popup_modal_open, popup_dropdown_open, popup_tooltip_on, focus_id.items, hover_id.items, hover_item.items),
                                .{
                                    .kind = pointer_kind,
                                    .id = pointer_id.items,
                                    .item = pointer_item.items,
                                    .x = pointer_x,
                                    .y = pointer_y,
                                    .buttons = pointer_buttons,
                                    .mods = pointer_mods,
                                    .clicks = pointer_clicks,
                                    .captured = pointer_captured,
                                },
                            );
                            std.debug.print("PATCH_TX target=status\n", .{});
                            try render.emitTextPatchByIdStyled(out, "status", status_text, "{\"fg\":\"#fbbf24\"}");
                            try out.flush();
                        },
                        .hover => |h| {
                            std.debug.print(
                                "EVENT_RX name=hover id={s} x={d} y={d} item={s}\n",
                                .{ h.id, h.x, h.y, h.item orelse "" },
                            );

                            hover_id.clearRetainingCapacity();
                            hover_item.clearRetainingCapacity();
                            if (h.id.len > 0) {
                                try hover_id.appendSlice(allocator, h.id);
                                if (h.item) |it| {
                                    if (it.len > 0) try hover_item.appendSlice(allocator, it);
                                }
                            }

                            if (!cfg.quiet_tx) std.debug.print("PATCH_TX target=root mode=morph reason=hover\n", .{});
                            const layout_alt = false;

                            var tick_buf: [64]u8 = undefined;
                            const tick_text = try std.fmt.bufPrint(&tick_buf, "Tick: {d}", .{tick});
                            const status_text = try state.buildStatusText(
                                allocator,
                                &status_buf,
                                state_on,
                                inputs[0..],
                                lists[0..],
                                focus_id.items,
                                term_rows,
                                term_cols,
                                if (scroll_id.items.len > 0) .{ .id = scroll_id.items, .scroll_y = scroll_y } else null,
                                popupsInfo(
                                    popup_modal_open,
                                    popup_dropdown_open,
                                    popup_tooltip_on,
                                    focus_id.items,
                                    hover_id.items,
                                    hover_item.items,
                                ),
                                if (pointer_have) .{
                                    .kind = pointer_kind,
                                    .id = pointer_id.items,
                                    .item = pointer_item.items,
                                    .x = pointer_x,
                                    .y = pointer_y,
                                    .buttons = pointer_buttons,
                                    .mods = pointer_mods,
                                    .clicks = pointer_clicks,
                                    .captured = pointer_captured,
                                } else null,
                            );

                            _ = arena_tx.reset(.retain_capacity);
                            const md_stream_node = switch (md_mode) {
                                .tracer18 => try markdown.compileLeaky(
                                    arena_tx.allocator(),
                                    md_buf.items,
                                    .{ .id = MD_STREAM_ID, .id_prefix = MD_STREAM_ID, .own_text = false },
                                ),
                                .tracer19a => if (md_blocks) |*s| try s.snapshotLeaky(arena_tx.allocator()) else try markdown.compileLeaky(
                                    arena_tx.allocator(),
                                    "",
                                    .{ .id = MD_STREAM_ID, .id_prefix = MD_STREAM_ID, .own_text = false },
                                ),
                                .tracer19b => if (md_inline) |*s| try s.snapshotLeaky(arena_tx.allocator()) else try markdown.compileLeaky(
                                    arena_tx.allocator(),
                                    "",
                                    .{ .id = MD_STREAM_ID, .id_prefix = MD_STREAM_ID, .own_text = false },
                                ),
                            };

                            var title_buf: [128]u8 = undefined;
                            var hint_buf: [512]u8 = undefined;
                            var faster_buf: [96]u8 = undefined;
                            var slower_buf: [96]u8 = undefined;
                            var chunk_smaller_buf: [96]u8 = undefined;
                            var chunk_larger_buf: [96]u8 = undefined;
                            const md_title = try mdStreamTitle(&title_buf, md_mode);
                            const md_hint = try mdStreamHint(&hint_buf, md_mode, md_tick_every, md_chunk_len);
                            const md_faster = try mdSpeedFasterLabel(&faster_buf, md_tick_every);
                            const md_slower = try mdSpeedSlowerLabel(&slower_buf, md_tick_every);
                            const md_chunk_smaller = try mdChunkSmallerLabel(&chunk_smaller_buf, md_chunk_len);
                            const md_chunk_larger = try mdChunkLargerLabel(&chunk_larger_buf, md_chunk_len);

                            try render.emitRootMorphPatch(
                                arena_tx.allocator(),
                                out,
                                tick_text,
                                status_text,
                                md_stream_node,
                                md_title,
                                md_hint,
                                md_faster,
                                md_slower,
                                md_chunk_smaller,
                                md_chunk_larger,
                                inputs[0..],
                                lists[0..],
                                layout_alt,
                                list_height,
                                popupsInfo(
                                    popup_modal_open,
                                    popup_dropdown_open,
                                    popup_tooltip_on,
                                    focus_id.items,
                                    hover_id.items,
                                    hover_item.items,
                                ),
                                widgets,
                                tick,
                            );
                            try out.flush();
                        },
                        .activate => |a| {
                            std.debug.print("EVENT_RX name=activate id={s} item={s}\n", .{ a.id, a.item });
                            var widgets_changed: bool = false;
                            if (std.mem.eql(u8, a.id, POPUPS_ID) or std.mem.eql(u8, a.id, MODAL_ACTIONS_ID) or std.mem.eql(u8, a.id, DROPDOWN_ID)) {
                                if (std.mem.eql(u8, a.id, POPUPS_ID)) {
                                    if (std.mem.eql(u8, a.item, POPUP_OPEN_MODAL)) {
                                        popup_modal_open = true;
                                        popup_dropdown_open = false;
                                    } else if (std.mem.eql(u8, a.item, POPUP_OPEN_DROPDOWN)) {
                                        popup_dropdown_open = !popup_dropdown_open;
                                        if (popup_dropdown_open) popup_modal_open = false;
                                    } else if (std.mem.eql(u8, a.item, POPUP_TOGGLE_TOOLTIP)) {
                                        popup_tooltip_on = !popup_tooltip_on;
                                    }
                                } else if (std.mem.eql(u8, a.id, MODAL_ACTIONS_ID) and std.mem.eql(u8, a.item, MODAL_CLOSE)) {
                                    popup_modal_open = false;
                                } else if (std.mem.eql(u8, a.id, DROPDOWN_ID)) {
                                    popup_dropdown_open = false;
                                }

                                var tick_buf: [64]u8 = undefined;
                                const tick_text = try std.fmt.bufPrint(&tick_buf, "Tick: {d}", .{tick});
                                const status_text = try state.buildStatusText(
                                    allocator,
                                    &status_buf,
                                    state_on,
                                    inputs[0..],
                                    lists[0..],
                                    focus_id.items,
                                    term_rows,
                                    term_cols,
                                    if (scroll_id.items.len > 0) .{ .id = scroll_id.items, .scroll_y = scroll_y } else null,
                                    popupsInfo(popup_modal_open, popup_dropdown_open, popup_tooltip_on, focus_id.items, hover_id.items, hover_item.items),
                                    if (pointer_have) .{
                                        .kind = pointer_kind,
                                        .id = pointer_id.items,
                                        .item = pointer_item.items,
                                        .x = pointer_x,
                                        .y = pointer_y,
                                        .buttons = pointer_buttons,
                                        .mods = pointer_mods,
                                        .clicks = pointer_clicks,
                                        .captured = pointer_captured,
                                    } else null,
                                );

                                const layout_alt = false;
                                _ = arena_tx.reset(.retain_capacity);
                                const md_stream_node = switch (md_mode) {
                                    .tracer18 => try markdown.compileLeaky(
                                        arena_tx.allocator(),
                                        md_buf.items,
                                        .{ .id = MD_STREAM_ID, .id_prefix = MD_STREAM_ID, .own_text = false },
                                    ),
                                    .tracer19a => if (md_blocks) |*s| try s.snapshotLeaky(arena_tx.allocator()) else try markdown.compileLeaky(
                                        arena_tx.allocator(),
                                        "",
                                        .{ .id = MD_STREAM_ID, .id_prefix = MD_STREAM_ID, .own_text = false },
                                    ),
                                    .tracer19b => if (md_inline) |*s| try s.snapshotLeaky(arena_tx.allocator()) else try markdown.compileLeaky(
                                        arena_tx.allocator(),
                                        "",
                                        .{ .id = MD_STREAM_ID, .id_prefix = MD_STREAM_ID, .own_text = false },
                                    ),
                                };

                                var title_buf: [128]u8 = undefined;
                                var hint_buf: [512]u8 = undefined;
                                var faster_buf: [96]u8 = undefined;
                                var slower_buf: [96]u8 = undefined;
                                var chunk_smaller_buf: [96]u8 = undefined;
                                var chunk_larger_buf: [96]u8 = undefined;
                                const md_title = try mdStreamTitle(&title_buf, md_mode);
                                const md_hint = try mdStreamHint(&hint_buf, md_mode, md_tick_every, md_chunk_len);
                                const md_faster = try mdSpeedFasterLabel(&faster_buf, md_tick_every);
                                const md_slower = try mdSpeedSlowerLabel(&slower_buf, md_tick_every);
                                const md_chunk_smaller = try mdChunkSmallerLabel(&chunk_smaller_buf, md_chunk_len);
                                const md_chunk_larger = try mdChunkLargerLabel(&chunk_larger_buf, md_chunk_len);

                                try render.emitRootMorphPatch(
                                    arena_tx.allocator(),
                                    out,
                                    tick_text,
                                    status_text,
                                    md_stream_node,
                                    md_title,
                                    md_hint,
                                    md_faster,
                                    md_slower,
                                    md_chunk_smaller,
                                    md_chunk_larger,
                                    inputs[0..],
                                    lists[0..],
                                    layout_alt,
                                    list_height,
                                    popupsInfo(popup_modal_open, popup_dropdown_open, popup_tooltip_on, focus_id.items, hover_id.items, hover_item.items),
                                    widgets,
                                    tick,
                                );
                                try render.emitTextPatchByIdStyled(out, "status", status_text, "{\"fg\":\"#fbbf24\"}");
                                try out.flush();
                                continue;
                            }

                            if (a.item.len == 0) {
                                if (std.mem.eql(u8, a.id, W_BTN)) {
                                    widgets.button_clicks += 1;
                                    widgets_changed = true;
                                } else if (std.mem.eql(u8, a.id, W_CHECKBOX)) {
                                    widgets.checkbox_checked = !widgets.checkbox_checked;
                                    widgets_changed = true;
                                } else if (std.mem.eql(u8, a.id, W_TOGGLE)) {
                                    widgets.toggle_on = !widgets.toggle_on;
                                    widgets_changed = true;
                                } else if (std.mem.eql(u8, a.id, W_TAB_ONE)) {
                                    widgets.active_tab = .one;
                                    widgets_changed = true;
                                } else if (std.mem.eql(u8, a.id, W_TAB_TWO)) {
                                    widgets.active_tab = .two;
                                    widgets_changed = true;
                                } else if (std.mem.eql(u8, a.id, W_TAB_THREE)) {
                                    widgets.active_tab = .three;
                                    widgets_changed = true;
                                } else if (std.mem.eql(u8, a.id, W_MENU_FILE)) {
                                    if (widgets.menu_open and widgets.menu_anchor == .file) {
                                        widgets.menu_open = false;
                                    } else {
                                        widgets.menu_open = true;
                                        widgets.menu_anchor = .file;
                                    }
                                    widgets_changed = true;
                                } else if (std.mem.eql(u8, a.id, W_MENU_HELP)) {
                                    if (widgets.menu_open and widgets.menu_anchor == .help) {
                                        widgets.menu_open = false;
                                    } else {
                                        widgets.menu_open = true;
                                        widgets.menu_anchor = .help;
                                    }
                                    widgets_changed = true;
                                }
                            } else if (std.mem.eql(u8, a.id, W_RADIO)) {
                                if (std.mem.eql(u8, a.item, "w-radio-a")) {
                                    widgets.radio_choice = .alpha;
                                    widgets_changed = true;
                                } else if (std.mem.eql(u8, a.item, "w-radio-b")) {
                                    widgets.radio_choice = .beta;
                                    widgets_changed = true;
                                } else if (std.mem.eql(u8, a.item, "w-radio-c")) {
                                    widgets.radio_choice = .gamma;
                                    widgets_changed = true;
                                }
                            } else if (std.mem.eql(u8, a.id, W_MENU_LIST)) {
                                widgets.menu_open = false;
                                if (std.mem.eql(u8, a.item, W_MENU_NEW)) {
                                    widgets.last_menu_action = .new;
                                } else if (std.mem.eql(u8, a.item, W_MENU_OPEN)) {
                                    widgets.last_menu_action = .open;
                                } else if (std.mem.eql(u8, a.item, W_MENU_ABOUT)) {
                                    widgets.last_menu_action = .about;
                                } else if (std.mem.eql(u8, a.item, W_MENU_QUIT)) {
                                    widgets.last_menu_action = .quit;
                                    return;
                                } else if (std.mem.eql(u8, a.item, W_MENU_CLOSE)) {
                                    widgets.last_menu_action = .none;
                                }
                                widgets_changed = true;
                            } else if (std.mem.eql(u8, a.id, W_TREE)) {
                                if (std.mem.eql(u8, a.item, W_TREE_ROOT)) {
                                    widgets.tree_root_expanded = !widgets.tree_root_expanded;
                                    widgets_changed = true;
                                } else if (std.mem.eql(u8, a.item, W_TREE_SRC)) {
                                    widgets.tree_src_expanded = !widgets.tree_src_expanded;
                                    widgets_changed = true;
                                } else if (std.mem.eql(u8, a.item, W_TREE_LIB)) {
                                    widgets.tree_lib_expanded = !widgets.tree_lib_expanded;
                                    widgets_changed = true;
                                } else if (std.mem.eql(u8, a.item, W_TREE_TESTS)) {
                                    widgets.tree_tests_expanded = !widgets.tree_tests_expanded;
                                    widgets_changed = true;
                                }
                            }

                            if (std.mem.eql(u8, a.id, MD_ACTIONS_ID)) {
                                if (std.mem.eql(u8, a.item, MD_ACTION_START)) {
                                    md_buf.clearRetainingCapacity();
                                    md_source.clearRetainingCapacity();
                                    md_cursor = 0;
                                    md_active = true;
                                    md_paused = false;
                                    if (md_blocks) |*s| s.deinit();
                                    md_blocks = null;
                                    if (md_inline) |*s| s.deinit();
                                    md_inline = null;

                                    const prompt = if (state.findInputSlot(inputs[0..], MD_PROMPT_ID)) |slot|
                                        slot.last.items
                                    else
                                        "";
                                    if (prompt.len > 0) {
                                        try md_source.appendSlice(allocator, prompt);
                                    } else {
                                        try md_source.appendSlice(allocator, md_default);
                                    }

                                    const next = @min(md_source.items.len, md_cursor + md_chunk_len);
                                    if (next > md_cursor) {
                                        const chunk = md_source.items[md_cursor..next];
                                        md_cursor = next;

                                        switch (md_mode) {
                                            .tracer18 => {
                                                try md_buf.appendSlice(allocator, chunk);
                                                _ = arena_tx.reset(.retain_capacity);
                                                try render.emitMarkdownMorphPatch(arena_tx.allocator(), out, MD_STREAM_ID, md_buf.items);
                                            },
                                            .tracer19a => {
                                                md_blocks = tui.markdown.StreamBlocks.init(
                                                    allocator,
                                                    .{ .id = MD_STREAM_ID, .id_prefix = MD_STREAM_ID, .own_text = false },
                                                    .{},
                                                    .plain,
                                                );
                                                _ = try md_blocks.?.push(chunk);
                                                _ = arena_tx.reset(.retain_capacity);
                                                const node = try md_blocks.?.snapshotLeaky(arena_tx.allocator());
                                                try render.emitNodeMorphPatch(out, MD_STREAM_ID, node);
                                            },
                                            .tracer19b => {
                                                md_inline = tui.markdown.StreamInline.init(
                                                    allocator,
                                                    .{ .id = MD_STREAM_ID, .id_prefix = MD_STREAM_ID, .own_text = false },
                                                    .{},
                                                );
                                                _ = try md_inline.?.push(chunk);
                                                _ = arena_tx.reset(.retain_capacity);
                                                const node = try md_inline.?.snapshotLeaky(arena_tx.allocator());
                                                try render.emitNodeMorphPatch(out, MD_STREAM_ID, node);
                                            },
                                        }
                                    }
                                    try out.flush();
                                    continue;
                                } else if (std.mem.eql(u8, a.item, MD_ACTION_PAUSE)) {
                                    if (md_active or md_cursor < md_source.items.len) md_paused = !md_paused;
                                    continue;
                                } else if (std.mem.eql(u8, a.item, MD_ACTION_RESET)) {
                                    md_buf.clearRetainingCapacity();
                                    md_source.clearRetainingCapacity();
                                    md_cursor = 0;
                                    md_active = false;
                                    md_paused = false;
                                    if (md_blocks) |*s| s.deinit();
                                    md_blocks = null;
                                    if (md_inline) |*s| s.deinit();
                                    md_inline = null;
                                    _ = arena_tx.reset(.retain_capacity);
                                    const empty = try markdown.compileLeaky(
                                        arena_tx.allocator(),
                                        "",
                                        .{ .id = MD_STREAM_ID, .id_prefix = MD_STREAM_ID, .own_text = false },
                                    );
                                    try render.emitNodeMorphPatch(out, MD_STREAM_ID, empty);
                                    try out.flush();
                                    continue;
                                }
                            } else if (std.mem.eql(u8, a.id, MD_MODE_ID)) {
                                if (std.mem.eql(u8, a.item, MD_MODE_18)) {
                                    md_mode = .tracer18;
                                } else if (std.mem.eql(u8, a.item, MD_MODE_19A)) {
                                    md_mode = .tracer19a;
                                } else if (std.mem.eql(u8, a.item, MD_MODE_19B)) {
                                    md_mode = .tracer19b;
                                }

                                md_buf.clearRetainingCapacity();
                                md_source.clearRetainingCapacity();
                                md_cursor = 0;
                                md_active = false;
                                md_paused = false;
                                if (md_blocks) |*s| s.deinit();
                                md_blocks = null;
                                if (md_inline) |*s| s.deinit();
                                md_inline = null;

                                _ = arena_tx.reset(.retain_capacity);
                                const empty = try markdown.compileLeaky(
                                    arena_tx.allocator(),
                                    "",
                                    .{ .id = MD_STREAM_ID, .id_prefix = MD_STREAM_ID, .own_text = false },
                                );
                                try render.emitNodeMorphPatch(out, MD_STREAM_ID, empty);
                                try out.flush();
                                continue;
                            } else if (std.mem.eql(u8, a.id, MD_SPEED_ID)) {
                                if (std.mem.eql(u8, a.item, MD_SPEED_FASTER)) {
                                    md_tick_every = @max(@as(usize, 1), md_tick_every / 2);
                                } else if (std.mem.eql(u8, a.item, MD_SPEED_SLOWER)) {
                                    md_tick_every = @min(@as(usize, 64), md_tick_every * 2);
                                } else if (std.mem.eql(u8, a.item, MD_SPEED_CHUNK_SMALLER)) {
                                    md_chunk_len = @max(@as(usize, 1), md_chunk_len / 2);
                                } else if (std.mem.eql(u8, a.item, MD_SPEED_CHUNK_LARGER)) {
                                    md_chunk_len = @min(@as(usize, 512), md_chunk_len * 2);
                                }

                                var faster_buf: [96]u8 = undefined;
                                var slower_buf: [96]u8 = undefined;
                                var chunk_smaller_buf: [96]u8 = undefined;
                                var chunk_larger_buf: [96]u8 = undefined;
                                try render.emitTextPatchById(
                                    out,
                                    MD_SPEED_FASTER,
                                    try mdSpeedFasterLabel(&faster_buf, md_tick_every),
                                );
                                try render.emitTextPatchById(
                                    out,
                                    MD_SPEED_SLOWER,
                                    try mdSpeedSlowerLabel(&slower_buf, md_tick_every),
                                );
                                try render.emitTextPatchById(
                                    out,
                                    MD_SPEED_CHUNK_SMALLER,
                                    try mdChunkSmallerLabel(&chunk_smaller_buf, md_chunk_len),
                                );
                                try render.emitTextPatchById(
                                    out,
                                    MD_SPEED_CHUNK_LARGER,
                                    try mdChunkLargerLabel(&chunk_larger_buf, md_chunk_len),
                                );
                                try out.flush();
                                continue;
                            }
                            if (state.findListSlot(lists[0..], a.id)) |slot| {
                                slot.activated.clearRetainingCapacity();
                                if (a.item.len > 0) try slot.activated.appendSlice(allocator, a.item);
                            }
                            const status_text = try state.buildStatusText(
                                allocator,
                                &status_buf,
                                state_on,
                                inputs[0..],
                                lists[0..],
                                focus_id.items,
                                term_rows,
                                term_cols,
                                if (scroll_id.items.len > 0) .{ .id = scroll_id.items, .scroll_y = scroll_y } else null,
                                popupsInfo(popup_modal_open, popup_dropdown_open, popup_tooltip_on, focus_id.items, hover_id.items, hover_item.items),
                                if (pointer_have) .{
                                    .kind = pointer_kind,
                                    .id = pointer_id.items,
                                    .item = pointer_item.items,
                                    .x = pointer_x,
                                    .y = pointer_y,
                                    .buttons = pointer_buttons,
                                    .mods = pointer_mods,
                                    .clicks = pointer_clicks,
                                    .captured = pointer_captured,
                                } else null,
                            );
                            if (widgets_changed) {
                                var tick_buf: [64]u8 = undefined;
                                const tick_text = try std.fmt.bufPrint(&tick_buf, "Tick: {d}", .{tick});

                                const layout_alt = false;
                                _ = arena_tx.reset(.retain_capacity);
                                const md_stream_node = switch (md_mode) {
                                    .tracer18 => try markdown.compileLeaky(
                                        arena_tx.allocator(),
                                        md_buf.items,
                                        .{ .id = MD_STREAM_ID, .id_prefix = MD_STREAM_ID, .own_text = false },
                                    ),
                                    .tracer19a => if (md_blocks) |*s| try s.snapshotLeaky(arena_tx.allocator()) else try markdown.compileLeaky(
                                        arena_tx.allocator(),
                                        "",
                                        .{ .id = MD_STREAM_ID, .id_prefix = MD_STREAM_ID, .own_text = false },
                                    ),
                                    .tracer19b => if (md_inline) |*s| try s.snapshotLeaky(arena_tx.allocator()) else try markdown.compileLeaky(
                                        arena_tx.allocator(),
                                        "",
                                        .{ .id = MD_STREAM_ID, .id_prefix = MD_STREAM_ID, .own_text = false },
                                    ),
                                };

                                var title_buf: [128]u8 = undefined;
                                var hint_buf: [512]u8 = undefined;
                                var faster_buf: [96]u8 = undefined;
                                var slower_buf: [96]u8 = undefined;
                                var chunk_smaller_buf: [96]u8 = undefined;
                                var chunk_larger_buf: [96]u8 = undefined;
                                const md_title = try mdStreamTitle(&title_buf, md_mode);
                                const md_hint = try mdStreamHint(&hint_buf, md_mode, md_tick_every, md_chunk_len);
                                const md_faster = try mdSpeedFasterLabel(&faster_buf, md_tick_every);
                                const md_slower = try mdSpeedSlowerLabel(&slower_buf, md_tick_every);
                                const md_chunk_smaller = try mdChunkSmallerLabel(&chunk_smaller_buf, md_chunk_len);
                                const md_chunk_larger = try mdChunkLargerLabel(&chunk_larger_buf, md_chunk_len);

                                try render.emitRootMorphPatch(
                                    arena_tx.allocator(),
                                    out,
                                    tick_text,
                                    status_text,
                                    md_stream_node,
                                    md_title,
                                    md_hint,
                                    md_faster,
                                    md_slower,
                                    md_chunk_smaller,
                                    md_chunk_larger,
                                    inputs[0..],
                                    lists[0..],
                                    layout_alt,
                                    list_height,
                                    popupsInfo(
                                        popup_modal_open,
                                        popup_dropdown_open,
                                        popup_tooltip_on,
                                        focus_id.items,
                                        hover_id.items,
                                        hover_item.items,
                                    ),
                                    widgets,
                                    tick,
                                );
                            }
                            std.debug.print("PATCH_TX target=status\n", .{});
                            try render.emitTextPatchByIdStyled(out, "status", status_text, "{\"fg\":\"#fbbf24\"}");
                            try out.flush();
                        },
                        .resize => |r| {
                            std.debug.print("EVENT_RX name=resize rows={d} cols={d}\n", .{ r.rows, r.cols });
                            term_rows = r.rows;
                            term_cols = r.cols;

                            const status_text = try state.buildStatusText(
                                allocator,
                                &status_buf,
                                state_on,
                                inputs[0..],
                                lists[0..],
                                focus_id.items,
                                term_rows,
                                term_cols,
                                if (scroll_id.items.len > 0) .{ .id = scroll_id.items, .scroll_y = scroll_y } else null,
                                popupsInfo(popup_modal_open, popup_dropdown_open, popup_tooltip_on, focus_id.items, hover_id.items, hover_item.items),
                                if (pointer_have) .{
                                    .kind = pointer_kind,
                                    .id = pointer_id.items,
                                    .item = pointer_item.items,
                                    .x = pointer_x,
                                    .y = pointer_y,
                                    .buttons = pointer_buttons,
                                    .mods = pointer_mods,
                                    .clicks = pointer_clicks,
                                    .captured = pointer_captured,
                                } else null,
                            );
                            std.debug.print("PATCH_TX target=status\n", .{});
                            try render.emitTextPatchByIdStyled(out, "status", status_text, "{\"fg\":\"#fbbf24\"}");

                            try out.flush();
                        },
                        .clipboard => |c| {
                            const op_s: []const u8 = switch (c.op) {
                                .write => "write",
                                .read => "read",
                            };
                            const ok_s: []const u8 = if (c.ok) "true" else "false";
                            const data_len: usize = if (c.data) |d| d.len else 0;
                            std.debug.print(
                                "EVENT_RX name=clipboard op={s} ok={s} request_id={d} data_len={d} reason={s}\n",
                                .{ op_s, ok_s, c.request_id, data_len, c.reason orelse "" },
                            );
                        },
                        .paste => |p| {
                            std.debug.print(
                                "EVENT_RX name=paste source={s} bytes={d}\n",
                                .{
                                    switch (p.source) {
                                        .bracketed => "bracketed",
                                        .clipboard => "clipboard",
                                    },
                                    p.bytes,
                                },
                            );
                        },
                        .rendered => |r_ev| {
                            std.debug.print(
                                "EVENT_RX name=rendered seq={d} dropped={d} bytes={d} changed_cells={d}\n",
                                .{ r_ev.seq, r_ev.dropped, r_ev.bytes, r_ev.changed_cells },
                            );
                        },
                        .dropped => |d_ev| {
                            std.debug.print(
                                "EVENT_RX name=dropped seq={d} reason={s}\n",
                                .{ d_ev.seq, d_ev.reason },
                            );
                        },
                    },
                    else => {},
                }
            },
        }
    }
}

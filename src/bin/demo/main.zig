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
        .box => |b| b.id,
        .scroll => |s| s.id,
        .overlay => |o| o.id,
        .text => |t| t.id,
        .styled_text => |t| t.id,
        .input => |i| i.id,
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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
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
        );
    }
    try out.flush();

    var stdin_buf: [4096]u8 = undefined;
    var stdin_r = std.fs.File.stdin().readerStreaming(&stdin_buf);
    var lr = jsonl.LineReader.init(allocator, &stdin_r.interface, 1024 * 1024);
    defer lr.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const stdin_fd: std.posix.fd_t = std.posix.STDIN_FILENO;

    while (true) {
        var fds = [_]std.posix.pollfd{
            .{ .fd = stdin_fd, .events = std.posix.POLL.IN, .revents = 0 },
        };

        const rc = try std.posix.poll(fds[0..], cfg.tick_interval_ms);
        if (rc == 0) {
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

        if ((fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL)) != 0) {
            return;
        }

        _ = lr.readMore() catch |e| {
            if (e == error.LineTooLong) {
                std.debug.print("backend_demo: EVENT_ERR line_too_long\n", .{});
                continue;
            }
            return e;
        };

        while (lr.nextLine()) |line| {
            _ = arena.reset(.retain_capacity);
            const msg = protocol.parseMsgLeaky(arena.allocator(), line) catch |e| {
                std.debug.print("backend_demo: EVENT_ERR {s}\n", .{@errorName(e)});
                continue;
            };

            switch (msg) {
                .event => |ev| switch (ev) {
                    .key => |k| {
                        std.debug.print("EVENT_RX name=key key={s}\n", .{k.key});
                        if (std.mem.eql(u8, k.key, "q")) {
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
                            );
                            std.debug.print("PATCH_TX target=status\n", .{});
                            try render.emitTextPatchByIdStyled(out, "status", status_text, "{\"fg\":\"#fbbf24\"}");
                            try out.flush();
                        } else if (std.mem.eql(u8, k.key, "x") or std.mem.eql(u8, k.key, "ctrl-c")) {
                            return;
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
                        );
                        try out.flush();
                    },
                    .activate => |a| {
                        std.debug.print("EVENT_RX name=activate id={s} item={s}\n", .{ a.id, a.item });
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
                            );
                            try render.emitTextPatchByIdStyled(out, "status", status_text, "{\"fg\":\"#fbbf24\"}");
                            try out.flush();
                            continue;
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
                        );
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
                        );
                        std.debug.print("PATCH_TX target=status\n", .{});
                        try render.emitTextPatchByIdStyled(out, "status", status_text, "{\"fg\":\"#fbbf24\"}");

                        try out.flush();
                    },
                },
                else => {},
            }
        }
    }
}

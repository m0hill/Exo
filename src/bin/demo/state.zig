const std = @import("std");

const tui = @import("tui");
const protocol = tui.protocol;

pub const InputSlot = struct {
    id: []const u8,
    last: std.ArrayList(u8) = .empty,
    last_len: usize = 0,
};

pub const ListSlot = struct {
    id: []const u8,
    selected: std.ArrayList(u8) = .empty,
    activated: std.ArrayList(u8) = .empty,
    items: std.ArrayList(u64) = .empty,
    next_item_id: u64,
};

pub const ScrollInfo = struct {
    id: []const u8,
    scroll_y: usize,
};

pub const PopupInfo = struct {
    modal_open: bool,
    dropdown_open: bool,
    tooltip_on: bool,
    tooltip_anchor: []const u8,
    hover_id: []const u8,
    hover_item: []const u8,
};

pub const PointerInfo = struct {
    kind: protocol.PointerKind,
    id: []const u8,
    item: []const u8,
    x: usize,
    y: usize,
    buttons: u8,
    mods: u8,
    clicks: u8,
    captured: bool,
};

pub const RadioChoice = enum { alpha, beta, gamma };
pub const TabsChoice = enum { one, two, three };
pub const MenuAnchor = enum { file, help };
pub const MenuAction = enum { none, new, open, quit, about };

pub const WidgetsState = struct {
    button_clicks: usize = 0,
    checkbox_checked: bool = false,
    toggle_on: bool = false,
    radio_choice: RadioChoice = .alpha,
    active_tab: TabsChoice = .one,
    menu_open: bool = false,
    menu_anchor: MenuAnchor = .file,
    last_menu_action: MenuAction = .none,
    tree_root_expanded: bool = true,
    tree_src_expanded: bool = true,
    tree_lib_expanded: bool = false,
    tree_tests_expanded: bool = false,
};

pub fn buildStatusText(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    state_on: bool,
    inputs: []const InputSlot,
    lists: []const ListSlot,
    focus: []const u8,
    term_rows: ?usize,
    term_cols: ?usize,
    scroll: ?ScrollInfo,
    popups: PopupInfo,
    pointer: ?PointerInfo,
) ![]const u8 {
    buf.clearRetainingCapacity();
    const w = buf.writer(allocator);
    const state_str = if (state_on) "ON" else "OFF";
    try w.print("State: {s}", .{state_str});
    if (term_rows != null and term_cols != null) {
        try w.print(" | Size: {d}x{d}", .{ term_rows.?, term_cols.? });
    }
    if (focus.len > 0) {
        try w.print(" | Focus: {s}", .{focus});
    }
    try w.print(
        " | Popups: modal={s} dropdown={s} tooltip={s}",
        .{
            if (popups.modal_open) "on" else "off",
            if (popups.dropdown_open) "on" else "off",
            if (popups.tooltip_on) "on" else "off",
        },
    );
    if (popups.tooltip_on and popups.tooltip_anchor.len > 0) {
        try w.print("(anchor={s})", .{popups.tooltip_anchor});
    }
    for (inputs) |in| {
        if (in.last_len == 0 and in.last.items.len == 0) continue;
        if (std.mem.eql(u8, in.id, "md-prompt")) {
            try w.print(" | {s} len={d}", .{ in.id, in.last_len });
            continue;
        }
        if (in.last.items.len > 0) {
            if (in.last_len > in.last.items.len) {
                try w.print(" | {s}: {s}… (len={d})", .{ in.id, in.last.items, in.last_len });
            } else {
                try w.print(" | {s}: {s}", .{ in.id, in.last.items });
            }
        } else {
            try w.print(" | {s} len={d}", .{ in.id, in.last_len });
        }
    }
    for (lists) |ls| {
        if (ls.selected.items.len > 0) {
            try w.print(" | {s} sel={s}", .{ ls.id, ls.selected.items });
        }
        if (ls.activated.items.len > 0) {
            try w.print(" act={s}", .{ls.activated.items});
        }
    }
    if (scroll) |s| {
        if (s.id.len > 0) {
            try w.print(" | Scroll: {s} y={d}", .{ s.id, s.scroll_y });
        }
    }
    if (pointer) |p| {
        try w.print(
            " | Pointer: {s} id={s} item={s} x={d} y={d} btns={d} mods={d} clicks={d} cap={s}",
            .{
                switch (p.kind) {
                    .down => "down",
                    .up => "up",
                    .move => "move",
                    .drag => "drag",
                    .scroll => "scroll",
                },
                p.id,
                p.item,
                p.x,
                p.y,
                p.buttons,
                p.mods,
                p.clicks,
                if (p.captured) "true" else "false",
            },
        );
    }
    return buf.items;
}

pub fn initItems(allocator: std.mem.Allocator, items: *std.ArrayList(u64), start: u64, end_inclusive: u64) !void {
    var n: u64 = start;
    while (n <= end_inclusive) : (n += 1) {
        try items.append(allocator, n);
    }
}

pub fn updateItems(allocator: std.mem.Allocator, slot: *ListSlot, tick: u64) void {
    if ((tick % 3) == 0) {
        const id = slot.next_item_id;
        slot.next_item_id += 1;
        _ = slot.items.insert(allocator, 0, id) catch {};
    }

    if (slot.items.items.len > 40) {
        _ = slot.items.pop();
    }

    if (slot.items.items.len >= 2 and (tick % 5) == 1) {
        const tmp = slot.items.items[0];
        slot.items.items[0] = slot.items.items[1];
        slot.items.items[1] = tmp;
    }

    if (slot.items.items.len >= 2 and (tick % 7) == 2) {
        const first = slot.items.items[0];
        var i: usize = 0;
        while (i + 1 < slot.items.items.len) : (i += 1) {
            slot.items.items[i] = slot.items.items[i + 1];
        }
        slot.items.items[slot.items.items.len - 1] = first;
    }
}

pub fn findInputSlot(inputs: []InputSlot, id: []const u8) ?*InputSlot {
    for (inputs) |*s| {
        if (std.mem.eql(u8, s.id, id)) return s;
    }
    return null;
}

pub fn findListSlot(lists: []ListSlot, id: []const u8) ?*ListSlot {
    for (lists) |*s| {
        if (std.mem.eql(u8, s.id, id)) return s;
    }
    return null;
}

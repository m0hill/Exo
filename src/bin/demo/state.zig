const std = @import("std");

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

pub fn buildStatusText(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    state_on: bool,
    inputs: []const InputSlot,
    lists: []const ListSlot,
    focus: []const u8,
    term_rows: ?usize,
    term_cols: ?usize,
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

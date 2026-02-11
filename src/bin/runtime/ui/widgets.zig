const std = @import("std");
const tui = @import("tui");
const protocol = tui.protocol;

pub const FocusKind = enum {
    input,
    list,
    vlist,
    scroll,
    textarea,
    action,
};

const InputWidgetState = struct {
    const HistoryEntry = struct {
        value: []u8,
        cursor: usize,
        selection_anchor: ?usize,
    };

    value: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    scroll_x: usize = 0,
    selection_anchor: ?usize = null,
    undo: std.ArrayList(HistoryEntry) = .empty,
    redo: std.ArrayList(HistoryEntry) = .empty,
};

const TextareaWidgetState = struct {
    const HistoryEntry = struct {
        value: []u8,
        cursor: usize,
        selection_anchor: ?usize,
    };

    value: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    scroll_y: usize = 0,
    selection_anchor: ?usize = null,
    undo: std.ArrayList(HistoryEntry) = .empty,
    redo: std.ArrayList(HistoryEntry) = .empty,
};

const ListWidgetState = struct {
    selected_id: std.ArrayList(u8) = .empty,
    scroll: usize = 0,
};

const VListWidgetState = struct {
    pub const RangeRequest = struct {
        start: usize,
        len: usize,
        request_id: u64,
    };

    pub const Window = struct {
        window_start: usize,
        window_len: usize,
    };

    scroll: usize = 0,
    selected_index: ?usize = null,
    next_request_id: u64 = 1,
    last_range_request: ?RangeRequest = null,
    last_satisfied_window: ?Window = null,
    pending_start: ?usize = null,
    pending_len: usize = 0,
    pending_reason: protocol.VListRangeReason = .init,
};

const ScrollWidgetState = struct {
    scroll_y: usize = 0,
    content_h: usize = 0,
    viewport_h: usize = 0,
};

const ActionWidgetState = struct {};

pub const WidgetState = union(enum) {
    input: InputWidgetState,
    list: ListWidgetState,
    vlist: VListWidgetState,
    scroll: ScrollWidgetState,
    textarea: TextareaWidgetState,
    action: ActionWidgetState,
};

pub const WidgetEntry = struct {
    id: std.ArrayList(u8) = .empty,
    state: WidgetState,
    state_initialized: bool = false,
};

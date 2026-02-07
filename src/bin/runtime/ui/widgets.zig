const std = @import("std");

pub const FocusKind = enum {
    input,
    list,
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

const ScrollWidgetState = struct {
    scroll_y: usize = 0,
    content_h: usize = 0,
    viewport_h: usize = 0,
};

const ActionWidgetState = struct {};

pub const WidgetState = union(enum) {
    input: InputWidgetState,
    list: ListWidgetState,
    scroll: ScrollWidgetState,
    textarea: TextareaWidgetState,
    action: ActionWidgetState,
};

pub const WidgetEntry = struct {
    id: std.ArrayList(u8) = .empty,
    state: WidgetState,
    state_initialized: bool = false,
};

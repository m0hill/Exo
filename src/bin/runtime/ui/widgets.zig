const std = @import("std");

pub const FocusKind = enum {
    input,
    list,
    scroll,
    textarea,
    action,
};

const InputWidgetState = struct {
    value: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    scroll_x: usize = 0,
};

const TextareaWidgetState = struct {
    value: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    scroll_y: usize = 0,
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
};

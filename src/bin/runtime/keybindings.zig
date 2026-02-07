const std = @import("std");

const tui = @import("tui");
const protocol = tui.protocol;

pub const Context = enum {
    global,
    input,
    textarea,
    list,
    scroll,
    action,
};

const OwnedRule = struct {
    key: []u8,
    mods: u8,
    action: protocol.KeyAction,
};

const BorrowedRule = struct {
    key: []const u8,
    mods: u8 = 0,
    action: protocol.KeyAction,
};

pub const KeymapState = struct {
    allocator: std.mem.Allocator,
    global: []OwnedRule = &.{},
    input: []OwnedRule = &.{},
    textarea: []OwnedRule = &.{},
    list: []OwnedRule = &.{},
    scroll: []OwnedRule = &.{},
    action: []OwnedRule = &.{},

    pub fn initDefaults(allocator: std.mem.Allocator) !KeymapState {
        var out: KeymapState = .{ .allocator = allocator };
        errdefer out.deinit();

        out.global = try cloneBorrowedRules(allocator, default_global_rules[0..]);
        out.input = try cloneBorrowedRules(allocator, default_input_rules[0..]);
        out.textarea = try cloneBorrowedRules(allocator, default_textarea_rules[0..]);
        out.list = try cloneBorrowedRules(allocator, default_list_rules[0..]);
        out.scroll = try cloneBorrowedRules(allocator, default_scroll_rules[0..]);
        out.action = try cloneBorrowedRules(allocator, default_action_rules[0..]);
        return out;
    }

    pub fn deinit(self: *KeymapState) void {
        freeOwnedRules(self.allocator, self.global);
        freeOwnedRules(self.allocator, self.input);
        freeOwnedRules(self.allocator, self.textarea);
        freeOwnedRules(self.allocator, self.list);
        freeOwnedRules(self.allocator, self.scroll);
        freeOwnedRules(self.allocator, self.action);
        self.* = .{ .allocator = self.allocator };
    }

    pub fn applyConfigReplace(self: *KeymapState, cfg: protocol.KeybindingsConfig) !void {
        var next = try KeymapState.initDefaults(self.allocator);
        errdefer next.deinit();

        if (cfg.global) |rules| try replaceContext(&next, .global, rules);
        if (cfg.input) |rules| try replaceContext(&next, .input, rules);
        if (cfg.textarea) |rules| try replaceContext(&next, .textarea, rules);
        if (cfg.list) |rules| try replaceContext(&next, .list, rules);
        if (cfg.scroll) |rules| try replaceContext(&next, .scroll, rules);
        if (cfg.action) |rules| try replaceContext(&next, .action, rules);

        self.deinit();
        self.* = next;
    }

    pub fn resolve(self: *const KeymapState, context: ?Context, key: []const u8, mods: u8) ?protocol.KeyAction {
        if (context) |ctx| {
            if (matchIn(self.rulesForContext(ctx), key, mods)) |action| return action;
        }
        return matchIn(self.global, key, mods);
    }

    fn rulesForContext(self: *const KeymapState, ctx: Context) []const OwnedRule {
        return switch (ctx) {
            .global => self.global,
            .input => self.input,
            .textarea => self.textarea,
            .list => self.list,
            .scroll => self.scroll,
            .action => self.action,
        };
    }
};

fn replaceContext(state: *KeymapState, context: Context, rules: []const protocol.KeybindingRule) !void {
    const next_rules = try cloneProtocolRules(state.allocator, rules);
    const slot: *[]OwnedRule = switch (context) {
        .global => &state.global,
        .input => &state.input,
        .textarea => &state.textarea,
        .list => &state.list,
        .scroll => &state.scroll,
        .action => &state.action,
    };
    freeOwnedRules(state.allocator, slot.*);
    slot.* = next_rules;
}

fn matchIn(rules: []const OwnedRule, key: []const u8, mods: u8) ?protocol.KeyAction {
    for (rules) |rule| {
        if (rule.mods == mods and std.mem.eql(u8, rule.key, key)) return rule.action;
    }
    return null;
}

fn cloneProtocolRules(allocator: std.mem.Allocator, rules: []const protocol.KeybindingRule) ![]OwnedRule {
    if (rules.len == 0) return &.{};
    var out = try allocator.alloc(OwnedRule, rules.len);
    errdefer allocator.free(out);
    for (rules, 0..) |rule, idx| {
        out[idx] = .{
            .key = try allocator.dupe(u8, rule.key),
            .mods = rule.mods,
            .action = rule.action,
        };
    }
    return out;
}

fn cloneBorrowedRules(allocator: std.mem.Allocator, rules: []const BorrowedRule) ![]OwnedRule {
    if (rules.len == 0) return &.{};
    var out = try allocator.alloc(OwnedRule, rules.len);
    errdefer allocator.free(out);
    for (rules, 0..) |rule, idx| {
        out[idx] = .{
            .key = try allocator.dupe(u8, rule.key),
            .mods = rule.mods,
            .action = rule.action,
        };
    }
    return out;
}

fn freeOwnedRules(allocator: std.mem.Allocator, rules: []OwnedRule) void {
    if (rules.len == 0) return;
    for (rules) |rule| allocator.free(rule.key);
    allocator.free(rules);
}

const default_global_rules = [_]BorrowedRule{
    .{ .key = "Tab", .mods = 0, .action = .focus_next },
    .{ .key = "Tab", .mods = 1, .action = .focus_prev },
    .{ .key = "Escape", .mods = 0, .action = .focus_clear },
};

const default_input_rules = [_]BorrowedRule{
    .{ .key = "ArrowLeft", .mods = 0, .action = .input_left },
    .{ .key = "ArrowRight", .mods = 0, .action = .input_right },
    .{ .key = "ArrowLeft", .mods = 4, .action = .input_word_left },
    .{ .key = "ArrowRight", .mods = 4, .action = .input_word_right },
    .{ .key = "b", .mods = 4, .action = .input_word_left },
    .{ .key = "f", .mods = 4, .action = .input_word_right },
    .{ .key = "Home", .mods = 0, .action = .input_home },
    .{ .key = "End", .mods = 0, .action = .input_end },
    .{ .key = "Delete", .mods = 0, .action = .input_delete },
    .{ .key = "Backspace", .mods = 0, .action = .input_backspace },
    .{ .key = "ArrowLeft", .mods = 1, .action = .input_select_left },
    .{ .key = "ArrowRight", .mods = 1, .action = .input_select_right },
    .{ .key = "ArrowLeft", .mods = 3, .action = .input_select_word_left },
    .{ .key = "ArrowRight", .mods = 3, .action = .input_select_word_right },
    .{ .key = "Home", .mods = 1, .action = .input_select_home },
    .{ .key = "End", .mods = 1, .action = .input_select_end },
    .{ .key = "a", .mods = 2, .action = .input_select_all },
    .{ .key = "c", .mods = 2, .action = .input_copy },
    .{ .key = "v", .mods = 2, .action = .input_paste },
    .{ .key = "z", .mods = 2, .action = .input_undo },
    .{ .key = "y", .mods = 2, .action = .input_redo },
};

const default_textarea_rules = [_]BorrowedRule{
    .{ .key = "ArrowLeft", .mods = 0, .action = .textarea_left },
    .{ .key = "ArrowRight", .mods = 0, .action = .textarea_right },
    .{ .key = "ArrowUp", .mods = 0, .action = .textarea_up },
    .{ .key = "ArrowDown", .mods = 0, .action = .textarea_down },
    .{ .key = "ArrowLeft", .mods = 4, .action = .textarea_word_left },
    .{ .key = "ArrowRight", .mods = 4, .action = .textarea_word_right },
    .{ .key = "b", .mods = 4, .action = .textarea_word_left },
    .{ .key = "f", .mods = 4, .action = .textarea_word_right },
    .{ .key = "Home", .mods = 0, .action = .textarea_home },
    .{ .key = "End", .mods = 0, .action = .textarea_end },
    .{ .key = "PageUp", .mods = 0, .action = .textarea_page_up },
    .{ .key = "PageDown", .mods = 0, .action = .textarea_page_down },
    .{ .key = "Delete", .mods = 0, .action = .textarea_delete },
    .{ .key = "Backspace", .mods = 0, .action = .textarea_backspace },
    .{ .key = "Enter", .mods = 0, .action = .textarea_newline },
    .{ .key = "ArrowLeft", .mods = 1, .action = .textarea_select_left },
    .{ .key = "ArrowRight", .mods = 1, .action = .textarea_select_right },
    .{ .key = "ArrowUp", .mods = 1, .action = .textarea_select_up },
    .{ .key = "ArrowDown", .mods = 1, .action = .textarea_select_down },
    .{ .key = "ArrowLeft", .mods = 3, .action = .textarea_select_word_left },
    .{ .key = "ArrowRight", .mods = 3, .action = .textarea_select_word_right },
    .{ .key = "Home", .mods = 1, .action = .textarea_select_home },
    .{ .key = "End", .mods = 1, .action = .textarea_select_end },
    .{ .key = "a", .mods = 2, .action = .textarea_select_all },
    .{ .key = "c", .mods = 2, .action = .textarea_copy },
    .{ .key = "v", .mods = 2, .action = .textarea_paste },
    .{ .key = "z", .mods = 2, .action = .textarea_undo },
    .{ .key = "y", .mods = 2, .action = .textarea_redo },
};

const default_list_rules = [_]BorrowedRule{
    .{ .key = "ArrowUp", .mods = 0, .action = .list_prev },
    .{ .key = "ArrowDown", .mods = 0, .action = .list_next },
    .{ .key = "k", .mods = 0, .action = .list_prev },
    .{ .key = "j", .mods = 0, .action = .list_next },
    .{ .key = "Enter", .mods = 0, .action = .list_activate },
};

const default_scroll_rules = [_]BorrowedRule{
    .{ .key = "k", .mods = 0, .action = .scroll_line_up },
    .{ .key = "j", .mods = 0, .action = .scroll_line_down },
    .{ .key = "PageUp", .mods = 0, .action = .scroll_page_up },
    .{ .key = "PageDown", .mods = 0, .action = .scroll_page_down },
    .{ .key = "Home", .mods = 0, .action = .scroll_home },
    .{ .key = "End", .mods = 0, .action = .scroll_end },
};

const default_action_rules = [_]BorrowedRule{
    .{ .key = "Enter", .mods = 0, .action = .action_activate },
    .{ .key = " ", .mods = 0, .action = .action_activate },
};

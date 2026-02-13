const std = @import("std");
const style = @import("../style.zig");

pub const NodeKind = enum {
    vbox,
    hbox,
    grid,
    box,
    scroll,
    overlay,
    text,
    styled_text,
    input,
    textarea,
    list,
};

const NODE_KIND_COUNT: usize = @typeInfo(NodeKind).@"enum".fields.len;

pub const StateFlags = struct {
    bits: u16 = 0,

    pub const hovered: u16 = 1 << 0;
    pub const focused: u16 = 1 << 1;
    pub const active: u16 = 1 << 2;
    pub const disabled: u16 = 1 << 3;
    pub const readonly: u16 = 1 << 4;
    pub const validation_error: u16 = 1 << 5;
    pub const validation_warning: u16 = 1 << 6;
    pub const validation_success: u16 = 1 << 7;

    pub fn has(self: StateFlags, mask: u16) bool {
        return (self.bits & mask) == mask;
    }
};

pub const CompiledRule = struct {
    kind: ?NodeKind = null,
    id: ?[]const u8 = null,
    classes: []const []const u8 = &.{},
    states_required: StateFlags = .{},
    style: style.StyleOverride = .{},
    specificity: u16 = 0,
    order: u16 = 0,
};

const RuleIndexSlice = []const u16;

pub const ThemeEngine = struct {
    all_rules: []const CompiledRule = &.{},
    wildcard_rule_indices: RuleIndexSlice = &.{},
    kind_rule_indices: [NODE_KIND_COUNT]RuleIndexSlice = [_]RuleIndexSlice{&.{}} ** NODE_KIND_COUNT,

    pub fn resolveOverride(
        self: ThemeEngine,
        kind: NodeKind,
        id: []const u8,
        class_str: ?[]const u8,
        state_flags: StateFlags,
    ) ?style.StyleOverride {
        var out: style.StyleOverride = .{};
        var any: bool = false;

        var fg_best_spec: i32 = -1;
        var fg_best_order: i32 = -1;
        var bg_best_spec: i32 = -1;
        var bg_best_order: i32 = -1;

        var attr_best_spec: [8]i32 = [_]i32{-1} ** 8;
        var attr_best_order: [8]i32 = [_]i32{-1} ** 8;

        self.applyBucket(
            self.wildcard_rule_indices,
            kind,
            id,
            class_str,
            state_flags,
            &out,
            &any,
            &fg_best_spec,
            &fg_best_order,
            &bg_best_spec,
            &bg_best_order,
            &attr_best_spec,
            &attr_best_order,
        );
        self.applyBucket(
            self.kind_rule_indices[@intFromEnum(kind)],
            kind,
            id,
            class_str,
            state_flags,
            &out,
            &any,
            &fg_best_spec,
            &fg_best_order,
            &bg_best_spec,
            &bg_best_order,
            &attr_best_spec,
            &attr_best_order,
        );

        return if (any) out else null;
    }

    fn applyBucket(
        self: ThemeEngine,
        bucket: RuleIndexSlice,
        kind: NodeKind,
        id: []const u8,
        class_str: ?[]const u8,
        state_flags: StateFlags,
        out: *style.StyleOverride,
        any: *bool,
        fg_best_spec: *i32,
        fg_best_order: *i32,
        bg_best_spec: *i32,
        bg_best_order: *i32,
        attr_best_spec: *[8]i32,
        attr_best_order: *[8]i32,
    ) void {
        for (bucket) |rule_idx| {
            const rule = self.all_rules[rule_idx];
            if (!ruleMatches(rule, kind, id, class_str, state_flags)) continue;

            const spec: i32 = @intCast(rule.specificity);
            const order: i32 = @intCast(rule.order);

            if (rule.style.fg != .inherit and betterWinner(spec, order, fg_best_spec.*, fg_best_order.*)) {
                out.fg = rule.style.fg;
                fg_best_spec.* = spec;
                fg_best_order.* = order;
                any.* = true;
            }

            if (rule.style.bg != .inherit and betterWinner(spec, order, bg_best_spec.*, bg_best_order.*)) {
                out.bg = rule.style.bg;
                bg_best_spec.* = spec;
                bg_best_order.* = order;
                any.* = true;
            }

            var bit_idx: usize = 0;
            while (bit_idx < 8) : (bit_idx += 1) {
                const bit: u8 = @as(u8, 1) << @intCast(bit_idx);
                if ((rule.style.attrs_set & bit) == 0) continue;
                if (!betterWinner(spec, order, attr_best_spec.*[bit_idx], attr_best_order.*[bit_idx])) continue;

                out.attrs_set |= bit;
                if ((rule.style.attrs_values & bit) != 0) {
                    out.attrs_values |= bit;
                } else {
                    out.attrs_values &= ~bit;
                }
                attr_best_spec.*[bit_idx] = spec;
                attr_best_order.*[bit_idx] = order;
                any.* = true;
            }
        }
    }
};

fn betterWinner(spec: i32, order: i32, best_spec: i32, best_order: i32) bool {
    if (best_spec < 0) return true;
    if (spec > best_spec) return true;
    if (spec < best_spec) return false;
    return order >= best_order;
}

fn ruleMatches(rule: CompiledRule, kind: NodeKind, id: []const u8, class_str: ?[]const u8, state_flags: StateFlags) bool {
    if (rule.kind) |rk| {
        if (rk != kind) return false;
    }
    if (rule.id) |rid| {
        if (!std.mem.eql(u8, rid, id)) return false;
    }
    if (!state_flags.has(rule.states_required.bits)) return false;
    for (rule.classes) |required_class| {
        if (!matchSelectorClassToken(required_class, class_str)) return false;
    }
    return true;
}

fn isSpace(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\n' or b == '\r' or b == '\x0B' or b == '\x0C';
}

fn dotBoundaryPrefix(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return false;
    if (!std.mem.startsWith(u8, haystack, needle)) return false;
    if (haystack.len == needle.len) return true;
    return haystack[needle.len] == '.';
}

pub fn matchSelectorClassToken(required: []const u8, class_str: ?[]const u8) bool {
    const raw = class_str orelse return false;
    var i: usize = 0;
    while (i < raw.len) {
        while (i < raw.len and isSpace(raw[i])) : (i += 1) {}
        if (i >= raw.len) break;
        const start = i;
        while (i < raw.len and !isSpace(raw[i])) : (i += 1) {}
        const token = raw[start..i];
        if (dotBoundaryPrefix(token, required)) return true;
    }
    return false;
}

pub const ParseSelectorError = error{ InvalidSelector, SelectorTooLong };

pub const ParsedSelector = struct {
    kind: ?NodeKind = null,
    id: ?[]const u8 = null,
    classes: []const []const u8 = &.{},
    states_required: StateFlags = .{},
    specificity: u16 = 0,
};

pub fn parseSelectorLeaky(
    allocator: std.mem.Allocator,
    selector: []const u8,
    max_selector_len: usize,
    max_classes: usize,
) ParseSelectorError!ParsedSelector {
    if (selector.len == 0) return error.InvalidSelector;
    if (selector.len > max_selector_len) return error.SelectorTooLong;

    var i: usize = 0;
    var out: ParsedSelector = .{};

    if (selector[i] == '*') {
        i += 1;
    } else if (isIdentStart(selector[i])) {
        const start = i;
        i += 1;
        while (i < selector.len and isIdentChar(selector[i])) : (i += 1) {}
        out.kind = parseNodeKind(selector[start..i]) catch return error.InvalidSelector;
        out.specificity += 1;
    }

    if (i < selector.len and selector[i] == '#') {
        i += 1;
        const start = i;
        if (start >= selector.len or !isIdentStart(selector[start])) return error.InvalidSelector;
        i += 1;
        while (i < selector.len and isIdentChar(selector[i])) : (i += 1) {}
        out.id = selector[start..i];
        out.specificity += 100;
    }

    var class_list = std.ArrayList([]const u8).empty;
    defer class_list.deinit(allocator);

    while (i < selector.len and selector[i] == '.') {
        i += 1;
        const start = i;
        if (start >= selector.len or !isClassChar(selector[start])) return error.InvalidSelector;
        i += 1;
        while (i < selector.len and selector[i] != ':' and selector[i] != '#') : (i += 1) {
            if (!isClassChar(selector[i])) return error.InvalidSelector;
        }
        if (i == start) return error.InvalidSelector;
        if (class_list.items.len >= max_classes) return error.InvalidSelector;
        class_list.append(allocator, selector[start..i]) catch return error.InvalidSelector;
        out.specificity += 10;
    }

    while (i < selector.len and selector[i] == ':') {
        i += 1;
        const start = i;
        if (start >= selector.len or !isIdentStart(selector[start])) return error.InvalidSelector;
        i += 1;
        while (i < selector.len and isIdentChar(selector[i])) : (i += 1) {}
        const state_name = selector[start..i];
        out.states_required.bits |= parseState(state_name) catch return error.InvalidSelector;
        out.specificity += 10;
    }

    if (i != selector.len) return error.InvalidSelector;

    out.classes = class_list.toOwnedSlice(allocator) catch return error.InvalidSelector;
    return out;
}

pub fn parseSelectorValidate(selector: []const u8, max_selector_len: usize) ParseSelectorError!void {
    var fixed: [8][]const u8 = undefined;
    var class_len: usize = 0;

    if (selector.len == 0) return error.InvalidSelector;
    if (selector.len > max_selector_len) return error.SelectorTooLong;

    var i: usize = 0;
    if (selector[i] == '*') {
        i += 1;
    } else if (isIdentStart(selector[i])) {
        const start = i;
        i += 1;
        while (i < selector.len and isIdentChar(selector[i])) : (i += 1) {}
        _ = parseNodeKind(selector[start..i]) catch return error.InvalidSelector;
    }

    if (i < selector.len and selector[i] == '#') {
        i += 1;
        if (i >= selector.len or !isIdentStart(selector[i])) return error.InvalidSelector;
        i += 1;
        while (i < selector.len and isIdentChar(selector[i])) : (i += 1) {}
    }

    while (i < selector.len and selector[i] == '.') {
        i += 1;
        const start = i;
        if (start >= selector.len or !isClassChar(selector[start])) return error.InvalidSelector;
        i += 1;
        while (i < selector.len and selector[i] != ':' and selector[i] != '#') : (i += 1) {
            if (!isClassChar(selector[i])) return error.InvalidSelector;
        }
        if (i == start) return error.InvalidSelector;
        if (class_len >= fixed.len) return error.InvalidSelector;
        fixed[class_len] = selector[start..i];
        class_len += 1;
    }

    while (i < selector.len and selector[i] == ':') {
        i += 1;
        const start = i;
        if (start >= selector.len or !isIdentStart(selector[start])) return error.InvalidSelector;
        i += 1;
        while (i < selector.len and isIdentChar(selector[i])) : (i += 1) {}
        _ = parseState(selector[start..i]) catch return error.InvalidSelector;
    }

    if (i != selector.len) return error.InvalidSelector;
}

fn parseState(s: []const u8) error{InvalidSelector}!u16 {
    if (std.mem.eql(u8, s, "hover")) return StateFlags.hovered;
    if (std.mem.eql(u8, s, "focus")) return StateFlags.focused;
    if (std.mem.eql(u8, s, "active")) return StateFlags.active;
    if (std.mem.eql(u8, s, "disabled")) return StateFlags.disabled;
    if (std.mem.eql(u8, s, "readonly")) return StateFlags.readonly;
    if (std.mem.eql(u8, s, "validation_error")) return StateFlags.validation_error;
    if (std.mem.eql(u8, s, "validation_warning")) return StateFlags.validation_warning;
    if (std.mem.eql(u8, s, "validation_success")) return StateFlags.validation_success;
    return error.InvalidSelector;
}

fn parseNodeKind(s: []const u8) error{InvalidSelector}!NodeKind {
    if (std.mem.eql(u8, s, "vbox")) return .vbox;
    if (std.mem.eql(u8, s, "hbox")) return .hbox;
    if (std.mem.eql(u8, s, "grid")) return .grid;
    if (std.mem.eql(u8, s, "box")) return .box;
    if (std.mem.eql(u8, s, "scroll")) return .scroll;
    if (std.mem.eql(u8, s, "overlay")) return .overlay;
    if (std.mem.eql(u8, s, "text")) return .text;
    if (std.mem.eql(u8, s, "styled_text")) return .styled_text;
    if (std.mem.eql(u8, s, "input")) return .input;
    if (std.mem.eql(u8, s, "textarea")) return .textarea;
    if (std.mem.eql(u8, s, "list")) return .list;
    return error.InvalidSelector;
}

fn isIdentStart(b: u8) bool {
    return (b >= 'A' and b <= 'Z') or (b >= 'a' and b <= 'z') or b == '_';
}

fn isIdentChar(b: u8) bool {
    return isIdentStart(b) or (b >= '0' and b <= '9') or b == '-';
}

fn isClassChar(b: u8) bool {
    return isIdentChar(b) or b == '.';
}

pub fn buildEngineLeaky(
    allocator: std.mem.Allocator,
    all_rules: []const CompiledRule,
) std.mem.Allocator.Error!ThemeEngine {
    var wildcard_count: usize = 0;
    var kind_counts: [NODE_KIND_COUNT]usize = [_]usize{0} ** NODE_KIND_COUNT;

    for (all_rules) |rule| {
        if (rule.kind) |k| {
            kind_counts[@intFromEnum(k)] += 1;
        } else {
            wildcard_count += 1;
        }
    }

    var wildcard_rule_indices_mut = try allocator.alloc(u16, wildcard_count);
    var kind_rule_indices_mut: [NODE_KIND_COUNT][]u16 = undefined;
    for (&kind_rule_indices_mut, 0..) |*slot, idx| {
        slot.* = try allocator.alloc(u16, kind_counts[idx]);
    }

    var wildcard_idx: usize = 0;
    var kind_idx: [NODE_KIND_COUNT]usize = [_]usize{0} ** NODE_KIND_COUNT;

    for (all_rules, 0..) |rule, rule_idx| {
        const idx16: u16 = @intCast(rule_idx);
        if (rule.kind) |k| {
            const kind_i = @intFromEnum(k);
            kind_rule_indices_mut[kind_i][kind_idx[kind_i]] = idx16;
            kind_idx[kind_i] += 1;
        } else {
            wildcard_rule_indices_mut[wildcard_idx] = idx16;
            wildcard_idx += 1;
        }
    }

    var kind_rule_indices: [NODE_KIND_COUNT]RuleIndexSlice = [_]RuleIndexSlice{&.{}} ** NODE_KIND_COUNT;
    for (&kind_rule_indices, 0..) |*slot, idx| {
        slot.* = kind_rule_indices_mut[idx];
    }

    return .{
        .all_rules = all_rules,
        .wildcard_rule_indices = wildcard_rule_indices_mut,
        .kind_rule_indices = kind_rule_indices,
    };
}

fn ConstIndexDataType(comptime all_rules: []const CompiledRule) type {
    comptime var wildcard_count: usize = 0;
    comptime var kind_counts: [NODE_KIND_COUNT]usize = [_]usize{0} ** NODE_KIND_COUNT;

    for (all_rules) |rule| {
        if (rule.kind) |k| {
            kind_counts[@intFromEnum(k)] += 1;
        } else {
            wildcard_count += 1;
        }
    }

    comptime var max_kind_count: usize = 0;
    for (kind_counts) |n| {
        if (n > max_kind_count) max_kind_count = n;
    }
    if (max_kind_count == 0) max_kind_count = 1;

    return struct {
        wildcard_buf: [wildcard_count]u16,
        kind_buf: [NODE_KIND_COUNT][max_kind_count]u16,
        kind_counts: [NODE_KIND_COUNT]usize,
    };
}

pub fn buildConstIndexData(comptime all_rules: []const CompiledRule) ConstIndexDataType(all_rules) {
    comptime var wildcard_count: usize = 0;
    comptime var kind_counts: [NODE_KIND_COUNT]usize = [_]usize{0} ** NODE_KIND_COUNT;

    for (all_rules) |rule| {
        if (rule.kind) |k| {
            kind_counts[@intFromEnum(k)] += 1;
        } else {
            wildcard_count += 1;
        }
    }

    comptime var max_kind_count: usize = 0;
    for (kind_counts) |n| {
        if (n > max_kind_count) max_kind_count = n;
    }
    if (max_kind_count == 0) max_kind_count = 1;

    var wildcard_buf: [wildcard_count]u16 = undefined;
    var kind_buf: [NODE_KIND_COUNT][max_kind_count]u16 = undefined;
    var kind_idx: [NODE_KIND_COUNT]usize = [_]usize{0} ** NODE_KIND_COUNT;
    var wildcard_idx: usize = 0;

    for (all_rules, 0..) |rule, rule_idx| {
        const idx16: u16 = @intCast(rule_idx);
        if (rule.kind) |k| {
            const kind_i = @intFromEnum(k);
            kind_buf[kind_i][kind_idx[kind_i]] = idx16;
            kind_idx[kind_i] += 1;
        } else {
            wildcard_buf[wildcard_idx] = idx16;
            wildcard_idx += 1;
        }
    }

    return .{
        .wildcard_buf = wildcard_buf,
        .kind_buf = kind_buf,
        .kind_counts = kind_counts,
    };
}

pub fn buildEngineFromConstIndices(
    all_rules: []const CompiledRule,
    data: anytype,
) ThemeEngine {
    var kind_rule_indices: [NODE_KIND_COUNT]RuleIndexSlice = [_]RuleIndexSlice{&.{}} ** NODE_KIND_COUNT;
    for (&kind_rule_indices, 0..) |*slot, idx| {
        const count: usize = data.kind_counts[idx];
        slot.* = data.kind_buf[idx][0..count];
    }
    return .{
        .all_rules = all_rules,
        .wildcard_rule_indices = data.wildcard_buf[0..],
        .kind_rule_indices = kind_rule_indices,
    };
}

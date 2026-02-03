const std = @import("std");

pub fn monotonicNowNs() u64 {
    const t = std.time.nanoTimestamp();
    if (t <= 0) return 0;
    return @as(u64, @intCast(t));
}

pub const resize_debounce_ns: u64 = 100 * std.time.ns_per_ms;
pub const backend_frame_interval_ns: u64 = 33 * std.time.ns_per_ms;
pub const max_pending_targets: usize = 256;
pub const max_backend_lines_per_iter: usize = 128;

pub fn minTimeoutMs(a: i32, b: i32) i32 {
    if (a < 0) return b;
    if (b < 0) return a;
    return if (a < b) a else b;
}

pub fn pollTimeoutMsForPendingFrame(now_ns: u64, last_render_ns: u64, has_pending: bool) i32 {
    if (!has_pending) return -1;
    if (last_render_ns == 0) return 0;
    const deadline = last_render_ns + backend_frame_interval_ns;
    if (now_ns >= deadline) return 0;
    const remaining_ns: u64 = deadline - now_ns;
    const ms: u64 = (remaining_ns + (std.time.ns_per_ms - 1)) / std.time.ns_per_ms;
    const max_i32: u64 = @as(u64, @intCast(std.math.maxInt(i32)));
    return @as(i32, @intCast(if (ms > max_i32) max_i32 else ms));
}

pub fn pollTimeoutMsForPendingResize(pending_resize: anytype, last_resize_tx_ns: u64) i32 {
    if (pending_resize == null) return -1;
    const now_ns = monotonicNowNs();
    if (last_resize_tx_ns == 0) return 0;
    const deadline = last_resize_tx_ns + resize_debounce_ns;
    if (now_ns >= deadline) return 0;
    const remaining_ns: u64 = deadline - now_ns;
    const ms: u64 = (remaining_ns + (std.time.ns_per_ms - 1)) / std.time.ns_per_ms;
    const max_i32: u64 = @as(u64, @intCast(std.math.maxInt(i32)));
    return @as(i32, @intCast(if (ms > max_i32) max_i32 else ms));
}

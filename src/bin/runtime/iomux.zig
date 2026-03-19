const std = @import("std");
const builtin = @import("builtin");

const tui = @import("tui");
const jsonl = tui.jsonl;
const terminal = tui.terminal;

pub const ExitSignal = enum {
    sigint,
    sigterm,
    ctrl_close,
};

pub const Event = union(enum) {
    stdin_bytes: []u8,
    backend_line: []u8,
    backend_line_too_long,
    backend_stderr: []u8,
    resize: terminal.Size,
    exit_signal: ExitSignal,
    backend_closed,
};

const Queue = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    buf: []Event,
    head: usize = 0,
    len: usize = 0,
    closed: bool = false,

    fn init(allocator: std.mem.Allocator, cap: usize) !Queue {
        return .{ .allocator = allocator, .buf = try allocator.alloc(Event, cap) };
    }

    fn deinit(self: *Queue) void {
        self.freePendingOwnedEvents();
        self.allocator.free(self.buf);
        self.buf = &.{};
    }

    fn freePendingOwnedEvents(self: *Queue) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            const idx = (self.head + i) % self.buf.len;
            switch (self.buf[idx]) {
                .stdin_bytes => |bytes| self.allocator.free(bytes),
                .backend_line => |line| self.allocator.free(line),
                .backend_stderr => |bytes| self.allocator.free(bytes),
                else => {},
            }
        }
        self.head = 0;
        self.len = 0;
    }

    fn close(self: *Queue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.closed = true;
        self.cond.broadcast();
    }

    fn isClosed(self: *Queue) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.closed;
    }

    fn push(self: *Queue, ev: Event) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.closed) return false;

        while (self.len == self.buf.len and !self.closed) {
            self.cond.wait(&self.mutex);
        }
        if (self.closed) return false;

        const idx = (self.head + self.len) % self.buf.len;
        self.buf[idx] = ev;
        self.len += 1;
        self.cond.signal();
        return true;
    }

    fn pushDropIfFull(self: *Queue, ev: Event) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closed) return false;
        if (self.len == self.buf.len) return false;
        const idx = (self.head + self.len) % self.buf.len;
        self.buf[idx] = ev;
        self.len += 1;
        self.cond.signal();
        return true;
    }

    fn popTimeout(self: *Queue, timeout_ms: i32) ?Event {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (timeout_ms < 0) {
            while (self.len == 0 and !self.closed) {
                self.cond.wait(&self.mutex);
            }
        } else {
            var deadline = std.time.Timer.start() catch null;
            while (self.len == 0 and !self.closed) {
                if (deadline) |*t| {
                    const elapsed = t.read();
                    const elapsed_ms: u64 = elapsed / std.time.ns_per_ms;
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
        self.cond.signal();
        return ev;
    }
};

pub const IOMux = struct {
    allocator: std.mem.Allocator,
    queue: Queue,

    term: *terminal.Terminal,
    backend_out: std.fs.File,
    backend_err: std.fs.File,

    backend_out_thread: ?std.Thread = null,
    backend_err_thread: ?std.Thread = null,
    resize_thread: ?std.Thread = null,
    signal_thread: ?std.Thread = null,
    signals: Signals = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        term: *terminal.Terminal,
        backend_out: std.fs.File,
        backend_err: std.fs.File,
    ) !IOMux {
        return .{
            .allocator = allocator,
            .queue = try Queue.init(allocator, 256),
            .term = term,
            .backend_out = backend_out,
            .backend_err = backend_err,
        };
    }

    pub fn start(self: *IOMux) !void {
        // Stdin reader thread (detached: cannot reliably interrupt a blocking read).
        var stdin_thread = try std.Thread.spawn(.{}, stdinThreadMain, .{self});
        stdin_thread.detach();

        self.backend_out_thread = try std.Thread.spawn(.{}, backendOutThreadMain, .{self});
        self.backend_err_thread = try std.Thread.spawn(.{}, backendErrThreadMain, .{self});
        self.resize_thread = try std.Thread.spawn(.{}, resizeThreadMain, .{self});
        try self.signals.install(self);
    }

    pub fn deinit(self: *IOMux) void {
        self.queue.close();

        // Close backend read handles to interrupt reader threads.
        self.backend_out.close();
        self.backend_err.close();

        if (self.backend_out_thread) |t| t.join();
        if (self.backend_err_thread) |t| t.join();
        if (self.resize_thread) |t| t.join();
        if (self.signal_thread) |t| t.join();

        self.signals.uninstall();
        self.queue.deinit();
    }

    pub fn recvTimeout(self: *IOMux, timeout_ms: i32) ?Event {
        return self.queue.popTimeout(timeout_ms);
    }

    fn stdinThreadMain(self: *IOMux) void {
        var tmp: [4096]u8 = undefined;
        while (true) {
            const n = self.term.read(&tmp) catch return;
            if (n == 0) return;
            const owned = self.allocator.dupe(u8, tmp[0..n]) catch return;
            if (!self.queue.push(.{ .stdin_bytes = owned })) {
                self.allocator.free(owned);
                return;
            }
        }
    }

    fn backendOutThreadMain(self: *IOMux) void {
        var buf: [4096]u8 = undefined;
        var r = self.backend_out.readerStreaming(&buf);
        var lr = jsonl.LineReader.init(self.allocator, &r.interface, 1024 * 1024);
        defer lr.deinit();

        while (true) {
            const n = lr.readMore() catch |e| {
                if (e == error.LineTooLong) {
                    _ = self.queue.push(.backend_line_too_long);
                    continue;
                }
                _ = self.queue.push(.backend_closed);
                return;
            };

            while (lr.nextLine()) |line| {
                const owned = self.allocator.dupe(u8, line) catch return;
                if (!self.queue.push(.{ .backend_line = owned })) {
                    self.allocator.free(owned);
                    return;
                }
            }

            if (n == 0 and lr.eof) {
                _ = self.queue.push(.backend_closed);
                return;
            }
        }
    }

    fn backendErrThreadMain(self: *IOMux) void {
        var tmp: [4096]u8 = undefined;
        while (true) {
            const n = self.backend_err.read(&tmp) catch return;
            if (n == 0) return;
            const owned = self.allocator.dupe(u8, tmp[0..n]) catch return;
            if (!self.queue.push(.{ .backend_stderr = owned })) {
                self.allocator.free(owned);
                return;
            }
        }
    }

    fn resizeThreadMain(self: *IOMux) void {
        var last: ?terminal.Size = null;
        while (true) {
            if (self.queue.isClosed()) return;
            std.Thread.sleep(100 * std.time.ns_per_ms);
            const sz = self.term.getSize() catch continue;
            if (last) |prev| {
                if (prev.rows == sz.rows and prev.cols == sz.cols) continue;
            }
            last = sz;
            if (!self.queue.push(.{ .resize = sz })) return;
        }
    }

    fn signalThreadMain(self: *IOMux) void {
        while (true) {
            const sig = self.signals.drain() orelse {
                if (self.queue.isClosed()) return;
                std.Thread.sleep(20 * std.time.ns_per_ms);
                continue;
            };
            if (!self.queue.push(.{ .exit_signal = sig })) return;
        }
    }
};

const Signals = if (builtin.os.tag == .windows) WindowsSignals else PosixSignals;

const PosixSignals = struct {
    sig_r: std.posix.fd_t = -1,
    sig_w: std.posix.fd_t = -1,

    fn install(self: *PosixSignals, mux: *IOMux) !void {
        const pipe = try std.posix.pipe();
        self.sig_r = pipe[0];
        self.sig_w = pipe[1];
        setFdNonBlocking(self.sig_r);
        setFdNonBlocking(self.sig_w);
        posix_sig_w_fd = self.sig_w;
        installSigintSigtermHandlers();
        mux.signal_thread = try std.Thread.spawn(.{}, IOMux.signalThreadMain, .{mux});
    }

    fn uninstall(self: *PosixSignals) void {
        posix_sig_w_fd = -1;
        if (self.sig_r >= 0) std.posix.close(self.sig_r);
        if (self.sig_w >= 0) std.posix.close(self.sig_w);
        self.sig_r = -1;
        self.sig_w = -1;
    }

    fn drain(self: *PosixSignals) ?ExitSignal {
        return drainSigPipe(self.sig_r);
    }
};

const WindowsSignals = struct {
    installed: bool = false,

    fn install(self: *WindowsSignals, mux: *IOMux) !void {
        win_setMux(mux);
        self.installed = (windowsInstallCtrlHandler() catch false);
    }

    fn uninstall(self: *WindowsSignals) void {
        if (self.installed) {
            _ = windowsUninstallCtrlHandler() catch {};
            self.installed = false;
        }
        win_setMux(null);
    }

    fn drain(_: *WindowsSignals) ?ExitSignal {
        return null;
    }
};

// --- POSIX signals (lazy on Windows) ---

var posix_sig_w_fd: std.posix.fd_t = -1;

fn posixSignalHandler(sig: c_int) callconv(.c) void {
    if (posix_sig_w_fd < 0) return;
    const b: [1]u8 = .{@as(u8, @intCast(sig))};
    _ = std.posix.system.write(posix_sig_w_fd, &b, 1);
}

fn installSigintSigtermHandlers() void {
    var sa: std.posix.Sigaction = .{
        .handler = .{ .handler = posixSignalHandler },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART,
    };
    std.posix.sigaction(std.posix.SIG.INT, &sa, null);
    std.posix.sigaction(std.posix.SIG.TERM, &sa, null);
}

fn setFdNonBlocking(fd: std.posix.fd_t) void {
    var fl_flags = std.posix.fcntl(fd, std.posix.F.GETFL, 0) catch return;
    fl_flags |= 1 << @bitOffsetOf(std.posix.O, "NONBLOCK");
    _ = std.posix.fcntl(fd, std.posix.F.SETFL, fl_flags) catch return;
}

fn drainSigPipe(fd: std.posix.fd_t) ?ExitSignal {
    var saw_int: bool = false;
    var saw_term: bool = false;

    var buf: [64]u8 = undefined;
    while (true) {
        const n = std.posix.read(fd, &buf) catch |e| switch (e) {
            error.WouldBlock => break,
            else => break,
        };
        if (n == 0) break;
        for (buf[0..n]) |b| {
            if (b == @as(u8, @intCast(std.posix.SIG.INT))) saw_int = true;
            if (b == @as(u8, @intCast(std.posix.SIG.TERM))) saw_term = true;
        }
    }

    if (saw_term) return .sigterm;
    if (saw_int) return .sigint;
    return null;
}

// --- Windows ctrl handler (lazy on POSIX) ---

const windows = std.os.windows;

var win_mux_ptr: ?*IOMux = null;

fn win_setMux(m: ?*IOMux) void {
    win_mux_ptr = m;
}

fn winCtrlHandler(ctrl_type: windows.DWORD) callconv(.winapi) windows.BOOL {
    const mux = win_mux_ptr orelse return windows.FALSE;
    _ = mux.queue.pushDropIfFull(.{ .exit_signal = switch (ctrl_type) {
        windows.CTRL_C_EVENT => .sigint,
        windows.CTRL_BREAK_EVENT => .sigint,
        windows.CTRL_CLOSE_EVENT => .ctrl_close,
        windows.CTRL_LOGOFF_EVENT => .ctrl_close,
        windows.CTRL_SHUTDOWN_EVENT => .ctrl_close,
        else => .ctrl_close,
    } });
    return windows.TRUE;
}

fn windowsInstallCtrlHandler() !bool {
    const rc = windows.kernel32.SetConsoleCtrlHandler(winCtrlHandler, windows.TRUE);
    return rc != 0;
}

fn windowsUninstallCtrlHandler() !void {
    _ = windows.kernel32.SetConsoleCtrlHandler(winCtrlHandler, windows.FALSE);
}

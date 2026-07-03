// Shared clipboard (text only, the Ctrl+C/Ctrl+V CLIPBOARD selection).
//
// Each telemouse process runs a clipboard worker on its own thread with its own
// X connection, so it can both (a) notice when the user copies something locally
// and (b) own the selection to serve *pastes* of text that came from another
// machine — X has no clipboard storage, the owner must answer paste requests, so
// this needs a live event loop of its own.
//
// The worker never touches the network and the main loop never touches X: they
// exchange text through two small mutex-guarded slots — `takeLocalCopy` (worker
// → main, "the user copied this, send it") and `setRemote` (main → worker, "make
// this pastable"). The main loop drains/sets these on its normal ticks.
//
// v1 limits: UTF-8 text only, one selection (CLIPBOARD), and a `max_text` cap
// with no INCR (chunked) transfer — larger clipboards are truncated. Non-Linux
// builds get a no-op stub for now.

const std = @import("std");
const builtin = @import("builtin");
const log = @import("log.zig");

/// Acquire a spinlock mutex. Critical sections here are a single small memcpy,
/// so spinning is cheaper than parking a thread.
fn lockSpin(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) {}
}

/// Largest clipboard text synced, chosen to fit comfortably in the command
/// line buffers on both ends once base64-encoded (~1.34x). Larger is truncated.
pub const max_text = 2048;

pub const Clipboard = switch (builtin.os.tag) {
    .linux => LinuxClipboard,
    else => StubClipboard,
};

/// Base64-encode clipboard text into `out` (the payload of a `clipboard <...>`
/// line). Returns an empty slice if it doesn't fit.
pub fn encode(out: []u8, text: []const u8) []const u8 {
    const enc = std.base64.standard.Encoder;
    if (enc.calcSize(text.len) > out.len) return out[0..0];
    return enc.encode(out, text);
}

/// Decode a base64 clipboard payload into `out`; null if malformed or too large.
pub fn decode(out: []u8, payload: []const u8) ?[]const u8 {
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(payload) catch return null;
    if (n > out.len) return null;
    dec.decode(out[0..n], payload) catch return null;
    return out[0..n];
}

test "clipboard payload round-trips through base64" {
    const text = "hello\tworld\n\"quoted\" + symbols/=";
    var enc: [256]u8 = undefined;
    const payload = encode(&enc, text);
    try std.testing.expect(std.mem.indexOfScalar(u8, payload, ' ') == null); // one safe token
    var dec: [256]u8 = undefined;
    try std.testing.expectEqualStrings(text, decode(&dec, payload).?);
    // Empty clipboard round-trips as an empty payload.
    try std.testing.expectEqualStrings("", decode(&dec, encode(&enc, "")).?);
    // Garbage is rejected, not crashed on.
    try std.testing.expect(decode(&dec, "not base64!!") == null);
}

const StubClipboard = struct {
    pub fn init() StubClipboard {
        return .{};
    }
    pub fn start(_: *StubClipboard, _: *log.Logger) void {}
    pub fn stop(_: *StubClipboard) void {}
    pub fn takeLocalCopy(_: *StubClipboard, _: []u8) ?[]const u8 {
        return null;
    }
    pub fn setRemote(_: *StubClipboard, _: []const u8) void {}
};

const LinuxClipboard = struct {
    logger: *log.Logger = undefined,
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = .init(false),

    mutex: std.atomic.Mutex = .unlocked,
    // main <- worker: a locally-copied text waiting to be sent.
    local: [max_text]u8 = undefined,
    local_len: usize = 0,
    has_local: bool = false,
    // main -> worker: a remote text to make pastable (own the selection).
    remote: [max_text]u8 = undefined,
    remote_len: usize = 0,
    has_remote: bool = false,

    pub fn init() LinuxClipboard {
        return .{};
    }

    pub fn start(self: *LinuxClipboard, logger: *log.Logger) void {
        self.logger = logger;
        self.running.store(true, .release);
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch |e| blk: {
            logger.warn("clipboard sharing disabled: {s}", .{@errorName(e)});
            self.running.store(false, .release);
            break :blk null;
        };
    }

    pub fn stop(self: *LinuxClipboard) void {
        self.running.store(false, .monotonic);
        if (self.thread) |t| t.join();
        self.thread = null;
    }

    /// Main thread: take a locally-copied text if one is pending (copied into
    /// `out`), else null. Called on the main loop's tick to forward it.
    pub fn takeLocalCopy(self: *LinuxClipboard, out: []u8) ?[]const u8 {
        lockSpin(&self.mutex);
        defer self.mutex.unlock();
        if (!self.has_local) return null;
        self.has_local = false;
        const n = @min(self.local_len, out.len);
        @memcpy(out[0..n], self.local[0..n]);
        return out[0..n];
    }

    /// Main thread: hand the worker text that arrived from another machine, to be
    /// owned and served as the local clipboard.
    pub fn setRemote(self: *LinuxClipboard, text: []const u8) void {
        lockSpin(&self.mutex);
        defer self.mutex.unlock();
        const n = @min(text.len, self.remote.len);
        @memcpy(self.remote[0..n], text[0..n]);
        self.remote_len = n;
        self.has_remote = true;
    }

    // ---- worker thread --------------------------------------------------

    fn run(self: *LinuxClipboard) void {
        var w = Worker{ .cb = self };
        if (!w.open()) {
            self.logger.warn("clipboard sharing unavailable (no X display)", .{});
            return;
        }
        defer w.close();
        while (self.running.load(.monotonic)) w.tick();
    }
};

// The worker owns all the X state; only `cb` is shared with the main thread and
// only through its mutex.
const Worker = struct {
    cb: *LinuxClipboard,
    dpy: *x.Display = undefined,
    win: x.Window = 0,
    fd: i32 = -1,
    a_clipboard: x.Atom = 0,
    a_utf8: x.Atom = 0,
    a_targets: x.Atom = 0,
    a_prop: x.Atom = 0, // our scratch property for incoming transfers
    xfixes_base: c_int = 0,
    // The text we currently own/serve (from a remote set), and the last text we
    // have seen either way — used to suppress echoing our own sets back out.
    serve: [max_text]u8 = undefined,
    serve_len: usize = 0,
    we_own: bool = false,
    last: [max_text]u8 = undefined,
    last_len: usize = 0,
    read_buf: [max_text]u8 = undefined,

    fn open(self: *Worker) bool {
        self.dpy = x.XOpenDisplay(null) orelse return false;
        const root = x.XDefaultRootWindow(self.dpy);
        self.win = x.XCreateSimpleWindow(self.dpy, root, -10, -10, 1, 1, 0, 0, 0);
        self.a_clipboard = x.XInternAtom(self.dpy, "CLIPBOARD", 0);
        self.a_utf8 = x.XInternAtom(self.dpy, "UTF8_STRING", 0);
        self.a_targets = x.XInternAtom(self.dpy, "TARGETS", 0);
        self.a_prop = x.XInternAtom(self.dpy, "TELEMOUSE_CLIP", 0);
        self.fd = x.XConnectionNumber(self.dpy);
        var evb: c_int = 0;
        var erb: c_int = 0;
        if (x.XFixesQueryExtension(self.dpy, &evb, &erb) != 0) {
            self.xfixes_base = evb;
            // Notify us whenever the CLIPBOARD owner changes (i.e. someone copied).
            x.XFixesSelectSelectionInput(self.dpy, root, self.a_clipboard, 1);
        }
        _ = x.XFlush(self.dpy);
        return true;
    }

    fn close(self: *Worker) void {
        _ = x.XCloseDisplay(self.dpy);
    }

    fn tick(self: *Worker) void {
        // Drain queued X events (paste requests, owner-change notifications).
        while (x.XPending(self.dpy) > 0) {
            var ev: x.XEvent = undefined;
            _ = x.XNextEvent(self.dpy, &ev);
            self.dispatch(&ev);
        }
        // Make any newly-arrived remote text pastable.
        self.applyRemote();
        // Wait for the next event or a periodic wakeup (to poll remote text).
        var pfd = [_]std.posix.pollfd{.{ .fd = self.fd, .events = std.posix.POLL.IN, .revents = 0 }};
        _ = std.posix.poll(&pfd, 200) catch {};
    }

    fn dispatch(self: *Worker, ev: *const x.XEvent) void {
        const etype = @as(*const c_int, @ptrCast(@alignCast(ev))).*;
        if (etype == x.SelectionRequest) {
            self.serveRequest(@ptrCast(@alignCast(ev)));
        } else if (etype == x.SelectionClear) {
            self.we_own = false; // another client took the selection
        } else if (self.xfixes_base != 0 and etype == self.xfixes_base + x.XFixesSelectionNotify) {
            const fe: *const x.XFixesSelectionNotifyEvent = @ptrCast(@alignCast(ev));
            if (fe.owner != self.win) self.onLocalCopy();
        }
    }

    /// The CLIPBOARD owner changed to someone other than us: the user copied
    /// something locally. Read it and, if it's new, queue it for the main thread.
    fn onLocalCopy(self: *Worker) void {
        self.we_own = false;
        const text = self.readClipboard() orelse return;
        if (std.mem.eql(u8, text, self.last[0..self.last_len])) return; // no change / our echo
        self.setLast(text);
        lockSpin(&self.cb.mutex);
        defer self.cb.mutex.unlock();
        const n = @min(text.len, self.cb.local.len);
        @memcpy(self.cb.local[0..n], text[0..n]);
        self.cb.local_len = n;
        self.cb.has_local = true;
    }

    fn applyRemote(self: *Worker) void {
        lockSpin(&self.cb.mutex);
        const pending = self.cb.has_remote;
        if (pending) {
            self.serve_len = self.cb.remote_len;
            @memcpy(self.serve[0..self.serve_len], self.cb.remote[0..self.serve_len]);
            self.cb.has_remote = false;
        }
        self.cb.mutex.unlock();
        if (!pending) return;
        // Own the selection so local apps paste this text; record it as `last`
        // so the resulting owner-change notification isn't echoed back out.
        self.setLast(self.serve[0..self.serve_len]);
        self.we_own = true;
        _ = x.XSetSelectionOwner(self.dpy, self.a_clipboard, self.win, x.CurrentTime);
        _ = x.XFlush(self.dpy);
    }

    /// Answer a paste request for the text we own.
    fn serveRequest(self: *Worker, req: *const x.XSelectionRequestEvent) void {
        var prop = req.property;
        if (prop == 0) prop = req.target; // obsolete clients
        var ok = false;
        if (self.we_own) {
            if (req.target == self.a_targets) {
                var targets = [_]x.Atom{ self.a_targets, self.a_utf8 };
                _ = x.XChangeProperty(self.dpy, req.requestor, prop, 4, 32, x.PropModeReplace, @ptrCast(&targets), targets.len);
                ok = true;
            } else if (req.target == self.a_utf8) {
                _ = x.XChangeProperty(self.dpy, req.requestor, prop, self.a_utf8, 8, x.PropModeReplace, self.serve[0..self.serve_len].ptr, @intCast(self.serve_len));
                ok = true;
            }
        }
        // Notify the requestor where we put the data (or that we declined).
        var note = std.mem.zeroes(x.XSelectionEvent);
        note.type = x.SelectionNotify;
        note.display = self.dpy;
        note.requestor = req.requestor;
        note.selection = req.selection;
        note.target = req.target;
        note.property = if (ok) prop else 0;
        note.time = req.time;
        _ = x.XSendEvent(self.dpy, req.requestor, 0, 0, @ptrCast(&note));
        _ = x.XFlush(self.dpy);
    }

    /// Fetch the current CLIPBOARD text as UTF-8 (into read_buf), or null.
    fn readClipboard(self: *Worker) ?[]const u8 {
        _ = x.XConvertSelection(self.dpy, self.a_clipboard, self.a_utf8, self.a_prop, self.win, x.CurrentTime);
        _ = x.XFlush(self.dpy);
        // Wait (bounded) for the SelectionNotify answering our request, serving
        // any paste requests that arrive meanwhile so we can't deadlock.
        var tries: u32 = 0;
        while (tries < 40) : (tries += 1) {
            if (x.XPending(self.dpy) == 0) {
                var pfd = [_]std.posix.pollfd{.{ .fd = self.fd, .events = std.posix.POLL.IN, .revents = 0 }};
                _ = std.posix.poll(&pfd, 50) catch {};
                if (x.XPending(self.dpy) == 0) continue;
            }
            var ev: x.XEvent = undefined;
            _ = x.XNextEvent(self.dpy, &ev);
            const etype = @as(*const c_int, @ptrCast(@alignCast(&ev))).*;
            if (etype == x.SelectionNotify) {
                const se: *const x.XSelectionEvent = @ptrCast(@alignCast(&ev));
                if (se.property == 0) return null;
                return self.readProperty();
            } else {
                self.dispatch(&ev); // serve requests / owner changes while waiting
            }
        }
        return null;
    }

    fn readProperty(self: *Worker) ?[]const u8 {
        var actual_type: x.Atom = 0;
        var actual_format: c_int = 0;
        var nitems: c_ulong = 0;
        var bytes_after: c_ulong = 0;
        var data: ?[*]u8 = null;
        const long_len: c_long = @intCast(max_text / 4 + 1);
        if (x.XGetWindowProperty(self.dpy, self.win, self.a_prop, 0, long_len, 1, self.a_utf8, &actual_type, &actual_format, &nitems, &bytes_after, &data) != 0)
            return null;
        const ptr = data orelse return null;
        defer _ = x.XFree(ptr);
        if (actual_format != 8) return null;
        const n = @min(@as(usize, @intCast(nitems)), self.read_buf.len);
        @memcpy(self.read_buf[0..n], ptr[0..n]);
        return self.read_buf[0..n];
    }

    fn setLast(self: *Worker, text: []const u8) void {
        const n = @min(text.len, self.last.len);
        @memcpy(self.last[0..n], text[0..n]);
        self.last_len = n;
    }
};

const x = struct {
    const Display = opaque {};
    const Window = c_ulong;
    const Atom = c_ulong;

    const SelectionClear: c_int = 29;
    const SelectionRequest: c_int = 30;
    const SelectionNotify: c_int = 31;
    const XFixesSelectionNotify: c_int = 0; // subtype offset from the xfixes event base
    const PropModeReplace: c_int = 0;
    const CurrentTime: c_ulong = 0;

    const XEvent = extern struct { pad: [24]c_long };

    const XSelectionRequestEvent = extern struct {
        type: c_int,
        serial: c_ulong,
        send_event: c_int,
        display: ?*Display,
        owner: Window,
        requestor: Window,
        selection: Atom,
        target: Atom,
        property: Atom,
        time: c_ulong,
    };

    const XSelectionEvent = extern struct {
        type: c_int,
        serial: c_ulong,
        send_event: c_int,
        display: ?*Display,
        requestor: Window,
        selection: Atom,
        target: Atom,
        property: Atom,
        time: c_ulong,
    };

    const XFixesSelectionNotifyEvent = extern struct {
        type: c_int,
        serial: c_ulong,
        send_event: c_int,
        display: ?*Display,
        subtype: c_int,
        window: Window,
        owner: Window,
        selection: Atom,
        timestamp: c_ulong,
        selection_timestamp: c_ulong,
    };

    extern "X11" fn XOpenDisplay(?[*:0]const u8) callconv(.c) ?*Display;
    extern "X11" fn XCloseDisplay(*Display) callconv(.c) c_int;
    extern "X11" fn XDefaultRootWindow(*Display) callconv(.c) Window;
    extern "X11" fn XCreateSimpleWindow(*Display, Window, c_int, c_int, c_uint, c_uint, c_uint, c_ulong, c_ulong) callconv(.c) Window;
    extern "X11" fn XInternAtom(*Display, [*:0]const u8, c_int) callconv(.c) Atom;
    extern "X11" fn XConvertSelection(*Display, Atom, Atom, Atom, Window, c_ulong) callconv(.c) c_int;
    extern "X11" fn XSetSelectionOwner(*Display, Atom, Window, c_ulong) callconv(.c) c_int;
    extern "X11" fn XGetWindowProperty(*Display, Window, Atom, c_long, c_long, c_int, Atom, *Atom, *c_int, *c_ulong, *c_ulong, *?[*]u8) callconv(.c) c_int;
    extern "X11" fn XChangeProperty(*Display, Window, Atom, Atom, c_int, c_int, [*]const u8, c_int) callconv(.c) c_int;
    extern "X11" fn XSendEvent(*Display, Window, c_int, c_long, *const anyopaque) callconv(.c) c_int;
    extern "X11" fn XNextEvent(*Display, *XEvent) callconv(.c) c_int;
    extern "X11" fn XPending(*Display) callconv(.c) c_int;
    extern "X11" fn XFlush(*Display) callconv(.c) c_int;
    extern "X11" fn XFree(?*anyopaque) callconv(.c) c_int;
    extern "X11" fn XConnectionNumber(*Display) callconv(.c) c_int;
    extern "Xfixes" fn XFixesQueryExtension(*Display, *c_int, *c_int) callconv(.c) c_int;
    extern "Xfixes" fn XFixesSelectSelectionInput(*Display, Window, Atom, c_ulong) callconv(.c) void;
};

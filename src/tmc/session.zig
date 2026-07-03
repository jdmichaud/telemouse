// Client-side sending: a `Sender` forwards commands to one server (mouse over
// UDP, everything else over TCP), and a `Session` ties the edge-switching state
// machine to a set of neighbour senders. Both the evdev (Linux) and the Win32
// hook (Windows) capture backends drive a `Session`, so the switching and
// forwarding logic lives here, once.

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;

const log = @import("../common/log.zig");
const protocol = @import("../common/protocol.zig");
const clipboard = @import("../common/clipboard.zig");
const switcher = @import("switcher.zig");

/// Sends commands to a server, routing each to its transport. The UDP socket is
/// opened up front; the TCP connection is opened on first use.
/// How long to wait for the server's placement acknowledgement before giving up
/// and streaming motion anyway (degrades to best-effort against an old server).
const ack_timeout_ms: i64 = 300;

/// A "reach" event from the server: its cursor hit `side` at `perp` (the pixel
/// along that edge, in the server screen's local coordinates).
pub const Reach = struct { side: switcher.Side, perp: i32 };

pub const Sender = struct {
    io: Io,
    logger: *log.Logger,
    server: net.IpAddress,
    udp: net.Socket,
    tcp: ?net.Stream = null,
    tcp_writer: net.Stream.Writer = undefined,
    tcp_buf: [4096]u8 = undefined,
    // Line-buffered reads of the server->client channel (the `placed` ack,
    // `reach` events, and `clipboard` updates — hence sized for a clipboard line).
    rbuf: [4096]u8 = undefined,
    rlen: usize = 0,
    line_buf: [4096]u8 = undefined,
    /// False while a placement is outstanding: motion (UDP) is dropped until the
    /// server acknowledges the `place`, so the first deltas can never overtake it
    /// on the other channel. Atomic because on Windows the capture (hook) thread
    /// clears it and reads it while the main thread sets it after the ack.
    ready: std.atomic.Value(bool) = .init(true),

    pub fn init(io: Io, logger: *log.Logger, server: net.IpAddress) !Sender {
        var any = net.IpAddress.parse("0.0.0.0", 0) catch unreachable;
        const udp = any.bind(io, .{ .mode = .dgram }) catch |e| {
            logger.err("cannot create udp socket: {s}", .{@errorName(e)});
            return error.SocketFailed;
        };
        return .{ .io = io, .logger = logger, .server = server, .udp = udp };
    }

    pub fn deinit(self: *Sender) void {
        self.udp.close(self.io);
        if (self.tcp) |stream| stream.close(self.io);
    }

    /// Open the TCP command channel if it is not already open. Returns false if
    /// the connection cannot be established (the caller degrades gracefully).
    fn tryConnect(self: *Sender) bool {
        if (self.tcp != null) return true;
        const stream = self.server.connect(self.io, .{ .mode = .stream }) catch |e| {
            self.logger.debug("cannot open tcp channel: {s}", .{@errorName(e)});
            return false;
        };
        self.tcp = stream;
        self.tcp_writer = stream.writer(self.io, &self.tcp_buf);
        return true;
    }

    /// Eagerly open the TCP channel now (best-effort), so the first edge
    /// crossing does not pay connection setup on top of the placement ack.
    pub fn connect(self: *Sender) void {
        _ = self.tryConnect();
    }

    /// Tear down a broken TCP connection so the next send reconnects.
    fn dropTcp(self: *Sender) void {
        if (self.tcp) |stream| stream.close(self.io);
        self.tcp = null;
    }

    /// Whether the TCP command channel is currently open. While control is remote
    /// this having gone false means the server dropped (a failed read/write tore
    /// it down), so the client must return home rather than strand the cursor.
    pub fn isConnected(self: *const Sender) bool {
        return self.tcp != null;
    }

    fn keyboardWriter(self: *Sender) ?*Io.Writer {
        if (!self.tryConnect()) return null;
        return &self.tcp_writer.interface;
    }

    /// Validate and send one command line. Returns true on success.
    pub fn dispatch(self: *Sender, line: []const u8) bool {
        const cmd = protocol.parse(line) catch |e| {
            self.logger.err("invalid command '{s}': {s}", .{ line, @errorName(e) });
            return false;
        };
        switch (cmd.transport()) {
            .udp => return self.sendUdp(line),
            .tcp => return self.sendTcp(line),
        }
    }

    fn sendUdp(self: *Sender, line: []const u8) bool {
        self.udp.send(self.io, &self.server, line) catch |e| {
            self.logger.debug("udp send failed: {s}", .{@errorName(e)});
            return false;
        };
        return true;
    }

    fn sendTcp(self: *Sender, line: []const u8) bool {
        const w = self.keyboardWriter() orelse return false;
        // On any write/flush error the connection is broken; drop it so the next
        // send reconnects.
        w.writeAll(line) catch |e| {
            self.logger.debug("tcp send failed: {s}; reconnecting next time", .{@errorName(e)});
            self.dropTcp();
            return false;
        };
        w.writeByte('\n') catch {
            self.dropTcp();
            return false;
        };
        w.flush() catch {
            self.dropTcp();
            return false;
        };
        return true;
    }

    /// Fire-and-forget relative motion over UDP. Silent (no logging) so it is
    /// safe to call from a low-level hook callback, where UDP never blocks.
    /// Dropped while a placement is still unacknowledged (see `ready`).
    pub fn sendMove(self: *Sender, dx: i32, dy: i32) void {
        if (!self.ready.load(.acquire)) return;
        var buf: [48]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "move {d} {d}", .{ dx, dy }) catch return;
        self.udp.send(self.io, &self.server, line) catch {};
    }

    /// Fire-and-forget absolute motion over UDP (the edge-switch streaming path).
    /// Same gating/threading rules as `sendMove`.
    pub fn sendMoveTo(self: *Sender, x: i32, y: i32) void {
        if (!self.ready.load(.acquire)) return;
        var buf: [48]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "moveto {d} {d}", .{ x, y }) catch return;
        self.udp.send(self.io, &self.server, line) catch {};
    }

    /// Absolute placement over TCP, used once when the pointer enters a
    /// neighbour. Sends `place x y` and waits for the server's ack before
    /// re-opening the UDP motion gate (`ready`), so a `move` can never be applied
    /// before the placement. Called on the send side (main thread on Windows).
    pub fn sendMouseAbs(self: *Sender, x: i32, y: i32) bool {
        var buf: [48]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "place {d} {d}", .{ x, y }) catch {
            self.ready.store(true, .release);
            return false;
        };
        if (!self.sendTcp(line)) {
            self.ready.store(true, .release);
            return false; // not even connected — the caller must not hand over
        }
        const acked = self.awaitAck();
        self.ready.store(true, .release);
        return acked;
    }

    /// Wait (briefly) for the server's `placed` acknowledgement. Returns true if a
    /// line came back (the server is there and answering), false on timeout/error.
    /// The server sends exactly one ack per `place`.
    fn awaitAck(self: *Sender) bool {
        return self.readLine(ack_timeout_ms) != null;
    }

    /// Read one '\n'-terminated line from the server (waiting up to `timeout_ms`),
    /// or null if none is available. The returned slice is valid until the next
    /// `readLine` call. Drops the connection on a hard error.
    fn readLine(self: *Sender, timeout_ms: i64) ?[]const u8 {
        if (self.extractLine()) |line| return line;
        const stream = self.tcp orelse return null;
        if (self.rlen >= self.rbuf.len) self.rlen = 0; // overlong line: reset
        var data = [_][]u8{self.rbuf[self.rlen..]};
        const timeout: Io.Timeout = .{ .duration = .{
            .raw = Io.Duration.fromMilliseconds(timeout_ms),
            .clock = .awake,
        } };
        const res = self.io.operateTimeout(.{ .net_read = .{
            .socket_handle = stream.socket.handle,
            .data = data[0..],
        } }, timeout) catch |e| switch (e) {
            error.Timeout => return null,
            else => {
                self.dropTcp();
                return null;
            },
        };
        const n = res.net_read catch {
            self.dropTcp();
            return null;
        };
        if (n == 0) {
            self.dropTcp(); // EOF: server closed the channel
            return null;
        }
        self.rlen += n;
        return self.extractLine();
    }

    fn extractLine(self: *Sender) ?[]const u8 {
        const nl = std.mem.indexOfScalar(u8, self.rbuf[0..self.rlen], '\n') orelse return null;
        const len = @min(nl, self.line_buf.len);
        @memcpy(self.line_buf[0..len], self.rbuf[0..len]);
        const rest = self.rlen - (nl + 1);
        std.mem.copyForwards(u8, self.rbuf[0..rest], self.rbuf[nl + 1 .. self.rlen]);
        self.rlen = rest;
        return self.line_buf[0..len];
    }

    /// Close the UDP gate: called when a placement becomes outstanding so motion
    /// is held until the following `place` is acknowledged.
    pub fn beginPlacement(self: *Sender) void {
        self.ready.store(false, .release);
    }

    pub fn sendKey(self: *Sender, down: bool, name: []const u8) void {
        var buf: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{s} {s}", .{ if (down) "keydown" else "keyup", name }) catch return;
        _ = self.sendTcp(line);
    }

    pub fn sendButton(self: *Sender, down: bool, name: []const u8) void {
        var buf: [48]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{s} {s}", .{ if (down) "buttondown" else "buttonup", name }) catch return;
        _ = self.sendTcp(line);
    }

    pub fn sendScroll(self: *Sender, dx: i32, dy: i32) void {
        var buf: [48]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "scroll {d} {d}", .{ dx, dy }) catch return;
        _ = self.sendTcp(line);
    }

    pub fn sendHide(self: *Sender) void {
        _ = self.sendTcp("hide");
    }

    /// Forward an already-base64-encoded clipboard payload.
    pub fn sendClipboard(self: *Sender, payload: []const u8) void {
        var buf: [clipboard.max_text * 2]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "clipboard {s}", .{payload}) catch return;
        _ = self.sendTcp(line);
    }
};

/// What a capture backend must do after feeding a motion event to the session.
pub const Transition = union(enum) {
    /// No change; keep doing what you were doing (includes server->server hops,
    /// where the grab stays and only the active target changes).
    none,
    /// Just left the client for a server: capture (grab / suppress) local input.
    grab,
    /// Just returned to the client: release capture and, on platforms that can,
    /// place the local cursor at this point (client-local coordinates).
    ungrab: switcher.Point,
};

/// A command to forward to a neighbour, produced by the capture side and
/// consumed by the sending side. Plain data so it can travel through a
/// lock-free queue between threads (used by the Windows backend).
pub const OutCmd = struct {
    edge: u8,
    tag: enum(u8) { move, moveto, mouse, button, key, scroll, hide },
    // move: a,b = dx,dy.  moveto/mouse: a,b = x,y.  scroll: a,b = dx,dy.
    a: i32 = 0,
    b: i32 = 0,
    down: bool = false,
    name_buf: [16]u8 = undefined,
    name_len: u8 = 0,

    /// The streamed motion goes over UDP; everything else over TCP.
    pub fn transport(self: *const OutCmd) protocol.Transport {
        return switch (self.tag) {
            .move, .moveto => .udp,
            else => .tcp,
        };
    }

    fn withName(edge: u8, tag: @FieldType(OutCmd, "tag"), down: bool, label: []const u8) OutCmd {
        var cmd = OutCmd{ .edge = edge, .tag = tag, .down = down };
        const n = @min(label.len, cmd.name_buf.len);
        @memcpy(cmd.name_buf[0..n], label[0..n]);
        cmd.name_len = @intCast(n);
        return cmd;
    }

    fn name(self: *const OutCmd) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

pub const Decision = struct {
    transition: Transition,
    /// A command to forward as a result of this motion, if any.
    out: ?OutCmd,
};

/// Ties the edge-switch state machine to the neighbour senders.
///
/// The "capture side" (`decide`, `capture*`) only touches the switcher and
/// produces `OutCmd`s -- no I/O, no logging -- so it is safe to run in a
/// low-level hook callback. The "send side" (`forward`) only touches the
/// senders. A single-threaded backend (evdev) calls both on one thread; a
/// two-threaded backend (Windows) runs the capture side on the hook thread and
/// the send side on the main thread, with an `OutCmd` queue in between.
const max_held = 16;
const HeldKey = struct { buf: [16]u8 = undefined, len: u8 = 0 };

pub const Session = struct {
    logger: *log.Logger,
    sw: switcher.Switcher,
    /// Senders indexed by screen index; slot 0 (the client) is always null.
    senders: [switcher.max_screens]?Sender,
    /// Shared clipboard worker (optional). The client is the hub: local copies go
    /// to every server, and a copy from one server is relayed to the others.
    clip: ?*clipboard.Clipboard = null,

    // Keys currently held down, tracked from every key event regardless of the
    // active screen, so a held modifier can be released on the old server and
    // re-pressed on the new one at a crossing. Capture-side (single-thread on
    // evdev, hook thread on Windows) state only.
    held: [max_held]HeldKey = undefined,
    held_n: usize = 0,
    // Screen we last warned was unreachable, so the warning isn't repeated every
    // motion frame while the pointer is pushed against a dead neighbour's edge.
    unreachable_warned: ?usize = null,
    // Extra commands a crossing produces (the modifier hand-off), drained by the
    // backend right after `decide` on the same (capture) thread.
    pending: [2 * max_held]OutCmd = undefined,
    pending_n: usize = 0,
    pending_i: usize = 0,

    /// `screens[0]` is the client. `addrs[i]` is the server behind screen `i`
    /// (addrs[0] must be null). Both slices are the same length.
    pub fn init(
        io: Io,
        logger: *log.Logger,
        screens: []const switcher.Rect,
        addrs: []const ?net.IpAddress,
    ) Session {
        var senders: [switcher.max_screens]?Sender = undefined;
        for (&senders) |*s| s.* = null;
        for (addrs, 0..) |maybe, i| {
            if (i >= switcher.max_screens) break;
            const addr = maybe orelse continue;
            senders[i] = Sender.init(io, logger, addr) catch continue;
        }
        return .{
            .logger = logger,
            .sw = switcher.Switcher.init(screens),
            .senders = senders,
        };
    }

    /// Eagerly open each neighbour's TCP channel. Call this after the session is
    /// in its final location (the senders hold pointers into their own storage),
    /// so the first crossing does not pay TCP setup on top of the placement ack.
    pub fn connectAll(self: *Session) void {
        for (&self.senders) |*s| {
            if (s.*) |*sender| sender.connect();
        }
    }

    pub fn deinit(self: *Session) void {
        for (&self.senders) |*s| {
            if (s.*) |*sender| sender.deinit();
        }
    }

    pub fn hasNeighbours(self: *const Session) bool {
        for (self.senders) |s| {
            if (s != null) return true;
        }
        return false;
    }

    /// The screen currently controlled, or null when on the client.
    fn activeScreen(self: *const Session) ?usize {
        return if (self.sw.onClient()) null else self.sw.currentScreen();
    }

    // ---- capture side (no I/O) ------------------------------------------

    pub fn decide(self: *Session, dx: i32, dy: i32) Decision {
        const old_screen = self.activeScreen();
        switch (self.sw.onMotion(dx, dy)) {
            .stay => return .{ .transition = .none, .out = null },
            // Entering a server (from the client): grab, and place the pointer
            // absolutely at the crossing point (acked `place`, over TCP). Close
            // the UDP gate now so motion waits for the ack.
            .grab => |p| {
                self.beginPlacement(p.screen);
                self.handoffModifiers(old_screen, p.screen);
                return .{ .transition = .grab, .out = absolute(p) };
            },
            // Hopping between servers: the grab stays; just place on the new one.
            .hop => |p| {
                self.beginPlacement(p.screen);
                self.handoffModifiers(old_screen, p.screen);
                self.pushLeave(old_screen); // hide the server we just left
                return .{ .transition = .none, .out = absolute(p) };
            },
            // Still on a server: stream the relative delta (UDP). (Absolute
            // streaming is cleaner but needs the server to place the cursor
            // through the display server, not the REL/ABS-mixed uinput device.)
            .move => |d| return .{ .transition = .none, .out = self.relative(d.dx, d.dy) },
            .ungrab => |u| {
                self.handoffModifiers(old_screen, null);
                self.pushLeave(old_screen); // hide the server we're returning from
                return .{ .transition = .{ .ungrab = .{ .x = u.x, .y = u.y } }, .out = null };
            },
        }
    }

    /// Release every held key on the screen being left and press it on the one
    /// being entered, so a modifier held across a crossing is not left stuck on
    /// the old screen nor missing on the new one. Queues the events in `pending`;
    /// the backend forwards them after `decide`.
    fn handoffModifiers(self: *Session, old_screen: ?usize, new_screen: ?usize) void {
        var i: usize = 0;
        while (i < self.held_n) : (i += 1) {
            const name = self.held[i].buf[0..self.held[i].len];
            if (old_screen) |s| self.pushPending(OutCmd.withName(@intCast(s), .key, false, name));
            if (new_screen) |s| self.pushPending(OutCmd.withName(@intCast(s), .key, true, name));
        }
    }

    /// Queue a `hide` for `old_screen` (a server we're leaving) so it hides its
    /// cursor while control is elsewhere. No-op when leaving the client.
    fn pushLeave(self: *Session, old_screen: ?usize) void {
        if (old_screen) |s| self.pushPending(.{ .edge = @intCast(s), .tag = .hide });
    }

    fn pushPending(self: *Session, cmd: OutCmd) void {
        if (self.pending_n < self.pending.len) {
            self.pending[self.pending_n] = cmd;
            self.pending_n += 1;
        }
    }

    /// Next queued hand-off command, or null when drained (which resets the
    /// queue). Called on the capture thread right after `decide`.
    pub fn nextPending(self: *Session) ?OutCmd {
        if (self.pending_i < self.pending_n) {
            const c = self.pending[self.pending_i];
            self.pending_i += 1;
            return c;
        }
        self.pending_i = 0;
        self.pending_n = 0;
        return null;
    }

    /// Close the UDP motion gate on the sender for `screen` (safe from the
    /// capture thread: it only touches an atomic on the sender).
    fn beginPlacement(self: *Session, screen: usize) void {
        if (screen < self.senders.len) {
            if (self.senders[screen]) |*s| s.beginPlacement();
        }
    }

    fn holdKey(self: *Session, name: []const u8) void {
        for (0..self.held_n) |i| {
            if (std.mem.eql(u8, self.held[i].buf[0..self.held[i].len], name)) return; // already held
        }
        if (self.held_n >= self.held.len) return;
        var k = HeldKey{};
        const n = @min(name.len, k.buf.len);
        @memcpy(k.buf[0..n], name[0..n]);
        k.len = @intCast(n);
        self.held[self.held_n] = k;
        self.held_n += 1;
    }

    fn releaseKey(self: *Session, name: []const u8) void {
        for (0..self.held_n) |i| {
            if (std.mem.eql(u8, self.held[i].buf[0..self.held[i].len], name)) {
                self.held[i] = self.held[self.held_n - 1]; // swap-remove
                self.held_n -= 1;
                return;
            }
        }
    }

    pub fn captureButton(self: *Session, down: bool, name: []const u8) ?OutCmd {
        const screen = self.activeScreen() orelse return null;
        return OutCmd.withName(@intCast(screen), .button, down, name);
    }

    pub fn captureKey(self: *Session, down: bool, name: []const u8) ?OutCmd {
        // Track held state from every key event, even on the client, so it is
        // known at the next crossing.
        if (down) self.holdKey(name) else self.releaseKey(name);
        const screen = self.activeScreen() orelse return null;
        return OutCmd.withName(@intCast(screen), .key, down, name);
    }

    pub fn captureScroll(self: *Session, dx: i32, dy: i32) ?OutCmd {
        const screen = self.activeScreen() orelse return null;
        return .{ .edge = @intCast(screen), .tag = .scroll, .a = dx, .b = dy };
    }

    fn absolute(p: switcher.Placement) ?OutCmd {
        return .{ .edge = @intCast(p.screen), .tag = .mouse, .a = p.x, .b = p.y };
    }

    fn relative(self: *Session, dx: i32, dy: i32) ?OutCmd {
        const screen = self.activeScreen() orelse return null;
        return .{ .edge = @intCast(screen), .tag = .move, .a = dx, .b = dy };
    }

    /// Sync the switcher's virtual cursor to the real cursor while on the client
    /// screen (see `switcher.setClientCursor`).
    pub fn syncClientCursor(self: *Session, rx: i32, ry: i32) void {
        self.sw.setClientCursor(rx, ry);
    }

    pub fn onClient(self: *const Session) bool {
        return self.sw.onClient();
    }

    /// Drain pending server->client messages from every connected server,
    /// dispatching `clipboard` updates inline (any server may send one) and
    /// returning a crossing `Decision` for a `reach` from the *active* server.
    /// Call in a loop and apply each returned decision; returns null when drained.
    pub fn pumpServers(self: *Session) ?Decision {
        for (&self.senders, 0..) |*s, i| {
            const sender = if (s.*) |*snd| snd else continue;
            while (sender.readLine(0)) |line| {
                if (parseClipboard(line)) |payload| {
                    self.onServerClipboard(i, payload);
                } else if (parseReach(line)) |r| {
                    // Only the screen we're on drives a crossing; a stale reach
                    // from elsewhere is ignored. Return so the caller applies the
                    // transition before we read on (it changes the active screen).
                    if (self.activeScreen() == i) return self.crossViaReach(r.side, r.perp);
                }
            }
        }
        return null;
    }

    /// A clipboard update arrived from server `from`: set it locally and relay it
    /// to every *other* server, so a copy on one machine reaches them all.
    fn onServerClipboard(self: *Session, from: usize, payload: []const u8) void {
        if (self.clip) |c| {
            var buf: [clipboard.max_text]u8 = undefined;
            if (clipboard.decode(&buf, payload)) |text| c.setRemote(text);
        }
        for (&self.senders, 0..) |*s, i| {
            if (i == from) continue;
            if (s.*) |*snd| snd.sendClipboard(payload);
        }
    }

    /// Forward a locally-copied text (if any) to every server. Called on the
    /// capture loop's ticks; the copy reaches the servers by the time the user
    /// crosses to one to paste.
    pub fn pumpClipboardOut(self: *Session) void {
        const clip = self.clip orelse return;
        var text_buf: [clipboard.max_text]u8 = undefined;
        const text = clip.takeLocalCopy(&text_buf) orelse return;
        var b64: [clipboard.max_text * 2]u8 = undefined;
        const payload = clipboard.encode(&b64, text);
        if (payload.len == 0) return;
        for (&self.senders) |*s| {
            if (s.*) |*snd| snd.sendClipboard(payload);
        }
    }

    /// Cross in response to a server edge reach: like `decide`, but the trigger is
    /// the server's report rather than local motion.
    pub fn crossViaReach(self: *Session, side: switcher.Side, perp: i32) Decision {
        const old_screen = self.activeScreen();
        switch (self.sw.reachedEdge(side, perp)) {
            .stay, .move => return .{ .transition = .none, .out = null },
            .grab => |p| { // shouldn't happen from a server reach, but handle safely
                self.beginPlacement(p.screen);
                self.handoffModifiers(old_screen, p.screen);
                return .{ .transition = .grab, .out = absolute(p) };
            },
            .hop => |p| {
                self.beginPlacement(p.screen);
                self.handoffModifiers(old_screen, p.screen);
                self.pushLeave(old_screen);
                return .{ .transition = .none, .out = absolute(p) };
            },
            .ungrab => |u| {
                self.handoffModifiers(old_screen, null);
                self.pushLeave(old_screen);
                return .{ .transition = .{ .ungrab = .{ .x = u.x, .y = u.y } }, .out = null };
            },
        }
    }

    /// Send the placement for a client->server crossing and report whether the
    /// neighbour acknowledged it. This gates the handover: the caller only grabs
    /// and hides the cursor once the server is confirmed present and answering,
    /// so a missing or dead server can never strand the pointer off-screen.
    pub fn confirmPlacement(self: *Session, cmd: OutCmd) bool {
        if (cmd.tag != .mouse or cmd.edge >= self.senders.len) return false;
        const sender = if (self.senders[cmd.edge]) |*s| s else return false;
        return sender.sendMouseAbs(cmd.a, cmd.b);
    }

    /// Roll back a client->server crossing that could not be committed (the
    /// server did not answer): revert the switcher to the client and drop the
    /// queued modifier hand-off. Returns the client-local point for the cursor.
    pub fn abortCross(self: *Session) switcher.Point {
        self.discardPending();
        return self.sw.abortToClient();
    }

    /// Drop any queued modifier hand-off (used when a crossing is aborted).
    pub fn discardPending(self: *Session) void {
        self.pending_n = 0;
        self.pending_i = 0;
    }

    /// Panic escape: force control back to the client from anywhere, dropping all
    /// grab/hand-off state and reopening every motion gate. Returns the
    /// client-local point to warp the real cursor to.
    pub fn forceHome(self: *Session) switcher.Point {
        self.held_n = 0;
        self.discardPending();
        self.unreachable_warned = null;
        for (&self.senders) |*s| {
            if (s.*) |*sender| sender.ready.store(true, .release);
        }
        return self.sw.forceToClient();
    }

    /// True when this key event is the panic chord (Ctrl+Alt+Esc): the always-
    /// available "give me my mouse back" escape, checked before forwarding.
    pub fn panicRequested(self: *const Session, down: bool, name: []const u8) bool {
        if (self.sw.onClient()) return false; // only meaningful while control is remote
        if (!down) return false;
        if (!std.mem.eql(u8, name, "esc") and !std.mem.eql(u8, name, "escape")) return false;
        return self.heldHasAny(&.{ "ctrl", "control", "leftctrl", "rightctrl" }) and
            self.heldHasAny(&.{ "alt", "leftalt" });
    }

    fn heldHasAny(self: *const Session, names: []const []const u8) bool {
        for (0..self.held_n) |i| {
            const h = self.held[i].buf[0..self.held[i].len];
            for (names) |n| {
                if (std.mem.eql(u8, h, n)) return true;
            }
        }
        return false;
    }

    /// Warn (once per episode) that a neighbour did not respond, so the message
    /// isn't repeated on every motion frame while pushed against its edge.
    pub fn warnUnreachableOnce(self: *Session, screen: usize) void {
        if (self.unreachable_warned) |s| {
            if (s == screen) return;
        }
        self.logger.warn("neighbour for screen {d} did not respond; staying on this screen", .{screen});
        self.unreachable_warned = screen;
    }

    pub fn clearUnreachable(self: *Session) void {
        self.unreachable_warned = null;
    }

    /// True when control is on a server whose command connection has dropped —
    /// the caller should force control home so the cursor isn't stranded on a
    /// dead remote. On the client there is nothing to lose.
    pub fn activeServerLost(self: *Session) bool {
        const screen = self.activeScreen() orelse return false;
        const sender = if (self.senders[screen]) |*s| s else return true;
        return !sender.isConnected();
    }

    // ---- send side ------------------------------------------------------

    /// Send a command. `move` (UDP) is fire-and-forget and never blocks, so it
    /// is safe from any thread -- including a hook callback. The TCP paths can
    /// block, so on Windows they run on the drainer thread, not the callback
    /// (route by `cmd.transport()`).
    pub fn forward(self: *Session, cmd: OutCmd) void {
        if (cmd.edge >= self.senders.len) return;
        const sender = if (self.senders[cmd.edge]) |*s| s else return;
        switch (cmd.tag) {
            .move => sender.sendMove(cmd.a, cmd.b),
            .moveto => sender.sendMoveTo(cmd.a, cmd.b),
            .mouse => _ = sender.sendMouseAbs(cmd.a, cmd.b),
            .button => sender.sendButton(cmd.down, cmd.name()),
            .key => sender.sendKey(cmd.down, cmd.name()),
            .scroll => sender.sendScroll(cmd.a, cmd.b),
            .hide => sender.sendHide(),
        }
    }
};

/// The base64 payload of a `clipboard <payload>` line, or null if not one.
fn parseClipboard(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (std.mem.eql(u8, trimmed, "clipboard")) return ""; // cleared
    if (std.mem.startsWith(u8, trimmed, "clipboard ")) return trimmed["clipboard ".len..];
    return null;
}

/// Parse a `reach <side> <perp>` line from the server. Returns null if it isn't
/// a well-formed reach event.
fn parseReach(line: []const u8) ?Reach {
    var it = std.mem.tokenizeAny(u8, std.mem.trim(u8, line, " \t\r\n"), " \t");
    const verb = it.next() orelse return null;
    if (!std.mem.eql(u8, verb, "reach")) return null;
    const side_s = it.next() orelse return null;
    const perp_s = it.next() orelse return null;
    const side: switcher.Side =
        if (std.mem.eql(u8, side_s, "left")) .left else if (std.mem.eql(u8, side_s, "right")) .right else if (std.mem.eql(u8, side_s, "top")) .top else if (std.mem.eql(u8, side_s, "bottom")) .bottom else return null;
    const perp = std.fmt.parseInt(i32, perp_s, 10) catch return null;
    return .{ .side = side, .perp = perp };
}

test "a reach line parses into a side + perpendicular position" {
    const r = parseReach("reach right 300").?;
    try std.testing.expectEqual(switcher.Side.right, r.side);
    try std.testing.expectEqual(@as(i32, 300), r.perp);
    try std.testing.expect(parseReach("placed") == null);
    try std.testing.expect(parseReach("reach sideways 1") == null);
}

test "a held modifier is released on the old screen and pressed on the new one" {
    // A two-screen lattice (client + a right neighbour) with no real senders, so
    // the capture-side logic can be exercised without any I/O.
    var logger = log.Logger.initStdout(undefined, .silent, "test");
    const screens = [_]switcher.Rect{
        .{ .x = 0, .y = 0, .w = 100, .h = 100 }, // client (screen 0)
        .{ .x = 100, .y = 0, .w = 100, .h = 100 }, // right neighbour (screen 1)
    };
    const addrs = [_]?net.IpAddress{ null, null };
    var sess = Session.init(undefined, &logger, &screens, &addrs);

    // Hold Ctrl while still on the client: tracked but not forwarded.
    try std.testing.expect(sess.captureKey(true, "ctrl") == null);
    try std.testing.expectEqual(@as(usize, 1), sess.held_n);

    // Cross onto the neighbour: a grab, plus a keydown hand-off for Ctrl on it.
    const g = sess.decide(100, 0);
    try std.testing.expect(g.transition == .grab);
    {
        const p = sess.nextPending().?;
        try std.testing.expect(p.tag == .key and p.down and p.edge == 1);
        try std.testing.expectEqualStrings("ctrl", p.name_buf[0..p.name_len]);
        try std.testing.expect(sess.nextPending() == null); // only one held key
    }

    // Motion on the server just streams (no crossing decided locally).
    try std.testing.expect(sess.decide(-100, 0).transition == .none);

    // The server reports its cursor reached the LEFT edge -> cross back to the
    // client: an ungrab, plus a keyup hand-off for Ctrl and a `hide` for the
    // server we left (so its screen shows no stray cursor).
    const u = sess.crossViaReach(.left, 40);
    try std.testing.expect(u.transition == .ungrab);
    {
        const p = sess.nextPending().?;
        try std.testing.expect(p.tag == .key and !p.down and p.edge == 1);
        const h = sess.nextPending().?;
        try std.testing.expect(h.tag == .hide and h.edge == 1);
        try std.testing.expect(sess.nextPending() == null);
    }

    // Releasing Ctrl clears the held set.
    _ = sess.captureKey(false, "ctrl");
    try std.testing.expectEqual(@as(usize, 0), sess.held_n);
}

test "a crossing to an unreachable neighbour is not committed" {
    var logger = log.Logger.initStdout(undefined, .silent, "test");
    const screens = [_]switcher.Rect{
        .{ .x = 0, .y = 0, .w = 100, .h = 100 },
        .{ .x = 100, .y = 0, .w = 100, .h = 100 },
    };
    const addrs = [_]?net.IpAddress{ null, null }; // no real senders => unreachable
    var sess = Session.init(undefined, &logger, &screens, &addrs);

    // Push off the right edge until the switcher decides to grab.
    var d: Decision = .{ .transition = .none, .out = null };
    for (0..60) |_| {
        d = sess.decide(2, 0);
        if (d.transition == .grab) break;
    }
    try std.testing.expect(d.transition == .grab);
    // The neighbour can't be confirmed (no sender), so the caller must not grab.
    try std.testing.expect(!sess.confirmPlacement(d.out.?));
    // Rolling back returns to the client so the cursor is never stranded.
    _ = sess.abortCross();
    try std.testing.expect(sess.onClient());
}

test "Ctrl+Alt+Esc panics back to the client, but only while remote" {
    var logger = log.Logger.initStdout(undefined, .silent, "test");
    const screens = [_]switcher.Rect{
        .{ .x = 0, .y = 0, .w = 100, .h = 100 },
        .{ .x = 100, .y = 0, .w = 100, .h = 100 },
    };
    const addrs = [_]?net.IpAddress{ null, null };
    var sess = Session.init(undefined, &logger, &screens, &addrs);

    _ = sess.captureKey(true, "ctrl");
    _ = sess.captureKey(true, "alt");
    // On the client the chord is inert (no surprise cursor jumps).
    try std.testing.expect(!sess.panicRequested(true, "esc"));

    for (0..60) |_| _ = sess.decide(2, 0);
    try std.testing.expect(!sess.onClient());
    // Remote: the chord fires and forceHome returns control.
    try std.testing.expect(sess.panicRequested(true, "esc"));
    _ = sess.forceHome();
    try std.testing.expect(sess.onClient());
    try std.testing.expectEqual(@as(usize, 0), sess.held_n);
}

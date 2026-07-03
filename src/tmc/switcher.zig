// Edge-switching state machine over a lattice of screens (platform independent).
//
// Every screen is a rectangle in a shared virtual-desktop pixel space. Screen 0
// is the client (fixed at the origin); the rest are servers positioned so their
// borders touch. The client tracks one absolute virtual cursor position and
// which screen it is on, integrating relative motion. When the cursor leaves the
// current screen's rectangle:
//   * if another screen's rectangle contains the new point, control crosses to
//     it (client->server = grab; server->server = hop; server->client = ungrab);
//   * otherwise the border is a wall and the cursor is clamped.
//
// Because crossing is pure geometry, an offline server (absent from the lattice)
// leaves a gap that is simply a wall, and a server reachable only *through* that
// gap is automatically unreachable -- so offline and "cursor-orphaned" both fall
// out for free. There is always a path back to the client along the screens the
// cursor already traversed, honouring the "cursor can always come home" rule.

const std = @import("std");

pub const max_screens = 16;

pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    pub fn contains(self: Rect, px: i32, py: i32) bool {
        return px >= self.x and px < self.x + self.w and py >= self.y and py < self.y + self.h;
    }
};

/// An absolute placement expressed in the target screen's local coordinates.
pub const Placement = struct { screen: usize, x: i32, y: i32 };
pub const Delta = struct { dx: i32, dy: i32 };
pub const Point = struct { x: i32, y: i32 };
pub const Side = enum { left, right, top, bottom };

pub const Outcome = union(enum) {
    /// On the client screen; nothing to forward.
    stay,
    /// client -> server: grab local input and place the cursor on the server.
    grab: Placement,
    /// server -> server: place the cursor on the new server (grab unchanged).
    hop: Placement,
    /// still on the current server: forward this relative delta.
    move: Delta,
    /// server -> client: release the grab. Carries the client-local position.
    ungrab: struct { x: i32, y: i32 },
};

pub const Switcher = struct {
    screens: [max_screens]Rect,
    n: usize,
    client: usize = 0,
    current: usize,
    vx: i32,
    vy: i32,

    /// `screens[0]` must be the client. Screens must not overlap; touching
    /// borders is what makes crossing possible.
    pub fn init(screens: []const Rect) Switcher {
        var s = Switcher{ .screens = undefined, .n = @min(screens.len, max_screens), .current = 0, .vx = 0, .vy = 0 };
        for (screens[0..s.n], 0..) |r, i| s.screens[i] = r;
        const c = s.screens[0];
        s.vx = c.x + @divTrunc(c.w, 2);
        s.vy = c.y + @divTrunc(c.h, 2);
        return s;
    }

    pub fn currentScreen(self: *const Switcher) usize {
        return self.current;
    }

    pub fn onClient(self: *const Switcher) bool {
        return self.current == self.client;
    }

    pub fn onMotion(self: *Switcher, dx: i32, dy: i32) Outcome {
        // On the client the virtual cursor tracks the real (X-synced) cursor, so
        // the crossing off the client is detected here, exactly at the edge.
        if (self.current == self.client) {
            self.vx += dx;
            self.vy += dy;
            const cur = self.screens[self.client];
            if (!cur.contains(self.vx, self.vy)) {
                if (self.findScreen(self.vx, self.vy)) |target| return self.crossTo(target);
                self.clampToCurrent();
            }
            return .stay;
        }
        // On a server the client cannot know the accelerated remote cursor, so it
        // just streams the relative delta; the *server* watches its cursor and
        // reports edge reaches (see `reachedEdge`).
        return .{ .move = .{ .dx = dx, .dy = dy } };
    }

    /// The server reports that its cursor reached `side` at `perp` (the pixel
    /// coordinate along that edge, in the server screen's local space). Cross to
    /// the neighbour on that side, or stay put if that side is a wall.
    pub fn reachedEdge(self: *Switcher, side: Side, perp: i32) Outcome {
        if (self.current == self.client) return .stay; // local side handled by onMotion
        const cur = self.screens[self.current];
        switch (side) {
            .left => {
                self.vx = cur.x - 1;
                self.vy = cur.y + perp;
            },
            .right => {
                self.vx = cur.x + cur.w;
                self.vy = cur.y + perp;
            },
            .top => {
                self.vx = cur.x + perp;
                self.vy = cur.y - 1;
            },
            .bottom => {
                self.vx = cur.x + perp;
                self.vy = cur.y + cur.h;
            },
        }
        if (self.findScreen(self.vx, self.vy)) |target| return self.crossTo(target);
        self.clampToCurrent();
        return .stay;
    }

    fn crossTo(self: *Switcher, target: usize) Outcome {
        const from_client = self.current == self.client;
        self.current = target;
        const r = self.screens[target];
        const lx = std.math.clamp(self.vx - r.x, 0, r.w - 1);
        const ly = std.math.clamp(self.vy - r.y, 0, r.h - 1);
        if (target == self.client) return .{ .ungrab = .{ .x = lx, .y = ly } };
        if (from_client) return .{ .grab = .{ .screen = target, .x = lx, .y = ly } };
        return .{ .hop = .{ .screen = target, .x = lx, .y = ly } };
    }

    /// Undo a just-decided client->server crossing that could not be committed
    /// (e.g. the neighbour did not answer): go back to the client screen with the
    /// virtual cursor clamped to the edge it tried to leave. Returns the
    /// client-local position so the caller can leave the real cursor there.
    pub fn abortToClient(self: *Switcher) Point {
        self.current = self.client;
        self.clampToCurrent();
        const c = self.screens[self.client];
        return .{ .x = self.vx - c.x, .y = self.vy - c.y };
    }

    /// Force control back to the client from anywhere (the panic escape),
    /// recentring the virtual cursor. Returns the client-local centre.
    pub fn forceToClient(self: *Switcher) Point {
        self.current = self.client;
        const c = self.screens[self.client];
        self.vx = c.x + @divTrunc(c.w, 2);
        self.vy = c.y + @divTrunc(c.h, 2);
        return .{ .x = @divTrunc(c.w, 2), .y = @divTrunc(c.h, 2) };
    }

    /// Sync the virtual cursor to the real (OS-accelerated) cursor position while
    /// on the client screen, given `rx,ry` in that screen's local pixels.
    pub fn setClientCursor(self: *Switcher, rx: i32, ry: i32) void {
        if (self.current != self.client) return;
        const c = self.screens[self.client];
        self.vx = c.x + rx;
        self.vy = c.y + ry;
    }

    fn findScreen(self: *const Switcher, px: i32, py: i32) ?usize {
        for (self.screens[0..self.n], 0..) |r, i| {
            if (i == self.current) continue;
            if (r.contains(px, py)) return i;
        }
        return null;
    }

    fn clampToCurrent(self: *Switcher) void {
        const r = self.screens[self.current];
        self.vx = std.math.clamp(self.vx, r.x, r.x + r.w - 1);
        self.vy = std.math.clamp(self.vy, r.y, r.y + r.h - 1);
    }
};

// A helper to build the classic 1-hop star (client + up to 4 neighbours) as a
// lattice, keeping the simple config working through the general code path.
pub const Neighbours = struct { left: ?Rect = null, right: ?Rect = null, top: ?Rect = null, bottom: ?Rect = null };

test "wall without a neighbour stays local and clamps" {
    const screens = [_]Rect{.{ .x = 0, .y = 0, .w = 100, .h = 100 }};
    var s = Switcher.init(&screens);
    for (0..200) |_| _ = s.onMotion(-10, 0);
    try std.testing.expect(s.onClient());
    try std.testing.expectEqual(@as(i32, 0), s.vx);
}

test "cross client -> right server (motion), then back (server reach)" {
    // client [0,100)x[0,100); server 1 to the right [100,200)x[0,100)
    const screens = [_]Rect{
        .{ .x = 0, .y = 0, .w = 100, .h = 100 },
        .{ .x = 100, .y = 0, .w = 100, .h = 100 },
    };
    var s = Switcher.init(&screens);
    // Crossing off the client happens on motion (the local cursor is X-synced).
    var grabbed: ?Placement = null;
    for (0..60) |_| switch (s.onMotion(1, 0)) {
        .grab => |p| grabbed = p,
        else => {},
    };
    try std.testing.expect(grabbed != null);
    try std.testing.expectEqual(@as(usize, 1), grabbed.?.screen);
    try std.testing.expectEqual(@as(i32, 0), grabbed.?.x); // entered server's left edge
    try std.testing.expect(!s.onClient());

    // While on the server, motion is just streamed — it never crosses on its own.
    try std.testing.expect(s.onMotion(-50, 0) == .move);
    try std.testing.expect(!s.onClient());

    // The server reports the cursor reached its LEFT edge -> cross back home.
    const back = s.reachedEdge(.left, 40);
    try std.testing.expect(back == .ungrab);
    try std.testing.expectEqual(@as(i32, 40), back.ungrab.y); // perpendicular pos preserved
    try std.testing.expect(s.onClient());
}

test "abortToClient rolls a just-decided crossing back to the client edge" {
    const screens = [_]Rect{
        .{ .x = 0, .y = 0, .w = 100, .h = 100 },
        .{ .x = 100, .y = 0, .w = 100, .h = 100 },
    };
    var s = Switcher.init(&screens);
    var crossed = false;
    for (0..60) |_| switch (s.onMotion(1, 0)) {
        .grab => crossed = true,
        else => {},
    };
    try std.testing.expect(crossed and !s.onClient());
    // The crossing could not be committed: roll back.
    const home = s.abortToClient();
    try std.testing.expect(s.onClient());
    try std.testing.expectEqual(@as(i32, 99), home.x); // clamped to the right edge
}

test "forceToClient returns home from a server (panic escape)" {
    const screens = [_]Rect{
        .{ .x = 0, .y = 0, .w = 100, .h = 100 },
        .{ .x = 100, .y = 0, .w = 100, .h = 100 },
    };
    var s = Switcher.init(&screens);
    for (0..60) |_| _ = s.onMotion(1, 0);
    try std.testing.expect(!s.onClient());
    const home = s.forceToClient();
    try std.testing.expect(s.onClient());
    try std.testing.expectEqual(@as(i32, 50), home.x); // recentred
}

test "chain: client -> server1 (motion) -> server2 (reach) hops without ungrab" {
    // client [0,100), server1 [100,200), server2 [200,300), all y [0,100)
    const screens = [_]Rect{
        .{ .x = 0, .y = 0, .w = 100, .h = 100 },
        .{ .x = 100, .y = 0, .w = 100, .h = 100 },
        .{ .x = 200, .y = 0, .w = 100, .h = 100 },
    };
    var s = Switcher.init(&screens);
    // Onto server1 by pushing off the client's right edge.
    for (0..60) |_| _ = s.onMotion(1, 0);
    try std.testing.expectEqual(@as(usize, 1), s.currentScreen());
    // server1 reports its RIGHT edge -> hop onto server2 (no ungrab).
    const out = s.reachedEdge(.right, 30);
    try std.testing.expect(out == .hop);
    try std.testing.expectEqual(@as(usize, 2), out.hop.screen);
    try std.testing.expectEqual(@as(usize, 2), s.currentScreen());
}

test "gap acts as a wall (orphaned server unreachable)" {
    // server2 exists but there is a gap between client and it (no server1):
    // client [0,100), (gap 100..200), server2 [200,300).
    const screens = [_]Rect{
        .{ .x = 0, .y = 0, .w = 100, .h = 100 },
        .{ .x = 200, .y = 0, .w = 100, .h = 100 },
    };
    var s = Switcher.init(&screens);
    for (0..300) |_| _ = s.onMotion(5, 0);
    try std.testing.expect(s.onClient()); // never reached the orphaned server
    try std.testing.expectEqual(@as(i32, 99), s.vx); // pinned at the client's right wall
}

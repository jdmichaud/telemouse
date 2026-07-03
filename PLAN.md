# telemouse — plan

This document is the design of record. It covers what exists, what is being
added (the configuration UI and everything it drags in), and the decisions
behind them. `STATUS.md` tracks progress against this plan.

## 1. What telemouse is

Two programs that let one keyboard and mouse drive several computers over a LAN,
Synergy/Barrier style:

- **`tms`** — server: a headless daemon that injects mouse/keyboard input on the
  machine it runs on (uinput on Linux, SendInput on Windows).
- **`tmc`** — client: owns the physical keyboard and mouse; when the pointer
  crosses a screen edge it captures local input and forwards it to the neighbour
  that owns the screen on the other side.

### Core architecture (settled, do not regress)

- **The client is the only speaker.** `tmc` talks to each `tms` directly. Servers
  never talk to each other and never forward. "Chaining" (`tmc → tms1 → tms2`)
  is only a *spatial layout*: tms2 is "the screen you reach past the far edge of
  tms1". The client tracks the cursor across the whole arrangement and sends
  input to whichever server owns the current screen. Servers stay dumb sinks.
- **Transport by nature of the data.** Relative motion (`move dx dy`) streams
  over UDP: loss- and order-tolerant (a dropped delta is a pixel short; reordered
  deltas still sum to the same place) and it composes across chained screens.
  Everything discrete — clicks, keys, absolute placement (`mouse x y`) — goes
  over TCP (reliable, ordered). One address/port carries both.
- **Concurrency without parallelism.** The server multiplexes its UDP and TCP
  sockets on one `Io.Select` loop; input is applied on that single task, so no
  locking. The Windows client capture is the one place with two threads (hook
  pump + sender), joined by a lock-free SPSC queue, no mutex.
- **Discovery is real mDNS/DNS-SD** on `224.0.0.251:5353`, self-contained (no
  Avahi/Bonjour). Servers advertise `_telemouse._udp.local`; the client queries
  and reads back address, port, name.
- **Dependency ethos.** Raw platform syscalls behind small abstractions; no
  binding packages. Config is ZON under the XDG path. CLI via a vendored `clap`.

## 2. New capability: visual configuration UI

`tmc` gains a graphical configuration screen for laying out the server lattice.

### 2.1 When it appears

- `tmc` with **no arguments and no config file**: print
  `no config file, opening configuration UI` and open it. On **OK**, write the
  config and print `configuration saved in <path>`.
- `tmc --configure` (alias `-C`): open the UI regardless, pre-populated from the
  existing config, merged with a fresh discovery scan. This is the only way to
  edit an existing config without deleting the file.
- **No display available** (headless / SSH, X unreachable): do not crash. Print
  `no config file and no display; run 'tmc --configure' on a desktop or edit
  <path> by hand` and exit non-zero.
- Closing via the window ✕ = **Cancel**. Cancel with no prior config → exit
  writing nothing.

### 2.2 The lattice model

- A canvas of screen icons. The **client's screen is fixed at the centre** and
  cannot be moved.
- Detected servers start scattered around the canvas (floating).
- Dragging a screen near an edge of an already-placed screen **snaps** it so the
  borders touch (grid-aligned, edge-to-edge). You can snap to the client first,
  then snap others to those, building outward.
- **Unsnap cascade:** after any unsnap/move, recompute connectivity to the
  centre; every screen no longer connected to the client through a chain of
  touching borders becomes floating. (Rule is connectivity-based, not
  "children of", so it is unambiguous for diamond/shared-border shapes.)
- Screens are **scaled to their real resolution** on the canvas (see §2.5), so a
  1080p and a 4K screen look proportionally right.

### 2.3 Screen states (the offline story)

A previously-configured server may be off, or reachable on the network but only
cursor-reachable through an offline screen. Three visual states:

- **Online & connected** — normal icon; part of the active lattice.
- **Offline** — configured but did not answer discovery. Greyed, small ✕. The
  machine itself is absent.
- **Cursor-orphaned** — online, but its only lattice path to the client crosses
  an offline screen. Dimmed/hatched differently from offline; the machine is
  fine, the *path* is broken (the user can re-snap it elsewhere to fix it).

### 2.4 Controls (kept minimal)

- The lattice canvas (drag/snap).
- **OK** / **Cancel**.
- **Identify** — wiggle the selected server's pointer in a small circle so the
  user can tell which physical machine an icon is (uses the existing protocol;
  ~10 lines). Also on double-click.
- **Rescan** — re-broadcast discovery to pick up servers powered on while the UI
  is open (or auto-rescan every few seconds while open).
- **Status bar** — hovered screen's name, `addr:port`, resolution, and state.
- The UI auto-fills the **client's** screen size from the OS (`GetSystemMetrics`
  / `XDisplayWidth`), fixing the "user must hand-enter resolution" wart.

Everything else (log level, ports, timeouts) stays hand-edited in the file; it
would bloat the UI for options set once.

### 2.5 Runtime rules the UI implies

- **Universal fallback: always be able to bring the cursor home.** Any error,
  lost neighbour, or dead end resolves by returning control to the client
  screen. This is the invariant the runtime must never violate.
- **Unconnected or dead edges are walls.** A screen border that touches nothing
  configured, or touches a server that is offline, behaves as a solid wall — the
  cursor cannot leave through it. This prevents the cursor from walking onto an
  unreachable screen and getting stuck.
- **Liveness at runtime.** The edge-switch runtime must know which neighbours are
  live (v1: the startup discovery result; later: periodic re-check) so it can
  apply the wall rule to offline neighbours.

## 3. Implications this pulls in

### 3.1 Config schema — from star to lattice

Current config is a depth-1 star (`left/right/top/bottom` of the client only),
which cannot express a chained lattice. New primary schema:

```zig
.{
    // Simple manual/programmatic setups keep the star shorthand (kept):
    .left = null, .right = "living-room:24800", .top = null, .bottom = null,

    // Full lattice (written by the UI; wins if present). x,y is the pixel
    // position of each screen's top-left in a virtual desktop; the client is
    // implicitly at (0,0) with its own resolution. Adjacency is derived from
    // which screens share a touching border.
    .screens = .{
        .{ .name = "living-room htpc", .addr = "192.168.1.20:24800", .x = 1920, .y = 0 },
        .{ .name = "laptop",           .addr = "192.168.1.21:24800", .x = 3840, .y = 120 },
    },
}
```

- **Pixel-accurate from the start** (no simplified grid phase): positions are
  pixel offsets in the virtual desktop, screens are their real resolution, and
  they may be offset along a shared border (e.g. a 1080p screen snapped to the
  top of a 4K one). Snapping aligns a touching edge; the perpendicular offset is
  whatever the user dragged to.
- **Keep the star shorthand** for people configuring by hand or by script on a
  simple one-hop setup. If `.screens` is present it takes precedence.

### 3.2 Server identity by name, not IP

Storing only `ip:port` rots when DHCP reassigns addresses. Store the mDNS
**instance name** as primary identity (+ last-known `addr:port` as fallback), and
re-resolve names via discovery at startup. "Name didn't answer discovery" *is*
the offline test.

### 3.3 Servers must advertise their resolution

Needed so the client can (a) scale icons in the UI, (b) compute the absolute
placement in the entered server's coordinates, and (c) know where one screen ends
and the next begins in the lattice. Carry width/height in the mDNS **TXT record**
(e.g. `w=1920 h=1080` alongside the existing `n=<name>`). The server queries its
own resolution at startup.

### 3.4 Switcher generalisation

`src/tmc/switcher.zig` currently models "4 edges of one screen". Generalise to
"walk a grid/lattice of screens": current active screen, per-edge neighbour
lookup, absolute placement on entering a screen, relative stream while on it,
wall on unconnected/offline edges, fallback-home invariant. Stays platform
agnostic and unit-testable.

## 4. The UI toolkit (Option 1: handmade, minimal deps)

Chosen for least static footprint and a consistent look across OSes:

- **Windows:** raw Win32 + GDI. Window + message loop; blit a pixel buffer with
  `StretchDIBits`. **Zero external dependencies** (already link `user32`).
- **Linux:** raw **XCB/Xlib** — `XCreateWindow` + `XPutImage` (MIT-SHM if
  available) + `XNextEvent`. **One dependency, `libX11`/`libxcb`**, present on
  essentially every desktop; runs under XWayland on Wayland. No Wayland-native
  backend (much more code for a small tool).
- **Widgets are software-rendered by us** into a framebuffer, reusing the
  zig-utils drawing tooling (`draw.zig`, `ttf.zig`/bitmap font, `png.zig`,
  `geometry.zig`). The UI looks identical on both OSes because we draw every
  pixel.

### 4.1 Consistent Win32 look on both OSes

Reference experiment: **`../wine-test/win2k_popup_x11.c`** — it reproduces the
classic Windows 3D chrome (raised/sunken bevels, `#D4D0C8 (212,208,200)` face,
white/light/shadow/dk-shadow edge tables, navy→blue caption gradient, min/max/
close glyphs) using **only libX11 rectangles and lines** — no Wine, no Win32.
That is the blueprint: implement one set of "classic control" drawing primitives
(`drawEdge`, `drawButton`, bevels, caption, checkbox) over a generic framebuffer,
and back it with GDI on Windows and hand-painted X11 on Linux — same algorithm,
same palette, same pixels. `win2k_popup_wine.c` also shows Wine's authentic
`DrawEdge`/`DrawFrameControl` (LGPL) if we want to match metrics exactly; we will
redraw rather than copy to avoid licence entanglement.

### 4.2 Win95 monitor icon

The screen icon is the Windows 95 Display-properties monitor (grey CRT, blue
screen, chunky 2-bit shading). **Redraw as original pixel art** in that spirit
(don't copy Microsoft's bitmap); embed via the zig-utils image tooling. States
(online/offline/orphaned/selected) are variants of the same sprite.

## 5. Protocol additions summary

- `move <dx> <dy>` (UDP) — relative motion stream. **(done)**
- `mouse <x> <y>` (TCP) — absolute placement, now reliable. **(done)**
- `keydown/keyup/buttondown/buttonup/scroll` (TCP). **(done)**
- mDNS TXT gains `w=`/`h=` resolution. **(planned, §3.3)**
- Optional: an **acked placement** so the client can withhold the UDP stream
  until the server confirms the cursor was placed (removes the cross-channel
  race where UDP `move` overtakes the TCP `mouse` on first crossing). Decision
  pending; see STATUS "open questions".

## 6. Build order

1. **Server resolution advertisement** (§3.3) — small, unblocks UI scaling and
   correct placement. Server-side + mDNS TXT + client parse.
2. **Config schema + switcher generalisation** (§3.1, §3.4) — headless,
   unit-testable; the runtime foundation the UI writes to.
3. **Offline/liveness + wall/fallback runtime rules** (§2.5) — make edge
   switching safe with missing servers before adding the UI that configures them.
4. **UI framebuffer + classic-control toolkit** (§4) — X11 backend first
   (testable here), then Win32; shared drawing core.
5. **Lattice canvas: icons, drag, snap, unsnap-cascade, states** (§2.2–2.3).
6. **OK/Cancel/Identify/Rescan/status bar + config read-write wiring** (§2.4).
7. **Polish:** eager TCP connect (placement race), reconnect, modifier-state on
   crossing, packaging.

## 7. Non-goals / deferred

- macOS (would need CGEventTap capture / CGEvent injection).
- Wayland-native UI (XWayland suffices).
- Auth/encryption on the wire — **noted as a real exposure** (any LAN host can
  drive a running `tms`); decision deferred, tracked in STATUS.
- Server-to-server anything (contradicts the client-only-speaker model).

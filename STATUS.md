# telemouse — status

Progress against `PLAN.md`. Kept in sync as work lands.

## Legend

- `[x]` done and **verified** (unit test, or exercised over loopback here)
- `[~]` **built but unverified** — compiles / cross-compiles, but never run on
  real hardware (this sandbox has no display, no `/dev/input`, no root, no
  Windows). Treat as "expect first-run bugs".
- `[ ]` not started
- `[>]` in progress

The single biggest caveat: **nothing in the input path — server injection or
client capture — has run on real hardware.** Everything below marked `[~]` needs
a live smoke test. See "Next" for the recommended first step.

## Foundation (shipped)

- [x] Project scaffold: `build.zig` (native + `-Dtarget=x86_64-windows`), ZON manifest
- [x] CLI parsing (`src/common/clap.zig`, ported from jdmichaud/zig-utils)
- [x] Logging: levels, stdout / `--log-file` / `--syslog` (verified incl. journald)
- [x] Config: ZON at XDG path, `-c` override, clear parse diagnostics
- [x] Unit tests: protocol, keymap, log, dns, mdns, switcher

## Transport & protocol

- [x] UDP + TCP on one `Io.Select` server loop (verified: mixed stream, disconnect)
- [x] `move dx dy` (UDP, relative) — verified over loopback
- [x] `mouse x y` (TCP, absolute placement) — verified over loopback
- [x] `click` / `key` / `keydown` / `keyup` / `buttondown` / `buttonup` / `scroll` — verified
- [x] Transport routing `protocol.Command.transport()` (`move`=udp, else tcp)
- [x] mDNS TXT advertises resolution (`w=`/`h=`) — verified: TXT `n=/w=/h=`, client shows `name (WxH)`
- [x] **Acked placement** (`place x y` over TCP → server replies `placed\n`; client
      waits for the ack before streaming UDP `move`, gated by an atomic `ready`
      flag per sender). Plain `mouse` stays fire-and-forget so `-e`/stdin don't
      pile up unread acks. **Decision: Option A** (see "Open questions"). Verified
      over loopback: `place` acked, `mouse` not, acks stay 1:1. Client-side gate
      built; full gate→ack→UDP flow needs the live edge-switch path.

## Server (`tms`)

- [x] UDP+TCP serving, `--dry-run` (verified: all commands logged/applied in dry-run)
- [x] Clean error + exit when `/dev/uinput` inaccessible
- [~] Linux uinput injection incl. relative `mouseMoveRelative`, scroll — **never emitted for real**
- [~] Windows `SendInput` backend (abs, relative, buttons, keys, scroll) — **never run**
- [x] Advertise own screen resolution: Windows queries `GetSystemMetrics`
      (SetCursorPos is pixel-native); Linux advertises the configured coordinate
      space (the uinput ABS range — which *is* the space it injects into, so it's
      the correct thing to advertise). `screenSize()` → mDNS TXT `w=`/`h=`.

## Discovery (mDNS / DNS-SD)

- [x] Client↔server discovery over real DNS-SD on 5353 (verified: correct addr:port)
- [x] Responder coexists with system mDNS via `SO_REUSEADDR`/`SO_REUSEPORT` (verified bind)
- [x] Wire response well-formed (PTR/SRV/TXT/A, decoded and checked)
- [~] `avahi-browse` interop — unconfirmed (no D-Bus to the daemon in sandbox)
- [~] Windows mDNS responder (raw ws2_32) — cross-compile only
- [ ] Resolution in TXT; client parses it

## Edge switching (lattice)

- [x] Switcher generalised to a **pixel-space lattice walk** — unit-tested:
      cross, wall, chain hop (server→server without ungrab), orphan-as-wall.
      Offline/orphaned fall out of the geometry (a gap is a wall).
- [x] Session drives the lattice (screen-indexed senders, hop = place on new
      server, ungrab returns client-local position)
- [x] tmc builds the lattice from the star shorthand (client + neighbours);
      `.screens` config (from the UI) will supersede it
- [x] Switcher state machine — unit-tested (enter/move/leave, wall clamp, cross-back)
- [x] Absolute-on-enter, relative-during, transport split — logic in `session.zig`
- [~] Linux evdev capture (`EVIOCGRAB`, code→name) — **never captured a real event**
- [~] **Cursor tracking via X11** (`src/tmc/xcursor.zig`): on the local screen the
      switcher syncs its virtual cursor to the *real* (OS-accelerated) cursor via
      `XQueryPointer` — fixes the crossing happening before the edge / drifting
      with speed (raw device motion ≠ accelerated cursor). Remote streaming is now
      **absolute** (`moveto x y`, UDP, no accel) so the remote cursor tracks the
      virtual cursor exactly. Cursor is **hidden** while remote (`XFixesHideCursor`,
      auto-restored by the X server on crash) and **warped** back on return.
      Degrades to a no-op with no X display. **Built, not yet run** (fixes reported
      from live testing; needs re-test on real hardware).
- [~] Windows low-level hooks + centre-trap + two-thread SPSC hand-off — **never run**
- [x] Clean error when `/dev/input` inaccessible (verified)

## Configuration UI (PLAN §2) — visual foundation done

Following `../wine-test/win2k_popup_wine.c` (the reference of truth):

- [x] Software framebuffer + 2D primitives + **authentic Wine `sys_colors`** +
      debug BMP dump (`src/ui/framebuffer.zig`)
- [x] Classic control drawing: 3D bevel (raised/sunken), panel, sunken well,
      push button (+ default ring + label), caption gradient
      (`src/ui/classic.zig`) — visually verified (render→PNG) + pixel assertions
- [x] **Tahoma text from the font's own embedded bitmap strikes** (ppem 11,
      1-bit) — pixel-identical to wine.c's `pixelsize=11:embeddedbitmap=true:
      antialias=false`; embedded `tahoma.ttf`, no ttf.zig / FreeType / Xft;
      `src/ui/font.zig`. Visually verified (upper/lower/digits/punct/IPs).
- [x] Win95 monitor **screen cells** with states (client/online/offline/
      orphaned/selected) + power LED + label (`src/ui/canvas.zig`) — visually
      verified (full arrangement mock rendered)
- [x] Lattice **snapping** + **connectivity/unsnap cascade** — unit-tested
- [x] Compose the live dialog: caption, canvas well, screen cells, status bar,
      OK/Cancel/Rescan/Identify buttons (`src/ui/configui.zig` `render`) — the
      layout/drag/hit-test/edge-derivation logic is **unit-tested** (buildModel,
      deriveEdges, sideOf, connectivity/orphan-as-wall)
- [~] Platform window layer (`src/ui/window.zig`): **Linux Xlib** `XPutImage`
      blit + `XNextEvent` loop. **Borderless fixed-size popup** (WS_POPUP-style):
      equal min/max `XSizeHints` (non-resizable) + `_MOTIF_WM_HINTS`
      decorations-off, so it draws its own Win2k caption (gradient + close X) and
      is dragged by that caption (`moveBy`/`XMoveWindow`, root-coord deltas) —
      **built, never run** (no display in sandbox). Win32/GDI backend still a stub.
- [x] Screen icon = Win95 **Display-Properties monitor** (guidebookgallery
      win95-1-1.png), traced from the reference at its native 186x170 and matched
      with a pixel-diff harness (`bevel95` + `m_face/m_shadow/m_hi/m_dark` = the
      Win95 palette 192/128/255/0; teal 0,128,128; **~87% exact-pixel match**, the
      rest = the reference's dithered outer border + fine base geometry that don't
      survive small cells). Structure: raised body + big sunken screen (bezel
      ~w/11) filling the body so a **wider cell yields a wider monitor** ("extend
      width for modern ratios"); base = bar (LED green/amber/red + recessed slot)
      / narrower neck / wider foot. Server name in white Tahoma (truncated).
      **Only the screen stretches**: the bezel and the whole base (bar/neck/foot)
      are sized from the cell *height*, so they stay identical across aspect
      ratios; only the screen widens. The **whole icon fits inside the cell**
      (option (c)), so monitors snap at their physical edges with no overlap — the
      teal is a symbolic screen, not a pixel-true display (true aspect would need
      chrome outside the cell → overlap). Config UI enlarged to **900x620** (~2x,
      bigger monitors); the viewport **centres on the client** and fits the rest
      around it. Verified: reference diff, stretch demo, full dialog.
- [x] Caption **close X** = the real **Marlett** glyph (0x72), rasterised from
      the embedded `marlett.ttf`'s own `glyf` outline via scanline fill
      (`src/ui/marlett.zig`) — no bitmap strikes in Marlett, so it's filled from
      the outline; unit-tested
- [x] Server advertises its **hostname** (Linux `uname`, Windows
      `GetComputerNameA`) as the mDNS display name — fixes the client/UI showing
      the uinput device name ("telemouse virtual input") instead of the machine
- [x] Stable viewport: zoom fit-all computed **once**, held fixed while dragging
      (no zoom-during-drag); refit only on Rescan
- [x] Snapping: **screen-space threshold** converted through the viewport (so it
      engages at any zoom), independent x/y align, **live** during drag —
      unit-tested (the previous fixed 24-world-px threshold was sub-pixel at
      fit-all zoom, which is why snapping appeared broken)
- [x] Triggers: first run (no config) from a tty **and** `--configure`/`-C`
      open the UI; graceful no-display message ("run on a desktop, or edit
      <path>") — **verified headless** (falls back correctly, exit 1)
- [x] Read existing edges into the UI (`buildModel` honours `left/right/top/
      bottom`); write config on OK (`saveConfig` emits ZON, preserving unrelated
      settings) — round-trip through the loader verified
- [x] Rescan (re-discovers, rebuilds arrangement keeping current edges)
- [x] Esc cancels the dialog (X11 layer reports the keysym via `XLookupKeysym`,
      dialog matches `XK_Escape`) — same as Cancel / close X
- [x] Identify — wiggles the selected server's pointer (a short horizontal shake
      of relative `move`s over UDP, `configui.identify`) so you can tell which
      physical machine it is; status line shows progress. Verified: the server
      receives and applies the exact 8-packet wiggle sequence (button click
      itself needs a display)
- [ ] Auto-fill client resolution from OS (still taken from config dims)
- [ ] Win95 monitor icon as original pixel art (current cell is drawn procedurally)

## Config schema & identity (PLAN §3)

- [x] **Lattice schema** (`.screens`): a list of `{name, addr, x, y, w, h}` in
      shared virtual-desktop pixels; first entry (no `addr`) is the client. Kept
      the `left/right/top/bottom` shorthand as the simple form; `.screens`
      supersedes it. `tmc` `buildLattice` builds the Session from `.screens` or
      the star fallback; mode selection triggers edge-switch on either. The UI
      restores a saved lattice (positions preserved, liveness re-checked, new
      servers added floating) and writes `.screens` on OK. Verified: ZON
      round-trips through the loader; unit-tested restore/liveness/re-save.
- [x] Server identity by mDNS **name** (+ addr fallback), re-resolved at startup:
      `.screens[*].name` is the stable key. The UI matches saved↔discovered by
      name first (then addr) and refreshes the stored address; `tmc` runs a
      discovery scan at edge-switch startup and `resolveScreenAddr` looks each
      name up to its current `ip:port` (falls back to the saved addr). Verified
      live: a stale-addr / correct-name config re-resolved to the server's real
      address over loopback mDNS. Unit-tested (moved server matched by name).
- [x] Switcher already a lattice walk (see "Edge switching") — `.screens` feeds it

## Offline / safety runtime (PLAN §2.5)

Implemented via **startup liveness + the switcher's existing geometry** (a gap is
a wall): at edge-switch startup `tmc` scans discovery and `buildLattice` drops
any `.screens` neighbour discovery cannot see, so its edge becomes a wall.

- [x] Liveness of neighbours (v1: startup discovery result) — verified live
- [x] Offline / unconfigured / dead edges act as walls — offline dropped from the
      lattice → gap → clamp; unconfigured edges were already walls. Verified:
      `ghost-pc` logged "is offline; that edge acts as a wall".
- [x] Cursor-orphaned (online but path blocked) — a screen only reachable through
      a dropped (offline) one is left not touching the lattice → walled off (the
      switcher's orphan-as-wall is unit-tested)
- [x] Universal fallback: the client is always screen 0 and always present, and
      crossings back toward it always resolve, so the cursor can always come home
- Safeguard: if the discovery scan comes back empty (mDNS unavailable) liveness
  is **not** applied — the saved lattice is trusted as-is (no false "all offline")
- [ ] Runtime (not startup) liveness — re-check while running, reconnect (future)

## Robustness / polish

- [x] **Eager TCP connect** — `Session.connectAll()` (after init, once senders are
      at their final address) pre-opens each neighbour's TCP so the first
      crossing doesn't pay connection setup on top of the placement ack
- [x] **Reconnect** when a neighbour's TCP drops — `sendTcp`/`awaitAck` `dropTcp()`
      on a write/read error; the next send reconnects via `tryConnect`
- [x] **Held-modifier hand-off at a crossing** — `Session` tracks held keys from
      every key event; on grab/hop/ungrab it queues keyup(old)+keydown(new) in
      `pending`, drained by both backends after `decide`. Unit-tested (grab→down,
      ungrab→up, release clears)
- [x] **Graceful shutdown** — SIGINT/SIGTERM (`sigaction`) on Linux, console
      handler on Windows set an atomic; the loop wakes on a 250 ms bounded UDP
      receive, `select.cancelDiscard()`s the in-flight ops, then returns so
      `main`'s defers run (**uinput destroy releases any held keys**). Verified:
      SIGINT → "shutting down" → exit 0, no fault. (mDNS thread is detached; the
      OS reclaims it and its socket on exit.)
- [x] **Packaging** — `install.sh` (+`--server`), `packaging/*.service` +
      udev rule, `.github/workflows/ci.yml` (libX11 + pinned Zig, build/win/test),
      `.gitignore`; `git init` done (staged, uncommitted)

## Next (recommended order, from PLAN §6)

1. **Server resolution advertisement** — small, unblocks UI scaling + correct
   placement. (Server queries own size → mDNS TXT `w=`/`h=` → client parses.)
2. **Config lattice schema + switcher generalisation** — headless, unit-testable.
3. **Offline liveness + wall/fallback rules** — make switching safe with missing
   servers *before* the UI that configures them.
4. **UI**: X11 framebuffer + classic-control toolkit (testable here), then Win32,
   then the lattice canvas and controls.
5. **Live smoke test** of the whole input path on real Linux + Windows — this is
   the outstanding validation gate for everything marked `[~]`.

## Open questions / decisions pending

- ~~**Placement ordering**~~ — **decided: Option A** (acked `place` handshake).
  Implemented: `place`→`placed\n`, per-sender atomic `ready` gate on the client.
  An eager/persistent TCP connection already keeps the ack to ~1 RTT.
- **Auth/encryption:** none today — any LAN host can drive a running `tms`.
  Real exposure; in-scope decision deferred.
- ~~Lattice v1 constraints~~ — **decided: pixel-accurate from the start** (real
  resolutions, pixel positions, offset-along-border allowed). No simplified grid
  phase. Resolution advertisement is the prerequisite (in progress).

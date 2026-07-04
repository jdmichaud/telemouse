# telemouse

One keyboard and mouse for several computers, over the local network —
Synergy/Barrier style.

telemouse is two small programs:

- **`tms`** — the *server*: a headless daemon that generates mouse and keyboard
  input on the machine it runs on.
- **`tmc`** — the *client*: owns your physical keyboard and mouse, discovers
  servers on the LAN, and hands control to a neighbour when you push the pointer
  off a screen edge. It also shares the clipboard across machines.

It runs on **Linux** and **Windows**, is dependency-light (no external daemons),
and on an X11 desktop needs no special permissions.

For how it works inside, see [ARCHITECTURE.md](ARCHITECTURE.md).

## Installing and using

### Build

telemouse builds with a recent [Zig](https://ziglang.org) (0.17-dev or newer):

```sh
zig build -Doptimize=ReleaseSafe    # produces ./zig-out/bin/tms and ./zig-out/bin/tmc
```

Copy `tms`/`tmc` onto your `PATH`, or use `./install.sh` to install them (and,
with `./install.sh --server`, a systemd unit for a headless server).

### Permissions (Linux)

On an **X11** desktop there is nothing to do — both ends work as ordinary X
clients. On **Wayland or a headless server** telemouse falls back to the kernel
input devices, which live behind the `input` group; grant access once with:

```sh
./setup-linux.sh --client            # a machine you drive from
./setup-linux.sh --server            # a machine being controlled
```

Then log out and back in. On **Windows** no setup is needed.

### Run the server

Run `tms` on each machine you want to control (as yourself, in your desktop
session):

```sh
tms                                 # listen on 0.0.0.0:24800
tms --dry-run --log-level debug     # log commands instead of injecting them
```

### Use the client

Run `tmc` on the machine with the keyboard and mouse.

```sh
tmc                                 # discover and list servers on the LAN
tmc -a 10.0.2.15 -e "mouse 960 540" # send one command to a server, then exit
tmc -a 10.0.2.15 -e "key ctrl+alt+t"
```

For the Synergy-style experience, tell `tmc` which server sits on which edge and
just run it — push the pointer off that edge and mouse + keyboard control jump to
the neighbour (and back when you cross the other way). Arrange screens visually
with `tmc --configure`, or edit the config file by hand:

```zig
// ~/.config/telemouse/tmc.zon
.{
    .right = "192.168.1.20:24800",   // a tms to the right of this screen
    .left  = "192.168.1.21:24800",   // ... and one to the left; omit for a wall
}
```

```sh
tmc                                 # now runs as an edge-switching client
```

### Configuration

Both programs read an optional [ZON](https://ziglang.org/documentation/master/#Zig-Object-Notation)
file (`~/.config/telemouse/{tms,tmc}.zon`, or `%APPDATA%\telemouse\` on Windows);
`-c <file>` overrides the path and a missing file just means "use defaults".
Command-line options take precedence. See
[`config/tms.zon.example`](config/tms.zon.example) and
[`config/tmc.zon.example`](config/tmc.zon.example) for the available keys, and
`tms --help` / `tmc --help` for every flag.

## Contributing

Contributions are welcome. The project keeps to plain Zig with self-declared
`extern` bindings and no external dependencies; new code should match the
surrounding style.

```sh
zig build                            # build (debug)
zig build test                       # run the unit tests
zig build -Dtarget=x86_64-windows    # cross-compile the Windows binaries
zig build run-tms -- --dry-run       # run a target (args after --)
```

- [ARCHITECTURE.md](ARCHITECTURE.md) explains the transport, discovery, edge
  switching, input backends and the wire protocol, with a map of `src/`.
- `PLAN.md` is the original design-of-record; `STATUS.md` tracks progress.
- Much of the input path (X11 injection/capture, Windows) can only be exercised
  on real hardware, so please note what you actually tested on a change.

Open a pull request against `main` with a focused, self-contained change and a
description of what you verified.

## License

[MIT](LICENSE) © Jean-Daniel Michaud

#!/usr/bin/env sh
# Build telemouse in release mode and install the binaries. With --server, also
# install the systemd unit + udev rule and create the service user (needs root).
#
#   ./install.sh            # build + install tms and tmc to $PREFIX/bin
#   sudo ./install.sh --server   # the above, plus the server service + udev rule
set -eu

PREFIX="${PREFIX:-/usr/local}"
SERVER=0
for arg in "$@"; do
    case "$arg" in
        --server) SERVER=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

cd "$(dirname "$0")"

echo "building (ReleaseSafe)…"
zig build -Doptimize=ReleaseSafe

echo "installing binaries to $PREFIX/bin"
install -Dm755 zig-out/bin/tms "$PREFIX/bin/tms"
install -Dm755 zig-out/bin/tmc "$PREFIX/bin/tmc"

if [ "$SERVER" -eq 1 ]; then
    if [ "$(id -u)" -ne 0 ]; then
        echo "--server needs root (for the udev rule, service user and unit)" >&2
        exit 1
    fi
    echo "creating 'telemouse' service user (if missing) and adding it to 'input'"
    id telemouse >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin telemouse
    usermod -aG input telemouse

    echo "installing udev rule for /dev/uinput"
    install -Dm644 packaging/99-telemouse-uinput.rules /etc/udev/rules.d/99-telemouse-uinput.rules
    udevadm control --reload-rules && udevadm trigger || true

    echo "installing systemd unit"
    install -Dm644 packaging/telemouse-server.service /etc/systemd/system/telemouse-server.service
    systemctl daemon-reload
    echo "done — start the server with:  systemctl enable --now telemouse-server"
else
    echo "done — run 'tms' on the machine to control, 'tmc' on the machine you drive from."
    echo "(for the server as a service: sudo ./install.sh --server)"
fi

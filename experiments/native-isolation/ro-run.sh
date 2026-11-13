#!/bin/sh
# Write audit for run-probes.sh: run a command with no network, and with every
# user-writable path except $TMPDIR read-only. Run it in a user+net+mount namespace:
#   d=$(mktemp -d) && TMPDIR=$d unshare -rnm experiments/native-isolation/ro-run.sh \
#       experiments/native-isolation/run-probes.sh; ls -A "$d"   # empty = no stray write
set -e
[ -n "${TMPDIR:-}" ] && [ -d "$TMPDIR" ] || { echo "ro-run: set TMPDIR to an existing directory"; exit 3; }
for m in "$HOME" /tmp /var/tmp /dev/shm /run/lock /run/shm /run/user/*; do
    [ -d "$m" ] && [ ! -L "$m" ] || continue
    mount --bind "$m" "$m"
    mount -o remount,bind,ro "$m"
done
mount --bind "$TMPDIR" "$TMPDIR"
mount -o remount,bind,rw "$TMPDIR"
for m in "$HOME" /tmp; do
    if touch "$m/.ro-run-probe" 2>/dev/null; then rm -f "$m/.ro-run-probe"; echo "ro-run: $m is writable"; exit 3; fi
done
echo "ro-run: read-only: $HOME /tmp /var/tmp /dev/shm /run/lock /run/shm /run/user/*; writable: $TMPDIR; no network"
exec "$@"

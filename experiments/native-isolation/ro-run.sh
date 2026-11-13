#!/bin/sh
# Write confinement for run-probes.sh: run a command with no network, and with every
# mount read-only except $TMPDIR, kernel pseudo file systems and device nodes.
# It starts itself in new user, network and mount namespaces (unshare -rnm):
#   d=$(mktemp -d) && TMPDIR=$d experiments/native-isolation/ro-run.sh \
#       experiments/native-isolation/run-probes.sh; ls -A "$d"   # empty = nothing left behind
set -e
[ -n "${TMPDIR:-}" ] && [ -d "$TMPDIR" ] || { echo "ro-run: set TMPDIR to an existing directory"; exit 3; }
# Start itself in new user, network and mount namespaces. The inner run checks
# that its mount namespace differs from the outer one, so no remount reaches the host.
if [ -z "${RO_RUN_OUTER_MNT:-}" ]; then
    RO_RUN_OUTER_MNT="$(readlink /proc/self/ns/mnt)" exec unshare -rnm "$0" "$@"
fi
[ "$(readlink /proc/self/ns/mnt)" != "$RO_RUN_OUTER_MNT" ] \
    || { echo "ro-run: not in a private mount namespace"; exit 3; }
# No network: the namespace must have no interface other than lo.
ifs="$(awk -F: 'NR > 2 {gsub(/ /, "", $1); if ($1 != "lo") print $1}' /proc/net/dev)"
[ -z "$ifs" ] || { echo "ro-run: network interfaces present: $ifs "; exit 3; }
skip() {  # mounts that stay as they are: pseudo file systems and device nodes
    case "$1" in /proc|/proc/*|/sys|/sys/*|/dev/pts|/dev/mqueue|"$TMPDIR") return 0 ;; esac
    [ -c "$1" ]
}
# Field 5 of mountinfo is the mount point, field 6 its options.
awk '{print $5}' /proc/self/mountinfo | sort -u | while read -r m; do
    skip "$m" && continue
    mount -o remount,bind,ro "$m" 2>/dev/null \
        || { mount --bind "$m" "$m" && mount -o remount,bind,ro "$m"; } \
        || { echo "ro-run: cannot make $m read-only"; exit 3; }
done
mount --bind "$TMPDIR" "$TMPDIR"
mount -o remount,bind,rw "$TMPDIR"
# The last mountinfo entry for a path is the visible one. List every visible rw mount.
rw="$(awk '{o[$5]=$6} END {for (m in o) if (o[m] ~ /(^|,)rw(,|$)/) print m}' /proc/self/mountinfo | sort |
    while read -r m; do skip "$m" || echo "$m"; done)"
[ -z "$rw" ] || { echo "ro-run: still writable: $rw"; exit 3; }
for m in "$HOME" /tmp /var/tmp /dev/shm /run; do
    if touch "$m/.ro-run-probe" 2>/dev/null; then rm -f "$m/.ro-run-probe"; echo "ro-run: $m is writable"; exit 3; fi
done
echo "ro-run: all mounts read-only except $TMPDIR, /proc, /sys, /dev/pts, /dev/mqueue and device nodes; no network"
echo "ro-run: writable mounts: $(awk '{o[$5]=$6} END {for (m in o) if (o[m] ~ /(^|,)rw(,|$)/) print m}' /proc/self/mountinfo | sort | tr '\n' ' ')"
exec "$@"

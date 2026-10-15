#!/usr/bin/env bash
# see README.md
set -euo pipefail

IFACE=""
SSID=""
PSK="88888888"
DONGLE="192.168.1.101"
DRY_RUN=0
ASSUME_YES=0
WORKDIR="${OTTO_WORKDIR:-$PWD/otto-$(date +%Y%m%d-%H%M%S)}"

usage() {
    cat <<EOF
Usage: sudo $0 -i <wifi-iface> [-s <ssid>] [-k <psk>] [--dry-run] [--yes]

  -i IFACE    Wi-Fi interface to join the dongle with (must NOT be your internet uplink)
  -s SSID     dongle SSID (default: auto-detect a single OTTO-* network)
  -k PSK      Wi-Fi password (default: 88888888)
  --dry-run   inspect, check for an update and download it, but do not flash
  --yes       flash without the confirmation prompt
EOF
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -i) IFACE="$2"; shift 2 ;;
        -s) SSID="$2"; shift 2 ;;
        -k) PSK="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --yes) ASSUME_YES=1; shift ;;
        -h|--help) usage 0 ;;
        *) echo "unknown argument: $1" >&2; usage 2 ;;
    esac
done

log() { echo "[$(date +%T)] $*"; }
die() { echo "[$(date +%T)] ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root (sudo): wpa_supplicant and ip need it"
[[ -n "$IFACE" ]] || usage 2
for c in iw wpa_supplicant wpa_passphrase ip curl python3 md5sum sha256sum; do
    command -v "$c" >/dev/null || die "missing command: $c"
done
[[ -d /sys/class/net/$IFACE/wireless ]] || die "$IFACE is not a Wi-Fi interface"

if ip route show default | grep -qw "dev $IFACE"; then
    die "$IFACE carries a default route — it is your uplink. Use another interface, or get internet via Ethernet / USB tethering first"
fi
if ip -4 addr show dev "$IFACE" | grep -q inet; then
    die "$IFACE already has an IPv4 address; disconnect it first"
fi
if command -v nmcli >/dev/null && nmcli -t -f DEVICE,STATE dev 2>/dev/null | grep -q "^$IFACE:" \
   && ! nmcli -t -f DEVICE,STATE dev | grep -q "^$IFACE:unmanaged"; then
    die "NetworkManager manages $IFACE; run 'nmcli device set $IFACE managed no' first (and 'managed yes' afterwards)"
fi
if ip route | grep -v "dev $IFACE" | grep -q "^192\.168\.1\.0/24"; then
    die "192.168.1.0/24 is already routed on another interface (your LAN?) — it collides with the dongle subnet"
fi

mkdir -p "$WORKDIR"
chmod 700 "$WORKDIR"
WPA_PID="$WORKDIR/wpa.pid"
ADDED_ADDR=""

cleanup() {
    [[ -f "$WPA_PID" ]] && kill "$(cat "$WPA_PID")" 2>/dev/null || true
    rm -f "$WPA_PID" "$WORKDIR/wpa.conf"
    [[ -n "$ADDED_ADDR" ]] && ip addr del "$ADDED_ADDR" dev "$IFACE" 2>/dev/null || true
    log "disconnected $IFACE from the dongle; files kept in $WORKDIR"
}
trap cleanup EXIT

ip link set "$IFACE" up
if [[ -z "$SSID" ]]; then
    mapfile -t found < <(iw dev "$IFACE" scan 2>/dev/null | sed -n 's/^\s*SSID: \(OTTO-.*\)$/\1/p' | sort -u)
    [[ ${#found[@]} -eq 1 ]] || die "found ${#found[@]} OTTO-* networks (${found[*]:-none}); pass -s <ssid>"
    SSID="${found[0]}"
fi
log "joining $SSID on $IFACE"

( umask 077; wpa_passphrase "$SSID" "$PSK" | grep -v '#psk' > "$WORKDIR/wpa.conf" )
wpa_supplicant -B -i "$IFACE" -c "$WORKDIR/wpa.conf" -P "$WPA_PID" -f "$WORKDIR/wpa.log"
for _ in $(seq 1 20); do
    iw dev "$IFACE" link | grep -q '^Connected' && break
    sleep 1
done
iw dev "$IFACE" link | grep -q '^Connected' || die "could not associate with $SSID (wrong password? see $WORKDIR/wpa.log)"
log "associated: $(iw dev "$IFACE" link | sed -n 's/^Connected to \([0-9a-f:]*\).*/\1/p') $(iw dev "$IFACE" link | sed -n 's/^\s*freq: \(.*\)/\1 MHz/p')"

# Read the DHCP offer without letting a client install routes or DNS.
LEASE=""
if command -v busybox >/dev/null && busybox --list | grep -qx udhcpc; then
    LEASE=$(busybox udhcpc -i "$IFACE" -n -q -t 5 -s /bin/true 2>&1 | sed -n 's/.*lease of \([0-9.]*\) obtained.*/\1/p')
elif command -v dhcpcd >/dev/null; then
    LEASE=$(dhcpcd -T -4 -t 15 "$IFACE" 2>/dev/null | sed -n "s/^new_ip_address='\{0,1\}\([0-9.]*\).*/\1/p")
fi
[[ -n "$LEASE" ]] || die "no DHCP lease (need busybox udhcpc or dhcpcd)"
ADDED_ADDR="$LEASE/24"
ip addr add "$ADDED_ADDR" dev "$IFACE"
log "address $LEASE on $IFACE (no gateway, no DNS)"

host_json() { curl -sS -m 5 "http://$DONGLE/cgi-bin/index.cgi?id=host"; }
jget() { python3 -c "import sys,json; j=json.load(sys.stdin); print($1)"; }

host_json > "$WORKDIR/host-before.json" || die "dongle web UI not reachable at http://$DONGLE"
CUR=$(jget 'j["sys"]["appver"]' < "$WORKDIR/host-before.json")
STATE=$(jget 'j.get("update")' < "$WORKDIR/host-before.json")
log "dongle $(jget 'j.get("name")' < "$WORKDIR/host-before.json"), firmware $CUR, update state $STATE"
[[ "$STATE" == "0" || "$STATE" == "None" ]] || die "dongle reports update state $STATE (an update is pending or running) — power-cycle it and retry"

IFS=. read -r _ DIR REGION <<< "$CUR"
if [[ "$REGION" == "2" ]]; then BASE="https://cpbox-abroad.oss-us-west-1.aliyuncs.com"; else BASE="https://cpbox.oss-cn-shenzhen.aliyuncs.com"; fi
MANIFEST="$BASE/$DIR/version.json"
curl -sS -m 20 -f "$MANIFEST" -o "$WORKDIR/version.json" || die "cannot fetch $MANIFEST (is this machine online through another interface?)"
NEW=$(jget 'j["appver"]' < "$WORKDIR/version.json")
URL=$(jget 'j["url"]' < "$WORKDIR/version.json")
log "vendor stable release: $NEW ($MANIFEST)"
log "release notes: $(jget 'j.get("msg","")' < "$WORKDIR/version.json")"

if [[ ! "$NEW" > "$CUR" ]]; then
    log "already up to date"
    exit 0
fi

IMG="$WORKDIR/update.img"
curl -sS -m 600 -f -D "$WORKDIR/img-headers.txt" "$URL" -o "$IMG" || die "download failed: $URL"
WANT_MD5=$(sed -n 's/^[Cc]ontent-[Mm][Dd]5: *\([^[:space:]]*\).*/\1/p' "$WORKDIR/img-headers.txt" | python3 -c "import sys,base64; s=sys.stdin.read().strip(); print(base64.b64decode(s).hex() if s else '')")
GOT_MD5=$(md5sum "$IMG" | cut -d' ' -f1)
if [[ -n "$WANT_MD5" ]]; then
    [[ "$WANT_MD5" == "$GOT_MD5" ]] || die "MD5 mismatch: server $WANT_MD5, file $GOT_MD5"
    log "image $(stat -c %s "$IMG") bytes, MD5 verified against server Content-MD5"
else
    log "image $(stat -c %s "$IMG") bytes, server sent no Content-MD5 — integrity NOT verified"
fi
log "sha256 $(sha256sum "$IMG" | cut -d' ' -f1)"

if [[ $DRY_RUN -eq 1 ]]; then
    log "dry run: would flash $CUR -> $NEW; stopping here"
    exit 0
fi
if [[ $ASSUME_YES -ne 1 ]]; then
    echo
    echo "About to flash $CUR -> $NEW. There is no rollback: the old firmware is not published."
    echo "Keep the dongle powered until this script says it is done AND through the power cycle it asks for."
    read -r -p "Type 'flash' to continue: " answer
    [[ "$answer" == "flash" ]] || die "aborted"
fi

log "uploading"
RESP=$(curl -sS -m 300 -F "file=@$IMG;filename=blob;type=application/octet-stream" "http://$DONGLE/cgi-bin/index.cgi?id=upload")
echo "$RESP" > "$WORKDIR/upload-resp.txt"
[[ "$(echo "$RESP" | jget 'j.get("code")')" == "0" ]] || die "upload rejected: $RESP"
log "upload accepted, dongle is staging the update"

last=""
for _ in $(seq 1 150); do
    st=$(host_json 2>/dev/null | jget 'j.get("update")' 2>/dev/null || echo unreachable)
    [[ "$st" != "$last" ]] && log "update state: $st" && last="$st"
    [[ "$st" == "3" ]] && break
    [[ "$st" =~ ^[0-9]+$ && "$st" -gt 3 ]] && die "dongle reports update failure (state $st)"
    sleep 4
done
[[ "$last" == "3" ]] || die "no completion after 10 minutes (last state: $last)"

echo
log "update staged. Now UNPLUG the dongle, wait 10 s, plug it back in, and do not unplug it again until this script confirms the new version."
for _ in $(seq 1 180); do
    ver=$(host_json 2>/dev/null | jget 'j["sys"]["appver"]' 2>/dev/null || true)
    if [[ "$ver" == "$NEW" ]]; then
        log "dongle now runs $NEW — done"
        exit 0
    fi
    sleep 5
done
die "new version not seen after 15 minutes; leave it powered and check http://$DONGLE in a browser"

#!/bin/sh
# =====================================================================
#  lib.sh - shared helper functions
#  This file is loaded by the other scripts. Do not run it directly.
# =====================================================================

# Where everything lives on the router
BRIDGE_DIR="/jffs/scripts/wifi-bridge"
CONF_FILE="$BRIDGE_DIR/bridge.conf"
BACKUP_DIR="$BRIDGE_DIR/backup"
LOG_TAG="wifi-bridge"

# ---------------------------------------------------------------------
# Printing
# ---------------------------------------------------------------------
say()  { echo "$*"; }
ok()   { echo "  [ OK ]  $*"; }
warn() { echo "  [WARN]  $*"; }
fail() { echo "  [FAIL]  $*"; }
step() { echo ""; echo "==> $*"; }

# Write to the router system log (see it with: logread | grep wifi-bridge)
log_msg() {
    [ "$ENABLE_LOGGING" = "yes" ] && logger -t "$LOG_TAG" "$1"
    return 0
}

die() {
    echo ""
    echo "ERROR: $1"
    echo ""
    exit 1
}

# ---------------------------------------------------------------------
# Load and check the config file
# ---------------------------------------------------------------------
load_config() {
    _cf="${1:-$CONF_FILE}"
    [ -f "$_cf" ] || die "Config file not found: $_cf
Copy src/bridge.conf.example to bridge.conf and edit it first."

    # shellcheck disable=SC1090
    . "$_cf"

    # Set safe defaults for anything the user left out
    [ -z "$RADIO" ]             && RADIO="wl0"
    [ -z "$BRIDGE_NAME" ]       && BRIDGE_NAME="br10"
    [ -z "$LINK_PREFIX" ]       && LINK_PREFIX="30"
    [ -z "$BANDWIDTH" ]         && BANDWIDTH="20"
    [ -z "$ISOLATE_AP_BSS" ]    && ISOLATE_AP_BSS="yes"
    [ -z "$ENABLE_MAC_FILTER" ] && ENABLE_MAC_FILTER="yes"
    [ -z "$HIDE_SSID" ]         && HIDE_SSID="yes"
    [ -z "$DISABLE_AIMESH" ]    && DISABLE_AIMESH="yes"
    [ -z "$ENABLE_LOGGING" ]    && ENABLE_LOGGING="yes"
    [ -z "$CHECK_INTERVAL_MINUTES" ] && CHECK_INTERVAL_MINUTES="1"
}

# Check that the values make sense. Called by install.sh.
validate_config() {
    _err=""

    case "$RADIO" in
        wl0|wl1|wl2) : ;;
        *) _err="$_err\n  RADIO must be wl0, wl1 or wl2 (you wrote: '$RADIO')" ;;
    esac

    is_ipv4 "$LOCAL_LINK_IP" || _err="$_err\n  LOCAL_LINK_IP is not a valid IP address: '$LOCAL_LINK_IP'"
    is_ipv4 "$PEER_LINK_IP"  || _err="$_err\n  PEER_LINK_IP is not a valid IP address: '$PEER_LINK_IP'"

    [ "$LOCAL_LINK_IP" = "$PEER_LINK_IP" ] && \
        _err="$_err\n  LOCAL_LINK_IP and PEER_LINK_IP must be different"

    is_mac "$PEER_RADIO_MAC" || _err="$_err\n  PEER_RADIO_MAC is not a valid MAC address: '$PEER_RADIO_MAC'
    It must look like AA:BB:CC:DD:EE:FF
    Get it from the OTHER router with: nvram get ${RADIO}_hwaddr"

    is_subnet "$PEER_LAN_SUBNET" || _err="$_err\n  PEER_LAN_SUBNET must look like 192.168.10.0/24 (you wrote: '$PEER_LAN_SUBNET')"

    case "$BRIDGE_NAME" in
        br0) _err="$_err\n  BRIDGE_NAME must NOT be br0. That is your home network." ;;
        br1|br2) _err="$_err\n  BRIDGE_NAME should not be $BRIDGE_NAME. ASUS uses it for guest networks." ;;
        br*) : ;;
        *) _err="$_err\n  BRIDGE_NAME should start with 'br' (you wrote: '$BRIDGE_NAME')" ;;
    esac

    case "$BANDWIDTH" in
        20|40|80) : ;;
        *) _err="$_err\n  BANDWIDTH must be 20, 40 or 80 (you wrote: '$BANDWIDTH')" ;;
    esac

    [ -z "$CHANNEL" ] && _err="$_err\n  CHANNEL is empty. Pick a fixed channel, for example 6."

    # A channel from the wrong band is the worst mistake to make here.
    # Everything installs fine and the link just never comes up, so it
    # looks like broken hardware. Catch it now instead.
    case "$CHANNEL" in
        ''|*[!0-9]*) [ -n "$CHANNEL" ] && _err="$_err\n  CHANNEL must be a plain number (you wrote: '$CHANNEL')" ;;
        *)
            if [ "$RADIO" = "wl0" ] && [ "$CHANNEL" -gt 14 ]; then
                _err="$_err\n  CHANNEL $CHANNEL is a 5 GHz channel, but RADIO is wl0 (2.4 GHz).
    Use 1-13, or set RADIO=\"wl1\"."
            elif [ "$RADIO" != "wl0" ] && [ "$CHANNEL" -lt 36 ]; then
                _err="$_err\n  CHANNEL $CHANNEL is a 2.4 GHz channel, but RADIO is $RADIO (5 GHz).
    Use 36/40/44/48 (no DFS), or set RADIO=\"wl0\"."
            fi
            # 40 and 80 MHz need the channel to be the start of its block.
            if [ "$RADIO" != "wl0" ] && [ "$BANDWIDTH" = "80" ]; then
                case "$CHANNEL" in
                    36|52|100|116|132|149) : ;;
                    *) _err="$_err\n  With BANDWIDTH=80 the channel must start an 80 MHz block:
    36, 52, 100, 116, 132 or 149 (you wrote: '$CHANNEL')." ;;
                esac
            fi
            ;;
    esac

    # Warn if the link IP overlaps the local LAN
    _lan=$(nvram get lan_ipaddr)
    if [ -n "$_lan" ]; then
        _lan3=$(echo "$_lan" | cut -d. -f1-3)
        _lnk3=$(echo "$LOCAL_LINK_IP" | cut -d. -f1-3)
        [ "$_lan3" = "$_lnk3" ] && \
            _err="$_err\n  LOCAL_LINK_IP ($LOCAL_LINK_IP) is inside your home network ($_lan).
    Pick a range you do not use, for example 192.168.255.1"
    fi

    if [ -n "$_err" ]; then
        echo ""
        echo "Your config file has problems:"
        printf "%b\n" "$_err"
        echo ""
        return 1
    fi
    return 0
}

is_ipv4() {
    echo "$1" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || return 1
    for _o in $(echo "$1" | tr '.' ' '); do
        [ "$_o" -gt 255 ] 2>/dev/null && return 1
    done
    return 0
}

is_mac() {
    echo "$1" | grep -qiE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'
}

is_subnet() {
    echo "$1" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'
}

# ---------------------------------------------------------------------
# Hardware discovery - this is what makes the scripts model independent
# ---------------------------------------------------------------------

# Real name of the radio interface, for example eth6 or eth1.
# We never hard-code it. We ask the router.
get_radio_if() {
    _if=$(nvram get "${RADIO}_ifname")
    [ -z "$_if" ] && _if=$(nvram get "${RADIO}_vifnames" | awk '{print $1}')
    echo "$_if"
}

# Radio number: wl0 -> 0, wl1 -> 1
get_radio_index() {
    echo "$RADIO" | sed 's/^wl//'
}

# Find the WDS link interface.
# The name is not the same on every firmware. It can be wds0.1,
# wds0.0.1 or similar. So we search for it instead of guessing.
get_wds_if() {
    _idx=$(get_radio_index)
    _found=$(ls /sys/class/net/ 2>/dev/null | grep "^wds${_idx}\." | head -1)
    [ -z "$_found" ] && _found=$(ls /sys/class/net/ 2>/dev/null | grep "^wds" | head -1)
    echo "$_found"
}

# Is the radio MAC of this router readable?
get_own_radio_mac() {
    nvram get "${RADIO}_hwaddr"
}

# ---------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------
if_exists()      { [ -d "/sys/class/net/$1" ]; }
in_bridge()      { [ -d "/sys/class/net/$1/brif/$2" ]; }
need_root()      { [ "$(id -u)" = "0" ] || die "Please run this as root."; }

# Check that this really is an ASUS router with Merlin firmware
# NOTE: we use "which", not "command -v".
# The router shell (BusyBox ash via Dropbear) has no "command" builtin,
# so "command -v" fails with "command: not found" on every router.
check_firmware() {
    which nvram >/dev/null 2>&1 || [ -x /usr/sbin/nvram ] || [ -x /bin/nvram ] || \
        die "This does not look like an ASUS router (no 'nvram' command)."
    which wl >/dev/null 2>&1 || \
        die "The 'wl' command is missing. This script needs ASUS Merlin firmware
on a Broadcom-based router."
    which brctl >/dev/null 2>&1 || \
        die "The 'brctl' command is missing. This firmware is not supported."
}

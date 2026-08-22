#!/bin/sh
# =====================================================================
#  install.sh - runs ON THE ROUTER
#  You do not start this yourself. deploy.sh copies it here and runs it.
# =====================================================================

BRIDGE_DIR="/jffs/scripts/wifi-bridge"
. "$BRIDGE_DIR/lib.sh" || { echo "ERROR: lib.sh missing"; exit 1; }

check_firmware
load_config
validate_config || exit 1

RADIO_IF=$(get_radio_if)
[ -n "$RADIO_IF" ] || die "Cannot find the interface for radio '$RADIO'."

say "  Router: $(nvram get productid), radio $RADIO is $RADIO_IF"

# ---------------------------------------------------------------------
# 1. Save the old settings so uninstall can put them back
# ---------------------------------------------------------------------
mkdir -p "$BACKUP_DIR"
if [ ! -f "$BACKUP_DIR/restore.sh" ]; then
    # The values go into a plain text file, one "key=value" per line.
    # restore.sh reads them back with 'read -r', so the shell never
    # looks inside a value.
    #
    # Why: a Wi-Fi key or a network name can hold " ' $ ` or \. Writing
    # "nvram set key='value'" lines means escaping all of that back into
    # shell code, and one case always slips through. The apostrophe did.
    # This file is your way back, so it must survive any value.
    for v in $(nvram show 2>/dev/null | grep -oE "^(${RADIO}[._][a-zA-Z0-9_.]*|smart_connect_x|cfg_master|jffs2_scripts)=" | tr -d '=' | sort -u); do
        printf '%s=%s\n' "$v" "$(nvram get "$v")"
    done > "$BACKUP_DIR/nvram-values.txt"

    cat > "$BACKUP_DIR/restore.sh" << 'RESTORE'
#!/bin/sh
# Puts back the Wi-Fi settings that were in place before wifi-bridge was
# installed. The values live in nvram-values.txt next to this file.
_dir=$(dirname "$0")
[ -f "$_dir/nvram-values.txt" ] || { echo "ERROR: nvram-values.txt is missing"; exit 1; }
_n=0
while IFS='=' read -r _k _v; do
    [ -n "$_k" ] || continue
    nvram set "$_k=$_v"
    _n=$((_n+1))
done < "$_dir/nvram-values.txt"
nvram commit
echo "  restored $_n settings"
RESTORE
    chmod 755 "$BACKUP_DIR/restore.sh"
    echo "Saved by wifi-bridge install on $(date), radio $RADIO" > "$BACKUP_DIR/README.txt"
    nvram show 2>/dev/null > "$BACKUP_DIR/nvram-before.txt"
    say "  Saved old settings ($(wc -l < "$BACKUP_DIR/nvram-values.txt") values) to $BACKUP_DIR/"
else
    say "  Backup already exists, keeping the original one"
fi

# ---------------------------------------------------------------------
# 2. Turn on custom scripts (without this, nothing would ever run)
# ---------------------------------------------------------------------
if [ "$(nvram get jffs2_scripts)" != "1" ]; then
    nvram set jffs2_scripts=1
    say "  Turned ON custom scripts (they were off)"
fi

# ---------------------------------------------------------------------
# 3. Radio settings
# ---------------------------------------------------------------------
# IMPORTANT: mode_x must be 2 (AP + WDS), NOT 1 (WDS only).
# With mode 1 the radio never starts sending, so nothing can connect.
# We tested this. See docs/FINDINGS.md.
nvram set "${RADIO}_mode_x=2"
nvram set "${RADIO}_wdsapply_x=1"
nvram set "${RADIO}_wdslist=$PEER_RADIO_MAC"
nvram set "${RADIO}_lazywds=0"

# The radio must have no password. WPA2 breaks the link every time.
nvram set "${RADIO}_auth_mode_x=open"
nvram set "${RADIO}_wep_x=0"

# Fixed channel on both sides, or the two radios never meet.
#
# The chanspec must also say how wide the channel is, not only its
# number:
#   20 MHz -> "36"      40 MHz -> "36/40"      80 MHz -> "36/80"
# A plain number with a wide setting leaves the radio confused. It then
# picks a width by itself, and the two sides can pick different ones.
# That looks exactly like "the link never comes up".
# On AX firmware the driver reads bw_cap. Setting bw alone is not
# enough. bw_160 must be off, or an 80 MHz block can grow into the
# block next to it.
case "$BANDWIDTH" in
    20) _chanspec="$CHANNEL"    ; _bw=1 ; _bwcap=1 ; _nctrlsb="none" ;;
    40) _chanspec="$CHANNEL/40" ; _bw=2 ; _bwcap=3 ; _nctrlsb="" ;;
    80) _chanspec="$CHANNEL/80" ; _bw=3 ; _bwcap=7 ; _nctrlsb="" ;;
esac
nvram set "${RADIO}_channel=$CHANNEL"
nvram set "${RADIO}_chanspec=$_chanspec"
nvram set "${RADIO}_bw=$_bw"
nvram set "${RADIO}_bw_cap=$_bwcap"
nvram set "${RADIO}_nctrlsb=$_nctrlsb"
nvram set "${RADIO}_bw_160=0"

[ "$HIDE_SSID" = "yes" ] && nvram set "${RADIO}_closed=1"

# One network name per radio, so the channel stays where we put it.
nvram set smart_connect_x=0

say "  Radio set to channel $CHANNEL, $BANDWIDTH MHz, open, WDS peer $PEER_RADIO_MAC"

# ---------------------------------------------------------------------
# 4. Turn off AiMesh
# ---------------------------------------------------------------------
# AiMesh owns the channel. If it stays on, the channel keeps moving
# and the link never comes up.
if [ "$DISABLE_AIMESH" = "yes" ]; then
    nvram set cfg_master=0
    for i in 0 1 2; do
        nvram set "wl${i}.4_bss_enabled=0" 2>/dev/null
    done
    say "  Turned off AiMesh"
fi

# ---------------------------------------------------------------------
# 5. Only let the other router use this radio
# ---------------------------------------------------------------------
if [ "$ENABLE_MAC_FILTER" = "yes" ]; then
    nvram set "${RADIO}_macmode=allow"
    nvram set "${RADIO}_maclist_x=<$PEER_RADIO_MAC"
    say "  MAC filter on: only $PEER_RADIO_MAC may connect"
fi

nvram commit

# ---------------------------------------------------------------------
# 6. Hook into the firmware start-up scripts
# ---------------------------------------------------------------------
# We never overwrite a hook file that already exists. We only add one
# line to it, marked with "# wifi-bridge" so uninstall can find it.
add_hook() {
    _name="$1"
    _file="/jffs/scripts/$_name"
    _line="$BRIDGE_DIR/hook.sh $_name \"\$@\"  # wifi-bridge"

    if [ ! -f "$_file" ]; then
        printf '#!/bin/sh\n%s\n' "$_line" > "$_file"
        chmod 755 "$_file"
        say "  Created /jffs/scripts/$_name"
    elif grep -q "# wifi-bridge" "$_file"; then
        say "  /jffs/scripts/$_name already has our line"
    else
        printf '%s\n' "$_line" >> "$_file"
        chmod 755 "$_file"
        say "  Added our line to your existing /jffs/scripts/$_name"
    fi
}

cat > "$BRIDGE_DIR/hook.sh" << 'HOOK'
#!/bin/sh
# Called by the firmware start-up scripts. $1 is which hook called us.
BRIDGE_DIR="/jffs/scripts/wifi-bridge"
. "$BRIDGE_DIR/lib.sh" 2>/dev/null || exit 0
load_config

case "$1" in
    services-start)
        # Repeat check, so the link is repaired after every Wi-Fi restart
        cru a wifibridge "*/$CHECK_INTERVAL_MINUTES * * * * $BRIDGE_DIR/wifi-bridge.sh"
        ( sleep 30 && "$BRIDGE_DIR/wifi-bridge.sh" ) &
        ;;
    firewall-start)
        # Let traffic pass between the home network and the link bridge.
        # No NAT here on purpose: the routers only translate on the
        # internet port, so addresses stay unchanged across the bridge.
        iptables -C INPUT -i "$BRIDGE_NAME" -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -i "$BRIDGE_NAME" -j ACCEPT
        iptables -C FORWARD -i "$BRIDGE_NAME" -o br0 -j ACCEPT 2>/dev/null || \
            iptables -I FORWARD -i "$BRIDGE_NAME" -o br0 -j ACCEPT
        iptables -C FORWARD -i br0 -o "$BRIDGE_NAME" -j ACCEPT 2>/dev/null || \
            iptables -I FORWARD -i br0 -o "$BRIDGE_NAME" -j ACCEPT
        ;;
    service-event-end)
        # $2 is the action, $3 is the service name
        case "$3" in
            wireless|net|net_and_phy|restart_wireless)
                ( sleep 8 && "$BRIDGE_DIR/wifi-bridge.sh" ) &
                ;;
        esac
        ;;
esac
exit 0
HOOK
chmod 755 "$BRIDGE_DIR/hook.sh"

add_hook services-start
add_hook firewall-start
add_hook service-event-end

# ---------------------------------------------------------------------
# 7. Start everything now, without waiting for a reboot
# ---------------------------------------------------------------------
cru a wifibridge "*/$CHECK_INTERVAL_MINUTES * * * * $BRIDGE_DIR/wifi-bridge.sh"
sh "$BRIDGE_DIR/hook.sh" firewall-start
sh "$BRIDGE_DIR/wifi-bridge.sh"

say "  Restarting Wi-Fi to apply the new radio settings..."
nohup sh -c 'service restart_wireless >/dev/null 2>&1' >/dev/null 2>&1 &

say ""
say "  Install finished on this router."
exit 0

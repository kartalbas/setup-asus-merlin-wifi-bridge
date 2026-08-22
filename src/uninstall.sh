#!/bin/sh
# =====================================================================
#  uninstall.sh - remove the bridge and put the old settings back
#  Normally started from your computer:  ./deploy.sh uninstall
# =====================================================================

BRIDGE_DIR="/jffs/scripts/wifi-bridge"
. "$BRIDGE_DIR/lib.sh" 2>/dev/null || { echo "ERROR: lib.sh missing"; exit 1; }
load_config 2>/dev/null

say "  Stopping the repair job..."
cru d wifibridge 2>/dev/null

say "  Removing our lines from the firmware hooks..."
for h in services-start firewall-start service-event-end; do
    f="/jffs/scripts/$h"
    [ -f "$f" ] || continue
    grep -v "# wifi-bridge" "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"
    chmod 755 "$f"
    # If only the shebang is left, the file is ours and can go
    if [ "$(grep -cvE '^#!|^[[:space:]]*$' "$f")" = "0" ]; then
        rm -f "$f"
        say "    deleted empty $f"
    else
        say "    cleaned $f (your other lines were kept)"
    fi
done

say "  Taking down the link bridge..."
if [ -n "${BRIDGE_NAME:-}" ] && if_exists "$BRIDGE_NAME"; then
    ip link set "$BRIDGE_NAME" down 2>/dev/null
    brctl delbr "$BRIDGE_NAME" 2>/dev/null
fi

say "  Restoring the old Wi-Fi settings..."
if [ -f "$BACKUP_DIR/restore.sh" ]; then
    sh "$BACKUP_DIR/restore.sh"
    say "    old settings restored from backup"
else
    warn "no backup found - setting safe defaults instead"
    nvram set "${RADIO}_mode_x=0"
    nvram set "${RADIO}_wdsapply_x=0"
    nvram set "${RADIO}_wdslist="
    nvram set "${RADIO}_macmode=disabled"
    nvram commit
    warn "Your Wi-Fi password settings may need to be set again in the web page."
fi

say "  Putting the radio back into your home network..."
RADIO_IF=$(get_radio_if 2>/dev/null)
[ -n "$RADIO_IF" ] && ! in_bridge br0 "$RADIO_IF" && brctl addif br0 "$RADIO_IF" 2>/dev/null

say "  Removing files..."
rm -f "$BRIDGE_DIR"/*.sh "$BRIDGE_DIR/bridge.conf"

say ""
say "  Done. Please restart this router to finish."
say "  The backup folder was kept: $BACKUP_DIR"
exit 0

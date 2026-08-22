#!/bin/sh
# =====================================================================
#  wifi-bridge.sh - builds and repairs the radio link
#
#  This runs every minute from cron, and also after every Wi-Fi
#  restart. It is safe to run as often as you like: if everything is
#  already correct, it changes nothing and exits.
#
#  What it does:
#    1. Finds the WDS link interface (name differs per firmware).
#    2. Creates the link bridge (for example br10).
#    3. Moves the WDS interface out of br0 and into the link bridge.
#       The router keeps putting it back into br0 after every Wi-Fi
#       restart. That is why this script must keep running.
#    4. Gives the link bridge its IP address.
#    5. Adds the route to the network behind the other router.
#    6. Keeps the open radio out of br0 (security).
# =====================================================================

BRIDGE_DIR="/jffs/scripts/wifi-bridge"
. "$BRIDGE_DIR/lib.sh" 2>/dev/null || {
    echo "ERROR: cannot load $BRIDGE_DIR/lib.sh"
    exit 1
}

load_config

# ---------------------------------------------------------------------
# Step 1: find the WDS interface
# ---------------------------------------------------------------------
# It only exists after the radio link has come up. If it is missing,
# there is nothing to do yet - we exit quietly and try again later.
WDS_IF=$(get_wds_if)
if [ -z "$WDS_IF" ]; then
    exit 0
fi

RADIO_IF=$(get_radio_if)

# ---------------------------------------------------------------------
# Step 2: make sure the link bridge exists and is up
# ---------------------------------------------------------------------
if ! if_exists "$BRIDGE_NAME"; then
    brctl addbr "$BRIDGE_NAME" 2>/dev/null && \
        log_msg "created bridge $BRIDGE_NAME"
fi
ip link set "$BRIDGE_NAME" up 2>/dev/null

# ---------------------------------------------------------------------
# Step 3: move the WDS interface into the link bridge
# ---------------------------------------------------------------------
# The firmware drops it into br0 automatically. If we left it there,
# both homes would become one single network with two DHCP servers,
# and devices would get addresses from the wrong router.
if in_bridge br0 "$WDS_IF"; then
    brctl delif br0 "$WDS_IF" 2>/dev/null && \
        log_msg "removed $WDS_IF from br0"
fi

if ! in_bridge "$BRIDGE_NAME" "$WDS_IF"; then
    brctl addif "$BRIDGE_NAME" "$WDS_IF" 2>/dev/null && \
        log_msg "added $WDS_IF to $BRIDGE_NAME"
fi
ip link set "$WDS_IF" up 2>/dev/null

# ---------------------------------------------------------------------
# Step 4: set the link IP address
# ---------------------------------------------------------------------
if ! ip -4 addr show dev "$BRIDGE_NAME" 2>/dev/null | grep -q "inet $LOCAL_LINK_IP/"; then
    ip addr add "$LOCAL_LINK_IP/$LINK_PREFIX" dev "$BRIDGE_NAME" 2>/dev/null && \
        log_msg "set IP $LOCAL_LINK_IP/$LINK_PREFIX on $BRIDGE_NAME"
fi

# ---------------------------------------------------------------------
# Step 5: route to the network behind the other router
# ---------------------------------------------------------------------
# Leave PEER_LAN_SUBNET empty in the config if some other tool
# (for example a VPN) should handle the routing instead.
if [ -n "$PEER_LAN_SUBNET" ]; then
    ip route replace "$PEER_LAN_SUBNET" via "$PEER_LINK_IP" dev "$BRIDGE_NAME" 2>/dev/null
fi

# ---------------------------------------------------------------------
# Step 6: keep the open radio out of your home network
# ---------------------------------------------------------------------
# The bridge radio has no password (the hardware forces this).
# The radio interface itself must NOT sit in br0, or anyone who
# connects to it would be inside your home network.
# The bridge traffic does not need it: that runs over $WDS_IF.
if [ "$ISOLATE_AP_BSS" = "yes" ] && [ -n "$RADIO_IF" ]; then
    if in_bridge br0 "$RADIO_IF"; then
        brctl delif br0 "$RADIO_IF" 2>/dev/null && \
            log_msg "security: removed open radio $RADIO_IF from br0"
    fi
fi

exit 0

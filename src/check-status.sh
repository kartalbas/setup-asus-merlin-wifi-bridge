#!/bin/sh
# =====================================================================
#  check-status.sh - is the bridge working?
#  Run it on the router, or from your computer: ./deploy.sh status
# =====================================================================

BRIDGE_DIR="/jffs/scripts/wifi-bridge"
. "$BRIDGE_DIR/lib.sh" || { echo "ERROR: lib.sh missing"; exit 1; }
load_config

RADIO_IF=$(get_radio_if)
WDS_IF=$(get_wds_if)
PROBLEMS=0
note() { PROBLEMS=$((PROBLEMS+1)); }

echo ""
echo "  Router:  $(nvram get productid)   LAN: $(nvram get lan_ipaddr)"
echo "  Radio:   $RADIO ($RADIO_IF)"
echo ""

# 1 - radio is sending
echo "1) Radio sending?"
BSS=$(wl -i "$RADIO_IF" bss 2>/dev/null)
if [ "$BSS" = "up" ]; then
    ok "radio is up and sending"
else
    fail "radio is DOWN (bss=$BSS) - nothing can connect"
    note
    echo "        Fix: check that mode is 2 (AP+WDS): nvram get ${RADIO}_mode_x"
fi

# 2 - channel
echo "2) Channel"
NOW=$(wl -i "$RADIO_IF" status 2>/dev/null | grep -i "Primary channel" | awk '{print $3}')
if [ "$NOW" = "$CHANNEL" ]; then
    ok "on channel $NOW (as configured)"
else
    fail "on channel $NOW, but config says $CHANNEL"
    note
    echo "        Both routers MUST use the same channel."
fi

# 3 - link interface
echo "3) Radio link"
if [ -n "$WDS_IF" ]; then
    ok "link interface $WDS_IF exists"
else
    fail "no link interface yet - the two radios have not connected"
    note
    echo "        Check the other router: same channel? correct MAC?"
fi

# 4 - the other radio is really connected
echo "4) Other router connected?"
STATE=$(wl -i "$RADIO_IF" sta_info "$PEER_RADIO_MAC" 2>/dev/null | grep -E "^[[:space:]]*state:" | head -1)
RSSI=$(wl -i "$RADIO_IF" sta_info "$PEER_RADIO_MAC" 2>/dev/null | grep "smoothed rssi" | awk '{print $3}')
case "$STATE" in
    *AUTHORIZED*)
        ok "connected (signal ${RSSI:-?} dBm)"
        if [ -n "$RSSI" ] && [ "$RSSI" -lt -75 ] 2>/dev/null; then
            echo "        Signal is weak. Move the routers closer or try 2.4 GHz."
        fi
        ;;
    *)
        # Only one end of a WDS link reports the peer state. The other
        # end shows an empty "state:" while traffic flows fine. We saw
        # this on both a 2.4 GHz and a 5 GHz link, on the same two
        # routers. So an empty state does not mean the link is broken.
        # If we can read the signal and the link interface is there, the
        # link is up. Check 7 below proves that traffic really passes.
        if [ -n "$WDS_IF" ] && [ -n "$RSSI" ]; then
            ok "connected (signal $RSSI dBm - this end shows no state, that is normal)"
            if [ "$RSSI" -lt -75 ] 2>/dev/null; then
                echo "        Signal is weak. Move the routers closer or try 2.4 GHz."
            fi
        elif [ -n "$WDS_IF" ]; then
            warn "link interface is there, but this end shows no state and no signal"
            echo "        Check 7 below decides whether traffic really passes."
        else
            fail "not connected"; note
        fi
        ;;
esac

# 5 - bridge
echo "5) Link bridge"
if [ -n "$WDS_IF" ] && in_bridge "$BRIDGE_NAME" "$WDS_IF"; then
    ok "$WDS_IF is in $BRIDGE_NAME"
elif [ -n "$WDS_IF" ] && in_bridge br0 "$WDS_IF"; then
    fail "$WDS_IF is in br0 - DANGER: both homes are one network now"
    note
    echo "        Fix: sh $BRIDGE_DIR/wifi-bridge.sh"
else
    fail "$WDS_IF is in no bridge"; note
fi

# 6 - address and route
echo "6) Address and route"
if ip -4 addr show dev "$BRIDGE_NAME" 2>/dev/null | grep -q "inet $LOCAL_LINK_IP/"; then
    ok "$BRIDGE_NAME has $LOCAL_LINK_IP"
else
    fail "$BRIDGE_NAME is missing $LOCAL_LINK_IP"; note
fi
if [ -z "$PEER_LAN_SUBNET" ]; then
    ok "routing is handled somewhere else (on purpose)"
elif ip route | grep -q "$PEER_LAN_SUBNET"; then
    ok "route to $PEER_LAN_SUBNET exists"
else
    fail "no route to $PEER_LAN_SUBNET"; note
fi

# 7 - can we reach the other side
echo "7) Reach the other router"
if ping -c 3 -W 2 "$PEER_LINK_IP" >/dev/null 2>&1; then
    ok "$PEER_LINK_IP answers over the radio link"
else
    fail "$PEER_LINK_IP does not answer"; note
fi

# 8 - security
echo "8) Security"
if [ "$ISOLATE_AP_BSS" = "yes" ]; then
    if in_bridge br0 "$RADIO_IF"; then
        fail "the open radio is inside br0 - anyone could enter your network"
        note
        echo "        Fix: sh $BRIDGE_DIR/wifi-bridge.sh"
    else
        ok "open radio is kept out of your home network"
    fi
fi
if [ "$ENABLE_MAC_FILTER" = "yes" ]; then
    [ "$(wl -i "$RADIO_IF" macmode 2>/dev/null)" = "2" ] && \
        ok "MAC filter is active" || { fail "MAC filter is not active"; note; }
fi

# 9 - firewall
echo "9) Firewall"
if iptables -S FORWARD 2>/dev/null | grep -q "$BRIDGE_NAME"; then
    ok "firewall lets the two networks talk"
else
    fail "firewall rules are missing"; note
    echo "        Fix: sh $BRIDGE_DIR/hook.sh firewall-start"
fi

# 10 - self repair
echo "10) Self-repair job"
if cru l 2>/dev/null | grep -q wifibridge; then
    ok "repair job runs every $CHECK_INTERVAL_MINUTES minute(s)"
else
    fail "repair job is missing - the link will break after a Wi-Fi restart"
    note
fi

echo ""
if [ "$PROBLEMS" -eq 0 ]; then
    echo "  RESULT: everything is fine."
else
    echo "  RESULT: $PROBLEMS problem(s) found. See docs/TROUBLESHOOTING.md"
fi
echo ""
exit 0

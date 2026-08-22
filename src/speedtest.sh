#!/bin/sh
# =====================================================================
#  speedtest.sh - measure the real speed of the radio link
#
#  Normally you start this from your computer:  ./deploy.sh speedtest
#
#  How it works: the routers have no iperf and no netcat server. But
#  they do have a small web server. We put a test file where that web
#  server can serve it, then download it across the link and measure.
#  The file must end in .png, because the web server asks for a login
#  on other file types.
# =====================================================================

BRIDGE_DIR="/jffs/scripts/wifi-bridge"
. "$BRIDGE_DIR/lib.sh" || { echo "ERROR: lib.sh missing"; exit 1; }
load_config

WEB_DIR="/tmp/var/wwwext"
TEST_FILE="$WEB_DIR/wifibridge-speedtest.png"
SIZE_MB="${2:-80}"

case "${1:-run}" in

  serve)
    # Create the test file on THIS router so the other side can pull it.
    mkdir -p "$WEB_DIR"
    dd if=/dev/zero of="$TEST_FILE" bs=1024k count="$SIZE_MB" 2>/dev/null
    echo "ready $(wc -c < "$TEST_FILE")"
    ;;

  clean)
    rm -f "$TEST_FILE"
    echo "cleaned"
    ;;

  run)
    PEER_LAN_IP="${PEER_LAN_IP:-}"
    if [ -z "$PEER_LAN_IP" ]; then
        echo "ERROR: PEER_LAN_IP is not set in bridge.conf"
        exit 1
    fi
    URL="http://$PEER_LAN_IP/user/wifibridge-speedtest.png"

    echo ""
    echo "  Downloading a test file across the radio link..."
    echo "  From: $URL"
    echo ""

    TOTAL=0; RUNS=0
    for i in 1 2 3; do
        R=$(curl -s -o /dev/null -w "%{http_code} %{size_download} %{speed_download}" --max-time 300 "$URL" 2>&1)
        CODE=$(echo "$R" | cut -d' ' -f1)
        SIZE=$(echo "$R" | cut -d' ' -f2)
        SPD=$(echo "$R" | cut -d' ' -f3 | cut -d. -f1)
        if [ "$CODE" = "200" ] && [ "${SPD:-0}" -gt 0 ] 2>/dev/null; then
            echo "    Run $i:  $((SIZE/1048576)) MB  ->  $((SPD/1048576)) MB/s   ($((SPD*8/1000000)) Mbit/s)"
            TOTAL=$((TOTAL+SPD)); RUNS=$((RUNS+1))
        else
            echo "    Run $i:  failed (HTTP $CODE)"
        fi
    done

    echo ""
    if [ "$RUNS" -gt 0 ]; then
        AVG=$((TOTAL/RUNS))
        echo "    AVERAGE: $((AVG/1048576)) MB/s   ($((AVG*8/1000000)) Mbit/s)"
    else
        echo "    Could not measure. Is the link up? Try: ./deploy.sh status"
    fi

    RADIO_IF=$(get_radio_if)
    echo ""
    echo "  Radio quality right now:"
    wl -i "$RADIO_IF" sta_info "$PEER_RADIO_MAC" 2>/dev/null | grep -E "rate of last|smoothed rssi" | sed 's/^/    /'
    echo ""
    ;;
esac
exit 0

#!/bin/sh
# =====================================================================
#  deploy.sh - set up a Wi-Fi bridge between two ASUS Merlin routers
#
#  RUN THIS ON YOUR COMPUTER (Mac or Linux), not on the router.
#  It talks to both routers over SSH and does all the work.
#
#  Usage:
#      ./deploy.sh check       Look at both routers, change nothing
#      ./deploy.sh install     Set up the bridge on both routers
#      ./deploy.sh status      Show if the bridge is working
#      ./deploy.sh speedtest   Measure the real speed
#      ./deploy.sh logs        Show recent bridge messages
#      ./deploy.sh uninstall   Remove everything, restore old settings
# =====================================================================

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CONF="$SCRIPT_DIR/setup.conf"
SRC="$SCRIPT_DIR/src"
REMOTE_DIR="/jffs/scripts/wifi-bridge"

# ---------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------
if [ -t 1 ]; then
    C_OK=$(printf '\033[32m'); C_ERR=$(printf '\033[31m')
    C_WARN=$(printf '\033[33m'); C_B=$(printf '\033[1m'); C_0=$(printf '\033[0m')
else
    C_OK=""; C_ERR=""; C_WARN=""; C_B=""; C_0=""
fi

title() { echo ""; echo "${C_B}=== $* ===${C_0}"; }
ok()    { echo "  ${C_OK}OK${C_0}    $*"; }
bad()   { echo "  ${C_ERR}FAIL${C_0}  $*"; }
warn()  { echo "  ${C_WARN}WARN${C_0}  $*"; }
info()  { echo "        $*"; }
die()   { echo ""; echo "${C_ERR}ERROR:${C_0} $*"; echo ""; exit 1; }

# ---------------------------------------------------------------------
# Load config
# ---------------------------------------------------------------------
[ -f "$CONF" ] || die "setup.conf not found.

Do this first:
    cp setup.conf.example setup.conf
    nano setup.conf"

# shellcheck disable=SC1090
. "$CONF"

: "${ROUTER_A_HOST:=}" ; : "${ROUTER_B_HOST:=}"
: "${ROUTER_A_USER:=admin}" ; : "${ROUTER_B_USER:=admin}"
: "${ROUTER_A_PORT:=22}" ; : "${ROUTER_B_PORT:=22}"
: "${SSH_KEY:=}" ; : "${RADIO:=wl0}" ; : "${CHANNEL:=auto}"
: "${BANDWIDTH:=20}" ; : "${LINK_IP_A:=192.168.255.1}"
: "${LINK_IP_B:=192.168.255.2}" ; : "${BRIDGE_NAME:=br10}"
: "${ISOLATE_AP_BSS:=yes}" ; : "${ENABLE_MAC_FILTER:=yes}"
: "${HIDE_SSID:=yes}" ; : "${DISABLE_AIMESH:=yes}"
: "${CHECK_INTERVAL_MINUTES:=1}" ; : "${ENABLE_LOGGING:=yes}"
: "${REBOOT_AFTER_INSTALL:=ask}" ; : "${ROUTE_OVERRIDE:=}"

case "$ROUTER_A_HOST" in ""|*example.com) die "Please edit setup.conf and enter the real address of Router A." ;; esac
case "$ROUTER_B_HOST" in ""|*example.com) die "Please edit setup.conf and enter the real address of Router B." ;; esac

SSH_OPTS="-o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new"
[ -n "$SSH_KEY" ] && SSH_OPTS="$SSH_OPTS -i $SSH_KEY"

# ---------------------------------------------------------------------
# Talking to the routers
# ---------------------------------------------------------------------
r_host() { [ "$1" = A ] && echo "$ROUTER_A_HOST" || echo "$ROUTER_B_HOST"; }
r_user() { [ "$1" = A ] && echo "$ROUTER_A_USER" || echo "$ROUTER_B_USER"; }
r_port() { [ "$1" = A ] && echo "$ROUTER_A_PORT" || echo "$ROUTER_B_PORT"; }
r_name() { [ "$1" = A ] && echo "Router A" || echo "Router B"; }

# Run a command on a router. Reads the command from standard input.
rsh() {
    _w="$1"
    # shellcheck disable=SC2086
    ssh $SSH_OPTS -p "$(r_port "$_w")" "$(r_user "$_w")@$(r_host "$_w")" /bin/sh
}

# Run a short command given as an argument.
rcmd() {
    _w="$1"; shift
    # shellcheck disable=SC2086
    ssh $SSH_OPTS -p "$(r_port "$_w")" "$(r_user "$_w")@$(r_host "$_w")" "$@"
}

# Copy a file to a router.
# NOTE: -O is required. Router SSH (Dropbear) cannot do SFTP, and
# newer OpenSSH uses SFTP by default. Without -O the copy fails.
rcopy() {
    _w="$1"; _file="$2"; _dest="$3"
    # shellcheck disable=SC2086
    scp -O $SSH_OPTS -P "$(r_port "$_w")" "$_file" "$(r_user "$_w")@$(r_host "$_w"):$_dest" >/dev/null
}

# ---------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------
netmask_to_cidr() {
    _bits=0
    for _o in $(echo "$1" | tr '.' ' '); do
        case "$_o" in
            255) _bits=$((_bits+8)) ;; 254) _bits=$((_bits+7)) ;;
            252) _bits=$((_bits+6)) ;; 248) _bits=$((_bits+5)) ;;
            240) _bits=$((_bits+4)) ;; 224) _bits=$((_bits+3)) ;;
            192) _bits=$((_bits+2)) ;; 128) _bits=$((_bits+1)) ;;
            0) : ;; *) echo 24; return ;;
        esac
    done
    echo "$_bits"
}

network_address() {
    _ip="$1"; _mask="$2"
    _i1=$(echo "$_ip"   | cut -d. -f1); _m1=$(echo "$_mask" | cut -d. -f1)
    _i2=$(echo "$_ip"   | cut -d. -f2); _m2=$(echo "$_mask" | cut -d. -f2)
    _i3=$(echo "$_ip"   | cut -d. -f3); _m3=$(echo "$_mask" | cut -d. -f3)
    _i4=$(echo "$_ip"   | cut -d. -f4); _m4=$(echo "$_mask" | cut -d. -f4)
    echo "$((_i1 & _m1)).$((_i2 & _m2)).$((_i3 & _m3)).$((_i4 & _m4))"
}

# ---------------------------------------------------------------------
# Gather facts from one router
# ---------------------------------------------------------------------
FACT_MODEL=""; FACT_FW=""; FACT_LAN_IP=""; FACT_LAN_MASK=""
FACT_LAN_SUBNET=""; FACT_RADIO_IF=""; FACT_RADIO_MAC=""
FACT_JFFS=""; FACT_AIMESH=""; FACT_CHANNEL=""

gather() {
    _w="$1"
    _out=$(rsh "$_w" << EOF
echo "MODEL=\$(nvram get productid)"
echo "FW=\$(nvram get buildno).\$(nvram get extendno)"
echo "LAN_IP=\$(nvram get lan_ipaddr)"
echo "LAN_MASK=\$(nvram get lan_netmask)"
echo "RADIO_IF=\$(nvram get ${RADIO}_ifname)"
echo "RADIO_MAC=\$(nvram get ${RADIO}_hwaddr)"
echo "JFFS=\$(nvram get jffs2_scripts)"
echo "AIMESH=\$(nvram get cfg_master)"
echo "CHANNEL=\$(wl -i \$(nvram get ${RADIO}_ifname) status 2>/dev/null | grep -i 'Primary channel' | awk '{print \$3}')"
echo "HAS_WL=\$(which wl >/dev/null 2>&1 && echo yes || echo no)"
echo "HAS_BRCTL=\$(which brctl >/dev/null 2>&1 && echo yes || echo no)"
EOF
) || return 1

    FACT_MODEL=$(echo "$_out"  | grep '^MODEL='     | cut -d= -f2-)
    FACT_FW=$(echo "$_out"     | grep '^FW='        | cut -d= -f2-)
    FACT_LAN_IP=$(echo "$_out" | grep '^LAN_IP='    | cut -d= -f2-)
    FACT_LAN_MASK=$(echo "$_out" | grep '^LAN_MASK=' | cut -d= -f2-)
    FACT_RADIO_IF=$(echo "$_out" | grep '^RADIO_IF=' | cut -d= -f2-)
    FACT_RADIO_MAC=$(echo "$_out" | grep '^RADIO_MAC=' | cut -d= -f2-)
    FACT_JFFS=$(echo "$_out"   | grep '^JFFS='      | cut -d= -f2-)
    FACT_AIMESH=$(echo "$_out" | grep '^AIMESH='    | cut -d= -f2-)
    FACT_CHANNEL=$(echo "$_out" | grep '^CHANNEL='  | cut -d= -f2-)
    _haswl=$(echo "$_out" | grep '^HAS_WL=' | cut -d= -f2-)
    _hasbr=$(echo "$_out" | grep '^HAS_BRCTL=' | cut -d= -f2-)

    [ "$_haswl" = yes ] || die "$(r_name "$_w"): the 'wl' command is missing.
This script needs ASUS Merlin firmware on a Broadcom router."
    [ "$_hasbr" = yes ] || die "$(r_name "$_w"): the 'brctl' command is missing."
    [ -n "$FACT_RADIO_IF" ] || die "$(r_name "$_w"): radio '$RADIO' does not exist on this router.
Try RADIO=\"wl0\" (2.4 GHz) or RADIO=\"wl1\" (5 GHz) in setup.conf."

    _cidr=$(netmask_to_cidr "$FACT_LAN_MASK")
    _net=$(network_address "$FACT_LAN_IP" "$FACT_LAN_MASK")
    FACT_LAN_SUBNET="$_net/$_cidr"
    return 0
}

# ---------------------------------------------------------------------
# Pick the quietest channel
# ---------------------------------------------------------------------
pick_channel() {
    info "Scanning the air on both routers (takes about 20 seconds)..." >&2
    _sa=$(rcmd A "IF=\$(nvram get ${RADIO}_ifname); wl -i \$IF scan >/dev/null 2>&1; sleep 6; wl -i \$IF scanresults 2>/dev/null | grep -oE 'Channel: [0-9]+' | awk '{print \$2}'" 2>/dev/null)
    _sb=$(rcmd B "IF=\$(nvram get ${RADIO}_ifname); wl -i \$IF scan >/dev/null 2>&1; sleep 6; wl -i \$IF scanresults 2>/dev/null | grep -oE 'Channel: [0-9]+' | awk '{print \$2}'" 2>/dev/null)
    _all=$(printf '%s\n%s\n' "$_sa" "$_sb" | grep -E '^[0-9]+$')

    if [ "$RADIO" = "wl0" ]; then _cands="1 6 11 13"; else _cands="36 40 44 48"; fi

    # Is channel 12/13 allowed here? Ask the router.
    _allowed=$(rcmd A "IF=\$(nvram get ${RADIO}_ifname); wl -i \$IF channels 2>/dev/null | tr '\n' ' '" 2>/dev/null)

    # Score each candidate. On 2.4 GHz channels overlap: a network on
    # channel 3 disturbs channel 1 badly. So we count neighbours too,
    # and weight them by how close they are. On 5 GHz our candidates do
    # not overlap, so only exact matches count.
    _best=""; _bestn=99999; _bestseen=0
    for _c in $_cands; do
        case " $_allowed " in *" $_c "*) : ;; *) continue ;; esac
        _score=0; _seen=0
        for _n in $_all; do
            _d=$((_n - _c)); [ "$_d" -lt 0 ] && _d=$((-_d))
            if [ "$RADIO" = "wl0" ]; then
                if [ "$_d" -le 4 ]; then
                    _score=$((_score + 5 - _d))
                    _seen=$((_seen + 1))
                fi
            else
                if [ "$_d" -eq 0 ]; then
                    _score=$((_score + 5)); _seen=$((_seen + 1))
                fi
            fi
        done
        if [ "$_score" -lt "$_bestn" ]; then
            _bestn="$_score"; _best="$_c"; _bestseen="$_seen"
        fi
    done
    _bestn="$_bestseen"
    [ -z "$_best" ] && _best=$([ "$RADIO" = "wl0" ] && echo 6 || echo 36)
    info "Channel $_best is the quietest ($_bestn nearby networks)." >&2
    echo "$_best"
}

# ---------------------------------------------------------------------
# COMMAND: check
# ---------------------------------------------------------------------
cmd_check() {
    title "Checking Router A"
    gather A || die "Cannot reach Router A over SSH.

Tried: ssh -p $ROUTER_A_PORT $ROUTER_A_USER@$ROUTER_A_HOST
Please check the address, user and port in setup.conf,
and make sure SSH is turned on. See README.md."
    ok "Reached $ROUTER_A_HOST"
    info "Model:        $FACT_MODEL (firmware $FACT_FW)"
    info "Home network: $FACT_LAN_SUBNET (router is $FACT_LAN_IP)"
    info "Radio $RADIO:    $FACT_RADIO_IF, MAC $FACT_RADIO_MAC, channel now $FACT_CHANNEL"
    A_LAN_SUBNET="$FACT_LAN_SUBNET"; A_RADIO_MAC="$FACT_RADIO_MAC"
    A_LAN_IP="$FACT_LAN_IP"; A_MODEL="$FACT_MODEL"
    [ "$FACT_JFFS" = "1" ] && ok "Custom scripts are on" || warn "Custom scripts are OFF - install will turn them on"
    [ "$FACT_AIMESH" = "1" ] && warn "AiMesh is ON - install will turn it off (it breaks the link)" || ok "AiMesh is off"

    title "Checking Router B"
    gather B || die "Cannot reach Router B over SSH.

Tried: ssh -p $ROUTER_B_PORT $ROUTER_B_USER@$ROUTER_B_HOST
Please check the address, user and port in setup.conf."
    ok "Reached $ROUTER_B_HOST"
    info "Model:        $FACT_MODEL (firmware $FACT_FW)"
    info "Home network: $FACT_LAN_SUBNET (router is $FACT_LAN_IP)"
    info "Radio $RADIO:    $FACT_RADIO_IF, MAC $FACT_RADIO_MAC, channel now $FACT_CHANNEL"
    B_LAN_SUBNET="$FACT_LAN_SUBNET"; B_RADIO_MAC="$FACT_RADIO_MAC"
    B_LAN_IP="$FACT_LAN_IP"; B_MODEL="$FACT_MODEL"
    [ "$FACT_JFFS" = "1" ] && ok "Custom scripts are on" || warn "Custom scripts are OFF - install will turn them on"
    [ "$FACT_AIMESH" = "1" ] && warn "AiMesh is ON - install will turn it off (it breaks the link)" || ok "AiMesh is off"

    title "Checking your plan"
    if [ "$A_LAN_SUBNET" = "$B_LAN_SUBNET" ]; then
        bad "Both routers use the same home network: $A_LAN_SUBNET"
        info "This cannot work. The two sides must be different."
        info "Change the LAN IP of one router, for example to 192.168.10.1,"
        info "then run this check again."
        die "Please fix the network addresses first."
    fi
    ok "The two home networks are different"
    info "Router A: $A_LAN_SUBNET"
    info "Router B: $B_LAN_SUBNET"

    if [ "$A_RADIO_MAC" = "$B_RADIO_MAC" ]; then
        die "Both routers report the same radio MAC address ($A_RADIO_MAC).
That should never happen. Please check that you entered two
different routers in setup.conf."
    fi
    ok "Found both radio MAC addresses automatically"

    _a3=$(echo "$LINK_IP_A" | cut -d. -f1-3)
    for _s in "$A_LAN_SUBNET" "$B_LAN_SUBNET"; do
        _s3=$(echo "$_s" | cut -d. -f1-3)
        [ "$_a3" = "$_s3" ] && die "The link network ($LINK_IP_A) is inside a home network ($_s).
Please pick different LINK_IP_A / LINK_IP_B in setup.conf,
for example 192.168.255.1 and 192.168.255.2."
    done
    ok "Link network $LINK_IP_A / $LINK_IP_B does not clash with anything"

    if [ "$CHANNEL" = "auto" ]; then
        title "Choosing a channel"
        CHOSEN=$(pick_channel)
    else
        CHOSEN="$CHANNEL"
        ok "Using channel $CHOSEN from setup.conf"
    fi
    # Guard: CHOSEN must be a plain number at this point
    case "$CHOSEN" in
        ''|*[!0-9]*) die "Could not work out a channel (got: '$CHOSEN').
Please set a fixed number in setup.conf, for example CHANNEL=\"6\"." ;;
    esac

    title "What will happen when you run: ./deploy.sh install"
    cat << SUMMARY

  Router A ($A_MODEL at $A_LAN_IP)
      home network $A_LAN_SUBNET       link IP $LINK_IP_A
  Router B ($B_MODEL at $B_LAN_IP)
      home network $B_LAN_SUBNET       link IP $LINK_IP_B

  Radio:      $RADIO on channel $CHOSEN, $BANDWIDTH MHz
  Bridge:     $BRIDGE_NAME
  Security:   isolate radio = $ISOLATE_AP_BSS, MAC filter = $ENABLE_MAC_FILTER

  These things WILL change on both routers:
    - The $RADIO radio stops being a normal Wi-Fi network.
      Devices that only use this radio will lose Wi-Fi.
    - Smart Connect and AiMesh will be turned off.
    - The radio will have NO password (the hardware requires this).
      It will be hidden and locked to the other router's MAC.

  Nothing is deleted. Old settings are saved on each router and
  './deploy.sh uninstall' puts them back.

SUMMARY
    ok "Check finished. Nothing was changed."
}

# ---------------------------------------------------------------------
# COMMAND: install
# ---------------------------------------------------------------------
install_one() {
    _w="$1"; _link_ip="$2"; _peer_ip="$3"; _peer_mac="$4"; _peer_subnet="$5"; _chan="$6"; _peer_lan_ip="$7"

    info "Uploading scripts to $(r_name "$_w")..."
    rcmd "$_w" "mkdir -p $REMOTE_DIR $REMOTE_DIR/backup" >/dev/null
    for f in lib.sh wifi-bridge.sh install.sh uninstall.sh check-status.sh speedtest.sh; do
        rcopy "$_w" "$SRC/$f" "$REMOTE_DIR/$f" || die "Could not copy $f to $(r_name "$_w").
If you see an 'sftp' or 'subsystem' error, your scp is too new.
This script already uses 'scp -O'. Please update your OpenSSH."
    done

    _route="$_peer_subnet"
    [ -n "$ROUTE_OVERRIDE" ] && _route="$ROUTE_OVERRIDE"

    info "Writing config on $(r_name "$_w")..."
    rsh "$_w" << EOF > /dev/null
cat > $REMOTE_DIR/bridge.conf << 'CONFEOF'
# Generated by deploy.sh - do not edit by hand.
# Edit setup.conf on your computer and run ./deploy.sh install again.
RADIO="$RADIO"
LOCAL_LINK_IP="$_link_ip"
PEER_LINK_IP="$_peer_ip"
LINK_PREFIX="30"
PEER_RADIO_MAC="$_peer_mac"
PEER_LAN_SUBNET="$_route"
PEER_LAN_IP="$_peer_lan_ip"
CHANNEL="$_chan"
BANDWIDTH="$BANDWIDTH"
BRIDGE_NAME="$BRIDGE_NAME"
ISOLATE_AP_BSS="$ISOLATE_AP_BSS"
ENABLE_MAC_FILTER="$ENABLE_MAC_FILTER"
HIDE_SSID="$HIDE_SSID"
DISABLE_AIMESH="$DISABLE_AIMESH"
CHECK_INTERVAL_MINUTES="$CHECK_INTERVAL_MINUTES"
ENABLE_LOGGING="$ENABLE_LOGGING"
CONFEOF
chmod 755 $REMOTE_DIR/*.sh
EOF

    info "Running installer on $(r_name "$_w")..."
    rcmd "$_w" "sh $REMOTE_DIR/install.sh" || die "The installer failed on $(r_name "$_w"). See the messages above."
}

cmd_install() {
    cmd_check

    echo ""
    printf "Type YES to install on both routers: "
    read -r _answer
    [ "$_answer" = "YES" ] || { echo "Nothing was changed."; exit 0; }

    title "Installing on Router A"
    install_one A "$LINK_IP_A" "$LINK_IP_B" "$B_RADIO_MAC" "$B_LAN_SUBNET" "$CHOSEN" "$B_LAN_IP"
    ok "Router A is ready"

    title "Installing on Router B"
    install_one B "$LINK_IP_B" "$LINK_IP_A" "$A_RADIO_MAC" "$A_LAN_SUBNET" "$CHOSEN" "$A_LAN_IP"
    ok "Router B is ready"

    _do_reboot="no"
    case "$REBOOT_AFTER_INSTALL" in
        yes) _do_reboot="yes" ;;
        ask)
            echo ""
            info "Both routers should now restart. This takes about 3 minutes."
            printf "Restart both routers now? [y/N]: "
            read -r _r
            case "$_r" in y|Y|yes|YES) _do_reboot="yes" ;; esac
            ;;
    esac

    if [ "$_do_reboot" = "yes" ]; then
        title "Restarting both routers"
        rcmd A "nohup sh -c 'sleep 3; reboot' >/dev/null 2>&1 &" >/dev/null 2>&1
        rcmd B "nohup sh -c 'sleep 20; reboot' >/dev/null 2>&1 &" >/dev/null 2>&1
        info "Both routers are restarting. Waiting for them to come back..."
        _n=0
        while [ "$_n" -lt 60 ]; do
            if rcmd A "echo up" >/dev/null 2>&1 && rcmd B "echo up" >/dev/null 2>&1; then break; fi
            _n=$((_n+1))
        done
        info "Giving the radio link 90 more seconds to connect..."
        rcmd A "sleep 90" >/dev/null 2>&1
        cmd_status
    else
        echo ""
        warn "You chose not to restart."
        info "The bridge may already work. Check it with: ./deploy.sh status"
        info "If it does not work, restart both routers and check again."
    fi
}

# ---------------------------------------------------------------------
# COMMAND: status
# ---------------------------------------------------------------------
cmd_status() {
    for _w in A B; do
        title "$(r_name "$_w") status"
        rcmd "$_w" "sh $REMOTE_DIR/check-status.sh" 2>&1 || \
            bad "Could not reach $(r_name "$_w") or the bridge is not installed there."
    done
}

# ---------------------------------------------------------------------
# COMMAND: speedtest
# ---------------------------------------------------------------------
cmd_speedtest() {
    title "Speed test over the radio link"
    info "Putting a test file on Router B..."
    rcmd B "sh $REMOTE_DIR/speedtest.sh serve 80" >/dev/null 2>&1 || \
        die "Could not create the test file on Router B."
    info "Downloading it from Router A across the link. Please wait..."
    rcmd A "sh $REMOTE_DIR/speedtest.sh run" 2>&1
    info "Cleaning up..."
    rcmd B "sh $REMOTE_DIR/speedtest.sh clean" >/dev/null 2>&1
}

# ---------------------------------------------------------------------
# COMMAND: logs
# ---------------------------------------------------------------------
cmd_logs() {
    for _w in A B; do
        title "$(r_name "$_w") log messages"
        rcmd "$_w" "logread 2>/dev/null | grep wifi-bridge | tail -25 || echo '(no messages yet)'" 2>&1
    done
}

# ---------------------------------------------------------------------
# COMMAND: uninstall
# ---------------------------------------------------------------------
cmd_uninstall() {
    title "Remove the bridge from both routers"
    echo ""
    info "This puts the old Wi-Fi settings back and deletes the scripts."
    printf "Type YES to remove it: "
    read -r _answer
    [ "$_answer" = "YES" ] || { echo "Nothing was changed."; exit 0; }

    for _w in A B; do
        title "Cleaning $(r_name "$_w")"
        rcmd "$_w" "sh $REMOTE_DIR/uninstall.sh" 2>&1 || warn "Could not clean $(r_name "$_w")."
    done
    echo ""
    ok "Done. Please restart both routers to finish."
}

# ---------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------
case "${1:-}" in
    check)     cmd_check ;;
    install)   cmd_install ;;
    status)    cmd_status ;;
    speedtest) cmd_speedtest ;;
    logs)      cmd_logs ;;
    uninstall) cmd_uninstall ;;
    *)
        cat << USAGE
Wi-Fi bridge for two ASUS Merlin routers

  ./deploy.sh check       Look at both routers and show the plan.
                          Changes nothing. Always start here.
  ./deploy.sh install     Set up the bridge on both routers.
  ./deploy.sh status      Show if the bridge is working.
  ./deploy.sh speedtest   Measure the real speed of the link.
  ./deploy.sh logs        Show recent messages from both routers.
  ./deploy.sh uninstall   Remove it and put the old settings back.

First time? Do this:
  1. cp setup.conf.example setup.conf
  2. nano setup.conf          (enter how to reach your two routers)
  3. ./deploy.sh check
  4. ./deploy.sh install
USAGE
        ;;
esac

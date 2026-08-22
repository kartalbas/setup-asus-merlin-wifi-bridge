# Every SSH Command, Step by Step

`deploy.sh` does all of this for you. This page exists so you can do it by
hand, and so you can understand what happens. These are the real commands,
in the real order, that built a working bridge.

## Names used on this page

Replace these with your own values.

| Name here | Means |
|---|---|
| `ROUTER_A` | address of router A, for example `192.168.0.1` |
| `ROUTER_B` | address of router B, for example `192.168.10.1` |
| `PORT` | your SSH port, often `22` |
| `USER` | your router login name, often `admin` |
| `RADIO` | `wl0` for 2.4 GHz, `wl1` for 5 GHz |
| `MAC_A` / `MAC_B` | radio MAC of router A / B (step 3 finds these) |

**Important for copying files:** always use `scp -O`. Router SSH cannot do
SFTP, but new versions of `scp` use SFTP by default. Without `-O` it fails.

---

## Step 1 - Can you reach both routers?

```sh
ssh -p PORT USER@ROUTER_A "echo OK; nvram get productid; nvram get buildno"
ssh -p PORT USER@ROUTER_B "echo OK; nvram get productid; nvram get buildno"
```

You should see `OK` and your router model.

---

## Step 2 - Look at the current state (changes nothing)

Run this on **both** routers.

```sh
ssh -p PORT USER@ROUTER_A '
echo "=== FIRMWARE ==="; uname -a; nvram get buildno
echo "=== CUSTOM SCRIPTS (must be 1) ==="; nvram get jffs2_scripts
echo "=== BRIDGES ==="; brctl show
echo "=== ADDRESSES ==="; ip -o -4 addr show
echo "=== ROUTES ==="; ip route
echo "=== RADIO NAMES ==="; nvram get wl0_ifname; nvram get wl1_ifname
echo "=== AIMESH (1 means ON) ==="; nvram get cfg_master
'
```

Write down two things: is `jffs2_scripts` a `1`, and is `cfg_master` a `1`?

---

## Step 3 - Find the radio MAC addresses

You need the MAC of the **radio**, not the one on the sticker and not the
WAN MAC. Ask each router:

```sh
ssh -p PORT USER@ROUTER_A "nvram get RADIO_hwaddr"    # this is MAC_A
ssh -p PORT USER@ROUTER_B "nvram get RADIO_hwaddr"    # this is MAC_B
```

Router A needs `MAC_B` later, and router B needs `MAC_A`. They cross over.

---

## Step 4 - Turn on custom scripts

Without this the router ignores every script you install. On many routers
this is OFF from the factory.

```sh
ssh -p PORT USER@ROUTER_A 'nvram set jffs2_scripts=1; nvram commit; nvram get jffs2_scripts'
ssh -p PORT USER@ROUTER_B 'nvram set jffs2_scripts=1; nvram commit; nvram get jffs2_scripts'
```

Must print `1`.

---

## Step 5 - Save the old settings first

Do this before you change anything. It is your way back.

```sh
ssh -p PORT USER@ROUTER_A '
mkdir -p /jffs/wifi-bridge-backup
nvram show 2>/dev/null > /jffs/wifi-bridge-backup/nvram-before.txt
for v in $(nvram show 2>/dev/null | grep -oE "^(RADIO[._][a-zA-Z0-9_.]*|smart_connect_x|cfg_master)=" | tr -d "=" | sort -u); do
  echo "nvram set $v=\"$(nvram get $v)\""
done > /jffs/wifi-bridge-backup/restore.sh
echo "nvram commit" >> /jffs/wifi-bridge-backup/restore.sh
chmod 755 /jffs/wifi-bridge-backup/restore.sh
wc -l /jffs/wifi-bridge-backup/restore.sh
'
```

Do the same on router B.

---

## Step 6 - Pick a quiet channel

Look at what your neighbours use. Do this on both routers and compare.

```sh
ssh -p PORT USER@ROUTER_A '
IF=$(nvram get RADIO_ifname)
wl -i $IF scan; sleep 6
wl -i $IF scanresults | grep -oE "Channel: [0-9]+" | awk "{print \$2}" | sort -n | uniq -c | sort -rn
'
```

You get a list like `5 1` (five networks on channel 1). Pick the channel
with the **smallest** count on both sides. Good choices on 2.4 GHz are
1, 6, 11 and 13.

Check that your country allows it:

```sh
ssh -p PORT USER@ROUTER_A 'IF=$(nvram get RADIO_ifname); wl -i $IF country; wl -i $IF channels'
```

Channels 12 and 13 are not allowed everywhere (for example not in the USA).

---

## Step 7 - Configure the radio

This is the core step. Run it on **router A**, using **MAC_B**:

```sh
ssh -p PORT USER@ROUTER_A '
# AP + WDS. This must be 2, NOT 1.
# With 1 ("WDS only") the radio never starts sending and nothing connects.
nvram set RADIO_mode_x=2
nvram set RADIO_wdsapply_x=1
nvram set RADIO_wdslist=MAC_B
nvram set RADIO_lazywds=0

# No password. WPA2 breaks this kind of link.
nvram set RADIO_auth_mode_x=open
nvram set RADIO_wep_x=0

# Same fixed channel on both routers
nvram set RADIO_channel=6
nvram set RADIO_chanspec=6
nvram set RADIO_bw=1            # 1 = 20 MHz, 2 = 40 MHz
nvram set RADIO_nctrlsb=none

# Hide the name, and one name per radio
nvram set RADIO_closed=1
nvram set smart_connect_x=0

nvram commit
'
```

Now the same on **router B**, but with `RADIO_wdslist=MAC_A`. Everything
else stays identical - **especially the channel**.

---

## Step 8 - Turn off AiMesh

AiMesh controls the channel. While it runs, your channel keeps moving and
the link can never form. This was the hardest problem to find.

```sh
ssh -p PORT USER@ROUTER_A '
nvram set cfg_master=0
nvram set wl0.4_bss_enabled=0
nvram set wl1.4_bss_enabled=0
nvram commit
'
```

Same on router B.

---

## Step 9 - Only allow the other router (optional but recommended)

```sh
ssh -p PORT USER@ROUTER_A '
IF=$(nvram get RADIO_ifname)
nvram set RADIO_macmode=allow
nvram set RADIO_maclist_x="<MAC_B"
nvram commit
wl -i $IF mac MAC_B
wl -i $IF macmode 2
'
```

Same on router B with `MAC_A`.

---

## Step 10 - Restart both routers

Settings like the channel only take effect properly after a full restart.

```sh
ssh -p PORT USER@ROUTER_A 'nohup sh -c "sleep 3; reboot" >/dev/null 2>&1 &'
ssh -p PORT USER@ROUTER_B 'nohup sh -c "sleep 20; reboot" >/dev/null 2>&1 &'
```

Wait about three minutes.

---

## Step 11 - Did the radios find each other?

```sh
ssh -p PORT USER@ROUTER_A '
IF=$(nvram get RADIO_ifname)
echo "--- radio sending? (want: up) ---";     wl -i $IF bss
echo "--- channel (must match router B) ---"; wl -i $IF status | grep -i "Primary channel"
echo "--- link interface ---";                ls /sys/class/net/ | grep wds
echo "--- other router ---";                  wl -i $IF sta_info MAC_B | grep -E "state|smoothed rssi"
'
```

What you want to see:

```
up
	Primary channel: 6
wds0.0.1
	 state: AUTHORIZED
smoothed rssi: -50
```

`state: AUTHORIZED` means the radios are connected. If `state:` is empty,
they are not. Check the channel on both sides first.

**Note the interface name.** Here it is `wds0.0.1`. On other firmware it
may be `wds0.1`. Use the name **your** router prints in the next step.

---

## Step 12 - Build the link network

Now we give the radio link its own bridge and its own address. This must
be its own bridge, **not** `br0`. If it went into `br0`, both homes would
become one network with two DHCP servers, and devices would get addresses
from the wrong router.

On **router A**:

```sh
ssh -p PORT USER@ROUTER_A '
WDS=$(ls /sys/class/net/ | grep "^wds" | head -1)
IF=$(nvram get RADIO_ifname)

brctl addbr br10 2>/dev/null
ip link set br10 up

# take it out of the home bridge, put it in the link bridge
brctl delif br0 $WDS 2>/dev/null
brctl addif br10 $WDS
ip link set $WDS up

# address of this side
ip addr add 192.168.255.1/30 dev br10

# route to the network behind the other router
ip route replace 192.168.10.0/24 via 192.168.255.2 dev br10

# security: keep the open radio out of the home network
brctl delif br0 $IF 2>/dev/null

brctl show; ip -o -4 addr show dev br10; ip route | grep 192.168.10
'
```

On **router B** the same, but swap the numbers:

```sh
ip addr add 192.168.255.2/30 dev br10
ip route replace 192.168.0.0/24 via 192.168.255.1 dev br10
```

---

## Step 13 - Open the firewall

The router blocks traffic between different bridges by default.

```sh
ssh -p PORT USER@ROUTER_A '
iptables -I INPUT   -i br10 -j ACCEPT
iptables -I FORWARD -i br10 -o br0  -j ACCEPT
iptables -I FORWARD -i br0  -o br10 -j ACCEPT
iptables -S FORWARD | grep br10
'
```

Same on router B. There is **no NAT rule** here on purpose. The router only
translates addresses on the internet port, so addresses stay unchanged
across the bridge. That is what you want.

---

## Step 14 - Test it

```sh
ssh -p PORT USER@ROUTER_A 'ping -c 5 192.168.255.2'      # the link itself
ssh -p PORT USER@ROUTER_A 'ping -c 5 192.168.10.1'       # the other router
ssh -p PORT USER@ROUTER_B 'ping -c 5 192.168.255.1'      # back again
ssh -p PORT USER@ROUTER_B 'ping -c 5 192.168.0.1'
```

All four must answer with `0% packet loss`.

---

## Step 15 - Make it survive a restart

Everything in step 12 and 13 is gone after a reboot, and the router also
puts the link back into `br0` after **every** Wi-Fi restart. So it must be
repaired automatically, once a minute.

This is exactly what `src/wifi-bridge.sh` does, and why a cron job runs it.
Install it the easy way:

```sh
./deploy.sh install
```

Or by hand: copy the scripts over (remember `-O`), then add the cron job.

```sh
scp -O -P PORT src/*.sh USER@ROUTER_A:/jffs/scripts/wifi-bridge/
ssh -p PORT USER@ROUTER_A 'cru a wifibridge "* * * * * /jffs/scripts/wifi-bridge/wifi-bridge.sh"'
ssh -p PORT USER@ROUTER_A 'cru l'
```

---

## Measuring the speed by hand

The routers have no `iperf` and no `nc` server. But they do run a small web
server. Put a file where it can serve it, then download it across the link.
The file **must** end in `.png` - other types ask for a login.

On **router B**:

```sh
ssh -p PORT USER@ROUTER_B 'mkdir -p /tmp/var/wwwext && dd if=/dev/zero of=/tmp/var/wwwext/test.png bs=1024k count=80'
```

On **router A**:

```sh
ssh -p PORT USER@ROUTER_A 'curl -s -o /dev/null -w "%{http_code} %{speed_download} bytes/s\n" http://192.168.10.1/user/test.png'
```

Divide by 1048576 to get MB/s. Clean up when you are done:

```sh
ssh -p PORT USER@ROUTER_B 'rm -f /tmp/var/wwwext/test.png'
```

**Do not use `ping` to measure speed.** The `ping` on these routers sends
only one packet per second, so you would just measure the clock.

---

## Going back

```sh
ssh -p PORT USER@ROUTER_A 'sh /jffs/wifi-bridge-backup/restore.sh; reboot'
ssh -p PORT USER@ROUTER_B 'sh /jffs/wifi-bridge-backup/restore.sh; reboot'
```

If SSH itself stops working: hold the reset button for 10 seconds and load
a saved `.cfg` backup from the web page. None of these commands touch the
firmware or the flash partitions.

---

## Useful commands for digging

```sh
# what the bridge scripts logged
logread | grep wifi-bridge

# is the radio really sending?
wl -i $(nvram get RADIO_ifname) bss

# what channel is it really on (this is the truth)
wl -i $(nvram get RADIO_ifname) status | grep -i "Primary channel"

# what channel it THINKS it is on (can lie during a scan - do not trust it)
wl -i $(nvram get RADIO_ifname) chanspec

# who is connected on the radio
wl -i $(nvram get RADIO_ifname) assoclist

# which interfaces sit in which bridge
brctl show
```

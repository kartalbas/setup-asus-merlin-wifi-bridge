# Troubleshooting

Always start here:

```sh
./deploy.sh status
```

It runs ten checks on each router and names the one that failed. Find that
check below.

---

## Check 1 fails: "radio is DOWN"

```
1) Radio sending?
   FAIL  radio is DOWN (bss=down) - nothing can connect
```

The radio is not sending. Nothing can ever connect, no matter what channel
you use.

**Cause:** the mode is "WDS only" instead of "AP + WDS".

```sh
ssh -p PORT USER@ROUTER "nvram get wl0_mode_x"
```

If it says `1`, that is the problem. It must be `2`.

```sh
ssh -p PORT USER@ROUTER 'nvram set wl0_mode_x=2; nvram commit; service restart_wireless'
```

---

## Check 2 fails: wrong channel

```
2) Channel
   FAIL  on channel 1, but config says 6
```

Both routers must be on the **same** channel. If they differ, they can
never hear each other.

**Cause A - AiMesh is still on.** This is the most common reason. AiMesh
owns the channel and keeps moving it.

```sh
ssh -p PORT USER@ROUTER "nvram get cfg_master"     # 1 means AiMesh is on
ssh -p PORT USER@ROUTER 'nvram set cfg_master=0; nvram set wl0.4_bss_enabled=0; nvram commit; reboot'
```

**Cause B - the setting needs a restart.** Changing the channel while the
router runs often does not stick. Restart the router.

**Cause C - the channel is not allowed in your country.**

```sh
ssh -p PORT USER@ROUTER 'IF=$(nvram get wl0_ifname); wl -i $IF country; wl -i $IF channels'
```

If your channel is not in the list, pick one that is. Channels 12 and 13
are not allowed everywhere.

> **Tip:** `wl ... chanspec` can show a different number while the radio is
> scanning. It is not lying on purpose, but do not trust it. The real
> channel is `wl ... status | grep "Primary channel"`.

---

## Check 3 or 4 fails: the radios do not connect

```
3) Radio link
   FAIL  no link interface yet
4) Other router connected?
   FAIL  not connected
```

Work through this list in order:

**1. Same channel on both sides?** See check 2 above. This is the reason
most of the time.

**2. Are the MAC addresses crossed correctly?** Router A must list router
B's MAC, and B must list A's.

```sh
ssh -p PORT USER@ROUTER_A "nvram get wl0_hwaddr; nvram get wl0_wdslist"
ssh -p PORT USER@ROUTER_B "nvram get wl0_hwaddr; nvram get wl0_wdslist"
```

A's `wdslist` must equal B's `hwaddr`, and the other way round. A common
mistake is using the MAC from the sticker or the WAN MAC. Use
`nvram get wl0_hwaddr`.

**3. Is a password set by mistake?** Must be `open`.

```sh
ssh -p PORT USER@ROUTER "nvram get wl0_auth_mode_x"
```

If it says `psk2`, the link will never come up. WPA2 does not work here.

**4. Is the signal good enough?**

```sh
ssh -p PORT USER@ROUTER_A 'IF=$(nvram get wl0_ifname); wl -i $IF sta_info MAC_B | grep rssi'
```

Better than -70 dBm is good. Worse than -80 dBm will be unstable. Move the
routers, or switch from 5 GHz to 2.4 GHz, which passes through walls much
better.

**5. Is the MAC filter blocking it?** Turn it off for a test:

```sh
ssh -p PORT USER@ROUTER 'IF=$(nvram get wl0_ifname); wl -i $IF macmode 0'
```

If it works now, the allowed address was wrong.

---

## Check 5 fails: "link is in br0"

```
5) Link bridge
   FAIL  wds0.0.1 is in br0 - DANGER: both homes are one network now
```

This is serious but easy to fix. Both networks are merged right now, and
two DHCP servers are handing out addresses. Devices may get an address from
the wrong router.

```sh
ssh -p PORT USER@ROUTER "sh /jffs/scripts/wifi-bridge/wifi-bridge.sh"
```

Then find out why it was not repaired automatically - see check 10.

---

## Check 7 fails: no ping to the other side

The radios are connected but no traffic passes.

**Addresses wrong?** The two must be in the same small network and must
differ:

```sh
ssh -p PORT USER@ROUTER_A "ip -4 addr show dev br10"    # want 192.168.255.1/30
ssh -p PORT USER@ROUTER_B "ip -4 addr show dev br10"    # want 192.168.255.2/30
```

**Firewall?** See check 9.

---

## Check 9 fails: firewall rules missing

```sh
ssh -p PORT USER@ROUTER "sh /jffs/scripts/wifi-bridge/hook.sh firewall-start"
```

To make it permanent, check that `/jffs/scripts/firewall-start` contains a
line with `# wifi-bridge`, and that custom scripts are on:

```sh
ssh -p PORT USER@ROUTER "nvram get jffs2_scripts"   # must be 1
```

---

## Check 10 fails: repair job missing

```
10) Self-repair job
    FAIL  repair job is missing
```

Without it, the link breaks again after the next Wi-Fi restart.

```sh
ssh -p PORT USER@ROUTER "cru l"
```

You want a line containing `wifibridge`. If it is missing:

```sh
ssh -p PORT USER@ROUTER "nvram get jffs2_scripts"
```

If this is `0`, that is the root cause - no script ever runs.

```sh
ssh -p PORT USER@ROUTER 'nvram set jffs2_scripts=1; nvram commit; reboot'
```

---

## "It worked, then it stopped"

Almost always a Wi-Fi restart happened and the repair job is not running.
See check 10. Look at what the scripts did:

```sh
./deploy.sh logs
```

---

## Devices get an address from the wrong router

The link is in `br0`. See check 5. Fix it immediately - while this lasts,
your two networks are one.

---

## Speed is much lower than expected

* On 2.4 GHz with 20 MHz width, 10-15 MB/s is normal and healthy.
* Try 40 MHz: set `BANDWIDTH="40"` and install again. Expect roughly double
  the speed, but a less stable link. Go back to 20 if it drops.
* Check the signal: below -75 dBm the speed falls fast.
* Pick a quieter channel: `./deploy.sh check` scans and suggests one.

**Do not measure with `ping`.** The `ping` on these routers sends one packet
per second, so you would measure the clock, not the link. Use
`./deploy.sh speedtest`.

---

## I locked myself out over SSH

The scripts never touch the WAN port, the firmware or the partitions, so
SSH from outside keeps working.

If you really cannot get in: hold the reset button for 10 seconds, then
load a saved `.cfg` backup from the web page.

---

## Copying files fails with an "sftp" error

Your `scp` is new and uses SFTP by default. Router SSH cannot do SFTP.
Always add `-O`:

```sh
scp -O -P PORT file USER@ROUTER:/jffs/scripts/
```

`deploy.sh` already does this.

---

## Start over from scratch

```sh
./deploy.sh uninstall
# restart both routers, then:
./deploy.sh check
./deploy.sh install
```

# Findings - Four Traps and Why the Scripts Look Like This

These are real problems found while building a working bridge on two ASUS
GT-AX6000 routers with Asuswrt-Merlin. Each one cost hours. They are
written down so you do not have to find them again.

---

## Trap 1: Custom scripts are off from the factory

`jffs2_scripts` was `0` on both routers. That single setting means the
firmware ignores **every** script in `/jffs/scripts/`.

The scripts were in place, correct, and executable. Nothing ran. A reboot
would have changed nothing, because there was nothing to trigger.

```sh
nvram get jffs2_scripts      # must be 1
nvram set jffs2_scripts=1; nvram commit
```

**In the scripts:** `install.sh` checks this first and turns it on.
`check-status.sh` reports it. It is the first thing to suspect when
"nothing happens".

---

## Trap 2: The link interface is not called what you expect

Almost every guide on the internet says the WDS interface is `wds0.1`.

On this firmware it is **`wds0.0.1`**.

A script that looks for a fixed name silently does nothing - it just exits,
every minute, forever, without an error.

```sh
ls /sys/class/net/ | grep wds
```

**In the scripts:** the name is never guessed. `get_wds_if()` searches for
whatever `wds*` interface exists, preferring the one matching the chosen
radio. This also makes 5 GHz work without changes, where the name starts
with `wds1.`.

---

## Trap 3: AiMesh silently owns the channel

This was the hardest one.

The channel was set correctly in NVRAM (`wl0_chanspec=13`), the setting was
committed, Wi-Fi was restarted - and the radio still ran on channel 8. A
`wl chanspec 13` command reported success, then measurements showed:

```
right away: 13      after 3s: 6      after 10s: 12      after 20s: 13
```

The channel was **wandering**. The radio was scanning, not settled.

The cause: AiMesh was active (`cfg_master=1`), with the full `cfg_server` /
`amas_*` daemon stack running, plus a hidden AiMesh backhaul network
(`wl0.4`, an SSID that is a long random-looking string) sitting on the very
radio we wanted for the bridge. AiMesh decides the channel, and it keeps
deciding it.

```sh
nvram get cfg_master              # 1 means AiMesh is running
nvram set cfg_master=0
nvram set wl0.4_bss_enabled=0
nvram commit
```

Note: `wl0.4_bss_enabled` turns itself back on after `service
restart_wireless`. Only a real reboot makes it stick.

**In the scripts:** `install.sh` turns AiMesh off by default
(`DISABLE_AIMESH="yes"`), and `deploy.sh check` warns you if it is on.

---

## Trap 4: "WDS only" mode does not work at all

This is the big one, and the one that wastes the most time, because
everything *looks* right.

Setting `wl0_mode_x=1` ("WDS Only") is what every guide tells you to do.
On this AX hardware it produces a radio that never transmits:

```sh
wl -i eth6 bss        # -> down
wl -i eth6 bssid      # -> 00:00:00:00:00:00
```

No beacons. Nothing can associate, on any channel. `wl bss up` does not
help. `wl0_bss_enabled` is already `1`. Every channel symptom described in
trap 3 was actually a *consequence* of this: an inactive radio has no real
channel, so it falls back to defaults and drifts.

The fix is `wl0_mode_x=2` - **"AP + WDS" (hybrid)**. With that:

```
bss=up   BSSID=<real mac>   Primary channel: 13   state: AUTHORIZED
```

The link came up within seconds and stayed up.

**The trade-off:** in hybrid mode the radio is also a normal access point.
Since WDS forces open authentication, that access point is open. This is
why the scripts cut the radio interface out of `br0` - see
[SECURITY.md](SECURITY.md). The bridge itself does not need it, because
bridge traffic runs over the separate `wds*` interface.

**In the scripts:** `install.sh` always sets mode `2`, and `check-status.sh`
checks `bss` first, because `down` explains everything else.

---

## Also worth knowing

**WPA2 breaks the link, for certain.** Tested directly: with
`auth_mode_x=psk2` on both sides, the radio is up and on the right channel,
but the peer never associates - 100% packet loss. Back to `open`, and it
works again in seconds. This is a hardware limit, not a configuration
mistake.

**`wl chanspec` can lie; `wl status` tells the truth.** During a scan,
`chanspec` reports whatever channel the radio is visiting. Always read
`wl ... status | grep "Primary channel"` instead.

**The router undoes your work constantly.** After every Wi-Fi restart the
firmware recreates the link interface and puts it back into `br0`, and puts
the radio back into `br0` too. Both must be repaired continuously. That is
why a cron job runs every minute - not as a workaround, but as the design.

**`ping` cannot measure speed here.** BusyBox `ping` sends one packet per
second and ignores flood options. 150 packets take exactly 150 seconds. An
early measurement showed "1 MB/s" and it was completely wrong.

**There is no `iperf` and no `nc` server.** BusyBox `nc` here is client
only, with no `-l`. The working method: drop a file into `/tmp/var/wwwext`
(served as `/user/` by the router web server) and download it with `curl`
across the link. The file must end in `.png` - other extensions get a login
redirect of 88 bytes instead of the file.

**A shared provider subnet is not a shortcut.** Both routers had public IPs
in the same `/24`. That looked like a direct path, but the provider answers
ARP for both (proxy ARP, same gateway MAC, TTL 63). There is no shared
layer 2, so it cannot replace a cable.

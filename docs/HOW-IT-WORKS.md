# How It Works

Plain words first, details after.

## The idea

Two routers. Each keeps its own network and its own internet line. We want
a computer on side A to reach a computer on side B. There is no cable, so
we use radio.

The trick has two halves:

1. **A radio cable.** WDS makes a Wi-Fi link that behaves like a network
   cable between the two routers. It carries raw network frames.
2. **A tiny network on top of it.** We give that "cable" its own small
   network with two addresses, and we tell each router how to reach the
   other side.

```
 Router A                                              Router B
 ---------                                             ---------
 br0   192.168.0.1/24    (your devices)                br0   192.168.10.1/24
 br10  192.168.255.1/30  <===== radio link =====>      br10  192.168.255.2/30

 Route on A:  192.168.10.0/24  via 192.168.255.2
 Route on B:  192.168.0.0/24   via 192.168.255.1
```

## Why a separate bridge (br10)?

This is the most important design choice.

The router puts the radio link into `br0` automatically. `br0` is your home
network. If we left it there, the two homes would melt into **one** network
with **two** DHCP servers. Your laptop could get an address from the wrong
router, and nothing would work properly.

So we pull the link out of `br0` and put it into its own bridge, `br10`.
Now the two homes stay separate, and traffic between them is **routed**,
not merged. That is exactly what we want.

We do not use `br1` or `br2` because ASUS uses those for guest networks.

## Why no NAT?

ASUS routers only change addresses on the internet port. Traffic that goes
over `br10` is not touched. So a computer on side B really sees the original
address `192.168.0.x`, not a fake one.

This matters if you run servers, or anything that checks who is calling.

## Why does a job run every minute?

Because the router keeps undoing our work.

Every time Wi-Fi restarts - and that happens on its own more often than you
think - the firmware creates the link interface again and drops it back
into `br0`. If nobody fixes that, two things break at once: the bridge
stops routing, and both homes merge into one network.

So `wifi-bridge.sh` runs once a minute from cron and also right after every
Wi-Fi restart. It checks everything and repairs whatever is wrong. If
nothing is wrong, it does nothing and exits. Running it often is free.

This is why the setup survives reboots, power cuts and firmware hiccups.

## Why "AP + WDS" and not "WDS only"?

You would expect "WDS only" to be the right mode. It is not, at least not
on newer ASUS AX hardware.

In "WDS only" mode the radio never starts sending. You can check it:
`wl -i <radio> bss` says `down`, and the BSSID is all zeros. No beacons
means nothing can ever connect, no matter what channel you pick.

In "AP + WDS" mode (`mode_x=2`) the radio starts properly, holds a fixed
channel, and the WDS link comes up within seconds.

The cost is that the radio is also a normal access point now - an open one.
That is why we cut it out of `br0`. See [SECURITY.md](SECURITY.md).

## What each file does

**On your computer**

| File | Job |
|---|---|
| `setup.conf` | The only file you edit. How to reach both routers. |
| `deploy.sh` | Talks to both routers over SSH and does everything. |

**On each router, in `/jffs/scripts/wifi-bridge/`**

| File | Job |
|---|---|
| `bridge.conf` | Settings for this router. Written by `deploy.sh`. |
| `lib.sh` | Shared helper functions. |
| `wifi-bridge.sh` | Builds and repairs the link. Runs every minute. |
| `hook.sh` | Called by the firmware at boot, on firewall restart, and after Wi-Fi restarts. |
| `check-status.sh` | Ten health checks. |
| `speedtest.sh` | Measures real speed. |
| `uninstall.sh` | Puts the old settings back. |
| `backup/restore.sh` | Your old settings, saved before any change. |

**Firmware hooks in `/jffs/scripts/`**

`services-start`, `firewall-start` and `service-event-end` each get **one
line** added, marked with `# wifi-bridge`. If you already have your own
hooks, they are kept - we only append. Uninstall removes just that line.

## Why the scripts work on any ASUS model

Nothing is hard-coded.

The radio interface is not assumed to be `eth6`. We ask the router:

```sh
nvram get wl0_ifname
```

The link interface name also differs between firmware versions - it can be
`wds0.1` or `wds0.0.1`. We do not guess, we search:

```sh
ls /sys/class/net/ | grep "^wds"
```

Same for your network addresses: `deploy.sh` reads `lan_ipaddr` and
`lan_netmask` from each router and works out the subnets itself. You never
type a MAC address or a network number.

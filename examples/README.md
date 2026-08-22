# Example Configurations

Copy the one that fits your case into `setup.conf` at the top level of the
project, then change the addresses to your own.

---

## Example 1 - The normal case (start here)

Two routers, one wall between them. 2.4 GHz, automatic channel choice.
This is what most people want.

```sh
ROUTER_A_HOST="192.168.0.1"
ROUTER_A_USER="admin"
ROUTER_A_PORT="22"

ROUTER_B_HOST="192.168.10.1"
ROUTER_B_USER="admin"
ROUTER_B_PORT="22"

SSH_KEY=""

RADIO="wl0"          # 2.4 GHz - best through walls
CHANNEL="auto"       # scan and pick the quietest
BANDWIDTH="20"       # most stable

LINK_IP_A="192.168.255.1"
LINK_IP_B="192.168.255.2"
BRIDGE_NAME="br10"

ISOLATE_AP_BSS="yes"
ENABLE_MAC_FILTER="yes"
HIDE_SSID="yes"
DISABLE_AIMESH="yes"

CHECK_INTERVAL_MINUTES="1"
ENABLE_LOGGING="yes"
REBOOT_AFTER_INSTALL="ask"
ROUTE_OVERRIDE=""
```

Expect roughly 10-15 MB/s.

---

## Example 2 - Routers in the same room, you want speed

5 GHz carries much more data but does not pass through walls well. Only
use this if the two routers can almost see each other.

```sh
RADIO="wl1"          # 5 GHz
CHANNEL="36"
BANDWIDTH="80"
```

Everything else the same as example 1.

If the link keeps dropping, go back to `RADIO="wl0"`. A slow link that
always works beats a fast one that does not.

---

## Example 3 - Reaching routers from outside your home

If you set them up over the internet, use the host names or public
addresses, and the WAN SSH port.

```sh
ROUTER_A_HOST="my-router-a.example-ddns.com"
ROUTER_A_PORT="2222"

ROUTER_B_HOST="my-router-b.example-ddns.com"
ROUTER_B_PORT="2222"

SSH_KEY="~/.ssh/id_ed25519"
```

Two warnings:

1. Turn on `LAN + WAN` SSH only if you use key login and a non-standard
   port. Never with a password only.
2. Do the install from a connection that does **not** go through either
   router's Wi-Fi. A phone hotspot works well. Changing Wi-Fi settings
   disconnects Wi-Fi clients, and you would cut your own line mid-install.

---

## Example 4 - Encrypt the traffic with a VPN on top

The bridge radio has no password, so traffic across it can be read. To fix
that, build a WireGuard tunnel between the two link addresses and let the
tunnel carry the LAN traffic.

Set up the bridge normally first and confirm it works. Then set:

```sh
ROUTE_OVERRIDE=" "
```

This stops the bridge from adding the LAN route, so the tunnel can own the
routing instead. Point your WireGuard endpoint at `192.168.255.1` (or `.2`)
and route your remote subnet through it.

Only do this after the plain bridge works. Fix one thing at a time.

---

## Not sure which one to take?

Take example 1. Get it working. Change one thing at a time afterwards, and
run `./deploy.sh status` after each change.

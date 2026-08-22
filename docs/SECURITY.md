# Security - Please Read Before You Install

This page is honest about what this setup protects and what it does not.

## The short version

* The bridge radio has **no password**. This is forced by the hardware.
* Someone nearby **can listen** to traffic crossing the bridge.
* Someone getting **into your network** through it is made hard, but it is
  not impossible.
* If that is not acceptable for you, use a cable or a powerline adapter.

## Why is there no password?

WDS on ASUS Broadcom hardware only works with open authentication.

This was tested, not guessed. With WPA2 turned on, both sides show the
radio up and on the right channel, but the link never forms: 100% packet
loss, and the peer state stays empty. Switch back to open, and the link
comes up again within seconds.

So: open is not laziness. It is the only setting that works.

## What could an attacker do?

**Listen to traffic.** Yes. Anything crossing the bridge can be captured by
someone with a Wi-Fi card nearby.

* Safe anyway: SSH, HTTPS, VPN tunnels, `kubectl`. These protect themselves.
* Not safe: plain file shares (SMB, NFS), printer jobs, plain HTTP, DNS.

If you move private files between the two sides, put a VPN on top. A
WireGuard tunnel across the link network is a good fit and costs little
speed.

**Get into your network.** This setup makes it hard, with two layers.

### Layer 1 - the open radio leads nowhere

This is the important one.

The bridge radio is an open access point. Normally that access point sits
inside `br0` - your home network. Anyone who connects would get a DHCP
address and be fully inside.

So we take the radio interface **out of `br0`**:

```sh
brctl delif br0 <radio-interface>
```

Now someone who connects lands in no bridge at all. No address, no route,
nothing to talk to. The bridge itself is unaffected, because the bridge
traffic runs over the separate WDS interface in `br10`.

A cron job enforces this every minute, because the firmware puts the radio
back into `br0` after every Wi-Fi restart.

### Layer 2 - MAC filter

Only the other router's MAC address is allowed on that radio.

Be clear about what this is worth: MAC addresses travel unencrypted in
every frame. Someone listening can read the allowed address and copy it.
This stops a curious neighbour. It does not stop a determined attacker.

### What is left

A determined attacker with the right equipment could copy the peer MAC and
associate. They would then be in `br10` - the link network - which **is**
routed to both homes.

So the honest summary: this is good protection against people nearby who
notice an open network. It is not protection against someone who is
specifically targeting you.

## Making it stronger

**Best: do not use radio.** A cable is better. If you cannot run a cable,
powerline adapters use your electrical wiring, are AES encrypted, and are
usually faster. Then you do not need any of this.

**Good: put a VPN on top.** Run WireGuard between `192.168.255.1` and
`192.168.255.2` and route the LAN traffic through it. Then set
`ROUTE_OVERRIDE=""` in `setup.conf` so the tunnel handles routing. Now
listening gives an attacker nothing.

**Also worth doing:** keep firewalls on your important machines switched on
and set to allow only the other subnet. The router routes, but each machine
decides for itself what it accepts.

## What this setup never does

* It does not touch the firmware or the flash partitions.
* It does not add NAT, so addresses stay real across the bridge.
* It does not open anything towards the internet.
* It does not delete your existing scripts - it only appends one marked
  line, and removes exactly that line on uninstall.
* It saves all changed settings before changing them.

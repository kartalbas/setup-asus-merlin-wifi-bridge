# Wi-Fi Bridge for Two ASUS Merlin Routers

Connect two ASUS routers over Wi-Fi. Each router keeps its **own** network,
its own DHCP, and its own internet line. Computers on one side can talk to
computers on the other side. No cable between the routers is needed.

You run one command from your computer. It sets up both routers over SSH.

```
   Router A                                      Router B
   home network 192.168.0.0/24                   home network 192.168.10.0/24
   link IP 192.168.255.1  <---- Wi-Fi ---->      link IP 192.168.255.2
```

Real result from a working setup (two ASUS GT-AX6000, 2.4 GHz, 20 MHz wide,
one wall between them): **12 MB/s (108 Mbit/s), 2-8 ms delay, no packet loss.**

---

## Is this for me?

**Use this if:**

* You have two ASUS routers with [Asuswrt-Merlin](https://www.asuswrt-merlin.net/) firmware.
* You cannot pull a network cable between them.
* You want two **separate** networks that can still reach each other.
* You do **not** want a mesh, a repeater, or a media bridge. Both boxes stay
  full routers.

**Do not use this if:**

* You can pull a cable. A cable is always better. Use the cable.
* You want one single big network. Then use AiMesh instead - it is easier.
* Your routers are not Broadcom-based. This needs the `wl` command.

---

## Before you start: read this once

This is the honest part. Please do not skip it.

**1. One radio stops being normal Wi-Fi.**
The radio you pick (2.4 GHz or 5 GHz) becomes the bridge. Devices that can
only use that radio will lose their Wi-Fi. On 2.4 GHz this often means
printers, robot vacuums, and smart home plugs. Plan for this. A cheap extra
access point on a LAN port brings them back.

**2. The bridge radio has no password.**
This is not our choice. ASUS hardware refuses to build this kind of link
with WPA2. We tested it: the link dies every time. So the radio runs open.

Two things protect you, and this setup turns both on by default:

* The open radio is **cut out of your home network**. If somebody connects
  to it, they get nothing: no address, no access, nowhere to go.
* Only the other router's MAC address is allowed on that radio.

What stays true anyway: **someone nearby can listen to the traffic that
crosses the bridge.** SSH, HTTPS and VPN traffic stay safe because they
protect themselves. Plain file shares and printer traffic do not.
Please read [docs/SECURITY.md](docs/SECURITY.md) before you decide.

---

## What you need

* Two ASUS routers running Asuswrt-Merlin firmware.
* **SSH turned on** on both routers (one minute each, see below).
* A Mac or Linux computer that can reach both routers over SSH.
* The two routers must use **different** home networks.
  For example `192.168.0.x` and `192.168.10.x`.
  If both use `192.168.1.x`, change one of them first.

### Turn on SSH (do this on both routers)

1. Open the router web page.
2. Go to **Administration** -> **System**.
3. Set **Enable SSH** to `LAN only` (or `LAN + WAN` if you set it up from
   outside your home).
4. Write down the **SSH port** (often `22`).
5. Click **Apply**.

Test it from your computer. Replace the address and port with yours:

```sh
ssh -p 22 admin@192.168.0.1 "echo it works"
```

If you see `it works`, you are ready.

---

## Install it

```sh
git clone https://github.com/kartalbas/setup-asus-merlin-wifi-bridge.git
cd setup-asus-merlin-wifi-bridge

cp setup.conf.example setup.conf
nano setup.conf          # fill in how to reach your two routers

./deploy.sh check        # looks at both routers, changes NOTHING
./deploy.sh install      # does the real work
```

That is all. `deploy.sh check` prints exactly what it will change before
anything happens. Run it as often as you like - it is always safe.

### What you must fill in

Only the top of `setup.conf`:

```sh
ROUTER_A_HOST="192.168.0.1"
ROUTER_A_USER="admin"
ROUTER_A_PORT="22"

ROUTER_B_HOST="192.168.10.1"
ROUTER_B_USER="admin"
ROUTER_B_PORT="22"
```

Everything else has good defaults. You do **not** need to look up MAC
addresses or network numbers - the script reads them from the routers.

---

## Check that it works

```sh
./deploy.sh status
```

You want to see `OK` on all ten lines, on both routers.

```sh
./deploy.sh speedtest
```

This sends real data across the link and tells you the speed in MB/s.

Then test it yourself from a computer on one side:

```sh
ping 192.168.10.1          # the other router
traceroute 192.168.10.5    # a computer on the other side
```

`traceroute` should show two hops: your own router, then the other one.

---

## All commands

| Command | What it does |
|---|---|
| `./deploy.sh check` | Look at both routers and show the plan. Changes nothing. |
| `./deploy.sh install` | Set up the bridge on both routers. |
| `./deploy.sh status` | Ten health checks on each router. |
| `./deploy.sh speedtest` | Measure the real speed. |
| `./deploy.sh logs` | Show recent messages from both routers. |
| `./deploy.sh uninstall` | Remove it and put the old settings back. |

---

## If something does not work

Start with `./deploy.sh status`. It tells you which of the ten checks
failed and what to do.

The most common problems:

| What you see | Why | Fix |
|---|---|---|
| The two radios never connect | They are on different channels | Both must use the same channel. Run `./deploy.sh check`. |
| Radio is DOWN, nothing connects | Mode is "WDS only" | Must be "AP + WDS". See [FINDINGS](docs/FINDINGS.md). |
| Channel keeps changing by itself | AiMesh is still on | Set `DISABLE_AIMESH="yes"` and install again. |
| Worked, then stopped after a Wi-Fi restart | The repair job is missing | `./deploy.sh status` line 10. |
| Devices get an address from the wrong router | The link landed in `br0` | `./deploy.sh status` line 5. |

Full list: [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)

---

## Remove it

```sh
./deploy.sh uninstall
```

This puts your old Wi-Fi settings back from the backup that was made
during install, and deletes the scripts. Restart both routers afterwards.

Nothing here touches the firmware or the flash partitions. If SSH ever
stops working, hold the reset button for 10 seconds and load a saved
`.cfg` backup.

---

## Documentation

* [How it works](docs/HOW-IT-WORKS.md) - the idea behind it, in plain words
* [Security](docs/SECURITY.md) - what is protected, what is not
* [Troubleshooting](docs/TROUBLESHOOTING.md) - every error and its fix
* [All SSH commands](docs/MANUAL-SSH-COMMANDS.md) - every single command,
  so you can do it by hand and understand each step
* [Findings](docs/FINDINGS.md) - the four traps we hit, and why the
  scripts are built the way they are

---

## License

MIT. See [LICENSE](LICENSE). Use it, change it, share it.

This is not an official ASUS project. Use at your own risk.

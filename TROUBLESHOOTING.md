# NetGo Hub - Requirements & Troubleshooting

## Machine requirements

The hub must run on a **persistent VM with a public IP** (IPsec needs the kernel's
XFRM stack and BGP routing, so serverless or containers are not suitable).

Minimum:
- **OS**: Ubuntu 22.04 / 24.04 LTS or Debian 12 (systemd-based).
- **Arch**: x86_64 or aarch64 (ARM64). The installer auto-detects it.
- **CPU / RAM**: 1 vCPU and 1 GB RAM is enough for the hub and enrollment service.
  Note: a local Rust build (when `--binaries-url` is not used) is CPU/RAM heavy and
  slow on 1 GB; 2 GB makes the first install more comfortable. Pre-built binaries
  avoid this entirely.
- **Disk**: 10 GB.
- **Network**: a routable public IPv4 reaching the VM, with inbound
  **UDP 500**, **UDP 4500** (IKE / NAT-T) and **TCP 8443** (enrollment) open in any
  upstream firewall / security group / NAT port-forwarding.
- **Privileges**: root (sudo) to run the installer.

The VM is the single unit: VPN (strongSwan), routing (FRR/BGP), enrollment service,
and the local PKI all live on it. One VM per hub.

> If testing from behind NAT: the VM cannot always reach its own public IP
> (hairpin NAT). Verify the frontal locally with
> `curl -k https://127.0.0.1:8443/health` (expect `ok`); external clients reach it
> through the public IP.

## Post-install checks

Run these right after installation (no FortiGate connected yet):

```bash
# Enrollment frontal is up (use localhost if the VM is behind NAT):
curl -k https://127.0.0.1:8443/health          # expect: ok

# VPN connections are loaded:
sudo swanctl --list-conns 2>/dev/null | grep -E 'fgt|ios-rw'

# BGP daemon is running (no neighbors yet is expected):
sudo vtysh -c 'show bgp summary'

# Base firewall is in place:
sudo iptables-nft -L FORWARD -n --line-numbers | head    # line 1 -> NETGO-FWD
sudo iptables-nft -L INPUT -n | grep -E '500|4500|8443'
```

## Verifying a FortiGate spoke connection

A FortiGate must **initiate** the tunnel (the hub is passive: `start_action = none`).
On the FortiGate side use: IKEv2, remote gateway = hub public IP, Local ID = `fgt-1`
(then `fgt-2`, ...), peer/remote ID = `mgmt-fgt-hub`, PSK = the value printed at the
end of the install, proposals AES256-GCM / PRF-SHA256 / DH14, phase2 selectors
0.0.0.0/0, and `auto-negotiate enable`.

Watch the tunnel come up (two terminals on the hub):

```bash
# Terminal 1 - live IKE negotiation:
sudo journalctl -u strongswan-starter -f
# (service may be 'strongswan' on some distros; the installer prints which one)

# Terminal 2 - IKE packets arriving (replace ens18 with your WAN interface):
sudo tcpdump -ni ens18 port 500 or port 4500
```

Then bring the tunnel up on the FortiGate and run the checks below.

### Diagnostic checks (FortiGate spoke)

```bash
# Is the tunnel established?
sudo swanctl --list-sas 2>/dev/null | grep -A3 fgt

# Did the updown hook create the per-FGT XFRM interface? (fgt-1 -> ipsec1)
ip link show ipsec1
ip addr show ipsec1

# Did the dynamic forwarding rules appear in NETGO-FWD?
sudo iptables-nft -L NETGO-FWD -n -v

# Was BGP port 179 opened on the tunnel interface?
sudo iptables-nft -L INPUT -n | grep 179

# Is the BGP session establishing?
sudo vtysh -c 'show bgp summary'
sudo vtysh -c 'show ip route bgp'
```

### Expected results

| Check | Expected when FGT `fgt-1` is connected |
|-------|-----------------------------------------|
| `swanctl --list-sas` | `fgt` SA `ESTABLISHED`, remote id `fgt-1` |
| `ip link show ipsec1` | interface `ipsec1` present, UP |
| `ip addr show ipsec1` | address `10.255.0.1/32` |
| `NETGO-FWD` rules | `-s <pool> -o ipsec1 ACCEPT` and `-d <pool> -i ipsec1 ACCEPT` |
| INPUT port 179 | `ACCEPT tcp dpt:179 in ipsec1` |
| `show bgp summary` | neighbor `10.255.0.2` state `Established` |

If `ipsec1` never appears, the hook did not run: check
`journalctl -t fgt-updown` for the Local ID it received (it must match `fgt-<N>`).

## Common issues

- **No IKE packets in tcpdump**: traffic is not reaching the hub. Check upstream
  firewall / security group / NAT forwarding for UDP 500 and 4500 to the VM.
- **`ipsec1` missing after tunnel up**: the FortiGate Local ID is not `fgt-<N>`.
  The hook parses `fgt-1`, `fgt-2`, ... from `PLUTO_PEER_ID`; anything else is
  ignored. Check `journalctl -t fgt-updown`.
- **BGP stuck in Active/Connect**: the tunnel or the host route to the FGT is
  missing. Confirm `ipsec1` has `10.255.0.1/32` and there is a `/32` route to the
  peer (`ip route get 10.255.0.2`).
- **Frontal not responding externally but OK on localhost**: hairpin NAT or a
  closed TCP 8443 upstream. Test from an external client, open 8443 inbound.
- **strongSwan service name**: it is `strongswan` on some systems and
  `strongswan-starter` on others. The installer detects and prints the right one.

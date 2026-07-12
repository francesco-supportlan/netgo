# netgo-hub: deploy a NetGo hub in one command

Installs a complete hub on a fresh Ubuntu/Debian VM: multi-FortiGate IKEv2 VPN
(strongSwan + FRR/BGP), iOS road warrior (EAP secret-per-device), enrollment service
(Sign in with Apple + QR), local PKI, firewall. Portable (any VM, any arch).

## Machine requirements

Persistent VM with a public IP (IPsec needs the kernel XFRM stack; serverless and
containers are not suitable).

- OS: Ubuntu 22.04/24.04 LTS or Debian 12 (systemd).
- Arch: x86_64 or aarch64 (auto-detected).
- 1 vCPU / 1 GB RAM / 10 GB disk (2 GB RAM recommended if building binaries locally).
- Public IPv4 with inbound UDP 500, UDP 4500, TCP 8443 open upstream.
- Root (sudo) to run the installer.

See `TROUBLESHOOTING.md` for post-install checks, FortiGate spoke verification, and
common issues.

## Deployment

On the fresh VM (single command):

    curl -fsSL https://raw.githubusercontent.com/francesco-supportlan/netgo/main/deploy/netgo-install-hub.sh \
      | sudo bash -s -- --ip <public_ip>

The script detects the architecture and downloads the matching pre-built binaries
from the latest release. `--ip` is optional (auto-detected if omitted).

Options:

    --ip <address>          public IP (auto-detected if omitted)
    --wan <iface>           WAN interface (default route if omitted)
    --binaries-url <url>    override the source of the pre-built binaries
    --org <name>            certificate organization (default NetGo)
    --pool <cidr>           road warrior pool (default 10.8.0.0/24)
    --pool-range <a-b>      explicit pool range (derived from --pool otherwise)

BGP / topology (defaults match the reference hub; override only if they collide
with your existing addressing or AS numbering):

    --psk-id <id>           FortiGate peer/PSK identity (default mgmt-fgt-hub)
    --rw-subnet <cidr>      management subnet advertised to clients (default 100.127.255.0/24)
    --vti-net <prefix>      BGP transit /24 prefix without last octet (default 10.255.0)
    --hub-as <n>            hub BGP AS number (default 65000)
    --spoke-as <n>          FortiGate spokes BGP AS number (default 65001)

Example with a custom pool and AS numbers:

    curl -fsSL https://raw.githubusercontent.com/francesco-supportlan/netgo/main/deploy/netgo-install-hub.sh \
      | sudo bash -s -- --ip 203.0.113.10 --pool 192.168.50.0/24 --hub-as 64512 --spoke-as 64513

At the end, the script prints the FortiGate PSK (to configure on each FGT) and the
root_fp (used in enrollment QR codes).

## PKI model

Self-contained per hub: root + intermediate generated locally on the VM. Each hub is
its own authority. The app pins this hub's root_fp via the QR code.

## Layout

    deploy/netgo-install-hub.sh   the install command
    TROUBLESHOOTING.md            requirements and diagnostics

## After installation

    sudo netgo-enroll-qr --label "Name" --ttl-hours 72   # activation token + QR
    curl -k https://127.0.0.1:8443/health                # health (use localhost if behind NAT)
    sudo swanctl --list-conns 2>/dev/null                # VPN connections

## Retrait propre, garde les données (pour réinstaller ensuite)
    sudo ./netgo-uninstall-hub.sh

## Tout effacer
    sudo ./netgo-uninstall-hub.sh --purge

## Sans confirmation (tests automatisés)
    sudo ./netgo-uninstall-hub.sh --purge --yes

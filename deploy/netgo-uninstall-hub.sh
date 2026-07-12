#!/usr/bin/env bash
# netgo-uninstall-hub.sh
# Removes a NetGo hub installed by netgo-install-hub.sh.
#
# Use --purge to also delete the data and PKI (irreversible: enrolled devices,
# master key and the hub root key are lost).
#
# Usage:
#   sudo ./netgo-uninstall-hub.sh [--purge] [--yes]

set -uo pipefail 

PURGE=0
ASSUME_YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --purge) PURGE=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1"; exit 1 ;;
  esac
done

say()  { echo -e "\n\033[1;36m== $*\033[0m"; }
ok()   { echo -e "  \033[32mok\033[0m $*"; }
warn() { echo -e "  \033[33m! \033[0m $*"; }

[[ $EUID -eq 0 ]] || { echo "must run as root (sudo)."; exit 1; }

# Locations (must match the installer)
PKI_DIR="/etc/netgo/pki"
FRONTAL_DIR="/etc/netgo/frontal"
STATE_DIR="/var/lib/netgo"
EAP_DIR="/var/lib/netgo/eap"
BIN_DIR="/usr/local/bin"
SBIN_DIR="/usr/local/sbin"
POOL_CIDR="10.8.0.0/24"   # default; adjust if a custom --pool was used

echo "This will remove the NetGo hub from this machine."
if [[ $PURGE -eq 1 ]]; then
  echo "MODE: --purge  (ALSO deletes $STATE_DIR and $PKI_DIR: DB, master key, root key)"
else
  echo "MODE: keep data ($STATE_DIR and $PKI_DIR are preserved)"
fi
if [[ $ASSUME_YES -ne 1 ]]; then
  read -r -p "Continue? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "aborted."; exit 0; }
fi

# ---------------------------------------------------------------------------
# 1. Stop and disable services
# ---------------------------------------------------------------------------
say "Stopping services"
for unit in netgo-frontal netgo-signer netgo-eap-reload.path netgo-eap-reload.service ipsec-hub.service; do
  systemctl stop "$unit" 2>/dev/null && ok "stopped $unit" || true
  systemctl disable "$unit" 2>/dev/null || true
done


# ---------------------------------------------------------------------------
# 2. Remove systemd units
# ---------------------------------------------------------------------------
say "Removing systemd units"
for f in netgo-frontal.service netgo-signer.service \
         netgo-eap-reload.service netgo-eap-reload.path ipsec-hub.service; do
  rm -f "/etc/systemd/system/$f" && ok "removed $f" || true
done
systemctl daemon-reload

# ---------------------------------------------------------------------------
# 3. Remove strongSwan config added by NetGo, then reload
# ---------------------------------------------------------------------------
say "Removing strongSwan config"
rm -f /etc/swanctl/conf.d/fgt.conf \
      /etc/swanctl/conf.d/roadwarrior.conf \
      /etc/swanctl/conf.d/netgo-eap-secrets.conf \
      /etc/swanctl/x509/server-cert.pem \
      /etc/swanctl/private/server-key.pem \
      /etc/swanctl/x509ca/netgo-intermediate.pem \
      /etc/swanctl/x509ca/netgo-root.pem \
      /etc/strongswan.d/99-netgo-quiet.conf

if [[ -f /etc/swanctl/swanctl.conf ]]; then
  sed -i '\#include /var/lib/netgo/eap/secrets.conf#d' /etc/swanctl/swanctl.conf 2>/dev/null || true
fi

swanctl --load-all >/dev/null 2>&1 || true
ok "strongSwan config removed"

# ---------------------------------------------------------------------------
# 4. Remove FRR/BGP config added by NetGo
# ---------------------------------------------------------------------------
say "Removing FRR config"

if [[ -f /etc/frr/frr.conf ]]; then
  : > /etc/frr/frr.conf
fi
if [[ -f /etc/frr/daemons ]]; then
  sed -i 's/^bgpd=yes/bgpd=no/' /etc/frr/daemons 2>/dev/null || true
fi
systemctl restart frr 2>/dev/null || true
ok "FRR config reset"

# ---------------------------------------------------------------------------
# 5. Remove network config (sysctl, firewall, interfaces)
# ---------------------------------------------------------------------------
say "Removing network config"
rm -f /etc/sysctl.d/99-netgo.conf && ok "removed sysctl drop-in" || true


iptables-nft -D FORWARD -j NETGO-FWD 2>/dev/null || true
iptables-nft -F NETGO-FWD 2>/dev/null || true
iptables-nft -X NETGO-FWD 2>/dev/null || true

iptables-nft -D INPUT -p udp --dport 500  -j ACCEPT 2>/dev/null || true
iptables-nft -D INPUT -p udp --dport 4500 -j ACCEPT 2>/dev/null || true
iptables-nft -D INPUT -p tcp --dport 8443 -j ACCEPT 2>/dev/null || true

iptables-nft -t mangle -D FORWARD -s "$POOL_CIDR" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1300 2>/dev/null || true
iptables-nft -t mangle -D FORWARD -d "$POOL_CIDR" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1300 2>/dev/null || true

for ifc in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^ipsec[0-9]+$' || true); do
  ip link del "$ifc" 2>/dev/null && ok "removed interface $ifc" || true
done
ip link del dummy-pool 2>/dev/null && ok "removed dummy-pool" || true

netfilter-persistent save >/dev/null 2>&1 || true
ok "network config removed"

# ---------------------------------------------------------------------------
# 6. Remove binaries and helper scripts
# ---------------------------------------------------------------------------
say "Removing binaries and scripts"
rm -f "$BIN_DIR/netgo-signer" "$BIN_DIR/netgo-frontal" "$BIN_DIR/netgo-enroll-qr"
rm -f "$SBIN_DIR/fgt-updown.sh" "$SBIN_DIR/ipsec-hub.sh" "$SBIN_DIR/rw-route.sh"
ok "binaries and scripts removed"

# ---------------------------------------------------------------------------
# 7. Frontal TLS (always removable; not user data)
# ---------------------------------------------------------------------------
rm -rf "$FRONTAL_DIR"

# ---------------------------------------------------------------------------
# 8. Data and PKI: kept unless --purge
# ---------------------------------------------------------------------------
if [[ $PURGE -eq 1 ]]; then
  say "Purging data and PKI"
  rm -rf "$STATE_DIR" && ok "removed $STATE_DIR (DB, master key)" || true
  rm -rf "$PKI_DIR"   && ok "removed $PKI_DIR (root + intermediate keys)" || true
  rmdir /etc/netgo 2>/dev/null || true
  # Remove system users only on purge.
  userdel netgo-signer 2>/dev/null && ok "removed user netgo-signer" || true
  userdel netgo-api    2>/dev/null && ok "removed user netgo-api" || true
  groupdel netgo       2>/dev/null || true
else
  say "Keeping data and PKI"
  warn "Kept $STATE_DIR (enrollment DB, master key)"
  warn "Kept $PKI_DIR (root + intermediate keys)"
  warn "System users netgo-signer / netgo-api kept. Use --purge to remove everything."
fi

say "Uninstall complete"
if [[ $PURGE -eq 1 ]]; then
  echo "  The hub and all its data have been removed."
else
  echo "  The hub was removed; data and PKI were preserved for a future reinstall."
  echo "  Run with --purge to erase them as well."
fi
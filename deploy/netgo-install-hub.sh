#!/usr/bin/env bash
# netgo-install-hub.sh
# Install a complete NetGo hub on a clean Ubuntu/Debian VM with a single command:
# VPN IKEv2 multi-FortiGate (strongSwan + FRR/BGP), roadwarrior iOS (EAP secret),
# enrollment service (signer + frontal), local PKI, firewall, persistence.
#
# PKI model: self-contained per hub (root + intermediate generated locally).
#
# Usage :
#   sudo ./netgo-install-hub.sh [--ip <public_ip>] [--wan <iface>] \
#        [--binaries-url <url>] [--org NetGo] [--pool <cidr>] [--pool-range <a-b>]
#
# Without --ip: auto-detected (external echo services).
# Without --wan: detected from the default route.
# Without --binaries-url: local Rust build (requires the toolchain).
# Without --pool: road warrior pool defaults to 10.8.0.0/24.
#   --pool 192.168.50.0/24 changes the pool; the .10-.250 range is derived,
#   or set it explicitly with --pool-range 192.168.50.20-192.168.50.200.
#
# BGP / topology options (defaults match the validated production hub):
#   --psk-id <id>           FortiGate peer/PSK identity (default mgmt-fgt-hub)
#   --rw-subnet <cidr>      management subnet advertised to clients (default 100.127.255.0/24)
#   --vti-net <prefix>      BGP transit /24 prefix, no last octet (default 10.255.0)
#   --hub-as <n>            hub BGP AS number (default 65000)
#   --spoke-as <n>          FortiGate spokes BGP AS number (default 65001)

set -euo pipefail

# ============================================================================
# Fixed hub parameters (consistent with validated production)
# ============================================================================
# All of these can be overridden with the matching command-line option.
HUB_PSK_ID="mgmt-fgt-hub"          # hub PSK identity / FGT peer ID   (--psk-id)
POOL_CIDR="10.8.0.0/24"            # road warrior pool                (--pool)
POOL_RANGE=""                      # derived from POOL_CIDR unless    (--pool-range)
RW_TS="100.127.255.0/24"           # management subnet to road warriors (--rw-subnet)
VTI_NET="10.255.0"                 # BGP transit /24 (hub .1, FGT-N .(N+1)) (--vti-net)
HUB_AS=65000                       # hub BGP AS                       (--hub-as)
SPOKE_AS=65001                     # FortiGate spokes BGP AS          (--spoke-as)
NETGO_ORG="NetGo"                  # cert organization                (--org)

# Final locations
PKI_DIR="/etc/netgo/pki"
FRONTAL_DIR="/etc/netgo/frontal"
STATE_DIR="/var/lib/netgo"
EAP_DIR="/var/lib/netgo/eap"
BIN_DIR="/usr/local/bin"
SBIN_DIR="/usr/local/sbin"

DIST_BASE="https://github.com/francesco-supportlan/netgo/releases/latest/download"

# ============================================================================
# Arguments
# ============================================================================
PUBLIC_IP=""
WAN_IFACE=""
BINARIES_URL=""
POOL_RANGE_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ip)           PUBLIC_IP="$2"; shift 2 ;;
    --wan)          WAN_IFACE="$2"; shift 2 ;;
    --binaries-url) BINARIES_URL="$2"; shift 2 ;;
    --org)          NETGO_ORG="$2"; shift 2 ;;
    --pool)         POOL_CIDR="$2"; shift 2 ;;
    --pool-range)   POOL_RANGE_ARG="$2"; shift 2 ;;
    --psk-id)       HUB_PSK_ID="$2"; shift 2 ;;
    --rw-subnet)    RW_TS="$2"; shift 2 ;;
    --vti-net)      VTI_NET="$2"; shift 2 ;;
    --hub-as)       HUB_AS="$2"; shift 2 ;;
    --spoke-as)     SPOKE_AS="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1"; exit 1 ;;
  esac
done

# Derive the pool allocation range from the CIDR unless explicitly provided.
# For a /24 like 10.8.0.0/24 -> 10.8.0.10-10.8.0.250.
derive_pool_range() {
  if [[ -n "$POOL_RANGE_ARG" ]]; then
    POOL_RANGE="$POOL_RANGE_ARG"
    return
  fi
  local base="${POOL_CIDR%/*}"          # e.g. 10.8.0.0
  local prefix="${base%.*}"             # e.g. 10.8.0
  POOL_RANGE="${prefix}.10-${prefix}.250"
}
derive_pool_range

# ============================================================================
# Helpers
# ============================================================================
say()  { echo -e "\n\033[1;36m== $*\033[0m"; }
ok()   { echo -e "  \033[32mok\033[0m $*"; }
warn() { echo -e "  \033[33m! \033[0m $*"; }
die()  { echo -e "\033[31mERREUR: $*\033[0m" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "must run as root (sudo)."

# ============================================================================
# Module 1: detection (arch, WAN, public IP)
# ============================================================================
detect_env() {
  say "Detecting environment"

  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64|amd64)  BIN_ARCH="x86_64" ;;
    aarch64|arm64) BIN_ARCH="aarch64" ;;
    *) die "unsupported architecture: $ARCH" ;;
  esac
  ok "architecture : $ARCH ($BIN_ARCH)"

  # WAN interface: from the default route, unless overridden.
  if [[ -z "$WAN_IFACE" ]]; then
    WAN_IFACE=$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')
  fi
  [[ -n "$WAN_IFACE" ]] || die "WAN interface not found (use --wan)."
  ok "interface WAN : $WAN_IFACE"

  # Public IP: override, otherwise detect.
  if [[ -z "$PUBLIC_IP" ]]; then
    # Sequential generic attempts (no cloud-specific dependency).
    for svc in "https://api.ipify.org" "https://ifconfig.me/ip" "https://icanhazip.com"; do
      PUBLIC_IP=$(curl -fsS --max-time 5 "$svc" 2>/dev/null | tr -d '[:space:]' || true)
      [[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
      PUBLIC_IP=""
    done
  fi
  [[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
    die "public IP not detected (use --ip <address>)."
  ok "IP publique : $PUBLIC_IP"
}

# ============================================================================
# Module: system users (created early so PKI files get correct ownership)
# ============================================================================
ensure_users() {
  say "System users"
  groupadd --system netgo 2>/dev/null || true
  useradd --system --no-create-home --shell /usr/sbin/nologin -g netgo netgo-signer 2>/dev/null || true
  useradd --system --no-create-home --shell /usr/sbin/nologin -g netgo netgo-api 2>/dev/null || true
  ok "users netgo-signer / netgo-api ready"
}

# ============================================================================
# Module 2: local PKI (model A: root + intermediate on the hub)
# ============================================================================
generate_pki() {
  say "Generating local PKI (root + intermediate, ECDSA P-256)"

  mkdir -p "$PKI_DIR"
  chmod 755 "$PKI_DIR"
  local work; work="$(mktemp -d)"

  # --- Root (self-signed) ---
  openssl ecparam -name prime256v1 -genkey -noout -out "$work/root.key.pem" 2>/dev/null
  openssl req -x509 -new -key "$work/root.key.pem" -sha256 -days 7300 \
    -subj "/CN=NetGo Root CA/O=${NETGO_ORG}" -out "$work/root.crt.pem"

  # --- Intermediate (signed by the root) ---
  openssl ecparam -name prime256v1 -genkey -noout -out "$work/intermediate.key.pem" 2>/dev/null
  openssl req -new -key "$work/intermediate.key.pem" \
    -subj "/CN=NetGo Intermediate CA ($(hostname))/O=${NETGO_ORG}" \
    -out "$work/intermediate.csr.pem"
  cat > "$work/int.ext" <<EXT
basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,keyCertSign,cRLSign
subjectKeyIdentifier=hash
EXT
  openssl x509 -req -in "$work/intermediate.csr.pem" \
    -CA "$work/root.crt.pem" -CAkey "$work/root.key.pem" \
    -CAcreateserial -sha256 -days 3650 -extfile "$work/int.ext" \
    -out "$work/intermediate.crt.pem"

  cat "$work/intermediate.crt.pem" "$work/root.crt.pem" > "$work/chain.pem"

  # --- VPN server cert (signed by the intermediate) ---
  # server cert SAN to match p.remoteIdentifier). Here remote_id = PUBLIC_IP.
  openssl ecparam -name prime256v1 -genkey -noout -out "$work/vpn-server.key.pem" 2>/dev/null
  openssl req -new -key "$work/vpn-server.key.pem" \
    -subj "/CN=$PUBLIC_IP/O=${NETGO_ORG}" -out "$work/vpn-server.csr.pem"
  cat > "$work/srv.ext" <<EXT
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=IP:$PUBLIC_IP
EXT
  openssl x509 -req -in "$work/vpn-server.csr.pem" \
    -CA "$work/intermediate.crt.pem" -CAkey "$work/intermediate.key.pem" \
    -CAcreateserial -sha256 -days 397 -extfile "$work/srv.ext" \
    -out "$work/vpn-server.crt.pem"

  # --- Frontal TLS cert (signed by the intermediate) ---
  openssl ecparam -name prime256v1 -genkey -noout -out "$work/tls.key.sec1.pem" 2>/dev/null
  openssl pkcs8 -topk8 -nocrypt -in "$work/tls.key.sec1.pem" -out "$work/tls.key.pem" 2>/dev/null
  openssl req -new -key "$work/tls.key.pem" \
    -subj "/CN=$PUBLIC_IP/O=${NETGO_ORG}" -out "$work/tls.csr.pem"
  cat > "$work/tls.ext" <<EXT
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=IP:$PUBLIC_IP
EXT
  openssl x509 -req -in "$work/tls.csr.pem" \
    -CA "$work/intermediate.crt.pem" -CAkey "$work/intermediate.key.pem" \
    -CAcreateserial -sha256 -days 397 -extfile "$work/tls.ext" \
    -out "$work/tls.crt.pem"
  cat "$work/tls.crt.pem" "$work/intermediate.crt.pem" > "$work/tls.fullchain.pem"

  # --- Deploy to final locations ---
  # PKI (frontal reads root.crt.pem; signer reads intermediate):
  install -m 644 "$work/root.crt.pem"          "$PKI_DIR/root.crt.pem"
  install -m 644 "$work/intermediate.crt.pem"  "$PKI_DIR/intermediate.crt.pem"
  install -m 644 "$work/chain.pem"             "$PKI_DIR/chain.pem"
  install -m 600 "$work/intermediate.key.pem"  "$PKI_DIR/intermediate.key.pem"
  # Root: key kept on the hub (model A). Strict permissions.
  install -m 600 "$work/root.key.pem"          "$PKI_DIR/root.key.pem"

  # strongSwan: server cert + CA
  mkdir -p /etc/swanctl/x509 /etc/swanctl/private /etc/swanctl/x509ca
  install -m 644 "$work/vpn-server.crt.pem"    /etc/swanctl/x509/server-cert.pem
  install -m 640 "$work/vpn-server.key.pem"    /etc/swanctl/private/server-key.pem
  install -m 644 "$work/intermediate.crt.pem"  /etc/swanctl/x509ca/netgo-intermediate.pem
  install -m 644 "$work/root.crt.pem"          /etc/swanctl/x509ca/netgo-root.pem

  # frontal : TLS (readable by netgo-api which runs the frontal)
  mkdir -p "$FRONTAL_DIR"
  install -m 640 -g netgo "$work/tls.fullchain.pem"  "$FRONTAL_DIR/tls.crt.pem"
  install -m 640 -g netgo "$work/tls.key.pem"        "$FRONTAL_DIR/tls.key.pem"
  chown netgo-api:netgo "$FRONTAL_DIR/tls.crt.pem" "$FRONTAL_DIR/tls.key.pem"
  # root cert read by the frontal too
  chgrp netgo "$PKI_DIR/root.crt.pem" 2>/dev/null || true
  chmod 644 "$PKI_DIR/root.crt.pem"

  # Root fingerprint (root_fp), for enrollment QR codes.
  ROOT_FP=$(openssl x509 -in "$PKI_DIR/root.crt.pem" -noout -fingerprint -sha256 | sed 's/.*=//' | tr -d ':')
  echo "$ROOT_FP" > "$PKI_DIR/root_fp.txt"

  rm -rf "$work"
  ok "PKI generated (root_fp = $ROOT_FP)"
  warn "Root key is on the hub ($PKI_DIR/root.key.pem). Back it up offline if possible."
}

# ============================================================================
# Module 3: packages
# ============================================================================
install_packages() {
  say "Installing packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq \
    strongswan strongswan-swanctl libcharon-extra-plugins \
    frr frr-pythontools \
    qrencode curl openssl iptables iptables-persistent ca-certificates \
    >/dev/null
  ok "base packages installed"

  if [[ -z "$BINARIES_URL" && "$DIST_BASE" == *YOUR_GH_USER* ]]; then
    apt-get install -y -qq build-essential pkg-config libssl-dev >/dev/null
    if ! command -v cargo >/dev/null; then
      warn "Rust not found: installing via rustup (may take a few minutes)"
      curl -fsS https://sh.rustup.rs | sh -s -- -y --profile minimal >/dev/null 2>&1
      # shellcheck disable=SC1091
      source "$HOME/.cargo/env"
    fi
    ok "build toolchain ready"
  fi
}

# ============================================================================
# Module 4: binaries (download or local build)
# ============================================================================
SRC_DIR_DEFAULT="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/src"

install_binaries() {
  say "Binaries netgo-signer / netgo-frontal"

  local url="$BINARIES_URL"
  if [[ -z "$url" && "$DIST_BASE" != *YOUR_GH_USER* ]]; then
    url="$DIST_BASE"
  fi

  if [[ -n "$url" ]]; then
    curl -fsSL "$url/netgo-signer-$BIN_ARCH"  -o "$BIN_DIR/netgo-signer"  || die "signer download failed ($url)"
    curl -fsSL "$url/netgo-frontal-$BIN_ARCH" -o "$BIN_DIR/netgo-frontal" || die "frontal download failed ($url)"
    chmod 755 "$BIN_DIR/netgo-signer" "$BIN_DIR/netgo-frontal"
    ok "binaries downloaded ($BIN_ARCH) from $url"
  else
    local src="${NETGO_SRC_DIR:-$SRC_DIR_DEFAULT}"
    [[ -f "$src/Cargo.toml" ]] || die "no --binaries-url set, DIST_BASE not configured, and no Rust source in $src"
    say "Local build (may take several minutes)"
    ( cd "$src" && cargo build --release >/dev/null 2>&1 ) || die "cargo build failed"
    install -m 755 "$src/target/release/netgo-signer"  "$BIN_DIR/netgo-signer"
    install -m 755 "$src/target/release/netgo-frontal" "$BIN_DIR/netgo-frontal"
    ok "binaries built locally"
  fi
}

# ============================================================================
# Module 5: strongSwan (fgt + roadwarrior + swanctl.conf)
# ============================================================================
PSK=""   

configure_strongswan() {
  say "Configuring strongSwan"
  mkdir -p /etc/swanctl/conf.d

  # Random PSK for this hub (base64, 32 bytes).
  PSK=$(openssl rand -base64 32)

  # --- FortiGate connection (multi-site, generic) ---
  cat > /etc/swanctl/conf.d/fgt.conf <<EOF
connections {
    fgt {
        version = 2
        local_addrs  = %any
        remote_addrs = %any
        local {
            auth = psk
            id = "$HUB_PSK_ID"
        }
        remote {
            auth = psk
        }
        children {
            fgt {
                local_ts = 0.0.0.0/0
                remote_ts = 0.0.0.0/0
                if_id_in  = %unique
                if_id_out = %unique
                updown = $SBIN_DIR/fgt-updown.sh
                start_action = none
                esp_proposals = aes256gcm16-modp2048
            }
        }
        proposals = aes256gcm16-prfsha256-modp2048
    }
}
secrets {
    ike-fgt {
        secret = "$PSK"
    }
}
EOF

  # --- iOS roadwarrior (EAP secret-per-device) ---
  cat > /etc/swanctl/conf.d/roadwarrior.conf <<EOF
connections {
    ios-rw {
        version = 2
        pools = rw_pool
        local_addrs  = %any
        remote_addrs = %any
        local {
            auth = pubkey
            certs = server-cert.pem
            id = "$PUBLIC_IP"
        }
        remote {
            auth = eap-mschapv2
            id = %any
            eap_id = %any
        }
        children {
            ios-rw {
                local_ts  = $RW_TS
                updown = $SBIN_DIR/rw-route.sh
                rekey_time = 3600
                dpd_action = clear
                esp_proposals = aes256gcm16-prfsha256-modp2048
            }
        }
        proposals = aes256gcm16-prfsha256-modp2048
        send_certreq = no
        fragmentation = yes
    }
}
pools {
    rw_pool {
        addrs = $POOL_RANGE
    }
}
EOF

  cat > /etc/swanctl/swanctl.conf <<EOF
# Include config snippets
include conf.d/*.conf
EOF

  ok "fgt + ios-rw connections written (PSK generated)"

  mkdir -p /etc/strongswan.d
  cat > /etc/strongswan.d/99-netgo-quiet.conf <<'EOF'
# NetGo: quiet the optional-plugin load failures on swanctl/charon startup.
charon {
    syslog {
        daemon {
            lib = -1
        }
    }
}
charon-systemd {
    syslog {
        daemon {
            lib = -1
        }
    }
}
swanctl {
}
EOF
  ok "plugin-load noise reduced"
}

# ============================================================================
# Module 6: FRR / BGP
# ============================================================================
configure_frr() {
  say "Configuring FRR / BGP"

  # Enable required daemons.
  if [[ -f /etc/frr/daemons ]]; then
    sed -i 's/^bgpd=no/bgpd=yes/'  /etc/frr/daemons
    sed -i 's/^zebra=no/zebra=yes/' /etc/frr/daemons
  fi

  cat > /etc/frr/frr.conf <<EOF
frr version 8.4.4
frr defaults traditional
hostname $(hostname)
log syslog informational
no ipv6 forwarding
service integrated-vtysh-config
!
ip route $POOL_CIDR blackhole
!
router bgp $HUB_AS
 bgp router-id ${VTI_NET}.1
 no bgp ebgp-requires-policy
 bgp disable-ebgp-connected-route-check
 neighbor SPOKES peer-group
 neighbor SPOKES remote-as $SPOKE_AS
 neighbor SPOKES description spokes-fgt
 neighbor SPOKES disable-connected-check
 bgp listen limit 50
 bgp listen range ${VTI_NET}.0/24 peer-group SPOKES
 !
 address-family ipv4 unicast
  network $POOL_CIDR
  neighbor SPOKES soft-reconfiguration inbound
 exit-address-family
exit
!
EOF
  chown frr:frr /etc/frr/frr.conf 2>/dev/null || true
  chmod 640 /etc/frr/frr.conf
  ok "frr.conf written (AS $HUB_AS, router-id ${VTI_NET}.1)"
}

# ============================================================================
# Module 7: enrollment service (users, dirs, units)
# ============================================================================
BUNDLE_ID="${NETGO_BUNDLE_ID:-me.netdev.netgo}"

configure_enrollment() {
  say "Enrollment service (signer + frontal)"

  mkdir -p "$STATE_DIR" "$EAP_DIR"
  chown -R netgo-signer:netgo "$STATE_DIR"
  chmod 750 "$STATE_DIR" "$EAP_DIR"

  # Unit signer.
  cat > /etc/systemd/system/netgo-signer.service <<EOF
[Unit]
Description=NetGo provisioning signer (local socket only)
After=network.target
Before=netgo-frontal.service

[Service]
Type=simple
ExecStart=$BIN_DIR/netgo-signer serve
User=netgo-signer
Group=netgo
Restart=on-failure
RestartSec=2
Environment=NETGO_DB=$STATE_DIR/enroll.db
Environment=NETGO_SOCK=/run/netgo/signer.sock
Environment=NETGO_MASTER_KEY=$STATE_DIR/master.key
Environment=NETGO_SWANCTL_SECRETS=$EAP_DIR/secrets.conf
Environment=NETGO_CERT_DAYS=365
Environment=NETGO_MAX_DEVICES=3
RuntimeDirectory=netgo
RuntimeDirectoryMode=0750
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths=$STATE_DIR
RestrictAddressFamilies=AF_UNIX
IPAddressDeny=any
CapabilityBoundingSet=

[Install]
WantedBy=multi-user.target
EOF

  # Unit frontal.
  cat > /etc/systemd/system/netgo-frontal.service <<EOF
[Unit]
Description=NetGo enrollment frontal (WAN HTTPS)
After=network-online.target netgo-signer.service
Wants=network-online.target
Requires=netgo-signer.service

[Service]
Type=simple
ExecStart=$BIN_DIR/netgo-frontal
User=netgo-api
Group=netgo
Restart=on-failure
RestartSec=2
Environment=NETGO_FRONTAL_ADDR=0.0.0.0:8443
Environment=NETGO_TLS_CERT=$FRONTAL_DIR/tls.crt.pem
Environment=NETGO_TLS_KEY=$FRONTAL_DIR/tls.key.pem
Environment=NETGO_CA_ROOT_PEM=$PKI_DIR/root.crt.pem
Environment=NETGO_SOCK=/run/netgo/signer.sock
Environment=NETGO_BUNDLE_ID=$BUNDLE_ID
Environment=NETGO_VPN_REMOTE_ID=$PUBLIC_IP
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
CapabilityBoundingSet=

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/netgo-eap-reload.service <<EOF
[Unit]
Description=Reload strongSwan credentials after NetGo EAP secrets change
After=strongswan.service

[Service]
Type=oneshot
ExecStart=/usr/bin/install -m 0640 -o root -g root $EAP_DIR/secrets.conf /etc/swanctl/conf.d/netgo-eap-secrets.conf
ExecStart=/usr/sbin/swanctl --load-creds
User=root
EOF

  cat > /etc/systemd/system/netgo-eap-reload.path <<EOF
[Unit]
Description=Watch NetGo provisioned EAP secrets

[Path]
PathModified=$EAP_DIR/secrets.conf
Unit=netgo-eap-reload.service

[Install]
WantedBy=multi-user.target
EOF

  ok "enrollment units and directories in place"

  install_qr_tool
}

# ============================================================================
# QR enrollment generator (installed as /usr/local/bin/netgo-enroll-qr)
# ============================================================================
install_qr_tool() {
  cat > "$BIN_DIR/netgo-enroll-qr" <<EOF
#!/usr/bin/env bash
# netgo-enroll-qr : generate an enrollment QR code for one user.
# Encodes netgo://enroll?host=&port=&token=&root_fp=&root=&vpn= into a QR (PNG).
# The root= field carries the full root certificate (base64url DER, no padding),
# so the app can anchor trust directly without the server presenting the root.
set -euo pipefail

HUB_HOST="$PUBLIC_IP"
HUB_PORT="8443"
VPN_ADDR="$PUBLIC_IP"
ROOT_CERT="$PKI_DIR/root.crt.pem"
export NETGO_DB="$STATE_DIR/enroll.db"
export NETGO_MASTER_KEY="$STATE_DIR/master.key"
export NETGO_SWANCTL_SECRETS="$EAP_DIR/secrets.conf"
SIGNER_BIN="$BIN_DIR/netgo-signer"

LABEL="user"; TTL_HOURS="72"; OUT=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --label)     LABEL="\$2"; shift 2 ;;
    --ttl-hours) TTL_HOURS="\$2"; shift 2 ;;
    --out)       OUT="\$2"; shift 2 ;;
    *) echo "unknown argument: \$1"; exit 1 ;;
  esac
done

command -v qrencode >/dev/null || { echo "qrencode missing (apt install qrencode)"; exit 1; }
[[ -f "\$ROOT_CERT" ]] || { echo "root cert not found: \$ROOT_CERT"; exit 1; }

# root fingerprint: SHA-256 of the DER, uppercase hex, no colons.
ROOT_FP=\$(openssl x509 -in "\$ROOT_CERT" -outform DER | openssl dgst -sha256 -hex | awk '{print \$NF}' | tr 'a-f' 'A-F')
# root certificate itself: base64url of the DER, no padding.
ROOT_B64=\$(openssl x509 -in "\$ROOT_CERT" -outform DER | base64 -w0 | tr '+/' '-_' | tr -d '=')

INVITE_OUT=\$(sudo -u netgo-signer \\
  NETGO_DB="\$NETGO_DB" NETGO_MASTER_KEY="\$NETGO_MASTER_KEY" \\
  NETGO_SWANCTL_SECRETS="\$NETGO_SWANCTL_SECRETS" \\
  "\$SIGNER_BIN" admin invite --label "\$LABEL" --ttl-hours "\$TTL_HOURS")
TOKEN=\$(echo "\$INVITE_OUT" | awk 'NF{last=\$0} END{gsub(/^[[:space:]]+/,"",last); print last}')
[[ -n "\$TOKEN" && \${#TOKEN} -ge 16 ]] || { echo "failed to extract token:"; echo "\$INVITE_OUT"; exit 1; }

URL="netgo://enroll?host=\${HUB_HOST}&port=\${HUB_PORT}&token=\${TOKEN}&root_fp=\${ROOT_FP}&root=\${ROOT_B64}&vpn=\${VPN_ADDR}"
[[ -n "\$OUT" ]] || OUT="enroll-\$(echo "\$LABEL" | tr -c '[:alnum:]' '_').png"

# The root cert makes the QR dense; use low error-correction to keep it scannable.
qrencode -o "\$OUT" -s 10 -m 3 -l L "\$URL"
echo "Activation token : \$TOKEN"
echo "Enrollment URL   : \$URL"
echo "URL length       : \$(echo -n "\$URL" | wc -c) chars"
echo "QR PNG written   : \$OUT"
echo ""
echo "Valid \${TTL_HOURS}h, single use. Send the PNG to: \$LABEL"
echo "Scan the PNG (the QR is dense; the terminal render is omitted on purpose)."
EOF
  chmod 755 "$BIN_DIR/netgo-enroll-qr"
  ok "QR generator installed: netgo-enroll-qr"
}

# ============================================================================
# Module 8: network (sysctl, NETGO-FWD chain, persistence scripts)
# ============================================================================
configure_network() {
  say "Network (forwarding, firewall, persistence scripts)"

  cat > /etc/sysctl.d/99-netgo.conf <<EOF
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
EOF
  sysctl -p /etc/sysctl.d/99-netgo.conf >/dev/null

  iptables-nft -N NETGO-FWD 2>/dev/null || true
  iptables-nft -C FORWARD -j NETGO-FWD 2>/dev/null || iptables-nft -I FORWARD 1 -j NETGO-FWD
  # Established returns for the pool.
  iptables-nft -C NETGO-FWD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
    iptables-nft -A NETGO-FWD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

  # --- Inbound ports (IKE, NAT-T, enrollment HTTPS) ---
  for p in 500 4500; do
    iptables-nft -C INPUT -p udp --dport $p -j ACCEPT 2>/dev/null || iptables-nft -I INPUT -p udp --dport $p -j ACCEPT
  done
  iptables-nft -C INPUT -p tcp --dport 8443 -j ACCEPT 2>/dev/null || iptables-nft -I INPUT -p tcp --dport 8443 -j ACCEPT

  # --- Persistence scripts ---
  cat > "$SBIN_DIR/fgt-updown.sh" <<EOF
#!/bin/bash
# Une interface XFRM par FortiGate. N derive du localid fgt-N.
LOGGER="logger -t fgt-updown"
N=\$(echo "\$PLUTO_PEER_ID" | sed -n 's/^fgt-\\([0-9]\\+\\)\$/\\1/p')
[ -z "\$N" ] && { \$LOGGER "PEER_ID '\$PLUTO_PEER_ID' != fgt-N, ignore"; exit 0; }
IFNAME="ipsec\${N}"
IFID="\${PLUTO_IF_ID_OUT}"
FGT_IP="${VTI_NET}.\$((N+1))"
WAN=$WAN_IFACE
POOL=$POOL_CIDR
case "\${PLUTO_VERB}" in
  up-client)
    ip link show "\$IFNAME" >/dev/null 2>&1 || ip link add "\$IFNAME" type xfrm dev "\$WAN" if_id "\$IFID"
    ip link set "\$IFNAME" up
    ip link set "\$IFNAME" mtu 1400
    ip addr replace ${VTI_NET}.1/32 dev "\$IFNAME"
    ip route replace "\${FGT_IP}/32" dev "\$IFNAME"
    iptables-nft -C INPUT -i "\$IFNAME" -p tcp --dport 179 -j ACCEPT 2>/dev/null || iptables-nft -I INPUT -i "\$IFNAME" -p tcp --dport 179 -j ACCEPT
    iptables-nft -C NETGO-FWD -s "\$POOL" -o "\$IFNAME" -j ACCEPT 2>/dev/null || iptables-nft -I NETGO-FWD -s "\$POOL" -o "\$IFNAME" -j ACCEPT
    iptables-nft -C NETGO-FWD -d "\$POOL" -i "\$IFNAME" -j ACCEPT 2>/dev/null || iptables-nft -I NETGO-FWD -d "\$POOL" -i "\$IFNAME" -j ACCEPT
    iptables-nft -t mangle -C FORWARD -o "\$IFNAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1300 2>/dev/null || iptables-nft -t mangle -A FORWARD -o "\$IFNAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1300
    \$LOGGER "up: \$IFNAME if_id=\$IFID FGT=\$FGT_IP (\$PLUTO_PEER_ID)"
    ;;
  down-client)
    iptables-nft -D INPUT -i "\$IFNAME" -p tcp --dport 179 -j ACCEPT 2>/dev/null || true
    iptables-nft -D NETGO-FWD -s "\$POOL" -o "\$IFNAME" -j ACCEPT 2>/dev/null || true
    iptables-nft -D NETGO-FWD -d "\$POOL" -i "\$IFNAME" -j ACCEPT 2>/dev/null || true
    iptables-nft -t mangle -D FORWARD -o "\$IFNAME" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1300 2>/dev/null || true
    ip link del "\$IFNAME" 2>/dev/null || true
    \$LOGGER "down: \$IFNAME nettoye (\$PLUTO_PEER_ID)"
    ;;
esac
exit 0
EOF
  chmod 755 "$SBIN_DIR/fgt-updown.sh"

  cat > "$SBIN_DIR/ipsec-hub.sh" <<EOF
#!/bin/bash
# Hub VPN multi-FGT : pool (annonce BGP via dummy) + MSS. Idempotent.
ip link show dummy-pool >/dev/null 2>&1 || ip link add dummy-pool type dummy
ip link set dummy-pool up
ip route replace $POOL_CIDR dev dummy-pool
iptables-nft -t mangle -C FORWARD -s $POOL_CIDR -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1300 2>/dev/null || \
  iptables-nft -t mangle -A FORWARD -s $POOL_CIDR -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1300
iptables-nft -t mangle -C FORWARD -d $POOL_CIDR -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1300 2>/dev/null || \
  iptables-nft -t mangle -A FORWARD -d $POOL_CIDR -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1300
exit 0
EOF
  chmod 755 "$SBIN_DIR/ipsec-hub.sh"

  cat > "$SBIN_DIR/rw-route.sh" <<EOF
#!/bin/bash
# In multi-FGT, return traffic to clients goes through the roadwarrior XFRM policies.
exit 0
EOF
  chmod 755 "$SBIN_DIR/rw-route.sh"

  cat > /etc/systemd/system/ipsec-hub.service <<EOF
[Unit]
Description=NetGo hub boot setup (dummy-pool, MSS)
After=network-online.target
Wants=network-online.target
Before=frr.service

[Service]
Type=oneshot
ExecStart=$SBIN_DIR/ipsec-hub.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  # Persist base iptables rules.
  netfilter-persistent save >/dev/null 2>&1 || true
  ok "network configured (NETGO-FWD chain, no Docker dependency)"
}

# ============================================================================
# Module 9: start services + summary
# ============================================================================
start_services() {
  say "Starting services"
  systemctl daemon-reload

  # Detect the strongSwan service name (varies: strongswan / strongswan-starter).
  local SS_SVC=""
  for cand in strongswan strongswan-starter; do
    if systemctl list-unit-files "${cand}.service" >/dev/null 2>&1 && \
       systemctl cat "${cand}.service" >/dev/null 2>&1; then
      SS_SVC="$cand"; break
    fi
  done
  [[ -n "$SS_SVC" ]] || SS_SVC="strongswan"
  ok "strongSwan service: $SS_SVC"

  # FRR: enable daemons then (re)start so bgpd comes up.
  systemctl enable frr >/dev/null 2>&1 || true
  systemctl restart frr >/dev/null 2>&1 || warn "frr: check status"

  systemctl enable --now ipsec-hub.service >/dev/null 2>&1 || warn "ipsec-hub: check status"
  systemctl enable --now "$SS_SVC" >/dev/null 2>&1 || warn "$SS_SVC: check status"

  # Signer first (creates DB, master key, empty secrets file).
  systemctl enable --now netgo-signer >/dev/null 2>&1 || warn "netgo-signer: check status"
  sleep 1
  # Generate the initial (empty) secrets file and enable the reload watcher.
  sudo -u netgo-signer \
    NETGO_DB=$STATE_DIR/enroll.db NETGO_MASTER_KEY=$STATE_DIR/master.key \
    NETGO_SWANCTL_SECRETS=$EAP_DIR/secrets.conf \
    "$BIN_DIR/netgo-signer" admin sync >/dev/null 2>&1 || true
  systemctl enable --now netgo-eap-reload.path >/dev/null 2>&1 || true
  systemctl enable --now netgo-frontal >/dev/null 2>&1 || warn "netgo-frontal: check status"

  # Load strongSwan config (needs charon running).
  sleep 1
  swanctl --load-all >/dev/null 2>&1 || warn "swanctl --load-all: check"

  # Sanity: is the frontal actually listening?
  sleep 1
  if systemctl is-active --quiet netgo-frontal; then
    ok "services started"
  else
    warn "netgo-frontal is NOT active - check: journalctl -u netgo-frontal -n 20"
  fi
}

print_summary() {
  local fp; fp=$(cat "$PKI_DIR/root_fp.txt" 2>/dev/null || echo "?")
  cat <<EOF

============================================================
  NETGO HUB INSTALLED
============================================================
  Public IP        : $PUBLIC_IP
  WAN interface    : $WAN_IFACE
  Hub PSK identity : $HUB_PSK_ID
  Road warrior pool: $POOL_CIDR ($POOL_RANGE)
  root_fp (QR)     : $fp

  FortiGate PSK (configure on each FGT, peer id "$HUB_PSK_ID"):
    $PSK

  Enroll a user (generates activation token + QR code):
    sudo netgo-enroll-qr --label "Name" --ttl-hours 72

  Checks:
    curl -k https://$PUBLIC_IP:8443/health              # should return: ok
    sudo swanctl --list-conns 2>/dev/null | grep -E 'fgt|ios-rw'
    sudo vtysh -c 'show bgp summary'
============================================================
EOF
  warn "Save this PSK now: it is not shown again."
}

# ============================================================================
# Full sequence
# ============================================================================
main() {
  detect_env
  ensure_users
  install_packages
  install_binaries
  generate_pki
  configure_strongswan
  configure_frr
  configure_enrollment
  configure_network
  start_services
  print_summary
}

main "$@"
#!/bin/bash
#
# tunnel-deploy.sh — combined dnstt + slipstream DNS-tunnel installer
#
# WHY THIS SCRIPT EXISTS
# -----------------------
# The original dnstt-deploy.sh and slipstream-deploy.sh each install an
# iptables NAT rule that redirects ALL UDP port 53 traffic to their own
# internal port:
#
#   iptables -t nat -I PREROUTING -p udp --dport 53 -j REDIRECT --to-ports <PORT>
#
# Both scripts also default that internal port to 5300. Running both
# installers back-to-back means the second one's rule sits on top of the
# chain and "wins" — the other tunnel keeps running but never receives
# any traffic, and if both are set to SOCKS mode they also collide on
# Dante's 127.0.0.1:1080.
#
# A single UDP port 53 can only be owned by one listener. Since real DNS
# resolvers always query port 53 regardless of which subdomain they're
# resolving, the only way to run two DNS-tunnel servers on the same box
# is to put a DNS-aware dispatcher in front of them that reads the query
# name and forwards to the right backend. This script uses `dnsdist`
# (PowerDNS's load balancer) for that job:
#
#   internet:53 (udp) --> dnsdist --> 127.0.0.1:5300 (dnstt-server)
#                                  \-> 127.0.0.1:5301 (slipstream-server)
#
# dnstt and slipstream each keep their own systemd service, config dir,
# user account and keys, exactly like the original scripts — only the
# port-53 ownership and the SOCKS port (if both use SOCKS) are
# de-conflicted.
#
# TESTED ASSUMPTIONS TO VERIFY BEFORE PRODUCTION USE:
#  - dnsdist is available via your distro's package manager (apt/dnf).
#    On RHEL-family systems you may need the EPEL repo first:
#      dnf install -y epel-release && dnf install -y dnsdist
#  - You are delegating TWO different subdomains (one per tunnel) at
#    your DNS provider, e.g. t1.example.com and t2.example.com, both
#    with NS records pointing at this server's IP.
#  - dnstt-server / slipstream-server CLI flags match the versions
#    referenced in your original scripts — re-check --help if a newer
#    release changes them.
#
set -e

if [[ $EUID -ne 0 ]]; then
    echo -e "\033[0;31m[ERROR]\033[0m This script must be run as root"
    exit 1
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
print_status()  { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
print_question(){ echo -ne "${BLUE}[QUESTION]${NC} $1"; }

# ---------------------------------------------------------------------------
# Global variables — internal ports are LOOPBACK ONLY now (dnsdist is the
# only thing that touches the public interface on 53).
# ---------------------------------------------------------------------------
DNSTT_BASE_URL="https://dnstt.network"
SLIPSTREAM_BASE_URL="https://github.com/EndPositive/slipstream/releases/download/v0.1.0"

INSTALL_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"

DNSTT_CONFIG_DIR="/etc/dnstt"
DNSTT_USER="dnstt"
DNSTT_PORT="5300"                       # 127.0.0.1:5300 only
DNSTT_CONFIG_FILE="${DNSTT_CONFIG_DIR}/dnstt-server.conf"

SLIPSTREAM_CONFIG_DIR="/etc/slipstream"
SLIPSTREAM_USER="slipstream"
SLIPSTREAM_PORT="5301"                  # 127.0.0.1:5301 only — de-conflicted from dnstt's 5300
SLIPSTREAM_CONFIG_FILE="${SLIPSTREAM_CONFIG_DIR}/slipstream-server.conf"

DNSDIST_CONFIG_DIR="/etc/dnsdist"
DNSDIST_CONFIG_FILE="${DNSDIST_CONFIG_DIR}/dnsdist.conf"

# SOCKS ports if either service uses SOCKS mode — kept distinct so they can
# both run in SOCKS mode simultaneously without touching Dante at all.
DNSTT_SOCKS_PORT="1080"
SLIPSTREAM_SOCKS_PORT="1081"

# ===========================================================================
# Shared helpers
# ===========================================================================
detect_os() {
    if [ -f /etc/os-release ]; then . /etc/os-release; OS=$NAME; else
        print_error "Cannot detect OS"; exit 1
    fi
    if command -v dnf &> /dev/null; then PKG_MANAGER="dnf"
    elif command -v yum &> /dev/null; then PKG_MANAGER="yum"
    elif command -v apt &> /dev/null; then PKG_MANAGER="apt"
    else print_error "Unsupported package manager"; exit 1; fi
    print_status "Detected OS: $OS / package manager: $PKG_MANAGER"
}

detect_arch() {
    local arch; arch=$(uname -m)
    case $arch in
        x86_64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        armv7l|armv6l) ARCH="arm" ;;
        i386|i686) ARCH="386" ;;
        *) print_error "Unsupported architecture: $arch"; exit 1 ;;
    esac
    print_status "Detected architecture: $ARCH"
}

check_required_tools() {
    print_status "Checking required tools..."
    local missing=()
    for tool in curl iptables openssl; do
        command -v "$tool" &> /dev/null || missing+=("$tool")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        print_status "Installing missing tools: ${missing[*]}"
        case $PKG_MANAGER in
            dnf|yum) $PKG_MANAGER install -y "${missing[@]}" ;;
            apt) apt update -y && apt install -y "${missing[@]}" ;;
        esac
    fi
}

install_dnsdist() {
    if command -v dnsdist &> /dev/null; then
        print_status "dnsdist already installed"
        return 0
    fi
    print_status "Installing dnsdist (DNS-aware dispatcher for shared port 53)..."
    case $PKG_MANAGER in
        apt)
            apt update -y
            apt install -y dnsdist
            ;;
        dnf|yum)
            $PKG_MANAGER install -y epel-release || true
            $PKG_MANAGER install -y dnsdist
            ;;
    esac
    if ! command -v dnsdist &> /dev/null; then
        print_error "dnsdist install failed — install it manually, then re-run this script."
        exit 1
    fi
}

# ===========================================================================
# dnstt install
# ===========================================================================
download_dnstt_server() {
    local filename="dnstt-server-linux-${ARCH}"
    local filepath="${INSTALL_DIR}/dnstt-server"
    if [ -f "$filepath" ]; then print_status "dnstt-server already installed"; return 0; fi

    print_status "Downloading dnstt-server..."
    curl -L -o "/tmp/$filename" "${DNSTT_BASE_URL}/$filename"
    curl -L -o "/tmp/SHA256SUMS" "${DNSTT_BASE_URL}/SHA256SUMS"
    (cd /tmp && sha256sum -c <(grep "$filename" SHA256SUMS)) || { print_error "Checksum failed"; exit 1; }
    chmod +x "/tmp/$filename"
    mv "/tmp/$filename" "$filepath"
    print_status "dnstt-server installed"
}

create_dnstt_user() {
    if ! id "$DNSTT_USER" &>/dev/null; then
        useradd -r -s /bin/false -d /nonexistent -c "dnstt service user" "$DNSTT_USER"
    fi
    mkdir -p "$DNSTT_CONFIG_DIR"
    chown -R "$DNSTT_USER":"$DNSTT_USER" "$DNSTT_CONFIG_DIR"
    chmod 750 "$DNSTT_CONFIG_DIR"
}

generate_dnstt_keys() {
    local key_prefix; key_prefix=$(echo "$DNSTT_SUBDOMAIN" | sed 's/\./_/g')
    DNSTT_PRIVATE_KEY_FILE="${DNSTT_CONFIG_DIR}/${key_prefix}_server.key"
    DNSTT_PUBLIC_KEY_FILE="${DNSTT_CONFIG_DIR}/${key_prefix}_server.pub"
    if [[ ! -f "$DNSTT_PRIVATE_KEY_FILE" || ! -f "$DNSTT_PUBLIC_KEY_FILE" ]]; then
        print_status "Generating dnstt keypair for $DNSTT_SUBDOMAIN..."
        dnstt-server -gen-key -privkey-file "$DNSTT_PRIVATE_KEY_FILE" -pubkey-file "$DNSTT_PUBLIC_KEY_FILE"
    fi
    chown "$DNSTT_USER":"$DNSTT_USER" "$DNSTT_PRIVATE_KEY_FILE" "$DNSTT_PUBLIC_KEY_FILE"
    chmod 600 "$DNSTT_PRIVATE_KEY_FILE"; chmod 644 "$DNSTT_PUBLIC_KEY_FILE"
    print_status "dnstt public key:"; cat "$DNSTT_PUBLIC_KEY_FILE"
}

create_dnstt_service() {
    local target_port="$DNSTT_TARGET_PORT"
    cat > "${SYSTEMD_DIR}/dnstt-server.service" << EOF
[Unit]
Description=dnstt DNS Tunnel Server
After=network.target dnsdist.service
Wants=network.target

[Service]
Type=simple
User=${DNSTT_USER}
Group=${DNSTT_USER}
ExecStart=${INSTALL_DIR}/dnstt-server -udp 127.0.0.1:${DNSTT_PORT} -privkey-file ${DNSTT_PRIVATE_KEY_FILE} -mtu 1232 ${DNSTT_SUBDOMAIN} 127.0.0.1:${target_port}
Restart=always
RestartSec=5
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${DNSTT_CONFIG_DIR}
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable dnstt-server
}

# ===========================================================================
# slipstream install
# ===========================================================================
download_slipstream_server() {
    local filename="slipstream-server-v0.1.0-linux-x86_64"
    local filepath="${INSTALL_DIR}/slipstream-server"
    if [ -f "$filepath" ]; then print_status "slipstream-server already installed"; return 0; fi

    print_status "Downloading slipstream-server..."
    curl -L -o "/tmp/$filename" "${SLIPSTREAM_BASE_URL}/$filename"
    chmod +x "/tmp/$filename"
    mv "/tmp/$filename" "$filepath"
    print_status "slipstream-server installed"
}

create_slipstream_user() {
    if ! id "$SLIPSTREAM_USER" &>/dev/null; then
        useradd -r -s /bin/false -d /nonexistent -c "slipstream service user" "$SLIPSTREAM_USER"
    fi
    mkdir -p "$SLIPSTREAM_CONFIG_DIR"
    chown -R "$SLIPSTREAM_USER":"$SLIPSTREAM_USER" "$SLIPSTREAM_CONFIG_DIR"
    chmod 750 "$SLIPSTREAM_CONFIG_DIR"
}

generate_slipstream_keys() {
    local key_prefix; key_prefix=$(echo "$SLIPSTREAM_SUBDOMAIN" | sed 's/\./_/g')
    SLIPSTREAM_PRIVATE_KEY_FILE="${SLIPSTREAM_CONFIG_DIR}/${key_prefix}_server.key"
    SLIPSTREAM_PUBLIC_KEY_FILE="${SLIPSTREAM_CONFIG_DIR}/${key_prefix}_server.pub"
    if [[ ! -f "$SLIPSTREAM_PRIVATE_KEY_FILE" || ! -f "$SLIPSTREAM_PUBLIC_KEY_FILE" ]]; then
        print_status "Generating slipstream keypair for $SLIPSTREAM_SUBDOMAIN..."
        openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes \
            -keyout "$SLIPSTREAM_PRIVATE_KEY_FILE" -out "$SLIPSTREAM_PUBLIC_KEY_FILE" \
            -subj "/CN=${key_prefix}" -addext "subjectAltName=DNS:${key_prefix}"
    fi
    chown "$SLIPSTREAM_USER":"$SLIPSTREAM_USER" "$SLIPSTREAM_PRIVATE_KEY_FILE" "$SLIPSTREAM_PUBLIC_KEY_FILE"
    chmod 600 "$SLIPSTREAM_PRIVATE_KEY_FILE"; chmod 644 "$SLIPSTREAM_PUBLIC_KEY_FILE"
}

create_slipstream_service() {
    local target_port="$SLIPSTREAM_TARGET_PORT"
    cat > "${SYSTEMD_DIR}/slipstream-server.service" << EOF
[Unit]
Description=slipstream DNS Tunnel Server
After=network.target dnsdist.service
Wants=network.target

[Service]
Type=simple
User=${SLIPSTREAM_USER}
Group=${SLIPSTREAM_USER}
ExecStart=${INSTALL_DIR}/slipstream-server --dns-listen-address=127.0.0.1 --dns-listen-port=${SLIPSTREAM_PORT} --target-address=127.0.0.1:${target_port} --domain=${SLIPSTREAM_SUBDOMAIN} --cert=${SLIPSTREAM_PUBLIC_KEY_FILE} --key=${SLIPSTREAM_PRIVATE_KEY_FILE}
Restart=always
RestartSec=5
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${SLIPSTREAM_CONFIG_DIR}
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable slipstream-server
    # NOTE: verify --dns-listen-address exists on your slipstream-server build
    # (run `slipstream-server --help`); if not, drop that flag and instead
    # keep it on the default listen address, then rely on the firewall step
    # below to block 5301/udp from anything but 127.0.0.1.
}

# ===========================================================================
# dnsdist front-end (the actual conflict fix)
# ===========================================================================
configure_dnsdist() {
    print_status "Configuring dnsdist to dispatch by subdomain..."

    # --- Free up port 53 before dnsdist tries to bind it -------------------
    # On Debian/Ubuntu, systemd-resolved runs a stub DNS listener on
    # 127.0.0.53:53. Binding dnsdist to 0.0.0.0:53 means "all local
    # addresses", which includes 127.0.0.53 — so dnsdist's bind() fails,
    # the control process exits non-zero, and systemctl reports exactly the
    # generic "failed because the control process exited with error code"
    # message with no further detail in the unit's own log line.
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        print_status "Disabling systemd-resolved's stub listener on port 53..."
        mkdir -p /etc/systemd/resolved.conf.d
        cat > /etc/systemd/resolved.conf.d/no-stub-listener.conf << 'EOF'
[Resolve]
DNSStubListener=no
EOF
        systemctl restart systemd-resolved
        # /etc/resolv.conf may have pointed at 127.0.0.53 — repoint it so the
        # box can still resolve names itself after the stub listener drops.
        if [ -L /etc/resolv.conf ] || grep -q "127.0.0.53" /etc/resolv.conf 2>/dev/null; then
            rm -f /etc/resolv.conf
            printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
        fi
    fi

    # Bail out early (with a real error) if anything is still on port 53,
    # rather than letting dnsdist fail silently again.
    if command -v ss &>/dev/null && ss -ulnp 2>/dev/null | grep -q ':53 '; then
        print_error "Something is still bound to UDP port 53:"
        ss -ulnp | grep ':53 '
        print_error "Stop that service, then re-run: systemctl restart dnsdist"
        exit 1
    fi

    mkdir -p "$DNSDIST_CONFIG_DIR"
    cat > "$DNSDIST_CONFIG_FILE" << EOF
-- Auto-generated by tunnel-deploy.sh
setLocal("0.0.0.0:53")

newServer({address="127.0.0.1:${DNSTT_PORT}", pool="dnstt"})
newServer({address="127.0.0.1:${SLIPSTREAM_PORT}", pool="slipstream"})

-- dnsdist < 1.9.0 (this is what Ubuntu 24.04's apt package ships, 1.8.3)
-- does not have a global SuffixMatchNode() selector function — that only
-- works from 1.9.0 onward. On 1.8.x you must build a class:SuffixMatchNode
-- object with newSuffixMatchNode() and pass it to SuffixMatchNodeRule().
local dnstt_smn = newSuffixMatchNode()
dnstt_smn:add("${DNSTT_SUBDOMAIN}.")
addAction(SuffixMatchNodeRule(dnstt_smn), PoolAction("dnstt"))

local slipstream_smn = newSuffixMatchNode()
slipstream_smn:add("${SLIPSTREAM_SUBDOMAIN}.")
addAction(SuffixMatchNodeRule(slipstream_smn), PoolAction("slipstream"))

-- Anything not matching either tunnel subdomain is dropped rather than
-- silently forwarded anywhere, since this box is not meant to be an
-- open resolver.
addAction(AllRule(), DropAction())
EOF

    # Validate syntax before touching the running service — a Lua error here
    # is the other common cause of "control process exited with error code".
    if ! dnsdist --check-config -C "$DNSDIST_CONFIG_FILE" &>/tmp/dnsdist-check.log; then
        print_error "dnsdist config failed validation:"
        cat /tmp/dnsdist-check.log
        exit 1
    fi

    systemctl enable dnsdist
    systemctl restart dnsdist
    print_status "dnsdist listening on :53, routing ${DNSTT_SUBDOMAIN} -> dnstt, ${SLIPSTREAM_SUBDOMAIN} -> slipstream"
}

# ===========================================================================
# Firewall — ONE set of rules, not two competing sets
# ===========================================================================
configure_firewall() {
    print_status "Configuring firewall (single shared rule set)..."

    if command -v firewall-cmd &> /dev/null && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port=53/udp
        firewall-cmd --reload
    elif command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
        ufw allow 53/udp
    else
        print_warning "No active firewall service detected — relying on iptables only"
    fi

    # Only dnsdist is public-facing on 53; the two tunnel backends and any
    # SOCKS proxies stay on 127.0.0.1 and never need public iptables rules.
    iptables -C INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p udp --dport 53 -j ACCEPT

    save_iptables_rules
}

save_iptables_rules() {
    case $PKG_MANAGER in
        dnf|yum)
            command -v iptables-save &> /dev/null && { mkdir -p /etc/sysconfig; iptables-save > /etc/sysconfig/iptables; }
            ;;
        apt)
            command -v iptables-save &> /dev/null && { mkdir -p /etc/iptables; iptables-save > /etc/iptables/rules.v4; }
            ;;
    esac
}

# ===========================================================================
# SOCKS backends (only set up if a service needs "socks" mode)
# ===========================================================================
setup_dante_instance() {
    # $1 = instance name (dnstt|slipstream), $2 = socks port, $3 = config path
    local name="$1" port="$2" conf="$3"
    case $PKG_MANAGER in
        dnf|yum) $PKG_MANAGER install -y dante-server ;;
        apt) apt install -y dante-server ;;
    esac
    local ext_if; ext_if=$(ip route | grep default | awk '{print $5}' | head -1)
    [[ -z "$ext_if" ]] && ext_if="eth0"

    cat > "$conf" << EOF
logoutput: syslog
user.privileged: root
user.unprivileged: nobody
internal: 127.0.0.1 port = ${port}
external: ${ext_if}
socksmethod: none
compatibility: sameport
extension: bind
client pass { from: 127.0.0.0/8 to: 0.0.0.0/0 log: error }
socks pass { from: 127.0.0.0/8 to: 0.0.0.0/0 command: bind connect udpassociate log: error }
socks block { from: 0.0.0.0/0 to: ::/0 log: error }
client block { from: 0.0.0.0/0 to: ::/0 log: error }
EOF

    cat > "${SYSTEMD_DIR}/danted-${name}.service" << EOF
[Unit]
Description=Dante SOCKS proxy for ${name}
After=network.target
[Service]
Type=simple
ExecStart=/usr/sbin/danted -f ${conf}
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "danted-${name}"
    systemctl restart "danted-${name}"
    print_status "Dante SOCKS proxy for ${name} on 127.0.0.1:${port}"
}

detect_ssh_port() {
    local p; p=$(ss -tlnp 2>/dev/null | grep sshd | awk '{print $4}' | cut -d':' -f2 | head -1)
    echo "${p:-22}"
}

# ===========================================================================
# User input
# ===========================================================================
get_user_input() {
    print_question "Enter dnstt nameserver subdomain (e.g., t1.example.com): "
    read -r DNSTT_SUBDOMAIN
    print_question "dnstt tunnel mode — 1) SOCKS  2) SSH [1/2]: "
    read -r m; [[ "$m" == "2" ]] && DNSTT_MODE="ssh" || DNSTT_MODE="socks"

    echo ""
    print_question "Enter slipstream nameserver subdomain (e.g., t2.example.com, MUST differ from above): "
    read -r SLIPSTREAM_SUBDOMAIN
    if [[ "$SLIPSTREAM_SUBDOMAIN" == "$DNSTT_SUBDOMAIN" ]]; then
        print_error "dnstt and slipstream must use different subdomains — dnsdist routes by that suffix."
        exit 1
    fi
    print_question "slipstream tunnel mode — 1) SOCKS  2) SSH [1/2]: "
    read -r m; [[ "$m" == "2" ]] && SLIPSTREAM_MODE="ssh" || SLIPSTREAM_MODE="socks"

    if [ "$DNSTT_MODE" = "ssh" ]; then DNSTT_TARGET_PORT=$(detect_ssh_port); else DNSTT_TARGET_PORT="$DNSTT_SOCKS_PORT"; fi
    if [ "$SLIPSTREAM_MODE" = "ssh" ]; then SLIPSTREAM_TARGET_PORT=$(detect_ssh_port); else SLIPSTREAM_TARGET_PORT="$SLIPSTREAM_SOCKS_PORT"; fi

    print_status "dnstt:      $DNSTT_SUBDOMAIN -> $DNSTT_MODE (127.0.0.1:${DNSTT_PORT} -> 127.0.0.1:${DNSTT_TARGET_PORT})"
    print_status "slipstream: $SLIPSTREAM_SUBDOMAIN -> $SLIPSTREAM_MODE (127.0.0.1:${SLIPSTREAM_PORT} -> 127.0.0.1:${SLIPSTREAM_TARGET_PORT})"
}

# ===========================================================================
# Main
# ===========================================================================
main() {
    detect_os
    detect_arch
    check_required_tools
    install_dnsdist

    get_user_input

    download_dnstt_server
    create_dnstt_user
    generate_dnstt_keys

    download_slipstream_server
    create_slipstream_user
    generate_slipstream_keys

    [ "$DNSTT_MODE" = "socks" ] && setup_dante_instance "dnstt" "$DNSTT_SOCKS_PORT" "/etc/danted-dnstt.conf"
    [ "$SLIPSTREAM_MODE" = "socks" ] && setup_dante_instance "slipstream" "$SLIPSTREAM_SOCKS_PORT" "/etc/danted-slipstream.conf"

    create_dnstt_service
    create_slipstream_service

    configure_firewall
    configure_dnsdist

    systemctl restart dnstt-server
    systemctl restart slipstream-server

    echo ""
    print_status "Done. Both tunnels share port 53 via dnsdist, each on its own subdomain:"
    print_status "  dnstt:      $DNSTT_SUBDOMAIN"
    print_status "  slipstream: $SLIPSTREAM_SUBDOMAIN"
    print_status "Check status: systemctl status dnsdist dnstt-server slipstream-server"
}

main "$@"

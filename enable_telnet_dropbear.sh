#!/bin/sh
# =============================================================================
#  Developed by visal 2026/11/14
#  enable_telnet_dropbear.sh
#
#  Target   : Tozed S12 UNISOC PLUS 4G CPE (OpenWrt, mipsel_24kc, uClibc)
#  Firmware : 4.32.3.1 "user mode"  ->  firmware-kernel-fs-v4.32.3.1-user
#
#  WHAT THIS SCRIPT DOES
#    1. Creates / repairs the login account "user" with an EMPTY password
#       (root is also set to an empty password, like the factory telnet setup).
#    2. Replaces /etc/init.d/telnet with a version that actually works on this
#       image, enables it in /etc/rc.d and starts telnet on TCP 23.
#    3. Installs /etc/init.d/dropbear + /etc/config/dropbear, generates host
#       keys and starts SSH (blank-password login allowed) on its own port.
#    4. Deletes /etc/close_login_tools so /etc/init.d/boot cannot switch both
#       services back off on the next reboot.
#    5. Starts everything and verifies the listening sockets.
#
#
#  PORT NOTE
#    Telnet and SSH cannot share the same TCP port. If TELNET_PORT and
#    DROPBEAR_PORT are equal the script automatically moves dropbear to
#    DROPBEAR_PORT_FALLBACK (22) and tells you so.
#    Want SSH on 23 only?  set ENABLE_TELNET=0 and DROPBEAR_PORT=23.
#
#  USAGE
#    sh enable_telnet_dropbear.sh            # enable (default)
#    sh enable_telnet_dropbear.sh status     # show current state, changes nothing
#    sh enable_telnet_dropbear.sh disable    # turn both services off
#
#  Everything is idempotent - safe to run again after a reboot or upgrade.
# =============================================================================

# ----------------------------- configuration --------------------------------
LOGIN_USER="user"                 # extra account requested
LOGIN_PASS=""                     # empty password
ROOT_EMPTY_PASS=1                 # 1 = also clear root password

ENABLE_TELNET=1                   # 1 = enable telnet
ENABLE_DROPBEAR=1                 # 1 = enable dropbear (SSH)

TELNET_PORT=23
DROPBEAR_PORT=23                  # requested port for SSH
DROPBEAR_PORT_FALLBACK=22         # used when it collides with telnet

ALLOW_WAN=0                       # 1 = also open the port on the WAN zone
DROPBEAR_SRC=""                   # optional: path to a dropbear binary to copy

TAG="[tz-telnet]"

# ------------------------------- helpers ------------------------------------
log()  { echo "$TAG $*"; }
warn() { echo "$TAG WARN: $*"; }
err()  { echo "$TAG ERROR: $*" >&2; }

need_root() {
    [ "$(id -u)" = "0" ] || { err "must run as root"; exit 1; }
}

have() { command -v "$1" >/dev/null 2>&1; }

# backup of the files we are going to touch
backup_files() {
    bdir="/root/telnet_dropbear_backup_$(date +%Y%m%d%H%M%S)"
    mkdir -p "$bdir" 2>/dev/null || return 0
    for f in /etc/passwd /etc/shadow /etc/group /etc/config/tozed \
             /etc/init.d/telnet /etc/config/dropbear; do
        [ -f "$f" ] && cp -f "$f" "$bdir/$(echo "$f" | tr '/' '_')" 2>/dev/null
    done
    log "backup written to $bdir"
}

# ------------------------- 1. accounts with empty password -------------------
add_empty_pass_user() {
    name="$1"
    home="$2"

    # group
    grep -q "^${name}:" /etc/group 2>/dev/null || \
        echo "${name}:x:1000:" >> /etc/group

    # passwd entry
    if ! grep -q "^${name}:" /etc/passwd 2>/dev/null; then
        echo "${name}:x:1000:1000:${name}:${home}:/bin/ash" >> /etc/passwd
        log "account '${name}' created"
    fi

    # shadow entry with an EMPTY password field (name::...)
    touch /etc/shadow
    if grep -q "^${name}:" /etc/shadow 2>/dev/null; then
        sed -i "s|^${name}:[^:]*:|${name}::|" /etc/shadow
    else
        echo "${name}::0:0:99999:7:::" >> /etc/shadow
    fi

    chmod 600 /etc/shadow 2>/dev/null

    # let busybox passwd do the final word when available
    if [ -x /bin/passwd ]; then
        passwd -d "$name" >/dev/null 2>&1
    fi

    mkdir -p "$home" 2>/dev/null
    log "account '${name}' -> empty password, shell /bin/ash"
}

setup_accounts() {
    log "step 1/5: accounts"
    [ "$ROOT_EMPTY_PASS" = "1" ] && add_empty_pass_user "root" "/root"
    add_empty_pass_user "$LOGIN_USER" "/root"
    sync
}

# ------------------------- 2. telnet init script -----------------------------
install_telnet_init() {
    log "step 2/5: /etc/init.d/telnet"
    cat > /etc/init.d/telnet <<'TELNET_INIT'
#!/bin/sh /etc/rc.common
# Telnet service - rewritten for the user-mode rootfs of 4.32.3.1
# The stock script called /usr/sbin/telnetd, which does not exist in this
# image, so procd had nothing to run. This version picks the first available
# daemon: /usr/sbin/telnetd -> busybox telnetd -> socat.

START=50
USE_PROCD=1

TELNET_PORT=23

start_service() {
	telnetEnable=$(uci -q get tozed.system.TZ_SYSTEM_TELNET_ENABLE)
	[ "${telnetEnable}" = "1" ] || {
		echo "telnet disabled by TZ_SYSTEM_TELNET_ENABLE"
		return 0
	}

	# 1) classic netkit / inetutils telnetd
	if [ -x /usr/sbin/telnetd ]; then
		procd_open_instance telnetd
		procd_set_param command /usr/sbin/telnetd -F -p "${TELNET_PORT}" -l /bin/login
		procd_set_param respawn 3600 5 5
		procd_set_param stdout 1
		procd_set_param stderr 1
		procd_close_instance
		echo "telnet: /usr/sbin/telnetd on ${TELNET_PORT}"
		return 0
	fi

	# 2) busybox applet
	if /bin/busybox --list 2>/dev/null | grep -qx telnetd; then
		procd_open_instance busybox-telnetd
		procd_set_param command /bin/busybox telnetd -F -p "${TELNET_PORT}" -l /bin/login
		procd_set_param respawn 3600 5 5
		procd_set_param stdout 1
		procd_set_param stderr 1
		procd_close_instance
		echo "telnet: busybox telnetd on ${TELNET_PORT}"
		return 0
	fi

	# 3) socat based daemon (present in this image)
	#    echo=0 is REQUIRED: socat does no telnet IAC negotiation, so the client
	#    keeps its own local echo. With the pty echo also on, every character
	#    is shown twice ("llss" instead of "ls"). Keep echo=0 AFTER sane.
	if [ -x /usr/bin/socat ]; then
		procd_open_instance socat-telnetd
		procd_set_param command /usr/bin/socat \
			TCP-LISTEN:${TELNET_PORT},reuseaddr,fork EXEC:/bin/login,pty,stderr,setsid,sigint,sane,echo=0
		procd_set_param respawn 3600 5 5
		procd_set_param stdout 1
		procd_set_param stderr 1
		procd_close_instance
		echo "telnet: socat on ${TELNET_PORT}"
		return 0
	fi

	echo "telnet: no usable telnet daemon found" >&2
	return 1
}
TELNET_INIT

    chmod 0755 /etc/init.d/telnet
    log "telnet init script installed"
}

# ------------------------- 3. dropbear (SSH) ---------------------------------
install_dropbear_init() {
    cat > /etc/init.d/dropbear <<'DROPBEAR_INIT'
#!/bin/sh /etc/rc.common
# Dropbear SSH service - rebuilt for the user-mode rootfs of 4.32.3.1
# The binary, the init script and /etc/config/dropbear were all removed in
# user mode. This script restores the standard OpenWrt behaviour and allows
# blank-password logins (-B) so the "user"/empty-password account works.

START=19
USE_PROCD=1
PROG=/usr/sbin/dropbear

start_service() {
	ssh_enable=$(uci -q get tozed.system.TZ_SYSTEM_SSH_ENABLE)
	[ "${ssh_enable}" = "0" ] && {
		echo "ssh disabled by TZ_SYSTEM_SSH_ENABLE"
		return 0
	}

	[ -x "${PROG}" ] || {
		echo "dropbear binary not found at ${PROG}" >&2
		return 1
	}

	port=$(uci -q get dropbear.@dropbear[0].Port)
	[ -n "${port}" ] || port=23

	mkdir -p /etc/dropbear /var/run

	# host keys: create them if the image lost them
	if [ ! -f /etc/dropbear/dropbear_rsa_host_key ] && [ -x /usr/bin/dropbearkey ]; then
		/usr/bin/dropbearkey -t rsa -s 2048 -f /etc/dropbear/dropbear_rsa_host_key >/dev/null 2>&1
	fi
	if [ ! -f /etc/dropbear/dropbear_ed25519_host_key ] && [ -x /usr/bin/dropbearkey ]; then
		/usr/bin/dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key >/dev/null 2>&1
	fi

	procd_open_instance
	procd_set_param command ${PROG} -F -B -R -P /var/run/dropbear.pid \
		-p "${port}" -K 300 -I 3600
	procd_set_param respawn 3600 5 5
	procd_set_param stdout 1
	procd_set_param stderr 1
	procd_close_instance

	echo "dropbear listening on ${port}"
}
DROPBEAR_INIT

    chmod 0755 /etc/init.d/dropbear
    log "dropbear init script installed"
}

install_dropbear_config() {
    if [ ! -f /etc/config/dropbear ]; then
        cat > /etc/config/dropbear <<EOF
config dropbear
	option PasswordAuth 'on'
	option RootPasswordAuth 'on'
	option Port '${DROPBEAR_PORT}'
	option Banner ''
EOF
        log "created /etc/config/dropbear (port ${DROPBEAR_PORT})"
    else
        uci -q set dropbear.@dropbear[0].PasswordAuth='on'
        uci -q set dropbear.@dropbear[0].RootPasswordAuth='on'
        uci -q set dropbear.@dropbear[0].Port="${DROPBEAR_PORT}"
        log "/etc/config/dropbear updated (port ${DROPBEAR_PORT})"
    fi
    uci -q commit dropbear
}

ensure_dropbear_binary() {
    if [ -x /usr/sbin/dropbear ]; then
        log "dropbear binary present: /usr/sbin/dropbear"
        return 0
    fi

    # 1) copy from the squashfs image if the read-only layer still has it
    for src in /rom/usr/sbin/dropbear /rom/usr/bin/dropbear; do
        if [ -x "$src" ]; then
            cp -f "$src" /usr/sbin/dropbear && chmod 0755 /usr/sbin/dropbear
            log "dropbear copied from $src"
            return 0
        fi
    done

    # 2) explicit source given by the operator
    if [ -n "$DROPBEAR_SRC" ] && [ -f "$DROPBEAR_SRC" ]; then
        cp -f "$DROPBEAR_SRC" /usr/sbin/dropbear && chmod 0755 /usr/sbin/dropbear
        log "dropbear copied from $DROPBEAR_SRC"
        return 0
    fi

    # 3) try opkg (needs working internet / feed)
    if have opkg; then
        log "dropbear missing, trying: opkg update && opkg install dropbear"
        opkg update >/dev/null 2>&1
        opkg install dropbear >/dev/null 2>&1
        if [ -x /usr/sbin/dropbear ]; then
            log "dropbear installed from opkg"
            return 0
        fi
    fi

    warn "dropbear binary is NOT present in this user-mode image"
    warn "telnet will still work; to get SSH, copy a mipsel_24kc dropbear to"
    warn "/usr/sbin/dropbear and re-run this script with DROPBEAR_SRC=/path"
    return 1
}

# ------------------------- 4. enable in rc.d / uci ---------------------------
enable_services() {
    log "step 4/5: enabling services"

    # telnet switch used by /etc/init.d/telnet
    uci -q set tozed.system.TZ_SYSTEM_TELNET_ENABLE='1'
    # ssh switch used by /etc/init.d/dropbear and by the web UI (system.lua)
    uci -q set tozed.system.TZ_SYSTEM_SSH_ENABLE='1'
    uci -q commit tozed

    # this flag makes /etc/init.d/boot force both switches back to 0
    if [ -f /etc/close_login_tools ]; then
        rm -f /etc/close_login_tools
        log "removed /etc/close_login_tools (boot-time kill switch)"
    fi

    # boot symlinks
    mkdir -p /etc/rc.d
    rm -f /etc/rc.d/S50telnet
    ln -sf ../init.d/telnet /etc/rc.d/S50telnet
    /etc/init.d/telnet enable >/dev/null 2>&1

    rm -f /etc/rc.d/S19dropbear
    ln -sf ../init.d/dropbear /etc/rc.d/S19dropbear
    /etc/init.d/dropbear enable >/dev/null 2>&1

    log "rc.d symlinks: S50telnet, S19dropbear"
}

# ------------------------- 5. firewall --------------------------------------
open_firewall() {
    [ "$ALLOW_WAN" = "1" ] || {
        log "firewall: LAN zone already accepts input, no rule needed"
        return 0
    }

    uci -q delete firewall.tz_telnet_wan
    uci set firewall.tz_telnet_wan=rule
    uci set firewall.tz_telnet_wan.name='Allow-Telnet-SSH-WAN'
    uci set firewall.tz_telnet_wan.src='wan'
    uci set firewall.tz_telnet_wan.proto='tcp'
    uci set firewall.tz_telnet_wan.dest_port="${TELNET_PORT} ${DROPBEAR_PORT}"
    uci set firewall.tz_telnet_wan.target='ACCEPT'
    uci commit firewall
    /etc/init.d/firewall reload >/dev/null 2>&1
    log "firewall: WAN rule added for ports ${TELNET_PORT}/${DROPBEAR_PORT}"
}

# ------------------------- start & verify -----------------------------------
start_services() {
    log "step 5/5: starting services"

    if [ "$ENABLE_TELNET" = "1" ]; then
        /etc/init.d/telnet restart >/dev/null 2>&1 || /etc/init.d/telnet start >/dev/null 2>&1
    else
        /etc/init.d/telnet stop >/dev/null 2>&1
        uci -q set tozed.system.TZ_SYSTEM_TELNET_ENABLE='0'
        uci -q commit tozed
    fi

    if [ "$ENABLE_DROPBEAR" = "1" ] && [ -x /usr/sbin/dropbear ]; then
        /etc/init.d/dropbear restart >/dev/null 2>&1 || /etc/init.d/dropbear start >/dev/null 2>&1
    fi

    sleep 2
    show_status
}

show_status() {
    # uci may be unavailable/busy, fall back to the config file
    db_port=$(uci -q get dropbear.@dropbear[0].Port 2>/dev/null)
    [ -n "$db_port" ] || db_port=$(awk -F"'" '/option Port/ {print $2}' /etc/config/dropbear 2>/dev/null)
    [ -n "$db_port" ] || db_port="$DROPBEAR_PORT"

    echo "-------------------------------------------------------------"
    echo " TELNET  : uci TZ_SYSTEM_TELNET_ENABLE = $(uci -q get tozed.system.TZ_SYSTEM_TELNET_ENABLE)"
    echo " SSH     : uci TZ_SYSTEM_SSH_ENABLE    = $(uci -q get tozed.system.TZ_SYSTEM_SSH_ENABLE)"
    echo " dropbear: port                        = ${db_port}"
    echo " user    : shadow entry -> $(grep "^${LOGIN_USER}:" /etc/shadow 2>/dev/null)"
    echo " root    : shadow entry -> $(grep '^root:' /etc/shadow 2>/dev/null)"
    echo "-------------------------------------------------------------"
    echo " processes:"
    ps 2>/dev/null | grep -E 'telnetd|socat|dropbear' | grep -v grep
    echo " listeners:"
    netstat -ltn 2>/dev/null | grep -E ":(${TELNET_PORT}|${db_port}|${DROPBEAR_PORT_FALLBACK})[[:space:]]" \
        || echo "  (nothing listening yet - check 'logread' for procd errors)"
    echo "-------------------------------------------------------------"
    echo " login: ${LOGIN_USER} / (empty password)   or   root / (empty password)"
}

# ------------------------------ disable -------------------------------------
disable_all() {
    need_root
    log "disabling telnet and dropbear"
    /etc/init.d/telnet stop   >/dev/null 2>&1
    /etc/init.d/dropbear stop >/dev/null 2>&1
    uci -q set tozed.system.TZ_SYSTEM_TELNET_ENABLE='0'
    uci -q set tozed.system.TZ_SYSTEM_SSH_ENABLE='0'
    uci -q commit tozed
    rm -f /etc/rc.d/S50telnet /etc/rc.d/S19dropbear
    log "done (files kept, services stopped and disabled)"
}

# -------------------------------- main --------------------------------------
main() {
    action="${1:-enable}"
    need_root

    case "$action" in
        status)
            show_status
            exit 0
            ;;
        disable)
            disable_all
            exit 0
            ;;
        enable|"")
            ;;
        *)
            echo "usage: $0 [enable|status|disable]"
            exit 1
            ;;
    esac

    # port collision handling
    if [ "$ENABLE_TELNET" = "1" ] && [ "$ENABLE_DROPBEAR" = "1" ] \
       && [ "$TELNET_PORT" = "$DROPBEAR_PORT" ]; then
        warn "telnet and dropbear cannot both bind TCP ${TELNET_PORT}"
        DROPBEAR_PORT="$DROPBEAR_PORT_FALLBACK"
        log  "dropbear moved to TCP ${DROPBEAR_PORT} (telnet keeps ${TELNET_PORT})"
    fi

    log "starting on $(cat /etc/openwrt_release 2>/dev/null | head -1)"
    backup_files
    setup_accounts
    install_telnet_init
    install_dropbear_init
    install_dropbear_config
    ensure_dropbear_binary || true
    enable_services
    open_firewall
    start_services

    log "finished - telnet ${TELNET_PORT}, dropbear ${DROPBEAR_PORT}"
}

main "$@"

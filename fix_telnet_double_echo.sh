#!/bin/sh
# =============================================================================
#  fix_telnet_double_echo.sh
#  Developed by visal 2026/11/14
#  Symptom: typing in telnet shows every character twice  ->  "llss", "ccdd"
#
#  Cause: the socat telnet daemon runs /bin/login on a pty that still has the
#         kernel ECHO flag set. socat does not speak the telnet protocol, so
#         the client never receives IAC WILL ECHO and keeps its own local echo
#         enabled. Result: client echoes once, pty echoes once = two chars.
#
#  Fix  : pty echo off (echo=0, placed AFTER sane so it wins).
#
# =============================================================================

INIT=/etc/init.d/telnet

[ "$(id -u)" = "0" ] || { echo "must be root"; exit 1; }
[ -f "$INIT" ] || { echo "$INIT not found - run enable_telnet_dropbear.sh first"; exit 1; }

if grep -q 'sane,echo=0' "$INIT"; then
    echo "already patched (sane,echo=0)"
else
    cp -f "$INIT" "/root/telnet.init.bak.$(date +%Y%m%d%H%M%S)"
    # only the socat line ends with ",sane"
    sed -i 's/,sane[[:space:]]*$/,sane,echo=0/' "$INIT"
    if grep -q 'sane,echo=0' "$INIT"; then
        echo "patched: pty echo disabled"
    else
        echo "patch failed - edit $INIT manually: add ,echo=0 after sane"
        exit 1
    fi
fi

/etc/init.d/telnet restart >/dev/null 2>&1
sleep 2

echo "--- current socat command ---"
ps 2>/dev/null | grep socat | grep -v grep
echo "--- listener ---"
netstat -ltn 2>/dev/null | grep ':23[[:space:]]'
echo
echo "Reconnect your telnet session. Characters should now appear once."
echo "If your client shows NOTHING while typing, your client relies on server"
echo "echo: set 'Force off' local echo in the client, or change echo=0 to echo=1"
echo "in $INIT and restart the service."

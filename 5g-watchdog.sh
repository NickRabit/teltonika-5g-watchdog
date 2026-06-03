#!/bin/sh
# =============================================================================
# 5G watchdog for Teltonika (Quectel modem, NSA 5G) by NickRabit
#
# Purpose: lock the LTE anchor cell (EARFCN + PCI) and continuously check that
#          the modem keeps NSA 5G on band n78 on top of it. If n78 disappears,
#          try a reconnect, and if that keeps failing, reboot the router.
#
# Started from init / hotplug. After startup it detaches into the background
# (the "( ... ) &" subshell + "exit 0"), so the init script returns immediately
# while the watchdog loop keeps running.
# =============================================================================

LOGTAG="5g-watchdog"                          # tag for logger -> greppable in the system log
MOB_IF="mob1s2a1"                             # mobile interface name in RutOS / OpenWrt

NO5G_COUNT_FILE="/tmp/no5g_count"             # counter of consecutive cycles without n78
RECONNECT_FAIL_FILE="/tmp/reconnect_fail_count" # counter of failed reconnect attempts
# (/tmp is tmpfs -> counters reset on reboot, which is intended here)

LTE_LOCK_FREQ="6300"                          # EARFCN of the LTE anchor cell (6300 = band 20, 800 MHz)
LTE_LOCK_PCI="295"                            # Physical Cell ID of the specific cell we lock to

# -----------------------------------------------------------------------------
# apply_lte_lock: lock the modem to one specific LTE cell (EARFCN + PCI).
# The goal is to stay on the anchor cell that carries 5G n78 via EN-DC (NSA).
# Without a lock the modem tends to roam to other LTE cells with no decent 5G.
# -----------------------------------------------------------------------------
apply_lte_lock() {
    logger -t "$LOGTAG" "Applying LTE lock: EARFCN=$LTE_LOCK_FREQ PCI=$LTE_LOCK_PCI"
    # QNWLOCK "common/4g",<num cells>,<earfcn>,<pci> -> lock 4G to a single cell
    LOCK_OUT="$(gsmctl -A "AT+QNWLOCK=\"common/4g\",1,$LTE_LOCK_FREQ,$LTE_LOCK_PCI" 2>/dev/null)"
    logger -t "$LOGTAG" "QNWLOCK response: $LOCK_OUT"
    sleep 3                                    # give the lock a moment to take effect
    # SERVINGCELL = current serving cell dump (log/debug only)
    SERVINGCELL="$(gsmctl -A 'AT+QENG="SERVINGCELL"' 2>/dev/null)"
    logger -t "$LOGTAG" "Serving cell after lock: $(echo "$SERVINGCELL" | tr '\n' ' ')"
}

# -----------------------------------------------------------------------------
# Wait until the modem is ready. QCAINFO returns carrier aggregation info;
# as long as there is no LTE/NR5G band listed, the modem is not up yet -> wait.
# -----------------------------------------------------------------------------
until gsmctl -A 'AT+QCAINFO' 2>/dev/null | grep -q -E 'LTE BAND|NR5G BAND'; do
    logger -t "$LOGTAG" "Waiting for modem..."
    sleep 10
done

# Initialize counters (create the files set to 0 if they don't exist yet)
[ -f "$NO5G_COUNT_FILE" ] || echo 0 > "$NO5G_COUNT_FILE"
[ -f "$RECONNECT_FAIL_FILE" ] || echo 0 > "$RECONNECT_FAIL_FILE"

apply_lte_lock                                 # initial lock right after startup

# -----------------------------------------------------------------------------
# The main watchdog loop runs in a background subshell (see the "&" below),
# so the init script can return immediately (exit 0) while this keeps running.
# -----------------------------------------------------------------------------
(
while true; do
    QCAINFO="$(gsmctl -A 'AT+QCAINFO' 2>/dev/null)"

    # If the AT command returns nothing (modem busy/restarting), skip this cycle
    if [ -z "$QCAINFO" ]; then
        logger -t "$LOGTAG" "QCAINFO empty, skipping"
        sleep 30
        continue
    fi

    # --- HEALTHY STATE: 5G n78 is active ---------------------------------------
    if echo "$QCAINFO" | grep -q 'NR5G BAND 78'; then
        echo 0 > "$NO5G_COUNT_FILE"            # reset both counters
        echo 0 > "$RECONNECT_FAIL_FILE"
        logger -t "$LOGTAG" "n78 OK (iface=$MOB_IF)"
        sleep 120                              # all good -> only check every 2 min
        continue
    fi

    # --- PROBLEM STATE: n78 missing -> bump the counter ------------------------
    NO5G_COUNT="$(cat "$NO5G_COUNT_FILE" 2>/dev/null)"
    NO5G_COUNT=$((NO5G_COUNT + 1))
    echo "$NO5G_COUNT" > "$NO5G_COUNT_FILE"
    logger -t "$LOGTAG" "n78 missing (count=$NO5G_COUNT, iface=$MOB_IF)"

    # Only act after 3 consecutive cycles without n78 (filters out short blips)
    if [ "$NO5G_COUNT" -ge 3 ]; then
        logger -t "$LOGTAG" "Trying reconnect on $MOB_IF"

        # Reconnect: bring the interface down, re-lock LTE, bring it up, lock again
        ifdown "$MOB_IF"
        sleep 8
        apply_lte_lock                         # lock even with the interface down
        ifup "$MOB_IF"
        sleep 30                               # wait for network registration
        apply_lte_lock                         # and lock once more after attach
        echo 0 > "$NO5G_COUNT_FILE"            # reset the n78-missing counter
        sleep 60                               # let 5G come up

        # Verify whether the reconnect helped
        QCAINFO_AFTER="$(gsmctl -A 'AT+QCAINFO' 2>/dev/null)"
        if echo "$QCAINFO_AFTER" | grep -q 'NR5G BAND 78'; then
            logger -t "$LOGTAG" "n78 restored after reconnect"
            echo 0 > "$RECONNECT_FAIL_FILE"    # success -> reset the failure counter
            continue
        fi

        # Reconnect didn't help -> bump the failure counter
        FAIL_COUNT="$(cat "$RECONNECT_FAIL_FILE" 2>/dev/null)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo "$FAIL_COUNT" > "$RECONNECT_FAIL_FILE"
        logger -t "$LOGTAG" "Reconnect failed count=$FAIL_COUNT"

        # After 3 failed reconnects do a hard router reboot (last resort)
        if [ "$FAIL_COUNT" -ge 3 ]; then
            logger -t "$LOGTAG" "Reconnect failed 3x, rebooting router"
            sleep 5
            reboot
        fi
    fi

    sleep 120                                  # poll interval while in the problem state
done
) &

exit 0   # init script returns immediately; the loop above keeps running in background

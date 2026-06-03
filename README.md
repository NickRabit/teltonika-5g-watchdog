# Teltonika 5G n78 Watchdog

A small shell script for Teltonika RutOS routers that helps keep an NSA 5G connection stable on band n78.

The script locks the modem to a specific LTE anchor cell using EARFCN + PCI and then continuously checks whether the n78 NR carrier is active. If n78 disappears for several checks in a row, the script reconnects the mobile interface. If reconnecting repeatedly fails, it reboots the router as a last resort.

## Why this exists

On some NSA 5G setups, the modem may drop from 5G n78 and roam to LTE-only cells. This can result in much worse throughput.

NSA 5G depends on an LTE anchor cell first. The 5G NR carrier is then added on top using EN-DC. Because of that, locking the modem to a good LTE anchor cell can help keep the n78 connection stable.

## What the script does

* Waits until the modem is ready.
* Applies an LTE cell lock using:

```sh
AT+QNWLOCK="common/4g",1,<earfcn>,<pci>
```

* Polls `AT+QCAINFO` in the background.
* Checks whether `NR5G BAND 78` is present.
* If n78 is active, it waits and checks again later.
* If n78 is missing several times in a row, it reconnects the mobile interface.
* If reconnecting fails repeatedly, it reboots the router.
* Logs everything using:

```sh
logger -t 5g-watchdog
```

## Tested device

Tested on:

* Teltonika RUTC50
* Quectel RG520N modem
* NSA 5G with band n78

It may also work on other Teltonika RutOS devices with compatible Quectel modems, but this has not been tested.

## Installation

Copy the script into RutOS custom scripts:

```text
System -> Maintenance -> Custom Scripts
```

After saving the script, restart the router so the watchdog starts cleanly after boot.

## Configuration

Before using the script, edit the values at the top:

```sh
MOB_IF="mob1s3a1"
LTE_LOCK_FREQ="6300"
LTE_LOCK_PCI="295"
```

### `MOB_IF`

Your mobile interface name in RutOS / OpenWrt.

Example:

```sh
MOB_IF="mob1s3a1"
```

### `LTE_LOCK_FREQ`

The EARFCN of the LTE anchor cell.

Example:

```sh
LTE_LOCK_FREQ="6300"
```

### `LTE_LOCK_PCI`

The PCI of the LTE anchor cell.

Example:

```sh
LTE_LOCK_PCI="295"
```

## How to find EARFCN and PCI
## How to find EARFCN and PCI

The easiest way to find the required values is directly in the RutOS web UI:

```text
Status -> Network -> Mobile
```

Check the mobile connection details while your 5G n78 connection is working well. Look for the LTE serving/anchor cell information, especially:

* EARFCN
* PCI

Use those values in the script:

```sh
LTE_LOCK_FREQ="<earfcn>"
LTE_LOCK_PCI="<pci>"
```

You can also verify the current serving cell and carrier aggregation info with AT commands:

```sh
gsmctl -A 'AT+QENG="SERVINGCELL"'
gsmctl -A 'AT+QCAINFO'
```

The goal is to use the LTE anchor cell that is active while n78 is working correctly.


## Logs

The script logs to the system log with the tag:

```text
5g-watchdog
```

You can filter the log for this tag to see what the watchdog is doing.

Example log messages include:

```text
Applying LTE lock
n78 OK
n78 missing
Trying reconnect
n78 restored after reconnect
Reconnect failed 3x, rebooting router
```

## Counters

The script stores temporary counters in `/tmp`:

```text
/tmp/no5g_count
/tmp/reconnect_fail_count
```

This means the counters reset after reboot. That is intentional.

## Important notes

This script locks the modem to a specific LTE cell. That can be useful in a fixed-location setup, but it may not be suitable for mobile use or for locations where the best serving cell changes often.

Use it only if you know which LTE anchor cell works best for your 5G NSA connection.

## Disclaimer

Use at your own risk.

This script is shared as a practical workaround for a specific NSA 5G stability issue. You should adjust it to your own router, modem, mobile operator, signal conditions, and local network setup.

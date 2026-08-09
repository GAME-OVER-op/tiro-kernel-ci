# Kurumi Power Monitor

Kurumi Power Monitor is a low-rate, userspace-only consumption recorder inside the Rust daemon.
It does not write files from the kernel and does not hold a wakelock.

## Storage

All history is stored under:

```text
/data/adb/kurumi_monitor/
```

Each system reboot creates or resumes a separate boot session based on:

```text
/proc/sys/kernel/random/boot_id
```

Data from different boot sessions is never mixed for deltas.
Old sessions are not deleted automatically.

## Sampling policy

The daemon records:

```text
boot_baseline: once after boot_completed when the daemon starts
hourly: once per hour during steady state
manual: when explicitly requested from the helper binary
```

The monitor is intentionally hourly to avoid making the recorder itself a battery consumer.

## Collected tables

Per boot session:

```text
snapshots.tsv       battery, charging, screen, uptime
wakeup_sources.tsv  kernel wakeup source counters
interrupts.tsv      /proc/interrupts totals
network.tsv         network interface rx/tx counters
thermal.tsv         thermal zone temperatures
uid_usage.tsv       /proc/uid_time_in_state totals when available
uid_io.tsv          /proc/uid_io/stats raw rows when available
processes.tsv       currently running processes at snapshot time
kernel_events.tsv   filtered dmesg lines for suspend/wlan/thermal/charger/ufs/etc.
packages.tsv        uid -> package mapping, captured once per boot session
meta.tsv            boot metadata
```

Global index:

```text
boot_sessions.tsv
last_snapshot_epoch
```

## Manual commands

The daemon copies itself to:

```text
/data/adb/kurumi_monitor/kurumi
```

Manual snapshot:

```sh
/data/adb/kurumi_monitor/kurumi --monitor-snapshot
```

Generate a simple boot-session summary table:

```sh
/data/adb/kurumi_monitor/kurumi --monitor-report
```

The report is written to:

```text
/data/adb/kurumi_monitor/reports/report_<epoch>.tsv
```

The report intentionally contains no verdicts or recommendations, only raw table summaries.

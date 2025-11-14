# stealmon – CPU Steal Time Monitor

`stealmon` is a small Linux tool that periodically samples CPU steal time from `/proc/stat` and writes it to a log file with timestamps.

It is intended to be dead simple to deploy (single Bash script + optional systemd unit) and useful for short- to medium-term analysis of CPU steal, for example when debugging noisy neighbors on virtualized environments.

## Features

* Samples CPU steal percentage in a fixed interval.
* Supports aggregate CPU or selected cores.
* Logs:

  * current steal percentage,
  * run-average steal percentage,
  * run-peak steal percentage,
  * sample count.
* Simple log rotation by size, with configurable retention.
* Designed to run as a long-lived service (e.g. via `systemd`).

## Requirements

* Linux system with `/proc/stat`.
* `bash`, `awk`, `stat`, `date`.
* No external dependencies.

## Installation

1. Copy the script:

   ```bash
   sudo cp stealmon.sh /usr/local/bin/stealmon.sh
   sudo chmod +x /usr/local/bin/stealmon.sh
   ```

2. (Optional) Install the `systemd` service:

   ```bash
   sudo cp stealmon.service /etc/systemd/system/stealmon.service
   sudo systemctl daemon-reload
   sudo systemctl enable --now stealmon.service
   ```

By default, logs are written to `/var/log/stealmon/stealmon.log`.

## Configuration

Configuration is done via environment variables:

* `INTERVAL_SECONDS` – sampling interval (default: `5`).
* `LOG_DIR` – directory for log files (default: `/var/log/stealmon`).
* `LOG_FILE_BASENAME` – log file base name (default: `stealmon`).
* `MAX_LOG_SIZE_BYTES` – rotate log when file size exceeds this value
  (default: `10485760` = 10 MiB).
* `RETENTION_FILES` – number of rotated logs to keep (default: `5`).
* `CPU_MODE` – one of:

  * `all` – aggregate CPU line from `/proc/stat` (default).
  * comma-separated CPU IDs, e.g. `0`, `0,1,2` – average of selected CPUs.

Example of running with custom settings:

```bash
INTERVAL_SECONDS=1 LOG_DIR=/tmp/stealmon CPU_MODE=0 ./stealmon.sh
```

## Log format

Each line (after the header) has the form:

```text
timestamp | steal_pct | run_avg_steal_pct | run_peak_steal_pct | samples
```

Example:

```text
# timestamp iso8601 | steal_pct | run_avg_steal_pct | run_peak_steal_pct | samples
2025-11-14T10:00:00+01:00 | 0.00 | 0.00 | 0.00 | 1
2025-11-14T10:00:05+01:00 | 2.35 | 1.18 | 2.35 | 2
2025-11-14T10:00:10+01:00 | 1.10 | 1.15 | 2.35 | 3
```

You can easily ingest this into tools like:

* `grep`, `awk`, `sed` for quick CLI analysis.
* `gnuplot`, `matplotlib`, etc., after importing as CSV (using `|` as a delimiter).

## Log rotation

When the main log file exceeds `MAX_LOG_SIZE_BYTES`, the script performs
simple size-based rotation:

* `stealmon.log` → `stealmon.log.1`
* `stealmon.log.1` → `stealmon.log.2`
* …
* Up to `RETENTION_FILES`.

If `RETENTION_FILES` is set to `0`, the current log is truncated instead
of being rotated.

## Usage as a service (systemd)

A basic `stealmon.service` unit file is provided:

```ini
[Unit]
Description=CPU steal time monitor
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/stealmon.sh
Restart=always
RestartSec=5
Environment=INTERVAL_SECONDS=5
Environment=LOG_DIR=/var/log/stealmon
Environment=MAX_LOG_SIZE_BYTES=10485760
Environment=RETENTION_FILES=5
Environment=CPU_MODE=all
User=root
Group=root

[Install]
WantedBy=multi-user.target
```

Enable and start:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now stealmon.service
```

Check status:

```bash
systemctl status stealmon.service
journalctl -u stealmon.service
```

## Inspecting metrics over a time period

Since each line is timestamped, you can filter by time or sample range.

### Show the last 20 samples

```bash
tail -n 20 /var/log/stealmon/stealmon.log
```

### Extract timestamps and steal%

```bash
grep -v '^#' /var/log/stealmon/stealmon.log \
  | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$1); gsub(/^[ \t]+|[ \t]+$/,"",$2); print $1, $2}'
```

### Compute average steal for the entire log

```bash
grep -v '^#' /var/log/stealmon/stealmon.log \
  | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$2); sum+=$2; n++} END {if (n>0) printf "avg_steal=%.2f%%\n", sum/n}'
```

### Filter samples between 10:00–11:00

```bash
grep '2025-11-14T10:' /var/log/stealmon/stealmon.log
```

## Notes

* Measures steal time as reported by the kernel via `/proc/stat`.

* Percentage is calculated as:

  ```text
  steal% = 100 * (delta_steal_jiffies / delta_total_jiffies)
  ```

* For multi-CPU configurations with several IDs in `CPU_MODE`, the
  script averages the per-CPU percentages.

## License

MIT
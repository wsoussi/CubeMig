#!/usr/bin/env python3
"""Summarize routing-demo HTTP probe CSV output."""

from __future__ import annotations

import argparse
import csv
import json
import statistics
from datetime import datetime
from pathlib import Path
from typing import Any


def parse_time(value: str | None) -> datetime | None:
    if not value:
        return None
    value = value.strip()
    if not value:
        return None
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    try:
        return datetime.fromisoformat(value)
    except ValueError:
        return None


def status_int(value: str | None) -> int | None:
    if value is None:
        return None
    value = value.strip()
    if not value.isdigit():
        return None
    return int(value)


def float_or_none(value: str | None) -> float | None:
    try:
        if value is None or value == "":
            return None
        return float(value)
    except ValueError:
        return None


def int_or_none(value: str | None) -> int | None:
    try:
        if value is None or value == "":
            return None
        return int(value)
    except ValueError:
        return None


def percentile(values: list[float], pct: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    rank = (pct / 100.0) * (len(ordered) - 1)
    lower = int(rank)
    upper = min(lower + 1, len(ordered) - 1)
    frac = rank - lower
    return ordered[lower] + (ordered[upper] - ordered[lower]) * frac


def latency_stats(rows: list[dict[str, Any]]) -> tuple[float | None, float | None, float | None]:
    values = [row["latency_ms"] for row in rows if row["latency_ms"] is not None]
    if not values:
        return None, None, None
    return statistics.mean(values), statistics.median(values), percentile(values, 95)


def is_success(row: dict[str, Any]) -> bool:
    status = row["http_status"]
    return status is not None and 200 <= status <= 299 and not row["error"]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe-csv", required=True)
    parser.add_argument("--metadata-json", required=True)
    parser.add_argument("--out-json", required=True)
    args = parser.parse_args()

    metadata = json.loads(Path(args.metadata_json).read_text(encoding="utf-8"))
    migration_start = parse_time(metadata.get("migration_command_start_time_utc"))
    migration_end = parse_time(metadata.get("migration_command_end_time_utc"))

    rows: list[dict[str, Any]] = []
    with Path(args.probe_csv).open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        for raw in reader:
            row = {
                "timestamp": parse_time(raw.get("timestamp_utc")),
                "request_id": raw.get("request_id", ""),
                "http_status": status_int(raw.get("http_status")),
                "latency_ms": float_or_none(raw.get("latency_ms")),
                "counter": int_or_none(raw.get("counter")),
                "cluster": raw.get("cluster", ""),
                "version": raw.get("version", ""),
                "body": raw.get("body", ""),
                "error": (raw.get("error") or "").strip(),
            }
            rows.append(row)

    successes = [row for row in rows if is_success(row)]
    pre_successes = [
        row for row in successes
        if migration_start is not None and row["timestamp"] is not None and row["timestamp"] < migration_start
    ]
    post_successes = [
        row for row in successes
        if migration_end is not None and row["timestamp"] is not None and row["timestamp"] > migration_end
    ]
    pre_mean, pre_median, pre_p95 = latency_stats(pre_successes)
    post_mean, post_median, post_p95 = latency_stats(post_successes)

    outage_failed: dict[str, Any] | None = None
    if migration_start is not None:
        for row in rows:
            ts = row["timestamp"]
            if ts is not None and ts >= migration_start and not is_success(row):
                outage_failed = row
                break

    last_success_before_outage: dict[str, Any] | None = None
    first_success_after_outage: dict[str, Any] | None = None
    if outage_failed is not None and outage_failed["timestamp"] is not None:
        outage_ts = outage_failed["timestamp"]
        before = [
            row for row in successes
            if row["timestamp"] is not None and row["timestamp"] < outage_ts
        ]
        after = [
            row for row in successes
            if row["timestamp"] is not None and row["timestamp"] > outage_ts
        ]
        if before:
            last_success_before_outage = before[-1]
        if after:
            first_success_after_outage = after[0]

    downtime_ms: float | None = None
    if last_success_before_outage is not None and first_success_after_outage is not None:
        before_ts = last_success_before_outage["timestamp"]
        after_ts = first_success_after_outage["timestamp"]
        if before_ts is not None and after_ts is not None:
            downtime_ms = (after_ts - before_ts).total_seconds() * 1000

    counter_before = last_success_before_outage["counter"] if last_success_before_outage else None
    counter_after = first_success_after_outage["counter"] if first_success_after_outage else None
    state_preserved: bool | None
    if counter_before is None or counter_after is None:
        state_preserved = None
    else:
        state_preserved = counter_after == counter_before + 1

    timeout_count = 0
    for row in rows:
        err = row["error"].lower()
        if row["http_status"] == 0 and ("timeout" in err or "timed out" in err):
            timeout_count += 1

    result = {
        "total_requests": len(rows),
        "http_2xx_count": len(successes),
        "http_503_count": sum(1 for row in rows if row["http_status"] == 503),
        "timeout_count": timeout_count,
        "error_count": sum(1 for row in rows if row["error"] or row["http_status"] == 0),
        "latency_pre_mean_ms": pre_mean,
        "latency_pre_median_ms": pre_median,
        "latency_pre_p95_ms": pre_p95,
        "latency_post_mean_ms": post_mean,
        "latency_post_median_ms": post_median,
        "latency_post_p95_ms": post_p95,
        "last_success_before_outage_timestamp": (
            last_success_before_outage["timestamp"].isoformat().replace("+00:00", "Z")
            if last_success_before_outage and last_success_before_outage["timestamp"] else None
        ),
        "first_success_after_outage_timestamp": (
            first_success_after_outage["timestamp"].isoformat().replace("+00:00", "Z")
            if first_success_after_outage and first_success_after_outage["timestamp"] else None
        ),
        "client_downtime_ms": downtime_ms,
        "counter_before": counter_before,
        "counter_after": counter_after,
        "state_preserved": state_preserved,
    }

    Path(args.out_json).write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

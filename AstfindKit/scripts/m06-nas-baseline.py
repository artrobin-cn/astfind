#!/usr/bin/env python3
"""M0.6 NAS interaction baseline harness.

Measures file-open proxies (sips / qlmanage) or summarizes already measured
manual samples. It intentionally does NOT claim to measure "content visible";
that requires a timestamped screen recording and must be labelled separately.

Raw samples stay on this machine. Only the sanitized summary belongs in the
handoff; file paths are replaced by stable tokens (file-01, file-02, ...).
"""

import argparse
import csv
import json
import math
import os
import platform
import statistics
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone

PROXY_OPERATIONS = ("sips", "qlmanage")
MEASUREMENTS = ("proxy-read", "launch-accept", "content-visible")
BACKGROUND_STATES = ("idle", "scanner", "ocr", "embed", "all")


def nearest_rank(values, percentile):
    if not values:
        return None
    ordered = sorted(values)
    rank = max(1, int(math.ceil(percentile * len(ordered))))
    return ordered[rank - 1]


def summary(values):
    if not values:
        return {"n": 0, "p50_ms": None, "p95_ms": None, "max_ms": None}
    return {
        "n": len(values),
        "p50_ms": round(statistics.median(values), 3),
        "p95_ms": round(nearest_rank(values, 0.95), 3),
        "max_ms": round(max(values), 3),
    }


def code_version():
    try:
        root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        return subprocess.check_output(
            ["git", "-C", root, "rev-parse", "--short", "HEAD"],
            text=True, stderr=subprocess.DEVNULL).strip()
    except Exception:
        return "unknown"


def environment():
    try:
        macos = subprocess.check_output(["sw_vers", "-productVersion"],
                                        text=True, stderr=subprocess.DEVNULL).strip()
    except Exception:
        macos = platform.mac_ver()[0]
    return {
        "os": "macOS",
        "os_version": macos,
        "machine": platform.machine(),
        "python": platform.python_version(),
        "code_version": code_version(),
        "started_at": datetime.now(timezone.utc).isoformat(),
    }


def read_files(args):
    files = []
    if args.files:
        with open(args.files, "r", encoding="utf-8") as handle:
            files.extend(line.strip() for line in handle if line.strip())
    files.extend(args.file or [])
    if not files:
        raise SystemExit("provide --files <list> or --file <path>")
    for path in files:
        if not os.path.isfile(path):
            raise SystemExit("not a file: %s" % path)
    return files


def measure_once(path, operation):
    began = time.perf_counter()
    if operation == "sips":
        result = subprocess.run(["sips", "-g", "pixelWidth", path],
                                stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL)
        ok = result.returncode == 0
    else:
        with tempfile.TemporaryDirectory(prefix="astfind-m06-ql-") as directory:
            result = subprocess.run(["qlmanage", "-t", "-s", "256", "-o", directory, path],
                                    stdout=subprocess.DEVNULL,
                                    stderr=subprocess.DEVNULL)
            ok = result.returncode == 0
    return (time.perf_counter() - began) * 1000.0, ok


def run_proxy(args):
    files = read_files(args)
    samples = []
    warmup = max(0, args.warmup)
    total = warmup + args.samples
    for index in range(total):
        if args.file_mode == "same":
            path = files[0]
            token = "file-01"
        else:
            position = index % len(files)
            path = files[position]
            token = "file-%02d" % (position + 1)
        started_wall = time.time()
        duration_ms, ok = measure_once(path, args.operation)
        if index < warmup:
            continue
        samples.append({
            "sample": index - warmup + 1,
            "file_token": token,
            "duration_ms": round(duration_ms, 3),
            "success": 1 if ok else 0,
            "started_at": round(started_wall, 3),
            "finished_at": round(time.time(), 3),
        })
        if args.interval_ms > 0 and index < total - 1:
            time.sleep(args.interval_ms / 1000.0)
    return samples


def read_duration_csv(path, column):
    values, rows = [], []
    with open(path, "r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        if column not in (reader.fieldnames or []):
            raise SystemExit("column %s not found in %s" % (column, path))
        for index, row in enumerate(reader, start=1):
            try:
                value = float(row[column])
            except (TypeError, ValueError):
                continue
            values.append(value)
            rows.append({"sample": index, "file_token": row.get("file_token", "manual"),
                         "duration_ms": value, "success": 1})
    return rows, values


def write_outputs(args, samples, values):
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    os.makedirs(args.output_dir, exist_ok=True)
    stem = "%s.%s" % (args.label, stamp)
    samples_path = os.path.join(args.output_dir, stem + ".samples.csv")
    summary_path = os.path.join(args.output_dir, stem + ".summary.json")

    with open(samples_path, "w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=[
            "sample", "file_token", "duration_ms", "success", "phase", "measurement",
            "background", "pacer", "source_label", "asset_count", "file_mode",
            "cache_group", "scan_run", "started_at", "finished_at"])
        writer.writeheader()
        for row in samples:
            writer.writerow(dict(row, phase=args.phase, measurement=args.measurement,
                                 background=args.background, pacer=args.pacer,
                                 source_label=args.source_label,
                                 asset_count=args.asset_count, file_mode=args.file_mode,
                                 cache_group=args.cache_group, scan_run=args.scan_run))

    result = {
        "phase": args.phase,
        "measurement": args.measurement,
        "operation": ("input-csv" if args.input_csv else
                      ("manual" if args.duration_ms else args.operation)),
        "background": args.background,
        "pacer": args.pacer,
        "cache_group": args.cache_group,
        "scan_run": args.scan_run,
        "source_label": args.source_label,
        "asset_count": args.asset_count,
        "file_mode": args.file_mode,
        "warmup": args.warmup,
        "samples": args.samples,
        "sample_interval_ms": args.interval_ms,
        "summary": summary(values),
        "environment": environment(),
        "raw_samples": os.path.basename(samples_path),
        "notes": args.notes or "",
    }
    with open(summary_path, "w", encoding="utf-8") as handle:
        json.dump(result, handle, ensure_ascii=False, indent=2)

    print(json.dumps(result["summary"], ensure_ascii=False))
    print("samples: %s" % samples_path)
    print("summary: %s" % summary_path)
    if args.measurement == "proxy-read" and args.samples < 30:
        print("WARNING: acceptance requires at least 30 proxy samples; this run has %d"
              % args.samples, file=sys.stderr)


def build_parser():
    parser = argparse.ArgumentParser(description="Astfind M0.6 NAS interaction baseline")
    parser.add_argument("--phase", required=True,
                        help="A-G matrix label (A idle, B scanner/pacer-off, C scanner/pacer-on, ...)")
    parser.add_argument("--measurement", choices=MEASUREMENTS, default="proxy-read")
    parser.add_argument("--background", choices=BACKGROUND_STATES, default="scanner")
    parser.add_argument("--pacer", choices=("on", "off"), default="off")
    parser.add_argument("--source-label", default="reference-smb",
                        help="sanitized source label; never put a real host/path here")
    parser.add_argument("--cache-group", choices=("cold", "hot", "unknown"), default="unknown",
                        help="cold = not recently read; hot = repeated read; must be reported separately")
    parser.add_argument("--scan-run", default="",
                        help="optional scanRunId / run label this sample belongs to")
    parser.add_argument("--asset-count", type=int, default=0)
    parser.add_argument("--samples", type=int, default=30)
    parser.add_argument("--interval-ms", type=int, default=0,
                        help="optional pause between proxy samples; spread samples across a long scan")
    parser.add_argument("--warmup", type=int, default=0)
    parser.add_argument("--file-mode", choices=("cycle", "same"), default="cycle",
                        help="cycle first-visit files; same = explicit hot-cache group")
    parser.add_argument("--operation", choices=PROXY_OPERATIONS, default="sips")
    parser.add_argument("--files", help="text file with one absolute path per line")
    parser.add_argument("--file", action="append", help="absolute path (repeatable)")
    parser.add_argument("--input-csv", help="summarize an existing CSV instead of measuring")
    parser.add_argument("--column", default="duration_ms")
    parser.add_argument("--duration-ms", type=float, action="append",
                        help="manual duration sample (repeatable; for UI measurements)")
    parser.add_argument("--output-dir", default=os.path.join(os.getcwd(), "m06-raw"))
    parser.add_argument("--label", default="m06")
    parser.add_argument("--notes", default="")
    return parser


def main():
    args = build_parser().parse_args()
    if args.input_csv:
        samples, values = read_duration_csv(args.input_csv, args.column)
        args.samples = len(values)
        write_outputs(args, samples, values)
    elif args.duration_ms:
        samples = [{"sample": index + 1, "file_token": "manual",
                    "duration_ms": round(value, 3), "success": 1}
                   for index, value in enumerate(args.duration_ms)]
        values = [row["duration_ms"] for row in samples]
        args.samples = len(values)
        write_outputs(args, samples, values)
    else:
        if args.measurement != "proxy-read":
            raise SystemExit("launch-accept/content-visible need --input-csv or --duration-ms "
                             "(manual timestamped measurement)")
        samples = run_proxy(args)
        values = [row["duration_ms"] for row in samples if row["success"]]
        write_outputs(args, samples, values)


if __name__ == "__main__":
    main()

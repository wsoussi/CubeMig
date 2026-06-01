#!/usr/bin/env python3
"""Normalize CRIU checkpoint mount metadata for CubeMig migrations.

This removes selected non-portable OCI/Kubernetes masked proc/sys mount
entries from CRIU mountpoints images before CubeMig builds a checkpoint image.
It is not a kernel upgrade workaround: target CRIU compatibility still matters.
The confirmed failure this handles is /proc/latency_stats being present in a
checkpoint created on cluster-sev-snp but absent on cluster1 worker2.
"""

from __future__ import annotations

import argparse
import json
import os
import posixpath
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path
from typing import Any


DEFAULT_BAD_MOUNTS = (
    "/proc/latency_stats",
    "/proc/timer_stats",
    "/proc/sched_debug",
    "/sys/devices/virtual/powercap",
)


class NormalizationError(RuntimeError):
    """Raised for expected normalization failures with user-facing messages."""


class Logger:
    def __init__(self, log_file: Path | None) -> None:
        self.log_file = log_file

    def log(self, message: str) -> None:
        print(message)
        if self.log_file is not None:
            self.log_file.parent.mkdir(parents=True, exist_ok=True)
            with self.log_file.open("a", encoding="utf-8") as fh:
                fh.write(f"{message}\n")


def parse_bool(value: str) -> bool:
    normalized = value.strip().lower()
    if normalized in {"true", "1", "yes", "y"}:
        return True
    if normalized in {"false", "0", "no", "n"}:
        return False
    raise argparse.ArgumentTypeError("expected true or false")


def normalize_mountpoint(mountpoint: str) -> str:
    if not mountpoint:
        return ""
    normalized = posixpath.normpath(mountpoint)
    if not normalized.startswith("/"):
        normalized = f"/{normalized}"
    return normalized


def run_command(cmd: list[str], context: str) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            cmd,
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except FileNotFoundError as exc:
        raise NormalizationError(f"{context} failed: command not found: {cmd[0]}") from exc
    except subprocess.CalledProcessError as exc:
        details = (exc.stderr or exc.stdout or "").strip()
        if details:
            raise NormalizationError(f"{context} failed: {details}") from exc
        raise NormalizationError(f"{context} failed with exit code {exc.returncode}") from exc


def safe_extract_tar(checkpoint_tar: Path, destination: Path) -> None:
    try:
        with tarfile.open(checkpoint_tar, "r:*") as tar:
            for member in tar.getmembers():
                member_path = Path(member.name)
                if member_path.is_absolute() or ".." in member_path.parts:
                    raise NormalizationError(
                        f"unsafe tar member path in checkpoint archive: {member.name}"
                    )
            for member in tar.getmembers():
                # Avoid preserving root-owned/restrictive checkpoint member attrs in
                # the temporary workspace; crit must be able to read/write images.
                tar.extract(member, destination, set_attrs=False)
    except tarfile.TarError as exc:
        raise NormalizationError(f"failed to extract checkpoint tar: {exc}") from exc


def repack_tar(source_dir: Path, output_tar: Path) -> None:
    output_tar.parent.mkdir(parents=True, exist_ok=True)
    temp_output = output_tar.with_name(f".{output_tar.name}.tmp")
    if temp_output.exists():
        temp_output.unlink()
    try:
        with tarfile.open(temp_output, "w") as tar:
            for path in sorted(source_dir.rglob("*")):
                arcname = path.relative_to(source_dir).as_posix()
                tar.add(path, arcname=arcname, recursive=False)
        os.chmod(temp_output, 0o644)
        os.replace(temp_output, output_tar)
    except (OSError, tarfile.TarError) as exc:
        raise NormalizationError(f"failed to repack normalized checkpoint tar: {exc}") from exc
    finally:
        if temp_output.exists():
            temp_output.unlink()


def copy_checkpoint_tar(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)
    os.chmod(destination, 0o644)


def load_mountpoints_json(image_path: Path) -> dict[str, Any]:
    decoded_path = image_path.with_suffix(f"{image_path.suffix}.json")
    os.chmod(image_path, os.stat(image_path).st_mode | 0o600)
    run_command(
        ["crit", "decode", "--pretty", "-i", str(image_path), "-o", str(decoded_path)],
        f"crit decode {image_path}",
    )
    try:
        with decoded_path.open("r", encoding="utf-8") as fh:
            return json.load(fh)
    except json.JSONDecodeError as exc:
        raise NormalizationError(f"crit decoded invalid JSON for {image_path}: {exc}") from exc
    finally:
        decoded_path.unlink(missing_ok=True)


def encode_mountpoints_json(image_path: Path, data: dict[str, Any]) -> None:
    json_path = image_path.with_suffix(f"{image_path.suffix}.normalized.json")
    encoded_tmp = image_path.with_suffix(f"{image_path.suffix}.normalized")
    try:
        with json_path.open("w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2)
            fh.write("\n")
        os.chmod(image_path, os.stat(image_path).st_mode | 0o600)
        run_command(
            ["crit", "encode", "-i", str(json_path), "-o", str(encoded_tmp)],
            f"crit encode {image_path}",
        )
        os.replace(encoded_tmp, image_path)
    finally:
        json_path.unlink(missing_ok=True)
        encoded_tmp.unlink(missing_ok=True)


def removable_entries(
    data: dict[str, Any],
    bad_mounts: set[str],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    entries = data.get("entries")
    if not isinstance(entries, list):
        raise NormalizationError("mountpoints image JSON does not contain an entries list")

    parent_ids = {
        entry.get("parent_mnt_id")
        for entry in entries
        if isinstance(entry, dict) and entry.get("parent_mnt_id") is not None
    }
    removed: list[dict[str, Any]] = []
    kept: list[dict[str, Any]] = []

    for entry in entries:
        if not isinstance(entry, dict):
            kept.append(entry)
            continue
        mountpoint = normalize_mountpoint(str(entry.get("mountpoint", "")))
        is_bad_mount = mountpoint in bad_mounts
        is_leaf = entry.get("mnt_id") not in parent_ids
        if is_bad_mount and is_leaf:
            removed.append(entry)
        else:
            kept.append(entry)

    return removed, kept


def normalize_checkpoint(
    checkpoint_tar: Path,
    output_tar: Path | None,
    in_place: bool,
    dry_run: bool,
    bad_mounts: set[str],
    strict: bool,
    logger: Logger,
) -> int:
    if shutil.which("crit") is None:
        raise NormalizationError("crit is not installed or not in PATH")

    checkpoint_tar = checkpoint_tar.resolve()
    if not checkpoint_tar.is_file():
        raise NormalizationError(f"checkpoint tar does not exist: {checkpoint_tar}")

    if dry_run:
        final_output = None
    elif in_place:
        final_output = checkpoint_tar
    else:
        if output_tar is None:
            name = checkpoint_tar.name
            if name.endswith(".tar"):
                name = f"{name[:-4]}.normalized.tar"
            else:
                name = f"{name}.normalized.tar"
            output_tar = checkpoint_tar.with_name(name)
        final_output = output_tar.resolve()
        if final_output == checkpoint_tar:
            raise NormalizationError("output path must differ from input unless --in-place is set")

    logger.log(f"checkpoint tar: {checkpoint_tar}")
    logger.log(f"bad mount list: {', '.join(sorted(bad_mounts))}")
    if dry_run:
        logger.log("dry-run: true")
    elif final_output is not None:
        logger.log(f"normalized checkpoint tar: {final_output}")

    with tempfile.TemporaryDirectory(prefix="cubemig-criu-normalize-") as tmp:
        extract_dir = Path(tmp) / "checkpoint"
        extract_dir.mkdir()
        safe_extract_tar(checkpoint_tar, extract_dir)

        mountpoint_images = sorted(extract_dir.rglob("mountpoints-*.img"))
        if not mountpoint_images:
            message = "checkpoint tar does not contain mountpoints-*.img"
            if strict:
                raise NormalizationError(message)
            logger.log(f"warning: {message}")
            if not dry_run and final_output is not None and final_output != checkpoint_tar:
                copy_checkpoint_tar(checkpoint_tar, final_output)
            return 0

        total_removed = 0
        for image_path in mountpoint_images:
            data = load_mountpoints_json(image_path)
            removed, kept = removable_entries(data, bad_mounts)
            if not removed:
                continue

            total_removed += len(removed)
            for entry in removed:
                action = "dry-run removable mount entry" if dry_run else "removed mount entry"
                logger.log(
                    f"{action}: "
                    f"image={image_path.relative_to(extract_dir)} "
                    f"mnt_id={entry.get('mnt_id', '')} "
                    f"parent_mnt_id={entry.get('parent_mnt_id', '')} "
                    f"mountpoint={entry.get('mountpoint', '')} "
                    f"root={entry.get('root', '')} "
                    f"source={entry.get('source', '')}"
                )

            if not dry_run:
                data["entries"] = kept
                encode_mountpoints_json(image_path, data)

        if total_removed == 0:
            logger.log("no normalization needed")
            if not dry_run and final_output is not None and final_output != checkpoint_tar:
                copy_checkpoint_tar(checkpoint_tar, final_output)
            return 0

        logger.log(f"removed mount entries: {total_removed}")
        if not dry_run and final_output is not None:
            if in_place:
                temp_in_place = checkpoint_tar.with_name(f".{checkpoint_tar.name}.normalized.tmp")
                repack_tar(extract_dir, temp_in_place)
                os.replace(temp_in_place, checkpoint_tar)
                os.chmod(checkpoint_tar, 0o644)
            else:
                repack_tar(extract_dir, final_output)

        return total_removed


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Remove selected non-portable OCI/Kubernetes masked proc/sys mount "
            "entries from CRIU checkpoint mountpoints images."
        )
    )
    parser.add_argument("--checkpoint-tar", required=True, type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--in-place", action="store_true")
    parser.add_argument("--bad-mount", action="append", default=[])
    parser.add_argument("--log-file", type=Path)
    parser.add_argument("--strict", type=parse_bool, default=True)
    parser.add_argument("--dry-run", action="store_true")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.in_place and args.output is not None:
        parser.error("--output cannot be combined with --in-place")

    bad_mount_values = args.bad_mount if args.bad_mount else list(DEFAULT_BAD_MOUNTS)
    bad_mounts = {normalize_mountpoint(value) for value in bad_mount_values if value.strip()}
    if not bad_mounts:
        parser.error("bad mount list must not be empty")

    logger = Logger(args.log_file)
    try:
        normalize_checkpoint(
            checkpoint_tar=args.checkpoint_tar,
            output_tar=args.output,
            in_place=args.in_place,
            dry_run=args.dry_run,
            bad_mounts=bad_mounts,
            strict=args.strict,
            logger=logger,
        )
    except NormalizationError as exc:
        logger.log(f"ERROR: {exc}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

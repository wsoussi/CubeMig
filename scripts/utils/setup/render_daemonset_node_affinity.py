#!/usr/bin/env python3
"""Inject a nodeAffinity that restricts a DaemonSet (or Pod) to a given list of node hostnames.

Used by single-migration.sh so DaemonSet pods do not get scheduled on NotReady or
cordoned (SchedulingDisabled) nodes — by default the DaemonSet controller adds tolerations for
node.kubernetes.io/unschedulable and node.kubernetes.io/not-ready, which lets DaemonSet pods land
on those nodes. We work around that by setting requiredDuringSchedulingIgnoredDuringExecution
nodeAffinity on kubernetes.io/hostname In (<ready,schedulable nodes>).

Usage:
    render_daemonset_node_affinity.py <input_manifest> <output_manifest> <node_name> [<node_name>...]

If no node names are passed the input is copied through unchanged (no-op fail-open: if we cannot
discover the node list, do not block the migration).
"""

from __future__ import annotations

import shutil
import sys
from pathlib import Path

import yaml


HOSTNAME_LABEL = "kubernetes.io/hostname"


def _build_affinity_block(node_names: list[str]) -> dict:
    return {
        "nodeAffinity": {
            "requiredDuringSchedulingIgnoredDuringExecution": {
                "nodeSelectorTerms": [
                    {
                        "matchExpressions": [
                            {
                                "key": HOSTNAME_LABEL,
                                "operator": "In",
                                "values": list(node_names),
                            }
                        ]
                    }
                ]
            }
        }
    }


def _merge_hostname_in(existing: dict, node_names: list[str]) -> dict:
    """Replace any existing kubernetes.io/hostname In/NotIn expression with our list, leaving
    everything else (other matchExpressions / matchFields, other nodeSelectorTerms) untouched."""
    affinity = existing.setdefault("nodeAffinity", {})
    required = affinity.setdefault("requiredDuringSchedulingIgnoredDuringExecution", {})
    terms = required.setdefault("nodeSelectorTerms", [])
    if not terms:
        terms.append({"matchExpressions": []})

    new_expr = {
        "key": HOSTNAME_LABEL,
        "operator": "In",
        "values": list(node_names),
    }

    for term in terms:
        match_expressions = term.setdefault("matchExpressions", [])
        replaced = False
        for i, expr in enumerate(match_expressions):
            if expr.get("key") == HOSTNAME_LABEL:
                match_expressions[i] = new_expr
                replaced = True
                break
        if not replaced:
            match_expressions.append(dict(new_expr))
    return existing


def _inject_pod_spec_affinity(pod_spec: dict, node_names: list[str]) -> None:
    affinity = pod_spec.get("affinity") or {}
    if affinity:
        pod_spec["affinity"] = _merge_hostname_in(affinity, node_names)
    else:
        pod_spec["affinity"] = _build_affinity_block(node_names)


def _inject_into_doc(doc: dict, node_names: list[str]) -> dict:
    if not isinstance(doc, dict):
        return doc
    kind = doc.get("kind")
    if kind in ("DaemonSet", "Deployment", "StatefulSet", "ReplicaSet", "Job"):
        spec = doc.setdefault("spec", {})
        template = spec.setdefault("template", {})
        pod_spec = template.setdefault("spec", {})
        _inject_pod_spec_affinity(pod_spec, node_names)
    elif kind == "CronJob":
        spec = doc.setdefault("spec", {})
        job_template = spec.setdefault("jobTemplate", {})
        job_spec = job_template.setdefault("spec", {})
        template = job_spec.setdefault("template", {})
        pod_spec = template.setdefault("spec", {})
        _inject_pod_spec_affinity(pod_spec, node_names)
    elif kind == "Pod":
        pod_spec = doc.setdefault("spec", {})
        _inject_pod_spec_affinity(pod_spec, node_names)
    return doc


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(
            "usage: render_daemonset_node_affinity.py <input> <output> [<node_name>...]",
            file=sys.stderr,
        )
        return 2

    input_path = Path(argv[1])
    output_path = Path(argv[2])
    node_names = [n for n in argv[3:] if n.strip()]

    if not input_path.exists():
        print(f"input manifest not found: {input_path}", file=sys.stderr)
        return 2

    if not node_names:
        # Fail-open: leave the manifest untouched so a discovery failure cannot block migration.
        if input_path.resolve() != output_path.resolve():
            shutil.copyfile(input_path, output_path)
        return 0

    with input_path.open("r") as fh:
        docs = list(yaml.safe_load_all(fh))

    rendered = [_inject_into_doc(doc, node_names) for doc in docs if doc is not None]

    with output_path.open("w") as fh:
        yaml.safe_dump_all(rendered, fh, sort_keys=False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

#!/usr/bin/env python3
"""Dependency-light structural validation for the Runner repository."""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read_json(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise AssertionError(f"Invalid JSON in {path.relative_to(ROOT)}: {exc}") from exc


def safe_relative_path(value: str) -> bool:
    if not isinstance(value, str) or not value or value.startswith("/") or "\\" in value:
        return False
    parts = value.split("/")
    return all(part not in ("", ".", "..") for part in parts)


def main() -> int:
    try:
        from jsonschema import Draft202012Validator, FormatChecker
    except ImportError:
        Draft202012Validator = None
        FormatChecker = None

    schema_paths = sorted((ROOT / "contracts" / "v1").glob("*.schema.json"))
    assert {p.name for p in schema_paths} == {
        "action.schema.json", "job.schema.json", "result.schema.json"
    }, "Missing versioned contract schema."
    schemas = {path.name: read_json(path) for path in schema_paths}

    if Draft202012Validator is not None:
        for schema in schemas.values():
            Draft202012Validator.check_schema(schema)

    manifests = {}
    action_dirs = {}
    action_schema = schemas["action.schema.json"]
    for manifest_path in sorted((ROOT / "actions").glob("*/action.json")):
        manifest = read_json(manifest_path)
        if Draft202012Validator is not None:
            Draft202012Validator(action_schema).validate(manifest)
        assert manifest.get("schemaVersion") == 1, f"Unsupported manifest schema: {manifest_path}"
        action_id = manifest.get("id")
        assert isinstance(action_id, str) and re.fullmatch(r"[a-z][a-z0-9-]*\.[a-z][a-z0-9-]*", action_id), f"Invalid action id: {manifest_path}"
        assert action_id not in manifests, f"Duplicate action id: {action_id}"
        assert re.fullmatch(r"\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?", manifest.get("version", "")), f"Invalid version: {action_id}"
        action_dir = manifest_path.parent
        assert safe_relative_path(manifest["execution"]["entrypoint"]), f"Unsafe entrypoint: {action_id}"
        assert (action_dir / manifest["execution"]["entrypoint"]).is_file(), f"Missing entrypoint: {action_id}"
        payload_schema_path = action_dir / manifest["input"]["payloadSchema"]
        payload_schema = read_json(payload_schema_path)
        if Draft202012Validator is not None:
            Draft202012Validator.check_schema(payload_schema)
        variants = manifest["execution"]["variants"]
        assert manifest["execution"]["defaultVariant"] in variants, f"Unknown default variant: {action_id}"
        for variant_name, variant in variants.items():
            dockerfile = variant["dockerfile"]
            assert safe_relative_path(dockerfile), f"Unsafe Dockerfile path: {action_id}/{variant_name}"
            assert (action_dir / dockerfile).is_file(), f"Missing Dockerfile: {action_id}/{variant_name}"
            resources = variant["resources"]
            assert isinstance(resources.get("network"), bool), f"Missing network flag: {action_id}/{variant_name}"
            assert float(resources.get("cpus", 0)) > 0, f"Invalid CPU limit: {action_id}/{variant_name}"
        manifests[action_id] = manifest
        action_dirs[action_id] = action_dir

    assert manifests, "No actions found."

    job_schema = schemas["job.schema.json"]
    examples = sorted((ROOT / "examples/jobs").glob("*.json"))
    assert examples, "No example jobs found."
    for example_path in examples:
        job = read_json(example_path)
        if Draft202012Validator is not None:
            Draft202012Validator(job_schema, format_checker=FormatChecker()).validate(job)
        assert job.get("schemaVersion") == 1, f"Invalid schemaVersion: {example_path}"
        action_id = job.get("action")
        assert action_id in manifests, f"Example references unknown action: {example_path}"
        manifest = manifests[action_id]
        assert job.get("actionVersion") == manifest["version"], f"Version mismatch: {example_path}"
        assert isinstance(job.get("payload"), dict), f"Missing payload object: {example_path}"
        payload_schema = read_json(action_dirs[action_id] / manifest["input"]["payloadSchema"])
        if Draft202012Validator is not None:
            Draft202012Validator(payload_schema, format_checker=FormatChecker()).validate(job["payload"])
        selector = manifest["execution"].get("selector")
        selected = job["payload"].get(selector.split(".")[-1]) if selector else manifest["execution"]["defaultVariant"]
        assert selected in manifest["execution"]["variants"], f"Invalid variant in {example_path}: {selected}"

    assert safe_relative_path("post.png")
    assert safe_relative_path("nested/post.png")
    assert not safe_relative_path("../escape.png")
    assert not safe_relative_path("/tmp/escape.png")
    assert not safe_relative_path("nested/../escape.png")

    svg_template = ROOT / "actions/template-image-render/templates/feature-announcement/template.svg"
    html_template = ROOT / "actions/template-image-render/templates/feature-announcement/index.html"
    assert svg_template.is_file() and html_template.is_file()
    for token in ("{{TITLE}}", "{{SUBTITLE}}", "{{EYEBROW}}", "{{ACCENT}}"):
        assert token in svg_template.read_text(encoding="utf-8"), f"Missing SVG token {token}"
        assert token in html_template.read_text(encoding="utf-8"), f"Missing HTML token {token}"

    if Draft202012Validator is None:
        print("Note: python-jsonschema is not installed; ran structural checks only.")
    print(f"Validated {len(manifests)} action(s), {len(examples)} example job(s), and {len(schema_paths)} schema(s).")
    print("Static validation passed. Docker rendering must be tested separately.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as exc:
        print(f"VALIDATION FAILED: {exc}", file=sys.stderr)
        raise SystemExit(1)

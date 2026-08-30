#!/usr/bin/env python3
"""Governance gate for Soundboard.

Enforces the machine-checkable subset of DATA_GOVERNANCE.md.
Exit 0 = pass, 1 = violations found, 2 = gate could not run.

Usage:
    python3 governance/check.py            # full gate
    python3 governance/check.py --pr FILE  # also check a PR body for the Compliance Block
"""
from __future__ import annotations

import datetime as dt
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.stderr.write("governance gate cannot run: pyyaml is missing. Install it with 'pip install pyyaml'.\n")
    raise SystemExit(2)

ROOT = Path(__file__).resolve().parent.parent
GOV = ROOT / "governance"
VALID_CLASSES = {"C0", "C1", "C2", "C3", "C4"}
PROTECTED = {"C2", "C3"}
SCAN_SUFFIXES = {".py", ".ts", ".tsx", ".js", ".jsx", ".go", ".rb", ".java", ".kt", ".swift", ".rs", ".sql", ".sh", ".yaml", ".yml", ".json", ".toml"}
SCAN_SKIP = {"node_modules", ".git", "dist", "build", "vendor", ".venv", "venv", "governance", "__pycache__"}

violations: list[str] = []


def fail(rule: str, msg: str) -> None:
    violations.append(f"{rule}  {msg}")


def load(name: str) -> dict:
    path = GOV / name
    if not path.exists():
        fail("DG-CLASS-03", f"missing required manifest governance/{name}")
        return {}
    try:
        return yaml.safe_load(path.read_text()) or {}
    except yaml.YAMLError as exc:
        fail("DG-CLASS-03", f"governance/{name} is not valid YAML: {exc}")
        return {}


# ---------------------------------------------------------------- manifests

purposes_doc = load("purposes.yaml")
vendors_doc = load("vendors.yaml")
datamap_doc = load("data-map.yaml")

purpose_ids = {p.get("id") for p in (purposes_doc.get("purposes") or [])}
retention_ids = set((datamap_doc.get("retention_policies") or {}).keys())

for p in purposes_doc.get("purposes") or []:
    pid = p.get("id", "<unnamed>")
    consent_basis = p.get("lawful_basis") == "consent"
    if consent_basis != bool(p.get("consent_required")):
        fail("DG-PURP-01", f"purpose {pid}: lawful_basis and consent_required disagree")
    for cls in p.get("data_classes") or []:
        if cls not in VALID_CLASSES:
            fail("DG-CLASS-01", f"purpose {pid}: unknown data class {cls}")
    if p.get("retention_ref") and p["retention_ref"] not in retention_ids:
        fail("DG-RET-01", f"purpose {pid}: retention_ref '{p['retention_ref']}' is not defined in data-map.yaml")

for v in vendors_doc.get("vendors") or []:
    vid = v.get("id", "<unnamed>")
    classes = set(v.get("data_classes") or [])
    if classes & PROTECTED and v.get("dpa_status") != "executed":
        fail("DG-VEND-02", f"vendor {vid}: receives {sorted(classes & PROTECTED)} without an executed DPA")
    if v.get("hosting_region") != "us":
        fail("DG-VEND-04", f"vendor {vid}: hosting_region must be 'us' at v1.0")
    if v.get("model_provider") and not classes <= {"C0", "C1"}:
        fail("DG-VEND-05", f"vendor {vid}: model providers are capped at C1, found {sorted(classes)}")
    for pid in v.get("purpose_ids") or []:
        if pid not in purpose_ids:
            fail("DG-PURP-01", f"vendor {vid}: unregistered purpose {pid}")
    if not v.get("approved_by"):
        fail("DG-VEND-01", f"vendor {vid}: missing governance approval")


def check_record(kind: str, label: str, rec: dict) -> None:
    cls = rec.get("class")
    if cls not in VALID_CLASSES:
        fail("DG-CLASS-02", f"{kind} {label}: missing or invalid class (untagged is treated as C3)")
    pids = rec.get("purpose_ids") or []
    if not pids:
        fail("DG-PURP-03", f"{kind} {label}: no registered purpose consumes this")
    for pid in pids:
        if pid not in purpose_ids:
            fail("DG-PURP-01", f"{kind} {label}: unregistered purpose {pid}")
    ref = rec.get("retention_ref")
    if not ref:
        fail("DG-RET-01", f"{kind} {label}: no retention_ref declared")
    elif ref not in retention_ids:
        fail("DG-RET-01", f"{kind} {label}: retention_ref '{ref}' is not defined")
    if cls in PROTECTED and kind == "field" and not rec.get("encrypted_at_rest"):
        fail("DG-SEC-01", f"field {label}: {cls} data must be encrypted at rest")


for f in datamap_doc.get("fields") or []:
    check_record("field", f"{f.get('store', '?')}.{f.get('field', '?')}", f)

for e in datamap_doc.get("events") or []:
    check_record("event", e.get("name", "<unnamed>"), e)
    for prop in e.get("properties") or []:
        if prop.get("class") not in VALID_CLASSES:
            fail("DG-CLASS-02", f"event {e.get('name')}: property {prop.get('name')} is untagged")

# ---------------------------------------------------------------- exceptions

exc_path = GOV / "exceptions.md"
if exc_path.exists():
    body = exc_path.read_text()
    active = body.split("## Template")[0]
    today = dt.date.today()
    for block in re.split(r"^### ", active, flags=re.M)[1:]:
        eid = block.splitlines()[0].strip()
        expires = re.search(r"^Expires:\s*(\d{4}-\d{2}-\d{2})", block, re.M)
        approver = re.search(r"^Approved by:\s*(\S.*)$", block, re.M)
        if not approver or approver.group(1).strip().startswith("<"):
            fail("DG-EX-02", f"exception {eid}: unapproved, so it does not authorise anything")
        if not expires:
            fail("DG-EX-01", f"exception {eid}: no expiry date")
        elif dt.date.fromisoformat(expires.group(1)) < today:
            fail("DG-EX-03", f"exception {eid}: expired on {expires.group(1)}")

# ---------------------------------------------------------------- code scan

BANNED = [
    (r"\byt[-_]?dlp\b|\byoutube[-_]dl\b|\bstreamlink\b|\bpytube\b", "P1", "platform media downloader"),
    (r"helix/clips.*(download|mp4)|clips\.twitch\.tv/.*\.mp4", "P1", "Twitch clip media retrieval"),
    (r"\b(voice[_-]?clone|voice[_-]?cloning|speaker[_-]?clone|tts[_-]?clone)\b", "P4", "voice cloning"),
    (r"(?i)(api[_-]?key|secret|password|token)\s*[:=]\s*[\"'][A-Za-z0-9_\-]{16,}[\"']", "P11", "hardcoded credential"),
    (r"(?i)log(ger)?\.(info|debug|warn|error)\([^)]*\b(email|password|ip_address|access_token|full_name)\b", "P7", "personal data in logs"),
    (r"(?i)\b(prod|production)[_-]?(dump|snapshot|seed)\b", "P9", "production data in non-production use"),
]


def scan() -> None:
    for path in ROOT.rglob("*"):
        if not path.is_file() or path.suffix not in SCAN_SUFFIXES:
            continue
        if any(part in SCAN_SKIP for part in path.parts):
            continue
        try:
            text = path.read_text(errors="ignore")
        except OSError:
            continue
        for pattern, pid, label in BANNED:
            for m in re.finditer(pattern, text):
                line = text[: m.start()].count("\n") + 1
                rel = path.relative_to(ROOT)
                fail(f"DG-STOP-01/{pid}", f"{rel}:{line} {label}")


scan()

# ---------------------------------------------------------------- PR block

if "--pr" in sys.argv:
    pr_file = Path(sys.argv[sys.argv.index("--pr") + 1])
    text = pr_file.read_text() if pr_file.exists() else ""
    required = ["Data classes touched:", "Purpose IDs:", "Rules applied:", "Prohibited patterns check:"]
    missing = [r for r in required if r not in text]
    if missing:
        fail("DG-PR-01", f"PR body is missing Compliance Block lines: {', '.join(missing)}")

# ---------------------------------------------------------------- report

if violations:
    print(f"GOVERNANCE GATE: FAIL ({len(violations)} violation(s))\n")
    for v in violations:
        print(f"  {v}")
    print("\nSee DATA_GOVERNANCE.md. Fail closed: do not merge, do not add a TODO and proceed (DG-AGENT-04).")
    raise SystemExit(1)

print("GOVERNANCE GATE: PASS")

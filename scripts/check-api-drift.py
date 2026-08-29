#!/usr/bin/env python3
"""Detect drift between what the skill claims and what the ElevenLabs API actually offers.

The skill is hand-written prose about a third-party API that changes underneath it. This script
compares every endpoint path and model id the skill mentions against the live OpenAPI document at
https://api.elevenlabs.io/openapi.json, and reports:

  FAIL  an endpoint or model the skill documents that the API no longer has  (exit 1)
  INFO  endpoints and models the API has that the skill does not cover       (exit 0)

With ELEVENLABS_API_KEY set it additionally queries GET /v1/models, so newly released models show up
in the INFO section as soon as they reach your account.

Usage:
    python3 scripts/check-api-drift.py            # fetch the live spec
    python3 scripts/check-api-drift.py --spec f   # use a local copy (offline / pinned)
    python3 scripts/check-api-drift.py --strict   # also fail on uncovered endpoints
"""
import argparse
import json
import os
import pathlib
import re
import sys
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
SPEC_URL = "https://api.elevenlabs.io/openapi.json"
MODELS_URL = "https://api.elevenlabs.io/v1/models"

# WebSocket endpoints are intentionally absent from the REST OpenAPI document. The skill mentions
# them only to say "curl cannot drive this", so they must not be reported as drift.
WEBSOCKET_PATHS = {
    "/v1/speech-to-text/realtime",
    "/v1/text-to-speech/{}/stream-input",
    "/v1/text-to-speech/{}/multi-stream-input",
    "/v1/text-to-dialogue/stream-input",
    "/v1/text-to-dialogue/multi-stream-input",
}

# Endpoint families the skill deliberately does not cover; listing them as "uncovered" is noise.
OUT_OF_SCOPE = re.compile(
    r"^/docs$|"
    r"^/v1/(convai|studio|workspace|service-accounts|webhooks|tests|flows|triage-tickets|"
    r"phone-numbers|batch-calling|whats-app|twilio|exotel|sip-trunk|audio-native|usage|"
    r"speech-engine|conversations|knowledge-base|tools|mcp|analytics|environment-variables|"
    r"api-keys|admin|assets|productions|single-use-token|dubbing/resource)"
)

# Models the skill names on purpose so the agent avoids them. The API has already dropped these, so
# their absence from the spec is expected, not drift.
DEPRECATED_ON_PURPOSE = {
    "eleven_monolingual_v1",
    "eleven_multilingual_v1",
    "eleven_turbo_v2",
    "eleven_turbo_v2_5",
}

# Models that legitimately never appear in the REST OpenAPI document: the endpoint takes model_id as
# a free-form string, or the model is only reachable over WebSocket. Absence proves nothing here, so
# these are reported as notes rather than failures.
NOT_IN_REST_SPEC = {
    "eleven_english_sts_v2",
    "eleven_multilingual_sts_v2",
    "scribe_v2_realtime",
    "scribe_v2_realtime_turbo",
    "scribe_v2_realtime_lite",
}

MODEL_RE = re.compile(r"\b(?:eleven_[a-z0-9_]+|scribe_v[0-9][a-z0-9_]*|music_v[0-9]|dubbing_v[0-9])\b")
# `POST /v1/...`, `GET|PATCH /v1/...` in prose and tables
DECLARED_RE = re.compile(r"`((?:GET|POST|PUT|PATCH|DELETE)(?:\|(?:GET|POST|PUT|PATCH|DELETE))*)\s+(/v[12]/[^`\s]+)`")
# curl invocations
CURL_RE = re.compile(r"https://api\.elevenlabs\.io(/v[12]/[^\s\"'\\]*)")


def normalise(path: str) -> str:
    """Collapse every variable segment to {} so skill paths and spec paths can be compared."""
    path = path.split("?", 1)[0].rstrip("/")
    segments = []
    for seg in path.split("/"):
        if seg.startswith("$") or (seg.startswith("{") and seg.endswith("}")):
            segments.append("{}")
        else:
            segments.append(seg)
    return "/".join(segments)


def path_matches(claimed: str, spec_paths: set[str]) -> bool:
    """A literal in the skill may fill a {} placeholder in the spec (e.g. a token_type value)."""
    if claimed in spec_paths:
        return True
    claimed_parts = claimed.split("/")
    for candidate in spec_paths:
        parts = candidate.split("/")
        if len(parts) != len(claimed_parts):
            continue
        if all(p == "{}" or p == c for p, c in zip(parts, claimed_parts)):
            return True
    return False


def load_spec(local: str | None) -> dict:
    if local:
        return json.loads(pathlib.Path(local).read_text(encoding="utf-8"))
    req = urllib.request.Request(SPEC_URL, headers={"User-Agent": "eleven-sk-drift-check"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read().decode("utf-8"))


def live_models(key: str) -> list[str]:
    req = urllib.request.Request(MODELS_URL, headers={"xi-api-key": key})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return [m["model_id"] for m in json.loads(r.read().decode("utf-8"))]
    except (urllib.error.URLError, KeyError, ValueError) as e:
        print(f"  note: live model check skipped ({e})")
        return []


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--spec", help="path to a local openapi.json instead of fetching it")
    ap.add_argument("--strict", action="store_true", help="also fail when endpoints are uncovered")
    args = ap.parse_args()

    skill_files = sorted(ROOT.glob("skills/*/SKILL.md")) + sorted(ROOT.glob("skills/*/references/*.md"))
    if not skill_files:
        print("no skill files found")
        return 1
    text = "\n".join(p.read_text(encoding="utf-8") for p in skill_files)

    try:
        spec = load_spec(args.spec)
    except (urllib.error.URLError, TimeoutError, ValueError) as e:
        print(f"could not load the OpenAPI spec: {e}")
        return 2

    spec_paths = {normalise(p) for p in spec.get("paths", {})}
    spec_blob = json.dumps(spec)
    print(f"spec: {len(spec_paths)} paths, checking {len(skill_files)} skill file(s)\n")

    claimed_paths = {normalise(m.group(2)) for m in DECLARED_RE.finditer(text)}
    claimed_paths |= {normalise(m.group(1)) for m in CURL_RE.finditer(text)}
    claimed_paths = {p for p in claimed_paths if "*" not in p and p not in WEBSOCKET_PATHS}

    failures = 0

    print("== endpoints documented by the skill")
    missing = sorted(p for p in claimed_paths if not path_matches(p, spec_paths))
    for p in sorted(claimed_paths):
        if p in missing:
            print(f"  FAIL {p} — not in the live API spec")
            failures += 1
    print(f"  {len(claimed_paths) - len(missing)}/{len(claimed_paths)} verified against the live spec")

    key = os.environ.get("ELEVENLABS_API_KEY") or os.environ.get("ELEVEN_API_KEY")
    catalogue = live_models(key) if key else []

    print("\n== models referenced by the skill")
    claimed_models = sorted(set(MODEL_RE.findall(text)))
    verified = 0
    for m in claimed_models:
        in_spec = f'"{m}"' in spec_blob
        in_catalogue = m in catalogue
        if in_spec or in_catalogue:
            verified += 1
        elif m in DEPRECATED_ON_PURPOSE:
            print(f"  NOTE {m} — gone from the API, named only so the skill steers away from it")
        elif m in NOT_IN_REST_SPEC:
            # Only the live catalogue can settle these; without a key, absence is not evidence.
            if catalogue:
                print(f"  FAIL {m} — absent from both the spec and this account's live catalogue")
                failures += 1
            else:
                print(f"  NOTE {m} — free-form or WebSocket-only model, not listed in the REST spec")
        else:
            print(f"  FAIL {m} — not found anywhere in the live API spec")
            failures += 1
    print(f"  {verified}/{len(claimed_models)} model id(s) confirmed against the live API")

    print("\n== API surface the skill does not cover (informational)")
    uncovered = sorted(
        p for p in spec_paths
        if p not in claimed_paths and not OUT_OF_SCOPE.match(p) and not path_matches(p, claimed_paths)
    )
    for p in uncovered:
        print(f"  INFO {p}")
    if not uncovered:
        print("  (none — full coverage of the in-scope surface)")

    print("\n== live model catalogue")
    if catalogue:
        new = [m for m in sorted(catalogue) if m not in claimed_models]
        for m in new:
            print(f"  INFO {m} — available on this account but not mentioned by the skill")
        if not new:
            print("  (every model on this account is already covered)")
    elif key:
        print("  (a key is set but GET /v1/models did not answer — see the note above)")
    else:
        print("  (set ELEVENLABS_API_KEY to also diff against your account's live catalogue)")

    if args.strict and uncovered:
        failures += len(uncovered)

    print(f"\n{'DRIFT DETECTED' if failures else 'NO DRIFT'} ({failures} failure(s))")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

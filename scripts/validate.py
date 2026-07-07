#!/usr/bin/env python3
"""Static validation of skills/*/SKILL.md: frontmatter, bash syntax, JSON payloads.

Runs in CI on every push so a broken skill never lands on main
(npx skills add installs straight from the default branch).
"""
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
failures = 0


def check(label: str, ok: bool, detail: str = "") -> None:
    global failures
    print(f"  {'OK  ' if ok else 'FAIL'} {label}" + (f" — {detail}" if detail else ""))
    if not ok:
        failures += 1


skill_files = sorted(ROOT.glob("skills/*/SKILL.md"))
if not skill_files:
    print("no skills/*/SKILL.md found")
    sys.exit(1)

for path in skill_files:
    src = path.read_text()
    rel = path.relative_to(ROOT)
    print(f"\n== {rel}")

    # Frontmatter
    m = re.match(r"^---\n(.*?)\n---\n", src, re.S)
    check("frontmatter present", bool(m))
    if m:
        fm = m.group(1)
        name = re.search(r"^name:\s*(\S+)", fm, re.M)
        desc = re.search(r"^description:\s*(.+)", fm, re.M)
        check("name matches directory", bool(name) and name.group(1) == path.parent.name)
        check(
            "description ≤ 1024 chars",
            bool(desc) and len(desc.group(1)) <= 1024,
            f"{len(desc.group(1))} chars" if desc else "missing",
        )

    # Bash blocks must parse
    for i, block in enumerate(re.findall(r"```bash\n(.*?)```", src, re.S), 1):
        r = subprocess.run(["bash", "-n"], input=block, capture_output=True, text=True)
        check(f"bash block {i} syntax", r.returncode == 0, r.stderr.strip())

    # Heredoc payloads must be valid JSON
    for i, payload in enumerate(re.findall(r"<<'EOF'\n(.*?)\nEOF", src, re.S), 1):
        try:
            json.loads(payload)
            check(f"heredoc payload {i} JSON", True)
        except ValueError as e:
            check(f"heredoc payload {i} JSON", False, str(e))

    # ```json blocks must be valid JSON (fragments starting with "tools" get wrapped)
    for i, frag in enumerate(re.findall(r"```json\n(.*?)```", src, re.S), 1):
        text = frag.strip()
        if text.startswith('"tools"'):
            text = "{" + text + "}"
        try:
            json.loads(text)
            check(f"json block {i}", True)
        except ValueError as e:
            check(f"json block {i}", False, str(e))

print(f"\n{'ALL CHECKS PASSED' if failures == 0 else f'{failures} CHECK(S) FAILED'}")
sys.exit(1 if failures else 0)

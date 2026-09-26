#!/usr/bin/env python3
"""Static validation of skills/*/SKILL.md and its bundled reference files.

Checks frontmatter against the Agent Skills specification (https://agentskills.io/specification),
the syntax of every bash and python snippet, the validity of every JSON payload, that every
referenced file exists, and that SKILL.md stays inside the spec's progressive-disclosure budget.

Runs in CI on every push so a broken skill never lands on main
(npx skills add installs straight from the default branch).
"""
import ast
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# Spec: https://agentskills.io/specification
NAME_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
MAX_NAME = 64
MAX_DESCRIPTION = 1024
MAX_COMPATIBILITY = 500
# "Keep your main SKILL.md under 500 lines" / "Instructions (< 5000 tokens recommended)"
MAX_SKILL_LINES = 500
MAX_SKILL_TOKENS = 5000

failures = 0
warnings = 0


def check(label: str, ok: bool, detail: str = "") -> None:
    global failures
    print(f"  {'OK  ' if ok else 'FAIL'} {label}" + (f" — {detail}" if detail else ""))
    if not ok:
        failures += 1


def warn(label: str, detail: str = "") -> None:
    global warnings
    print(f"  WARN {label}" + (f" — {detail}" if detail else ""))
    warnings += 1


def parse_frontmatter(src: str):
    """Parse the small YAML subset the spec allows: scalars plus one nested string map."""
    m = re.match(r"^---\n(.*?)\n---\n", src, re.S)
    if not m:
        return None, None
    fields, current = {}, None
    for line in m.group(1).splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if line.startswith((" ", "\t")):
            if current is None or ":" not in line:
                continue
            k, v = line.strip().split(":", 1)
            fields.setdefault(current, {})[k.strip()] = v.strip().strip("\"'")
            continue
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        key, value = key.strip(), value.strip()
        if value:
            fields[key] = value.strip("\"'")
            current = None
        else:
            fields[key] = {}
            current = key
    return m.group(1), fields


def find_bash() -> str | None:
    """Find a working bash executable for syntax checking (`bash -n`)."""
    candidates = ["bash"]
    if sys.platform == "win32":
        for p in [
            r"C:\Program Files\Git\bin\bash.exe",
            r"C:\Program Files (x86)\Git\bin\bash.exe",
        ]:
            if pathlib.Path(p).exists():
                candidates.append(p)
    for cmd in candidates:
        try:
            r = subprocess.run(
                [cmd, "-n"], input="true\n", capture_output=True, encoding="utf-8", errors="replace"
            )
            if r.returncode == 0:
                return cmd
        except (OSError, ValueError):
            continue
    return None


BASH_BIN = find_bash()
HAVE_BASH = BASH_BIN is not None


def check_snippets(src: str, label: str) -> None:
    """bash syntax, python syntax, and every JSON payload in one markdown file."""
    for i, block in enumerate(re.findall(r"```bash\n(.*?)```", src, re.S), 1):
        if not HAVE_BASH:
            continue
        # encoding= is required: snippets contain IPA characters that the Windows
        # locale codec cannot encode.
        r = subprocess.run(
            [BASH_BIN, "-n"], input=block, capture_output=True, encoding="utf-8", errors="replace"
        )
        check(f"{label}: bash block {i} syntax", r.returncode == 0, r.stderr.strip())

    # Heredoc JSON payloads: -d @- <<'EOF' ... EOF
    for i, payload in enumerate(re.findall(r"<<'EOF'\n(.*?)\nEOF", src, re.S), 1):
        try:
            json.loads(payload)
            check(f"{label}: heredoc payload {i} JSON", True)
        except ValueError as e:
            check(f"{label}: heredoc payload {i} JSON", False, str(e))

    # Inline payloads: -d '{...}' / -F 'field={...}'
    inline = re.findall(r"-[dF] '([^']*)'", src)
    n = 0
    for raw in inline:
        body = raw.split("=", 1)[1] if raw.startswith(("voice_settings=", "additional_formats=")) else raw
        if not body.lstrip().startswith(("{", "[")):
            continue
        n += 1
        try:
            json.loads(body)
            check(f"{label}: inline payload {n} JSON", True)
        except ValueError as e:
            check(f"{label}: inline payload {n} JSON", False, f"{body[:60]}… {e}")

    # Embedded python heredocs
    for i, code in enumerate(re.findall(r"<<'PYEOF'\n(.*?)\nPYEOF", src, re.S), 1):
        try:
            ast.parse(code)
            check(f"{label}: python block {i} syntax", True)
        except SyntaxError as e:
            check(f"{label}: python block {i} syntax", False, str(e))

    # ```json blocks (fragments starting with a quoted key get wrapped)
    for i, frag in enumerate(re.findall(r"```json\n(.*?)```", src, re.S), 1):
        text = frag.strip()
        if text.startswith('"'):
            text = "{" + text + "}"
        try:
            json.loads(text)
            check(f"{label}: json block {i}", True)
        except ValueError as e:
            check(f"{label}: json block {i}", False, str(e))


skill_files = sorted(ROOT.glob("skills/*/SKILL.md"))
if not skill_files:
    print("no skills/*/SKILL.md found")
    sys.exit(1)

for path in skill_files:
    src = path.read_text(encoding="utf-8")
    skill_dir = path.parent
    print(f"\n== {path.relative_to(ROOT)}")

    raw_fm, fm = parse_frontmatter(src)
    check("frontmatter present", fm is not None)
    if fm:
        name = fm.get("name")
        check("name present and a string", isinstance(name, str) and bool(name))
        if isinstance(name, str):
            check("name matches directory", name == skill_dir.name, f"{name!r} vs {skill_dir.name!r}")
            check("name matches spec pattern", bool(NAME_RE.match(name)), name)
            check(f"name <= {MAX_NAME} chars", len(name) <= MAX_NAME, f"{len(name)} chars")

        desc = fm.get("description")
        check("description present and non-empty", isinstance(desc, str) and bool(desc.strip()))
        if isinstance(desc, str):
            check(
                f"description <= {MAX_DESCRIPTION} chars",
                len(desc) <= MAX_DESCRIPTION,
                f"{len(desc)} chars",
            )

        compat = fm.get("compatibility")
        if compat is not None:
            check(
                f"compatibility <= {MAX_COMPATIBILITY} chars",
                isinstance(compat, str) and len(compat) <= MAX_COMPATIBILITY,
                f"{len(compat)} chars" if isinstance(compat, str) else "not a string",
            )

        meta = fm.get("metadata")
        if meta is not None:
            check(
                "metadata is a string map",
                isinstance(meta, dict) and all(isinstance(v, str) for v in meta.values()),
            )

    # Progressive-disclosure budget for the always-loaded file
    body = src[len(raw_fm) + 9 :] if raw_fm else src
    lines = len(src.splitlines())
    approx_tokens = len(body) // 4
    check(f"SKILL.md <= {MAX_SKILL_LINES} lines", lines <= MAX_SKILL_LINES, f"{lines} lines")
    if approx_tokens > MAX_SKILL_TOKENS:
        warn(
            f"SKILL.md body over the recommended {MAX_SKILL_TOKENS} tokens",
            f"~{approx_tokens} tokens — move detail into references/",
        )
    else:
        check(f"SKILL.md body <= ~{MAX_SKILL_TOKENS} tokens", True, f"~{approx_tokens} tokens")

    # Every referenced bundled file must exist
    bundled = sorted(p for p in skill_dir.rglob("*.md") if p != path)
    for md in [path] + bundled:
        text = md.read_text(encoding="utf-8")
        rel_label = md.relative_to(skill_dir).as_posix()
        for ref in sorted(set(re.findall(r"(?:references|scripts|assets)/[A-Za-z0-9_.\-/]+", text))):
            check(f"{rel_label}: reference {ref} exists", (skill_dir / ref).exists())

    # No credentials committed by accident
    for md in [path] + bundled:
        text = md.read_text(encoding="utf-8")
        leaked = re.findall(r"\bsk_[A-Za-z0-9]{16,}\b|\bxi-api-key:\s*[A-Za-z0-9]{16,}", text)
        check(
            f"{md.relative_to(skill_dir).as_posix()}: no hardcoded key",
            not leaked,
            str(leaked[:1]) if leaked else "",
        )

    # Snippets in SKILL.md and in every bundled reference
    for md in [path] + bundled:
        check_snippets(md.read_text(encoding="utf-8"), md.relative_to(skill_dir).as_posix())

    if bundled:
        print(f"  INFO {len(bundled)} bundled reference file(s) validated")
    if not HAVE_BASH:
        warn("bash unavailable — skipped bash syntax checks", "CI (ubuntu-latest) still runs them")

summary = "ALL CHECKS PASSED" if failures == 0 else f"{failures} CHECK(S) FAILED"
if warnings:
    summary += f" ({warnings} warning(s))"
print(f"\n{summary}")
sys.exit(1 if failures else 0)

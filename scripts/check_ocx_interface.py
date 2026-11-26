#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 The OCX Authors
"""Guard: rules_ocx touches ocx only through its two vendor commands.

Usage: check_ocx_interface.py [ROOT]   (default: the repository root)

Scans ROOT/ocx/**/*.bzl and prints one `path:line: <class>: <text>` line per
finding (at most one per line and class); exit 1 on any finding, 0 when clean,
2 when ROOT/ocx is not a directory, holds no .bzl file, or a .bzl file cannot
be read (a wrong ROOT or a partial scan must never read as green or as findings). The count of files read goes to stderr.

Comments and true docstrings (a triple-quoted string that is a statement of
its own) are blanked first. Brackets are matched by depth counting over a copy
of the source whose string contents are masked.

Classes:
  subcommand  An ocx argv names a subcommand other than `vendor` /
              `package vendor`. Recognised as an argv:
                - a list literal with direct string elements that holds a
                  known subcommand name AND (a string starting with `-`, or
                  a non-string element naming a binary: `ocx`, `binary`,
                  `bin`, or a list inside a `run_ocx(...)` call), or that is
                  joined by `+`/`+=` to something and starts with the name;
                - the string arguments of `run_ocx(...)`;
                - `.append("sub")` / `.extend([...])` when the file builds a
                  `"--format", "json"` pair;
                - a string holding a command line `ocx [flags] <sub>` that is
                  inside the parentheses of `execute(...)` or `run_ocx(...)`
                  (so also inside a list passed there, but not inside a `{...}`
                  hint dict). Hint, doc, `fail()`
                  and format-string text naming a command for the user to
                  type is not an argv rules_ocx runs and is not checked.
              `package` counts only when the next string is not `vendor`.
  home-path   A string names a segment of an ocx home: `layers/`, `blobs/`,
              `symlinks/`, `refs/`, `metadata.json`, `install.json`,
              `resolve.json` (anywhere), or a bare segment `layers`, `blobs`,
              `symlinks`, `refs`, `packages`, `packages/...` in the same
              statement (split at newlines outside brackets and at `;`) as a
              home variable (`home`, `OCX_HOME`, `ocx_home`). The vendor
              manifest's own `packages/...` paths, with no home variable,
              pass.
  metadata    A package metadata field (`binaries`, `entrypoints`, `env`,
              `dependencies`) used as a key: `x["env"]`, `x.get("env")`,
              `x.pop("env")`, `"env" in x`. Attribute reads on the manifest
              struct (`pkg.entrypoints`) and plain list literals pass. The
              one exempt file, by exact relative path, is
              `ocx/private/vendor_manifest.bzl` (the one place that
              parses manifest.json and builds the struct); classes 1 and 2
              still apply there.

  parse       Unbalanced brackets (an unclosed opener or a stray closer); the
              literal is then skipped by the other classes.

Limits (a regex guard, not a Starlark parser): a key or segment built from a
variable, an argv split across several variables or functions, and a subcommand
passed through a helper other than `run_ocx` are invisible. Upgrade the guard
if a real bypass shows up.
"""

import pathlib
import re
import sys

SUBCOMMANDS = frozenset({
    "add", "clean", "config", "deps", "env", "exec", "find", "index", "info", "init", "inspect",
    "install", "lock", "package", "pull", "remove", "run", "select", "shell", "uninstall",
    "update", "which",
})
META_KEYS = frozenset({"binaries", "entrypoints", "env", "dependencies"})
HOME_FILES = re.compile(r"(?<![\w-])(?:metadata|install|resolve)\.json\b")
HOME_SLASH = re.compile(r"(?<![\w-])(?:layers|blobs|symlinks|refs)/")
HOME_BARE = re.compile(r"(?<![\w.-])(?:layers|blobs|symlinks|refs|packages)(?![\w.-])")
HOME_VAR = re.compile(r"\b(?:home|OCX_HOME|ocx_home)\b", re.IGNORECASE)
BINARY_NAME = re.compile(r"\b\w*(?:ocx|binary|bin)\w*\b", re.IGNORECASE)
CMDLINE = re.compile(
    r"(?<![\w.\-/])ocx(?:\.exe)?(?:\s+-\S+(?:\s+json)?)*\s+([a-z][a-z-]*)(?:\s+([a-z][a-z-]*))?"
)
FORMAT_PAIR = re.compile(r"""["']--format["']\s*,\s*["']json["']""")
APPEND = re.compile(r"""\.(?:append|extend)\(\s*\[?\s*["'](\w+)["']""")
POP_GET = re.compile(r"\.(?:get|pop)\(\s*$")
OPEN, CLOSE = "([{", ")]}"
# The one parse surface: it builds the manifest struct, so class 3 skips it.
METADATA_EXEMPT = "ocx/private/vendor_manifest.bzl"


class Source:
    """Comment- and docstring-blanked text, a string-masked twin, and the strings."""

    def __init__(self, src):
        self.strings = {}  # opening-quote offset -> (end offset, value)
        out = []
        pos = 0  # characters emitted so far
        i, n = 0, len(src)
        while i < n:
            c = src[i]
            if c == "#":
                while i < n and src[i] != "\n":
                    out.append(" ")
                    pos += 1
                    i += 1
            elif c in "\"'":
                q = c * 3 if src.startswith(c * 3, i) else c
                end = i + len(q)
                while end < n and not src.startswith(q, end):
                    if src[end] == "\\":
                        end += 1
                    if len(q) == 1 and end < n and src[end] == "\n":
                        break
                    end += 1
                close = min(end + len(q), n)
                if len(q) == 3 and self._is_docstring(src, i, close):
                    out.append("".join(ch if ch == "\n" else " " for ch in src[i:close]))
                else:
                    self.strings[pos] = (pos + close - i, src[i + len(q) : end])
                    out.append(src[i:close])
                pos += close - i
                i = close
            else:
                out.append(c)
                pos += 1
                i += 1
        self.text = "".join(out)
        mask = list(self.text)
        for start, (end, _) in self.strings.items():
            q = 3 if self.text.startswith(self.text[start] * 3, start) and end - start >= 6 else 1
            for k in range(start + q, end - q):
                mask[k] = "_"
        self.mask = "".join(mask)

    @staticmethod
    def _is_docstring(src, start, close):
        line_start = src.rfind("\n", 0, start) + 1
        line_end = src.find("\n", close)
        rest = src[close : line_end if line_end >= 0 else len(src)].strip()
        return src[line_start:start].strip() == "" and (rest == "" or rest.startswith("#"))

    def line(self, offset):
        return self.text.count("\n", 0, offset) + 1

    def match(self, i):
        """Index of the bracket closing the one at i, or -1."""
        depth = 0
        for k in range(i, len(self.mask)):
            ch = self.mask[k]
            if ch in OPEN:
                depth += 1
            elif ch in CLOSE:
                depth -= 1
                if depth == 0:
                    return k
        return -1

    def elements(self, a, b):
        """Trimmed (start, end) of the top-level comma-separated parts of mask[a:b]."""
        parts, depth, s = [], 0, a
        for k in range(a, b):
            ch = self.mask[k]
            depth += (ch in OPEN) - (ch in CLOSE)
            if ch == "," and depth == 0:
                parts.append((s, k))
                s = k + 1
        parts.append((s, b))
        out = []
        for s, e in parts:
            while s < e and self.mask[s].isspace():
                s += 1
            while e > s and self.mask[e - 1].isspace():
                e -= 1
            if s < e:
                out.append((s, e))
        return out

    def direct_strings(self, a, b):
        """Values of the elements that start with a string literal, None for the rest."""
        return [self.strings[s][1] if s in self.strings else None for s, _ in self.elements(a, b)]


def argv_hit(items, strong, weak):
    """The offending subcommand in a list of direct string items, or None."""
    for idx, s in enumerate(items):
        if s not in SUBCOMMANDS:
            continue
        if s == "package":
            nxt = next((t for t in items[idx + 1 :] if t is not None), None)
            if (strong or weak) and nxt is not None and nxt != "vendor":
                return s
            continue
        if strong or (weak and idx == 0):
            return s
    return None


def scan_text(src, name):
    sc = Source(src)
    text, mask = sc.text, sc.mask
    found = set()

    def add(offset, cls, msg):
        found.add((sc.line(offset), cls, msg))

    file_pair = bool(FORMAT_PAIR.search(text))

    # run_ocx(...) calls: every direct string argument is argv; lists inside are strong.
    call_spans = []
    for m in re.finditer(r"\brun_ocx\s*\(", mask):
        if mask[: m.start()].rstrip().endswith("def"):
            continue
        a = m.end() - 1
        b = sc.match(a)
        if b < 0:
            continue
        call_spans.append((a, b))
        hit = argv_hit(sc.direct_strings(a + 1, b), True, True)
        if hit:
            add(m.start(), "subcommand", f"ocx subcommand `{hit}` is not a vendor form")

    # list literals (a `[` after an identifier, `)` or `]` is a subscript).
    for i, ch in enumerate(mask):
        if ch != "[" or (i and (mask[i - 1].isalnum() or mask[i - 1] in "_)]")):
            continue
        j = sc.match(i)
        if j < 0:
            continue
        elems = sc.elements(i + 1, j)
        items = [sc.strings[s][1] if s in sc.strings else None for s, _ in elems]
        non_strings = [mask[s:e] for (s, e), v in zip(elems, items) if v is None]
        strong = (
            any(v and v.startswith("-") for v in items)
            or any(BINARY_NAME.search(t) for t in non_strings)
            or any(a < i < b for a, b in call_spans)
        )
        before = mask[:i].rstrip()
        after = mask[j + 1 :].lstrip()
        weak = (
            before.endswith(("+", "+="))
            or after.startswith("+")
            or (file_pair and before.endswith("("))
        )
        hit = argv_hit(items, strong, weak)
        if hit:
            add(i, "subcommand", f"ocx subcommand `{hit}` is not a vendor form")

    if file_pair:
        for m in APPEND.finditer(text):
            if m.group(1) in SUBCOMMANDS and mask[m.start()] == ".":
                add(m.start(), "subcommand", f"ocx subcommand `{m.group(1)}` is not a vendor form")

    def stack(a, k):
        """Brackets still open at k, counted from a: a string in `{...}` is a hint dict, not argv."""
        opened = []
        for ch in mask[a:k]:
            if ch in OPEN:
                opened.append(ch)
            elif ch in CLOSE and opened:
                opened.pop()
        return opened

    exec_spans = list(call_spans)
    for m in re.finditer(r"\bexecute\s*\(", mask):
        b = sc.match(m.end() - 1)
        if b >= 0 and not mask[: m.start()].rstrip().endswith("def"):
            exec_spans.append((m.end() - 1, b))

    for start, (end, value) in sc.strings.items():
        m = CMDLINE.search(value) if any(a < start < b and "{" not in stack(a, start) for a, b in exec_spans) else None
        if m and m.group(1) in SUBCOMMANDS and not (m.group(1) == "package" and m.group(2) == "vendor"):
            add(start, "subcommand", f"command line `{m.group(0)}` runs a non-vendor ocx command")
        if HOME_FILES.search(value) or HOME_SLASH.search(value):
            add(start, "home-path", f"ocx home path `{value}`")
        # metadata key context, read off the masked twin
        if value in META_KEYS and name != METADATA_EXEMPT:
            ctx = mask[:start].rstrip()
            tail = mask[end:].lstrip()
            subscript = (
                ctx.endswith("[")
                and len(ctx) > 1
                and (ctx[-2].isalnum() or ctx[-2] in "_)]")
                and tail.startswith("]")
            )
            if subscript or POP_GET.search(mask[:start]) or re.match(r"in\s+[\w(]", tail):
                add(start, "metadata", f"metadata field `{value}` read outside the manifest struct")

    # bare home segments: only inside a statement that also holds a home variable
    a = depth = 0
    spans = []
    for k, ch in enumerate(mask + "\n"):
        if k < len(mask):
            depth += (ch in OPEN) - (ch in CLOSE)
        if depth <= 0 and ch in "\n;":
            spans.append((a, k))
            a = k + 1
    for a, b in spans:
        if not HOME_VAR.search(mask[a:b]):
            continue
        for start, (end, value) in sc.strings.items():
            if a <= start < b and HOME_BARE.search(value):
                add(start, "home-path", f"ocx home segment `{value}` joined to a home variable")

    # unbalanced brackets: the matchers above skip such a literal, so say so loudly
    opened = []
    for k, ch in enumerate(mask):
        if ch in OPEN:
            opened.append(k)
        elif ch in CLOSE:
            if opened:
                opened.pop()
            else:
                add(k, "parse", f"unmatched `{ch}`")
    for k in opened:
        add(k, "parse", f"unclosed `{mask[k]}`")

    first = {}
    for ln, cls, msg in sorted(found):
        first.setdefault((ln, cls), msg)
    return [f"{name}:{ln}: {cls}: {msg}" for (ln, cls), msg in first.items()]


class UnreadableError(Exception):
    """A .bzl file could not be read; the scan is incomplete, so it must not read as findings."""


def scan_tree(root):
    root = pathlib.Path(root)
    files = sorted((root / "ocx").rglob("*.bzl")) if (root / "ocx").is_dir() else []
    lines = []
    for path in files:
        try:
            src = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as e:
            raise UnreadableError(f"cannot read {path}: {e}") from e
        lines += scan_text(src, path.relative_to(root).as_posix())
    return lines, len(files)


def main(argv):
    root = argv[1] if len(argv) > 1 else pathlib.Path(__file__).resolve().parent.parent
    try:
        lines, count = scan_tree(root)
    except UnreadableError as e:
        print(f"check_ocx_interface: {e}", file=sys.stderr)
        return 2
    if count == 0:
        print(f"check_ocx_interface: no .bzl file under {root}/ocx; wrong ROOT?", file=sys.stderr)
        return 2
    print(f"check_ocx_interface: read {count} files", file=sys.stderr)
    for line in lines:
        print(line)
    return 1 if lines else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

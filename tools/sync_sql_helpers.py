from __future__ import annotations

import argparse
import re
import sys
from collections.abc import Sequence
from dataclasses import dataclass
from itertools import pairwise
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SQL_INSTALLERS = (
    "pgFirstAid.sql",
    "view_pgFirstAid.sql",
    "view_pgFirstAid_managed.sql",
)


@dataclass(frozen=True)
class Fragment:
    source: Path
    function_name: str
    dollar_tag: bytes
    targets: tuple[str, ...]


FRAGMENTS: dict[str, Fragment] = {
    "agent_prompt": Fragment(
        source=Path("data/agent_prompt.sql"),
        function_name="pgfirstaid_agent_prompt",
        dollar_tag=b"$prompt$",
        targets=SQL_INSTALLERS,
    ),
    "view_installer": Fragment(
        source=Path("data/view_installer.sql"),
        function_name="_pgfirstaid_install_view",
        dollar_tag=b"$view_install$",
        targets=SQL_INSTALLERS[1:],
    ),
}


class HelperSyncError(ValueError):
    pass


def function_span(data: bytes, spec: Fragment, label: str) -> tuple[int, int]:
    signature = re.compile(
        rb"^[ \t]*CREATE[ \t\r\n]+OR[ \t\r\n]+REPLACE[ \t\r\n]+FUNCTION[ \t\r\n]+"
        + re.escape(spec.function_name.encode())
        + rb"[ \t\r\n]*\(",
        re.IGNORECASE | re.MULTILINE,
    )
    matches = list(signature.finditer(data))
    if len(matches) != 1:
        raise HelperSyncError(
            f"{label}: expected exactly one CREATE OR REPLACE FUNCTION "
            f"{spec.function_name}, found {len(matches)}; restore a unique helper"
        )
    match = matches[0]
    # Refuse to cross a statement or dollar boundary while finding the body.
    header = re.compile(
        rb"[^;$]*?\)[^;$]*?\bAS[ \t\r\n]+(?-i:" + re.escape(spec.dollar_tag) + rb")",
        re.IGNORECASE,
    ).match(data, match.end())
    if header is None:
        raise HelperSyncError(
            f"{label}: malformed {spec.function_name} header; expected "
            f"AS {spec.dollar_tag.decode()} after its parameter list"
        )
    closing = data.find(spec.dollar_tag, header.end())
    end = closing + len(spec.dollar_tag) + 1
    if (
        closing == -1
        or data[closing:end] != spec.dollar_tag + b";"
        or re.match(rb"[ \t]*(?:\r?\n|\Z)", data[end:]) is None
    ):
        raise HelperSyncError(
            f"{label}: malformed {spec.function_name} body; expected closing "
            f"{spec.dollar_tag.decode()}; on its final SQL line"
        )
    return match.start(), end


def validate_source(data: bytes, spec: Fragment, label: str) -> bytes:
    start, end = function_span(data, spec, label)
    comments_only = re.fullmatch(rb"(?:[ \t]*(?:--[^\r\n]*)?\r?\n)*", data[:start])
    markers = re.search(
        rb"^[ \t]*--[ \t]*GENERATED[ \t]+", data, re.MULTILINE | re.IGNORECASE
    )
    if (
        comments_only is None
        or markers is not None
        or data[end:] not in (b"", b"\n", b"\r\n")
    ):
        raise HelperSyncError(
            f"{label}: expected only helper comments, the {spec.function_name} "
            "definition and an optional final newline; remove extra SQL or markers"
        )
    return data[:end]


def replacement_span(
    data: bytes, kind: str, spec: Fragment, label: str
) -> tuple[int, int]:
    function_start, function_end = function_span(data, spec, label)
    marker_prefix = f"-- GENERATED {kind}".encode()
    markers = list(
        re.finditer(
            rb"^[ \t]*--[ \t]*GENERATED[ \t]+"
            + re.escape(kind.encode())
            + rb"\b[^\r\n]*",
            data,
            re.MULTILINE | re.IGNORECASE,
        )
    )
    if not markers:
        return function_start, function_end
    if len(markers) != 2 or [marker.group() for marker in markers] != [
        marker_prefix + b" BEGIN",
        marker_prefix + b" END",
    ]:
        raise HelperSyncError(
            f"{label}: missing, duplicate, reversed, or malformed markers; "
            f"restore exactly one '{marker_prefix.decode()} BEGIN/END' pair"
        )
    begin, end = markers
    interior = data[begin.end() : end.start()]
    newline = b"\r\n" if interior.startswith(b"\r\n") else b"\n"
    if not interior.startswith(newline):
        raise HelperSyncError(f"{label}: BEGIN marker must occupy its own line")
    validate_source(interior[len(newline) :], spec, label)
    if not (begin.end() < function_start < function_end <= end.start()):
        raise HelperSyncError(
            f"{label}: markers must enclose only {spec.function_name}; "
            "restore the helper block boundaries"
        )
    return begin.start(), end.end()


def plan_sync(root: Path) -> dict[Path, tuple[bytes, bytes]]:
    sources = {
        kind: validate_source(
            (root / spec.source).read_bytes(), spec, f"{spec.source}: {kind}"
        )
        for kind, spec in FRAGMENTS.items()
    }
    plan: dict[Path, tuple[bytes, bytes]] = {}
    for target in SQL_INSTALLERS:
        path = root / target
        original = path.read_bytes()
        replacements: list[tuple[int, int, bytes]] = []
        for kind, spec in FRAGMENTS.items():
            if target not in spec.targets:
                continue
            start, end = replacement_span(original, kind, spec, f"{target}: {kind}")
            block = (
                f"-- GENERATED {kind} BEGIN\n".encode()
                + sources[kind]
                + f"\n-- GENERATED {kind} END".encode()
            )
            replacements.append((start, end, block))
        replacements.sort()
        for previous, current in pairwise(replacements):
            if previous[1] > current[0]:
                raise HelperSyncError(
                    f"{target}: overlapping helper blocks; restore separate boundaries"
                )
        updated = original
        # Original offsets remain valid when replacements run from bottom to top.
        for start, end, block in reversed(replacements):
            updated = updated[:start] + block + updated[end:]
        plan[path] = original, updated
    return plan


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Sync canonical SQL helpers into standalone installers."
    )
    parser.add_argument(
        "--check", action="store_true", help="report drift without writing files"
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=REPO_ROOT,
        help="repository root (default: script root)",
    )
    args = parser.parse_args(argv)
    try:
        # Validate every source and target before the first possible write.
        plan = plan_sync(args.root)
        stale = False
        for path, (original, updated) in plan.items():
            if original == updated:
                print(f"ok {path.name}")
            elif args.check:
                stale = True
                print(f"stale {path.name}")
            else:
                path.write_bytes(updated)
                print(f"updated {path.name}")
        if stale:
            print("Run uv run python tools/sync_sql_helpers.py to regenerate helpers.")
        return int(stale)
    except (OSError, HelperSyncError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

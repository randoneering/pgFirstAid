from __future__ import annotations

import re

MARKER = b"-- pgFirstAid atomic installer"
HEADER = MARKER + b" v1\n"
WRAPPER = re.compile(
    re.escape(HEADER)
    + rb"DO (?P<tag>\$pgfirstaid_install(?:_[0-9]+)?\$)\nBEGIN\n"
    + rb"(?P<body>.*)\nEND;\n(?P=tag);\n\Z",
    re.DOTALL,
)


class InstallerWrapperError(ValueError):
    pass


def unwrap_installer(data: bytes) -> bytes:
    if not data.startswith(MARKER):
        return data
    # The final boundary remains authoritative after generated data adds an old tag.
    match = WRAPPER.fullmatch(data)
    if match is None:
        raise InstallerWrapperError(
            "malformed pgFirstAid installer wrapper; restore its generated "
            "header and final END/dollar-tag boundary before regenerating"
        )
    return match["body"]


def wrap_installer(body: bytes) -> bytes:
    number = 0
    tag = b"$pgfirstaid_install$"
    # PostgreSQL's outer dollar lexer also sees tags inside inner SQL literals.
    while tag in body:
        number += 1
        tag = f"$pgfirstaid_install_{number}$".encode()
    return HEADER + b"DO " + tag + b"\nBEGIN\n" + body + b"\nEND;\n" + tag + b";\n"


def refresh_installer(data: bytes) -> bytes:
    body = unwrap_installer(data)
    return wrap_installer(body) if data.startswith(MARKER) else data

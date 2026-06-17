#!/usr/bin/env python3
# pgFirstAid staging DB audit script.
# Fetches pgFirstAid.sql from GitHub, runs it against a target database,
# and posts results as a PR comment. Exits non-zero when findings meet or
# exceed the configured severity threshold.
#
# Required env vars:
#   DATABASE_URL              - PostgreSQL connection string
#   GITHUB_TOKEN              - automatically set by GitHub Actions
#   GITHUB_REPOSITORY         - automatically set by GitHub Actions (owner/repo)
#   PR_NUMBER                 - pull request number (from github.event.pull_request.number)
#
# Optional env vars:
#   PGFIRSTAID_VERSION        - git ref to fetch pgFirstAid.sql from (default: main)
#   PGFIRSTAID_FAIL_SEVERITY  - CRITICAL | HIGH | MEDIUM | LOW | NONE (default: HIGH)
#                               NONE disables job failure but still posts results.

import json
import logging
import os
import sys
import time
import urllib.error
import urllib.request
from typing import Any

import psycopg2
import psycopg2.extras

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
logger = logging.getLogger(__name__)

SEVERITY_ORDER = ["CRITICAL", "HIGH", "MEDIUM", "LOW", "INFO"]
SEVERITY_EMOJI = {
    "CRITICAL": "🔴",
    "HIGH": "🟠",
    "MEDIUM": "🟡",
    "LOW": "🔵",
    "INFO": "ℹ️",
}
# Sentinel embedded in the comment body so we can find and update it on
# subsequent runs rather than posting a new comment every time.
COMMENT_SENTINEL = "<!-- pgfirstaid-audit -->"
GITHUB_API = "https://api.github.com"
PGFIRSTAID_RAW = (
    "https://raw.githubusercontent.com/randoneering/pgFirstAid/{version}/pgFirstAid.sql"
)


def load_config() -> dict[str, str]:
    # PR_NUMBER is allowed to be empty (workflow_dispatch without a PR).
    required = {
        "database_url": os.environ.get("DATABASE_URL", ""),
        "github_token": os.environ.get("GITHUB_TOKEN", ""),
        "github_repository": os.environ.get("GITHUB_REPOSITORY", ""),
    }
    missing = [k for k, v in required.items() if not v]
    if missing:
        logger.error("Missing required environment variables: %s", ", ".join(missing))
        sys.exit(1)

    fail_severity = os.environ.get("PGFIRSTAID_FAIL_SEVERITY", "HIGH").upper()
    if fail_severity not in [*SEVERITY_ORDER, "NONE"]:
        logger.error(
            "Invalid PGFIRSTAID_FAIL_SEVERITY '%s'. Must be one of: %s",
            fail_severity,
            ", ".join([*SEVERITY_ORDER, "NONE"]),
        )
        sys.exit(1)

    return {
        **required,
        "pr_number": os.environ.get("PR_NUMBER", ""),
        "pgfirstaid_version": os.environ.get("PGFIRSTAID_VERSION", "main"),
        "fail_severity": fail_severity,
    }


def _urlopen_with_retry(url: str, timeout: int = 30, max_retries: int = 3) -> bytes:
    last_exc: Exception | None = None
    for attempt in range(max_retries):
        try:
            with urllib.request.urlopen(url, timeout=timeout) as resp:  # noqa: S310
                return resp.read()
        except (urllib.error.HTTPError, urllib.error.URLError) as e:
            last_exc = e
            if attempt < max_retries - 1:
                wait = (attempt + 1) * 2
                logger.warning("Retry %d/%d after %ds: %s", attempt + 1, max_retries, wait, e)
                time.sleep(wait)
    logger.error("Request failed after %d retries: %s", max_retries, last_exc)
    sys.exit(1)


def fetch_pgfirstaid_sql(version: str) -> str:
    url = PGFIRSTAID_RAW.format(version=version)
    logger.info("Fetching pgFirstAid.sql from %s", url)
    return _urlopen_with_retry(url).decode("utf-8")


def run_audit(database_url: str, sql: str) -> list[dict[str, Any]]:
    logger.info("Running pgFirstAid audit")
    conn = None
    try:
        conn = psycopg2.connect(database_url, connect_timeout=10)
        conn.autocommit = True
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            # Install/replace the function.
            cur.execute(sql)
            # Return rows in severity order so the comment reads cleanly.
            cur.execute("""
                SELECT *
                FROM pg_firstAid()
                ORDER BY
                    CASE severity
                        WHEN 'CRITICAL' THEN 1
                        WHEN 'HIGH'     THEN 2
                        WHEN 'MEDIUM'   THEN 3
                        WHEN 'LOW'      THEN 4
                        ELSE 5
                    END,
                    category,
                    check_name
            """)
            return [dict(row) for row in cur.fetchall()]
    except psycopg2.OperationalError as e:
        logger.error("Database connection failed: %s", e)
        sys.exit(1)
    finally:
        if conn:
            conn.close()


def severity_index(severity: str) -> int:
    try:
        return SEVERITY_ORDER.index(severity.upper())
    except ValueError:
        # Unknown severities sort after INFO.
        return len(SEVERITY_ORDER)


def should_fail(results: list[dict[str, Any]], fail_severity: str) -> bool:
    if fail_severity == "NONE":
        return False
    threshold = severity_index(fail_severity)
    return any(severity_index(r.get("severity", "INFO")) <= threshold for r in results)


def count_by_severity(results: list[dict[str, Any]]) -> dict[str, int]:
    counts: dict[str, int] = {s: 0 for s in SEVERITY_ORDER}
    for row in results:
        sev = row.get("severity", "INFO").upper()
        counts[sev] = counts.get(sev, 0) + 1
    return counts


def _cell(value: Any, max_len: int = 120) -> str:
    # Flatten and truncate cell content so it doesn't break the markdown table.
    text = str(value or "").replace("\n", " ").replace("|", "\\|").strip()
    if len(text) > max_len:
        text = text[: max_len - 1] + "…"
    return text


def format_comment(
    results: list[dict[str, Any]], fail_severity: str, failed: bool
) -> str:
    counts = count_by_severity(results)

    summary_rows = [
        f"| {SEVERITY_EMOJI.get(sev, '')} {sev} | {counts[sev]} |"
        for sev in SEVERITY_ORDER
        if counts.get(sev, 0) > 0
    ]
    summary_table = (
        "| Severity | Count |\n|---|---|\n" + "\n".join(summary_rows)
        if summary_rows
        else "No issues found. ✅"
    )

    if results:
        header = (
            "| Severity | Category | Check | Object | Issue | Recommended Action |\n"
            "|---|---|---|---|---|---|"
        )
        rows = [
            "| {emoji} {sev} | {cat} | {check} | {obj} | {issue} | {action} |".format(
                emoji=SEVERITY_EMOJI.get(r.get("severity", ""), ""),
                sev=_cell(r.get("severity")),
                cat=_cell(r.get("category")),
                check=_cell(r.get("check_name")),
                obj=_cell(r.get("object_name")),
                issue=_cell(r.get("issue_description")),
                action=_cell(r.get("recommended_action")),
            )
            for r in results
        ]
        full_table = header + "\n" + "\n".join(rows)
        details_block = (
            f"<details>\n<summary>Full results ({len(results)} findings)</summary>"
            f"\n\n{full_table}\n\n</details>"
        )
    else:
        details_block = ""

    if failed:
        threshold_note = (
            f"\n> ⚠️ **Job failed** — findings at or above `{fail_severity}` threshold were found."
        )
    elif fail_severity == "NONE":
        threshold_note = "\n> ℹ️ Failure threshold is `NONE` — audit is informational only."
    else:
        threshold_note = (
            f"\n> ✅ No findings at or above the `{fail_severity}` threshold."
        )

    parts = [
        COMMENT_SENTINEL,
        "### 🩺 pgFirstAid Audit",
        "",
        summary_table,
    ]
    if details_block:
        parts += ["", details_block]
    parts.append(threshold_note)

    return "\n".join(parts)


def github_request(
    method: str,
    url: str,
    token: str,
    body: dict[str, Any] | None = None,
) -> Any:
    data = json.dumps(body).encode("utf-8") if body else None
    req = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "pgfirstaid-audit",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:  # noqa: S310
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        logger.error("GitHub API error: HTTP %s — %s", e.code, e.read().decode())
        return None


def find_existing_comment(token: str, repo: str, pr_number: str) -> int | None:
    # Paginate through all comments on the PR to find a previous audit post.
    page = 1
    while True:
        url = (
            f"{GITHUB_API}/repos/{repo}/issues/{pr_number}/comments"
            f"?per_page=100&page={page}"
        )
        result = github_request("GET", url, token)
        if not isinstance(result, list) or len(result) == 0:
            break
        for comment in result:
            if COMMENT_SENTINEL in comment.get("body", ""):
                return int(comment["id"])
        page += 1
    return None


def post_or_update_comment(
    token: str, repo: str, pr_number: str, body: str
) -> None:
    existing_id = find_existing_comment(token, repo, pr_number)
    if existing_id:
        url = f"{GITHUB_API}/repos/{repo}/issues/comments/{existing_id}"
        method = "PATCH"
        logger.info("Updating existing comment %s", existing_id)
    else:
        url = f"{GITHUB_API}/repos/{repo}/issues/{pr_number}/comments"
        method = "POST"
        logger.info("Posting new comment on PR #%s", pr_number)

    github_request(method, url, token, {"body": body})


def main() -> None:
    config = load_config()

    sql = fetch_pgfirstaid_sql(config["pgfirstaid_version"])
    results = run_audit(config["database_url"], sql)

    failed = should_fail(results, config["fail_severity"])
    comment_body = format_comment(results, config["fail_severity"], failed)

    if config["pr_number"]:
        post_or_update_comment(
            config["github_token"],
            config["github_repository"],
            config["pr_number"],
            comment_body,
        )
    else:
        # workflow_dispatch or other non-PR trigger — print results instead.
        logger.info("No PR number found; printing audit results to stdout.")
        print(comment_body)

    counts = count_by_severity(results)
    for sev in SEVERITY_ORDER:
        if counts.get(sev, 0) > 0:
            logger.info("%s %s: %s", SEVERITY_EMOJI.get(sev, ""), sev, counts[sev])

    if failed:
        logger.error(
            "Audit failed: findings at or above %s severity were found.",
            config["fail_severity"],
        )
        sys.exit(1)

    logger.info("Audit complete. No findings at or above the %s threshold.", config["fail_severity"])


if __name__ == "__main__":
    main()

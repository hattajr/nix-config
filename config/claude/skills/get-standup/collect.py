# /// script
# requires-python = ">=3.12"
# dependencies = ["loguru"]
# ///
"""Deterministic standup collector: scans dev roots and emits raw activity since D days ago."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
from dataclasses import asdict, dataclass, field
from datetime import date, datetime, timedelta
from pathlib import Path

from loguru import logger

SCAN_ROOTS: tuple[str, ...] = ("~/dev", "~/lab")
WALK_IGNORE: frozenset[str] = frozenset(
    {
        ".git",
        "node_modules",
        ".venv",
        "venv",
        "__pycache__",
        "dist",
        "build",
        ".next",
        "target",
        ".mypy_cache",
        ".pytest_cache",
        ".ruff_cache",
        ".ipynb_checkpoints",
    }
)
MAX_FILES_PER_DIR: int = 50
OUTPUT_BASE: Path = Path("~/.claude/standups").expanduser()


@dataclass
class Commit:
    """A single non-merge commit authored by the user."""

    hash: str
    date: str
    subject: str
    body: str
    merged: (
        bool  # reachable from the pushed default branch (shipped vs work-in-progress)
    )


@dataclass
class WorkingChanges:
    """Uncommitted state of a repo's working tree."""

    staged: list[str] = field(default_factory=list)
    unstaged: list[str] = field(default_factory=list)
    untracked: list[str] = field(default_factory=list)
    latest_mtime: float = 0.0


@dataclass
class RepoActivity:
    """Activity collected for one project directory."""

    name: str
    path: str
    is_git: bool
    latest_activity: str
    branch: str | None = None
    shipped_ref: str = ""
    author_emails: list[str] = field(default_factory=list)
    commits: list[Commit] = field(default_factory=list)
    active_branches: list[str] = field(default_factory=list)
    working_changes: WorkingChanges | None = None
    modified_files: list[str] = field(default_factory=list)
    files_truncated: bool = False


def run_git(repo: Path, args: list[str]) -> str:
    """Run a git command in repo and return stripped stdout, empty string on failure."""
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        logger.debug("git {} failed in {}: {}", args, repo, result.stderr.strip())
        return ""
    return result.stdout.rstrip(
        "\n"
    )  # keep leading spaces for porcelain status parsing


def configured_emails(repo: Path, extra: list[str]) -> list[str]:
    """Return the author emails to filter commits by for this repo."""
    emails = list(extra)
    repo_email = run_git(repo, ["config", "user.email"])
    if repo_email and repo_email not in emails:
        emails.append(repo_email)
    return emails


def shipped_ref(repo: Path) -> str:
    """Return the remote default branch (pushed) a commit must reach to count as shipped."""
    origin_head = run_git(repo, ["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"])
    if origin_head:
        return origin_head.removeprefix("refs/remotes/")  # e.g. "origin/main"
    for candidate in ("origin/main", "origin/master"):
        if run_git(
            repo, ["rev-parse", "--verify", "--quiet", f"refs/remotes/{candidate}"]
        ):
            return candidate
    return ""  # no pushed default branch: nothing counts as shipped


def shipped_hashes(
    repo: Path, since: date, emails: list[str], shipped: str
) -> set[str]:
    """Return full hashes of the user's commits reachable from the pushed default branch."""
    if not emails or not shipped:
        return set()
    args = [shipped, "--no-merges", f"--since={since.isoformat()}"]
    for email in emails:
        args.append(f"--author={email}")
    return set(run_git(repo, ["rev-list", *args]).split())


def collect_commits(
    repo: Path, since: date, emails: list[str], shipped: str
) -> list[Commit]:
    """Return the user's non-merge commits across all local branches, flagged shipped vs not."""
    if not emails:
        return []
    merged = shipped_hashes(repo, since, emails, shipped)
    args = [
        "log",
        "--branches",  # local heads only; --all varies with fetch state (non-deterministic)
        "--no-merges",
        f"--since={since.isoformat()}",
        "--date=short",
        "--pretty=format:%H%x1f%cd%x1f%s%x1f%b%x1e",  # committer date matches --since filtering
    ]
    for email in emails:
        args.append(f"--author={email}")
    raw = run_git(repo, args)
    commits: list[Commit] = []
    for record in raw.split("\x1e"):
        record = record.strip(
            "\n"
        )  # \x1f/\x1e are whitespace to str.strip(); strip only newlines
        if not record:
            continue
        parts = record.split("\x1f")
        if len(parts) < 3:
            continue
        full_hash = parts[0]
        body = parts[3].strip() if len(parts) > 3 else ""
        commits.append(
            Commit(
                hash=full_hash[:10],
                date=parts[1],
                subject=parts[2],
                body=body,
                merged=full_hash in merged,
            )
        )
    return commits


def collect_active_branches(repo: Path, since: date) -> list[str]:
    """Return local branches with a commit dated after the cutoff."""
    raw = run_git(
        repo,
        [
            "for-each-ref",
            "--sort=-committerdate",
            "refs/heads",
            "--format=%(refname:short)%x1f%(committerdate:short)",
        ],
    )
    branches: list[str] = []
    for line in raw.splitlines():
        name, _, when = line.partition("\x1f")
        if when and _parse_iso_date(when) >= since:
            branches.append(name)
    return branches


def _path_mtime(repo: Path, path: str) -> float | None:
    """Return a changed path's mtime, falling back to its nearest existing ancestor for deletions."""
    probe = repo / path
    while probe != repo.parent:  # a deleted file dates by the dir that held it
        try:
            return probe.stat().st_mtime
        except OSError:
            probe = probe.parent
    return None


def collect_working_changes(repo: Path, since_ts: float) -> WorkingChanges:
    """Return recently-modified staged, unstaged, and untracked paths from git status porcelain."""
    # -z gives NUL-separated, unquoted paths so spaces and non-ASCII parse correctly.
    raw = run_git(repo, ["status", "--porcelain=v1", "-z"])
    changes = WorkingChanges()
    tokens = raw.split("\x00")
    i = 0
    while i < len(tokens):
        entry = tokens[i]
        i += 1
        if len(entry) < 4:
            continue
        index_status, worktree_status, path = entry[0], entry[1], entry[3:]
        if index_status in ("R", "C") or worktree_status in ("R", "C"):
            i += 1  # rename/copy: the next token is the source path; report only the new path
        mtime = _path_mtime(repo, path)
        if mtime is not None and mtime <= since_ts:
            continue  # stale uncommitted file from before the window
        if mtime is not None:
            changes.latest_mtime = max(changes.latest_mtime, mtime)
        if index_status == "?" and worktree_status == "?":
            changes.untracked.append(path)
            continue
        if index_status not in (" ", "?"):
            changes.staged.append(f"{index_status} {path}")
        if worktree_status not in (" ", "?"):
            changes.unstaged.append(f"{worktree_status} {path}")
    return changes


def collect_modified_files(
    directory: Path, since_ts: float
) -> tuple[list[str], bool, float]:
    """Return files modified after the cutoff, a truncation flag, and the latest mtime seen."""
    found: list[str] = []
    latest = 0.0
    for root, dirs, files in os.walk(directory):
        dirs[:] = [d for d in dirs if d not in WALK_IGNORE and not d.startswith(".")]
        for name in files:
            full = Path(root) / name
            try:
                mtime = full.stat().st_mtime
            except OSError:
                continue
            if mtime > since_ts:
                found.append(str(full.relative_to(directory)))
                latest = max(latest, mtime)
            if len(found) >= MAX_FILES_PER_DIR:
                return found, True, latest
    return found, False, latest


def _parse_iso_date(value: str) -> date:
    """Parse a YYYY-MM-DD string into a date, defaulting to the epoch on failure."""
    try:
        return datetime.strptime(value, "%Y-%m-%d").date()
    except ValueError:
        return date(1970, 1, 1)


def is_git_repo(directory: Path) -> bool:
    """Return True if the directory is a git repo or worktree (.git dir or file)."""
    return (directory / ".git").exists()


def analyze_directory(
    directory: Path, since: date, since_ts: float, extra_emails: list[str]
) -> RepoActivity | None:
    """Collect activity for one directory, or None if nothing changed since the cutoff."""
    if is_git_repo(directory):
        emails = configured_emails(directory, extra_emails)
        shipped = shipped_ref(directory)
        commits = collect_commits(directory, since, emails, shipped)
        branches = collect_active_branches(directory, since)
        working = collect_working_changes(directory, since_ts)
        has_working = bool(working.staged or working.unstaged or working.untracked)
        if not commits and not branches and not has_working:
            return None
        commit_dates = [c.date for c in commits]
        working_date = (
            datetime.fromtimestamp(working.latest_mtime).date().isoformat()
            if working.latest_mtime
            else ""
        )
        candidates = [d for d in [*commit_dates, working_date] if d]
        latest = max(candidates, default=since.isoformat())
        return RepoActivity(
            name=directory.name,
            path=str(directory),
            is_git=True,
            latest_activity=latest,
            branch=run_git(directory, ["rev-parse", "--abbrev-ref", "HEAD"]) or None,
            shipped_ref=shipped,
            author_emails=emails,
            commits=commits,
            active_branches=branches,
            working_changes=working,
        )
    files, truncated, latest_ts = collect_modified_files(directory, since_ts)
    if not files:
        return None
    return RepoActivity(
        name=directory.name,
        path=str(directory),
        is_git=False,
        latest_activity=datetime.fromtimestamp(latest_ts).date().isoformat(),
        modified_files=files,
        files_truncated=truncated,
    )


def discover_directories(roots: list[Path]) -> list[Path]:
    """Return depth-1 visible subdirectories across all existing roots."""
    found: list[Path] = []
    for root in roots:
        if not root.is_dir():
            logger.warning("scan root missing: {}", root)
            continue
        for child in sorted(root.iterdir()):
            if child.is_dir() and not child.name.startswith("."):
                found.append(child)
    return found


def _render_commit_lines(lines: list[str], commits: list[Commit]) -> None:
    """Append formatted commit bullets (with indented bodies) to lines."""
    for c in commits:
        lines.append(f"- `{c.hash}` ({c.date}) {c.subject}")
        if c.body:
            for body_line in c.body.splitlines():
                if body_line.strip():
                    lines.append(f"    {body_line.strip()}")
    lines.append("")


def render_markdown(
    since: str,
    generated_at: str,
    days: int,
    roots: list[str],
    activities: list[RepoActivity],
) -> str:
    """Render the collected activity as a human-readable raw markdown report."""
    lines = [
        f"# Raw standup activity ({since} → {generated_at}, {days}d)",
        "",
        f"Roots scanned: {', '.join(roots)}",
        f"Directories with activity: {len(activities)}",
        "",
    ]
    for act in activities:
        lines.append(f"## {act.name}")
        lines.append(f"`{act.path}` — latest activity {act.latest_activity}")
        lines.append("")
        if act.is_git:
            if act.branch:
                lines.append(f"- Current branch: `{act.branch}`")
            if act.active_branches:
                lines.append(f"- Active branches: {', '.join(act.active_branches)}")
            lines.append("")
            merged = [c for c in act.commits if c.merged]
            unmerged = [c for c in act.commits if not c.merged]
            target = f"`{act.shipped_ref}`" if act.shipped_ref else "a default branch"
            if merged:
                lines.append(f"### Commits — pushed to {target} (shipped)")
                _render_commit_lines(lines, merged)
            if unmerged:
                lines.append(
                    f"### Commits — NOT yet pushed to {target} "
                    "(work in progress, do NOT report as done/shipped)"
                )
                _render_commit_lines(lines, unmerged)
            wc = act.working_changes
            if wc and (wc.staged or wc.unstaged or wc.untracked):
                lines.append("### Working tree (in progress)")
                for item in wc.staged:
                    lines.append(f"- staged: {item}")
                for item in wc.unstaged:
                    lines.append(f"- unstaged: {item}")
                for item in wc.untracked:
                    lines.append(f"- untracked: {item}")
                lines.append("")
        else:
            lines.append("### Modified files (no git)")
            for f in act.modified_files:
                lines.append(f"- {f}")
            if act.files_truncated:
                lines.append(f"- _(truncated at {MAX_FILES_PER_DIR} files)_")
            lines.append("")
    return "\n".join(lines)


def main() -> None:
    """Scan configured roots and write raw.json and raw.md for the standup window."""
    parser = argparse.ArgumentParser(
        description="Collect standup activity over the last N days."
    )
    parser.add_argument(
        "--days", type=int, default=7, help="number of days to look back"
    )
    parser.add_argument(
        "--roots", nargs="*", default=list(SCAN_ROOTS), help="directories to scan"
    )
    parser.add_argument("--out", type=str, default="", help="output directory override")
    args = parser.parse_args()

    today = date.today()
    since = today - timedelta(days=args.days)
    since_ts = datetime.combine(since, datetime.min.time()).timestamp()
    extra_emails = [
        e for e in os.environ.get("STANDUP_EMAILS", "").split(",") if e.strip()
    ]

    roots = [Path(r).expanduser() for r in args.roots]
    out_dir = (
        Path(args.out).expanduser()
        if args.out
        else OUTPUT_BASE / f"{today.strftime('%Y%m%d')}-{args.days}d"
    )
    out_dir.mkdir(parents=True, exist_ok=True)

    logger.info(
        "collecting since {} across {} roots into {}", since, len(roots), out_dir
    )
    activities: list[RepoActivity] = []
    for directory in discover_directories(roots):
        activity = analyze_directory(directory, since, since_ts, extra_emails)
        if activity is not None:
            activities.append(activity)
            logger.info("activity in {}", activity.name)

    root_strs = [str(r) for r in roots]
    report: dict[str, object] = {
        "generated_at": today.isoformat(),
        "since": since.isoformat(),
        "days": args.days,
        "roots": root_strs,
        "directories_with_activity": len(activities),
        "repos": [asdict(a) for a in activities],
    }

    (out_dir / "raw.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    markdown = render_markdown(
        since.isoformat(), today.isoformat(), args.days, root_strs, activities
    )
    (out_dir / "raw.md").write_text(markdown, encoding="utf-8")
    logger.success("OUTDIR={}", out_dir)
    logger.success("wrote raw.json and raw.md for {} directories", len(activities))


if __name__ == "__main__":
    main()

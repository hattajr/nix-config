# /// script
# requires-python = ">=3.12"
# dependencies = ["loguru", "pytest"]
# ///
"""Tests for the deterministic standup collector."""

from __future__ import annotations

import subprocess
from datetime import date, datetime, timedelta
from pathlib import Path

import collect


def _git(repo: Path, *args: str) -> None:
    """Run a git command in repo, raising on failure."""
    subprocess.run(
        ["git", "-C", str(repo), *args], check=True, capture_output=True, text=True
    )


def _init_repo(path: Path, email: str = "me@example.com") -> Path:
    """Create a git repo with a configured identity and one initial commit."""
    path.mkdir(parents=True, exist_ok=True)
    _git(path, "init", "-q")
    _git(path, "config", "user.email", email)
    _git(path, "config", "user.name", "Me")
    (path / "README.md").write_text("init\n", encoding="utf-8")
    _git(path, "add", "README.md")
    _git(path, "commit", "-q", "-m", "initial commit")
    return path


def test_parse_iso_date_valid() -> None:
    """A well-formed date string parses to the matching date."""
    assert collect._parse_iso_date("2026-06-24") == date(2026, 6, 24)


def test_parse_iso_date_invalid_falls_back_to_epoch() -> None:
    """A malformed date string falls back to the epoch rather than raising."""
    assert collect._parse_iso_date("not-a-date") == date(1970, 1, 1)


def test_is_git_repo_detects_dot_git(tmp_path: Path) -> None:
    """A directory with a .git entry is recognized as a repo, a plain one is not."""
    repo = _init_repo(tmp_path / "repo")
    plain = tmp_path / "plain"
    plain.mkdir()
    assert collect.is_git_repo(repo) is True
    assert collect.is_git_repo(plain) is False


def test_path_mtime_existing_and_deleted(tmp_path: Path) -> None:
    """An existing file yields its mtime; a deleted file falls back to its parent dir mtime."""
    existing = tmp_path / "recent.txt"
    existing.write_text("x", encoding="utf-8")
    assert collect._path_mtime(tmp_path, "recent.txt") is not None
    subdir = tmp_path / "sub"
    subdir.mkdir()
    # a deleted file under an existing dir dates by that dir, not None
    assert collect._path_mtime(tmp_path, "sub/gone.txt") == subdir.stat().st_mtime


def test_collect_commits_filters_by_author(tmp_path: Path) -> None:
    """Only commits by the configured email are collected."""
    repo = _init_repo(tmp_path / "repo", email="me@example.com")
    (repo / "mine.txt").write_text("mine", encoding="utf-8")
    _git(repo, "add", "mine.txt")
    _git(repo, "commit", "-q", "-m", "my work")
    _git(
        repo,
        "-c",
        "user.email=other@example.com",
        "-c",
        "user.name=Other",
        "commit",
        "-q",
        "--allow-empty",
        "-m",
        "their work",
    )
    since = date.today() - timedelta(days=1)
    shipped = collect.shipped_ref(repo)
    commits = collect.collect_commits(repo, since, ["me@example.com"], shipped)
    subjects = {c.subject for c in commits}
    assert "my work" in subjects
    assert "their work" not in subjects


def test_collect_commits_flags_shipped_by_push(tmp_path: Path) -> None:
    """A commit counts as shipped only once pushed to the remote default branch."""
    remote = tmp_path / "remote.git"
    subprocess.run(
        ["git", "init", "--bare", "-q", str(remote)], check=True, capture_output=True
    )
    repo = _init_repo(tmp_path / "repo")
    default = collect.run_git(repo, ["rev-parse", "--abbrev-ref", "HEAD"])
    _git(repo, "remote", "add", "origin", str(remote))
    _git(repo, "push", "-q", "origin", default)
    _git(repo, "remote", "set-head", "origin", default)  # creates origin/HEAD

    (repo / "shipped.txt").write_text("done", encoding="utf-8")
    _git(repo, "add", "shipped.txt")
    _git(repo, "commit", "-q", "-m", "shipped work")
    _git(repo, "push", "-q", "origin", default)  # pushed -> shipped

    (repo / "local.txt").write_text("local", encoding="utf-8")
    _git(repo, "add", "local.txt")
    _git(repo, "commit", "-q", "-m", "local only work")  # committed, NOT pushed

    _git(repo, "checkout", "-q", "-b", "feature")
    (repo / "wip.txt").write_text("wip", encoding="utf-8")
    _git(repo, "add", "wip.txt")
    _git(repo, "commit", "-q", "-m", "wip work")  # feature branch, not pushed

    since = date.today() - timedelta(days=1)
    shipped = collect.shipped_ref(repo)
    commits = collect.collect_commits(repo, since, ["me@example.com"], shipped)
    by_subject = {c.subject: c.merged for c in commits}
    assert by_subject["shipped work"] is True
    assert by_subject["local only work"] is False
    assert by_subject["wip work"] is False


def test_collect_working_changes_parses_status(tmp_path: Path) -> None:
    """Staged, unstaged, and untracked paths are split correctly with leading spaces preserved."""
    repo = _init_repo(tmp_path / "repo")
    (repo / "README.md").write_text("changed\n", encoding="utf-8")  # unstaged modify
    (repo / "staged.txt").write_text("new\n", encoding="utf-8")
    _git(repo, "add", "staged.txt")  # staged add
    (repo / "untracked.txt").write_text("loose\n", encoding="utf-8")  # untracked
    since_ts = date.today() - timedelta(days=1)
    since_float = datetime.combine(since_ts, datetime.min.time()).timestamp()
    changes = collect.collect_working_changes(repo, since_float)
    assert any("README.md" in c for c in changes.unstaged)
    assert any("staged.txt" in c for c in changes.staged)
    assert "untracked.txt" in changes.untracked


def test_collect_working_changes_handles_spaced_and_renamed_paths(
    tmp_path: Path,
) -> None:
    """Spaced and renamed paths parse without quotes, and a rename reports only the new path."""
    repo = _init_repo(tmp_path / "repo")
    (repo / "a b.txt").write_text("hi", encoding="utf-8")
    _git(repo, "add", "a b.txt")
    _git(repo, "commit", "-q", "-m", "add spaced")
    _git(repo, "mv", "a b.txt", "c d.txt")  # staged rename
    (repo / "e f.txt").write_text("loose", encoding="utf-8")  # untracked, spaced
    since_float = (datetime.now() - timedelta(days=1)).timestamp()
    changes = collect.collect_working_changes(repo, since_float)
    assert any("c d.txt" in s and '"' not in s for s in changes.staged)
    assert "e f.txt" in changes.untracked
    assert not any(
        "a b.txt" in x for x in changes.staged + changes.unstaged + changes.untracked
    )


def test_collect_working_changes_excludes_stale_files(tmp_path: Path) -> None:
    """Uncommitted files last modified before the cutoff are excluded from scope."""
    import os

    repo = _init_repo(tmp_path / "repo")
    stale = repo / "old.txt"
    stale.write_text("ancient", encoding="utf-8")
    old_ts = (datetime.now() - timedelta(days=30)).timestamp()
    os.utime(stale, (old_ts, old_ts))
    since_float = (datetime.now() - timedelta(days=7)).timestamp()
    changes = collect.collect_working_changes(repo, since_float)
    assert not any("old.txt" in c for c in changes.untracked)

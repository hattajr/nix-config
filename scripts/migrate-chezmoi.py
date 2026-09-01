#!/usr/bin/env python3
"""Safe, resumable takeover of the pinned ChezMoi reference.

This program never invokes a mutating ChezMoi command.  It only moves exact,
pre-approved existing paths into a private backup before Home Manager activation.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parent.parent
INVENTORY = ROOT / "migration/chezmoi-af63b22.inventory.json"
SOURCE_COMMIT = "af63b22ec845bdcb7c7f2780c06c2184bd0d7efe"
RUNTIME_PREFIXES = (".pi/agent/auth.json", ".pi/agent/secrets.json", ".pi/agent/sessions", ".pi/agent/node_modules")


def fail(message: str) -> None:
    print(f"nix-migration: ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def state_root(home: Path) -> Path:
    return Path(os.environ.get("XDG_STATE_HOME", home / ".local/state")) / "nix-config/migrations/chezmoi-v1"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def source_commit(source: Path) -> str:
    if not source.is_dir():
        fail(f"ChezMoi source is absent: {source}")
    try:
        return subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
    except (OSError, subprocess.CalledProcessError):
        fail(f"ChezMoi source is not a readable Git checkout: {source}")


def load_inventory(source: Path) -> dict:
    inventory = json.loads(INVENTORY.read_text())
    if source_commit(source) != inventory["sourceCommit"]:
        fail("ChezMoi source commit differs from the reviewed inventory; update and review the inventory before migrating")
    return inventory


def is_safe_leaf(path: Path) -> bool:
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError:
        return False
    return stat.S_ISREG(mode) or stat.S_ISLNK(mode)


def is_runtime(relative: str) -> bool:
    return relative == RUNTIME_PREFIXES[0] or relative == RUNTIME_PREFIXES[1] or relative.startswith(RUNTIME_PREFIXES[2] + "/") or relative.startswith(RUNTIME_PREFIXES[3] + "/")


def guarded_paths(inventory: dict) -> list[str]:
    """Return only leaf paths; ignoring a container would hide unrelated files."""
    paths = [item["path"] for item in inventory["items"] if item["owner"] in ("home-manager", "retired")]
    return sorted(path for path in paths if not any(other != path and other.startswith(path + "/") for other in paths))


def plan(home: Path, source: Path) -> dict:
    inventory = load_inventory(source)
    entries = []
    for item in inventory["items"]:
        relative = item["path"]
        target = home / relative
        # Container directories stay real directories. Runtime state is never
        # moved even if an old manifest accidentally classifies it otherwise.
        if not target.exists() and not target.is_symlink() or target.is_dir() or is_runtime(relative):
            continue
        if not is_safe_leaf(target):
            fail(f"refusing special file or unsupported target: {target}")
        entries.append({"path": relative, "owner": item["owner"], "treatment": item["treatment"], "sha256": sha256(target) if target.is_file() and not target.is_symlink() else None, "symlink": os.readlink(target) if target.is_symlink() else None})
    payload = {"schema": 1, "sourceCommit": inventory["sourceCommit"], "home": str(home), "entries": entries, "guardPaths": guarded_paths(inventory)}
    payload["digest"] = hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    return payload


def transaction_dir(home: Path, digest: str) -> Path:
    return state_root(home) / "transactions" / digest


def write_private(path: Path, data: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(data)
    os.chmod(temporary, 0o600)
    temporary.replace(path)


def legacy_mosh_artifacts(home: Path) -> list[Path]:
    # Discovery only. Package-manager and system paths are intentionally never
    # changed by migration; report possible old user artifacts for approval.
    candidates = [
        home / ".local/bin/mosh", home / ".local/bin/mosh-client",
        home / ".local/bin/mosh-server", home / ".local/share/mosh-osc52.built",
        home / "src/mosh-osc52", home / "mosh-osc52-src.tar.gz",
    ]
    return [path for path in candidates if path.exists() or path.is_symlink()]


def show_plan(payload: dict) -> None:
    print(f"nix-migration: reviewed ChezMoi commit {payload['sourceCommit']}")
    print(f"nix-migration: plan digest {payload['digest']}")
    print(f"nix-migration: {len(payload['entries'])} existing managed leaves require takeover")
    for entry in payload["entries"]:
        print(f"  {entry['treatment']:17} {entry['path']}")
    for artifact in legacy_mosh_artifacts(Path(payload["home"])):
        print(f"  legacy-mosh       {artifact.relative_to(Path(payload['home']))} (reported only; not removed)")


def resumable_plan(home: Path, source: Path) -> dict | None:
    # `current` is durable before backup begins. It therefore covers an
    # approved-but-not-started plan, a partial journal, activation-pending,
    # and terminal complete. Rolled-back transactions intentionally permit a
    # new plan.
    load_inventory(source)
    current = state_root(home) / "current"
    if not current.exists():
        return None
    tx = transaction_dir(home, current.read_text().strip())
    plan_file = tx / "plan.json"
    if not plan_file.exists():
        return None
    result = tx / "result.json"
    if result.exists() and json.loads(result.read_text()).get("state") == "rolled-back":
        return None
    return json.loads(plan_file.read_text())


def create_plan(args: argparse.Namespace) -> int:
    payload = resumable_plan(args.home, args.source) or plan(args.home, args.source)
    tx = transaction_dir(args.home, payload["digest"])
    write_private(tx / "plan.json", json.dumps(payload, indent=2) + "\n")
    write_private(state_root(args.home) / "current", payload["digest"] + "\n")
    show_plan(payload)
    return 0


def install_overlap_guard(source: Path, tx: Path, paths: list[str]) -> str:
    """Prevent a later chezmoi apply from overwriting takeover paths.

    The source is deliberately changed only after its reviewed commit has been
    verified and backups are complete. The original ignore file is retained in
    the private transaction so rollback can restore it before activation.
    """
    ignore = source / ".chezmoiignore"
    before = ignore.read_text() if ignore.exists() else ""
    marker_start = "# BEGIN nix-config Home Manager takeover"
    marker_end = "# END nix-config Home Manager takeover"
    if marker_start in before or marker_end in before:
        fail("ChezMoi ignore file already contains a nix-config takeover guard")
    write_private(tx / "chezmoiignore.before", before)
    block = "\n".join([marker_start, *paths, marker_end]) + "\n"
    content = before.rstrip("\n") + ("\n" if before else "") + block
    temporary = ignore.with_suffix(".nix-config.tmp")
    temporary.write_text(content)
    temporary.replace(ignore)
    return hashlib.sha256(content.encode()).hexdigest()


def execute(args: argparse.Namespace) -> int:
    payload = resumable_plan(args.home, args.source) or plan(args.home, args.source)
    if args.digest != payload["digest"]:
        fail("plan digest does not match current files; run plan again and explicitly approve the new digest")
    tx = transaction_dir(args.home, payload["digest"])
    result = tx / "result.json"
    existing_state = json.loads(result.read_text()).get("state") if result.exists() else None
    if existing_state == "complete":
        print(f"nix-migration: transaction {payload['digest']} is already complete")
        return 0
    if existing_state in ("rollback-restoring", "rollback-cleanup"):
        # An exact installer retry must finish a crashed rollback before it can
        # ever reuse a journal. Re-plan from restored targets afterwards.
        rollback(args)
        payload = plan(args.home, args.source)
        if args.digest != payload["digest"]:
            fail("rollback restored changed files; review and approve the new migration digest")
        tx = transaction_dir(args.home, payload["digest"])
        result = tx / "result.json"
    write_private(tx / "plan.json", json.dumps(payload, indent=2) + "\n")
    journal = tx / "journal.jsonl"
    backup = tx / "backup"
    backup.mkdir(parents=True, exist_ok=True)
    os.chmod(backup, 0o700)
    records: dict[str, str] = {}
    if journal.exists():
        for line in journal.read_text().splitlines():
            if line:
                record = json.loads(line)
                records[record["path"]] = record["state"]

    def record(output, relative: str, state: str) -> None:
        output.write(json.dumps({"path": relative, "state": state, "at": datetime.now(timezone.utc).isoformat()}, sort_keys=True) + "\n")
        output.flush()
        os.fsync(output.fileno())
        records[relative] = state

    with journal.open("a", encoding="utf-8") as output:
        os.chmod(journal, 0o600)
        for entry in payload["entries"]:
            relative = entry["path"]
            state = records.get(relative)
            if state == "source-cleared":
                continue
            target = args.home / relative
            destination = backup / relative
            if state == "backup-started":
                # A crash during copying leaves only a private, incomplete
                # backup candidate. The original is still present, so discard
                # that candidate and retry without touching user data.
                if destination.exists() or destination.is_symlink():
                    destination.unlink()
                state = None
            if state is None:
                if destination.exists() or destination.is_symlink():
                    fail(f"backup already exists without a journal record: {destination}")
                if not target.exists() and not target.is_symlink():
                    fail(f"target changed since planning: {target}")
                if not is_safe_leaf(target):
                    fail(f"target is no longer a regular file or symlink: {target}")
                if entry["sha256"] is not None and (target.is_symlink() or sha256(target) != entry["sha256"]):
                    fail(f"target changed since planning: {target}")
                if entry["symlink"] is not None and (not target.is_symlink() or os.readlink(target) != entry["symlink"]):
                    fail(f"target changed since planning: {target}")
                destination.parent.mkdir(parents=True, exist_ok=True)
                record(output, relative, "backup-started")
                if target.is_symlink():
                    destination.symlink_to(os.readlink(target))
                else:
                    shutil.copy2(target, destination)
                    if sha256(target) != sha256(destination):
                        fail(f"backup verification failed: {target}")
                record(output, relative, "backup-verified")
            if records.get(relative) == "backup-verified":
                # Either this is the first pass, or a prior process died after
                # durable backup verification but before/after unlinking.
                if target.exists() or target.is_symlink():
                    if not is_safe_leaf(target):
                        fail(f"target is no longer a regular file or symlink: {target}")
                    target.unlink()
                record(output, relative, "source-cleared")
    guard_digest = install_overlap_guard(args.source, tx, payload["guardPaths"])
    write_private(result, json.dumps({"state": "activation-pending", "digest": payload["digest"], "guardDigest": guard_digest}, indent=2) + "\n")
    print(f"nix-migration: backup complete at {backup}; rerun the original installer to activate Home Manager")
    return 0


def status(args: argparse.Namespace) -> int:
    current = state_root(args.home) / "current"
    if not current.exists():
        print("nix-migration: no ChezMoi migration transaction")
        return 0
    digest = current.read_text().strip()
    result = transaction_dir(args.home, digest) / "result.json"
    if not result.exists():
        print(f"nix-migration: planned {digest}")
        return 0
    payload = json.loads(result.read_text())
    guard = transaction_dir(args.home, digest) / "chezmoiignore.before"
    if payload.get("state") in ("activation-pending", "complete"):
        if not guard.exists() or not args.source.joinpath(".chezmoiignore").exists():
            fail("ChezMoi takeover guard is missing; rerun migration rollback or repair the source before applying")
        if hashlib.sha256(args.source.joinpath(".chezmoiignore").read_bytes()).hexdigest() != payload.get("guardDigest"):
            fail("ChezMoi takeover guard was altered; refusing to apply overlapping configurations")
    print(json.dumps(payload, indent=2))
    return 0


def mark_complete_after_activation(home: Path) -> int:
    """Internal handoff called by bro only after its activate command succeeds."""
    current = state_root(home) / "current"
    if not current.exists():
        fail("no migration transaction to complete")
    digest = current.read_text().strip()
    tx = transaction_dir(home, digest)
    result = tx / "result.json"
    if result.exists() and json.loads(result.read_text()).get("state") == "complete":
        return 0
    if not result.exists() or json.loads(result.read_text()).get("state") != "activation-pending":
        fail("migration is not awaiting activation")
    payload = json.loads(result.read_text())
    write_private(result, json.dumps({"state": "complete", "digest": digest, "guardDigest": payload.get("guardDigest")}, indent=2) + "\n")
    return 0


def resume(args: argparse.Namespace) -> int:
    payload = resumable_plan(args.home, args.source)
    if payload is None:
        fail("no approved activation-pending migration transaction to resume")
    args.digest = payload["digest"]
    return execute(args)


def legacy(args: argparse.Namespace) -> int:
    for artifact in legacy_mosh_artifacts(args.home):
        print(f"nix-migration: legacy Mosh artifact (not removed): {artifact}")
    return 0


def rollback(args: argparse.Namespace) -> int:
    current = state_root(args.home) / "current"
    if not current.exists():
        fail("no migration transaction to roll back")
    digest = current.read_text().strip()
    tx = transaction_dir(args.home, digest)
    journal = tx / "journal.jsonl"
    rollback_journal = tx / "rollback.jsonl"
    result = tx / "result.json"
    result_state = json.loads(result.read_text()).get("state") if result.exists() else None
    if result_state == "rolled-back":
        print(f"nix-migration: transaction {digest} is already rolled back")
        return 0
    # A completed activation owns its current Home Manager links. Rollback is
    # deliberately unavailable rather than rewriting terminal state or trying
    # to move over those links; generation rollback is a separate operation.
    if result_state == "complete":
        fail("migration is already complete; rollback is not applicable")

    ignore_backup = tx / "chezmoiignore.before"
    if ignore_backup.exists():
        ignore = args.source / ".chezmoiignore"
        previous = ignore_backup.read_text()
        temporary = ignore.with_suffix(".nix-config.tmp")
        temporary.write_text(previous)
        temporary.replace(ignore)

    def finish_cleanup() -> int:
        # Cleanup is only entered after every eligible backup has a durable
        # restored marker. All paths below are private transaction state.
        if journal.exists():
            journal.unlink()
        backup_root = tx / "backup"
        if backup_root.exists():
            shutil.rmtree(backup_root)
        if rollback_journal.exists():
            rollback_journal.unlink()
        write_private(result, json.dumps({"state": "rolled-back", "digest": digest}, indent=2) + "\n")
        print(f"nix-migration: restored transaction {digest}; a later retry creates a fresh backup")
        return 0

    if result_state == "rollback-cleanup":
        return finish_cleanup()
    if not journal.exists():
        fail("transaction has no backup journal to roll back")

    source_states: dict[str, str] = {}
    for line in journal.read_text().splitlines():
        if line:
            record = json.loads(line)
            source_states[record["path"]] = record["state"]
    restore_states: dict[str, str] = {}
    if rollback_journal.exists():
        for line in rollback_journal.read_text().splitlines():
            if line:
                record = json.loads(line)
                restore_states[record["path"]] = record["state"]

    write_private(result, json.dumps({"state": "rollback-restoring", "digest": digest}, indent=2) + "\n")
    with rollback_journal.open("a", encoding="utf-8") as output:
        os.chmod(rollback_journal, 0o600)
        def restore_record(relative: str, state: str) -> None:
            output.write(json.dumps({"path": relative, "state": state, "at": datetime.now(timezone.utc).isoformat()}, sort_keys=True) + "\n")
            output.flush()
            os.fsync(output.fileno())
            restore_states[relative] = state

        for relative, source_state in reversed(list(source_states.items())):
            target = args.home / relative
            backup = tx / "backup" / relative
            restore_state = restore_states.get(relative)
            if restore_state == "restored" or restore_state == "not-needed":
                continue
            if restore_state == "restore-started":
                if target.exists() or target.is_symlink():
                    if backup.exists() or backup.is_symlink():
                        fail(f"rollback has both target and backup: {target}")
                    restore_record(relative, "restored")
                    continue
                if not backup.exists() and not backup.is_symlink():
                    fail(f"rollback backup disappeared: {backup}")
            elif source_state == "backup-started":
                # The original was never cleared; an incomplete private copy
                # is discarded only during final transaction cleanup.
                if not target.exists() and not target.is_symlink():
                    fail(f"rollback cannot find original target: {target}")
                restore_record(relative, "not-needed")
                continue
            elif source_state == "backup-verified" and (target.exists() or target.is_symlink()):
                # Crash before unlink: source is still the authoritative copy.
                restore_record(relative, "not-needed")
                continue
            elif target.exists() or target.is_symlink():
                fail(f"refusing rollback over changed destination: {target}")

            if not backup.exists() and not backup.is_symlink():
                fail(f"backup is missing: {backup}")
            # Durable intent is written before the same-filesystem move. A
            # crash after move is recognized by target-present/backup-absent.
            restore_record(relative, "restore-started")
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(backup), str(target))
            restore_record(relative, "restored")

    write_private(result, json.dumps({"state": "rollback-cleanup", "digest": digest}, indent=2) + "\n")
    return finish_cleanup()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", type=Path, default=Path.home())
    parser.add_argument("--source", type=Path, default=Path(os.environ.get("CHEZMOI_SOURCE", Path.home() / ".local/share/chezmoi")))
    parser.add_argument("--inventory", type=Path, help="explicit reviewed inventory (test fixture only)")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("plan")
    execute_parser = commands.add_parser("execute")
    execute_parser.add_argument("--digest", required=True)
    commands.add_parser("status")
    commands.add_parser("resume")
    commands.add_parser("rollback")
    commands.add_parser("legacy")
    args = parser.parse_args()
    global INVENTORY
    if args.inventory:
        INVENTORY = args.inventory
    if args.command == "plan": return create_plan(args)
    if args.command == "execute": return execute(args)
    if args.command == "resume": return resume(args)
    if args.command == "rollback": return rollback(args)
    if args.command == "legacy": return legacy(args)
    return status(args)

if __name__ == "__main__":
    raise SystemExit(main())

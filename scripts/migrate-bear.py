#!/usr/bin/env python3
"""Read-only Bear snapshot, verified staging, and append-only Sloth migration.

Only the copied SQLite database is opened. The original is read using ordinary
read-only file handles, including its WAL, then verified unchanged byte-for-byte.
"""
from __future__ import annotations

import argparse
import collections
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import stat
import subprocess
import sys
import tempfile
import urllib.parse
import uuid

NAMESPACE = uuid.UUID("ea2ef659-c93f-5c81-8a16-1c54d322b075")
BEAR_DEFAULT = Path.home() / "Library/Group Containers/9K33E3U3T4.net.shinyfrog.bear/Application Data"
SLOTH_DEFAULT = Path.home() / "Library/Application Support/Sloth"
LINK = re.compile(r'(!?)\[((?:\\.|[^\]\\\n])*)\]\(\s*(<[^>\n]*>|(?:\\.|[^()\n]|\([^()\n]*\))*)\s*\)')
EPOCH = dt.datetime(2001, 1, 1, tzinfo=dt.timezone.utc)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def json_bytes(value) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")


def read_regular(path: Path) -> bytes:
    """Do not follow a symlink, even for a source file."""
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError(f"Not a regular file: {path}")
        return stream.read()


def inside(child: Path, parent: Path) -> bool:
    return child.resolve().is_relative_to(parent.resolve())


def source_files(source: Path) -> list[Path]:
    paths = [source / "database.sqlite"]
    for suffix in ("-wal", "-shm", "-journal"):
        path = source / ("database.sqlite" + suffix)
        if path.exists():
            paths.append(path)
    local = source / "Local Files"
    if local.exists():
        for path in local.rglob("*"):
            if path.is_symlink():
                raise ValueError(f"Source contains a symlink: {path}")
            if path.is_file():
                paths.append(path)
    return sorted(paths)


def fingerprints(source: Path) -> dict:
    return {str(path.relative_to(source)): {
        "sha256": digest(read_regular(path)), "size": path.stat().st_size,
        "modifiedNanoseconds": path.stat().st_mtime_ns,
    } for path in source_files(source)}


def stable_snapshot(source: Path, snapshot: Path) -> dict:
    """Copy a consistent DB/WAL and assets without SQLite touching the source."""
    for _ in range(3):
        before = fingerprints(source)
        if snapshot.exists():
            shutil.rmtree(snapshot)
        snapshot.mkdir(parents=True, mode=0o700)
        for name, info in before.items():
            path = snapshot / name
            path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            content = read_regular(source / name)
            if digest(content) != info["sha256"]:
                break
            path.write_bytes(content)
            path.chmod(0o600)
        else:
            if before == fingerprints(source):
                # Shared-memory indexes are ephemeral and are regenerated only
                # in this private copy. The copied WAL retains committed edits.
                for suffix in ("-shm",):
                    (snapshot / ("database.sqlite" + suffix)).unlink(missing_ok=True)
                return before
    raise RuntimeError("Bear changed during the snapshot. Try again when it is idle.")


def stable_id(key: str) -> str:
    return str(uuid.uuid5(NAMESPACE, key)).upper()


def iso_date(value) -> str:
    if value is None:
        raise ValueError("A source note has a missing timestamp")
    return (EPOCH + dt.timedelta(seconds=float(value))).strftime("%Y-%m-%dT%H:%M:%SZ")


def code_ranges(text: str) -> list[tuple[int, int]]:
    ranges = [(m.start(), m.end()) for m in re.finditer(
        r'(?ms)^[ \t]*(`{3,}|~{3,})[^\n]*(?:\n|$).*?(?:^[ \t]*\1[ \t]*(?:\n|$)|\Z)', text)]
    ranges += [(m.start(), m.end()) for m in re.finditer(r'`[^`\n]*`', text)]
    return ranges


def rewrite_attachments(text: str, filenames: dict[str, str]) -> tuple[str, collections.Counter]:
    ignored = code_ranges(text)
    replacements = []
    counts = collections.Counter()
    for match in LINK.finditer(text):
        if any(start < match.end() and end > match.start() for start, end in ignored):
            continue
        preceding = len(text[:match.start()]) - len(text[:match.start()].rstrip("\\"))
        if preceding % 2:
            continue
        start, end = match.span(3)
        raw = match.group(3).rstrip()
        end = start + len(raw)
        if raw.startswith("<") and raw.endswith(">"):
            raw = raw[1:-1]; start += 1; end -= 1
        else:
            title = re.search(r'''\s+["'][^"']*["']$''', raw)
            if title:
                raw = raw[:title.start()]; end = start + len(raw)
        decoded = urllib.parse.unquote(re.sub(r"\\(.)", r"\1", raw))
        if decoded in filenames:
            replacements.append((start, end, filenames[decoded]))
            counts[decoded] += 1
    for start, end, target in reversed(replacements):
        text = text[:start] + target + text[end:]
    return text, counts


def resolve_source_attachment(snapshot: Path, row: sqlite3.Row) -> Path:
    identity, filename = row["ZUNIQUEIDENTIFIER"], row["ZFILENAME"]
    if not identity or not filename or Path(identity).name != identity or Path(filename).name != filename:
        raise ValueError("Attachment metadata contains an invalid filename")
    candidates = [snapshot / "Local Files" / folder / identity / filename
                  for folder in ("Note Images", "Note Files", "Note Videos")]
    found = [p for p in candidates if p.is_file() and not p.is_symlink()]
    if len(found) != 1:
        raise ValueError(f"Missing or ambiguous attachment record {row['Z_PK']}")
    return found[0]


def stage_migration(source: Path, staging: Path) -> dict:
    source, staging = source.resolve(), staging.absolute()
    if inside(staging, source) or inside(source, staging):
        raise ValueError("Staging must be separate from the Bear data directory")
    staging.mkdir(parents=True, exist_ok=False, mode=0o700)
    original = stable_snapshot(source, staging / "source-snapshot")
    (staging / "source-fingerprints.json").write_bytes(json_bytes(original))
    connection = sqlite3.connect(staging / "source-snapshot/database.sqlite")
    connection.row_factory = sqlite3.Row
    if connection.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
        raise ValueError("The copied Bear database failed its integrity check")
    source_notes = list(connection.execute("SELECT * FROM ZSFNOTE ORDER BY Z_PK"))
    source_files_rows = list(connection.execute("SELECT * FROM ZSFNOTEFILE ORDER BY Z_PK"))
    tags = collections.defaultdict(list)
    for row in connection.execute("SELECT j.Z_5NOTES, t.ZTITLE FROM Z_5TAGS j JOIN ZSFNOTETAG t ON t.Z_PK=j.Z_13TAGS"):
        tags[row[0]].append(row[1])
    attachment_rows = collections.defaultdict(list)
    for row in source_files_rows:
        attachment_rows[row["ZNOTE"]].append(row)
    counts = {"total": len(source_notes), "active": 0, "archived": 0, "trashed": 0,
              "encrypted": 0, "locked": 0, "permanentlyDeleted": 0, "pinned": 0}
    notes, records, assets = [], [], {}
    attachment_root = staging / "attachments"
    attachment_root.mkdir(mode=0o700)
    problems = []
    for row in source_notes:
        for key, column in (("encrypted", "ZENCRYPTED"), ("locked", "ZLOCKED"),
                            ("permanentlyDeleted", "ZPERMANENTLYDELETED"), ("pinned", "ZPINNED")):
            counts[key] += bool(row[column])
        state = "trashed" if row["ZTRASHED"] else "archived" if row["ZARCHIVED"] else "active"
        counts[state] += 1
        key = f"bear-note:{row['ZUNIQUEIDENTIFIER']}:{row['Z_PK']}"
        if row["ZENCRYPTED"] or row["ZTEXT"] is None:
            problems.append(f"Note record {row['Z_PK']} is encrypted or has no readable text")
            continue
        filenames, note_assets = {}, []
        for file_row in attachment_rows[row["Z_PK"]]:
            if file_row["ZENCRYPTED"]:
                problems.append(f"Attachment record {file_row['Z_PK']} is encrypted"); continue
            try:
                origin = resolve_source_attachment(staging / "source-snapshot", file_row)
                payload = read_regular(origin)
                checksum = digest(payload)
                extension = re.sub(r"[^a-z0-9]", "", origin.suffix.lower().lstrip("."))[:16] or "bin"
                asset_id = stable_id(f"bear-file:{file_row['ZUNIQUEIDENTIFIER']}:{checksum}").lower()
                target = f"attachments/{asset_id}.{extension}"
                prior = filenames.get(file_row["ZFILENAME"])
                if prior is not None and prior != target:
                    raise ValueError(f"Ambiguous duplicate filename in note record {row['Z_PK']}")
                filenames[file_row["ZFILENAME"]] = target
                (staging / target).write_bytes(payload)
                (staging / target).chmod(0o600)
                assets[target] = {"sha256": checksum, "bytes": len(payload)}
                note_assets.append({"sourceRecord": file_row["Z_PK"], "sourceID": file_row["ZUNIQUEIDENTIFIER"],
                                    "path": target, "filename": file_row["ZFILENAME"], "sha256": checksum})
            except (OSError, ValueError) as error:
                problems.append(str(error))
        original_text = row["ZTEXT"]
        text, reference_counts = rewrite_attachments(original_text, filenames)
        # Bear stores tags in both text and relations. Preserve text exactly and
        # refuse silent metadata loss if a future version stops doing so.
        missing_tags = [tag for tag in tags[row["Z_PK"]] if "#" + tag not in original_text]
        if missing_tags:
            problems.append(f"Note record {row['Z_PK']} has {len(missing_tags)} tags absent from its Markdown")
        for name in filenames:
            if not reference_counts[name]:
                problems.append(f"An attachment in note record {row['Z_PK']} has no Markdown reference")
        note = {"id": stable_id(key), "text": text,
                "createdAt": iso_date(row["ZCREATIONDATE"]), "modifiedAt": iso_date(row["ZMODIFICATIONDATE"]),
                "pinned": bool(row["ZPINNED"]), "archived": bool(row["ZARCHIVED"]), "trashed": bool(row["ZTRASHED"])}
        notes.append(note)
        records.append({"sourceKey": key, "sourceRecord": row["Z_PK"], "sourceID": row["ZUNIQUEIDENTIFIER"],
                        "slothID": note["id"], "sourceTextSHA256": digest(original_text.encode()),
                        "importedSHA256": digest(json_bytes(note)), "tags": sorted(tags[row["Z_PK"]]),
                        "createdReferenceSeconds": row["ZCREATIONDATE"], "modifiedReferenceSeconds": row["ZMODIFICATIONDATE"],
                        "attachments": note_assets, "rewrittenAttachmentReferences": sum(reference_counts.values())})
    connection.close()
    if fingerprints(source) != original:
        problems.append("Bear changed while migration was staged; take a fresh snapshot before applying")
    note_data = json_bytes(notes)
    (staging / "notes.json").write_bytes(note_data)
    manifest = {"version": 1, "sourceDirectory": str(source), "createdAt": dt.datetime.now(dt.timezone.utc).isoformat(),
                "counts": counts, "sourceAttachmentRecords": len(source_files_rows), "uniqueAttachments": len(assets),
                "attachmentBytes": sum(a["bytes"] for a in assets.values()), "notesSHA256": digest(note_data),
                "notes": records, "assets": assets, "problems": problems,
                "sourceUnchanged": fingerprints(source) == original}
    (staging / "manifest.json").write_bytes(json_bytes(manifest))
    return manifest


def load_stage(staging: Path) -> tuple[dict, list]:
    manifest = json.loads(read_regular(staging / "manifest.json"))
    if manifest["problems"]:
        raise ValueError("Migration contains unresolved problems and cannot be applied")
    note_data = read_regular(staging / "notes.json")
    if digest(note_data) != manifest["notesSHA256"]:
        raise ValueError("Staged notes do not match their manifest")
    notes = json.loads(note_data)
    if len(notes) != manifest["counts"]["total"] or len({n["id"] for n in notes}) != len(notes):
        raise ValueError("Staged note count or IDs are invalid")
    for relative, info in manifest["assets"].items():
        if not re.fullmatch(r"attachments/[a-f0-9-]+\.[a-z0-9]+", relative):
            raise ValueError("Invalid staged attachment path")
        data = read_regular(staging / relative)
        if digest(data) != info["sha256"] or len(data) != info["bytes"]:
            raise ValueError("Staged attachment does not match its manifest")
    return manifest, notes


def atomic_write(path: Path, payload: bytes) -> None:
    fd, name = tempfile.mkstemp(prefix=".sloth-migration-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(payload); stream.flush(); os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        Path(name).unlink(missing_ok=True)


def require_sloth_quit() -> None:
    result = subprocess.run(["/usr/bin/pgrep", "-x", "Sloth"], capture_output=True)
    if result.returncode == 0:
        raise ValueError("Quit Sloth before applying the migration so its autosave cannot race the merge")
    if result.returncode != 1:
        raise RuntimeError("Could not verify that Sloth is quit; process inspection failed")


def apply_migration(staging: Path, destination: Path, check_running: bool = True) -> dict:
    manifest, imported = load_stage(staging)
    source = Path(manifest["sourceDirectory"])
    destination = destination.absolute()
    if inside(destination, source) or inside(source, destination):
        raise ValueError("The destination cannot be inside or contain Bear's data directory")
    if inside(destination, staging) or inside(staging, destination):
        raise ValueError("The destination must be separate from the staging directory")
    expected_source = json.loads(read_regular(staging / "source-fingerprints.json"))
    if fingerprints(source) != expected_source:
        raise ValueError("Bear changed since this snapshot. Stage a fresh migration before applying")
    if check_running:
        require_sloth_quit()
    destination.mkdir(parents=True, exist_ok=True, mode=0o700)
    if destination.is_symlink() or (destination / "attachments").is_symlink():
        raise ValueError("Destination paths must not be symbolic links")
    storage = destination / "notes.json"
    before = read_regular(storage) if storage.exists() else None
    existing = json.loads(before) if before else []
    if not isinstance(existing, list) or len({n["id"].upper() for n in existing}) != len(existing):
        raise ValueError("Sloth's existing notes are invalid or contain duplicate IDs")
    ledger_path = destination / "bear-import-ledger.json"
    ledger = json.loads(read_regular(ledger_path)) if ledger_path.exists() else {"version": 1, "imports": {}}
    by_id = {n["id"].upper(): n for n in existing}
    added, skipped, conflicts = [], 0, 0
    for record, note in zip(manifest["notes"], imported):
        if record["slothID"] != note["id"] or digest(json_bytes(note)) != record["importedSHA256"]:
            raise ValueError("Staged note metadata does not match its content")
        ledger_key = record["sourceKey"] + ":" + record["importedSHA256"]
        previous_id = ledger["imports"].get(ledger_key)
        if previous_id and previous_id.upper() in by_id:
            skipped += 1; continue  # Keep any subsequent edits made in Sloth.
        candidate = dict(note)
        if candidate["id"].upper() in by_id:
            if by_id[candidate["id"].upper()] == candidate:
                skipped += 1
                ledger["imports"][ledger_key] = candidate["id"]
                continue
            candidate["id"] = stable_id(record["sourceKey"] + ":copy:" + record["importedSHA256"])
            conflicts += 1
            if candidate["id"] in by_id:
                # Already imported copy; preserve any edits to it as well.
                skipped += 1; ledger["imports"][ledger_key] = candidate["id"]; continue
        added.append(candidate); by_id[candidate["id"]] = candidate
        ledger["imports"][ledger_key] = candidate["id"]
    attachment_root = destination / "attachments"
    for relative, info in manifest["assets"].items():
        target = destination / relative
        if target.exists() and digest(read_regular(target)) != info["sha256"]:
            raise ValueError("A Sloth attachment has conflicting bytes; nothing was replaced")
    if check_running:
        require_sloth_quit()
    if (read_regular(storage) if storage.exists() else None) != before:
        raise ValueError("Sloth's notes changed during preflight; nothing was imported")
    backup = destination / ("migration-backup-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:8])
    backup.mkdir(mode=0o700)
    for name in ("notes.json", "notes.backup.json", "bear-import-ledger.json"):
        path = destination / name
        if path.exists():
            (backup / name).write_bytes(read_regular(path))
    # Existing assets are immutable and never replaced. An interrupted merge can
    # leave extra unused files, but cannot leave published notes missing assets.
    attachment_root.mkdir(exist_ok=True, mode=0o700)
    for relative in manifest["assets"]:
        target = destination / relative
        if not target.exists():
            atomic_write(target, read_regular(staging / relative))
    if (read_regular(storage) if storage.exists() else None) != before:
        raise ValueError("Sloth's notes changed during file copy; imported notes were not published")
    if fingerprints(source) != expected_source:
        raise ValueError("Bear changed during migration. Notes were not published; stage a fresh migration")
    merged = existing + added
    if added or before is None:
        atomic_write(storage, json_bytes(merged))
    atomic_write(ledger_path, json_bytes(ledger))
    if json.loads(read_regular(storage)) != merged:
        raise RuntimeError("Post-import note verification failed; backup is retained")
    if json.loads(read_regular(storage))[:len(existing)] != existing:
        raise RuntimeError("Pre-existing Sloth notes failed preservation verification")
    for relative, info in manifest["assets"].items():
        if digest(read_regular(destination / relative)) != info["sha256"]:
            raise RuntimeError("Post-import attachment verification failed")
    result = {"added": len(added), "skipped": skipped, "conflictCopies": conflicts,
              "existingPreserved": len(existing), "total": len(merged), "verifiedAttachments": len(manifest["assets"]),
              "backupDirectory": str(backup), "destination": str(destination)}
    atomic_write(backup / "receipt.json", json_bytes(result))
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    stage = commands.add_parser("stage", help="Read Bear and build a verified private migration folder")
    stage.add_argument("--source", type=Path, default=BEAR_DEFAULT)
    stage.add_argument("--staging", type=Path, required=True)
    apply = commands.add_parser("apply", help="Append staged notes to Sloth; requires Sloth to be quit")
    apply.add_argument("--staging", type=Path, required=True)
    apply.add_argument("--destination", type=Path, default=SLOTH_DEFAULT)
    verify = commands.add_parser("verify", help="Check staged bytes and report whether Bear is unchanged")
    verify.add_argument("--staging", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == "stage":
            manifest = stage_migration(args.source, args.staging)
            print(json.dumps({k: manifest[k] for k in ("counts", "sourceAttachmentRecords", "uniqueAttachments", "attachmentBytes", "sourceUnchanged", "problems")}, indent=2))
            return 1 if manifest["problems"] else 0
        if args.command == "apply":
            print(json.dumps(apply_migration(args.staging, args.destination), indent=2))
        else:
            manifest, notes = load_stage(args.staging)
            source_unchanged = fingerprints(Path(manifest["sourceDirectory"])) == json.loads(read_regular(args.staging / "source-fingerprints.json"))
            print(json.dumps({"stagedNotesVerified": len(notes), "attachmentsVerified": len(manifest["assets"]), "sourceUnchanged": source_unchanged}, indent=2))
            return 0 if source_unchanged else 1
        return 0
    except (OSError, ValueError, sqlite3.Error, RuntimeError, KeyError) as error:
        print(f"Migration stopped: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

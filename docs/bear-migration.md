# Copying Bear into Sloth

`scripts/migrate-bear.py` copies a local Bear library into Sloth. Bear is never
opened for writing. The script reads its database, WAL, and attachment files with
read-only file handles, checks that they stayed unchanged, and opens only the
private SQLite copy. All note states are retained: active, archived, and trashed.
The original Markdown is preserved except for attachment destinations, which are
rewritten to Sloth-owned immutable files. Tags remain in the original Markdown;
creation/modification dates and pin/archive/trash flags are preserved. Source
fractional timestamps and source IDs remain in the private migration manifest.
Sloth's existing JSON format stores timestamps to the nearest lower second.

The staging folder contains private documents and a full copied source database.
Keep it in `.build/` (gitignored); do not commit or publish it. The tool creates
that folder with permissions restricted to its owner.

## Stage and inspect

```sh
python3 scripts/migrate-bear.py stage --staging .build/bear-migration-YYYYMMDD
python3 scripts/migrate-bear.py verify --staging .build/bear-migration-YYYYMMDD
```

The default source is Bear's local group container under `~/Library/Group
Containers/9K33E3U3T4.net.shinyfrog.bear/Application Data`. `--source` can select
another copy. Staging refuses to reuse a directory. It stops migration for
unreadable/encrypted notes, missing attachments, ambiguous attachment names, or
tag metadata that cannot be preserved from the text. It never asks Bear to
download, decrypt, export, or change settings.

Source IDs are not assumed unique: some Bear onboarding records have duplicate
IDs. Every source record gets a deterministic Sloth UUID using its source ID and
primary key, so all documents survive. Duplicated attachment records that point
to the same bytes share one immutable copied file. Existing wiki links and
external URLs are preserved.

## Apply after quitting Sloth

```sh
python3 scripts/migrate-bear.py apply --staging .build/bear-migration-YYYYMMDD
python3 scripts/migrate-bear.py verify --staging .build/bear-migration-YYYYMMDD
```

The default destination is `~/Library/Application Support/Sloth`; `--destination`
selects an isolated test library. The tool requires successful process inspection
showing that Sloth is quit. It also verifies that Bear still matches the snapshot
and that Sloth's notes have not changed during the merge. If Bear has changed,
create a fresh stage.

Apply backs up the existing Sloth notes and import ledger in a timestamped
`migration-backup-*` directory. It verifies and copies attachments first, then
atomically publishes the combined notes. Existing Sloth records are kept intact.
An ID collision creates an additional deterministic copy instead of replacing a
note. A ledger makes reruns idempotent, including after later Sloth edits. If a
Bear record subsequently changes, a future migration preserves the previous
Sloth record and imports the newer source as a separate copy.

The command checks all imported attachment hashes and verifies all existing notes
after writing. Its receipt reports document/file counts and the backup location.
Any interrupted copy can leave unused files, but notes are not published before
their attachment payloads are present. No source content is printed.

## Validation

```sh
python3 -m unittest discover -s Tests -p test_bear_migration.py -v
```

Synthetic tests cover committed WAL data, duplicate source IDs, active/archive/
trash states, Unicode, dates, tags, exact attachment bytes, escaped Markdown,
code exclusions, source fingerprint preservation, existing-note backups,
idempotence after local edits, ID/file collisions, staging tamper detection,
encrypted/missing payloads, source changes, symlinks, and process-check errors.

The staged library on 2026-10-15 contains 118 notes (36 active, 50 archived,
32 trashed), 28 attachment records sharing 23 files (4,075,122 bytes), and no
encrypted/locked/missing documents. A private dry-run merged all 118 with the
existing 8 Sloth notes, verified 126 total, and added zero documents on a repeat.
Bear's source hashes and modification timestamps remained unchanged.

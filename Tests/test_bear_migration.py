#!/usr/bin/env python3
"""Migration safety/integrity tests using synthetic Bear and Sloth libraries."""
import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("bear_migration", Path(__file__).parents[1] / "scripts/migrate-bear.py")
migration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(migration)


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="sloth-migration-test-")
        self.root = Path(self.temporary.name)
        self.source = self.root / "Bear"
        self.source.mkdir()
        self.staging = self.root / "staged"
        self.destination = self.root / "Sloth"
        self.db = sqlite3.connect(self.source / "database.sqlite")
        self.db.executescript("""
            CREATE TABLE ZSFNOTE (Z_PK INTEGER PRIMARY KEY, ZUNIQUEIDENTIFIER TEXT, ZTEXT TEXT,
                ZCREATIONDATE REAL, ZMODIFICATIONDATE REAL, ZPINNED INTEGER DEFAULT 0,
                ZARCHIVED INTEGER DEFAULT 0, ZTRASHED INTEGER DEFAULT 0,
                ZENCRYPTED INTEGER DEFAULT 0, ZLOCKED INTEGER DEFAULT 0, ZPERMANENTLYDELETED INTEGER DEFAULT 0);
            CREATE TABLE ZSFNOTEFILE (Z_PK INTEGER PRIMARY KEY, ZUNIQUEIDENTIFIER TEXT,
                ZFILENAME TEXT, ZNOTE INTEGER, ZENCRYPTED INTEGER DEFAULT 0);
            CREATE TABLE ZSFNOTETAG (Z_PK INTEGER PRIMARY KEY, ZTITLE TEXT);
            CREATE TABLE Z_5TAGS (Z_5NOTES INTEGER, Z_13TAGS INTEGER);
        """)
        self.original_text = '# Unicode বাংলা 👋\n\n![File \\[one\\]](<image one.png>)\n#work/ideas\n\n`![example](image one.png)`\n[Web](https://example.com/image%20one.png)\n'
        self.db.execute("INSERT INTO ZSFNOTE(Z_PK,ZUNIQUEIDENTIFIER,ZTEXT,ZCREATIONDATE,ZMODIFICATIONDATE,ZPINNED) VALUES(1,'duplicate',?,0,1234,1)", (self.original_text,))
        self.db.execute("INSERT INTO ZSFNOTE(Z_PK,ZUNIQUEIDENTIFIER,ZTEXT,ZCREATIONDATE,ZMODIFICATIONDATE,ZARCHIVED) VALUES(2,'duplicate','Archived',50,4567,1)")
        self.db.execute("INSERT INTO ZSFNOTE(Z_PK,ZUNIQUEIDENTIFIER,ZTEXT,ZCREATIONDATE,ZMODIFICATIONDATE,ZTRASHED) VALUES(3,'third','Trashed',60,4568,1)")
        self.db.execute("INSERT INTO ZSFNOTEFILE VALUES(1,'file-id','image one.png',1,0)")
        self.db.execute("INSERT INTO ZSFNOTETAG VALUES(1,'work/ideas')")
        self.db.execute("INSERT INTO Z_5TAGS VALUES(1,1)")
        self.db.commit()
        file = self.source / "Local Files/Note Images/file-id/image one.png"
        file.parent.mkdir(parents=True)
        self.file_bytes = b"synthetic-original-attachment\x00\xff"
        file.write_bytes(self.file_bytes)

    def tearDown(self):
        self.db.close()
        self.temporary.cleanup()

    def stage(self):
        manifest = migration.stage_migration(self.source, self.staging)
        self.assertEqual(manifest["problems"], [])
        return manifest

    def apply(self):
        return migration.apply_migration(self.staging, self.destination, check_running=False)

    def test_all_states_duplicate_source_ids_dates_tags_and_exact_attachment_bytes(self):
        before = migration.fingerprints(self.source)
        manifest = self.stage()
        notes = json.loads((self.staging / "notes.json").read_text())
        self.assertEqual(manifest["counts"]["total"], 3)
        self.assertEqual([manifest["counts"][x] for x in ("active", "archived", "trashed")], [1, 1, 1])
        self.assertEqual(len({note["id"] for note in notes}), 3)
        self.assertTrue(notes[0]["pinned"])
        self.assertTrue(notes[1]["archived"])
        self.assertTrue(notes[2]["trashed"])
        self.assertEqual(notes[0]["createdAt"], "2001-01-01T00:00:00Z")
        self.assertEqual(notes[0]["modifiedAt"], "2001-01-01T00:20:34Z")
        target = next(iter(manifest["assets"]))
        self.assertEqual((self.staging / target).read_bytes(), self.file_bytes)
        self.assertEqual(notes[0]["text"], self.original_text.replace("(<image one.png>)", f"(<{target}>)"))
        self.assertEqual(manifest["notes"][0]["tags"], ["work/ideas"])
        self.assertEqual(migration.fingerprints(self.source), before)
        self.assertTrue(manifest["sourceUnchanged"])

    def test_wal_committed_notes_are_in_snapshot_without_source_sqlite_access(self):
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("INSERT INTO ZSFNOTE(Z_PK,ZUNIQUEIDENTIFIER,ZTEXT,ZCREATIONDATE,ZMODIFICATIONDATE) VALUES(4,'wal','Committed only in WAL',0,1)")
        self.db.commit()
        self.assertTrue((self.source / "database.sqlite-wal").exists())
        before = migration.fingerprints(self.source)
        manifest = self.stage()
        self.assertEqual(manifest["counts"]["total"], 4)
        self.assertEqual(migration.fingerprints(self.source), before)

    def test_apply_preserves_existing_notes_and_backup_then_is_idempotent_after_local_edit(self):
        manifest = self.stage()
        self.destination.mkdir()
        existing = {"id": "AA8BC5B1-5361-4EB3-8076-BF16AF567AC1", "text": "Already in Sloth",
                    "createdAt": "2026-10-01T10:00:00Z", "modifiedAt": "2026-10-01T10:00:00Z",
                    "pinned": False, "archived": False, "trashed": False}
        original = migration.json_bytes([existing])
        (self.destination / "notes.json").write_bytes(original)
        result = self.apply()
        self.assertEqual((result["added"], result["existingPreserved"], result["total"]), (3, 1, 4))
        self.assertEqual((Path(result["backupDirectory"]) / "notes.json").read_bytes(), original)
        notes = json.loads((self.destination / "notes.json").read_text())
        self.assertEqual(notes[0], existing)
        notes[1]["text"] = "Edited in Sloth after migration"
        (self.destination / "notes.json").write_bytes(migration.json_bytes(notes))
        result2 = self.apply()
        self.assertEqual((result2["added"], result2["skipped"], result2["total"]), (0, 3, 4))
        self.assertEqual(json.loads((self.destination / "notes.json").read_text()), notes)
        for target in manifest["assets"]:
            self.assertEqual((self.destination / target).read_bytes(), self.file_bytes)

    def test_conflicting_sloth_id_gets_copy_without_overwrite(self):
        self.stage()
        staged = json.loads((self.staging / "notes.json").read_text())
        original = dict(staged[0], text="Existing conflicting note")
        self.destination.mkdir()
        (self.destination / "notes.json").write_bytes(migration.json_bytes([original]))
        result = self.apply()
        self.assertEqual((result["added"], result["conflictCopies"]), (3, 1))
        notes = json.loads((self.destination / "notes.json").read_text())
        self.assertEqual(notes[0], original)
        self.assertEqual(len({note["id"] for note in notes}), 4)
        self.assertEqual(notes[1]["text"], staged[0]["text"])
        self.assertEqual(self.apply()["added"], 0)

    def test_attachment_collision_refuses_before_notes_changed(self):
        manifest = self.stage()
        (self.destination / "attachments").mkdir(parents=True)
        target = next(iter(manifest["assets"]))
        (self.destination / target).write_bytes(b"different existing file")
        with self.assertRaisesRegex(ValueError, "conflicting bytes"):
            self.apply()
        self.assertFalse((self.destination / "notes.json").exists())
        self.assertEqual((self.destination / target).read_bytes(), b"different existing file")

    def test_tampered_staged_notes_or_assets_refused(self):
        manifest = self.stage()
        path = self.staging / "notes.json"
        original = path.read_bytes()
        path.write_bytes(b"[]")
        with self.assertRaisesRegex(ValueError, "Staged notes"):
            self.apply()
        path.write_bytes(original)
        (self.staging / next(iter(manifest["assets"]))).write_bytes(b"tampered")
        with self.assertRaisesRegex(ValueError, "Staged attachment"):
            self.apply()
        self.assertFalse(self.destination.exists())

    def test_encrypted_and_missing_files_block_apply(self):
        self.db.execute("UPDATE ZSFNOTE SET ZENCRYPTED=1 WHERE Z_PK=2")
        self.db.commit()
        (self.source / "Local Files/Note Images/file-id/image one.png").unlink()
        manifest = migration.stage_migration(self.source, self.staging)
        self.assertEqual(manifest["counts"]["encrypted"], 1)
        self.assertEqual(len(manifest["problems"]), 2)
        with self.assertRaisesRegex(ValueError, "unresolved"):
            self.apply()

    def test_source_destination_overlap_and_symlink_refused(self):
        with self.assertRaisesRegex(ValueError, "separate"):
            migration.stage_migration(self.source, self.source / "bad-stage")
        self.stage()
        with self.assertRaisesRegex(ValueError, "Bear's data"):
            migration.apply_migration(self.staging, self.source, check_running=False)
        self.destination.symlink_to(self.source, target_is_directory=True)
        with self.assertRaises(ValueError):
            self.apply()

    def test_source_change_after_staging_blocks_before_destination_writes(self):
        self.stage()
        self.db.execute("UPDATE ZSFNOTE SET ZTEXT='New Bear edit' WHERE Z_PK=2")
        self.db.commit()
        with self.assertRaisesRegex(ValueError, "fresh migration"):
            self.apply()
        self.assertFalse(self.destination.exists())

    def test_process_inspection_must_succeed(self):
        for code, error in ((0, ValueError), (2, RuntimeError), (-9, RuntimeError)):
            with self.subTest(returncode=code), patch.object(migration.subprocess, "run") as run:
                run.return_value.returncode = code
                with self.assertRaises(error):
                    migration.require_sloth_quit()
        with patch.object(migration.subprocess, "run") as run:
            run.return_value.returncode = 1
            migration.require_sloth_quit()

    def test_rewrite_handles_escaped_labels_titles_nested_paths_and_code(self):
        text = '[a \\[b\\]](photo%20(one).png "title")\n![x](photo%20(one).png)\n`![x](photo%20(one).png)`\n```\n![x](photo%20(one).png)\n```\n\\![x](photo%20(one).png)'
        rewritten, counts = migration.rewrite_attachments(text, {"photo (one).png": "attachments/new.png"})
        self.assertEqual(counts["photo (one).png"], 2)
        self.assertIn('(attachments/new.png "title")', rewritten)
        self.assertIn('`![x](photo%20(one).png)`', rewritten)
        self.assertIn('\\![x](photo%20(one).png)', rewritten)


if __name__ == "__main__":
    unittest.main()

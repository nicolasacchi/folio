#!/usr/bin/env python3
"""Build a test cc.db with private remote Library rows.

This is an experiment tool, not the final runtime path. Kindle's catalog DB uses
an ICU collation extension that the stock sqlite3 shell cannot write without the
Kindle catalog process. For controlled tests we register a simple host collation
so SQLite can update a copy, then deploy that copy with a full backup.
"""

from __future__ import annotations

import argparse
import csv
import json
import shutil
import sqlite3
import uuid
from pathlib import Path


PREFIX = "SELFHOST:"


def read_manifest(path: Path) -> list[dict[str, str]]:
    if path.suffix == ".json":
        payload = json.loads(path.read_text(encoding="utf-8"))
        return [
            {
                "id": str(item["id"]),
                "title": str(item["title"]),
                "author": str(item.get("author", "")),
                "size": str(item.get("size", "0")),
                "mime": str(item.get("mime", "application/octet-stream")),
                "filename": str(item.get("filename", "")),
            }
            for item in payload["items"]
        ]

    with path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        return [
            {
                "id": row["id"],
                "title": row["title"],
                "author": row.get("author", ""),
                "size": row.get("size", "0"),
                "mime": row.get("mime", "application/octet-stream"),
                "filename": row.get("filename", ""),
            }
            for row in reader
        ]


def icu_fallback(left: object, right: object) -> int:
    a = "" if left is None else str(left).casefold()
    b = "" if right is None else str(right).casefold()
    return (a > b) - (a < b)


def table_columns(conn: sqlite3.Connection) -> list[str]:
    return [row[1] for row in conn.execute("pragma table_info(Entries)")]


def find_template(conn: sqlite3.Connection) -> sqlite3.Row:
    row = conn.execute(
        """
        select * from Entries
        where p_isArchived = 1
          and p_isVisibleInHome = 1
          and p_cdeKey is not null
          and p_titles_0_nominal is not null
        order by p_purchaseDate desc
        limit 1
        """
    ).fetchone()
    if row is None:
        raise SystemExit("No archived visible template row found in cc.db")
    return row


def title_json(title: str) -> str:
    return json.dumps([{"display": title, "pronunciation": "", "collation": title}], ensure_ascii=False)


def credits_json(author: str) -> str:
    if not author:
        return "[]"
    return json.dumps(
        [{"name": {"display": author, "pronunciation": "", "collation": author}, "role": "author"}],
        ensure_ascii=False,
    )


def searchable_words(item: dict[str, str]) -> str:
    parts = [item["title"], item.get("author", ""), item["id"], item.get("filename", "")]
    return " ".join(part for part in parts if part).lower()


def private_cde_key(item_id: str) -> str:
    safe = "".join(ch for ch in item_id.upper() if ch.isalnum())
    return "SELFHOST" + safe[:24]


def private_uuid(item_id: str) -> str:
    return PREFIX + str(uuid.uuid5(uuid.NAMESPACE_URL, "kindle-privatecloud:" + item_id))


def build_row(columns: list[str], template: sqlite3.Row, item: dict[str, str]) -> dict[str, object]:
    row = {column: template[column] for column in columns}
    title = item["title"]
    author = item.get("author", "")
    cde_key = private_cde_key(item["id"])

    row.update(
        {
            "p_uuid": private_uuid(item["id"]),
            "p_type": "Entry:Item",
            "p_location": None,
            "p_lastAccess": None,
            "p_modificationTime": None,
            "p_isArchived": 1,
            "p_titles_0_nominal": title,
            "p_titles_0_collation": title,
            "p_titles_0_pronunciation": title,
            "j_titles": title_json(title),
            "p_titleCount": 1,
            "p_credits_0_name_collation": author,
            "j_credits": credits_json(author),
            "p_creditCount": 1 if author else 0,
            "j_collections": "[]",
            "p_collectionCount": 0,
            "j_members": "[]",
            "p_memberCount": 0,
            "p_lastAccessedPosition": None,
            "p_expirationDate": None,
            "p_publisher": "",
            "p_isDRMProtected": 0,
            "p_isVisibleInHome": 1,
            "p_isLatestItem": 1,
            "p_isDownloading": 0,
            "p_isUpdateAvailable": 0,
            "p_virtualCollectionCount": 0,
            "p_languages_0": "en",
            "j_languages": '["en"]',
            "p_languageCount": 1,
            "p_mimeType": item.get("mime") or "application/x-mobipocket-ebook",
            "p_cover": None,
            "p_thumbnail": None,
            "p_diskUsage": 0,
            "p_cdeGroup": cde_key,
            "p_cdeKey": cde_key,
            "p_cdeType": "PDOC",
            "p_version": "1",
            "p_guid": item["id"],
            "j_displayObjects": "[]",
            "j_displayTags": "[]",
            "j_excludedTransports": "[]",
            "p_isMultimediaEnabled": 0,
            "p_watermark": None,
            "p_contentSize": int(item.get("size") or 0),
            "p_percentFinished": 0,
            "p_isTestData": 0,
            "p_contentIndexedState": 2,
            "p_metadataIndexedState": 2,
            "p_noteIndexedState": 0,
            "p_credits_0_name_pronunciation": author,
            "p_metadataStemWords": searchable_words(item),
            "p_metadataStemLanguage": "en",
            "p_ownershipType": "Purchase",
            "p_shareType": None,
            "p_contentState": "Archived",
            "p_metadataUnicodeWords": searchable_words(item),
            "p_homeMemberCount": 0,
            "j_collectionsSyncAttributes": "[]",
            "p_collectionSyncCounter": 0,
            "p_collectionDataSetName": None,
            "p_originType": "PrivateCloud",
            "p_pvcId": None,
            "p_companionCdeKey": None,
            "p_seriesState": None,
            "p_totalContentSize": 0,
            "p_visibilityState": 0,
            "p_isProcessed": 1,
            "p_readState": 0,
            "p_subType": 0,
            "p_lastOpenTime": None,
            "p_conversionStatus": None,
        }
    )
    return row


def privatecloud_downloaded_filenames(conn: sqlite3.Connection) -> set[str]:
    rows = conn.execute(
        """
        select p_location from Entries
        where p_location like '/mnt/us/documents/PrivateCloud/%'
        """
    ).fetchall()
    return {Path(str(row[0])).name for row in rows if row[0]}


def import_rows(db_path: Path, manifest_path: Path, output_path: Path, include_downloaded: bool) -> None:
    shutil.copy2(db_path, output_path)
    items = read_manifest(manifest_path)

    conn = sqlite3.connect(output_path)
    conn.row_factory = sqlite3.Row
    conn.create_collation("icu", icu_fallback)
    columns = table_columns(conn)
    template = find_template(conn)
    downloaded = set() if include_downloaded else privatecloud_downloaded_filenames(conn)

    placeholders = ", ".join("?" for _ in columns)
    column_sql = ", ".join(columns)
    insert_sql = f"insert into Entries ({column_sql}) values ({placeholders})"

    with conn:
        conn.execute("delete from Entries where p_uuid like ?", (PREFIX + "%",))
        conn.execute("delete from Entries where p_cdeKey like 'SELFHOST%'")
        for item in items:
            if item.get("filename") in downloaded:
                continue
            row = build_row(columns, template, item)
            conn.execute(insert_sql, [row.get(column) for column in columns])

    count = conn.execute("select count(*) from Entries where p_uuid like ?", (PREFIX + "%",)).fetchone()[0]
    conn.close()
    print(f"Wrote {count} private remote rows to {output_path}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Build a cc.db copy with private archived rows.")
    parser.add_argument("--db", required=True, type=Path, help="Source cc.db")
    parser.add_argument("--manifest", required=True, type=Path, help="manifest.tsv or manifest.json")
    parser.add_argument("--output", required=True, type=Path, help="Output cc.db copy")
    parser.add_argument(
        "--include-downloaded",
        action="store_true",
        help="Also import manifest rows that already exist under /mnt/us/documents/PrivateCloud",
    )
    args = parser.parse_args()
    import_rows(args.db, args.manifest, args.output, args.include_downloaded)


if __name__ == "__main__":
    main()

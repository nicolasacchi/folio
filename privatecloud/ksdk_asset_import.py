#!/usr/bin/env python3
"""Build a test ksdk.asset.db with private Library asset nodes."""

from __future__ import annotations

import argparse
import json
import shutil
import sqlite3
import time
from pathlib import Path

from catalog_import import icu_fallback, private_cde_key, read_manifest


def table_columns(conn: sqlite3.Connection) -> list[str]:
    return [row[1] for row in conn.execute("pragma table_info(Nodes)")]


def privatecloud_downloaded_filenames(cc_db: Path) -> set[str]:
    conn = sqlite3.connect(cc_db)
    try:
        rows = conn.execute(
            """
            select p_location from Entries
            where p_location like '/mnt/us/documents/PrivateCloud/%'
            """
        ).fetchall()
    finally:
        conn.close()
    return {Path(str(row[0])).name for row in rows if row[0]}


def additional_data(title: str) -> str:
    return json.dumps(
        {
            "title": title,
            "current_reading_page": 1,
            "total_page": 1,
            "children_count": 0,
            "thumbnail_location": "",
            "notebook_template": "",
            "standalone_thumbnail_preference": "",
            "delete_state": 0,
            "incompatible_software_version": "",
            "hide_recovered_badge": False,
            "notebook_incomplete": False,
            "notebook_health_state": "",
            "notebook_metadata_health_state": "",
        },
        separators=(",", ":"),
        ensure_ascii=False,
    )


def build_row(columns: list[str], item: dict[str, str]) -> dict[str, object]:
    title = item["title"]
    author = item.get("author", "")
    cde_key = private_cde_key(item["id"])
    now = int(time.time())
    return {
        column: None
        for column in columns
    } | {
        "ASSET_ID": cde_key + "!!PDOC",
        "TYPE": "DOCUMENT",
        "ASIN": cde_key,
        "TITLE": title,
        "TITLE_COLLATION": title,
        "PARENT_ASSET_ID": None,
        "PARENT_ASSET_VALUE_ID": "",
        "PARENT_VERSION": "",
        "GENRE_RANK": 0,
        "SYNC_STATE": "SYNCED",
        "PARENT_TYPE": "UNKNOWN",
        "TOTAL_POSITION": None,
        "ADDITIONAL_DATA": additional_data(title),
        "RECAP_ENABLED": 0,
        "ORIGIN": "Unknown",
        "DOWNLOAD_STATE": "Unknown",
        "ARCHIVE": 0,
        "LOCATION": "",
        "MIMETYPE": "",
        "SIDELOAD": 0,
        "AUTHORS": author,
        "AUTHORS_COLLATION": author,
        "PUBLISHER": "",
        "PUBLICATION_DATE": None,
        "THUMBNAIL": "",
        "MODIFICATION_DATE": now,
        "GUID": item["id"],
        "CREATION_DATE": now,
        "ENCRYPT": 0,
        "LAST_ACCESS_TIME": now,
        "PARENT_HASH": "",
        "SYSTEM_HIDDEN": 0,
        "LAST_OPEN_TIME": 0,
        "INDEX_STATE": None,
        "SEARCH_METADATA": " ".join([title, author, item["id"], item.get("filename", "")]).lower(),
        "VISIBILITY_WITH_GROUPING": 0,
        "READ_STATE": None,
        "SUB_TYPE": None,
    }


def import_rows(db_path: Path, cc_db: Path, manifest_path: Path, output_path: Path, include_downloaded: bool) -> None:
    shutil.copy2(db_path, output_path)
    items = read_manifest(manifest_path)
    downloaded = set() if include_downloaded else privatecloud_downloaded_filenames(cc_db)

    conn = sqlite3.connect(output_path)
    conn.create_collation("icu", icu_fallback)
    columns = table_columns(conn)
    placeholders = ", ".join("?" for _ in columns)
    column_sql = ", ".join(columns)
    insert_sql = f"insert into Nodes ({column_sql}) values ({placeholders})"

    with conn:
        conn.execute("delete from Nodes where ASSET_ID like 'SELFHOST%' or ASIN like 'SELFHOST%'")
        for item in items:
            if item.get("filename") in downloaded:
                continue
            row = build_row(columns, item)
            conn.execute(insert_sql, [row.get(column) for column in columns])

    count = conn.execute("select count(*) from Nodes where ASSET_ID like 'SELFHOST%'").fetchone()[0]
    conn.close()
    print(f"Wrote {count} private KSDK asset rows to {output_path}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Build a ksdk.asset.db copy with private asset rows.")
    parser.add_argument("--db", required=True, type=Path, help="Source ksdk.asset.db")
    parser.add_argument("--cc-db", required=True, type=Path, help="Source cc.db used to skip downloaded files")
    parser.add_argument("--manifest", required=True, type=Path, help="manifest.tsv or manifest.json")
    parser.add_argument("--output", required=True, type=Path, help="Output ksdk.asset.db copy")
    parser.add_argument("--include-downloaded", action="store_true")
    args = parser.parse_args()
    import_rows(args.db, args.cc_db, args.manifest, args.output, args.include_downloaded)


if __name__ == "__main__":
    main()

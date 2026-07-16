#!/usr/bin/env python3
"""Migrate ebook piles into Folio single-root taxonomy via hardlinks.

Layout:  DEST/<category>[/<sub>]/Author>/<Title>.<ext>
Companion: docs/library-taxonomy.yml

Usage:
  python3 migrate_library_tree.py --phase 1          # main Calibre + book/
  python3 migrate_library_tree.py --phase 2          # nik_book Calibre (dedupe)
  python3 migrate_library_tree.py --phase 1 --dry-run
"""
from __future__ import annotations

import argparse
import hashlib
import os
import re
import shutil
import sqlite3
import sys
import unicodedata
from collections import Counter, defaultdict
from pathlib import Path

FORMATS = {".epub", ".mobi", ".azw3", ".azw", ".pdf", ".prc", ".txt", ".fb2", ".cbz", ".cbr", ".djvu", ".kfx"}
SKIP_NAMES = {"cover.jpg", "metadata.opf", "metadata.db", ".DS_Store"}

# --- author → category (normalized key: lower, alnum words sorted for match) ---
AUTHOR_CAT: dict[str, str] = {}


def _add_authors(cat: str, *names: str) -> None:
    for n in names:
        AUTHOR_CAT[norm_author_key(n)] = cat


def norm_author_key(name: str) -> str:
    s = unicodedata.normalize("NFKD", name)
    s = "".join(c for c in s if not unicodedata.combining(c))
    s = s.lower().replace("'", " ")
    # "Last, First" → words
    s = s.replace(",", " ")
    words = re.findall(r"[a-z0-9]+", s)
    return " ".join(sorted(words))


def display_author(name: str) -> str:
    """Prefer 'First Last'; flip 'Last, First' when single comma."""
    name = (name or "").strip()
    if not name or name.lower() in {"unknown", "aa.vv.", "aa. vv.", "autori vari", "an", "."}:
        return "Unknown"
    if name.count(",") == 1 and " and " not in name.lower():
        last, first = [p.strip() for p in name.split(",", 1)]
        if first and last and not any(x in first for x in ("|", ";")):
            # avoid flipping multi-author "A, B"
            if " " not in last or len(last.split()) <= 2:
                if re.match(r"^[A-ZÀ-Ö]", first) or re.match(r"^[a-z]", first):
                    # Harari Yuval Noah style already First-ish if no comma
                    if len(first.split()) >= 1 and len(last.split()) <= 3:
                        # "Last, First Middle" → "First Middle Last"
                        return sanitize(f"{first} {last}", is_author=True)
    # known inverted without comma
    flips = {
        "murakami haruki": "Haruki Murakami",
        "harari yuval noah": "Yuval Noah Harari",
        "green john": "John Green",
        "nhat hahn thich": "Thich Nhat Hanh",
        "pessoa fernando": "Fernando Pessoa",
    }
    k = name.lower().strip()
    if k in flips:
        return flips[k]
    return sanitize(name, is_author=True)


def sanitize(s: str, is_author: bool = False) -> str:
    s = unicodedata.normalize("NFC", s).strip()
    s = re.sub(r'[/\\:*?"<>|]', "—", s)
    s = re.sub(r"\s+", " ", s).strip(" .")
    if not s:
        return "Unknown" if is_author else "Untitled"
    return s[:180]


def stem_title(title: str) -> str:
    t = sanitize(title)
    t = re.sub(r"\s*\(\d+\)\s*$", "", t)  # calibre id
    return t[:160] or "Untitled"


# Fiction
_add_authors(
    "fiction/literary",
    "José Saramago", "Jose Saramago", "Stefano Benni", "Fernando Pessoa", "Pessoa Fernando",
    "Margaret Atwood", "Cormac McCarthy", "Michel Houellebecq", "Umberto Eco",
    "Alessandro Baricco", "Italo Calvino", "Jorge Luis Borges", "Luis Sepúlveda", "Luis Sepulveda",
    "Alan Bennett", "John Banville", "Nick Hornby", "Jonathan Coe", "Truman Capote",
    "Francesco Muzzopappa", "Raduan Nassar", "Billy-Ray Belcourt", "Chuck Palahniuk",
    "Ismail Kadare", "Ala Al-Aswani", "'Ala Al-Aswani", "Alejandro Jodorowsky",
    "Hermann Hesse", "Voltaire", "Jack London", "Mario Rigoni Stern",
    "Andrea Camilleri",  # also crime; literary/crime → crime preferred below
    "George Orwell", "Virginia Woolf", "Jane Austen", "Charles Dickens",
    "Elena Ferrante", "Jhumpa Lahiri", "Kazuo Ishiguro", "Haruki Murakami", "Murakami Haruki",
    "Neil Gaiman", "John Green", "Green John", "Ernest Cline",
    "Lily Brooks-Dalton", "Amal El-Mohtar", "Max Gladstone",
)
_add_authors(
    "fiction/sf",
    "Isaac Asimov", "Philip K. Dick", "Stanislaw Lem", "Douglas Adams", "Ray Bradbury",
    "Arthur C. Clarke", "Michael Crichton", "William Gibson", "H.G. Wells", "H. G. Wells",
    "Kurt Vonnegut", "Jeff VanderMeer", "Valerio Evangelisti", "Hugh Howey",
    "Neal Shusterman", "Ursula K. Le Guin", "Frank Herbert", "Iain M. Banks",
    "Kim Stanley Robinson", "Andy Weir", "Terry Pratchett", "Stephen M. Baxter",
)
_add_authors(
    "fiction/crime",
    "Agatha Christie", "Stieg Larsson", "Irene Adler", "Andrea Camilleri",
    "Georges Simenon", "Anne Holt", "Harlan Coben", "Stephen King",
    "John Elder Robison",  # not crime - remove
)
# fix mistaken
AUTHOR_CAT.pop(norm_author_key("John Elder Robison"), None)

_add_authors(
    "fiction/crime",
    "Edgar Wallace", "Boris Akunin", "Ellery Queen", "S. S. Van Dine",
)
_add_authors(
    "fiction/fantasy",
    "J.R.R. Tolkien", "John R. R. Tolkien", "Roger Zelazny", "Leigh Bardugo",
    "Patrick Rothfuss", "George R. R. Martin",
)
_add_authors(
    "fiction/kids_ya",
    "Enid Blyton", "Geronimo Stilton", "Gianni Rodari", "Astrid Lindgren",
    "Bianca Pitzorno", "Pierdomenico Baccalario", "Davide Morosinotto",
    "Anna Vivarelli", "Roald Dahl", "Maurice Sendak", "Julia Donaldson",
    "Suzanne Collins", "Alexandra Bracken", "Katherine Rundell",
    "Clete Barret Smith", "Lauren Wolk", "Lissa Evans", "Laura Marx Fitzgerald",
    "Anna Cerasoli", "Roberto Piumini", "David Walliams", "Ingo Siegner",
)

# Nonfiction
_add_authors(
    "nonfiction/science",
    "Anton Zeilinger", "Peter Wohlleben", "Jim Al-Khalili", "Johnjoe McFadden",
    "Adam Rutherford", "Jared Diamond", "Rachel Carson", "Telmo Pievani",
    "Stefano Mancuso", "Mark W. Moffett", "Temple Grandin",
    "Eirik Newth", "Hugh Aldersey-Williams", "Tim Flannery",
)
_add_authors(
    "nonfiction/history",
    "Yuval Noah Harari", "Harari Yuval Noah", "Indro Montanelli", "Mario Cervi",
    "Jacques Le Goff", "Alessandro Barbero", "John Foot", "Peter Frankopan",
    "Carlo Bitossi", "Samuel P. Huntington", "Julian Assange",
    "Noam Chomsky", "Yanis Varoufakis", "Glenn Greenwald",
    "Sergio del Molino", "Ernst H. Gombrich", "Alfio Caruso",
    "Bruce Bueno de Mesquita", "Franklin Foer",
)
_add_authors(
    "nonfiction/psych_society",
    "Daniel Kahneman", "Daniel Goleman", "Paolo Crepet", "Carl Gustav Jung",
    "Giorgio Nardone", "Nassim Nicholas Taleb", "Richard H. Thaler",
    "Brian Weiss", "Luigi Zoja", "Alberto Pellai", "Alberto Siracusano",
    "John Elder Robison", "Bernard Beitman", "Daniel Bergner",
    "Maura Gancitano", "Seth Godin", "Adam Kahane",
)
_add_authors(
    "nonfiction/tech_ai",
    "Mustafa Suleyman", "MICHAEL BHASKAR", "Michael Bhaskar",
    "Henry A. Kissinger", "Eric Schmidt", "Daniel Huttenlocher",
    "Stefano Quintarelli", "Evgeny Morozov", "Ray Kurzweil",
    "Luis G. Serrano", "Sebastian Raschka", "Dmitry Zinoviev",
    "Josh Chin", "Liza Lin", "Paolo Iabichino",
)
_add_authors(
    "nonfiction/philosophy",
    "Osho", "Thich Nhat Hanh", "Nhat Hahn Thich", "Alain de Botton",
    "Anthony De Mello", "James G. Frazer", "Oswald Wirth",
    "Sekkei Harada", "Dario Canil",
)

# Practical
_add_authors(
    "practical/parenting",
    "Adele Faber", "Elaine Mazlish", "ISABELLA UNGARO", "MARIO ROSSI BRUNORI",
    "Barbara Tamborini",
)
_add_authors(
    "practical/health",
    "Jessie Inchauspé", "Jessie Inchauspe", "Kazuhiro Nakagawa",
    "Vittorio Caprioglio", "Rupa Marya", "Raj Patel",
)
_add_authors(
    "practical/travel",
    "Lonely Planet", "Albano Marcarini",
)
_add_authors(
    "practical/tech_manuals",
    "Noel Rappin", "David Chelimsky", "Bonaventura Di Bello",
    "Giampaolo Lorusso",
)
_add_authors(
    "classics/world",
    "Jules Verne", "Edgar Allan Poe", "Howard Phillips Lovecraft",
    "Sir Arthur Conan Doyle", "Arthur Conan Doyle", "Emilio Salgari",
    "Dante Alighieri", "Virgilio", "Giovanni Boccaccio", "Carlo Goldoni",
    "Alexandre Dumas", "Victor Hugo", "Honoré de Balzac", "Honore de Balzac",
    "Stendhal", "Émile Zola", "Emile Zola", "Guy de Maupassant",
    "Lev Nikolaevic Tolstoj", "Leo Tolstoy",
)

TITLE_RULES: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"rough\s*guide|phrasebook|lonely\s*planet|guida\s+(di|a)\s", re.I), "practical/travel"),
    (re.compile(r"\b(O'?Reilly|Apress|Pragmatic|Addison.?Wesley|Manning|Packt)\b", re.I), "practical/tech_manuals"),
    (re.compile(r"machine\s*learning|deep\s*learning|python|rails|ruby|elixir|javascript|kubernetes|docker|sql\b", re.I), "practical/tech_manuals"),
    (re.compile(r"\b(bimby|ricett|cucina|cookbook|chef)\b", re.I), "practical/craft"),
    (re.compile(r"\b(montessori|homeschool|unschool|genitori|educazion|figli)\b", re.I), "practical/parenting"),
    (re.compile(r"\b(sapiens|homo\s*deus|21\s*lezioni|nexus)\b", re.I), "nonfiction/history"),
    (re.compile(r"\b(urania|fondazione|foundation|dune|neuromante|cyberpunk)\b", re.I), "fiction/sf"),
    (re.compile(r"\b(poirot|montalbano|maigret|sherlock|giallo)\b", re.I), "fiction/crime"),
    (re.compile(r"\b(geronimo|banda dei cinque|favole al telefono|pinocchio)\b", re.I), "fiction/kids_ya"),
]

SERIES_CAT = {
    "urania": "fiction/sf",
    "classiciurania": "fiction/sf",
    "le grandi storie della fantascienza": "fiction/sf",
    "il commissario maigret": "fiction/crime",
    "hercule poirot": "fiction/crime",
    "montalbano": "fiction/crime",
    "miss marple": "fiction/crime",
    "millennium": "fiction/crime",
    "sandokan": "classics/world",
    "la banda dei cinque": "fiction/kids_ya",
}


def classify(author: str, title: str, series: str | None = None) -> str:
    if series:
        sk = re.sub(r"[^a-z0-9]+", " ", series.lower()).strip()
        sk = re.sub(r"\s+", " ", sk)
        for key, cat in SERIES_CAT.items():
            if key in sk:
                return cat
    # multi-author: try each part
    for part in re.split(r"\s*\|\s*|\s*;\s*|,\s*(?=[A-Z])", author or ""):
        k = norm_author_key(part)
        if k in AUTHOR_CAT:
            return AUTHOR_CAT[k]
    k = norm_author_key(author or "")
    if k in AUTHOR_CAT:
        return AUTHOR_CAT[k]
    blob = f"{title} {author}"
    for pat, cat in TITLE_RULES:
        if pat.search(blob):
            return cat
    return "_inbox"


def file_sha256(path: Path, limit: int | None = None) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        if limit:
            h.update(f.read(limit))
        else:
            for chunk in iter(lambda: f.read(1024 * 1024), b""):
                h.update(chunk)
    return h.hexdigest()


def link_or_copy(src: Path, dst: Path, dry_run: bool) -> str:
    if dry_run:
        return "dry-run"
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.exists():
        try:
            if dst.samefile(src):
                return "exists-same"
        except OSError:
            pass
        # different file same name — disambiguate
        stem, suf = dst.stem, dst.suffix
        n = 2
        while dst.exists():
            dst = dst.with_name(f"{stem} ({n}){suf}")
            n += 1
    try:
        os.link(src, dst)
        return "hardlink"
    except OSError:
        shutil.copy2(src, dst)
        return "copy"


def unique_dest(dest_dir: Path, title: str, ext: str, used: set[str]) -> Path:
    base = stem_title(title)
    name = f"{base}{ext}"
    key = name.lower()
    n = 2
    while key in used or (dest_dir / name).exists():
        name = f"{base} ({n}){ext}"
        key = name.lower()
        n += 1
    used.add(key)
    return dest_dir / name


def load_calibre_books(calibre_root: Path) -> list[dict]:
    db = calibre_root / "metadata.db"
    books: list[dict] = []
    if db.is_file():
        conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            """
            SELECT b.id, b.title, b.path, b.series_index,
                   (SELECT group_concat(a.name, ' & ')
                    FROM books_authors_link l JOIN authors a ON a.id=l.author
                    WHERE l.book=b.id) AS author,
                   (SELECT s.name FROM books_series_link sl
                    JOIN series s ON s.id=sl.series WHERE sl.book=b.id) AS series
            FROM books b
            """
        ).fetchall()
        for r in rows:
            # path is relative Author/Title (id)
            folder = calibre_root / r["path"]
            if not folder.is_dir():
                continue
            formats = [
                p for p in folder.iterdir()
                if p.is_file() and p.suffix.lower() in FORMATS
            ]
            if not formats:
                continue
            books.append(
                {
                    "title": r["title"],
                    "author": r["author"] or "Unknown",
                    "series": r["series"],
                    "files": formats,
                    "source": str(folder),
                }
            )
        conn.close()
        return books

    # no db: walk Author/Title folders
    for author_dir in sorted(calibre_root.iterdir()):
        if not author_dir.is_dir() or author_dir.name.startswith("."):
            continue
        for title_dir in author_dir.iterdir():
            if not title_dir.is_dir():
                continue
            formats = [
                p for p in title_dir.iterdir()
                if p.is_file() and p.suffix.lower() in FORMATS
            ]
            if not formats:
                continue
            title = re.sub(r"\s*\(\d+\)\s*$", "", title_dir.name)
            books.append(
                {
                    "title": title,
                    "author": author_dir.name,
                    "series": None,
                    "files": formats,
                    "source": str(title_dir),
                }
            )
    return books


def load_loose_tree(root: Path) -> list[dict]:
    """Loose files and nested dirs under book/, etc."""
    books: list[dict] = []
    if not root.exists():
        return books
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        files = [
            Path(dirpath) / f
            for f in filenames
            if Path(f).suffix.lower() in FORMATS and f not in SKIP_NAMES
        ]
        if not files:
            continue
        # group by stem
        by_stem: dict[str, list[Path]] = defaultdict(list)
        for f in files:
            by_stem[f.stem].append(f)
        for stem, paths in by_stem.items():
            title, author = split_stem(stem)
            # Anna's Archive pattern: Title -- Author -- year -- ...
            if " -- " in stem:
                parts = [p.strip() for p in stem.split(" -- ")]
                if len(parts) >= 2:
                    title = parts[0]
                    author = parts[1] if parts[1].lower() != "null" else author
            books.append(
                {
                    "title": title or stem,
                    "author": author or "Unknown",
                    "series": None,
                    "files": paths,
                    "source": str(paths[0].parent),
                }
            )
    return books


def split_stem(stem: str) -> tuple[str, str | None]:
    for sep in (" -- ", " - "):
        if sep in stem:
            a, b = stem.split(sep, 1)
            return a.strip(), b.strip() or None
    return stem, None


def migrate_books(
    items: list[dict],
    dest_root: Path,
    seen_sha: set[str],
    dry_run: bool,
    stats: Counter,
) -> None:
    # track used filenames per author dest dir
    used_in_dir: dict[Path, set[str]] = defaultdict(set)

    for item in items:
        author_disp = display_author(item["author"])
        # primary author for multi: first segment
        primary = item["author"].split("&")[0].split("|")[0].strip()
        author_disp = display_author(primary) if primary else author_disp
        title = item["title"]
        cat = classify(item["author"], title, item.get("series"))
        cat_parts = cat.split("/")
        dest_dir = dest_root.joinpath(*cat_parts, author_disp)
        stats["books_seen"] += 1
        stats[f"cat:{cat}"] += 1

        # prefer epub > azw3 > mobi > pdf when ordering links
        ordered = sorted(
            item["files"],
            key=lambda p: (
                [".epub", ".azw3", ".mobi", ".azw", ".pdf"].index(p.suffix.lower())
                if p.suffix.lower() in {".epub", ".azw3", ".mobi", ".azw", ".pdf"}
                else 99
            ),
        )
        format_hashes: dict[Path, str] = {}
        for f in ordered:
            try:
                format_hashes[f] = file_sha256(f)
            except OSError as e:
                stats["read_errors"] += 1
                print(f"ERR read {f}: {e}", file=sys.stderr)
        if not format_hashes:
            continue
        if all(h in seen_sha for h in format_hashes.values()):
            stats["deduped_works"] += 1
            continue

        linked_any = False
        for f, h in format_hashes.items():
            if h in seen_sha:
                stats["deduped_files"] += 1
                continue
            seen_sha.add(h)
            dest = unique_dest(dest_dir, title, f.suffix.lower(), used_in_dir[dest_dir])
            action = link_or_copy(f, dest, dry_run)
            stats[action] += 1
            stats["files"] += 1
            linked_any = True
        if linked_any:
            stats["books_linked"] += 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dest", type=Path, default=Path("/home/nik/komga/library/books"))
    ap.add_argument("--phase", type=int, choices=[1, 2, 3], required=True)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--sha-cache", type=Path, default=Path("/home/nik/komga/library/books/.migrate_sha256.txt"))
    args = ap.parse_args()

    dest: Path = args.dest
    seen_sha: set[str] = set()
    if args.sha_cache.is_file() and args.phase > 1:
        seen_sha = set(args.sha_cache.read_text().splitlines())
        print(f"loaded {len(seen_sha)} hashes from cache")

    stats: Counter = Counter()
    items: list[dict] = []

    if args.phase == 1:
        main_cal = Path("/home/nik/komga/library/Calibre Library")
        book_dir = Path("/home/nik/komga/library/book")
        loose_root = Path("/home/nik/komga/library/Nocedicocco E Il Grande Mago -- Ingo Siegner.pdf")
        print("loading main Calibre…")
        items.extend(load_calibre_books(main_cal))
        print(f"  calibre books: {len(items)}")
        loose = load_loose_tree(book_dir)
        print(f"  book/ loose: {len(loose)}")
        items.extend(loose)
        if loose_root.is_file():
            items.append(
                {
                    "title": "Nocedicocco E Il Grande Mago",
                    "author": "Ingo Siegner",
                    "series": None,
                    "files": [loose_root],
                    "source": str(loose_root.parent),
                }
            )
    elif args.phase == 2:
        nik_cal = Path("/home/nik/komga/library/nik_book/Calibre Library")
        print("loading nik_book Calibre…")
        items = load_calibre_books(nik_cal)
        print(f"  books: {len(items)}")
    elif args.phase == 3:
        print("Phase 3 (dumps) not automated — place wanted files under books/_inbox manually.")
        return 0

    print(f"migrating {len(items)} works → {dest} dry_run={args.dry_run}")
    if not args.dry_run:
        dest.mkdir(parents=True, exist_ok=True)
        (dest / "_inbox").mkdir(exist_ok=True)
        (dest / "_quarantine").mkdir(exist_ok=True)

    migrate_books(items, dest, seen_sha, args.dry_run, stats)

    if not args.dry_run:
        args.sha_cache.parent.mkdir(parents=True, exist_ok=True)
        args.sha_cache.write_text("\n".join(sorted(seen_sha)) + "\n")
        print(f"wrote sha cache ({len(seen_sha)}) → {args.sha_cache}")

    print("\n=== stats ===")
    for k, v in sorted(stats.items(), key=lambda kv: (-kv[1], kv[0])):
        print(f"{v:6d}  {k}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

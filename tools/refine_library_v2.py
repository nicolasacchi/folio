#!/usr/bin/env python3
"""Further refine books/ tree: expand genre maps, merge author dupes, parse Unknown."""
from __future__ import annotations

import os
import re
import unicodedata
from collections import Counter, defaultdict
from pathlib import Path

# Library root to refine. Override with the LIBRARY_BOOKS env var.
BASE = Path(os.environ.get("LIBRARY_BOOKS", Path.home() / "library" / "books"))

# genre for authors still sitting in general (and anywhere)
EXTRA: dict[str, str] = {}


def nk(name: str) -> str:
    s = unicodedata.normalize("NFKD", name or "")
    s = "".join(c for c in s if not unicodedata.combining(c)).lower()
    s = s.replace("'", " ").replace("_", " ").replace(".", " ").replace(";", " ")
    words = re.findall(r"[a-z0-9]+", s.split(";")[0])
    return " ".join(sorted(words))


def san(s: str) -> str:
    s = unicodedata.normalize("NFC", (s or "").strip())
    s = re.sub(r'[/\\:*?"<>|]', "—", s)
    s = re.sub(r"\s+", " ", s).strip(" .")
    return s[:180] or "Unknown"


def put(cat: str, *names: str) -> None:
    for n in names:
        EXTRA[nk(n)] = cat
        toks = re.findall(r"[A-Za-zÀ-ÿ']+", n)
        if len(toks) == 2:
            EXTRA[nk(f"{toks[1]} {toks[0]}")] = cat


# Italian contemporary literary
put("fiction/literary",
    "Dino Buzzati", "Buzzati", "Vitaliano Brancati", "Brancati",
    "Chiara Gamberale", "Gamberale", "Francesco Falconi", "Falconi",
    "Pino Cacucci", "Cacucci", "Francesco Guccini", "Guccini",
    "Alessandro Perissinotto", "Perissinotto", "Alessia Gazzola", "Gazzola",
    "Giorgio Faletti", "Faletti", "Diego De Silva", "De Silva Diego",
    "Francesco Muzzopappa", "Muzzopappa", "Beppe Severgnini", "Severgnini",
    "Arto Paasilinna", "Paasilinna", "Almudena Grandes", "Grandes",
    "Arturo Pérez-Reverte", "Perez-Reverte", "Arturo Perez-Reverte",
    "Carlos Ruiz Zafón", "Carlos Ruiz Zafon", "Zafon", "Zafón",
    "David Grossman", "Grossman", "Chaim Potok", "Potok",
    "Roddy Doyle", "Doyle Roddy", "Anthony Burgess", "Burgess",
    "Yasunari Kawabata", "Kawabata", "Ala Al-Aswani", "'Ala Al-Aswani",
    "Albert Camus", "Camus",  # also philosophy - literary for novels
    "Arthur Schnitzler", "Schnitzler", "Friedrich Dürrenmatt", "Durrenmatt",
    "Dürrenmatt", "Emilio Praga", "Praga", "Carlo Dossi", "Dossi",
    "Angelo Poliziano", "Poliziano", "Carlo Fruttero", "Fruttero",
    "Franco Lucentini", "Lucentini", "Fruttero e Lucentini",
    "Eraldo Baldini", "Baldini Eraldo", "Cinzia Tani", "Tani",
    "Bruno Morchio", "Morchio", "Ben Pastor", "Pastor Ben",
    "Alessandro Girola", "Girola", "Alec Valschi", "Valschi",
    "Claudio Paganelli", "Paganelli", "Emilia Valli", "Valli Emilia",
    "Brenno", "Cristina Contilli", "Contilli", "Franco Mecucci", "Mecucci",
    "Fabio Delizzos", "Delizzos", "Fabiana Redivo", "Redivo",
    "Federica Bosco", "Bosco Federica", "Emiliano Bertocchi", "Bertocchi",
    "Giobbe Covatta", "Covatta", "Romano Battaglia", "Battaglia",
    "Ayrin Greenflag", "Greenflag", "Abel Wakaam", "Wakaam",
    "Christopher Moore", "Moore Christopher", "Katie Fforde", "Fforde Katie",
    "Nicholas Evans", "Evans Nicholas", "Robert Macfarlane", "Macfarlane",  # nature - science
)

put("nonfiction/science", "Robert Macfarlane", "Macfarlane")
put("nonfiction/history",
    "Enzo Biagi", "Biagi", "Claudio Rendina", "Rendina",
    "Federico Rampini", "Rampini", "Eric Frattini", "Frattini",
    "Galileo Galilei", "Galilei",  # science history
)
put("nonfiction/science", "Galileo Galilei", "Galilei")
put("nonfiction/psych_society", "Zygmunt Bauman", "Bauman")
put("nonfiction/philosophy", "Albert Camus", "Camus")  # essays - but novels literary; last wins - philosophy overwrites literary for Camus
# Prefer literary for Camus novels - re-put literary
put("fiction/literary", "Albert Camus", "Camus")

put("fiction/crime",
    "Deon Meyer", "Meyer Deon", "Andrew Vachss", "Vachss",
    "Brian Freeman", "Freeman Brian", "Elizabeth Ferrars", "Ferrars",
    "Alexander McCall Smith", "McCall Smith", "Carl Hiaasen", "Hiaasen",
    "Alex Kava", "Kava", "Brigitte Aubert", "Aubert",
    "Donald E. Westlake", "Westlake", "Craig Rice", "Rice Craig",
    "Francis Durbridge", "Durbridge", "G. M. Ford", "Ford GM",
    "Cody McFadyen", "McFadyen", "Sebastian Fitzek", "Fitzek",
    "Alessia Gazzola",  # often crime/medical - keep literary? Gazzola is medical mystery - crime
)
put("fiction/crime", "Alessia Gazzola", "Gazzola")

put("fiction/thriller",
    "Eric Van Lustbader", "Lustbader", "Don Pendleton", "Pendleton",
    "Glenn Cooper", "Cooper Glenn", "Frank Schätzing", "Schatzing", "Schätzing",
    "Catherine Coulter", "Coulter", "Desmond Bagley", "Bagley",
    "David Ambrose", "Ambrose",
)

put("fiction/romance",
    "Anne Stuart", "Stuart Anne", "Anne Mather", "Mather Anne",
    "Anne Herries", "Herries", "Anne Golon", "Golon",  # Angélique historical romance
    "Debbie Macomber", "Macomber", "Elizabeth Hoyt", "Hoyt",
    "Emma Holly", "Holly Emma", "Jeaniene Frost", "Frost Jeaniene",
    "Indigo Bloome", "Bloome", "Colleen Gleason", "Gleason",
    "Deryn Lake", "Lake Deryn", "Katie Fforde", "Fforde",
    "Federica Bosco", "Bosco",  # chick lit
)

put("fiction/historical",
    "Diana Gabaldon", "Gabaldon", "Anne Golon", "Golon",
    "Gary Jennings", "Jennings", "Angélique",
)

put("fiction/horror",
    "Frank De Felitta", "De Felitta", "Frank Belknap Long", "Belknap Long",
    "Eraldo Baldini",  # often horror/noir italian
)

put("fiction/sf",
    "Brian Stableford", "Stableford", "Chad Oliver", "Oliver Chad",
    "Eleanor Arnason", "Arnason", "Edgar Pangborn", "Pangborn",
    "Colin Kapp", "Kapp", "Piers Anthony", "ANTHONY PIERS", "Anthony Piers",
    "Frank Schätzing", "Schatzing",  # also thriller eco - sf
    "Edgar Rice Burroughs", "Burroughs",  # also adventure/fantasy
)

put("fiction/fantasy",
    "Barbara Hambly", "Hambly", "Ed Greenwood", "Greenwood",
    "Christopher Paolini", "Paolini", "Garth Nix", "Nix",
    "Ann Marston", "Marston", "Piers Anthony", "Anthony Piers",
    "Edgar Rice Burroughs", "Burroughs", "Clive S. Lewis", "C.S. Lewis",
)

put("fiction/kids_ya",
    "Cornelia Funke", "Funke", "Christopher Paolini", "Paolini",  # YA fantasy
    "Garth Nix", "Nix",
)

put("fiction/adventure",
    "Edgar Rice Burroughs", "Burroughs", "Desmond Bagley", "Bagley",
)

put("classics/world",
    "Arthur Schnitzler", "Schnitzler", "Marquis de Sade", "De Sade",
    "Donatien Alphonse Francois Marchese De Sade", "Sade",
    "Pietro Aretino", "Aretino", "Angelo Poliziano", "Poliziano",
    "Carlo Dossi", "Dossi", "Emilio Praga", "Praga",
    "Galileo Galilei",  # no - nonfiction
)
put("classics/italian",
    "Pietro Aretino", "Aretino", "Angelo Poliziano", "Poliziano",
    "Carlo Dossi", "Dossi", "Emilio Praga", "Praga", "Vitaliano Brancati", "Brancati",
    "Dino Buzzati", "Buzzati",  # modern classic IT - literary better
)
put("fiction/literary", "Dino Buzzati", "Buzzati", "Vitaliano Brancati", "Brancati")

put("fiction/erotica",  # not in taxonomy - use romance
    "Emma Holly", "Indigo Bloome", "Marquis de Sade", "Sade", "Pietro Aretino",
)
# map erotica authors to romance or literary
put("fiction/romance", "Emma Holly", "Indigo Bloome", "Jeaniene Frost")
put("classics/world", "Marquis de Sade", "De Sade", "Donatien Alphonse Francois Marchese De Sade")
put("classics/italian", "Pietro Aretino", "Aretino")

# Known works in Unknown
KNOWN = [
    (re.compile(r"giardino dei finzi|finzi.?contini", re.I), "Giorgio Bassani", "fiction/literary"),
    (re.compile(r"lista di schindler|schindler", re.I), "Thomas Keneally", "fiction/literary"),
    (re.compile(r"certi bambini", re.I), "Diego De Silva", "fiction/literary"),
    (re.compile(r"imbarazzismi", re.I), "Michele Serra", "fiction/literary"),
    (re.compile(r"rigoberta manch", re.I), "Elizabeth Burgos", "nonfiction/biography"),
    (re.compile(r"sotterranei del majestic|majestic", re.I), "Georges Simenon", "fiction/crime"),
    (re.compile(r"camera d.ambra|amber room", re.I), "Steve Berry", "fiction/thriller"),
    (re.compile(r"lupo mannaro|werewolf", re.I), "Unknown", "fiction/horror"),
    (re.compile(r"underworld|under.?world", re.I), "Greg Cox", "fiction/sf"),
    (re.compile(r"adolescente\b", re.I), "Fedor Dostoevskij", "classics/world"),
    (re.compile(r"non ora.? non qui", re.I), "Erri De Luca", "fiction/literary"),
    (re.compile(r"gabbrielli|jeev", re.I), "P.G. Wodehouse", "fiction/literary"),
    (re.compile(r"american pulp", re.I), "Various", "fiction/crime"),
    (re.compile(r"libri da ardere|fahrenheit", re.I), "Ray Bradbury", "fiction/sf"),
    (re.compile(r"scacchiera sterminata", re.I), "Unknown", "fiction/general"),
    (re.compile(r"morte al piano", re.I), "J. L. Rickard", "fiction/crime"),
    (re.compile(r"freebook", re.I), None, None),  # handled by parse
]

TITLE_RULES = [
    (re.compile(r"\b(giallo|detective|commissario|omicidio|indagine|mistery|mystery)\b", re.I), "fiction/crime"),
    (re.compile(r"\b(thriller|cospiraz|spia\b|agente)\b", re.I), "fiction/thriller"),
    (re.compile(r"\b(vampiri|horror|fantasma|ghost|lupo mannaro)\b", re.I), "fiction/horror"),
    (re.compile(r"\b(fantascienza|urania|galattico|spazio|robot|android)\b", re.I), "fiction/sf"),
    (re.compile(r"\b(fantasy|drago|magia|stregon)\b", re.I), "fiction/fantasy"),
    (re.compile(r"\b(sposa|duca|sceicco|amore|romance|rosa)\b", re.I), "fiction/romance"),
    (re.compile(r"\b(romanzo storico|medioevo|egitto|impero|nazismo|guerra mondiale)\b", re.I), "fiction/historical"),
    (re.compile(r"\b(biografia|autobiografia|memorie)\b", re.I), "nonfiction/biography"),
    (re.compile(r"\b(storia|politica|geopolitic)\b", re.I), "nonfiction/history"),
    (re.compile(r"\b(filosofia|stoic)\b", re.I), "nonfiction/philosophy"),
    (re.compile(r"\b(manuale|programmazione|python|algoritm|calcolator)\b", re.I), "practical/tech_manuals"),
    (re.compile(r"\b(ragazzi|geronimo|favole)\b", re.I), "fiction/kids_ya"),
    (re.compile(r"\b(poesie|poesia)\b", re.I), "fiction/poetry"),
]

GARBAGE_FOLDERS = {
    "microsoft word", "asus", "_ebook", "ebook", "alessandro", "1994",
    "administrator", "documento1", "test", "null", "none",
}

FIRST = {
    "john", "james", "robert", "michael", "william", "david", "richard", "charles",
    "daniel", "paul", "mark", "george", "thomas", "christopher", "stephen", "andrew",
    "anthony", "brian", "kevin", "edward", "ronald", "donald", "steven", "kenneth",
    "mary", "patricia", "jennifer", "linda", "elizabeth", "barbara", "susan", "jessica",
    "anne", "ann", "jane", "kate", "alice", "emma", "sarah", "laura", "michelle",
    "andrea", "marco", "luca", "paolo", "giovanni", "francesco", "alessandro", "mario",
    "luigi", "giuseppe", "roberto", "stefano", "carlo", "enrico", "davide", "matteo",
    "chiara", "giulia", "francesca", "elena", "silvia", "paola", "monica", "valentina",
    "jean", "pierre", "marie", "hans", "klaus", "erik", "paulo", "carlos", "miguel",
    "jose", "juan", "luis", "pedro", "tom", "tim", "jim", "bob", "joe", "mike",
    "alan", "neil", "ian", "hugh", "philip", "martin", "bernard", "alfred", "arthur",
    "edgar", "oscar", "victor", "ernest", "dean", "clive", "julian", "agatha",
    "haruki", "gabriel", "jorge", "isabel", "michel", "albert", "franz", "italo",
    "umberto", "primo", "dario", "fabio", "erri", "dacia", "cesare", "alberto",
    "antonio", "pietro", "ken", "dan", "lee", "jack", "ray", "frank", "margaret",
    "cormac", "elena", "banana", "fernando", "stefano", "mauro", "luciano", "nick",
    "pino", "dino", "vitaliano", "chiara", "giorgio", "diego", "beppe", "arto",
    "almudena", "arturo", "carlos", "david", "chaim", "roddy", "anthony", "yasunari",
    "arthur", "friedrich", "emilio", "angelo", "eraldo", "cinzia", "bruno", "ben",
    "alec", "claudio", "emilia", "cristina", "franco", "fabiana", "federica",
    "emiliano", "giobbe", "romano", "ayrin", "abel", "christopher", "katie",
    "nicholas", "robert", "enzo", "federico", "eric", "galileo", "zygmunt",
    "deon", "andrew", "brian", "alexander", "carl", "alex", "brigitte", "donald",
    "craig", "francis", "cody", "sebastian", "eric", "don", "glenn", "frank",
    "catherine", "desmond", "anne", "debbie", "elizabeth", "emma", "jeaniene",
    "indigo", "colleen", "deryn", "diana", "gary", "barbara", "ed", "garth",
    "ann", "piers", "edgar", "clive", "cornelia", "eleanor", "chad", "colin",
}


def flip_display(name: str) -> str:
    name = name.split(";")[0].strip()
    toks = re.findall(r"[A-Za-zÀ-ÿ']+", name)
    if len(toks) == 2:
        a, b = toks[0], toks[1]
        if b.lower() in FIRST and a.lower() not in FIRST:
            return san(f"{b} {a}")
    return san(name)


def lookup(name: str) -> str | None:
    k = nk(name)
    if k in EXTRA:
        return EXTRA[k]
    toks = re.findall(r"[A-Za-zÀ-ÿ']+", name)
    if len(toks) == 2:
        k2 = nk(f"{toks[1]} {toks[0]}")
        if k2 in EXTRA:
            return EXTRA[k2]
    return None


def parse_stem(stem: str) -> tuple[str | None, str]:
    stem = re.sub(r"\s*\(\d+\)\s*$", "", stem).strip()
    stem = re.sub(r"\s*\[.*?\]\s*", " ", stem)
    m = re.match(
        r"^(?P<a>.+?)\s+-\s+(?P<t>.+?)(?:\s+-\s+freebook.*)?$",
        stem, re.I,
    )
    if m:
        a, t = m.group("a").strip(), m.group("t").strip()
        if 2 < len(a) < 60 and not a.isdigit():
            return a, t
    return None, stem


def unique(dest_dir: Path, name: str) -> Path:
    dest = dest_dir / name
    if not dest.exists():
        return dest
    stem, suf = Path(name).stem, Path(name).suffix
    n = 2
    while dest.exists():
        dest = dest_dir / f"{stem} ({n}){suf}"
        n += 1
    return dest


def move_to(src: Path, cat: str, author: str, stats: Counter) -> None:
    dest_dir = BASE.joinpath(*cat.split("/"), author)
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = unique(dest_dir, src.name)
    if src.resolve() == dest.resolve():
        stats["same"] += 1
        return
    try:
        src.rename(dest)
        stats["moved"] += 1
        stats[f"→{cat}"] += 1
    except OSError:
        try:
            os.link(src, dest)
            src.unlink()
            stats["moved"] += 1
            stats[f"→{cat}"] += 1
        except OSError:
            stats["err"] += 1


def merge_author_dupes(stats: Counter) -> None:
    """Merge Last First / First Last folders under same category."""
    # map: (cat_path, sorted_name_key) -> list of dirs
    groups: dict[tuple[str, str], list[Path]] = defaultdict(list)
    for cat_dir in BASE.iterdir():
        if not cat_dir.is_dir() or cat_dir.name.startswith("_"):
            continue
        for sub in cat_dir.iterdir():
            if not sub.is_dir():
                continue
            cat = f"{cat_dir.name}/{sub.name}"
            for author_dir in sub.iterdir():
                if not author_dir.is_dir():
                    continue
                key = nk(author_dir.name)
                if not key or len(key) < 3:
                    continue
                groups[(cat, key)].append(author_dir)

    for (cat, key), dirs in groups.items():
        if len(dirs) < 2:
            continue
        # prefer First Last display (more spaces as First Last if second is first name)
        def score(d: Path) -> tuple:
            name = d.name
            toks = re.findall(r"[A-Za-zÀ-ÿ']+", name)
            nfiles = sum(1 for f in d.iterdir() if f.is_file())
            first_last = 1 if len(toks) >= 2 and toks[0].lower() in FIRST else 0
            return (first_last, nfiles, -len(name))

        dirs_sorted = sorted(dirs, key=score, reverse=True)
        primary = dirs_sorted[0]
        for other in dirs_sorted[1:]:
            for f in list(other.iterdir()):
                if not f.is_file():
                    continue
                dest = unique(primary, f.name)
                try:
                    f.rename(dest)
                    stats["merged_files"] += 1
                except OSError:
                    try:
                        os.link(f, dest)
                        f.unlink()
                        stats["merged_files"] += 1
                    except OSError:
                        stats["merge_err"] += 1
            try:
                if not any(other.iterdir()):
                    other.rmdir()
                    stats["merged_dirs"] += 1
            except OSError:
                pass


def main() -> None:
    stats: Counter = Counter()

    # Pass 1: re-shelf by expanded maps + title rules
    files = [p for p in BASE.rglob("*") if p.is_file() and not p.name.startswith(".") and p.name != "README.txt"]
    print(f"pass1: {len(files)} files")
    for src in files:
        rel = src.relative_to(BASE).parts
        if rel[0].startswith("_") or len(rel) < 3:
            continue
        cur = f"{rel[0]}/{rel[1]}"
        folder = rel[-2]
        stem = src.stem

        # skip garbage device folders content into Unknown later
        cat = None
        author = flip_display(folder)

        if nk(folder) in {nk(g) for g in GARBAGE_FOLDERS} or folder in GARBAGE_FOLDERS:
            parsed, title = parse_stem(stem)
            if parsed:
                cat = lookup(parsed)
                author = flip_display(parsed)
                if not cat:
                    for pat, c in TITLE_RULES:
                        if pat.search(stem):
                            cat = c
                            break
                if not cat:
                    cat = "fiction/general"
                    author = flip_display(parsed)
            else:
                for pat, ka, c in KNOWN:
                    if c and pat.search(stem):
                        cat, author = c, san(ka)
                        break
                if not cat:
                    for pat, c in TITLE_RULES:
                        if pat.search(stem):
                            cat = c
                            author = "Unknown"
                            break
                if not cat:
                    cat = "fiction/general"
                    author = "Unknown"
        else:
            cat = lookup(folder)
            if not cat:
                parsed, _ = parse_stem(stem)
                if parsed:
                    cat = lookup(parsed)
                    if cat:
                        author = flip_display(parsed)
            if not cat:
                for pat, ka, c in KNOWN:
                    if c and pat.search(stem):
                        cat, author = c, san(ka)
                        break
            if not cat:
                for pat, c in TITLE_RULES:
                    if pat.search(stem):
                        cat = c
                        break
            if not cat:
                # Unknown / Various special
                if folder in ("Unknown", "Various", "AA.VV_", "Anonimo", "Anonymous"):
                    parsed, _ = parse_stem(stem)
                    if parsed:
                        cat = lookup(parsed) or "fiction/general"
                        author = flip_display(parsed)
                    else:
                        for pat, ka, c in KNOWN:
                            if c and pat.search(stem):
                                cat, author = c, san(ka)
                                break
                        if not cat:
                            for pat, c in TITLE_RULES:
                                if pat.search(stem):
                                    cat, author = c, "Unknown"
                                    break
                        if not cat:
                            stats["stayed"] += 1
                            continue
                else:
                    stats["stayed"] += 1
                    continue

        if cat == cur and flip_display(folder) == folder:
            stats["already"] += 1
            continue
        if cat == cur and author == folder:
            stats["already"] += 1
            continue

        move_to(src, cat, author, stats)

    print("pass1 done", {k: v for k, v in stats.most_common(25)})

    # Pass 2: merge author duplicates
    stats2: Counter = Counter()
    merge_author_dupes(stats2)
    print("merge", dict(stats2))

    # prune empty
    for d in sorted(BASE.rglob("*"), reverse=True):
        if d.is_dir() and d != BASE:
            try:
                next(d.iterdir())
            except StopIteration:
                try:
                    d.rmdir()
                except OSError:
                    pass

    cats: Counter = Counter()
    total = 0
    for p in BASE.rglob("*"):
        if not p.is_file() or p.name.startswith(".") or p.name == "README.txt":
            continue
        total += 1
        rel = p.relative_to(BASE).parts
        cats["/".join(rel[:2]) if not rel[0].startswith("_") else rel[0]] += 1
    print(f"\n=== FINAL {total} ===")
    for k, v in cats.most_common():
        print(f"{v:6d}  {k}")
    gen = BASE / "fiction/general"
    if gen.exists():
        print("general authors", len([d for d in gen.iterdir() if d.is_dir()]))
        print("Unknown files", sum(1 for f in (gen/"Unknown").iterdir() if f.is_file()) if (gen/"Unknown").exists() else 0)


if __name__ == "__main__":
    main()

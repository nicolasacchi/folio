#!/usr/bin/env python3
"""Drain books/_inbox and salvage _quarantine into taxonomy shelves.

Parses junk author folders (Unknown, Bluebook, ENTERPRIZE, …) via
'Author - Title' filename patterns + large author/surname maps + title rules.
"""
from __future__ import annotations

import re
import shutil
import unicodedata
from collections import Counter
from pathlib import Path

BASE = Path("/path/to/library/books")
INBOX = BASE / "_inbox"
QUAR = BASE / "_quarantine"

# --- helpers ---

def sanitize(s: str) -> str:
    s = unicodedata.normalize("NFC", (s or "").strip())
    s = re.sub(r'[/\\:*?"<>|]', "—", s)
    s = re.sub(r"\s+", " ", s).strip(" .")
    return s[:180] or "Unknown"


def norm_key(name: str) -> str:
    s = unicodedata.normalize("NFKD", name or "")
    s = "".join(c for c in s if not unicodedata.combining(c)).lower()
    s = s.replace("'", " ").replace("_", " ").replace(".", " ")
    words = re.findall(r"[a-z0-9]+", s)
    return " ".join(sorted(words))


def flip_last_first(name: str) -> str:
    """'Connelly Michael' / 'Coelho Paulo' → First Last when 2 tokens."""
    name = sanitize(name)
    if "," in name:
        parts = [p.strip() for p in name.split(",", 1)]
        if len(parts) == 2 and parts[0] and parts[1] and "&" not in name:
            return sanitize(f"{parts[1]} {parts[0]}")
    toks = name.split()
    if len(toks) == 2 and toks[0][0:1].isupper() and toks[1][0:1].isupper():
        # heuristic: if first token looks like surname-only (common inverted)
        # Only flip when second is a common given name OR first is known surname
        return name  # handled by maps with both forms
    return name


# author key → category
CAT: dict[str, str] = {}


def add(cat: str, *names: str) -> None:
    for n in names:
        CAT[norm_key(n)] = cat


# ========== large author maps ==========
add("fiction/sf",
    "Brian W. Aldiss", "Aldiss Brian W", "Aldiss Brian W_", "Ben Bova", "Bruce Sterling",
    "Fredric Brown", "Brunner John", "John Brunner", "Edmond Hamilton", "David Gerrold",
    "Andre Norton", "Damon Knight", "Algis Budrys", "Clark Ashton Smith", "Elizabeth Moon",
    "Charles Eric Maine", "Foster Alan Dean", "Alan Dean Foster", "Poul Anderson",
    "Anderson Poul", "C.J. Cherryh", "Connie Willis", "Robert A. Heinlein", "Heinlein",
    "Ursula K. Le Guin", "Frank Herbert", "Orson Scott Card", "Joe Haldeman",
    "Robert Silverberg", "Harry Harrison", "Jack Vance", "Theodore Sturgeon",
    "Alfred Bester", "Samuel R. Delany", "Octavia E. Butler", "Octavia Butler",
    "Iain M. Banks", "China Miéville", "China Mieville", "Ted Chiang", "Greg Egan",
    "Peter F. Hamilton", "Alastair Reynolds", "Richard Morgan", "Dan Simmons",
    "Hyperion", "Liu Cixin", "Cixin Liu", "Isaac Asimov", "Asimov Isaac", "Asimov",
    "Philip K. Dick", "Dick Philip K", "Stanislaw Lem", "Ray Bradbury", "Arthur C. Clarke",
    "Clarke Arthur C", "Douglas Adams", "William Gibson", "Gibson William",
    "Michael Crichton", "Kurt Vonnegut", "H.G. Wells", "Jules Verne",
    "Robert Sheckley", "Sheckley", "A.E. van Vogt", "Van Vogt", "Alfred E. Van Vogt",
    "Alfed E. Van Vogt", "Barrington J. Bayley", "Barrington J_ Bayley",
    "Frederik Pohl", "Cyril Kornbluth", "Fritz Leiber", "Clifford D. Simak",
    "Bob Shaw", "Fred Saberhagen", "Anne McCaffrey", "David Brin", "Greg Bear",
    "Kim Stanley Robinson", "Neal Stephenson", "Stephenson Neal", "Charles Stross",
    "Ken MacLeod", "Ian McDonald", "Jeff VanderMeer", "Margaret Atwood",  # when dystopian - ok
    "Valerio Evangelisti", "Alan D. Altieri", "Ann Leckie", "Andy Weir",
    "Hugh Howey", "Ernest Cline", "Ready Player One",
    "David G. Hartwell", "James Tiptree", "James Tiptree Jr",
    "Charles Eric Maine", "Eric Frank Russell", "Henry Kuttner", "C.L. Moore",
    "Murray Leinster", "Edmond Hamilton", "Jack Williamson", "E.E. Doc Smith",
    "A.E. van Vogt", "Hal Clement", "James Blish", "Poul Anderson",
    "Gordon R. Dickson", "Keith Laumer", "Christopher Priest",
    "J.G. Ballard", "Ballard J.G", "Philip Jose Farmer", "Farmer Philip Jose",
    "Roger Zelazny", "Zelazny Roger", "Samuel Delany", "Thomas M. Disch",
    "Norman Spinrad", "Harlan Ellison", "Ellison Harlan", "Robert Heinlein",
    "Larry Niven", "Niven Larry", "Jerry Pournelle", "Spider Robinson",
    "C.J. Cherryh", "Cherryh C.J", "Lois McMaster Bujold", "David Weber",
    "John Scalzi", "Scalzi", "Martha Wells", "N.K. Jemisin", "Becky Chambers",
    "Adrian Tchaikovsky", "Peter Watts", "Charles Yu", "Emily St. John Mandel",
    "Arkadij e Boris Strugackij", "Boris Strugatskij", "Strugatsky",
    "Sergei Lukyanenko", "Dmitry Glukhovsky", "Arkady Strugatsky",
    "Gianluigi Zuddas", "Lino Aldani", "Vittorio Catani", "Franco Ricciardiello",
)

add("fiction/fantasy",
    "C.S. Lewis", "CS Lewis", "Clive Barker", "David Gemmell", "David Eddings",
    "Cassandra Clare", "Cate Tiernan", "J.R.R. Tolkien", "Tolkien", "Tolkien J.R.R",
    "Terry Pratchett", "Pratchett", "Neil Gaiman", "Gaiman Neil", "George R.R. Martin",
    "George R. R. Martin", "Patrick Rothfuss", "Brandon Sanderson", "Robert Jordan",
    "Ursula Le Guin", "Michael Moorcock", "Moorcock", "Anne McCaffrey",
    "Marion Zimmer Bradley", "Andre Norton", "Fritz Leiber", "Roger Zelazny",
    "Guy Gavriel Kay", "Joe Abercrombie", "Robin Hobb", "Patrick Rothfuss",
    "Philip Pullman", "Pullman", "J.K. Rowling", "Rowling", "Eoin Colfer", "Colfer Eoin",
    "Rick Riordan", "Suzanne Collins", "Collins Suzanne", "Stephenie Meyer",
    "Charlaine Harris", "Angela Carter", "China Mieville",
    "Christelle Dabos", "Leigh Bardugo", "Sarah J. Maas",
    "Robert E. Howard", "Howard Robert E", "H.P. Lovecraft", "Lovecraft",
    "Howard Phillips Lovecraft", "Clark Ashton Smith",
)

add("fiction/crime",
    "Michael Connelly", "Connelly Michael", "Elmore Leonard", "Carol O'Connell",
    "Tom Clancy", "Clancy Tom", "Dennis Lehane", "Christopher Fowler",
    "Charlotte Link", "Fred Vargas", "David Baldacci", "Baldacci David",
    "Robert Crais", "Crais Robert", "Erica Spindler", "Carlene Thompson",
    "Frederick Forsyth", "Forsyth", "Danila Comastri Montanari",
    "Piero Colaprico", "Colaprico Piero", "Marcello Fois", "Fois Marcello",
    "Derek Raymond", "Andrew Klavan", "Cornell Woolrich", "Candace Robb",
    "Jean Failler", "Failler Jean", "Alfred Hitchcock", "Hitchcock",
    "Agatha Christie", "Christie Agatha", "Georges Simenon", "Simenon",
    "Andrea Camilleri", "Camilleri", "Stieg Larsson", "Larsson",
    "Stephen King", "King Stephen", "Harlan Coben", "Coben",
    "Patricia Cornwell", "Cornwell Patricia", "Jeffery Deaver", "Deaver Jeffery",
    "Elizabeth George", "George Elizabeth", "Ellis Peters", "Peters Ellis",
    "Ed McBain", "McBain", "Clive Cussler", "Cussler Clive", "Cussler",
    "Dean Koontz", "Koontz", "Dean R. Koontz", "Anne Perry", "Perry Anne",
    "Douglas Preston", "Preston Douglas", "Lincoln Child", "Dan Brown", "Brown Dan",
    "Erle Stanley Gardner", "Gardner", "Carlo Lucarelli", "Lucarelli",
    "Alexandra Marinina", "Andy McNab", "McNab", "Robin Cook", "Cook Robin",
    "James Patterson", "Patterson", "John Grisham", "Grisham",
    "Lee Child", "Child Lee", "Jack Reacher", "Ian Rankin", "Rankin",
    "Henning Mankell", "Mankell", "Jo Nesbø", "Jo Nesbo", "Nesbo",
    "Donna Leon", "Leon Donna", "Michael Dibdin", "Dibdin",
    "Manuel Vázquez Montalbán", "Vazquez Montalban",
    "Giorgio Scerbanenco", "Scerbanenco", "Massimo Carlotto", "Carlotto",
    "Giancarlo De Cataldo", "De Cataldo", "Roberto Saviano", "Saviano",
    "Antonio Manzini", "Manzini", "Marco Malvaldi", "Malvaldi",
    "Maurizio de Giovanni", "De Giovanni", "Donato Carrisi", "Carrisi",
    "Gianrico Carofiglio", "Carofiglio", "Andrea Camilleri",
    "Raymond Chandler", "Chandler", "Dashiell Hammett", "Hammett",
    "James Ellroy", "Ellroy", "Walter Mosley", "Mosley",
    "Tana French", "Gillian Flynn", "Flynn Gillian", "Paula Hawkins",
    "Ruth Rendell", "P.D. James", "PD James", "Colin Dexter",
    "Peter Robinson", "Reginald Hill", "Val McDermid", "Ian Rankin",
    "Kathy Reichs", "Reichs", "Tess Gerritsen", "Gerritsen",
    "Michael Connelly", "Robert Galbraith", "J.K. Rowling",  # strike - galbraith only
    "Boris Akunin", "Akunin", "Edgar Wallace", "Wallace Edgar",
    "Arthur Conan Doyle", "Conan Doyle", "Ellery Queen", "S.S. Van Dine",
    "Rex Stout", "Stout Rex", "Ngaio Marsh", "Marsh Ngaio",
    "Mary Higgins Clark", "Higgins Clark", "James Hadley Chase",
    "Mickey Spillane", "Spillane", "John le Carré", "Le Carre", "Le Carré",
    "John le Carre", "Len Deighton", "Deighton", "Robert Ludlum", "Ludlum",
    "Eric Ambler", "Ambler", "Graham Greene",  # sometimes spy
    "Patrick O'Brian", "O'Brian", "Tom Clancy",
    "Michael Di Mercurio", "Di Mercurio",
)

add("fiction/literary",
    "Paulo Coelho", "Coelho Paulo", "Fabio Volo", "Volo Fabio",
    "Luciano De Crescenzo", "De Crescenzo Luciano", "Daniel Pennac", "Pennac",
    "Charles Bukowski", "Bukowski", "Andrea De Carlo", "De Carlo Andrea",
    "Mauro Corona", "Corona Mauro", "Barbara Taylor Bradford", "Bradford Barbara Taylor",
    "Colleen McCullough", "McCullough", "Belva Plain", "Dacia Maraini", "Maraini",
    "Cesare Pavese", "Pavese", "Federigo Tozzi", "Tozzi", "Beppe Fenoglio", "Fenoglio",
    "Alberto Moravia", "Moravia", "Erri De Luca", "De Luca Erri",
    "Banana Yoshimoto", "Yoshimoto", "Andrea Vitali", "Vitali",
    "Alberto Bevilacqua", "Bevilacqua Alberto", "Gabriel Garcia Marquez",
    "Gabriel García Márquez", "Garcia Marquez", "Ken Follett", "Follett Ken",
    "Bernard Cornwell", "Cornwell Bernard", "Christian Jacq", "CHRISTIAN JACQ",
    "Anne Rice", "Rice Anne", "Danielle Steel", "Steel Danielle",
    "Diana Palmer", "Barbara Cartland", "Cartland", "Carole Mortimer",
    "Black Shayla", "Christina Dodd", "Elizabeth Lowell", "Candace Camp",
    "Connie Mason", "Bradford", "Alice A. Bailey",  # theosophy - philosophy
    "Doris Lessing", "Lessing", "Samuel Beckett", "Beckett Samuel",
    "Gao Xingjian", "Jorge Amado", "Amado Jorge", "Franz Kafka", "Kafka",
    "Ernest Hemingway", "Hemingway", "F. Scott Fitzgerald", "Fitzgerald",
    "John Steinbeck", "Steinbeck", "William Faulkner", "Faulkner",
    "Virginia Woolf", "Woolf", "James Joyce", "Joyce", "Marcel Proust", "Proust",
    "Italo Calvino", "Calvino", "Umberto Eco", "Eco Umberto",
    "José Saramago", "Saramago", "Stefano Benni", "Benni",
    "Alessandro Baricco", "Baricco", "Niccolò Ammaniti", "Ammaniti",
    "Margaret Mazzantini", "Mazzantini", "Elena Ferrante", "Ferrante",
    "Oriana Fallaci",  # often nonfiction
    "Andrea Camilleri",  # crime preferred - last write wins if we put crime after
    "Haruki Murakami", "Murakami", "Kazuo Ishiguro", "Ishiguro",
    "Ian McEwan", "McEwan", "Julian Barnes", "Barnes", "Kazuo",
    "Milan Kundera", "Kundera", "Isabel Allende", "Allende",
    "Mario Vargas Llosa", "Vargas Llosa", "Carlos Fuentes", "Fuentes",
    "Roberto Bolaño", "Bolano", "Javier Marías", "Marias",
    "Antonio Tabucchi", "Tabucchi", "Claudio Magris", "Magris",
    "Primo Levi", "Levi Primo", "Natalia Ginzburg", "Ginzburg",
    "Elsa Morante", "Morante", "Alberto Arbasino", "Arbasino",
    "Pier Paolo Pasolini", "Pasolini", "Leonardo Sciascia", "Sciascia",
    "Gesualdo Bufalino", "Bufalino", "Vincenzo Consolo", "Consolo",
    "Andrea Camilleri", "Andrea De Carlo", "Susanna Tamaro", "Tamaro",
    "Margaret Atwood", "Atwood", "Cormac McCarthy", "McCarthy",
    "Michel Houellebecq", "Houellebecq", "Jonathan Coe", "Coe",
    "Nick Hornby", "Hornby", "Ian McEwan", "Zadie Smith", "Smith Zadie",
    "Chimamanda Ngozi Adichie", "Adichie", "Sally Rooney", "Rooney",
    "Elena Ferrante", "Jhumpa Lahiri", "Lahiri",
    "Anaïs Nin", "Anais Nin", "Nin Anais",
    "Daphne Du Maurier", "Du Maurier Daphne", "Du Maurier",
    "Angela Carter", "Carter Angela", "A.S. Byatt", "Byatt",
    "Iris Murdoch", "Murdoch", "Doris Lessing",
    "Alessandro Girola",  # indie IT - literary default
    "Alec Valschi", "Claudio Paganelli", "Emilia Valli",
    "Andrea Frediani", "Frediani Andrea",  # historical fiction
    "Alessandro",  # too vague - skip via later
)

# fix: crime must win for camilleri - re-add
add("fiction/crime", "Andrea Camilleri", "Camilleri Andrea", "Camilleri")
add("nonfiction/philosophy", "Alice A. Bailey", "Bailey Alice")
add("nonfiction/history", "Oriana Fallaci", "Fallaci Oriana", "Bruno Vespa", "Vespa Bruno",
    "Arrigo Petacco", "Petacco", "Corrado Augias", "Augias",
    "Indro Montanelli", "Montanelli", "Alessandro Barbero", "Barbero",
    "Yuval Noah Harari", "Harari", "Noam Chomsky", "Chomsky",
    "Eric Hobsbawm", "Hobsbawm", "Tony Judt", "Judt",
    "Timothy Snyder", "Snyder Timothy", "Anne Applebaum", "Applebaum",
)

add("classics/italian",
    "Alessandro Manzoni", "Manzoni", "Manzoni Alessandro",
    "Antonio Fogazzaro", "Fogazzaro", "Federico De Roberto", "De Roberto",
    "Anton Giulio Barrili", "Barrili", "Emilio De Marchi", "De Marchi",
    "Edmondo De Amicis", "De Amicis", "Gabriele D'Annunzio", "D'Annunzio",
    "Dante Alighieri", "Dante", "Giovanni Boccaccio", "Boccaccio",
    "Francesco Petrarca", "Petrarca", "Niccolò Machiavelli", "Machiavelli",
    "Carlo Goldoni", "Goldoni", "Giacomo Leopardi", "Leopardi",
    "Ugo Foscolo", "Foscolo", "Alessandro Tassoni", "Tassoni",
    "Giovanni Verga", "Verga", "Luigi Pirandello", "Pirandello",
    "Italo Svevo", "Svevo", "Giuseppe Tomasi di Lampedusa", "Lampedusa",
    "Ippolito Nievo", "Nievo", "Matilde Serao", "Serao",
    "Grazia Deledda", "Deledda", "Luigi Capuana", "Capuana",
    "Afro Publio Terenzio", "Terenzio", "Publio Virgilio Marone", "Virgilio",
)

add("classics/world",
    "Anton Pavlovic Cechov", "Chekhov", "Cechov", "Tolstoj", "Tolstoy",
    "Dostoevskij", "Dostoevsky", "Dostoevskij Fedor", "Fedor Dostoevskij",
    "Alexandre Dumas", "Dumas", "Victor Hugo", "Hugo", "Honoré de Balzac", "Balzac",
    "Stendhal", "Émile Zola", "Zola", "Guy de Maupassant", "Maupassant",
    "Gustave Flaubert", "Flaubert", "Charles Dickens", "Dickens",
    "Jane Austen", "Austen", "Charlotte Brontë", "Emily Brontë", "Bronte",
    "Mark Twain", "Twain", "Herman Melville", "Melville", "Edgar Allan Poe", "Poe",
    "Oscar Wilde", "Wilde", "Robert Louis Stevenson", "Stevenson",
    "Arthur Conan Doyle", "Jules Verne", "Verne", "Emilio Salgari", "Salgari",
    "Homer", "Omero", "Ovidio", "Ovid", "Horace", "Orazio",
    "William Shakespeare", "Shakespeare", "Molière", "Moliere",
    "Johann Wolfgang von Goethe", "Goethe", "Friedrich Schiller", "Schiller",
    "Franz Kafka", "Kafka", "Thomas Mann", "Mann Thomas",
    "Marcel Proust", "Proust", "James Joyce", "Joyce",
    "Leo Tolstoy", "Lev Tolstoj", "Fyodor Dostoevsky",
    "Ivan Turgenev", "Turgenev", "Nikolai Gogol", "Gogol",
    "Miguel de Cervantes", "Cervantes", "Lope de Vega",
    "Daniel Defoe", "Defoe", "Jonathan Swift", "Swift",
    "Mary Shelley", "Shelley Mary", "Bram Stoker", "Stoker",
    "H.G. Wells", "Wells", "Jack London", "London Jack",
    "Joseph Conrad", "Conrad", "Henry James", "James Henry",
    "George Eliot", "Eliot George", "Thomas Hardy", "Hardy Thomas",
    "Aleksej Tolstoj", "Alexei Tolstoy",
)

add("fiction/kids_ya",
    "Franklin W. Dixon", "Dixon", "Carolyn Keene", "Keene",
    "Eoin Colfer", "Colfer Eoin", "Cassandra Clare",
    "Geronimo Stilton", "Gianni Rodari", "Rodari", "Enid Blyton", "Blyton",
    "Roald Dahl", "Dahl Roald", "Astrid Lindgren", "Lindgren",
    "Bianca Pitzorno", "Pitzorno", "J.K. Rowling", "Rowling",
    "Rick Riordan", "Riordan", "John Green", "Green John",
    "Suzanne Collins", "Collins", "Stephenie Meyer", "Meyer Stephenie",
    "Lemony Snicket", "Snicket", "Philip Pullman", "Pullman",
    "C.S. Lewis", "Lewis C.S", "J.M. Barrie", "Barrie",
    "Lewis Carroll", "Carroll", "A.A. Milne", "Milne",
    "Beatrix Potter", "Potter Beatrix", "Dr. Seuss", "Seuss",
    "Maurice Sendak", "Sendak", "Eric Carle", "Carle",
    "Jeff Kinney", "Kinney", "Dav Pilkey", "Pilkey",
)

add("nonfiction/science",
    "Carlo Rovelli", "Rovelli", "Brian Greene", "Greene Brian",
    "Richard Dawkins", "Dawkins", "Stephen Hawking", "Hawking",
    "Carl Sagan", "Sagan", "Neil deGrasse Tyson", "Tyson",
    "Oliver Sacks", "Sacks", "Siddhartha Mukherjee", "Mukherjee",
    "Mary Roach", "Roach", "Bill Bryson", "Bryson",  # often science pop
    "Jared Diamond", "Diamond Jared", "Richard Feynman", "Feynman",
    "Albert Hofmann", "Hofmann", "Benoit Mandelbrot", "Mandelbrot",
    "Anton Zeilinger", "Zeilinger", "Peter Wohlleben", "Wohlleben",
    "Jim Al-Khalili", "Al-Khalili", "Telmo Pievani", "Pievani",
    "Stefano Mancuso", "Mancuso", "E.O. Wilson", "Wilson Edward",
)

add("nonfiction/psych_society",
    "Daniel Kahneman", "Kahneman", "Daniel Goleman", "Goleman",
    "Paolo Crepet", "Crepet", "Carl Gustav Jung", "Jung",
    "Sigmund Freud", "Freud", "Erich Fromm", "Fromm",
    "Viktor Frankl", "Frankl", "Alice Miller", "Miller Alice",
    "Allan Pease", "Pease", "Gary Chapman",  # 5 love languages
    "Brené Brown", "Brene Brown", "Brown Brene",
    "Malcolm Gladwell", "Gladwell", "Jonathan Haidt", "Haidt",
    "Steven Pinker", "Pinker", "Robert Cialdini", "Cialdini",
    "Nassim Nicholas Taleb", "Taleb", "Jordan Peterson", "Peterson",
)

add("nonfiction/philosophy",
    "Emanuele Severino", "Severino", "Epitteto", "Epictetus",
    "Marco Aurelio", "Marcus Aurelius", "Seneca", "Platone", "Plato",
    "Aristotele", "Aristotle", "Nietzsche", "Schopenhauer", "Kant",
    "Heidegger", "Sartre", "Camus", "Simone de Beauvoir",
    "Byung-chul Han", "Han Byung-chul", "Slavoj Zizek", "Zizek",
    "Alain de Botton", "de Botton", "Osho", "Thich Nhat Hanh",
    "Dalai Lama", "Confucio", "Laozi", "Lao Tzu",
    "Filosofia",  # dump folder of philosophy
)

add("nonfiction/history",
    "Yuval Noah Harari", "Harari", "Indro Montanelli", "Montanelli",
    "Alessandro Barbero", "Barbero", "Jacques Le Goff", "Le Goff",
    "Eric Hobsbawm", "Tony Judt", "Howard Zinn", "Zinn",
    "Mary Beard", "Beard Mary", "Tom Holland", "Holland Tom",
    "Antony Beevor", "Beevor", "Max Hastings", "Hastings",
    "Simon Schama", "Schama", "Niall Ferguson", "Ferguson",
    "Christian Jacq",  # egypt - fiction often
)

add("nonfiction/tech_ai",
    "Cade Metz", "Metz", "Ashlee Vance", "Vance Ashlee",
    "Walter Isaacson", "Isaacson",  # bios tech
    "Eric Schmidt", "Schmidt", "Ray Kurzweil", "Kurzweil",
    "Nick Bostrom", "Bostrom", "Max Tegmark", "Tegmark",
    "Cathy O'Neil", "O'Neil", "Shoshana Zuboff", "Zuboff",
    "Evgeny Morozov", "Morozov", "Jaron Lanier", "Lanier",
    "Clay Shirky", "Shirky", "Charles Petzold", "Petzold",
)

add("practical/tech_manuals",
    "Charles Petzold", "Petzold", "Noel Rappin", "David Flanagan",
    "Martin Fowler", "Fowler Martin", "Robert C. Martin", "Uncle Bob",
    "Kent Beck", "Beck Kent", "Eric Evans", "Evans Eric",
    "Gang of Four", "GoF", "Steve McConnell", "McConnell",
)

add("practical/parenting",
    "Adele Faber", "Elaine Mazlish", "Alberto Pellai", "Pellai",
)

add("practical/health",
    "Jessie Inchauspé", "Inchauspe", "Deepak Chopra", "Chopra",
)

add("practical/travel",
    "Lonely Planet", "Rough Guides", "Rough Guide", "Michelin",
)

add("fiction/literary",
    "Gao Xingjian", "Bai Xianyong", "Mo Yan", "Yan Lianke",
    "Orhan Pamuk", "Pamuk", "Naguib Mahfouz", "Mahfouz",
    "Chinua Achebe", "Achebe", "Ngugi wa Thiong'o",
)

# Romance / commercial → literary (no romance shelf)
add("fiction/literary",
    "Carole Mortimer", "Diana Palmer", "Barbara Cartland", "Belva Plain",
    "Danielle Steel", "Nora Roberts", "Roberts Nora", "Nicholas Sparks",
    "Sparks Nicholas", "Jojo Moyes", "Moyes", "Sophie Kinsella", "Kinsella",
    "Black Shayla", "Christina Dodd", "Elizabeth Lowell", "Candace Camp",
    "Connie Mason", "Bradford Barbara Taylor",
)

# Title keyword rules (applied when author unknown / weak)
TITLE_RULES: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"\b(urania|fantascienza|foundation|fondazione|dune|cyberpunk|neuromante|odissea nello spazio|2001|2010|2061|3001|hyperion|ender|asimov|robot|android)\b", re.I), "fiction/sf"),
    (re.compile(r"\b(giallo|maigret|poirot|montalbano|sherlock|detective|omicidio|assassin|thriller|noir|mistero|indagine|commissario)\b", re.I), "fiction/crime"),
    (re.compile(r"\b(harry potter|geronimo|rodari|favole|fiabe|ragazzi|young adult|hunger games|narnia|hobbit)\b", re.I), "fiction/kids_ya"),
    (re.compile(r"\b(signore degli anelli|lord of the rings|game of thrones|trono di spade|earthsea|terry pratchett|discworld)\b", re.I), "fiction/fantasy"),
    (re.compile(r"\b(rough guide|lonely planet|guida di|guida turistica|travel guide|phrasebook)\b", re.I), "practical/travel"),
    (re.compile(r"\b(machine learning|deep learning|python|javascript|kubernetes|docker|programming|oreilly|o'reilly|rails|ruby on)\b", re.I), "practical/tech_manuals"),
    (re.compile(r"\b(storia d'italia|seconda guerra|prima guerra|biografia|autobiografia|memoir)\b", re.I), "nonfiction/history"),
    (re.compile(r"\b(filosofia|stoicismo|meditazione|zen|buddismo|tao)\b", re.I), "nonfiction/philosophy"),
    (re.compile(r"\b(psicolog|ansia|depressione|mindfulness|intelligen\w+ emotiva)\b", re.I), "nonfiction/psych_society"),
    (re.compile(r"\b(fisica|quantistic|biologia|evoluzione|cosmo|universo|neuroscienz)\b", re.I), "nonfiction/science"),
    (re.compile(r"\b(ricett|cucina|bimby|cookbook|chef)\b", re.I), "practical/craft"),
    (re.compile(r"\b(promessi sposi|divina commedia|decameron|eneide|iliade|odissea)\b", re.I), "classics/italian"),
    (re.compile(r"\b(moby dick|ivanhoe|tom sawyer|huckleberry|orgoglio e pregiudizio|guerra e pace|delitto e castigo)\b", re.I), "classics/world"),
    (re.compile(r"\b(1984|fattoria degli animali|animal farm|brave new world)\b", re.I), "fiction/literary"),
]

# Known work title → (author, category) for Bluebook/Unknown salvage
KNOWN_WORKS: list[tuple[re.Pattern[str], str, str]] = [
    (re.compile(r"2001|2010|2061|3001|odissea", re.I), "Arthur C. Clarke", "fiction/sf"),
    (re.compile(r"^1984\b|fattoria degli animali|animal farm", re.I), "George Orwell", "fiction/literary"),
    (re.compile(r"moby dick", re.I), "Herman Melville", "classics/world"),
    (re.compile(r"ivanhoe", re.I), "Walter Scott", "classics/world"),
    (re.compile(r"tom sawyer|huckleberry", re.I), "Mark Twain", "classics/world"),
    (re.compile(r"promessi sposi", re.I), "Alessandro Manzoni", "classics/italian"),
    (re.compile(r"margaret atwood|ancella|handmaid", re.I), "Margaret Atwood", "fiction/literary"),
    (re.compile(r"grande meaulnes", re.I), "Alain-Fournier", "classics/world"),
    (re.compile(r"guerra e pace|anna karenina", re.I), "Lev Tolstoj", "classics/world"),
    (re.compile(r"delitto e castigo|fratelli karamazov|idiota\b", re.I), "Fedor Dostoevskij", "classics/world"),
    (re.compile(r"divina commedia|inferno di dante", re.I), "Dante Alighieri", "classics/italian"),
    (re.compile(r"il nome della rosa", re.I), "Umberto Eco", "fiction/literary"),
    (re.compile(r"il piccolo principe", re.I), "Antoine de Saint-Exupéry", "fiction/kids_ya"),
    (re.compile(r"sapiens|homo deus|21 lezioni", re.I), "Yuval Noah Harari", "nonfiction/history"),
    (re.compile(r"fondazione|ciclo delle fondazioni|abissi d.acciaio|io.?robot", re.I), "Isaac Asimov", "fiction/sf"),
    (re.compile(r"dune\b", re.I), "Frank Herbert", "fiction/sf"),
    (re.compile(r"guida galattica|autostoppisti", re.I), "Douglas Adams", "fiction/sf"),
    (re.compile(r"signore degli anelli|lo hobbit|silmarillion", re.I), "J.R.R. Tolkien", "fiction/fantasy"),
    (re.compile(r"harry potter", re.I), "J.K. Rowling", "fiction/kids_ya"),
    (re.compile(r"sherlock holmes", re.I), "Arthur Conan Doyle", "fiction/crime"),
    (re.compile(r"poirot|miss marple", re.I), "Agatha Christie", "fiction/crime"),
    (re.compile(r"montalbano", re.I), "Andrea Camilleri", "fiction/crime"),
]

JUNK_AUTHORS = {
    "unknown", "aa vv", "aa vv_", "anonimo", "anonymous", "an", "administrator",
    "bluebook", "enterprize", "stevenlob", "provart", "monobook", "bruno",
    "a d n", "a d n_", "acer 5520", "1994", "angel", "ettore", "antonio",
    "alessandro", "filosofia", "barabba edizioni", "adn",
}

FREEBOOK_RE = re.compile(
    r"^(?P<author>.+?)\s+-\s+(?P<title>.+?)(?:\s+-\s+freebook.*)?$",
    re.I,
)
AUTHOR_TITLE_RE = re.compile(
    r"^(?P<author>[A-ZÀ-ÖØ-Þ][^/]{1,60}?)\s+-\s+(?P<title>.+)$"
)


def lookup_author(name: str) -> str | None:
    if not name:
        return None
    k = norm_key(name)
    if k in CAT:
        return CAT[k]
    # try without middle initials noise
    k2 = norm_key(re.sub(r"\b[A-Z]\b\.?", " ", name))
    if k2 in CAT:
        return CAT[k2]
    # surname-only last token
    toks = re.findall(r"[A-Za-zÀ-ÿ']+", name)
    if toks:
        sk = norm_key(toks[-1])
        # only if unique enough - check multi-word keys ending with surname
        for key, cat in CAT.items():
            parts = key.split()
            if parts and parts[-1] == sk and len(parts) >= 1:
                # prefer exact surname match only for distinctive long surnames
                if len(sk) >= 6:
                    return cat
    # inverted "Last First"
    toks = name.replace("_", " ").split()
    if len(toks) == 2:
        flipped = f"{toks[1]} {toks[0]}"
        k = norm_key(flipped)
        if k in CAT:
            return CAT[k]
    if len(toks) == 3:
        flipped = f"{toks[1]} {toks[2]} {toks[0]}"
        k = norm_key(flipped)
        if k in CAT:
            return CAT[k]
        flipped2 = f"{toks[2]} {toks[0]} {toks[1]}"
        k = norm_key(flipped2)
        if k in CAT:
            return CAT[k]
    return None


def parse_filename(stem: str) -> tuple[str | None, str]:
    """Return (author_or_None, title)."""
    stem = re.sub(r"\s*\(\d+\)\s*$", "", stem).strip()
    stem = re.sub(r"\s*_Ita Libro_?\s*", " ", stem, flags=re.I)
    stem = re.sub(r"\s*\[.*?\]\s*", " ", stem)
    stem = re.sub(r"\s+", " ", stem).strip()

    # freebook / Author - Title
    m = FREEBOOK_RE.match(stem)
    if m and " - " in stem:
        author, title = m.group("author").strip(), m.group("title").strip()
        # avoid treating "AA.VV. - Something" specially
        if len(author) > 2 and not author.lower().startswith("http"):
            return author, title

    # "Author. Title" rare
    m = re.match(r"^([A-Z][a-zà-ö]+(?:\s+[A-Z][a-zà-ö]+){1,3})\.\s+(.+)$", stem)
    if m:
        return m.group(1), m.group(2)

    return None, stem


def classify_file(folder_author: str, stem: str) -> tuple[str, str]:
    """Return (category, display_author)."""
    folder_author = folder_author.strip()
    parsed_author, title = parse_filename(stem)
    junk_folder = norm_key(folder_author) in JUNK_AUTHORS or folder_author in {
        "Unknown", "AA.VV_", "Anonimo", "Anonymous", "Bluebook", "ENTERPRIZE",
        "Administrator", "stevenlob", "A.D.N_", "Acer 5520", "1994", "Filosofia",
    }

    author = folder_author
    if junk_folder and parsed_author:
        author = parsed_author
    elif junk_folder:
        author = "Unknown"

    # known works from title
    for pat, known_author, cat in KNOWN_WORKS:
        if pat.search(title) or pat.search(stem):
            return cat, sanitize(known_author)

    # author map
    cat = lookup_author(author)
    if cat:
        # display: flip Last First if helpful
        disp = author
        toks = author.replace("_", " ").split()
        if len(toks) == 2 and lookup_author(f"{toks[1]} {toks[0]}"):
            # if flipped form is in map, prefer First Last when second form matches map better
            if norm_key(f"{toks[1]} {toks[0]}") in CAT:
                disp = f"{toks[1]} {toks[0]}"
        return cat, sanitize(disp)

    if parsed_author and not junk_folder:
        cat = lookup_author(parsed_author)
        if cat:
            return cat, sanitize(parsed_author)

    # title rules
    for pat, cat in TITLE_RULES:
        if pat.search(stem) or pat.search(title):
            disp = sanitize(parsed_author or (folder_author if not junk_folder else "Unknown"))
            return cat, disp

    # Filosofia folder → philosophy
    if folder_author == "Filosofia":
        return "nonfiction/philosophy", sanitize(parsed_author or "Unknown")

    return "_inbox", sanitize(folder_author if not junk_folder else (parsed_author or "Unknown"))


def unique_path(dest_dir: Path, name: str) -> Path:
    dest = dest_dir / name
    if not dest.exists():
        return dest
    stem, suf = Path(name).stem, Path(name).suffix
    n = 2
    while dest.exists():
        dest = dest_dir / f"{stem} ({n}){suf}"
        n += 1
    return dest


def move_file(src: Path, cat: str, author: str, stats: Counter) -> None:
    dest_dir = BASE / cat / author
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = unique_path(dest_dir, src.name)
    if src.resolve() == dest.resolve():
        stats["same"] += 1
        return
    src.rename(dest)
    stats["moved"] += 1
    stats[f"to:{cat}"] += 1


def process_tree(root: Path, stats: Counter, label: str) -> None:
    if not root.exists():
        return
    files = [p for p in root.rglob("*") if p.is_file() and not p.name.startswith(".")]
    print(f"[{label}] {len(files)} files under {root}")
    for src in files:
        # author folder = first path component under root's immediate structure
        try:
            rel = src.relative_to(root)
        except ValueError:
            continue
        parts = rel.parts
        if len(parts) >= 2:
            folder_author = parts[-2] if len(parts) >= 2 else "Unknown"
            # quarantine/bluebook/Bluebook/file → author Bluebook
            if root == QUAR:
                # _quarantine/<bucket>/<Author?>/file or _quarantine/<bucket>/file
                if len(parts) >= 3:
                    folder_author = parts[-2]
                elif len(parts) == 2:
                    folder_author = parts[0]  # bluebook, enterprize
        else:
            folder_author = "Unknown"

        cat, author = classify_file(folder_author, src.stem)
        if cat == "_inbox":
            # leave in inbox but maybe fix author folder if we parsed better
            if root == INBOX and author != folder_author and author != "Unknown":
                # re-home within inbox under better author name
                dest_dir = INBOX / author
                dest_dir.mkdir(parents=True, exist_ok=True)
                dest = unique_path(dest_dir, src.name)
                if dest != src:
                    src.rename(dest)
                    stats["inbox_reauthor"] += 1
            else:
                stats["stayed_inbox"] += 1
            continue
        move_file(src, cat, author, stats)

    # prune empty dirs
    for d in sorted(root.rglob("*"), reverse=True):
        if d.is_dir():
            try:
                next(d.iterdir())
            except StopIteration:
                try:
                    d.rmdir()
                except OSError:
                    pass


def main() -> None:
    stats: Counter = Counter()
    process_tree(INBOX, stats, "inbox")
    process_tree(QUAR, stats, "quarantine")

    # leftover quarantine → collapse into _quarantine/unsorted or leave
    # recount
    print("\n=== move stats ===")
    for k, v in sorted(stats.items(), key=lambda x: (-x[1], x[0])):
        print(f"{v:6d}  {k}")

    cats: Counter = Counter()
    total = 0
    for p in BASE.rglob("*"):
        if not p.is_file() or p.name.startswith(".") or p.name == "README.txt":
            continue
        total += 1
        rel = p.relative_to(BASE).parts
        if rel[0] == "_inbox":
            cats["_inbox"] += 1
        elif rel[0] == "_quarantine":
            cats["_quarantine/" + (rel[1] if len(rel) > 1 else "?")] += 1
        else:
            cats["/".join(rel[:2])] += 1
    print(f"\n=== distribution ({total} files) ===")
    for k, v in cats.most_common():
        print(f"{v:6d}  {k}")
    inbox_authors = len([d for d in INBOX.iterdir() if d.is_dir()]) if INBOX.exists() else 0
    print(f"inbox authors remaining: {inbox_authors}")


if __name__ == "__main__":
    main()

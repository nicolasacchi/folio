#!/usr/bin/env python3
"""Re-shelf books/ into taxonomy v2 (finer fiction leaves).

Moves files under /home/nik/komga/library/books by author maps + title rules.
Does not invent depth-3 paths. Residual narrative → fiction/general.
Prestige authors → fiction/literary (kept small).
"""
from __future__ import annotations

import os
import re
import unicodedata
from collections import Counter
from pathlib import Path

BASE = Path("/home/nik/komga/library/books")
CAT: dict[str, str] = {}


def sanitize(s: str) -> str:
    s = unicodedata.normalize("NFC", (s or "").strip())
    s = re.sub(r'[/\\:*?"<>|]', "—", s)
    s = re.sub(r"\s+", " ", s).strip(" .")
    return (s[:180] if s else "Unknown")


def norm_key(name: str) -> str:
    s = unicodedata.normalize("NFKD", name or "")
    s = "".join(c for c in s if not unicodedata.combining(c)).lower()
    s = s.replace("'", " ").replace("_", " ").replace(".", " ").replace(";", " ")
    # drop translator tails: take first author only
    if " e " in s and "," not in s:
        pass
    words = re.findall(r"[a-z0-9]+", s.split(";")[0])
    return " ".join(sorted(words))


def add(cat: str, *names: str) -> None:
    for n in names:
        CAT[norm_key(n)] = cat
        # also store unflipped tokens for Last First folders
        toks = re.findall(r"[A-Za-zÀ-ÿ']+", n)
        if len(toks) == 2:
            CAT[norm_key(f"{toks[1]} {toks[0]}")] = cat


# --- prestige literary (curated, small) ---
add("fiction/literary",
    "José Saramago", "Jose Saramago", "Stefano Benni", "Italo Calvino", "Calvino Italo",
    "Umberto Eco", "Eco Umberto", "Alessandro Baricco", "Erri De Luca", "De Luca Erri",
    "Gabriel Garcia Marquez", "Gabriel García Márquez", "Garcia Marquez",
    "Haruki Murakami", "Murakami Haruki", "Banana Yoshimoto", "Yoshimoto Banana",
    "Margaret Atwood", "Cormac McCarthy", "Michel Houellebecq", "Elena Ferrante",
    "Luis Sepúlveda", "Luis Sepulveda", "Paulo Coelho", "Coelho Paulo",  # borderline - keep literary popular
    "Fernando Pessoa", "Pessoa Fernando", "Jorge Luis Borges", "Borges",
    "Alberto Moravia", "Moravia Alberto", "Cesare Pavese", "Pavese Cesare",
    "Beppe Fenoglio", "Fenoglio", "Dacia Maraini", "Maraini Dacia",
    "Antonio Tabucchi", "Tabucchi", "Primo Levi", "Levi Primo",
    "Natalia Ginzburg", "Ginzburg", "Elsa Morante", "Morante",
    "Leonardo Sciascia", "Sciascia", "Pier Paolo Pasolini", "Pasolini",
    "Andrea Camilleri",  # NO - crime; remove below
    "Kazuo Ishiguro", "Ishiguro", "Ian McEwan", "McEwan",
    "Virginia Woolf", "Woolf", "James Joyce", "Joyce", "Marcel Proust", "Proust",
    "Thomas Mann", "Mann Thomas", "Franz Kafka", "Kafka",  # also classics - classics wins if we check classics first
    "Samuel Beckett", "Beckett", "Doris Lessing", "Lessing",
    "Emmanuel Carrère", "Carrere", "Colson Whitehead", "Whitehead",
    "Roberto Bolaño", "Bolano", "Orhan Pamuk", "Pamuk",
    "Amos Oz", "A.B. Yehoshua", "Yehoshua", "Andrés Neuman", "Neuman",
    "Andrea Bajani", "Bajani", "Claudia Durastanti", "Durastanti",
    "Niccolò Ammaniti", "Ammaniti", "Margaret Mazzantini", "Mazzantini",
    "Andrea De Carlo", "De Carlo Andrea", "Mauro Corona", "Corona Mauro",
    "Luciano De Crescenzo", "De Crescenzo", "Andrea Vitali", "Vitali Andrea",
    "Alberto Bevilacqua", "Bevilacqua Alberto", "Dario Fo", "Fo Dario",
    "Charles Bukowski", "Bukowski", "Chuck Palahniuk", "Palahniuk",
    "Alan Bennett", "Bennett Alan", "John Banville", "Banville",
    "Nick Hornby", "Hornby", "Jonathan Coe", "Coe Jonathan",
    "Isabel Allende", "Allende", "Mario Vargas Llosa", "Vargas Llosa",
    "Carlos Fuentes", "Fuentes", "Javier Marías", "Marias",
    "Milan Kundera", "Kundera", "Alejandro Jodorowsky", "Jodorowsky",
    "Eric-Emmanuel Schmitt", "Schmitt", "Daniel Pennac", "Pennac",
    "Angela Carter", "Carter Angela", "Anaïs Nin", "Anais Nin", "Nin Anais",
    "Gao Xingjian", "Jhumpa Lahiri", "Lahiri", "Zadie Smith", "Smith Zadie",
    "Sally Rooney", "Rooney", "Chimamanda Ngozi Adichie", "Adichie",
)

# remove Camilleri from literary if added - force crime
add("fiction/crime", "Andrea Camilleri", "Camilleri")

# --- romance ---
add("fiction/romance",
    "Danielle Steel", "Steel Danielle", "Diana Palmer", "Palmer Diana",
    "Barbara Cartland", "Cartland", "Barbara Taylor Bradford", "Bradford Barbara Taylor",
    "Carole Mortimer", "Mortimer Carole", "Belva Plain", "Plain Belva",
    "Connie Mason", "Mason Connie", "Elizabeth Lowell", "Lowell Elizabeth",
    "Christina Dodd", "Dodd Christina", "Candace Camp", "Camp Candace",
    "Emma Darcy", "Darcy Emma", "Sylvia Day", "Day Sylvia", "Shayla Black", "Black Shayla",
    "Abby Green", "Green Abby", "Julia Quinn", "Quinn Julia", "Mary Balogh", "Balogh",
    "Courtney Milan", "Milan Courtney", "Nora Roberts", "Roberts Nora",
    "Nicholas Sparks", "Sparks Nicholas", "Jojo Moyes", "Moyes",
    "Sophie Kinsella", "Kinsella", "Federico Moccia", "Moccia",
    "Fabio Volo", "Volo Fabio", "Anna Premoli", "Premoli",
    "Sarah Addison Allen", "Allen Sarah", "Deborah Hale", "Hale Deborah",
    "Ann Lethbridge", "Lethbridge", "Leigh Michaels", "Michaels Leigh",
    "Frances Roding", "Karen Van Der Zee", "Bonnie Pega", "Patricia Wilson",
    "Elizabeth Oldfield", "Christine Scott", "Quinn Wilder",
    "Christine Feehan", "Feehan",  # paranormal romance
    "BJ James", "James BJ", "Emily French", "Doris J. Lorenz",
    "Sally Garrett", "Garrett Sally", "Alessia Esse", "Camocardi Mariangela",
    "Chiara Cilli", "Francesca Muci", "Diana Lama", "Irene Cao",
    "E.L. James", "EL James", "James EL",
)

# --- historical ---
add("fiction/historical",
    "Bernard Cornwell", "Cornwell Bernard", "Christian Jacq", "CHRISTIAN JACQ", "Jacq Christian",
    "Ken Follett", "Follett Ken", "Colleen McCullough", "McCullough",
    "Andrea Frediani", "Frediani Andrea", "Conn Iggulden", "Iggulden",
    "Wilbur Smith", "Smith Wilbur", "Dorothy Dunnett", "Dunnett",
    "Philippa Gregory", "Gregory Philippa", "Edward Rutherfurd", "Rutherfurd",
    "Anthony Riches", "Riches Anthony", "Elizabeth Fremantle", "Fremantle",
    "Hilary Mantel", "Mantel", "Robert Harris", "Harris Robert",  # often hist thriller
    "Edward Bulwer-Lytton", "Bulwer-Lytton", "Robert Graves", "Graves Robert",
    "Mary Renault", "Renault", "Marguerite Yourcenar", "Yourcenar",
    "Umberto Eco",  # Nome della rosa etc - historical; but also literary - historical for Eco novels OK
)

# Eco: literary is fine; historical for Eco - last write wins. Prefer literary for Eco.
add("fiction/literary", "Umberto Eco", "Eco Umberto")

# --- horror ---
add("fiction/horror",
    "Anne Rice", "Rice Anne", "Stephen King", "King Stephen",
    "Clive Barker", "Barker Clive", "H.P. Lovecraft", "Lovecraft", "Howard Phillips Lovecraft",
    "Dean Koontz", "Koontz", "Dean R. Koontz",  # often thriller/horror
    "Chelsea Quinn Yarbro", "Yarbro", "Brian Lumley", "Lumley",
    "Al Sarrantonio", "Sarrantonio", "Dennis Etchison", "Etchison",
    "Shirley Jackson", "Jackson Shirley", "Edgar Allan Poe",  # classics too
    "Bram Stoker", "Stoker", "Mary Shelley",  # classics
    "Barbara Baraldi", "Baraldi", "Peter Straub", "Straub",
    "Ramsey Campbell", "Campbell Ramsey", "Thomas Ligotti", "Ligotti",
    "Joe Hill", "Hill Joe", "Paul Tremblay", "Tremblay",
)

# King crime books stay horror by default (good enough)

# --- thriller (from crime + literary) ---
add("fiction/thriller",
    "Tom Clancy", "Clancy Tom", "Clive Cussler", "Cussler Clive", "Cussler",
    "David Baldacci", "Baldacci David", "Baldacci",
    "Frederick Forsyth", "Forsyth", "Andy McNab", "McNab",
    "Dan Brown", "Brown Dan", "Robert Ludlum", "Ludlum",
    "John le Carré", "Le Carre", "Le Carré", "John le Carre",
    "Len Deighton", "Deighton", "Robert Harris", "Harris Robert",
    "Lee Child", "Child Lee", "Jack Reacher",
    "James Patterson", "Patterson", "John Grisham", "Grisham",  # legal thriller
    "Michael Crichton",  # often sf/thriller - sf may win
    "Douglas Preston", "Preston Douglas", "Lincoln Child", "Child Lincoln",
    "Jeffery Deaver", "Deaver",  # crime-thriller hybrid → thriller OK
    "Robin Cook", "Cook Robin",  # medical thriller
    "Brad Meltzer", "Meltzer", "Allan Folsom", "Folsom",
    "Michael Di Mercurio", "Di Mercurio", "Eric Ambler", "Ambler",
    "Daniel Silva", "Silva Daniel", "Vince Flynn", "Flynn Vince",
    "Brad Thor", "Thor Brad", "David Morrell", "Morrell",
)

# crime pure detection
add("fiction/crime",
    "Agatha Christie", "Christie Agatha", "Georges Simenon", "Simenon",
    "Andrea Camilleri", "Camilleri", "Stieg Larsson", "Larsson",
    "Anne Perry", "Perry Anne", "Ellis Peters", "Peters Ellis",
    "Ed McBain", "McBain", "Ellery Queen", "Queen Ellery",
    "Patricia Cornwell", "Cornwell Patricia",  # forensic crime
    "Elizabeth George", "George Elizabeth", "Raymond Chandler", "Chandler",
    "Dashiell Hammett", "Hammett", "Rex Stout", "Stout",
    "Ngaio Marsh", "Marsh", "P.D. James", "PD James",
    "Ruth Rendell", "Rendell", "Ian Rankin", "Rankin",
    "Henning Mankell", "Mankell", "Jo Nesbø", "Jo Nesbo", "Nesbo",
    "Donna Leon", "Leon Donna", "Michael Connelly", "Connelly Michael",
    "Dennis Lehane", "Lehane", "Elmore Leonard", "Leonard Elmore",
    "Carol O'Connell", "O'Connell", "Cornell Woolrich", "Woolrich",
    "Fred Vargas", "Vargas Fred", "Carlo Lucarelli", "Lucarelli",
    "Giorgio Scerbanenco", "Scerbanenco", "Massimo Carlotto", "Carlotto",
    "Giancarlo De Cataldo", "De Cataldo", "Donato Carrisi", "Carrisi",
    "Gianrico Carofiglio", "Carofiglio", "Antonio Manzini", "Manzini",
    "Marco Malvaldi", "Malvaldi", "Maurizio de Giovanni", "De Giovanni",
    "Boris Akunin", "Akunin", "Edgar Wallace", "Wallace Edgar",
    "Arthur Conan Doyle", "Conan Doyle", "S.S. Van Dine", "Van Dine",
    "Erle Stanley Gardner", "Gardner", "A.A. Fair", "Fair",
    "Edward Bunker", "Bunker", "David Goodis", "Goodis",
    "James Ellroy", "Ellroy", "Walter Mosley", "Mosley",
    "Tana French", "Gillian Flynn", "Flynn Gillian", "Paula Hawkins",
    "Kathy Reichs", "Reichs", "Tess Gerritsen", "Gerritsen",
    "Val McDermid", "McDermid", "Peter Robinson", "Robinson Peter",
    "Alexandra Marinina", "Marinina", "Jean Failler", "Failler",
    "Danila Comastri Montanari", "Comastri", "Piero Colaprico", "Colaprico",
    "Marcello Fois", "Fois", "Christopher Fowler", "Fowler Christopher",
    "Charlotte Link", "Link Charlotte", "Andrew Klavan", "Klavan",
    "Candace Robb", "Robb Candace", "Derek Raymond", "Raymond Derek",
    "Alfred Hitchcock", "Hitchcock", "James Hadley Chase", "Chase",
    "Mickey Spillane", "Spillane", "Mary Higgins Clark", "Higgins Clark",
    "Irene Adler", "Adler Irene",  # italian crime series brand
)

# SF / fantasy already mostly shelved; reinforce
add("fiction/sf",
    "Isaac Asimov", "Asimov", "Philip K. Dick", "Dick Philip", "Stanislaw Lem", "Lem",
    "Douglas Adams", "Adams Douglas", "Ray Bradbury", "Bradbury",
    "Arthur C. Clarke", "Clarke Arthur", "William Gibson", "Gibson William",
    "Frank Herbert", "Herbert Frank", "Ursula K. Le Guin", "Le Guin",
    "Robert A. Heinlein", "Heinlein", "Clifford D. Simak", "Simak",
    "A.E. van Vogt", "Van Vogt", "Fritz Leiber", "Leiber",  # also fantasy
    "Frederik Pohl", "Pohl", "Dan Simmons", "Simmons Dan",
    "Alan Dean Foster", "Foster Alan", "C.J. Cherryh", "Cherryh",
    "Anne McCaffrey", "McCaffrey",  # fantasy-ish
    "Poul Anderson", "Anderson Poul", "Bob Shaw", "Shaw Bob",
    "Fred Saberhagen", "Saberhagen", "Valerio Evangelisti", "Evangelisti",
    "Brian W. Aldiss", "Aldiss", "Ben Bova", "Bova", "Bruce Sterling", "Sterling",
    "Fredric Brown", "Brown Fredric", "John Brunner", "Brunner",
    "Edmond Hamilton", "Hamilton Edmond", "David Gerrold", "Gerrold",
    "Andre Norton", "Norton Andre", "Damon Knight", "Knight Damon",
    "Algis Budrys", "Budrys", "Elizabeth Moon", "Moon Elizabeth",
    "Liu Cixin", "Cixin Liu", "Ann Leckie", "Leckie", "Andy Weir", "Weir",
    "Hugh Howey", "Howey", "Neal Stephenson", "Stephenson",
    "Iain M. Banks", "Banks Iain", "Kim Stanley Robinson", "Robinson Kim",
    "Orson Scott Card", "Card", "Joe Haldeman", "Haldeman",
    "Robert Silverberg", "Silverberg", "Harry Harrison", "Harrison Harry",
    "Jack Vance", "Vance Jack", "Theodore Sturgeon", "Sturgeon",
    "Alfred Bester", "Bester", "Samuel R. Delany", "Delany",
    "Octavia E. Butler", "Butler Octavia", "Ted Chiang", "Chiang",
    "Greg Egan", "Egan", "Peter F. Hamilton", "Hamilton Peter",
    "Alastair Reynolds", "Reynolds Alastair", "Richard Morgan", "Morgan Richard",
    "J.G. Ballard", "Ballard", "Philip Jose Farmer", "Farmer",
    "Harlan Ellison", "Ellison", "Larry Niven", "Niven",
    "John Scalzi", "Scalzi", "Martha Wells", "Wells Martha",
    "Strugatsky", "Strugatskij", "Arkadij e Boris Strugackij",
    "Cordwainer Smith", "Smith Cordwainer", "James Tiptree", "Tiptree",
    "Michael Crichton", "Crichton",  # techno-thriller/sf
    "Ernest Cline", "Cline", "Ready Player One",
)

add("fiction/fantasy",
    "J.R.R. Tolkien", "Tolkien", "Terry Pratchett", "Pratchett",
    "Neil Gaiman", "Gaiman", "George R.R. Martin", "George R. R. Martin", "Martin George",
    "C.S. Lewis", "Lewis CS", "Roger Zelazny", "Zelazny",
    "David Gemmell", "Gemmell", "David Eddings", "Eddings",
    "Cassandra Clare", "Clare Cassandra", "Patrick Rothfuss", "Rothfuss",
    "Brandon Sanderson", "Sanderson", "Robert Jordan", "Jordan Robert",
    "Marion Zimmer Bradley", "Bradley Marion", "Michael Moorcock", "Moorcock",
    "Philip Pullman", "Pullman", "J.K. Rowling", "Rowling",  # kids often
    "Rick Riordan", "Riordan", "Guy Gavriel Kay", "Kay Guy",
    "Joe Abercrombie", "Abercrombie", "Robin Hobb", "Hobb",
    "Robert E. Howard", "Howard Robert", "Fritz Leiber", "Leiber Fritz",
    "Anne McCaffrey", "McCaffrey", "Andre Norton", "Norton",
    "David Gaider", "Gaider", "Emma Bull", "Bull Emma",
    "Ursula K. Le Guin",  # Earthsea fantasy - sf map may win for other books
)

add("fiction/kids_ya",
    "Geronimo Stilton", "Gianni Rodari", "Rodari", "Enid Blyton", "Blyton",
    "Roald Dahl", "Dahl Roald", "Astrid Lindgren", "Lindgren",
    "Bianca Pitzorno", "Pitzorno", "Suzanne Collins", "Collins Suzanne",
    "John Green", "Green John", "Eoin Colfer", "Colfer",
    "Franklin W. Dixon", "Dixon", "Carolyn Keene", "Keene",
    "J.K. Rowling", "Rowling", "Rick Riordan", "Riordan",
    "C.S. Lewis", "Lewis", "Maurice Sendak", "Sendak",
    "Pierdomenico Baccalario", "Baccalario", "Davide Morosinotto", "Morosinotto",
    "Anna Vivarelli", "Vivarelli", "Roberto Piumini", "Piumini",
    "Katherine Rundell", "Rundell", "Alexandra Bracken", "Bracken",
    "Stephenie Meyer", "Meyer Stephenie", "Lemony Snicket", "Snicket",
    "Jeff Kinney", "Kinney", "Dav Pilkey", "Pilkey",
    "Ingo Siegner", "Siegner", "Angeline Boulley", "Boulley",
    "Alan Gratz", "Gratz", "Christine Nöstlinger", "Nostlinger",
    "Carlo Collodi", "Collodi", "Anna Llenas", "Llenas",
)

add("fiction/adventure",
    "Emilio Salgari", "Salgari", "Jules Verne", "Verne",  # also classics
    "Jack London", "London Jack", "H. Rider Haggard", "Haggard",
    "Alexandre Dumas", "Dumas",  # also classics
    "Robert Louis Stevenson", "Stevenson", "Rudyard Kipling", "Kipling",
    "Patrick O'Brian", "O Brian", "C.S. Forester", "Forester",
    "Wilbur Smith", "Smith Wilbur",  # also historical
)

add("fiction/poetry",
    "Charles Baudelaire", "Baudelaire", "Giacomo Leopardi", "Leopardi",
    "Emily Dickinson", "Dickinson", "Walt Whitman", "Whitman",
    "Pablo Neruda", "Neruda", "Rainer Maria Rilke", "Rilke",
    "T.S. Eliot", "Eliot TS", "W.B. Yeats", "Yeats",
    "Eugenio Montale", "Montale", "Giuseppe Ungaretti", "Ungaretti",
    "Salvatore Quasimodo", "Quasimodo", "Alda Merini", "Merini",
    "Charles Bukowski",  # also literary - literary wins for prose; poetry titles later
)

add("fiction/drama",
    "William Shakespeare", "Shakespeare", "Carlo Goldoni", "Goldoni",
    "Luigi Pirandello", "Pirandello", "Dario Fo", "Fo Dario",
    "Samuel Beckett", "Beckett", "Bertolt Brecht", "Brecht",
    "Anton Chekhov", "Chekhov", "Cechov", "Henrik Ibsen", "Ibsen",
    "Tennessee Williams", "Williams Tennessee", "Arthur Miller", "Miller Arthur",
    "Molière", "Moliere", "Sophocles", "Sofocle", "Euripides", "Euripide",
    "Pietro Metastasio", "Metastasio",
)

# classics
add("classics/italian",
    "Alessandro Manzoni", "Manzoni", "Dante Alighieri", "Dante",
    "Giovanni Boccaccio", "Boccaccio", "Francesco Petrarca", "Petrarca",
    "Niccolò Machiavelli", "Machiavelli", "Giacomo Leopardi", "Leopardi",
    "Ugo Foscolo", "Foscolo", "Giovanni Verga", "Verga",
    "Luigi Pirandello", "Pirandello", "Italo Svevo", "Svevo",
    "Giuseppe Tomasi di Lampedusa", "Lampedusa", "Edmondo De Amicis", "De Amicis",
    "Gabriele D'Annunzio", "D'Annunzio", "Antonio Fogazzaro", "Fogazzaro",
    "Federico De Roberto", "De Roberto", "Ippolito Nievo", "Nievo",
    "Grazia Deledda", "Deledda", "Matilde Serao", "Serao",
    "Emilio De Marchi", "De Marchi", "Carlo Goldoni", "Goldoni",
)

add("classics/world",
    "Homer", "Omero", "Virgil", "Virgilio", "Ovid", "Ovidio",
    "William Shakespeare", "Shakespeare",
    "Jane Austen", "Austen", "Charles Dickens", "Dickens",
    "Charlotte Brontë", "Emily Brontë", "Bronte",
    "Mark Twain", "Twain", "Herman Melville", "Melville",
    "Edgar Allan Poe", "Poe", "Oscar Wilde", "Wilde",
    "Leo Tolstoy", "Tolstoy", "Tolstoj", "Fyodor Dostoevsky", "Dostoevskij", "Dostoevsky",
    "Anton Chekhov", "Cechov", "Chekhov",
    "Victor Hugo", "Hugo", "Honoré de Balzac", "Balzac", "Stendhal",
    "Émile Zola", "Zola", "Gustave Flaubert", "Flaubert",
    "Guy de Maupassant", "Maupassant", "Alexandre Dumas", "Dumas",
    "Jules Verne", "Verne", "H.G. Wells", "Wells HG",
    "Mary Shelley", "Shelley Mary", "Bram Stoker", "Stoker",
    "Robert Louis Stevenson", "Stevenson", "Joseph Conrad", "Conrad",
    "Henry James", "James Henry", "George Eliot", "Eliot George",
    "Thomas Hardy", "Hardy Thomas", "Daniel Defoe", "Defoe",
    "Jonathan Swift", "Swift", "Miguel de Cervantes", "Cervantes",
    "Johann Wolfgang von Goethe", "Goethe", "Franz Kafka", "Kafka",
    "Marcel Proust", "Proust", "James Joyce", "Joyce",
    "Ernest Hemingway", "Hemingway", "F. Scott Fitzgerald", "Fitzgerald",
    "John Steinbeck", "Steinbeck", "William Faulkner", "Faulkner",
    "George Orwell", "Orwell",  # modern classic
    "Aldous Huxley", "Huxley", "Virginia Woolf", "Woolf",
    "Jack London", "London Jack", "Arthur Conan Doyle", "Conan Doyle",
    "Emilio Salgari", "Salgari", "Aleksej Tolstoj", "Alexei Tolstoy",
    "Antoine de Saint-Exupéry", "Saint-Exupery", "Antoine Galland", "Galland",
)

# nonfiction expansions
add("nonfiction/biography",
    "Walter Isaacson", "Isaacson", "Ashlee Vance", "Vance Ashlee",
    "Oriana Fallaci", "Fallaci",  # often reportage - history too
    "Anne Frank", "Frank Anne", "Primi Levi",  # if memoir
)
add("nonfiction/history",
    "Yuval Noah Harari", "Harari", "Indro Montanelli", "Montanelli",
    "Alessandro Barbero", "Barbero", "Jacques Le Goff", "Le Goff",
    "Noam Chomsky", "Chomsky", "Bruno Vespa", "Vespa",
    "Arrigo Petacco", "Petacco", "Corrado Augias", "Augias",
    "Eric Hobsbawm", "Hobsbawm", "Tony Judt", "Judt",
    "Fernand Braudel", "Braudel", "Howard Zinn", "Zinn",
    "Mary Beard", "Beard Mary", "Antony Beevor", "Beevor",
    "Francesco Guicciardini", "Guicciardini", "Glenn Greenwald", "Greenwald",
    "Yanis Varoufakis", "Varoufakis", "Julian Assange", "Assange",
)
add("nonfiction/science",
    "Carlo Rovelli", "Rovelli", "Brian Greene", "Greene Brian",
    "Richard Dawkins", "Dawkins", "Stephen Hawking", "Hawking",
    "Carl Sagan", "Sagan", "Oliver Sacks", "Sacks",
    "Jared Diamond", "Diamond", "Richard Feynman", "Feynman",
    "Anton Zeilinger", "Zeilinger", "Peter Wohlleben", "Wohlleben",
    "Jim Al-Khalili", "Al-Khalili", "Telmo Pievani", "Pievani",
    "Stefano Mancuso", "Mancuso", "Bill Bryson", "Bryson",
)
add("nonfiction/psych_society",
    "Daniel Kahneman", "Kahneman", "Daniel Goleman", "Goleman",
    "Paolo Crepet", "Crepet", "Carl Gustav Jung", "Jung",
    "Sigmund Freud", "Freud", "Erich Fromm", "Fromm",
    "Viktor Frankl", "Frankl", "Malcolm Gladwell", "Gladwell",
    "Nassim Nicholas Taleb", "Taleb", "Steven Pinker", "Pinker",
    "Robert Cialdini", "Cialdini", "Jonathan Haidt", "Haidt",
    "Alice Miller", "Miller Alice", "Allan Pease", "Pease",
)
add("nonfiction/philosophy",
    "Emanuele Severino", "Severino", "Friedrich Nietzsche", "Nietzsche",
    "Immanuel Kant", "Kant", "Plato", "Platone", "Aristotle", "Aristotele",
    "Seneca", "Marcus Aurelius", "Marco Aurelio", "Epictetus", "Epitteto",
    "Byung-chul Han", "Han Byung", "Alain de Botton", "de Botton",
    "Osho", "Thich Nhat Hanh", "Dalai Lama", "Schopenhauer",
    "Heidegger", "Sartre", "Camus", "Simone de Beauvoir",
    "Agostino", "Sant Agostino", "Augustine",
)
add("nonfiction/tech_ai",
    "Cade Metz", "Metz", "Ray Kurzweil", "Kurzweil",
    "Nick Bostrom", "Bostrom", "Max Tegmark", "Tegmark",
    "Shoshana Zuboff", "Zuboff", "Evgeny Morozov", "Morozov",
    "Eric Schmidt", "Schmidt", "Mustafa Suleyman", "Suleyman",
    "Clay Shirky", "Shirky", "Jaron Lanier", "Lanier",
    "Cathy O'Neil", "O Neil", "Andrew S. Tanenbaum", "Tanenbaum",
)
add("nonfiction/arts",
    "Franco Battiato", "Battiato", "Arturo Graf", "Graf",
    "Susan Sontag", "Sontag", "John Berger", "Berger John",
)
add("nonfiction/business",
    "Seth Godin", "Godin", "Nassim Nicholas Taleb",  # psych too
    "Richard H. Thaler", "Thaler", "Thomas Piketty", "Piketty",
)
add("practical/tech_manuals",
    "Andrew S. Tanenbaum", "Tanenbaum", "Martin Fowler", "Fowler Martin",
    "Robert C. Martin", "Uncle Bob", "Kent Beck", "Beck Kent",
    "Noel Rappin", "Rappin", "Charles Petzold", "Petzold",
    "Roberto Marmo", "Marmo",  # AI algorithms manual
)

TITLE_RULES: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"\b(bridgerton|sceicco|sposa|duca\b|regency|rosa\b|romance|amore proibito|ti prego lasciati)\b", re.I), "fiction/romance"),
    (re.compile(r"\b(urania|fantascienza|foundation|fondazione|dune\b|cyberpunk|neuromante|odissea nello spazio|hyperion|ender|io.?robot)\b", re.I), "fiction/sf"),
    (re.compile(r"\b(giallo|maigret|poirot|montalbano|sherlock|detective|commissario|indagine|whodunit)\b", re.I), "fiction/crime"),
    (re.compile(r"\b(thriller|conspiracy|cospiraz|agente segreto|spia\b|op center|bourne)\b", re.I), "fiction/thriller"),
    (re.compile(r"\b(horror|vampiri|vampiro|ghost|fantasma|necroscope| Lovecraft| Lovecraft)\b", re.I), "fiction/horror"),
    (re.compile(r"\b(romanzo storico|medioevo|antico egitto|impero romano|seconda guerra mondiale|nazismo)\b", re.I), "fiction/historical"),
    (re.compile(r"\b(signore degli anelli|hobbit|trono di spade|harry potter|narnia|discworld|terre a)\b", re.I), "fiction/fantasy"),
    (re.compile(r"\b(geronimo|rodari|favole|fiabe per|ragazzi|young adult|hunger games)\b", re.I), "fiction/kids_ya"),
    (re.compile(r"\b(poesie|poesia|canzoniere|sonetti)\b", re.I), "fiction/poetry"),
    (re.compile(r"\b(teatro|dramma|commedia|tragedia|atto unico)\b", re.I), "fiction/drama"),
    (re.compile(r"\b(rough guide|lonely planet|guida di|phrasebook)\b", re.I), "practical/travel"),
    (re.compile(r"\b(machine learning|deep learning|python|javascript|kubernetes|architettura dei calcolatori|algoritmi|programmazione)\b", re.I), "practical/tech_manuals"),
    (re.compile(r"\b(filosofia|stoicismo|meditazione|zen\b)\b", re.I), "nonfiction/philosophy"),
    (re.compile(r"\b(biografia|autobiografia|memorie|diario di)\b", re.I), "nonfiction/biography"),
    (re.compile(r"\b(storia d'|seconda guerra|prima guerra|geopolitic)\b", re.I), "nonfiction/history"),
    (re.compile(r"\b(psicolog|ansia|mindfulness|intelligen\w+ emotiva)\b", re.I), "nonfiction/psych_society"),
    (re.compile(r"\b(fisica quant|biologia|evoluzione|cosmo|universo|neuroscienz)\b", re.I), "nonfiction/science"),
    (re.compile(r"\b(ricett|cucina|bimby|cookbook)\b", re.I), "practical/craft"),
    (re.compile(r"\b(promessi sposi|divina commedia|decameron)\b", re.I), "classics/italian"),
    (re.compile(r"\b(moby dick|guerra e pace|delitto e castigo|orgoglio e pregiudizio|anna karenina)\b", re.I), "classics/world"),
]

# Prefer classics over literary for classic authors when both mapped - classics written last for those names
# Actually lookup is single key - last add wins. We re-added literary for Eco after historical.
# For Dickens/Hemingway/Orwell/Kafka - classics/world should win: re-add classics last
for n in [
    "Charles Dickens", "Dickens", "Ernest Hemingway", "Hemingway", "George Orwell", "Orwell",
    "Franz Kafka", "Kafka", "Jane Austen", "Austen", "Oscar Wilde", "Wilde",
    "Virginia Woolf", "Woolf", "James Joyce", "Joyce", "Marcel Proust", "Proust",
    "F. Scott Fitzgerald", "Fitzgerald", "John Steinbeck", "Steinbeck",
    "William Faulkner", "Faulkner", "Aldous Huxley", "Huxley", "Samuel Beckett", "Beckett",
    "Edgar Allan Poe", "Poe", "Mary Shelley", "Shelley", "Bram Stoker", "Stoker",
    "Leo Tolstoy", "Tolstoy", "Tolstoj", "Fyodor Dostoevsky", "Dostoevskij",
    "Victor Hugo", "Hugo", "Alexandre Dumas", "Dumas", "Jules Verne", "Verne",
    "Mark Twain", "Twain", "Herman Melville", "Melville", "Homer", "Omero",
    "Dante Alighieri", "Dante", "Alessandro Manzoni", "Manzoni",
    "Edmondo De Amicis", "De Amicis", "Federigo Tozzi", "Tozzi",
]:
    # determine italian vs world
    if norm_key(n) in {norm_key(x) for x in [
        "Dante Alighieri", "Dante", "Alessandro Manzoni", "Manzoni", "Edmondo De Amicis",
        "De Amicis", "Federigo Tozzi", "Tozzi", "Giovanni Verga", "Pirandello", "Svevo",
    ]}:
        add("classics/italian", n)
    else:
        add("classics/world", n)

# Tozzi is modern Italian classic-ish - classics/italian OK


def primary_author(folder: str) -> str:
    """Strip translators after ; and pick first author."""
    name = folder.split(";")[0].strip()
    name = re.sub(r"\s+", " ", name)
    return name


def lookup(name: str) -> str | None:
    if not name:
        return None
    k = norm_key(name)
    if k in CAT:
        return CAT[k]
    # first author only if " & " or " e "
    for sep in (" & ", " e ", " and ", "|"):
        if sep in name:
            return lookup(name.split(sep)[0].strip())
    toks = re.findall(r"[A-Za-zÀ-ÿ']+", name)
    if len(toks) == 2:
        flipped = f"{toks[1]} {toks[0]}"
        k2 = norm_key(flipped)
        if k2 in CAT:
            return CAT[k2]
    if len(toks) >= 2:
        # surname only if long
        sk = norm_key(toks[-1])
        if len(sk) >= 7:
            for key, cat in CAT.items():
                parts = key.split()
                if parts and parts[-1] == sk:
                    return cat
    return None


def display_author(name: str) -> str:
    name = primary_author(name)
    if name.lower() in {"unknown", "various", "aa.vv_", "aa.vv", "anonimo", "anonymous"}:
        return sanitize(name.title() if name.lower() != "aa.vv_" else "Various")
    toks = re.findall(r"[A-Za-zÀ-ÿ']+", name)
    # flip Last First when second token looks like given name and first doesn't map alone
    if len(toks) == 2:
        flipped = f"{toks[1]} {toks[0]}"
        if norm_key(flipped) in CAT and norm_key(name) not in CAT:
            return sanitize(flipped)
        # if folder is Last First (Italian catalog) and both capitalized
        first_names = {
            "john", "james", "robert", "michael", "william", "david", "richard", "charles",
            "daniel", "paul", "mark", "george", "joseph", "thomas", "christopher", "stephen",
            "andrew", "anthony", "joshua", "kenneth", "brian", "kevin", "edward", "ronald",
            "mary", "patricia", "jennifer", "linda", "elizabeth", "barbara", "susan", "jessica",
            "anne", "ann", "jane", "kate", "alice", "emma", "olivia", "sophia",
            "andrea", "marco", "luca", "paolo", "giovanni", "francesco", "alessandro", "mario",
            "luigi", "giuseppe", "roberto", "stefano", "carlo", "enrico", "davide", "matteo",
            "chiara", "giulia", "francesca", "elena", "silvia", "paola", "laura", "monica",
            "jean", "pierre", "marie", "hans", "klaus", "erik", "paulo", "carlos", "miguel",
            "jose", "juan", "luis", "pedro", "tom", "tim", "jim", "bob", "joe", "mike",
            "alan", "neil", "ian", "hugh", "philip", "martin", "bernard", "alfred", "arthur",
            "edgar", "oscar", "victor", "ernest", "dean", "clive", "julian", "agatha",
            "haruki", "kazuo", "gabriel", "jorge", "mario", "isabel", "michel", "albert",
            "franz", "thomas", "italo", "umberto", "primo", "dario", "fabio", "massimo",
            "erri", "beatrice", "chiara", "federico", "nicola", "dacia", "cesare", "alberto",
            "antonio", "pietro", "giacomo", "eugenio", "salvatore", "alda", "ori ana",
            "ken", "dan", "lee", "jack", "ray", "philip", "frank", "ursula", "octavia",
            "margaret", "cormac", "michel", "elena", "luis", "banana", "paulo", "fernando",
            "jorge", "alessandro", "stefano", "andrea", "mauro", "luciano", "charles", "chuck",
            "nick", "jonathan", "ian", "kazuo", "zadie", "sally", "jhumpa",
            "bernard", "christian", "colleen", "conn", "wilbur", "philippa", "edward",
            "danielle", "diana", "barbara", "carole", "belva", "connie", "emma", "sylvia",
            "shayla", "julia", "nora", "nicholas", "jojo", "sophie", "federico", "anna",
            "anne", "stephen", "clive", "howard", "chelsea", "brian", "peter", "joe",
            "tom", "clive", "david", "frederick", "andy", "robert", "john", "len", "james",
            "douglas", "jeffery", "robin", "brad", "michael", "eric", "daniel", "vince",
        }
        if toks[1].lower() in first_names and toks[0].lower() not in first_names:
            return sanitize(f"{toks[1]} {toks[0]}")
    return sanitize(name)


def classify(folder: str, stem: str) -> tuple[str, str]:
    author = primary_author(folder)
    cat = lookup(author)
    if cat:
        return cat, display_author(author)

    # title rules
    for pat, c in TITLE_RULES:
        if pat.search(stem):
            return c, display_author(author)

    # current path already has a category — preserve non-literary if good
    return None, display_author(author)  # type: ignore


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


def current_category(path: Path) -> str:
    rel = path.relative_to(BASE).parts
    if rel[0].startswith("_"):
        return rel[0]
    if len(rel) >= 2:
        return f"{rel[0]}/{rel[1]}"
    return rel[0]


def main() -> None:
    stats: Counter = Counter()
    files = [
        p for p in BASE.rglob("*")
        if p.is_file() and not p.name.startswith(".") and p.name != "README.txt"
    ]
    print(f"scanning {len(files)} files")

    for src in files:
        rel = src.relative_to(BASE).parts
        if rel[0].startswith("_"):
            continue
        # author folder is last dir before file
        folder = rel[-2] if len(rel) >= 2 else "Unknown"
        cur = current_category(src)
        new_cat, author = classify(folder, src.stem)

        if new_cat is None:
            # residual: if currently literary → general; else keep
            if cur == "fiction/literary":
                new_cat = "fiction/general"
            else:
                stats["kept"] += 1
                continue
        elif new_cat == cur:
            stats["already"] += 1
            # still maybe fix author folder name
            if display_author(folder) != folder and False:
                pass
            continue

        dest_dir = BASE.joinpath(*new_cat.split("/"), author)
        dest_dir.mkdir(parents=True, exist_ok=True)
        dest = unique_path(dest_dir, src.name)
        try:
            if src.resolve() == dest.resolve():
                stats["same"] += 1
                continue
            src.rename(dest)
            stats["moved"] += 1
            stats[f"{cur}→{new_cat}"] += 1
        except OSError:
            try:
                os.link(src, dest)
                src.unlink()
                stats["moved"] += 1
                stats[f"{cur}→{new_cat}"] += 1
            except OSError as e:
                stats["err"] += 1
                if stats["err"] <= 5:
                    print("ERR", e, src)

    # prune empty dirs
    for d in sorted(BASE.rglob("*"), reverse=True):
        if d.is_dir() and d != BASE:
            try:
                next(d.iterdir())
            except StopIteration:
                try:
                    d.rmdir()
                except OSError:
                    pass

    print("\n=== moves ===")
    for k, v in stats.most_common(40):
        print(f"{v:6d}  {k}")

    cats: Counter = Counter()
    total = 0
    for p in BASE.rglob("*"):
        if not p.is_file() or p.name.startswith(".") or p.name == "README.txt":
            continue
        total += 1
        rel = p.relative_to(BASE).parts
        if rel[0].startswith("_"):
            cats[rel[0]] += 1
        else:
            cats["/".join(rel[:2])] += 1
    print(f"\n=== FINAL distribution ({total}) ===")
    for k, v in cats.most_common():
        print(f"{v:6d}  {k}")


if __name__ == "__main__":
    main()

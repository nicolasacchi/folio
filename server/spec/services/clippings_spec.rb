require 'rails_helper'

RSpec.describe Library::Clippings do
  SEP = "==========\r\n"

  let(:italian_clippings) do
    "\u{FEFF}Il nome della rosa (Umberto Eco)\r\n" \
    "- La tua evidenziazione a pagina 45 | posizione 680-682 | Aggiunto il lunedì 6 luglio 2026 21:13:22\r\n" \
    "\r\n" \
    "In principio era il Verbo e il Verbo era presso Dio.\r\n" + SEP +
    "Il nome della rosa (Umberto Eco)\r\n" \
    "- La tua nota alla posizione 690 | Aggiunto il lunedì 6 luglio 2026 21:15:00\r\n" \
    "\r\n" \
    "Da rileggere.\r\n" + SEP +
    "Il nome della rosa (Umberto Eco)\r\n" \
    "- Il tuo segnalibro alla posizione 700 | Aggiunto il lunedì 6 luglio 2026 21:16:00\r\n" \
    "\r\n" \
    "\r\n" + SEP
  end

  let(:english_clippings) do
    "The Salt Road (Ada Author)\r\n" \
    "- Your Highlight on page 12 | location 150-155 | Added on Monday, July 6, 2026 9:13:22 PM\r\n" \
    "\r\n" \
    "The road was long and white with salt.\r\n" + SEP
  end

  describe ".parse" do
    it "parses Italian highlights, notes and bookmarks" do
      entries = described_class.parse(italian_clippings)

      expect(entries.map(&:kind)).to eq(%w[highlight note bookmark])

      highlight = entries.first
      expect(highlight.raw_title).to eq("Il nome della rosa")
      expect(highlight.raw_author).to eq("Umberto Eco")
      expect(highlight.page).to eq(45)
      expect(highlight.location_start).to eq(680)
      expect(highlight.location_end).to eq(682)
      expect(highlight.content).to eq("In principio era il Verbo e il Verbo era presso Dio.")
      expect(highlight.added_at).to eq(Time.zone.local(2026, 7, 6, 21, 13, 22))

      expect(entries.second.content).to eq("Da rileggere.")
      expect(entries.third.content).to be_nil
    end

    it "parses English entries" do
      entry = described_class.parse(english_clippings).first

      expect(entry.kind).to eq("highlight")
      expect(entry.page).to eq(12)
      expect(entry.location_start).to eq(150)
      expect(entry.added_at).to eq(Time.zone.local(2026, 7, 6, 21, 13, 22))
    end

    it "gives each entry a stable fingerprint" do
      first = described_class.parse(italian_clippings).map(&:fingerprint)
      second = described_class.parse(italian_clippings).map(&:fingerprint)
      expect(first).to eq(second)
      expect(first.uniq.size).to eq(3)
    end

    it "survives garbage" do
      expect(described_class.parse("random\ntext")).to eq([])
      expect(described_class.parse("")).to eq([])
    end
  end

  describe ".import" do
    let!(:device) { create(:device) }
    let!(:book) { create(:book, title: "Il nome della rosa", author: "Umberto Eco") }

    it "creates annotations matched to books, idempotently" do
      stats = described_class.import(device, italian_clippings)
      expect(stats[:imported]).to eq(3)
      expect(device.annotations.count).to eq(3)
      expect(device.annotations.matched.count).to eq(3)
      expect(device.annotations.highlights.first.book).to eq(book)

      again = described_class.import(device, italian_clippings)
      expect(again[:imported]).to eq(0)
      expect(device.annotations.count).to eq(3)
    end

    it "prefers the author-matching book among same-title candidates" do
      other = create(:book, title: "Il nome della rosa", author: "Someone Else")

      described_class.import(device, italian_clippings)
      expect(device.annotations.highlights.first.book).to eq(book)
      expect(device.annotations.where(book: other)).to be_empty
    end

    it "matches 'Lastname, Firstname' catalog authors" do
      book.update!(author: "Eco, Umberto")

      described_class.import(device, italian_clippings)
      expect(device.annotations.matched.count).to eq(3)
    end

    it "keeps unmatched entries and rematches them later" do
      book.update!(title: "Different Title")

      described_class.import(device, italian_clippings)
      expect(device.annotations.unmatched.count).to eq(3)

      book.update!(title: "Il nome della rosa")
      described_class.import(device, english_clippings)
      expect(device.annotations.unmatched.count).to eq(1) # only the English one
    end
  end
end

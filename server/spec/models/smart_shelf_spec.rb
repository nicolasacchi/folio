require "rails_helper"

RSpec.describe SmartShelf, type: :model do
  def condition(field, op, value = nil)
    { "field" => field, "op" => op, "value" => value }.compact
  end

  describe "validations" do
    it "requires a name" do
      shelf = build(:smart_shelf, name: nil)
      expect(shelf).not_to be_valid
      expect(shelf.errors[:name]).to be_present
    end

    it "requires a unique name" do
      create(:smart_shelf, name: "Dupe")
      shelf = build(:smart_shelf, name: "Dupe")
      expect(shelf).not_to be_valid
      expect(shelf.errors[:name]).to be_present
    end

    it "assigns an increasing position by default" do
      first = create(:smart_shelf, name: "First")
      second = create(:smart_shelf, name: "Second")
      expect(second.position).to be > first.position
    end

    it "is valid with no conditions at all (an empty/blank shelf)" do
      shelf = build(:smart_shelf, rules: {})
      expect(shelf).to be_valid
    end

    it "rejects an unknown field" do
      shelf = build(:smart_shelf, rules: { "conditions" => [ condition("nonexistent_field", "equals", "x") ] })
      expect(shelf).not_to be_valid
      expect(shelf.errors[:rules].join).to match(/unknown field/)
    end

    it "rejects an unknown operator for an otherwise-known field" do
      shelf = build(:smart_shelf, rules: { "conditions" => [ condition("author", "regexp", "x") ] })
      expect(shelf).not_to be_valid
      expect(shelf.errors[:rules].join).to match(/unknown operator/)
    end

    it "rejects a non-whitelisted value shape (a Hash instead of a string/number)" do
      shelf = build(:smart_shelf, rules: { "conditions" => [ condition("author", "equals", { "$ne" => nil }) ] })
      expect(shelf).not_to be_valid
      expect(shelf.errors[:rules].join).to match(/value must be plain text/)
    end

    it "rejects a non-whitelisted value shape (an Array)" do
      shelf = build(:smart_shelf, rules: { "conditions" => [ condition("author", "equals", [ "a", "b" ]) ] })
      expect(shelf).not_to be_valid
    end

    it "rejects a value that doesn't fit the field's expected shape (a non-integer year)" do
      shelf = build(:smart_shelf, rules: { "conditions" => [ condition("published_year", "equals", "not-a-year") ] })
      expect(shelf).not_to be_valid
      expect(shelf.errors[:rules].join).to match(/invalid value/)
    end

    it "rejects an unknown read_state value" do
      shelf = build(:smart_shelf, rules: { "conditions" => [ condition("read_state", "equals", "on_fire") ] })
      expect(shelf).not_to be_valid
    end

    it "rejects a format value that isn't a real BookFile format" do
      shelf = build(:smart_shelf, rules: { "conditions" => [ condition("format", "equals", "exe") ] })
      expect(shelf).not_to be_valid
    end

    it "rejects malformed rules (not a Hash)" do
      shelf = build(:smart_shelf, rules: "DROP TABLE books;")
      expect(shelf).not_to be_valid
      expect(shelf.errors[:rules]).to be_present
    end

    it "rejects more than the maximum number of conditions" do
      too_many = Array.new(SmartShelf::MAX_CONDITIONS + 1) { condition("author", "equals", "x") }
      shelf = build(:smart_shelf, rules: { "conditions" => too_many })
      expect(shelf).not_to be_valid
    end

    # The whole point of the whitelist: a crafted field/op/value designed
    # to look like it might reach raw SQL is rejected by plain validation
    # long before any query runs — never a SQL-layer error.
    it "rejects a crafted injection-shaped field without ever reaching the database" do
      shelf = build(:smart_shelf, name: "Injection attempt",
        rules: { "conditions" => [ condition("id); DROP TABLE books;--", "equals", "x") ] })

      expect(shelf).not_to be_valid
      expect { shelf.save }.not_to change { SmartShelf.count }
      expect(Book.count).to eq(0)
      expect { Book.connection.execute("SELECT 1") }.not_to raise_error
    end

    it "rejects a crafted injection-shaped operator without ever reaching the database" do
      shelf = build(:smart_shelf, rules: { "conditions" => [ condition("author", "1=1; DROP TABLE books;--", "x") ] })
      expect(shelf).not_to be_valid
    end

    # A blank row (no field chosen) is filtered out before it ever reaches
    # SmartShelf — see SmartShelvesController#smart_shelf_params — but a
    # blank condition that does make it into `rules` (e.g. saved some
    # other way) is a validation error here, not a silent no-op: field
    # "" doesn't match anything in the whitelist.
    it "rejects a bare/blank condition rather than silently ignoring it" do
      shelf = build(:smart_shelf, rules: { "conditions" => [ {} ] })
      expect(shelf).not_to be_valid
      expect(shelf.errors[:rules].join).to match(/unknown field/)
    end
  end

  describe "#books" do
    it "never executes an unsafe query even if an invalid row is force-saved directly" do
      shelf = build(:smart_shelf, name: "Direct", position: 1)
      shelf.save!(validate: false)
      shelf.update_column(:rules, { "conditions" => [ condition("id); DROP TABLE books;--", "equals", "x") ] }.to_json)

      expect { shelf.reload.books.to_a }.not_to raise_error
      expect(shelf.reload.books.to_a).to eq([])
    end

    describe "author" do
      it "equals matches the exact author" do
        asimov = create(:book, author: "Isaac Asimov")
        create(:book, author: "Ursula K. Le Guin")
        shelf = create(:smart_shelf, rules: { "conditions" => [ condition("author", "equals", "Isaac Asimov") ] })
        expect(shelf.books).to contain_exactly(asimov)
      end

      it "contains matches a substring" do
        asimov = create(:book, author: "Isaac Asimov")
        create(:book, author: "Ursula K. Le Guin")
        shelf = create(:smart_shelf, rules: { "conditions" => [ condition("author", "contains", "Asim") ] })
        expect(shelf.books).to contain_exactly(asimov)
      end
    end

    describe "series" do
      it "equals matches the exact series" do
        foundation = create(:book, series: "Foundation")
        create(:book, series: "Discworld")
        shelf = create(:smart_shelf, rules: { "conditions" => [ condition("series", "equals", "Foundation") ] })
        expect(shelf.books).to contain_exactly(foundation)
      end
    end

    describe "category" do
      it "equals matches the exact category" do
        sf = create(:book, category: "fiction/sf")
        create(:book, category: "fiction/fantasy")
        shelf = create(:smart_shelf, rules: { "conditions" => [ condition("category", "equals", "fiction/sf") ] })
        expect(shelf.books).to contain_exactly(sf)
      end

      it "under matches every book under the given root" do
        sf = create(:book, category: "fiction/sf")
        fantasy = create(:book, category: "fiction/fantasy")
        cooking = create(:book, category: "practical/cooking")
        shelf = create(:smart_shelf, rules: { "conditions" => [ condition("category", "under", "fiction") ] })
        expect(shelf.books).to contain_exactly(sf, fantasy)
        expect(shelf.books).not_to include(cooking)
      end
    end

    describe "format" do
      it "matches books with a file of the given format" do
        book = create(:book)
        create(:book_file, book: book, format: "azw3")
        other = create(:book)
        create(:book_file, book: other, format: "epub")

        shelf = create(:smart_shelf, rules: { "conditions" => [ condition("format", "equals", "azw3") ] })
        expect(shelf.books).to contain_exactly(book)
      end
    end

    describe "language" do
      it "matches the exact language" do
        english = create(:book, language: "en")
        create(:book, language: "it")
        shelf = create(:smart_shelf, rules: { "conditions" => [ condition("language", "equals", "en") ] })
        expect(shelf.books).to contain_exactly(english)
      end
    end

    describe "published_year" do
      it "equals matches the exact year" do
        classic = create(:book, published_year: 1954)
        create(:book, published_year: 2020)
        shelf = create(:smart_shelf, rules: { "conditions" => [ condition("published_year", "equals", "1954") ] })
        expect(shelf.books).to contain_exactly(classic)
      end

      it "between matches an inclusive range" do
        in_range = create(:book, published_year: 1955)
        create(:book, published_year: 1930)
        create(:book, published_year: 2000)
        shelf = create(:smart_shelf, rules: { "conditions" => [ condition("published_year", "between", "1950,1960") ] })
        expect(shelf.books).to contain_exactly(in_range)
      end
    end

    describe "added_at" do
      it "after matches books added on/after the given date" do
        old = create(:book, created_at: Time.zone.local(2020, 1, 1))
        recent = create(:book, created_at: Time.zone.local(2026, 1, 1))
        shelf = create(:smart_shelf, rules: { "conditions" => [ condition("added_at", "after", "2025-01-01") ] })
        expect(shelf.books).to contain_exactly(recent)
        expect(shelf.books).not_to include(old)
      end

      it "between matches an inclusive date range" do
        in_range = create(:book, created_at: Time.zone.local(2023, 3, 1))
        create(:book, created_at: Time.zone.local(2020, 1, 1))
        shelf = create(:smart_shelf,
          rules: { "conditions" => [ condition("added_at", "between", "2023-01-01,2023-06-01") ] })
        expect(shelf.books).to contain_exactly(in_range)
      end
    end

    describe "read_state" do
      let!(:device) { create(:device) }

      it "currently_reading matches a book with unfinished progress" do
        reading = create(:book)
        create(:reading_state, book: reading, device: device, progress_percent: 40)
        finished = create(:book)
        create(:reading_state, book: finished, device: device, progress_percent: 99)
        never = create(:book)

        shelf = create(:smart_shelf, rules: { "conditions" => [ condition("read_state", "equals", "currently_reading") ] })
        expect(shelf.books).to contain_exactly(reading)
      end

      it "finished matches a book past the finished threshold" do
        finished = create(:book)
        create(:reading_state, book: finished, device: device, progress_percent: 99)
        reading = create(:book)
        create(:reading_state, book: reading, device: device, progress_percent: 40)

        shelf = create(:smart_shelf, rules: { "conditions" => [ condition("read_state", "equals", "finished") ] })
        expect(shelf.books).to contain_exactly(finished)
      end

      it "never_opened matches a book with no reading_states at all" do
        never = create(:book)
        reading = create(:book)
        create(:reading_state, book: reading, device: device, progress_percent: 40)

        shelf = create(:smart_shelf, rules: { "conditions" => [ condition("read_state", "equals", "never_opened") ] })
        expect(shelf.books).to contain_exactly(never)
      end
    end

    describe "has_highlights" do
      it "present matches a book with a highlight annotation" do
        device = create(:device)
        highlighted = create(:book)
        create(:annotation, book: highlighted, device: device, kind: "highlight")
        plain = create(:book)

        shelf = create(:smart_shelf, rules: { "conditions" => [ condition("has_highlights", "present") ] })
        expect(shelf.books).to contain_exactly(highlighted)
      end

      it "absent matches a book with no highlight annotation" do
        device = create(:device)
        highlighted = create(:book)
        create(:annotation, book: highlighted, device: device, kind: "highlight")
        plain = create(:book)

        shelf = create(:smart_shelf, rules: { "conditions" => [ condition("has_highlights", "absent") ] })
        expect(shelf.books).to contain_exactly(plain)
      end
    end

    describe "has_fulltext" do
      it "present matches indexed books" do
        indexed = create(:book, has_fulltext: true)
        create(:book, has_fulltext: false)
        shelf = create(:smart_shelf, rules: { "conditions" => [ condition("has_fulltext", "present") ] })
        expect(shelf.books).to contain_exactly(indexed)
      end
    end

    describe "combining conditions" do
      it "ANDs conditions together by default (match: all)" do
        asimov_sf = create(:book, author: "Isaac Asimov", category: "fiction/sf")
        asimov_other = create(:book, author: "Isaac Asimov", category: "practical")
        other_sf = create(:book, author: "Someone Else", category: "fiction/sf")

        shelf = create(:smart_shelf, rules: {
          "match" => "all",
          "conditions" => [ condition("author", "equals", "Isaac Asimov"), condition("category", "under", "fiction") ]
        })
        expect(shelf.books).to contain_exactly(asimov_sf)
      end

      it "ORs conditions together when match: any" do
        asimov = create(:book, author: "Isaac Asimov", published_year: 2020)
        old_book = create(:book, author: "Nobody", published_year: 1930)
        unrelated = create(:book, author: "Nobody", published_year: 2020)

        shelf = create(:smart_shelf, rules: {
          "match" => "any",
          "conditions" => [ condition("author", "equals", "Isaac Asimov"), condition("published_year", "equals", "1930") ]
        })
        expect(shelf.books).to contain_exactly(asimov, old_book)
      end
    end

    it "eager-loads book_files and conversions so rendering a page never N+1s" do
      book = create(:book, author: "Isaac Asimov")
      create(:book_file, book: book, format: "epub")
      shelf = create(:smart_shelf, rules: { "conditions" => [ condition("author", "equals", "Isaac Asimov") ] })

      resolved = shelf.books.to_a
      expect(resolved.first.association(:book_files)).to be_loaded
      expect(resolved.first.association(:conversions)).to be_loaded
    end

    it "returns Book.none when a shelf has zero conditions" do
      create(:book)
      shelf = create(:smart_shelf, rules: {})
      expect(shelf.books.to_a).to eq([])
    end
  end
end

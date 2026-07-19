require "rails_helper"

RSpec.describe "Library scan progress", type: :request do
  let!(:user) { create(:user) }

  before do
    post session_path, params: { email_address: user.email_address, password: "password" }
    # The show action's @catalog block queries SolidQueue::Job, but the
    # test database has no queue database configured (see
    # config/database.yml) and merely stubbing an ActiveRecord class makes
    # rspec-rails eagerly load its schema — so pre-seed the (:null_store
    # in test, otherwise a no-op) cache key with a real store instead,
    # which short-circuits Rails.cache.fetch before the block ever runs.
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    Rails.cache.write("catalog_counts", {
      books: 0, to_convert: 0, fulltext_missing: 0, duplicate_groups: 0,
      to_enrich: 0, embedded: nil, queued: 0, failed_conversions: 0
    })
    # The view's "Last scan" section only renders once SCAN_ROOTS is
    # configured (unset in test).
    allow(Library::Scan).to receive(:roots).and_return([ Pathname.new("/books") ])
  end

  after { Rails.cache = @previous_cache }

  it "surfaces the relocated count alongside imported/duplicate once a scan finishes" do
    allow(Library::Scan).to receive(:progress).and_return(
      state: "done", started_at: 1.minute.ago.to_i, finished_at: Time.current.to_i,
      done: 5, total: 5, counts: { imported: 3, duplicate: 1, relocated: 2, skipped: 0 }
    )

    get library_scan_path

    expect(response.body).to include("3 imported").and include("1 duplicate").and include("2 relocated")
  end

  it "hides the relocated stamp when nothing was relocated" do
    allow(Library::Scan).to receive(:progress).and_return(
      state: "done", started_at: 1.minute.ago.to_i, finished_at: Time.current.to_i,
      done: 2, total: 2, counts: { imported: 2, duplicate: 0, relocated: 0, skipped: 0 }
    )

    get library_scan_path

    expect(response.body).to include("2 imported")
    expect(response.body).not_to include("relocated")
  end

  it "does not render a counts line while a scan is still running" do
    allow(Library::Scan).to receive(:progress).and_return(
      state: "running", started_at: 1.minute.ago.to_i, done: 1, total: 5
    )

    get library_scan_path

    expect(response.body).not_to include("imported")
  end

  describe "catalog counts" do
    before do
      # Let the @catalog block in #show actually run instead of the
      # pre-seeded stub above.
      Rails.cache.delete("catalog_counts")
      # queued: SolidQueue::Job.where(...).count hits the same
      # no-queue-database-in-test wall as cancel_queued (see catalog_spec.rb) —
      # same verify_partial_doubles dance to stub it out.
      RSpec::Mocks.configuration.verify_partial_doubles = false
      allow(SolidQueue::Job).to receive(:where).and_return(double(count: 0))
      RSpec::Mocks.configuration.verify_partial_doubles = true
    end

    it "counts fulltext_missing off the has_fulltext flag rather than scanning the FTS index" do
      create(:book, has_fulltext: true)
      create(:book, has_fulltext: false)
      create(:book, has_fulltext: false)

      get library_scan_path

      expect(response.body).to include("Index full text (2)")
    end
  end
end

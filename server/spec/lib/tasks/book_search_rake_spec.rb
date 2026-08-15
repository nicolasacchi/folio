require "rails_helper"

# No rake-task spec precedent existed in this repo before this file — the
# task is loaded directly via Rake rather than through a dedicated harness.
RSpec.describe "book_search:rebuild_metadata" do
  before(:all) { Rails.application.load_tasks }

  let(:task) { Rake::Task["book_search:rebuild_metadata"] }

  after { task.reenable }

  # BookSearch.clear! (spec_helper's before(:each)) already leaves the FTS
  # DB empty, so a book carrying has_fulltext: true with no index_book! call
  # behind it is exactly the post-truncation state this task exists to fix.
  it "resets has_fulltext to false and queues re-extraction for an opted-in book left stale by a truncated search DB" do
    stale = create(:book, fulltext_enabled: true, has_fulltext: true)

    expect { task.invoke }
      .to have_enqueued_job(IndexBookJob).with(stale.id).exactly(:once)

    expect(stale.reload.has_fulltext).to be(false)
  end

  it "preserves already-stored fulltext for an opted-out book instead of wiping it" do
    disabled = create(:book, fulltext_enabled: false)
    BookSearch.index_book!(disabled, fulltext: "already extracted body text")

    expect { task.invoke }.not_to have_enqueued_job(IndexBookJob)

    expect(disabled.reload.has_fulltext).to be(true)
    expect(BookSearch.stored_fulltext(disabled.id)).to eq("already extracted body text")
  end

  it "is safe to re-run: a second pass does not clear fulltext extracted between runs" do
    book = create(:book, fulltext_enabled: true, has_fulltext: true)
    BookSearch.index_book!(book, fulltext: "real extracted text")

    task.invoke
    task.reenable
    task.invoke

    expect(book.reload.has_fulltext).to be(true)
    expect(BookSearch.stored_fulltext(book.id)).to eq("real extracted text")
  end
end

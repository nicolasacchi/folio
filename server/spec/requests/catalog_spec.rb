require 'rails_helper'

RSpec.describe "Catalog", type: :request do
  let!(:user) { create(:user) }

  before do
    post session_path, params: { email_address: user.email_address, password: "password" }
    # cancel_queued queries SolidQueue::{Ready,Scheduled,Blocked}Execution
    # directly, but (as in library_scan_progress_spec) the test database has
    # no queue database configured (see config/database.yml), so those
    # tables don't exist here. Normally rspec-rails' AR integration would
    # let a plain `allow(RealClass).to ...` through without touching the
    # DB, but this suite's verify_partial_doubles = true (spec_helper.rb)
    # makes it eagerly load the mocked class's schema to validate the
    # double — which fails against a table that doesn't exist. Disable
    # verification just long enough to stub these three classes' queries
    # to a no-op chain.
    RSpec::Mocks.configuration.verify_partial_doubles = false
    [ SolidQueue::ReadyExecution, SolidQueue::ScheduledExecution, SolidQueue::BlockedExecution ].each do |executions|
      allow(executions).to receive(:joins).and_return(double(where: double(find_each: nil)))
    end
    RSpec::Mocks.configuration.verify_partial_doubles = true
  end

  describe "POST /catalog/cancel_queued" do
    it "destroys pending conversions and fails conversions stuck in running" do
      book = create(:book)
      source = create(:book_file, book: book, format: "epub")
      pending = create(:conversion, book: book, book_file: source, target_format: "azw3", status: "pending")
      stuck = create(:conversion, book: book, book_file: source, target_format: "mobi", status: "running",
        started_at: 1.minute.ago)

      post catalog_cancel_queued_path

      expect(Conversion.exists?(pending.id)).to be(false)
      expect(stuck.reload).to be_failed
      expect(stuck.error).to eq("conversion timed out (worker stopped)")
      expect(response).to redirect_to(library_scan_path)
    end

    it "leaves conversions that are not pending/running untouched" do
      book = create(:book)
      source = create(:book_file, book: book, format: "epub")
      completed = create(:conversion, book: book, book_file: source, target_format: "azw3", status: "completed")

      post catalog_cancel_queued_path

      expect(completed.reload).to be_completed
    end
  end
end

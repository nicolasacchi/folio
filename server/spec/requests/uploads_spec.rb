require "rails_helper"

RSpec.describe "Uploads", type: :request do
  let!(:user) { create(:user) }

  before do
    post session_path, params: { email_address: user.email_address, password: "password" }
  end

  after do
    FileUtils.rm_rf(UploadsController::STASH_ROOT)
  end

  it "redirects back with an alert when no files are picked" do
    post uploads_path, params: { files: [] }

    expect(response).to redirect_to(new_upload_path)
    expect(flash[:alert]).to include("Pick at least one file")
  end

  it "stashes each file and enqueues one ingest job per file" do
    uploads = [
      fixture_file_upload("The Salt Road -- Ada Author.txt", "text/plain"),
      fixture_file_upload("The Salt Road -- Ada Author.txt", "text/plain")
    ]

    expect { post uploads_path, params: { files: uploads } }
      .to have_enqueued_job(IngestUploadJob).twice

    expect(Dir.glob(UploadsController::STASH_ROOT.join("*.txt")).size).to eq(2)
  end

  it "redirects to the shelf immediately with a background-import notice" do
    post uploads_path, params: { files: [ fixture_file_upload("The Salt Road -- Ada Author.txt", "text/plain") ] }

    expect(response).to redirect_to(root_path)
    expect(flash[:notice]).to include("imported in the background")
  end

  it "does not ingest inline — the book only exists once the job runs" do
    post uploads_path, params: { files: [ fixture_file_upload("The Salt Road -- Ada Author.txt", "text/plain") ] }

    expect(Book.count).to eq(0)
  end
end

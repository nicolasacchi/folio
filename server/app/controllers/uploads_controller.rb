class UploadsController < ApplicationController
  def new
  end

  def create
    files = Array(params[:files]).reject(&:blank?)
    return redirect_to new_upload_path, alert: "Pick at least one file." if files.empty?

    added, duplicates, failed = [], [], []
    files.each do |upload|
      result = Library::Ingest.call(upload.tempfile.path, original_filename: upload.original_filename)
      (result.duplicate? ? duplicates : added) << result.book
    rescue Library::Ingest::UnsupportedFormat => error
      failed << "#{upload.original_filename} (#{error.message})"
    end

    messages = []
    messages << "Added #{helpers.pluralize(added.size, 'book')}." if added.any?
    messages << "Skipped #{duplicates.size} already in the library." if duplicates.any?
    messages << "Failed: #{failed.join(', ')}" if failed.any?

    if added.one? && duplicates.empty? && failed.empty?
      redirect_to added.first, notice: messages.join(" ")
    else
      redirect_to root_path, notice: messages.join(" ")
    end
  end
end

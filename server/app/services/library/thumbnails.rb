# Kindle Library thumbnails, rendered from the book cover. The firmware
# looks for `/mnt/us/system/thumbnails/thumbnail_<ASIN>_<cdeType>_portrait.jpg`
# for EBOK content; the daemon installs what we generate here.
module Library
  module Thumbnails
    # Roughly what the store delivers; the firmware scales as needed.
    HEIGHT = 470

    module_function

    def root
      Library.base_root.join("thumbnails")
    end

    def path(book)
      root.join("#{book.public_id}.jpg")
    end

    # Generates (or refreshes) the cached thumbnail; returns nil without a
    # cover. Cheap staleness check: regenerate when the cover is newer.
    def ensure(book)
      cover = Library.cover_path(book)
      return nil unless File.exist?(cover)

      thumb = path(book)
      return thumb if File.exist?(thumb) && File.mtime(thumb) >= File.mtime(cover)

      FileUtils.mkdir_p(root)
      ImageProcessing::Vips
        .source(cover.to_s)
        .resize_to_limit(nil, HEIGHT)
        .convert("jpg")
        .saver(quality: 82, strip: true)
        .call(destination: thumb.to_s)
      thumb
    rescue LoadError, StandardError => error
      # No libvips (dev host) or a broken cover — the manifest simply
      # omits the thumbnail; everything else still works.
      Rails.logger.warn("thumbnail generation failed for #{book.public_id}: #{error.message}")
      nil
    end

    # The exact filename the firmware derives from the file's CDE identity.
    def kindle_filename(asin, cde_type)
      safe_asin = asin.to_s.gsub(/[^A-Za-z0-9._-]/, "")
      return nil if safe_asin.blank?
      "thumbnail_#{safe_asin}_#{cde_type.presence || 'EBOK'}_portrait.jpg"
    end
  end
end

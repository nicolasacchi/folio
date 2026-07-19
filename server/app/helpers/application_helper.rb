module ApplicationHelper
  # Annotation#location_label renders e.g. "page 12 · loc. 340–355" — "loc."
  # (a Kindle location, not a page number) is cryptic on its own, so wrap it
  # in an <abbr> the first time it'd otherwise be plain text.
  def location_label_html(annotation)
    label = annotation.location_label
    return nil if label.blank?

    safe_join(label.split(/(loc\.)/).map { |part|
      part == "loc." ? content_tag(:abbr, part, title: "Kindle location, not a page number") : part
    })
  end
end

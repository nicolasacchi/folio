# Loads config/library_taxonomy.yml (a frozen copy of
# docs/library-taxonomy.yml) — the shelf structure books.category paths
# are drawn from. Forward-compatible on purpose: a category the taxonomy
# doesn't (yet) know about (a new directory ahead of a taxonomy version
# bump) never raises, it just falls back to a humanized version of its
# path segments.
module Library::Taxonomy
  CONFIG_PATH = Rails.root.join("config", "library_taxonomy.yml")

  module_function

  def config
    @config ||= YAML.load_file(CONFIG_PATH) || {}
  end

  # root key => { "label" => ..., "label_en" => ..., "subs" => { key => {...} } },
  # in taxonomy (YAML) order.
  def categories
    @categories ||= (config["categories"] || {})
  end

  def known?(category)
    root, sub = category.to_s.split("/", 2)
    return false if root.blank? || !categories.key?(root)

    sub.nil? || subs_for(root).key?(sub)
  end

  def subs_for(root)
    (categories[root.to_s] || {})["subs"] || {}
  end

  # "fiction/sf" => "Fiction / Fantascienza" (root label + sub label); a
  # bare root ("fiction") returns just its label.
  def label_for(category)
    return nil if category.blank?

    root, sub = category.to_s.split("/", 2)
    label = entry_label(categories[root], root)
    return label if sub.nil?

    "#{label} / #{sub_label_for(root, sub)}"
  end

  def sub_label_for(root, sub)
    entry_label(subs_for(root)[sub], sub)
  end

  def entry_label(entry, key)
    (entry && (entry["label_en"] || entry["label"])) || key.to_s.humanize
  end
end

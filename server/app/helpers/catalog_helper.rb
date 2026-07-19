module CatalogHelper
  # Human labels for CatalogOperationJob's operation keys, for the Catalog
  # page's "Catalog operations" status line.
  CATALOG_OPERATION_LABELS = {
    "convert_all" => "Convert to Kindle format",
    "index_fulltext" => "Full-text indexing",
    "merge_duplicates" => "Merge duplicates",
    "enrich_all" => "Metadata enrichment",
    "embed_all" => "Semantic reindex"
  }.freeze

  def catalog_operation_label(operation)
    CATALOG_OPERATION_LABELS.fetch(operation.to_s, operation.to_s.tr("_", " "))
  end

  def catalog_state_stamp_class(state)
    case state.to_s
    when "done" then "stamp stamp--ready"
    when "failed" then "stamp stamp--failed"
    else "stamp stamp--pending"
    end
  end
end

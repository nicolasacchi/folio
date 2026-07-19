# The exact Content-Type strings OPDS 1.2 requires for each resource kind
# (OPDS 1.2 §7.1). A plain "application/atom+xml" is not enough — clients
# (KOReader, Thorium…) key off the `profile`/`kind` parameters to tell a
# navigation feed from an acquisition feed from a single entry document.
module Opds
  module ContentTypes
    NAVIGATION  = "application/atom+xml;profile=opds-catalog;kind=navigation"
    ACQUISITION = "application/atom+xml;profile=opds-catalog;kind=acquisition"
    ENTRY       = "application/atom+xml;type=entry;profile=opds-catalog"
    OPENSEARCH  = "application/opensearchdescription+xml"
  end
end

# Reciprocal Rank Fusion: combines two independently-ranked id lists (FTS
# BM25 results and vector/chunk-similarity results) into one ranking,
# without needing their scores to be on comparable scales — only each
# list's relative order matters. Pure and model/DB-independent on
# purpose, so the fusion logic is unit-testable with plain arrays of ids.
module Library::HybridSearch
  module_function

  # score(id) = sum, over every list the id appears in, of 1/(k + rank),
  # rank 1-based. k=60 is the RRF constant from Cormack et al. (2009):
  # large enough that the exact top rank in one list doesn't dominate,
  # small enough that being unranked in a list still costs something. An
  # id present near the top of both lists outranks one present near the
  # top of only one; an id missing from a list simply doesn't get that
  # list's contribution (no penalty term, no need for the lists to be the
  # same length).
  #
  # Ties (equal fused score — e.g. two ids each appearing in exactly one
  # list, both at the same rank) are broken deterministically by whichever
  # id was encountered first, scanning fts_ranked_ids then
  # vector_ranked_ids, so results are stable across calls with the same
  # inputs.
  def fuse(fts_ranked_ids, vector_ranked_ids, k: 60)
    scores = Hash.new(0.0)
    first_seen = {}

    [ fts_ranked_ids, vector_ranked_ids ].each_with_index do |ids, list_index|
      ids.each_with_index do |id, rank|
        scores[id] += 1.0 / (k + rank + 1)
        first_seen[id] ||= [ list_index, rank ]
      end
    end

    scores.keys.sort_by { |id| [ -scores[id], first_seen[id] ] }
  end
end

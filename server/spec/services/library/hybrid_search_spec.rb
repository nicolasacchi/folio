require 'rails_helper'

# Pure logic, no model/DB dependency — RRF only needs the relative order
# of each input list. Every expectation below is hand-computed from
# score(id) = sum over lists of 1/(k + 0-based-rank + 1).
RSpec.describe Library::HybridSearch do
  describe ".fuse" do
    it "ranks a doc found near the top of both lists above one found in only one" do
      fts = [ 1, 2, 3 ]
      vector = [ 1, 4, 5 ]

      fused = described_class.fuse(fts, vector)

      # id 1: 1/61 (fts) + 1/61 (vector) ~= 0.0328, far above any
      # single-list id's ~0.016.
      expect(fused.first).to eq(1)
    end

    it "includes ids missing from one of the two lists" do
      fts = [ 10, 20 ]
      vector = [ 30 ]

      fused = described_class.fuse(fts, vector)

      expect(fused).to contain_exactly(10, 20, 30)
    end

    it "ranks by the standard RRF score (1/(k+rank)) rather than raw rank sums" do
      # id 1: rank 1 in fts only -> 1/61
      # id 2: rank 2 in fts, rank 1 in vector -> 1/62 + 1/61 (higher, despite
      # never being #1 in either single list)
      fused = described_class.fuse([ 1, 2 ], [ 2 ])

      expect(fused).to eq([ 2, 1 ])
    end

    it "returns an empty ranking for two empty lists" do
      expect(described_class.fuse([], [])).to eq([])
    end

    it "is deterministic for ids exactly tied on fused score" do
      # id 10 (fts, rank 1) and id 30 (vector, rank 1) both score exactly
      # 1/61 — a genuine tie. First-seen order (fts scanned before vector)
      # breaks it in favor of id 10.
      fused = described_class.fuse([ 10, 20 ], [ 30 ])

      expect(fused).to eq([ 10, 30, 20 ])
    end

    it "weighs a strong single-list rank more heavily as k shrinks, and breadth across lists more as k grows" do
      fts = [ 1, 9, 2 ]
      vector = [ 7, 6, 2 ]
      # id 1: rank 1 in fts only. id 2: rank 3 in both lists.
      # k=60 (default): id1 = 1/61 ~= 0.0164; id2 = 2 * 1/63 ~= 0.0317 -> id2 wins.
      # k=0: id1 = 1/1 = 1.0; id2 = 2 * 1/3 ~= 0.667 -> id1 wins.
      expect(described_class.fuse(fts, vector).first).to eq(2)
      expect(described_class.fuse(fts, vector, k: 0).first).to eq(1)
    end
  end
end

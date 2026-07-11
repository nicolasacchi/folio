# Suggests which on-device books to remove when a Kindle runs low on
# space. The goal: keep `low_space_threshold_mb` free *after* the pending
# queue lands, sacrificing books the reader is done with first.
#
# Candidate order:
#   1. finished    — progress ≥ FINISHED_PERCENT (biggest first)
#   2. never opened — delivered ≥ NEVER_OPENED_AFTER ago, no reading state
#   3. dormant     — last opened ≥ DORMANT_AFTER ago (stalest first)
#
# Anything read recently or delivered recently is never suggested.
module Library
  class EvictionPlanner
    FINISHED_PERCENT = 95.0
    NEVER_OPENED_AFTER = 7.days
    DORMANT_AFTER = 45.days

    Suggestion = Struct.new(:delivery, :book, :size, :reason, keyword_init: true)

    def initialize(device)
      @device = device
    end

    # Bytes that must be freed to honor the threshold once pending
    # downloads land. Zero (or storage unknown) → empty plan.
    def needed_bytes
      return 0 unless @device.storage_known?
      shortfall = @device.low_space_threshold_bytes + @device.pending_bytes - @device.free_bytes
      [ shortfall, 0 ].max
    end

    def plan
      needed = needed_bytes
      return [] if needed.zero?

      picked = []
      freed = 0
      candidates.each do |suggestion|
        break if freed >= needed
        picked << suggestion
        freed += suggestion.size
      end
      picked
    end

    # All evictable books in priority order (the device page shows this
    # even when space is fine, as "what would go first").
    def candidates
      states = @device.reading_states.index_by(&:book_id)

      scored = @device.deliveries.on_device.includes(book: :book_files).filter_map do |delivery|
        book = delivery.book
        size = book.kindle_file&.size.to_i
        next if size.zero?

        state = states[book.id]
        rank = rank_for(delivery, state)
        next unless rank

        [ rank, Suggestion.new(delivery: delivery, book: book, size: size, reason: rank[:reason]) ]
      end

      scored.sort_by { |rank, suggestion| [ rank[:priority], rank[:order] ] }.map(&:last)
    end

    private

    def rank_for(delivery, state)
      if state&.progress_percent.to_f >= FINISHED_PERCENT
        { priority: 0, order: -state_size(delivery), reason: "finished" }
      elsif state.nil? && delivery.delivered_at <= NEVER_OPENED_AFTER.ago
        { priority: 1, order: -state_size(delivery), reason: "never opened" }
      elsif state && state.content_mtime <= DORMANT_AFTER.ago
        { priority: 2, order: state.content_mtime.to_i, reason: "dormant #{(Time.current - state.content_mtime).seconds.in_days.round} days" }
      end
    end

    def state_size(delivery)
      delivery.book.kindle_file&.size.to_i
    end
  end
end

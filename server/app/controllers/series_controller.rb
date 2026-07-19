class SeriesController < ApplicationController
  def index
    @series = Book.where.not(series: [ nil, "" ])
                  .group(:series)
                  .order(Arel.sql("lower(series)"))
                  .count

    # One representative cover per series, fetched in two queries total
    # (not one per row) so the grid below never N+1s: first the lowest
    # book id per series name, then those books in a single lookup.
    representative_ids = Book.where(series: @series.keys).group(:series).minimum(:id)
    @covers = Book.where(id: representative_ids.values).index_by(&:series)
  end
end

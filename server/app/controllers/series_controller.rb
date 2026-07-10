class SeriesController < ApplicationController
  def index
    @series = Book.where.not(series: [ nil, "" ])
                  .group(:series)
                  .order(Arel.sql("lower(series)"))
                  .count
  end
end

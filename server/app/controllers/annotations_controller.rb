# Browsable highlights & notes parsed from the devices' My Clippings.txt.
class AnnotationsController < ApplicationController
  PER_PAGE = 50

  def index
    @kind = Annotation::KINDS.include?(params[:kind]) ? params[:kind] : nil
    @query = params[:q].to_s.strip

    scope = Annotation.with_content.includes(:book, :device).recent
    scope = scope.where(kind: @kind) if @kind
    scope = scope.where("content LIKE ?", "%#{Annotation.sanitize_sql_like(@query)}%") if @query.present?

    @total = scope.count
    @page = [ params[:page].to_i, 1 ].max
    @annotations = scope.offset((@page - 1) * PER_PAGE).limit(PER_PAGE)
    @counts = Annotation.group(:kind).count
  end
end

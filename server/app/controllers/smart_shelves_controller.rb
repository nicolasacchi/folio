# Saved rule-based shelves — see SmartShelf for the whitelisted rule
# schema. #show renders the resolved books through the same shelf grid +
# pagination as BooksController#index (see app/views/books/_shelf_grid and
# _pager), just filtered/sorted server-side against a different scope.
class SmartShelvesController < ApplicationController
  before_action :set_smart_shelf, only: [ :show, :edit, :update, :destroy ]

  def index
    @smart_shelves = SmartShelf.ordered
  end

  def show
    @sort = BooksController::SORTS.include?(params[:sort]) ? params[:sort] : "recent"
    scope = @smart_shelf.books
    scope = case @sort
    when "title" then scope.order(Arel.sql("lower(title)"), :id)
    when "author" then scope.order(Arel.sql("lower(coalesce(author, ''))"), Arel.sql("lower(title)"), :id)
    else scope.order(created_at: :desc, id: :desc)
    end

    @total = scope.count
    @page = [ params[:page].to_i, 1 ].max
    @last_page = [ (@total / BooksController::PER_PAGE.to_f).ceil, 1 ].max
    @page = @last_page if @page > @last_page
    @books = scope.offset((@page - 1) * BooksController::PER_PAGE).limit(BooksController::PER_PAGE)
  end

  def new
    @smart_shelf = SmartShelf.new
  end

  def create
    @smart_shelf = SmartShelf.new(smart_shelf_params)
    if @smart_shelf.save
      redirect_to smart_shelves_path, notice: "“#{@smart_shelf.name}” created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @smart_shelf.update(smart_shelf_params)
      redirect_to smart_shelves_path, notice: "“#{@smart_shelf.name}” updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @smart_shelf.destroy!
    redirect_to smart_shelves_path, notice: "Smart shelf removed.", status: :see_other
  end

  private

  def set_smart_shelf
    @smart_shelf = SmartShelf.find(params[:id])
  end

  # The form posts parallel arrays (one entry per condition row) rather
  # than a raw JSON blob — Rails collects same-named `[]` params in DOM
  # order, so no per-row index bookkeeping is needed on either side. This
  # only shapes the params into the {match, conditions} structure
  # SmartShelf expects; SmartShelf's own whitelist validation (see
  # SmartShelf#rules_are_valid) still has the final say on what's safe to
  # save, exactly as it would for any other source of a `rules` hash.
  def smart_shelf_params
    raw = params.fetch(:smart_shelf, {})
    fields = Array(raw[:condition_field])
    ops = Array(raw[:condition_op])
    values = Array(raw[:condition_value])

    conditions = fields.each_index.filter_map do |i|
      next if fields[i].blank?
      { "field" => fields[i], "op" => ops[i].to_s, "value" => values[i].to_s }
    end

    {
      name: raw[:name],
      rules: { "match" => (raw[:match].presence_in(SmartShelf::MATCH_MODES) || "all"), "conditions" => conditions }
    }
  end
end

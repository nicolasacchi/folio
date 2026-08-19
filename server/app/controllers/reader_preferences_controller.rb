# Session-auth JSON endpoint for the web reader's display settings
# (font/theme/etc.). Mirrors ReaderController#update_position's CSRF +
# JSON shape; stored per-user on User#reader_preferences.
class ReaderPreferencesController < ApplicationController
  def update
    prefs = Current.user.update_reader_preferences!(preference_params)
    render json: prefs
  end

  private

  def preference_params
    raw = params[:preferences].presence || params
    raw.permit(
      :fontSize, :lineHeight, :margin, :theme, :flow, :fontFamily,
      :justify, :hyphenate, :keepScreenOn
    )
  end
end

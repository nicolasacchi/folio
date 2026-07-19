module DevicesHelper
  # Explains an eviction reason token produced by Library::EvictionPlanner
  # (see its criteria comment for the source of truth) as a tooltip for the
  # device and queue pages. Reasons the planner didn't produce itself
  # ("requested from web", "missing on device") aren't tied to a fixed
  # threshold, so they get no hint.
  def eviction_reason_hint(reason)
    case reason.to_s.delete_prefix("auto: ")
    when "finished"
      "Reading progress is #{Library::EvictionPlanner::FINISHED_PERCENT.to_i}% or higher."
    when "never opened"
      "Delivered more than #{Library::EvictionPlanner::NEVER_OPENED_AFTER.inspect} ago and still never opened."
    when /\Adormant \d+ days?\z/
      "Last opened more than #{Library::EvictionPlanner::DORMANT_AFTER.inspect} ago."
    end
  end

  # Renders an eviction reason with its hint as a title attribute, when one
  # applies — used anywhere a reason/evict_reason string is shown verbatim.
  def eviction_reason_span(reason, css_class: nil)
    hint = eviction_reason_hint(reason)
    content_tag(:span, reason, class: css_class, title: hint)
  end
end

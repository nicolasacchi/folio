require "rails_helper"
require "erb"
require "yaml"

# config/recurring.yml jobs declared with a plain `command:` run through
# SolidQueue::RecurringJob, which is hardcoded to `queue_as
# :solid_queue_recurring`. A task's own `queue:` option overrides that (see
# SolidQueue::RecurringTask#enqueue_options), but only if it's set to a
# queue a worker in config/queue.yml actually polls — otherwise the task is
# enqueued and simply never picked up.
RSpec.describe "config/recurring.yml" do
  def load_yaml(relative_path)
    rendered = ERB.new(Rails.root.join(relative_path).read).result
    YAML.safe_load(rendered, aliases: true)
  end

  let(:recurring_tasks) { load_yaml("config/recurring.yml").fetch("production") }
  let(:worker_queues) do
    load_yaml("config/queue.yml").fetch("production").fetch("workers").flat_map { |worker| Array(worker["queues"]) }
  end

  it "queues every command-based recurring task on a queue a worker actually consumes" do
    command_tasks = recurring_tasks.select { |_name, task| task.key?("command") }
    expect(command_tasks).not_to be_empty # sanity check: don't pass vacuously

    command_tasks.each do |name, task|
      expect(task["queue"]).to be_present, "#{name} has no queue: set, so it enqueues onto " \
        "solid_queue_recurring, which no worker in config/queue.yml polls"
      expect(worker_queues).to include(task["queue"]), "#{name} is queued on #{task["queue"].inspect}, " \
        "but config/queue.yml only has workers for #{worker_queues.sort.inspect}"
    end
  end
end

require 'rails_helper'

RSpec.describe DatabaseMaintenanceJob do
  it "delegates to DatabaseMaintenance.run!" do
    expect(DatabaseMaintenance).to receive(:run!).with(no_args)

    described_class.perform_now
  end

  # DatabaseMaintenance.run! rescues per-target, so even if a satellite
  # database contends with this example's own open transaction (the test
  # suite's "queue"/"cache" roles point at the same file as "primary" —
  # unlike development/production, which are separate files) the job
  # still completes without raising.
  it "runs against the real test database without raising" do
    expect { described_class.perform_now }.not_to raise_error
  end
end

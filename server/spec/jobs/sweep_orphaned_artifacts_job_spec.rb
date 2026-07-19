require 'rails_helper'

RSpec.describe SweepOrphanedArtifactsJob do
  it "delegates to Library::StorageGc.sweep!" do
    expect(Library::StorageGc).to receive(:sweep!).with(no_args)

    described_class.perform_now
  end
end

require 'rails_helper'

RSpec.describe DatabaseMaintenance do
  describe ".maintain" do
    it "checkpoints and reports ok when quick_check passes" do
      connection = double("connection")
      allow(connection).to receive(:execute).with("PRAGMA wal_checkpoint(TRUNCATE)")
        .and_return([ { "busy" => 0, "log" => 3, "checkpointed" => 3 } ])
      allow(connection).to receive(:execute).with("PRAGMA quick_check")
        .and_return([ { "quick_check" => "ok" } ])

      result = described_class.maintain(:primary, connection, quick_check: true)

      expect(result.label).to eq(:primary)
      expect(result.checkpoint).to eq({ "busy" => 0, "log" => 3, "checkpointed" => 3 })
      expect(result.quick_check).to eq("ok")
      expect(result).to be_ok
    end

    it "flags not-ok when quick_check reports a problem (array-row connections, e.g. a raw SQLite3::Database)" do
      connection = double("connection")
      allow(connection).to receive(:execute).with("PRAGMA wal_checkpoint(TRUNCATE)").and_return([ [ 0, 0, 0 ] ])
      allow(connection).to receive(:execute).with("PRAGMA quick_check")
        .and_return([ [ "row 3 missing from index books" ] ])

      result = described_class.maintain(:primary, connection, quick_check: true)

      expect(result).not_to be_ok
      expect(result.quick_check).to eq("row 3 missing from index books")
    end

    it "skips quick_check for satellite targets" do
      connection = double("connection")
      allow(connection).to receive(:execute).with("PRAGMA wal_checkpoint(TRUNCATE)").and_return([ [ 0, 0, 0 ] ])

      result = described_class.maintain(:queue, connection)

      expect(connection).not_to have_received(:execute).with("PRAGMA quick_check")
      expect(result.quick_check).to be_nil
      expect(result).to be_ok
    end

    it "rescues a failed target, logs at error level, and returns nil rather than raising" do
      connection = double("connection")
      allow(connection).to receive(:execute).and_raise(SQLite3::BusyException, "database is locked")

      expect(Rails.logger).to receive(:error).with(a_string_matching(/queue failed/))

      expect(described_class.maintain(:queue, connection)).to be_nil
    end
  end

  describe ".log" do
    it "logs info for an ok result" do
      result = described_class::Result.new(label: :primary, checkpoint: { "busy" => 0 }, quick_check: "ok")
      expect(Rails.logger).to receive(:info).with(a_string_matching(/primary checkpoint=.*quick_check=ok/))

      described_class.log(result)
    end

    it "logs at error level (not just info) for a not-ok quick_check" do
      result = described_class::Result.new(label: :primary, checkpoint: { "busy" => 0 }, quick_check: "corruption found")
      expect(Rails.logger).to receive(:error).with(a_string_matching(/quick_check=corruption found.*corrupt/))

      described_class.log(result)
    end
  end

  describe ".run!" do
    # Exercises the real primary connection — the same connection this
    # example's transactional fixture already holds open, so no
    # cross-connection lock contention — against the actual test database.
    it "runs the primary checkpoint + quick_check cleanly and returns an ok result" do
      allow(Rails.logger).to receive(:info).and_call_original

      results = described_class.run!

      primary = results.find { |r| r.label == :primary }
      expect(primary).to be_present
      expect(primary.quick_check).to eq("ok")
      expect(primary).to be_ok
      expect(Rails.logger).to have_received(:info).at_least(:once)
    end
  end
end

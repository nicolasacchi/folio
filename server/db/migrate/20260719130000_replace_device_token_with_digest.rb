class ReplaceDeviceTokenWithDigest < ActiveRecord::Migration[8.1]
  # The device API (Api::V1::BaseController) authenticates the kindled
  # daemon with a per-device token sent as plaintext in X-Api-Token. We
  # used to store that token verbatim in `devices.token`; a database leak
  # would hand over live credentials for every real Kindle. From here on
  # we store only a SHA-256 digest and look devices up by digest — see
  # Device.digest_token/.authenticate_by_token, which must compute the
  # exact same digest as this backfill so already-deployed daemons keep
  # authenticating with the plaintext token they already have.
  def up
    add_column :devices, :token_digest, :string

    # Backfill from the current plaintext `token` column, which still
    # exists at this point in the migration. update_columns bypasses
    # validations/callbacks so this is a pure data copy, not a resave.
    Device.reset_column_information
    Device.find_each do |device|
      device.update_columns(token_digest: Device.digest_token(device.token))
    end

    unmigrated = Device.where(token_digest: nil).count
    raise "token_digest backfill left #{unmigrated} device(s) null — aborting" if unmigrated.positive?

    add_index :devices, :token_digest, unique: true
    change_column_null :devices, :token_digest, false

    remove_index :devices, name: "index_devices_on_token"
    remove_column :devices, :token
  end

  def down
    # The plaintext token is unrecoverable from the digest — this only
    # restores the column shape, not any prior token value. Every device
    # would need a fresh token afterwards.
    add_column :devices, :token, :string
    add_index :devices, :token, unique: true

    remove_index :devices, name: "index_devices_on_token_digest"
    remove_column :devices, :token_digest
  end
end

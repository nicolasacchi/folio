class CreateKosync < ActiveRecord::Migration[8.1]
  def change
    # A KOReader "Custom sync server" account. Deliberately separate from
    # `users`: kosync clients authenticate with x-auth-user/x-auth-key (an
    # MD5-hex of the plaintext password, computed client-side — see
    # KosyncCredential), never the web session or a bcrypt(plaintext)
    # password. `user_id` is an optional link so a web-UI settings page can
    # show/own a household member's kosync credential without forcing a
    # 1:1 (a kosync username need not match an email, and not every kosync
    # account need be tied to a Folio login).
    create_table :kosync_credentials do |t|
      t.references :user, foreign_key: true, null: true
      t.string :username, null: false
      t.string :key_digest, null: false

      t.timestamps
    end
    add_index :kosync_credentials, :username, unique: true

    # One row per (credential, opaque document hash) — the kosync
    # protocol's whole unit of sync. `document` is a client-chosen opaque
    # digest (partial-md5 of the file's bytes, or md5 of its filename) that
    # the server never interprets or maps to a Folio Book (see
    # KosyncProgress). Every PUT unconditionally overwrites this row
    # (last-write-wins on the server-stamped `synced_at`), matching the
    # reference kosync server exactly — no per-device history here, unlike
    # `reading_states`.
    create_table :kosync_progresses do |t|
      t.references :kosync_credential, null: false, foreign_key: true
      t.string :document, null: false
      t.text :progress, null: false
      t.float :percentage, null: false
      t.string :device
      t.string :device_id
      t.text :metadata
      t.integer :synced_at, null: false

      t.timestamps
    end
    # The hot path (every PUT and GET): lookup by (credential, document).
    add_index :kosync_progresses, [ :kosync_credential_id, :document ], unique: true,
      name: "index_kosync_progresses_on_credential_and_document"
  end
end

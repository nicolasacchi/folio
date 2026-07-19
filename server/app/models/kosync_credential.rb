# A KOReader "Custom sync server" account — intentionally separate from
# User. KOReader always MD5-hashes the plaintext password client-side and
# sends that hex string as `x-auth-key` (see main.lua doRegister/doLogin);
# the server never sees the original password, so the only thing there is
# to authenticate is the MD5 hex itself. We store bcrypt(md5_hex) — never
# the md5 hex as-is (which is what the reference Lua/Redis server does) —
# so a database leak doesn't hand out a directly-replayable kosync key.
# Never reuse users.password_digest here: the web login never sees this
# MD5 hex, and this credential never sees the web password.
#
# Naming the has_secure_password attribute :key (-> key_digest column)
# means ActiveRecord::SecurePassword#authenticate_by — which keys off any
# "<attr>_digest" column, not just the default :password — works for free:
# KosyncCredential.authenticate_by(username:, key:), the same call shape
# Opds::BaseController already uses for User.
class KosyncCredential < ApplicationRecord
  has_secure_password :key, validations: false

  belongs_to :user, optional: true
  has_many :kosync_progresses, dependent: :destroy

  # Reference server rejects usernames containing ':' (it's a Redis key
  # separator there); we don't use Redis, but keep the same constraint so
  # behavior matches the protocol's expectations either way.
  validates :username, presence: true, uniqueness: true, format: { without: /:/, message: "must not contain ':'" }
  validates :key_digest, presence: true

  # Registration policy for POST /kosync/users/create. Defaults to open
  # (KOReader's built-in "Register" flow expects to just work — there's no
  # invite/admin-provisioning concept in the client), matching the official
  # sync.koreader.rocks service unless explicitly disabled. Flip to "false"
  # once this server is reachable beyond a trusted circle and you'd rather
  # provision kosync accounts by hand than let anyone with the URL sign up
  # — see README for the exposure this trades off.
  def self.open_registration?
    ENV["KOSYNC_OPEN_REGISTRATION"] != "false"
  end
end

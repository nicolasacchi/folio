class AddAdminToUsers < ActiveRecord::Migration[8.1]
  def up
    add_column :users, :admin, :boolean, null: false, default: false
    # Everyone who exists today (the seeded account) becomes an admin —
    # user management ships admin-gated and somebody must hold the keys.
    execute "UPDATE users SET admin = 1"
  end

  def down
    remove_column :users, :admin
  end
end

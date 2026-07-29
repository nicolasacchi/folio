class AddSharedKindlesAndPreferredDevice < ActiveRecord::Migration[8.1]
  def change
    add_reference :devices, :main_user, foreign_key: { to_table: :users, on_delete: :nullify }, index: true
    add_reference :users, :preferred_device, foreign_key: { to_table: :devices, on_delete: :nullify }, index: true

    reversible do |dir|
      dir.up do
        user_count = select_value("SELECT COUNT(*) FROM users").to_i
        if user_count == 1
          user_id = Integer(select_value("SELECT id FROM users LIMIT 1"))
          execute("UPDATE devices SET main_user_id = #{user_id} WHERE kind = 'kindle'")
        end
      end
    end
  end
end

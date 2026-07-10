# Idempotent bootstrap: one web user and one device token for the Kindle.
if User.none?
  email = ENV.fetch("ADMIN_EMAIL", "admin@kindle.local")
  password = ENV.fetch("ADMIN_PASSWORD") { SecureRandom.alphanumeric(16) }
  User.create!(email_address: email, password: password)
  puts "Created web user #{email} with password: #{password}"
  puts "(set ADMIN_EMAIL / ADMIN_PASSWORD to control these)"
end

if Device.none?
  device = Device.create!(name: "kindle-1")
  puts "Created device 'kindle-1' with API token: #{device.token}"
end

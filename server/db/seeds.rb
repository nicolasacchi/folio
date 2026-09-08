# Idempotent bootstrap: one web user and one device token for the Kindle.
if User.none?
  email = ENV.fetch("ADMIN_EMAIL", "admin@kindle.local")
  password = ENV["ADMIN_PASSWORD"].presence
  generated = password.nil?
  password ||= SecureRandom.alphanumeric(16)
  User.create!(email_address: email, password: password, admin: true)
  if generated
    # Only echo passwords we invented; provided ones must stay out of logs.
    puts "Created web user #{email} with password: #{password}"
    puts "(set ADMIN_EMAIL / ADMIN_PASSWORD to control these)"
  else
    puts "Created web user #{email} (password from ADMIN_PASSWORD)"
  end
end

if Device.none?
  device = Device.create!(name: "kindle-1")
  abort "Device 'kindle-1' was created but raw_token is blank — no API token to print" if device.raw_token.blank?
  puts "Created device 'kindle-1' with API token: #{device.raw_token}"
end

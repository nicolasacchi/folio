# Be sure to restart your server when you modify this file.

# Define an application-wide content security policy.
# See the Securing Rails Applications Guide for more information:
# https://guides.rubyonrails.org/security.html#content-security-policy-header

# Rails.application.configure do
#   config.content_security_policy do |policy|
#     policy.default_src :self, :https
#     policy.font_src    :self, :https, :data
#     policy.img_src     :self, :https, :data
#     policy.object_src  :none
#     policy.script_src  :self, :https
#     policy.style_src   :self, :https
#     # Specify URI for violation reports
#     # policy.report_uri "/csp-violation-report-endpoint"
#   end
#
#   # Generate session nonces for permitted importmap, inline scripts, and inline styles.
#   config.content_security_policy_nonce_generator = ->(request) { request.session.id.to_s }
#   config.content_security_policy_nonce_directives = %w(script-src style-src)
#
#   # Automatically add `nonce` to `javascript_tag`, `javascript_include_tag`, and `stylesheet_link_tag`
#   # if the corresponding directives are specified in `content_security_policy_nonce_directives`.
#   # config.content_security_policy_nonce_auto = true
#
#   # Report violations without enforcing the policy.
#   # config.content_security_policy_report_only = true
# end

# No app-wide policy (left off above, as generated) — most controllers here
# render nothing untrusted. ReaderController opts into its own, tighter
# policy (see its `content_security_policy` block) because foliate-js opens
# each book section in a `sandbox="allow-same-origin allow-scripts"` iframe
# whose `blob:` document is same-origin with this app and runs whatever
# script the book itself contains, with no sanitization. `script-src :self`
# there (no `unsafe-inline`) is what actually blocks that — inline
# `<script>` tags in book-supplied HTML can't carry a nonce, so they're
# rejected outright, while our own top-level page's importmap bootstrap
# script tags need one, which is what this nonce generator is for. Global
# and harmless everywhere else: importmap-rails' tag helpers always ask
# `request.content_security_policy_nonce` for a nonce, but Rails only
# emits a `Content-Security-Policy` header (and thus only enforces
# anything) for a request whose controller actually set one — every other
# controller here leaves `request.content_security_policy` nil, so this
# generator is simply never consulted for them.
Rails.application.configure do
  config.content_security_policy_nonce_generator = ->(request) { request.session.id.to_s }
  config.content_security_policy_nonce_directives = %w[script-src]
end

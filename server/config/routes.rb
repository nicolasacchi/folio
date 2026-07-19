Rails.application.routes.draw do
  resource :session
  resources :passwords, param: :token

  root "books#index"

  resources :books, only: [ :index, :show, :edit, :update, :destroy ] do
    member do
      get :cover
      get :download # ?fmt=azw3, defaults to the Kindle-ready file
      post :reindex # queue full-text extraction + reindex
    end
    resources :conversions, only: [ :create ]
  end
  # In-browser reader (web session auth — the device API is untouched).
  get    "books/:id/read"                        => "reader#show",      as: :read_book
  get    "books/:id/read/file"                   => "reader#file",      as: :read_book_file
  put    "books/:id/read/position"               => "reader#update_position", as: :read_book_position
  get    "books/:id/read/state"                  => "reader#state",           as: :read_book_state
  get    "books/:id/read/annotations"            => "reader_annotations#index"
  post   "books/:id/read/annotations"            => "reader_annotations#create"
  patch  "books/:id/read/annotations/:annotation_id" => "reader_annotations#update"
  delete "books/:id/read/annotations/:annotation_id" => "reader_annotations#destroy"
  patch  "books/:id/read/annotations/:annotation_id/locate" => "reader_annotations#locate"
  get    "lookup" => "lookups#show"

  resources :deliveries, only: [ :create, :destroy ]
  # Ask a device to delete a delivered book (rides the next manifest).
  resources :evictions, only: [ :create, :destroy ], param: :delivery_id
  resources :uploads, only: [ :new, :create ]
  resources :users, only: [ :index, :create, :update, :destroy ]
  resources :devices, only: [ :index, :create, :show, :update, :destroy ] do
    member do
      post :evict_suggested # apply the whole eviction plan in one tap
    end
  end

  get "queue", to: "queue#index", as: :queue

  get "series", to: "series#index", as: :series_index

  get "reading", to: "reading#index", as: :reading

  get "notes", to: "annotations#index", as: :annotations

  get "duplicates", to: "duplicates#index"
  post "duplicates/merge", to: "duplicates#merge", as: :merge_duplicates

  # Whole-catalog batch operations (buttons on the Catalog page).
  post "catalog/convert_all", to: "catalog#convert_all", as: :catalog_convert_all
  post "catalog/index_fulltext", to: "catalog#index_fulltext", as: :catalog_index_fulltext
  post "catalog/merge_duplicates", to: "catalog#merge_duplicates", as: :catalog_merge_duplicates
  post "catalog/enrich_all", to: "catalog#enrich_all", as: :catalog_enrich_all
  post "catalog/embed_all", to: "catalog#embed_all", as: :catalog_embed_all
  post "catalog/embed_chunks_all", to: "catalog#embed_chunks_all", as: :catalog_embed_chunks_all
  post "catalog/cancel_queued", to: "catalog#cancel_queued", as: :catalog_cancel_queued

  # Folder scanning (Komga-style: reference books in place from SCAN_ROOTS).
  resource :library_scan, only: [ :show, :create ] do
    post :prune
  end

  # Read-only OPDS 1.2 (Atom/XML) catalog for external readers (KOReader,
  # Thorium, Marvin, Panels, Calibre…). Deliberately its own top-level
  # namespace, not nested under /api/v1: different auth (HTTP Basic against
  # User, not a device token) and different content types (Atom/XML, not
  # JSON) — see Opds::BaseController.
  namespace :opds do
    root to: "catalog#root"

    get "new",             to: "catalog#new_books", as: :new_books
    get "books",           to: "catalog#books",     as: :books
    get "search",          to: "catalog#search",    as: :search
    get "opensearch.xml",  to: "catalog#opensearch", as: :opensearch

    get "authors",        to: "catalog#authors",  as: :authors
    get "authors/:name",  to: "catalog#author",   as: :author, constraints: { name: /[^\/]+/ }

    get "series",         to: "catalog#series_index", as: :series_index
    get "series/:name",   to: "catalog#series",       as: :series, constraints: { name: /[^\/]+/ }

    get "categories",       to: "catalog#categories", as: :categories
    get "categories/*path", to: "catalog#category",   as: :category

    get "entries/:public_id",           to: "catalog#entry",       as: :entry
    get "entries/:public_id/file",      to: "downloads#file",      as: :entry_file
    get "entries/:public_id/cover",     to: "downloads#cover",     as: :entry_cover
    get "entries/:public_id/thumbnail", to: "downloads#thumbnail", as: :entry_thumbnail
  end

  # KOReader's built-in progress-sync ("kosync") protocol. A user points
  # KOReader's "Custom sync server" setting at this Folio instance's
  # `https://<host>/kosync/` (trailing slash — KOReader's Spore client
  # appends these paths to that base URL verbatim) and these routes serve
  # exactly the paths the client calls: `/users/create`, `/users/auth`,
  # `/syncs/progress`, `/syncs/progress/:document`, `/healthcheck`. Its own
  # top-level namespace, not nested under /api/v1 or /opds: different auth
  # (x-auth-user/x-auth-key against KosyncCredential, not a device token or
  # HTTP Basic against User) — see Kosync::BaseController.
  namespace :kosync do
    post "users/create",             to: "users#create"
    get  "users/auth",               to: "users#auth"
    put  "syncs/progress",           to: "syncs#update", as: :sync_progress
    get  "syncs/progress/:document", to: "syncs#show", as: :sync_progress_document,
      constraints: { document: /[^\/]+/ }
    get  "healthcheck",              to: "health#show"
  end

  namespace :api do
    namespace :v1 do
      get "manifest", to: "manifests#show"
      get "queue_version", to: "queue_versions#show", as: :queue_version
      get "books/:public_id/file", to: "book_files#show", as: :book_file
      get "books/:public_id/thumbnail", to: "thumbnails#show", as: :book_thumbnail
      get "books/:public_id/reading_state", to: "reading_states#show", as: :book_reading_state
      put "books/:public_id/reading_state", to: "reading_states#update"
      post "device/status", to: "device_statuses#create", as: :device_status
      post "removals/:id/ack", to: "removals#ack", as: :ack_removal
      put "clippings", to: "clippings#update", as: :clippings
    end
  end

  # Health checks: /up for humans/monitors, /healthz for the Kindle daemon
  # (same endpoint name the Python prototype used).
  get "up" => "rails/health#show", as: :rails_health_check
  get "healthz" => "rails/health#show"
  # Deeper check (DB write + Solid Queue heartbeat) for humans/monitors —
  # the daemon itself only relies on the plain /healthz above.
  get "healthz/deep" => "health#deep"

  # PWA files so the web UI can be installed to a phone's home screen.
  get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker
end

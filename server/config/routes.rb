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
  resources :uploads, only: [ :new, :create ]
  resources :devices, only: [ :index, :create, :destroy ]

  get "series", to: "series#index", as: :series_index

  get "duplicates", to: "duplicates#index"
  post "duplicates/merge", to: "duplicates#merge", as: :merge_duplicates

  # Folder scanning (Komga-style: reference books in place from SCAN_ROOTS).
  resource :library_scan, only: [ :show, :create ] do
    post :prune
  end

  namespace :api do
    namespace :v1 do
      get "manifest", to: "manifests#show"
      get "books/:public_id/file", to: "book_files#show", as: :book_file
      get "books/:public_id/reading_state", to: "reading_states#show", as: :book_reading_state
      put "books/:public_id/reading_state", to: "reading_states#update"
    end
  end

  # Health checks: /up for humans/monitors, /healthz for the Kindle daemon
  # (same endpoint name the Python prototype used).
  get "up" => "rails/health#show", as: :rails_health_check
  get "healthz" => "rails/health#show"

  # PWA files so the web UI can be installed to a phone's home screen.
  get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker
end

Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  namespace :api do
    get "state", to: "state#show"
    get "hud", to: "hud#show"
    get "campus", to: "campus#show"
    post "commands", to: "commands#create"
    get "me", to: "me#show"
  end

  get "login", to: "sessions#new"
  post "login", to: "sessions#create"
  match "logout", to: "sessions#destroy", via: [:get, :delete]
  get "setup", to: "setup#new"
  post "setup", to: "setup#create"

  get "v/:ver/*path", to: "static#show", format: false

  root "home#show"
end

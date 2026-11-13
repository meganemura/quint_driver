Rails.application.routes.draw do
  root "parcels#index"

  resources :parcels, only: :index do
    resource :assignment, only: :create
    resource :release, only: :create
    resource :withdrawal, only: :create
  end
  resources :intakes, only: :create
end

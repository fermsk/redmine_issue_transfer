RedmineApp::Application.routes.draw do
  resources :projects do
    resource :issue_transfer, only: [:new, :create], controller: 'issue_transfer'
  end
  
  resource :issue_transfer, only: [:new, :create], controller: 'issue_transfer', path: 'issue_transfer'
end
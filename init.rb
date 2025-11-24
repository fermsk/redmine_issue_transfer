Redmine::Plugin.register :redmine_issue_transfer do
  name 'Redmine Issue Transfer plugin'
  author 'Ivan Zhelezny'
  description 'This plugin transfers issues from another Redmine instance'
  version '0.0.1'
  url 'http://gitlab.aladdin.ru/devops/infrastructure/redmine_6/redmine_issue_transfer.git'
  author_url 'http://gitlab.aladdin.ru'

  requires_redmine version_or_higher: '4.1.0'
  
  # Add to admin menu
  menu :admin_menu, :issue_transfer, 
       { controller: 'issue_transfer', action: 'new' }, 
       caption: 'Transfer Issues from Another Redmine', 
       html: { class: 'icon icon-move' }, 
       if: Proc.new { User.current.admin? }
  
  
  project_module :issue_transfer do
    permission :transfer_issues, { issue_transfer: [:new, :create] }, require: :member
  end
end
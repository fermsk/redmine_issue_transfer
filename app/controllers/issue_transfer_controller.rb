class IssueTransferController < ApplicationController
  before_action :require_admin_user
  before_action :find_project, only: [:new, :create]

  def new
    @transfer_config = IssueTransferConfig.new
  end

  def create
    @transfer_config = IssueTransferConfig.new(transfer_params)
    
    if @transfer_config.valid?
      begin
        transfer_service = IssueTransferService.new(@transfer_config)
        result = transfer_service.transfer_issues
        
        if result[:success]
          flash[:notice] = "Successfully transferred #{result[:count]} issues"
        else
          flash[:error] = "Transfer failed: #{result[:error]}"
        end
      rescue => e
        flash[:error] = "Transfer failed: #{e.message}"
        Rails.logger.error "Transfer error: #{e.message}\n#{e.backtrace.join("\n")}"
      end
    else
      render :new
      return
    end
    
    redirect_to new_issue_transfer_path
  end

  private

  def require_admin_user
    unless User.current.admin?
      render_403
      return false
    end
  end

  def find_project
    if params[:project_id]
      @project = Project.find(params[:project_id])
    else
      @project = Project.first
    end
  end

  def transfer_params
    params.require(:issue_transfer_config).permit(
      :source_url, :source_api_key, :source_version_id, 
      :target_project_id, :target_version_id, :fallback_assignee_id
    )
  end
end
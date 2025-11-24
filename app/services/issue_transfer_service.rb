# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'
require 'securerandom'

class IssueTransferService
  def initialize(config)
    @config = config
    @user_mapping = {}
    @tracker_mapping = {}
    @status_mapping = {}
    @priority_mapping = {}
    @source_trackers_cache = {}
    @source_statuses_cache = {}
    @source_priorities_cache = {}
    @created_issues_map = {} # To map source issue IDs to target issue IDs
  end

  def transfer_issues
    begin
      issues = fetch_issues_from_source
      transferred_count = 0
      parent_child_relations = []
      
      # First pass: create all issues without parent relationships
      issues.each do |issue|
        target_issue_id = transfer_single_issue(issue)
        if target_issue_id
          @created_issues_map[issue['id']] = target_issue_id
          transferred_count += 1
          
          # Store parent-child relationships for later processing
          if issue['parent'] && issue['parent']['id']
            parent_child_relations << {
              child_id: target_issue_id, 
              source_parent_id: issue['parent']['id']
            }
          end
        end
      end
      
      # Update parent-child relationships
      update_parent_child_relationships(parent_child_relations)
      
      # Transfer attachments and journals for all issues
      issues.each do |issue|
        if @created_issues_map[issue['id']]
          transfer_attachments(issue['id'], @created_issues_map[issue['id']])
          transfer_journals(issue['id'], @created_issues_map[issue['id']])
        end
      end
      
      { success: true, count: transferred_count }
    rescue => e
      Rails.logger.error "Transfer failed: #{e.message}\n#{e.backtrace.join("\n")}"
      { success: false, error: e.message }
    end
  end

  private

  def fetch_issues_from_source
    all_issues = []
    offset = 0
    limit = 100
    
    loop do
      issues_batch = fetch_issues_batch(offset, limit)
      break if issues_batch.empty?
      
      all_issues.concat(issues_batch)
      offset += limit
      
      # Break if we've got all issues
      break if issues_batch.length < limit
    end
    
    all_issues
  end

  def fetch_issues_batch(offset, limit)
    uri = URI.parse("#{@config.source_url}/issues.json")
    
    params = {
      'fixed_version_id' => @config.source_version_id, 
      'limit' => limit, 
      'offset' => offset, 
      'include' => 'attachments, relations, children, journals' # Include additional data
    }
    
    uri.query = URI.encode_www_form(params)
    
    request = Net::HTTP::Get.new(uri)
    request['X-Redmine-API-Key'] = @config.source_api_key
    
    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') do |http|
      http.request(request)
    end
    
    if response.code == '200'
      data = JSON.parse(response.body)
      data['issues'] || []
    else
      raise "Failed to fetch issues: #{response.code} - #{response.body}"
    end
  end

  def transfer_single_issue(source_issue)
    # Map users first
    #mapped_user_id = map_user(source_issue['assigned_to'])
    
    mapped_user_id = @config.fallback_assignee_id.presence&.to_i
    
    # Prepare the description with source information
    original_description = source_issue['description'] || ''
    source_info = "\n\n---\n*Issue transferred from external Redmine*\n"
    source_info += "*Source ID: #{source_issue['id']}*\n"
    source_info += "*Source URL: #{@config.source_url}*\n"
    source_info += "*Transfer Date: #{Time.current.strftime('%Y-%m-%d %H:%M:%S')}*"
    
    full_description = original_description + source_info
    
    # Prepare issue data
    issue_data = {
      issue: {
        subject: source_issue['subject'], 
        description: full_description, 
        project_id: @config.target_project_id.to_i, 
        tracker_id: map_tracker_by_name(source_issue['tracker']),    # Use tracker name directly
        status_id: map_status(source_issue['status']['id']), 
        priority_id: map_priority(source_issue['priority']['id']), 
        fixed_version_id: @config.target_version_id.to_i, 
        assigned_to_id: mapped_user_id, 
        category_id: map_category(source_issue['category']), 
        done_ratio: source_issue['done_ratio'] || 0, 
        estimated_hours: source_issue['estimated_hours'], 
        start_date: source_issue['start_date'], 
        due_date: source_issue['due_date']
        # Note: parent issue will be set later
      }.reject { |k, v| v.nil? }
    }
    
    # Create issue in target Redmine
    create_issue_in_target(issue_data)
  end

  # Enhanced tracker mapping that properly matches by name
  def map_tracker_by_name(source_tracker)
    return nil unless source_tracker
    
    # Check if we've already mapped this tracker
    return @tracker_mapping[source_tracker['id']] if @tracker_mapping.key?(source_tracker['id'])
    
    source_tracker_name = source_tracker['name']
    
    # Try to find tracker by exact name in target project
    target_project = Project.find(@config.target_project_id)
    target_tracker = target_project.trackers.find_by(name: source_tracker_name)
    
    # If not found, try case-insensitive match
    unless target_tracker
      target_tracker = target_project.trackers.find do |tracker|
        tracker.name.downcase == source_tracker_name.downcase
      end
    end
    
    # If still not found, try partial matching for common tracker types (Russian/English)
    unless target_tracker
      source_name_lower = source_tracker_name.downcase
      target_project.trackers.each do |tracker|
        tracker_name_lower = tracker.name.downcase
        if (source_name_lower.include?('bug') || source_name_lower.include?('ошибка')) && 
           (tracker_name_lower.include?('bug') || tracker_name_lower.include?('ошибка'))
          target_tracker = tracker
          break
        elsif (source_name_lower.include?('task') || source_name_lower.include?('задача')) && 
              (tracker_name_lower.include?('task') || tracker_name_lower.include?('задача'))
          target_tracker = tracker
          break
        elsif (source_name_lower.include?('feature') || source_name_lower.include?('требование')) && 
              (tracker_name_lower.include?('feature') || tracker_name_lower.include?('требование'))
          target_tracker = tracker
          break
        elsif (source_name_lower.include?('request') || source_name_lower.include?('запрос')) && 
              (tracker_name_lower.include?('request') || tracker_name_lower.include?('запрос'))
          target_tracker = tracker
          break
        elsif (source_name_lower.include?('build') || source_name_lower.include?('сборка')) && 
              (tracker_name_lower.include?('build') || tracker_name_lower.include?('сборка'))
          target_tracker = tracker
          break
         elsif (source_name_lower.include?('process') || source_name_lower.include?('процесс')) && 
              (tracker_name_lower.include?('process') || tracker_name_lower.include?('процесс'))
          target_tracker = tracker
          break
        end
      end
    end
    
    # If still not found, use first available tracker
    target_tracker ||= target_project.trackers.first
    target_tracker ||= Tracker.first
    
    if target_tracker
      @tracker_mapping[source_tracker['id']] = target_tracker.id
      Rails.logger.info "Mapped tracker: #{source_tracker['name']} -> #{target_tracker.name}"
      target_tracker.id
    else
      Rails.logger.warn "No tracker mapping found for #{source_tracker['name']}"
      # Fallback to ID 1
      @tracker_mapping[source_tracker['id']] = 1
      1
    end
  end

  def map_user(source_user)
    return nil unless source_user
    
    # Check if we've already mapped this user
    return @user_mapping[source_user['id']] if @user_mapping.key?(source_user['id'])
    
    # Try to find existing user by login only
    existing_user = User.find_by(login: source_user['login'])
    
    if existing_user
      @user_mapping[source_user['id']] = existing_user.id
      return existing_user.id
    end
    
    # If user cannot be found, return fallback assignee if specified
    if @config.fallback_assignee_id.present?
      fallback_user = User.find_by(id: @config.fallback_assignee_id)
      if fallback_user
        @user_mapping[source_user['id']] = fallback_user.id
        return fallback_user.id
      end
    end
    
    # Return nil if no user mapping possible
    nil
  end

  def map_status(source_status_id)
    return @status_mapping[source_status_id] if @status_mapping.key?(source_status_id)
    
    # Fetch source status info to get its name
    source_status = fetch_source_status(source_status_id)
    return nil unless source_status
    
    # Try to find status by exact name
    target_status = IssueStatus.find_by(name: source_status['name'])
    
    # If not found, try case-insensitive match
    unless target_status
      target_status = IssueStatus.where("LOWER(name) = ?", source_status['name'].downcase).first
    end
    
    # Try to find by similar status names (common mappings)
    unless target_status
      name_mapping = {
        'New' => ['new'], 
        'InProgress' => ['inprogress'], 
        'Done' => ['done'], 
        'Closed' => ['closed'], 
        'OnHold' => ['onhold'], 
        'Testing' => ['testing'], 
        'Completed' => ['completed'], 
        'Waiting' => ['waiting']
      }
      
      source_status_name = source_status['name'].downcase.strip
      name_mapping.each do |target_name, possible_names|
        if possible_names.include?(source_status_name)
          target_status = IssueStatus.find_by("LOWER(name) = ?", target_name.downcase)
          break if target_status
        end
      end
    end
    
    # If still not found, use default status
    target_status ||= IssueStatus.default_status || IssueStatus.first
    
    if target_status
      @status_mapping[source_status_id] = target_status.id
      target_status.id
    else
      # Fallback to any available status
      fallback_status = IssueStatus.first
      @status_mapping[source_status_id] = fallback_status&.id
      fallback_status&.id
    end
  end
  
  def map_priority(source_priority_id)
    return @priority_mapping[source_priority_id] if @priority_mapping.key?(source_priority_id)
    
    # Fetch source priority info to get its name
    source_priority = fetch_source_priority(source_priority_id)
    return nil unless source_priority
    
    # Try to find priority by exact name
    target_priority = IssuePriority.find_by(name: source_priority['name'])
    
    # If not found, try case-insensitive match
    unless target_priority
      target_priority = IssuePriority.where("LOWER(name) = ?", source_priority['name'].downcase).first
    end
    
    # Try to find by similar priority names (common mappings)
    unless target_priority
      name_mapping = {
        'Низкий' => ['low', 'низкий'], 
        'Нормальный' => ['normal', 'нормальный'], 
        'Высокий' => ['high', 'высокий'], 
        'Немедленный' => ['immediate', 'немедленный']
      }
      
      source_priority_name = source_priority['name'].downcase.strip
      name_mapping.each do |target_name, possible_names|
        if possible_names.include?(source_priority_name)
          target_priority = IssuePriority.find_by("LOWER(name) = ?", target_name.downcase)
          break if target_priority
        end
      end
    end
    
    # If still not found, use default priority
    target_priority ||= IssuePriority.first
    
    if target_priority
      @priority_mapping[source_priority_id] = target_priority.id
      target_priority.id
    else
      # Fallback to priority ID 2 (Normal)
      @priority_mapping[source_priority_id] = 2
      2
    end
  end
  
  def fetch_source_priority(priority_id)
    # Check cache first
    return @source_priorities_cache[priority_id] if @source_priorities_cache.key?(priority_id)
    
    begin
      uri = URI.parse("#{@config.source_url}/enumerations/issue_priorities.json")
      request = Net::HTTP::Get.new(uri)
      request['X-Redmine-API-Key'] = @config.source_api_key
      
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') do |http|
        http.request(request)
      end
      
      if response.code == '200'
        data = JSON.parse(response.body)
        priority = data['issue_priorities'].find { |p| p['id'] == priority_id }
        @source_priorities_cache[priority_id] = priority if priority
        priority || { 'id' => priority_id, 'name' => "Priority #{priority_id}" }
      else
        Rails.logger.warn "Failed to fetch priorities: #{response.code}"
        { 'id' => priority_id, 'name' => "Priority #{priority_id}" }
      end
    rescue => e
      Rails.logger.error "Error fetching priority #{priority_id}: #{e.message}"
      { 'id' => priority_id, 'name' => "Priority #{priority_id}" }
    end
  end

  def fetch_source_tracker(tracker_id)
    return @source_trackers_cache[tracker_id] if @source_trackers_cache.key?(tracker_id)
    
    uri = URI.parse("#{@config.source_url}/trackers/#{tracker_id}.json")
    request = Net::HTTP::Get.new(uri)
    request['X-Redmine-API-Key'] = @config.source_api_key
    
    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') do |http|
      http.request(request)
    end
    
    if response.code == '200'
      data = JSON.parse(response.body)
      @source_trackers_cache[tracker_id] = data['tracker']
    else
      Rails.logger.warn "Failed to fetch tracker #{tracker_id}: #{response.code}"
      @source_trackers_cache[tracker_id] = nil
    end
  rescue => e
    Rails.logger.error "Error fetching tracker #{tracker_id}: #{e.message}"
    @source_trackers_cache[tracker_id] = nil
  end
  
  def fetch_source_status(status_id)
    return @source_statuses_cache[status_id] if @source_statuses_cache.key?(status_id)
    
    uri = URI.parse("#{@config.source_url}/issue_statuses/#{status_id}.json")
    request = Net::HTTP::Get.new(uri)
    request['X-Redmine-API-Key'] = @config.source_api_key
    
    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') do |http|
      http.request(request)
    end
    
    if response.code == '200'
      data = JSON.parse(response.body)
      @source_statuses_cache[status_id] = data['issue_status']
    else
      Rails.logger.warn "Failed to fetch status #{status_id}: #{response.code}"
      @source_statuses_cache[status_id] = nil
    end
  rescue => e
    Rails.logger.error "Error fetching status #{status_id}: #{e.message}"
    @source_statuses_cache[status_id] = nil
  end
  
  def map_category(source_category)
    return nil unless source_category
    
    # Try to find existing category
    category = IssueCategory.find_by(
      project_id: @config.target_project_id, 
      name: source_category['name']
    )
    
    # Create if it doesn't exist
    unless category
      category = IssueCategory.create(
        project_id: @config.target_project_id, 
        name: source_category['name']
      )
    end
    
    category&.id
  end

#######-------------------create_issue_in_target

  def create_issue_in_target(issue_data)
    # Parse host properly
    host_info = parse_host_info(Setting.host_name)
    
    uri = URI::HTTP.build(
      host: host_info[:host],
      port: host_info[:port],
      scheme: Setting.protocol,
      path: '/issues.json'
    )
    
    request = Net::HTTP::Post.new(uri)
    request['X-Redmine-API-Key'] = User.current.api_key
    request['Content-Type'] = 'application/json'
    #request['Accept'] = 'application/json'  # Add Accept header
    request.body = issue_data.to_json
    
    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') do |http|
      http.request(request)
    end
    
    if response.code == '201'
      data = JSON.parse(response.body)
      data['issue']['id'] # Return the created issue ID
    else
      Rails.logger.error "Failed to create issue: #{response.code} - #{response.body}"
      nil
    end
  end

  def update_parent_child_relationships(relations)
    relations.each do |relation|
      begin
        target_parent_id = @created_issues_map[relation[:source_parent_id]]
        if target_parent_id
          update_issue_parent(relation[:child_id], target_parent_id)
        end
      rescue => e
        Rails.logger.error "Failed to update parent-child relationship for issue #{relation[:child_id]}: #{e.message}"
      end
    end
  end

  
  
  def update_issue_parent(issue_id, parent_id)
    # Parse host properly
    host_info = parse_host_info(Setting.host_name)
    
    uri = URI::HTTP.build(
      host: host_info[:host],
      port: host_info[:port],
      scheme: Setting.protocol,
      path: "/issues/#{issue_id}.json"
    )
    
    issue_data = {
      issue: {
        parent_issue_id: parent_id
      }
    }
    
    request = Net::HTTP::Put.new(uri)
    request['X-Redmine-API-Key'] = User.current.api_key
    request['Content-Type'] = 'application/json'
    #request['Accept'] = 'application/json'  # Add Accept header
    request.body = issue_data.to_json
    
    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') do |http|
      http.request(request)
    end
    
    # HTTP 204 is actually a success response for PUT requests
    if response.code == '200' || response.code == '204'
      Rails.logger.info "Successfully updated parent for issue #{issue_id} to parent #{parent_id}"
    else
      Rails.logger.error "Failed to update parent for issue #{issue_id}: #{response.code} - #{response.body}"
    end
  end

  def transfer_attachments(source_issue_id, target_issue_id)
    begin
      Rails.logger.info "Transferring attachments from source issue #{source_issue_id} to target issue #{target_issue_id}"
      
      # Fetch issue details with attachments
      uri = URI.parse("#{@config.source_url}/issues/#{source_issue_id}.json?include=attachments")
      request = Net::HTTP::Get.new(uri)
      request['X-Redmine-API-Key'] = @config.source_api_key
      
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') do |http|
        http.request(request)
      end
      
      if response.code == '200'
        data = JSON.parse(response.body)
        attachments = data['issue']['attachments'] || []
        
        Rails.logger.info "Found #{attachments.length} attachments for source issue #{source_issue_id}"
        
        attachments.each do |attachment|
          download_and_upload_attachment(attachment, target_issue_id)
        end
      else
        Rails.logger.error "Failed to fetch issue with attachments. Status: #{response.code}, Response: #{response.body}"
      end
    rescue => e
      Rails.logger.error "Error transferring attachments for issue #{source_issue_id}: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
    end
  end

#####------------download_and_upload_attachment
  
  def download_and_upload_attachment(source_attachment, target_issue_id)
    begin
      Rails.logger.info "Processing attachment: #{source_attachment['filename']} (ID: #{source_attachment['id']})"
      
      # Download attachment content
      content_url = source_attachment['content_url']
      if content_url.nil? || content_url.empty?
        Rails.logger.error "No content URL for attachment: #{source_attachment['filename']}"
        return
      end
      
      download_uri = URI.parse(content_url)
      download_request = Net::HTTP::Get.new(download_uri)
      download_request['X-Redmine-API-Key'] = @config.source_api_key
      #download_request['Accept'] = '*/*'
      
      download_response = Net::HTTP.start(download_uri.hostname, download_uri.port, use_ssl: download_uri.scheme == 'https') do |http|
        http.request(download_request)
      end
      
      if download_response.code == '200'
        Rails.logger.info "Successfully downloaded attachment: #{source_attachment['filename']} (#{download_response.body.length} bytes)"
        
        # Ensure we're working with binary data
        file_content = download_response.body
        if file_content.encoding != Encoding::ASCII_8BIT
          file_content = file_content.force_encoding(Encoding::ASCII_8BIT)
        end
        
        # Upload to target issue
        upload_result = upload_file_to_redmine(file_content, source_attachment['filename'], source_attachment['content_type'])
        
        if upload_result[:success]
          token = upload_result[:token]
          if token
            attach_issue_with_upload(target_issue_id, source_attachment, token)
          else
            Rails.logger.error "No token received from upload for #{source_attachment['filename']}"
          end
        else
          Rails.logger.error "Failed to upload #{source_attachment['filename']}: #{upload_result[:error]}"
        end
      else
        Rails.logger.error "Failed to download attachment #{source_attachment['filename']}. Status: #{download_response.code}"
        Rails.logger.error "Response: #{download_response.body}"
      end
    rescue => e
      Rails.logger.error "Error processing attachment #{source_attachment['filename']}: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
    end
  end
 
  
  def upload_attachment_to_target_improved(target_issue_id, source_attachment, file_content)
    begin
      Rails.logger.info "Uploading attachment to target using improved method: #{source_attachment['filename']}"
      
      # Use Redmine's built-in file upload mechanism instead of manual multipart
      upload_result = upload_file_to_redmine(file_content, source_attachment['filename'], source_attachment['content_type'])
      
      if upload_result[:success]
        token = upload_result[:token]
        if token
          Rails.logger.info "File uploaded successfully, got token: #{token}"
          # Attach to issue
          attach_issue_with_upload(target_issue_id, source_attachment, token)
        else
          Rails.logger.error "No token received from upload"
        end
      else
        Rails.logger.error "Failed to upload file: #{upload_result[:error]}"
      end
      
    rescue => e
      Rails.logger.error "Error in improved upload method: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
    end
  end

#####------------upload_file_to_redmine

  def upload_file_to_redmine(file_content, filename, content_type = nil)
    begin
      Rails.logger.info "Uploading file to Redmine: #{filename}"
      Rails.logger.debug "File size: #{file_content.length} bytes"
      Rails.logger.debug "Original content type: #{content_type}"
      
      # Parse host information
      host_info = parse_host_info(Setting.host_name)
      
      # Sanitize filename for URL encoding
      sanitized_filename = filename.gsub(/[^\w\.\-\(\)\u0400-\u04FF\u00C0-\u00FF]/, '_')
      
      # Build the upload URI correctly using URI.encode_www_form for query parameters
      upload_uri = URI::HTTP.build(
        host: host_info[:host],   
        port: host_info[:port],   
        scheme: Setting.protocol,   
        path: '/uploads.json',   
        query: URI.encode_www_form({filename: sanitized_filename})
      )
      
      Rails.logger.info "Constructed upload URI: #{upload_uri}"
      
      # Create upload request with proper headers
      upload_request = Net::HTTP::Post.new(upload_uri)
      upload_request['X-Redmine-API-Key'] = User.current.api_key
      # IMPORTANT: For uploads, Content-Type should be application/octet-stream, not the file's content type
      upload_request['Content-Type'] = 'application/octet-stream'
      upload_request['Accept'] = 'application/json'
      
      # Add User-Agent header to avoid potential filtering
      upload_request['User-Agent'] = 'Redmine Issue Transfer Plugin'
      
      # Ensure file content is in the correct encoding
      if file_content.is_a?(String) && file_content.encoding != Encoding::ASCII_8BIT
        file_content = file_content.dup.force_encoding(Encoding::ASCII_8BIT)
      end
      
      upload_request.body = file_content
      
      Rails.logger.debug "Request headers: #{upload_request.to_hash}"
      Rails.logger.debug "Content-Type header: #{upload_request['Content-Type']}"
      Rails.logger.debug "Accept header: #{upload_request['Accept']}"
      
      # Make the upload request with timeout settings
      upload_response = Net::HTTP.start(upload_uri.hostname, upload_uri.port,    
                                      use_ssl: upload_uri.scheme == 'https',  
                                      open_timeout: 30,   
                                      read_timeout: 60) do |http|
        http.request(upload_request)
      end
      
      Rails.logger.info "Upload response status: #{upload_response.code}"
      Rails.logger.debug "Upload response headers: #{upload_response.to_hash}"
      Rails.logger.debug "Upload response body: #{upload_response.body}"
      
      case upload_response.code
      when '201'
        begin
          upload_data = JSON.parse(upload_response.body)
          token = upload_data['upload']['token']
          if token
            Rails.logger.info "Successfully obtained upload token: #{token}"
            { success: true, token: token }
          else
            Rails.logger.error "No token in upload response: #{upload_response.body}"
            { success: false, error: "No token in response" }
          end
        rescue JSON::ParserError => e
          Rails.logger.error "Failed to parse JSON response: #{e.message}"
          Rails.logger.error "Response body: #{upload_response.body}"
          { success: false, error: "Invalid JSON response from server" }
        end
      when '406'
        Rails.logger.error "406 Not Acceptable - Server doesn't accept the request format"
        Rails.logger.error "This might be due to missing headers or server configuration"
        Rails.logger.error "Response body length: #{upload_response.body&.length || 0}"
        Rails.logger.error "Request headers sent: #{upload_request.to_hash}"
        { success: false, error: "Server rejected request (406): Check server configuration and headers" }
      when '401', '403'
        Rails.logger.error "#{upload_response.code} - Authentication/Authorization error"
        Rails.logger.error "API Key may be invalid or insufficient permissions"
        { success: false, error: "Authentication failed (#{upload_response.code}): Check API key and permissions" }
      when '400'
        Rails.logger.error "400 - Bad Request"
        Rails.logger.error "Response: #{upload_response.body}"
        { success: false, error: "Bad request (400): #{upload_response.body}" }
      when '413'
        Rails.logger.error "413 - Request Entity Too Large"
        Rails.logger.error "File may be too large for server configuration"
        { success: false, error: "File too large (413): Check server file size limits" }
      when '500'
        Rails.logger.error "500 - Internal Server Error"
        Rails.logger.error "Response: #{upload_response.body}"
        { success: false, error: "Server error (500): #{upload_response.body}" }
      else
        Rails.logger.error "Upload failed with unexpected status #{upload_response.code}"
        Rails.logger.error "Response body: #{upload_response.body}"
        Rails.logger.error "Response headers: #{upload_response.to_hash}"
        { success: false, error: "HTTP #{upload_response.code}: #{upload_response.body}" }
      end
      
    rescue URI::InvalidURIError => e
      Rails.logger.error "URI encoding error for filename: #{filename}"
      Rails.logger.error "Error details: #{e.message}"
      { success: false, error: "URI encoding failed: #{e.message}" }
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      Rails.logger.error "Timeout error during upload: #{e.message}"
      { success: false, error: "Timeout during upload: #{e.message}" }
    rescue => e
      Rails.logger.error "Error uploading file to Redmine: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      { success: false, error: e.message }
    end
  end
#####------------upload_file_to_redmine  

#####------------attach_issue_with_upload  
  
  def attach_issue_with_upload(target_issue_id, source_attachment, token)
    begin
      # Parse host information properly
      host_info = parse_host_info(Setting.host_name)
      
      # Build URI using proper components
      uri_components = {
        host: host_info[:host],  
        scheme: Setting.protocol,  
        path: "/issues/#{target_issue_id}.json"
      }
      
      # Only add port if it's non-standard
      if host_info[:port] && 
         ((Setting.protocol == 'https' && host_info[:port] != 443) || 
          (Setting.protocol == 'http' && host_info[:port] != 80))
        uri_components[:port] = host_info[:port]
      end
      
      attach_uri = URI::HTTP.build(uri_components)
      
      attach_data = {
        issue: {
          uploads: [{
            token: token,   
            filename: source_attachment['filename'],   
            content_type: source_attachment['content_type'] || 'application/octet-stream',   
            description: source_attachment['description'] || ''
          }]
        }
      }
      
      attach_request = Net::HTTP::Put.new(attach_uri)
      attach_request['X-Redmine-API-Key'] = User.current.api_key
      attach_request['Content-Type'] = 'application/json'
      attach_request['Accept'] = 'application/json'
      attach_request.body = attach_data.to_json
      
      attach_response = Net::HTTP.start(attach_uri.hostname, attach_uri.port,   
                                       use_ssl: attach_uri.scheme == 'https') do |http|
        http.request(attach_request)
      end
      
      if attach_response.code == '200' || attach_response.code == '204'
        Rails.logger.info "Successfully attached file to target issue #{target_issue_id}"
        return true
      else
        Rails.logger.error "Failed to attach file to issue #{target_issue_id}. Status: #{attach_response.code}"
        Rails.logger.error "Response: #{attach_response.body}"
        Rails.logger.error "Response headers: #{attach_response.to_hash}"
        return false
      end
    rescue => e
      Rails.logger.error "Error attaching file to issue: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      return false
    end
  end
#####------------attach_issue_with_upload  
  
  def add_note_to_target_issue(target_issue_id, note, created_on, author_name)
    begin
      # Parse host information properly
      host_info = parse_host_info(Setting.host_name)
      
      # Build URI using proper components
      uri_components = {
        host: host_info[:host], 
        scheme: Setting.protocol, 
        path: "/issues/#{target_issue_id}.json"
      }
      
      # Only add port if it's non-standard
      if host_info[:port] && 
         ((Setting.protocol == 'https' && host_info[:port] != 443) || 
          (Setting.protocol == 'http' && host_info[:port] != 80))
        uri_components[:port] = host_info[:port]
      end
      
      uri = URI::HTTP.build(uri_components)
      
      note_with_author = "#{note}\n\n[Note from #{author_name || 'Unknown'} on #{created_on || Time.current.strftime('%Y-%m-%d %H:%M:%S')}]"
      
      issue_data = {
        issue: {
          notes: note_with_author
        }
      }
      
      request = Net::HTTP::Put.new(uri)
      request['X-Redmine-API-Key'] = '987f1c47c83fad54538f060aadaa7238812a2ed4'
      request['Content-Type'] = 'application/json'
      # request['Accept'] = 'application/json'
      request.body = issue_data.to_json
      
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') do |http|
        http.request(request)
      end
      
      # HTTP 204 is actually a success response for PUT requests
      if response.code == '200' || response.code == '204'
        Rails.logger.info "Successfully added note to target issue #{target_issue_id}"
      else
        Rails.logger.error "Failed to add note to target issue #{target_issue_id}: #{response.code} - #{response.body}"
      end
    rescue => e
      Rails.logger.error "Error adding note to target issue: #{e.message}"
    end
  end

  
  def transfer_journals(source_issue_id, target_issue_id)
    begin
      # Fetch journals from source issue
      uri = URI.parse("#{@config.source_url}/issues/#{source_issue_id}.json?include=journals")
      request = Net::HTTP::Get.new(uri)
      request['X-Redmine-API-Key'] = @config.source_api_key
      
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') do |http|
        http.request(request)
      end
      
      if response.code == '200'
        data = JSON.parse(response.body)
        journals = data['issue']['journals'] || []
        
        # Add each journal entry as a note to the target issue
        journals.each do |journal|
          if journal['notes'] && !journal['notes'].strip.empty?
            add_note_to_target_issue(target_issue_id, journal['notes'], journal['created_on'], journal['user']&.[]('name'))
          end
        end
      end
    rescue => e
      Rails.logger.error "Error transferring journals: #{e.message}"
    end
  end

  
  def parse_host_info(host_string)
    begin
      Rails.logger.debug "Parsing host string:  #{host_string.inspect}"
      
      # Convert to string and clean it up
      host_str = host_string.to_s.strip
      
      # Remove surrounding brackets, quotes, and other problematic characters
      host_str = host_str.gsub(/[\[\]"'`]/, '').gsub(/\s+/, '')
      
      # Handle the case where we have a full URL
      if host_str.match?(/\Ahttps?:\/\//)
        uri = URI.parse(host_str)
        host = uri.host
        port = uri.port
      else
        # Handle various host:port formats
        host, port_str = host_str.split(':', 2)
        
        # Clean the host
        host = host.gsub(/[\[\]]/, '') if host
        
        # Parse port if provided
        if port_str && !port_str.empty?
          port = port_str.to_i
          # Validate port
          if port <= 0 || port > 65535
            port = (Setting.protocol == 'https') ? 443 : 80
          end
        else
          port = (Setting.protocol == 'https') ? 443 : 80
        end
      end
      
      # Validate and set defaults if needed
      host = host.to_s.strip
      if host.empty?
        host = 'localhost'
        port = (Setting.protocol == 'https') ? 443 : 80
      end
      
      Rails.logger.debug "Final parsed host:  #{host},  port:  #{port}"
      { host:  host,  port:  port }
      
    rescue URI::InvalidURIError => e
      Rails.logger.error "URI parsing error for host '#{host_string}':  #{e.message}"
      # Try to extract host manually
      manual_host = host_string.to_s.gsub(/[\[\]"'`]/, '').gsub(/\s+/, '').split(':').first || 'localhost'
      manual_port = (Setting.protocol == 'https') ? 443 : 80
      Rails.logger.info "Using manual parsing:  host=#{manual_host},  port=#{manual_port}"
      { host:  manual_host,  port:  manual_port }
    rescue => e
      Rails.logger.error "Unexpected error parsing host info '#{host_string}':  #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      # Safe fallback
      { host:  'localhost',  port:  (Setting.protocol == 'https') ? 443 : 80 }
    end
  end
end
#!/usr/bin/env ruby

require 'net/http'
require 'json'
require 'uri'

class AttachmentTransferTest
  def initialize(source_url, source_api_key)
    @source_url = source_url
    @source_api_key = source_api_key
  end

  def test_attachment_transfer(source_issue_id)
    puts "Testing attachment transfer for issue #{source_issue_id}"
    puts "=" * 50
    
    # 1. Fetch issue with attachments
    attachments = fetch_issue_attachments(source_issue_id)
    return unless attachments && !attachments.empty?
    
    # 2. Test first attachment
    first_attachment = attachments.first
    puts "Testing attachment: #{first_attachment['filename']}"
    puts "Content URL: #{first_attachment['content_url']}"
    
    # 3. Download attachment
    file_content = download_attachment(first_attachment)
    return unless file_content
    
    puts "Downloaded #{file_content.length} bytes successfully"
    
    # 4. Try to upload to target (this is where it's failing)
    test_upload_to_target(file_content, first_attachment['filename'])
  end

  private

  def fetch_issue_attachments(issue_id)
    begin
      uri = URI.parse("#{@source_url}/issues/#{issue_id}.json?include=attachments")
      request = Net::HTTP::Get.new(uri)
      request['X-Redmine-API-Key'] = @source_api_key
      
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == 'https') do |http|
        http.request(request)
      end
      
      if response.code == '200'
        data = JSON.parse(response.body)
        attachments = data['issue']['attachments'] || []
        puts "Found #{attachments.length} attachments"
        attachments
      else
        puts "Failed to fetch issue: #{response.code} - #{response.body}"
        nil
      end
    rescue => e
      puts "Error fetching issue: #{e.message}"
      nil
    end
  end

  def download_attachment(attachment)
    begin
      content_url = attachment['content_url']
      if content_url.nil? || content_url.empty?
        puts "No content URL for attachment"
        return nil
      end
      
      download_uri = URI.parse(content_url)
      download_request = Net::HTTP::Get.new(download_uri)
      download_request['X-Redmine-API-Key'] = @source_api_key
      
      download_response = Net::HTTP.start(download_uri.hostname, download_uri.port, 
                                        use_ssl: download_uri.scheme == 'https') do |http|
        http.request(download_request)
      end
      
      if download_response.code == '200'
        puts "Successfully downloaded attachment"
        download_response.body
      else
        puts "Failed to download attachment: #{download_response.code}"
        puts "Response: #{download_response.body}"
        nil
      end
    rescue => e
      puts "Error downloading attachment: #{e.message}"
      nil
    end
  end

  def test_upload_to_target(file_content, filename)
    puts "\nTesting upload to target Redmine..."
    
    # Get current Redmine settings (you'll need to adjust this for your environment)
    # For testing, let's assume localhost settings
    target_host = 'localhost'
    target_port = 3099
    target_protocol = 'https'
    target_api_key = ENV['REDMINE_API_KEY'] || ''
    
    begin
      # Build upload URI
      upload_uri = URI::HTTP.build(
        host: target_host,
        port: target_port,
        scheme: target_protocol,
        path: '/uploads.json',
        query: URI.encode_www_form({filename: filename})
      )
      
      puts "Upload URI: #{upload_uri}"
      
      upload_request = Net::HTTP::Post.new(upload_uri)
      upload_request['X-Redmine-API-Key'] = target_api_key
      upload_request['Content-Type'] = 'application/octet-stream'
      upload_request.body = file_content
      
      upload_response = Net::HTTP.start(upload_uri.hostname, upload_uri.port,
                                      use_ssl: upload_uri.scheme == 'https') do |http|
        http.request(upload_request)
      end
      
      puts "Upload response status: #{upload_response.code}"
      puts "Upload response headers: #{upload_response.to_hash}"
      puts "Upload response body: #{upload_response.body}"
      
      if upload_response.code == '201'
        puts "Upload successful!"
        upload_data = JSON.parse(upload_response.body)
        puts "Token: #{upload_data['upload']['token']}"
      else
        puts "Upload failed with status #{upload_response.code}"
      end
      
    rescue => e
      puts "Error during upload test: #{e.message}"
      puts e.backtrace
    end
  end
end

# Usage example (uncomment and adjust for your environment):
test = AttachmentTransferTest.new('', '')
test.test_attachment_transfer(11352) # replace with actual issue ID
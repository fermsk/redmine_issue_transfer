class IssueTransferConfig
  include ActiveModel::Model
  include ActiveModel::Validations

  attr_accessor :source_url, :source_api_key, :source_version_id
  attr_accessor :target_project_id, :target_version_id, :fallback_assignee_id

  validates :source_url, presence: true, format: { with: URI::DEFAULT_PARSER.make_regexp }
  validates :source_api_key, presence: true
  validates :source_version_id, presence: true, numericality: { only_integer: true }
  validates :target_project_id, presence: true, numericality: { only_integer: true }
  validates :target_version_id, presence: true, numericality: { only_integer: true }
  validates :fallback_assignee_id, presence:  true, numericality: { only_integer: true }
  
end
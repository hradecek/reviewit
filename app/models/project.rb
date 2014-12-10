class Project < ActiveRecord::Base
  has_and_belongs_to_many :users
  has_many :merge_requests, dependent: :destroy

  validates :name, presence: true

  def has_gitlab_ci?
    !gitlab_ci_token.blank? and !gitlab_ci_project_url.blank?
  end

  def ci_status patch
    ap ci_status_url_for(patch)
    Timeout::timeout(2) do
      raw_result = Net::HTTP.get(ci_status_url_for(patch))
      result = JSON.parse(raw_result)
      result['url'] = "#{gitlab_ci_project_url}/builds/#{result['id']}"
      result
    end
  rescue Timeout::Error
    { status: 'unknown' }
  end

  private

  def ci_status_url_for patch
#    15cc9596c3ba462f20579453607aaed4d75c0733
    URI("#{gitlab_ci_project_url}/builds/15cc9596c3ba462f20579453607aaed4d75c0733/status.json?token=#{gitlab_ci_token}")
#    URI("#{gitlab_ci_project_url}/builds/#{patch.gitlab_ci_hash}/status.json?token=#{gitlab_ci_token}")
  end
end

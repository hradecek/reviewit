require 'tmpdir'
require 'fileutils'
require 'tempfile'

class MergeRequest < ActiveRecord::Base
  belongs_to :author, class_name: User
  belongs_to :reviewer, class_name: User
  belongs_to :project

  has_many :patches, -> { order(:created_at) }, dependent: :destroy
  has_many :history_events, -> { order(:when) }, dependent: :destroy

  enum status: [ :open, :integrating, :needs_rebase, :accepted, :abandoned ]

  # Any status >= this is considered a closed MR
  CLOSE_LIMIT = 3

  scope :pending, -> { where("status < #{CLOSE_LIMIT}") }
  scope :closed, -> { where("status >= #{CLOSE_LIMIT}") }

  validates :target_branch, presence: true
  validates :subject, presence: true
  validates :author, presence: true
  validate :author_cant_be_reviewer

  before_save :write_history

  def can_update?
    not %w(accepted integrating).include? status
  end

  def closed?
    MergeRequest.statuses[status] >= CLOSE_LIMIT
  end

  def add_patch data
    patch = Patch.new
    patch.commit_message = data[:commit_message]
    patch.diff = data[:diff]
    patch.linter_ok = data[:linter_ok]
    patch.description = data[:description]
    self.patches << patch
    add_history_event author, 'updated the merge request'
  end

  def abandon! reviewer
    add_history_event reviewer, 'abandoned the merge request'
    self.status = :abandoned
    save!
  end

  def integrate! reviewer
    return if %w(accepted integrating abandoned).include? status
    add_history_event reviewer, 'accepted the merge request'

    self.reviewer = reviewer
    self.status = :integrating
    save!

    Thread.new do
      begin
        on_git_repository(patch) do |dir|
          if git_am(dir, patch) and git_push(dir, target_branch)
            accepted!
          else
            add_history_event reviewer, 'failed to integrate merge request'
            needs_rebase!
          end
        end
      rescue
        output.puts "\n\n******** Stupid error from Review it! programmer ******** \n\n"
        output.puts $!.inspect
        output.puts $!.backtrace
        open!
      ensure
        patch.integration_log = output.string
        patch.save
        ActiveRecord::Base.connection.close
      end
    end
  end

  def patch
    @patch ||= patches.last
  end

  def git_format_patch
    return if patch.nil?

    reviewer_stamp = (reviewer.nil? ? '' : "\nReviewed by #{reviewer.name} on MR ##{id}\n")
    out =<<eot
From: #{author.name} <#{author.email}>
Date: #{patch.created_at.strftime('%a, %d %b %Y %H:%M:%S %z')}

#{indent_comment patch.commit_message}
#{indent_comment reviewer_stamp}
#{patch.diff}
--
review it!
eot
  end

  def push_to_gitlab_ci
    Thread.new do
      begin
        on_git_repository(patch) do |dir|
          branch_name = "mr-#{id}-version-#{patches.count}"
          if git_am(dir, patch) and git_push(dir, branch_name)
            patch.gitlab_ci_hash = `git rev-parse HEAD`.strip
            patch.save
          end
        end
      ensure
        ActiveRecord::Base.connection.close
      end
    end
  end
private

  def write_history
    add_history_event author, "changed the target branch from #{target_branch_was} to #{target_branch}" if target_branch_changed? and !target_branch_was.nil?
  end

  def add_history_event who, what
    self.history_events << HistoryEvent.new(who: who, what: what)
  end

  def indent_comment comment
    comment.each_line.map {|line| "    #{line}"}.join
  end

  def author_cant_be_reviewer
    errors.add(:reviewer, 'can\'t be the author.') if author == reviewer
  end

  def on_git_repository patch
    base_dir = "#{Dir.tmpdir}/reviewit"
    project_dir_name = "patch#{patch.id}_#{SecureRandom.hex}"
    dir = "#{base_dir}/#{project_dir_name}"
    FileUtils.rm_rf dir
    FileUtils.mkdir_p dir

    call "cd #{base_dir} && git clone --depth 1 #{project.repository} #{project_dir_name}"
    call "cd #{dir} && git reset --hard origin/#{target_branch}"
    yield dir
  ensure
    FileUtils.rm_rf dir
  end

  def git_am dir, patch
    contents = git_format_patch
    file = Tempfile.new 'patch'
    file.puts contents
    file.close
    call "cd #{dir} && git am #{file.path}"
  end

  def git_push dir, branch
    call "cd #{dir} && git push origin master:#{branch}"
  end

  def output
    @output ||= StringIO.new
  end

  def call command
    output.puts "$ #{command}"
    res = `#{command} 2>&1`.strip
    output.puts(res) unless res.empty?
    $?.exitstatus.zero?
  end
end

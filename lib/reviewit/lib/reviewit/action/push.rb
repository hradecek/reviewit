module Reviewit
  class Push < Action

    RME_STAMP = /^Rme-MR-id: (.*)$/

    def run
      read_commit_header
      read_commit_diff

      if updating?
        api.update_merge_request(@mr_id, @subject, @commit_message, @commit_diff, read_user_message)
      else
        mr_id = api.create_merge_request(@subject, @commit_message, @commit_diff)
        append_mr_id_to_commit(mr_id)
      end
    end
  private
    def read_commit_header
      @subject = `git show -s --format="%s"`.strip
      @commit_message = `git show -s --format="%B"`.strip
    end

    def read_commit_diff
      @commit_diff = `git show --format=""`
    end

    def append_mr_id_to_commit mr_id
      open('|git commit --amend -F -', 'w+') do |git|
        git.write @commit_message
        git.write "\n\nRme-MR-id: #{mr_id}\n"
        git.close
      end
    end

    def updating?
      match = /^Rme-MR-id: (?<id>\d+)$/.match @commit_message
      return false if match.nil?

      @mr_id = match[:id]
    end
  end
end
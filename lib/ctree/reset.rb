# frozen_string_literal: true

module Ctree
  module Reset
    module_function

    def run(confirm: true)
      target_path = Pathname.pwd
      toplevel_out, _, status = Sh.capture3("git", "-C", target_path.to_s, "rev-parse", "--show-toplevel")
      Log.die "not inside a git repository" unless status.success?
      git_top = Pathname.new(toplevel_out.strip)
      unless target_path.realpath == git_top.realpath
        Log.die "must be invoked from the worktree top-level (cwd=#{target_path}, top=#{git_top})"
      end

      common_out, _, c_st = Sh.capture3("git", "-C", target_path.to_s, "rev-parse", "--git-common-dir")
      Log.die "could not resolve git common dir" unless c_st.success?
      common = Pathname.new(common_out.strip)
      common = (target_path / common) unless common.absolute?
      source_root = common.parent.realpath

      if source_root == target_path.realpath
        Log.die "already in the source project; run ctree reset from inside a worktree"
      end

      config = Config.load(target_path)
      Log.debug_mode = config[:log_level] == "debug"
      worktree_name = target_path.basename.to_s

      source_head = head_commit(source_root, "HEAD")
      Log.die "could not resolve the source repo's HEAD" if source_head.nil?

      Log.info "worktree:  #{target_path}"
      Log.info "source:    #{source_root}  [#{source_head[0, 11]}]"

      if confirm
        raw = Prompt.read_line("reset this worktree to the source's commit, discarding uncommitted changes? [y/N]: ")
        answer = raw.to_s.gsub(/[\x00-\x1f\x7f]/, "").strip.downcase
        unless answer == "y" || answer == "yes"
          Log.info "reset aborted"
          raise ExitStatus.new(1)
        end
      end

      unless reset_repo(target_path, source_root, source_head, worktree_name, worktree_name)
        Log.die "could not reset #{worktree_name}"
      end

      failed = false
      Rebase.embedded_repos(target_path, config[:rebase]).each do |worktree_repo|
        relative = worktree_repo.relative_path_from(target_path).to_s
        source_repo = source_root / relative

        unless source_repo.directory? && (source_repo / ".git").exist?
          Log.warn_ "no source counterpart for #{relative}; skipping"
          next
        end

        _, fetch_error, fetch_status = Spinner.with_spinner("fetching #{relative}") do
          Sh.capture3("git", "-C", worktree_repo.to_s, "fetch", source_repo.to_s, "HEAD")
        end
        unless fetch_status.success?
          Log.warn_ "git fetch #{source_repo} failed for #{relative}: #{fetch_error.strip}"
          failed = true
          next
        end

        source_repo_head = head_commit(worktree_repo, "FETCH_HEAD")
        failed = true unless reset_repo(worktree_repo, source_repo, source_repo_head, worktree_name, relative)
      end

      raise ExitStatus.new(2) if failed
    end

    def reset_repo(repo_path, source_repo_path, commit, worktree_name, label)
      back_up_unreferenced_head(repo_path, worktree_name, label)

      _, checkout_error, checkout_status = Spinner.with_spinner("checking out #{commit[0, 11]} in #{label}") do
        Sh.capture3("git", "-C", repo_path.to_s, "checkout", "--force", "--detach", commit)
      end
      unless checkout_status.success?
        Log.warn_ "git checkout #{commit[0, 11]} failed in #{label}: #{checkout_error.strip}"
        return false
      end

      worktree_untracked = untracked_paths(repo_path)
      source_untracked = untracked_paths(source_repo_path)
      if worktree_untracked.nil? || source_untracked.nil?
        Log.warn_ "could not list untracked files for #{label}; left them in place"
        return false
      end

      extra_paths = worktree_untracked - source_untracked
      unless extra_paths.empty?
        _, clean_error, clean_status = Sh.capture3("git", "-C", repo_path.to_s, "clean", "-fd", "--", *extra_paths)
        unless clean_status.success?
          Log.warn_ "git clean failed in #{label}: #{clean_error.strip}"
          return false
        end
        Log.info "removed untracked in #{label}: #{extra_paths.join(", ")}"
      end

      Log.info "reset #{label} to #{commit[0, 11]}"
      true
    end

    def back_up_unreferenced_head(repo_path, worktree_name, label)
      head = head_commit(repo_path, "HEAD")
      return if head.nil?

      containing_refs, _, refs_status = Sh.capture3(
        "git", "-C", repo_path.to_s, "for-each-ref", "--contains", head, "--format=%(refname)",
        "refs/heads", "refs/remotes", "refs/tags"
      )
      return if refs_status.success? && !containing_refs.strip.empty?

      backup_branch = "backup/#{worktree_name}-#{head[0, 11]}"
      _, branch_error, branch_status = Sh.capture3("git", "-C", repo_path.to_s, "branch", backup_branch, head)
      Log.die "could not back up #{head[0, 11]} in #{label}: #{branch_error.strip}" unless branch_status.success?
      Log.info "backed up #{head[0, 11]} in #{label} to branch #{backup_branch}"
    end

    def head_commit(repo_path, revision)
      out, _, status = Sh.capture3("git", "-C", repo_path.to_s, "rev-parse", "--verify", "--quiet", "#{revision}^{commit}")
      status.success? ? out.strip : nil
    end

    def untracked_paths(repo_path)
      out, _, status = Sh.capture3("git", "-C", repo_path.to_s, "ls-files", "--others", "--exclude-standard", "--directory")
      status.success? ? out.lines.map(&:chomp).reject(&:empty?) : nil
    end

    private_class_method :reset_repo, :back_up_unreferenced_head, :head_commit, :untracked_paths
  end
end

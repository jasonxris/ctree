# frozen_string_literal: true

RSpec.describe "Ctree::CLI reset" do
  around do |ex|
    Dir.mktmpdir do |parent_dir|
      @parent = Pathname.new(parent_dir).realpath
      @source = @parent / "src"
      @worktree = @parent / "wt1"
      FileUtils.mkdir_p(@source.to_s)
      Dir.chdir(@source) { ex.run }
    end
  end

  def git(path, *args)
    out, status = Open3.capture2e("git", "-C", path.to_s, *args)
    raise "git #{args.join(" ")} failed: #{out}" unless status.success?

    out.strip
  end

  def commit_file(path, name, content)
    File.write((path / name).to_s, content)
    git(path, "add", name)
    git(path, "commit", "-q", "-m", "change #{name}")
    git(path, "rev-parse", "HEAD")
  end

  def init_repo(path)
    FileUtils.mkdir_p(path.to_s)
    git(path, "init", "-q", "-b", "main")
    git(path, "config", "user.email", "test@example.com")
    git(path, "config", "user.name", "Test")
  end

  before do
    init_repo(@source)
    File.write((@source / ".gitignore").to_s, ".ctree/\nignored.txt\nplugins/\n")
    git(@source, "add", ".gitignore")
    git(@source, "commit", "-q", "-m", "init")
    @old_commit = commit_file(@source, "app.rb", "old\n")
    git(@source, "worktree", "add", "-q", "--detach", @worktree.to_s, @old_commit)
    @source_commit = commit_file(@source, "app.rb", "new\n")
    allow(Ctree::Prompt).to receive(:read_line).and_return("y")
  end

  def reset_in_worktree
    Dir.chdir(@worktree.to_s) { Ctree::CLI.run(["reset"]) }
  end

  it "errors when run from the source project rather than a worktree" do
    expect { Ctree::CLI.run(["reset"]) }.to raise_error(Ctree::Error, /already in the source project/)
  end

  it "rejects extra arguments" do
    expect { Ctree::CLI.run(["reset", "wt1"]) }.to raise_error(Ctree::ExitStatus) { |e| expect(e.exit_code).to eq(1) }
  end

  it "leaves the worktree untouched when the user does not confirm" do
    allow(Ctree::Prompt).to receive(:read_line).and_return("")
    File.write((@worktree / "app.rb").to_s, "edited\n")

    expect { reset_in_worktree }.to raise_error(Ctree::ExitStatus) { |e| expect(e.exit_code).to eq(1) }
    expect(git(@worktree, "rev-parse", "HEAD")).to eq(@old_commit)
    expect(File.read((@worktree / "app.rb").to_s)).to eq("edited\n")
  end

  it "skips the prompt when confirm is false" do
    Dir.chdir(@worktree.to_s) { Ctree::Reset.run(confirm: false) }

    expect(Ctree::Prompt).not_to have_received(:read_line)
    expect(git(@worktree, "rev-parse", "HEAD")).to eq(@source_commit)
  end

  it "checks out the source's commit detached and discards tracked changes" do
    File.write((@worktree / "app.rb").to_s, "edited\n")

    reset_in_worktree

    expect(git(@worktree, "rev-parse", "HEAD")).to eq(@source_commit)
    expect(git(@worktree, "branch", "--show-current")).to eq("")
    expect(File.read((@worktree / "app.rb").to_s)).to eq("new\n")
  end

  it "removes untracked paths the source lacks, keeps the ones it has, and never touches ignored files" do
    FileUtils.mkdir_p((@source / "reports").to_s)
    File.write((@source / "reports" / "keep.txt").to_s, "x")
    FileUtils.mkdir_p((@worktree / "reports").to_s)
    File.write((@worktree / "reports" / "keep.txt").to_s, "x")
    FileUtils.mkdir_p((@worktree / "scratch").to_s)
    File.write((@worktree / "scratch" / "probe.rb").to_s, "x")
    File.write((@worktree / "stray.rb").to_s, "x")
    File.write((@worktree / "ignored.txt").to_s, "x")

    reset_in_worktree

    expect((@worktree / "reports" / "keep.txt")).to exist
    expect((@worktree / "ignored.txt")).to exist
    expect((@worktree / "scratch")).not_to exist
    expect((@worktree / "stray.rb")).not_to exist
  end

  it "saves a commit no ref contains to a backup branch before leaving it" do
    git(@worktree, "config", "user.email", "test@example.com")
    git(@worktree, "config", "user.name", "Test")
    orphan_commit = commit_file(@worktree, "review.rb", "under review\n")

    reset_in_worktree

    backup_branch = "backup/wt1-#{orphan_commit[0, 11]}"
    expect(git(@source, "rev-parse", backup_branch)).to eq(orphan_commit)
  end

  it "does not create a backup branch when a branch already contains the commit" do
    git(@worktree, "switch", "-q", "-c", "feature")

    reset_in_worktree

    expect(git(@source, "branch", "--list", "backup/*")).to eq("")
    expect(git(@source, "rev-parse", "feature")).to eq(@old_commit)
  end

  it "resets each embedded repo to its source counterpart's commit" do
    source_plugin = @source / "plugins" / "foo"
    init_repo(source_plugin)
    plugin_old_commit = commit_file(source_plugin, "plugin.rb", "old\n")
    plugin_new_commit = commit_file(source_plugin, "plugin.rb", "new\n")
    worktree_plugin = @worktree / "plugins" / "foo"
    FileUtils.mkdir_p(worktree_plugin.parent.to_s)
    git(@worktree / "plugins", "clone", "-q", source_plugin.to_s, "foo")
    git(worktree_plugin, "checkout", "-q", plugin_old_commit)
    File.write((worktree_plugin / "plugin.rb").to_s, "edited\n")
    FileUtils.mkdir_p((@worktree / ".ctree").to_s)
    File.write((@worktree / ".ctree" / "config.yml").to_s, "rebase:\n  - plugins\n")

    reset_in_worktree

    expect(git(worktree_plugin, "rev-parse", "HEAD")).to eq(plugin_new_commit)
    expect(File.read((worktree_plugin / "plugin.rb").to_s)).to eq("new\n")
  end

  describe "Ctree::List.managed_worktree_paths" do
    it "returns worktrees whose env file names a compose project, excluding the source and plain worktrees" do
      File.write((@worktree / ".env").to_s, "COMPOSE_PROJECT_NAME=wt1\n")
      plain_worktree = @parent / "plain"
      git(@source, "worktree", "add", "-q", "--detach", plain_worktree.to_s)

      expect(Ctree::List.managed_worktree_paths(@source)).to eq([@worktree])
    end
  end
end

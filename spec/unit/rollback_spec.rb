# frozen_string_literal: true

RSpec.describe "Ctree::Create.rollback" do
  around do |ex|
    Dir.mktmpdir do |parent_dir|
      @parent = Pathname.new(parent_dir).realpath
      @work = @parent / "src"
      FileUtils.mkdir_p(@work.to_s)
      Dir.chdir(@work) { ex.run }
    end
  end

  before do
    system("git", "init", "-q", "-b", "master", out: File::NULL, err: File::NULL)
    system("git", "config", "user.email", "test@example.com")
    system("git", "config", "user.name", "Test")
    File.write("placeholder", "x")
    system("git", "add", ".", out: File::NULL, err: File::NULL)
    system("git", "commit", "-q", "-m", "init", out: File::NULL, err: File::NULL)
  end

  def add_worktree(name, branch: name, new_branch: true)
    target = @parent / name
    args = new_branch ? ["-b", branch, target.to_s] : [target.to_s, branch]
    system("git", "-C", @work.to_s, "worktree", "add", *args, out: File::NULL, err: File::NULL)
    target
  end

  def branch_exists?(branch)
    system("git", "-C", @work.to_s, "show-ref", "--verify", "--quiet", "refs/heads/#{branch}")
  end

  it "never prompts, and removes the worktree, compose project, and volumes" do
    target = add_worktree("tree1")
    allow(Ctree::Prompt).to receive(:read_line).and_raise("rollback must not prompt")

    stub_sh(
      docker_system: [true],
      docker_capture3: [
        ["tree1_v1\ntree1_v2\n", "", true], # docker volume ls
        ["", "", true],                     # docker ps --all
        ["", "", true],                     # docker images
        ["", "", true]                      # docker volume rm v1 v2 (batch)
      ]
    )

    failures = Ctree::Create.rollback(name: "tree1", delete_branch: true)

    expect(failures).to eq([])
    expect(target).not_to exist
    expect(Ctree::Sh).to have_received(:capture3)
      .with("docker", "volume", "rm", "tree1_v1", "tree1_v2").once
    expect(branch_exists?("tree1")).to be false
  end

  it "deletes a branch ctree created but preserves a pre-existing branch" do
    system("git", "-C", @work.to_s, "branch", "brought-along", out: File::NULL, err: File::NULL)
    target = add_worktree("tree1", branch: "brought-along", new_branch: false)
    stub_sh(docker_capture3: [], docker_system: [false])

    Ctree::Create.rollback(name: "tree1", delete_branch: false)

    expect(target).not_to exist
    expect(branch_exists?("brought-along")).to be true
  end

  it "warns on a failing cleanup step and still runs the remaining steps" do
    target = add_worktree("tree1")

    stub_sh(
      docker_system: [true],
      docker_capture3: [
        ["", "", true],             # docker volume ls -- no volumes
        ["", "", true],             # docker ps --all -- no containers
        ["tree1-web\n", "", true],  # docker images -- one tagged image
        ["", "boom", false]        # docker rmi -- fails
      ]
    )

    failures = nil
    expect {
      failures = Ctree::Create.rollback(name: "tree1", delete_branch: true)
    }.to output(/docker rmi returned non-zero/).to_stderr

    expect(failures).to eq(["image rmi"])
    expect(target).not_to exist
    expect(branch_exists?("tree1")).to be false
  end
end

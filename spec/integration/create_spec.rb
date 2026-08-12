# frozen_string_literal: true

RSpec.describe "Ctree::CLI create" do
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
    File.write(".env", "COMPOSE_PROJECT_NAME=src\nDB_PORT=5432\n")
    system("git", "add", ".env", out: File::NULL, err: File::NULL)
    system("git", "commit", "-q", "-m", "init", out: File::NULL, err: File::NULL)
  end

  # Stubs Clonefile to perform a real FileUtils.cp_r so the target directory
  # is properly populated for subsequent git/File operations.
  def stub_clonefile
    allow(Ctree::Clonefile).to receive(:available?).and_return(true)
    allow(Ctree::Clonefile).to receive(:clone) do |src, tgt|
      FileUtils.cp_r(src.to_s, tgt.to_s)
      true
    end
  end

  it "rejects an invalid worktree name" do
    expect {
      Ctree::CLI.run(["create", "Bad Name", "wt1"])
    }.to raise_error(Ctree::Error, /invalid name/)
  end

  it "refuses to create a worktree of a worktree" do
    existing_wt = @parent / "existing-wt"
    system("git", "-C", @work.to_s, "worktree", "add", "-b", "existing-branch",
           existing_wt.to_s, out: File::NULL, err: File::NULL)

    Dir.chdir(existing_wt.to_s) do
      expect {
        Ctree::CLI.run(["create", "wt2", "wt2"])
      }.to raise_error(Ctree::Error, /must be run from a source repo, not from a worktree/)
    end

    system("git", "-C", @work.to_s, "worktree", "remove", "--force", existing_wt.to_s,
           out: File::NULL, err: File::NULL)
  end

  def docker_stubs
    [
      ["", "", true],   # docker info
      ["", "", true],   # docker ps source -- no running containers
      ["", "", true],   # docker volume ls -- no source volumes, doubles as the snapshot
      ["", "", true],   # docker images -- no source images to tag
      ["web\n", "", true], # docker compose config --services
      ["", "", true],   # docker compose up --no-start --no-build web
      ["", "", true],
    ]
  end

  it "creates a sibling worktree on a new branch with updated .env" do
    allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
    allow(Ctree::Prompt).to receive(:read_line).and_return("n")
    stub_clonefile
    stub_sh(docker_capture3: docker_stubs)

    expect {
      Ctree::CLI.run(["create", "wt1", "wt1"])
    }.not_to raise_error

    sibling = @work.parent / "wt1"
    expect(sibling).to be_directory
    env_content = (sibling / ".env").read
    expect(env_content).to include("COMPOSE_PROJECT_NAME=wt1")
    expect(env_content).to include("HOST_NAME=wt1")
    expect(env_content).to include("DB_PORT=5432")
    expect(env_content).not_to include("HOST_NAME_SUFFIX")

    system("git", "-C", @work.to_s, "worktree", "remove", "--force", sibling.to_s,
           out: File::NULL, err: File::NULL)
  end

  it "asks nothing per variable when the copy-all answer is accepted" do
    allow(Ctree::Prompt).to receive(:for_env_var_change).and_call_original
    allow(Ctree::Prompt).to receive(:read_line).and_return("")
    stub_clonefile
    stub_sh(docker_capture3: docker_stubs)

    expect {
      Ctree::CLI.run(["create", "wt-copyall", "wt-copyall"])
    }.not_to raise_error

    expect(Ctree::Prompt).not_to have_received(:for_env_var_change)

    sibling = @work.parent / "wt-copyall"
    env_content = (sibling / ".env").read
    expect(env_content).to include("COMPOSE_PROJECT_NAME=wt-copyall")
    expect(env_content).to include("DB_PORT=5432")

    system("git", "-C", @work.to_s, "worktree", "remove", "--force", sibling.to_s,
           out: File::NULL, err: File::NULL)
  end

  it "brings up each compose service individually rather than all at once" do
    allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
    allow(Ctree::Prompt).to receive(:read_line).and_return("n")
    stub_clonefile
    stub_sh(docker_capture3: [
      ["", "", true],                       # docker info
      ["", "", true],                       # docker ps source
      ["", "", true],                       # docker volume ls -- none, doubles as the snapshot
      ["", "", true],                       # docker images
      ["web\nwebpack\njobs\n", "", true],   # docker compose config --services
      ["", "", true],                       # up --no-start --no-build web
      ["", "", true],                       # up --no-start --no-build webpack
      ["", "", true],                       # up --no-start --no-build jobs
      ["", "", true],
    ])

    expect {
      Ctree::CLI.run(["create", "wt1", "wt1"])
    }.not_to raise_error

    sibling = @work.parent / "wt1"
    %w[web webpack jobs].each do |service|
      expect(Ctree::Sh).to have_received(:capture3).with(
        "docker", "compose", "--project-directory", sibling.to_s,
        "--project-name", "wt1", "up", "--no-start", "--no-build", service
      )
    end
    expect(Ctree::Sh).not_to have_received(:capture3).with(
      "docker", "compose", "--project-directory", sibling.to_s,
      "--project-name", "wt1", "up", "--no-start", "--no-build"
    )

    system("git", "-C", @work.to_s, "worktree", "remove", "--force", sibling.to_s,
           out: File::NULL, err: File::NULL)
  end

  it "removes the containers created for volume materialization, keeping volumes" do
    allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
    allow(Ctree::Prompt).to receive(:read_line).and_return("n")
    stub_clonefile
    stub_sh(docker_capture3: docker_stubs)

    expect {
      Ctree::CLI.run(["create", "wt1", "wt1"])
    }.not_to raise_error

    sibling = @work.parent / "wt1"
    expect(Ctree::Sh).to have_received(:capture3).with(
      "docker", "compose", "--project-directory", sibling.to_s,
      "--project-name", "wt1", "down"
    )
    expect(Ctree::Sh).not_to have_received(:capture3).with(
      "docker", "compose", "--project-directory", sibling.to_s,
      "--project-name", "wt1", "down", "-v"
    )

    system("git", "-C", @work.to_s, "worktree", "remove", "--force", sibling.to_s,
           out: File::NULL, err: File::NULL)
  end

  it "falls back to a single up --no-start --no-build when compose services can't be listed" do
    allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
    allow(Ctree::Prompt).to receive(:read_line).and_return("n")
    stub_clonefile
    stub_sh(docker_capture3: [
      ["", "", true],                 # docker info
      ["", "", true],                 # docker ps source
      ["", "", true],                 # docker volume ls -- none, doubles as the snapshot
      ["", "", true],                 # docker images
      ["", "boom", false],            # docker compose config --services -- fails
      ["", "", true],                 # fallback: up --no-start --no-build (all services)
      ["", "", true],
    ])

    expect {
      Ctree::CLI.run(["create", "wt1", "wt1"])
    }.to output(/could not list compose services/).to_stderr

    sibling = @work.parent / "wt1"
    expect(Ctree::Sh).to have_received(:capture3).with(
      "docker", "compose", "--project-directory", sibling.to_s,
      "--project-name", "wt1", "up", "--no-start", "--no-build"
    )

    system("git", "-C", @work.to_s, "worktree", "remove", "--force", sibling.to_s,
           out: File::NULL, err: File::NULL)
  end

  it "writes HOST_NAME_SUFFIX to the worktree .env when configured" do
    FileUtils.mkdir_p((@work / ".ctree").to_s)
    File.write((@work / ".ctree" / "config.yml").to_s, "host_name_suffix: docker\n")

    allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
    allow(Ctree::Prompt).to receive(:read_line).and_return("n")
    stub_clonefile
    stub_sh(docker_capture3: docker_stubs)

    expect {
      Ctree::CLI.run(["create", "wt1", "wt1"])
    }.not_to raise_error

    sibling = @work.parent / "wt1"
    env_content = (sibling / ".env").read
    expect(env_content).to include("HOST_NAME_SUFFIX=docker")

    system("git", "-C", @work.to_s, "worktree", "remove", "--force", sibling.to_s,
           out: File::NULL, err: File::NULL)
  end

  it "reads and writes the configured env_filename instead of .env" do
    FileUtils.mkdir_p((@work / ".ctree").to_s)
    File.write((@work / ".ctree" / "config.yml").to_s, "env_filename: .env.custom\n")
    File.write((@work / ".env.custom").to_s, "COMPOSE_PROJECT_NAME=src\nDB_PORT=5432\n")
    system("git", "-C", @work.to_s, "add", ".ctree", ".env.custom", out: File::NULL, err: File::NULL)
    system("git", "-C", @work.to_s, "commit", "-q", "--amend", "--no-edit",
           out: File::NULL, err: File::NULL)

    allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
    allow(Ctree::Prompt).to receive(:read_line).and_return("n")
    stub_clonefile
    stub_sh(docker_capture3: docker_stubs)

    expect {
      Ctree::CLI.run(["create", "wt1", "wt1"])
    }.to output(/updated \.env\.custom/).to_stdout

    sibling = @work.parent / "wt1"
    env_content = (sibling / ".env.custom").read
    expect(env_content).to include("COMPOSE_PROJECT_NAME=wt1")
    expect(env_content).to include("HOST_NAME=wt1")

    system("git", "-C", @work.to_s, "worktree", "remove", "--force", sibling.to_s,
           out: File::NULL, err: File::NULL)
  end

  it "injects shared volumes into the compose override file and appends it to COMPOSE_FILE" do
    FileUtils.mkdir_p((@work / ".ctree").to_s)
    File.write((@work / ".ctree" / "config.yml").to_s,
               "share_volumes:\n  - yarn-cache\ncompose_override_file: docker-compose.local.ctree.yml\n")
    File.write((@work / ".env").to_s,
               "COMPOSE_PROJECT_NAME=src\nCOMPOSE_FILE=docker-compose.yml\nDB_PORT=5432\n")
    File.write((@work / "docker-compose.local.ctree.yml").to_s,
               "services:\n  web:\n    labels: []\n")
    system("git", "-C", @work.to_s, "add", ".", out: File::NULL, err: File::NULL)
    system("git", "-C", @work.to_s, "commit", "-q", "--amend", "--no-edit",
           out: File::NULL, err: File::NULL)

    allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
    allow(Ctree::Prompt).to receive(:read_line).and_return("n")
    stub_clonefile

    stub_sh(docker_capture3: [
      ["", "", true],                          # docker info
      ["", "", true],                          # docker ps source
      ["src_yarn-cache\n", "", true],          # docker volume ls -- yarn-cache, doubles as the snapshot
      ["", "", true],                          # docker images
      ["web\n", "", true],                     # docker compose config --services
      ["", "", true],                          # docker compose up --no-start --no-build web
      ["", "", true],
    ])

    expect {
      Ctree::CLI.run(["create", "wt1", "wt1"])
    }.not_to raise_error

    sibling = @work.parent / "wt1"
    override = YAML.safe_load((sibling / "docker-compose.local.ctree.yml").read)
    expect(override["volumes"]["yarn-cache"]).to eq(
      "external" => true, "name" => "src_yarn-cache"
    )
    env_content = (sibling / ".env").read
    expect(env_content).to match(/COMPOSE_FILE=.*docker-compose\.local\.ctree\.yml/)

    system("git", "-C", @work.to_s, "worktree", "remove", "--force", sibling.to_s,
           out: File::NULL, err: File::NULL)
  end

  it "warns when compose_override_file is missing from the worktree and share_volumes is configured" do
    FileUtils.mkdir_p((@work / ".ctree").to_s)
    File.write((@work / ".ctree" / "config.yml").to_s,
               "share_volumes:\n  - yarn-cache\ncompose_override_file: docker-compose.local.ctree.yml\n")
    system("git", "-C", @work.to_s, "add", ".ctree", out: File::NULL, err: File::NULL)
    system("git", "-C", @work.to_s, "commit", "-q", "--amend", "--no-edit",
           out: File::NULL, err: File::NULL)

    allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
    allow(Ctree::Prompt).to receive(:read_line).and_return("n")
    stub_clonefile
    stub_sh(docker_capture3: docker_stubs)

    expect {
      Ctree::CLI.run(["create", "wt1", "wt1"])
    }.to output(/docker-compose\.local\.ctree\.yml not found in worktree.*yarn-cache/).to_stderr

    system("git", "-C", @work.to_s, "worktree", "remove", "--force",
           (@work.parent / "wt1").to_s, out: File::NULL, err: File::NULL)
  end

  it "warns for each share_volume whose source Docker volume does not exist" do
    FileUtils.mkdir_p((@work / ".ctree").to_s)
    File.write((@work / ".ctree" / "config.yml").to_s,
               "share_volumes:\n  - yarn-cache\n  - missing-vol\ncompose_override_file: docker-compose.local.ctree.yml\n")
    File.write((@work / ".env").to_s,
               "COMPOSE_PROJECT_NAME=src\nCOMPOSE_FILE=docker-compose.yml\nDB_PORT=5432\n")
    File.write((@work / "docker-compose.local.ctree.yml").to_s,
               "services:\n  web:\n    labels: []\n")
    system("git", "-C", @work.to_s, "add", ".", out: File::NULL, err: File::NULL)
    system("git", "-C", @work.to_s, "commit", "-q", "--amend", "--no-edit",
           out: File::NULL, err: File::NULL)

    allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
    allow(Ctree::Prompt).to receive(:read_line).and_return("n")
    stub_clonefile

    stub_sh(docker_capture3: [
      ["", "", true],                 # docker info
      ["", "", true],                 # docker ps source
      ["src_yarn-cache\n", "", true], # docker volume ls -- yarn-cache exists, missing-vol does not
      ["", "", true],                 # docker images
      ["web\n", "", true],            # docker compose config --services
      ["", "", true],                 # docker compose up --no-start --no-build web
      ["", "", true],
    ])

    expect {
      Ctree::CLI.run(["create", "wt1", "wt1"])
    }.to output(/source volume src_missing-vol not found.*missing-vol will not be shared/).to_stderr

    sibling = @work.parent / "wt1"
    override = YAML.safe_load((sibling / "docker-compose.local.ctree.yml").read)
    expect(override["volumes"]["yarn-cache"]).to eq("external" => true, "name" => "src_yarn-cache")
    expect(override["volumes"]).not_to have_key("missing-vol")

    system("git", "-C", @work.to_s, "worktree", "remove", "--force", sibling.to_s,
           out: File::NULL, err: File::NULL)
  end

  it "warns when all share_volumes are absent from Docker and no external references are written" do
    FileUtils.mkdir_p((@work / ".ctree").to_s)
    File.write((@work / ".ctree" / "config.yml").to_s,
               "share_volumes:\n  - yarn-cache\ncompose_override_file: docker-compose.local.ctree.yml\n")
    File.write((@work / ".env").to_s,
               "COMPOSE_PROJECT_NAME=src\nCOMPOSE_FILE=docker-compose.yml\nDB_PORT=5432\n")
    File.write((@work / "docker-compose.local.ctree.yml").to_s,
               "services:\n  web:\n    labels: []\n")
    system("git", "-C", @work.to_s, "add", ".", out: File::NULL, err: File::NULL)
    system("git", "-C", @work.to_s, "commit", "-q", "--amend", "--no-edit",
           out: File::NULL, err: File::NULL)

    allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
    allow(Ctree::Prompt).to receive(:read_line).and_return("n")
    stub_clonefile
    stub_sh(docker_capture3: docker_stubs)

    expect {
      Ctree::CLI.run(["create", "wt1", "wt1"])
    }.to output(/no source volumes found for share_volumes.*worktree will use its own isolated copies/).to_stderr

    system("git", "-C", @work.to_s, "worktree", "remove", "--force",
           (@work.parent / "wt1").to_s, out: File::NULL, err: File::NULL)
  end

  it "preserves !override and !reset YAML tags in the compose override file" do
    FileUtils.mkdir_p((@work / ".ctree").to_s)
    File.write((@work / ".ctree" / "config.yml").to_s,
               "share_volumes:\n  - yarn-cache\ncompose_override_file: docker-compose.local.ctree.yml\n")
    File.write((@work / ".env").to_s,
               "COMPOSE_PROJECT_NAME=src\nCOMPOSE_FILE=docker-compose.yml\nDB_PORT=5432\n")
    File.write((@work / "docker-compose.local.ctree.yml").to_s,
               "services:\n  web:\n    ports: !override []\n    aliases: !reset []\n")
    system("git", "-C", @work.to_s, "add", ".", out: File::NULL, err: File::NULL)
    system("git", "-C", @work.to_s, "commit", "-q", "--amend", "--no-edit",
           out: File::NULL, err: File::NULL)

    allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
    allow(Ctree::Prompt).to receive(:read_line).and_return("n")
    stub_clonefile

    stub_sh(docker_capture3: [
      ["", "", true],                          # docker info
      ["", "", true],                          # docker ps source
      ["src_yarn-cache\n", "", true],          # docker volume ls -- yarn-cache, doubles as the snapshot
      ["", "", true],                          # docker images
      ["web\n", "", true],                     # docker compose config --services
      ["", "", true],                          # docker compose up --no-start --no-build web
      ["", "", true],
    ])

    expect {
      Ctree::CLI.run(["create", "wt1", "wt1"])
    }.not_to raise_error

    sibling = @work.parent / "wt1"
    override_content = (sibling / "docker-compose.local.ctree.yml").read
    expect(override_content).to include("!override")
    expect(override_content).to include("!reset")
    override_doc = YAML.safe_load(override_content, aliases: true)
    expect(override_doc["volumes"]["yarn-cache"]).to eq(
      "external" => true, "name" => "src_yarn-cache"
    )

    system("git", "-C", @work.to_s, "worktree", "remove", "--force", sibling.to_s,
           out: File::NULL, err: File::NULL)
  end

  it "removes files present in source but not on the target branch" do
    system("git", "checkout", "-q", "-b", "feature-branch", out: File::NULL, err: File::NULL)
    system("git", "checkout", "-q", "master", out: File::NULL, err: File::NULL)
    File.write("extra.rb", "# extra")
    system("git", "add", "extra.rb", out: File::NULL, err: File::NULL)
    system("git", "commit", "-q", "-m", "add extra", out: File::NULL, err: File::NULL)

    allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
    allow(Ctree::Prompt).to receive(:read_line).and_return("n")
    stub_clonefile
    stub_sh(docker_capture3: docker_stubs)

    expect {
      Ctree::CLI.run(["create", "wt1", "feature-branch"])
    }.not_to raise_error

    sibling = @work.parent / "wt1"
    expect(sibling / "extra.rb").not_to exist

    system("git", "-C", @work.to_s, "worktree", "remove", "--force", sibling.to_s,
           out: File::NULL, err: File::NULL)
  end

  it "does not clone top-level directories listed in exclude" do
    FileUtils.mkdir_p((@work / ".ctree").to_s)
    File.write((@work / ".ctree" / "config.yml").to_s, "exclude:\n  - node_modules\n")
    File.write((@work / ".gitignore").to_s, "node_modules/\n")
    FileUtils.mkdir_p((@work / "node_modules").to_s)
    File.write((@work / "node_modules" / "package.json").to_s, "{}")
    system("git", "-C", @work.to_s, "add", ".gitignore", ".ctree", out: File::NULL, err: File::NULL)
    system("git", "-C", @work.to_s, "commit", "-q", "--amend", "--no-edit",
           out: File::NULL, err: File::NULL)

    allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
    allow(Ctree::Prompt).to receive(:read_line).and_return("n")
    stub_clonefile
    stub_sh(docker_capture3: docker_stubs)

    expect {
      Ctree::CLI.run(["create", "wt1", "wt1"])
    }.not_to raise_error

    sibling = @work.parent / "wt1"
    expect(sibling / "node_modules").not_to exist
    expect(sibling / ".env").to exist

    system("git", "-C", @work.to_s, "worktree", "remove", "--force", sibling.to_s,
           out: File::NULL, err: File::NULL)
  end

  it "does not clone top-level files listed in exclude" do
    FileUtils.mkdir_p((@work / ".ctree").to_s)
    File.write((@work / ".ctree" / "config.yml").to_s, "exclude:\n  - secrets.yml\n")
    File.write((@work / ".gitignore").to_s, "secrets.yml\n")
    File.write((@work / "secrets.yml").to_s, "api_key: secret")
    system("git", "-C", @work.to_s, "add", ".gitignore", ".ctree", out: File::NULL, err: File::NULL)
    system("git", "-C", @work.to_s, "commit", "-q", "--amend", "--no-edit",
           out: File::NULL, err: File::NULL)

    allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
    allow(Ctree::Prompt).to receive(:read_line).and_return("n")
    stub_clonefile
    stub_sh(docker_capture3: docker_stubs)

    expect {
      Ctree::CLI.run(["create", "wt1", "wt1"])
    }.not_to raise_error

    sibling = @work.parent / "wt1"
    expect(sibling / "secrets.yml").not_to exist
    expect(sibling / ".env").to exist

    system("git", "-C", @work.to_s, "worktree", "remove", "--force", sibling.to_s,
           out: File::NULL, err: File::NULL)
  end

  it "copies update file from source, overwriting the branch version after git checkout" do
    FileUtils.mkdir_p((@work / ".ctree").to_s)
    File.write((@work / ".ctree" / "config.yml").to_s, "update:\n  - lockfile.test\n")
    File.write((@work / "lockfile.test").to_s, "source-version")
    system("git", "-C", @work.to_s, "add", ".ctree", "lockfile.test",
           out: File::NULL, err: File::NULL)
    system("git", "-C", @work.to_s, "commit", "-q", "--amend", "--no-edit",
           out: File::NULL, err: File::NULL)

    system("git", "-C", @work.to_s, "checkout", "-q", "-b", "wt1",
           out: File::NULL, err: File::NULL)
    File.write((@work / "lockfile.test").to_s, "old-version")
    system("git", "-C", @work.to_s, "add", "lockfile.test",
           out: File::NULL, err: File::NULL)
    system("git", "-C", @work.to_s, "commit", "-q", "-m", "old lockfile",
           out: File::NULL, err: File::NULL)
    system("git", "-C", @work.to_s, "checkout", "-q", "master",
           out: File::NULL, err: File::NULL)

    allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
    allow(Ctree::Prompt).to receive(:read_line).and_return("n")
    stub_clonefile
    stub_sh(docker_capture3: docker_stubs)

    expect {
      Ctree::CLI.run(["create", "wt1", "wt1"])
    }.not_to raise_error

    sibling = @work.parent / "wt1"
    expect((sibling / "lockfile.test").read).to eq("source-version")

    system("git", "-C", @work.to_s, "worktree", "remove", "--force", sibling.to_s,
           out: File::NULL, err: File::NULL)
  end

  it "fails when the target sibling path already exists" do
    sibling = @work.parent / "wt2"
    FileUtils.mkdir_p(sibling.to_s)

    allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
    allow(Ctree::Prompt).to receive(:read_line).and_return("n")

    expect {
      Ctree::CLI.run(["create", "wt2", "wt2"])
    }.to raise_error(Ctree::Error)
  ensure
    FileUtils.rm_rf(sibling.to_s) if sibling
  end

  it "aborts before writing anything when the copy would not fit on disk" do
    allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
    allow(Ctree::Prompt).to receive(:read_line).and_return("n")
    stub_clonefile
    stub_sh(docker_capture3: [
      ["", "", true],                      # docker info
      ["", "", true],                      # docker ps source
      ["src_data\n", "", true],            # docker volume ls -- a copyable volume, doubles as the snapshot
      ["10737418240\n1073741824\n", "", true], # docker run -- needs 10GB, 1GB available
    ])

    expect {
      expect {
        Ctree::CLI.run(["create", "wt1", "wt1"])
      }.to raise_error(Ctree::Error, /not enough free space/)
    }.to output(/continuing would exhaust the disk/).to_stderr

    expect(@work.parent / "wt1").not_to exist
    worktree_list, _, _ = Open3.capture3("git", "-C", @work.to_s, "worktree", "list")
    expect(worktree_list).not_to include("wt1")
  end

  it "proceeds when the copy fits with room to spare" do
    allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
    allow(Ctree::Prompt).to receive(:read_line).and_return("n")
    allow(Ctree::Volume).to receive(:copy).and_return([fake_status(true), "", 1024])
    stub_clonefile
    stub_sh(docker_capture3: [
      ["", "", true],                         # docker info
      ["", "", true],                         # docker ps source
      ["src_data\n", "", true],               # docker volume ls -- a copyable volume, doubles as the snapshot
      ["1024\n107374182400\n", "", true],     # docker run -- needs 1KB, 100GB available
      ["", "", true],                         # docker images
      ["web\n", "", true],                    # docker compose config --services
      ["", "", true],                         # docker compose up --no-start --no-build web
      ["", "", true],                         # docker compose down
    ])

    expect {
      Ctree::CLI.run(["create", "wt1", "wt1"])
    }.not_to raise_error
    expect(Ctree::Volume).to have_received(:copy).with("src_data", "wt1_data", anything)

    system("git", "-C", @work.to_s, "worktree", "remove", "--force",
           (@work.parent / "wt1").to_s, out: File::NULL, err: File::NULL)
  end

  it "creates empty volumes for suffixes listed in empty_volumes without copying" do
    FileUtils.mkdir_p((@work / ".ctree").to_s)
    File.write((@work / ".ctree" / "config.yml").to_s,
               "empty_volumes:\n  - log\nlog_level: debug\n")
    system("git", "-C", @work.to_s, "add", ".ctree",
           out: File::NULL, err: File::NULL)
    system("git", "-C", @work.to_s, "commit", "-q", "--amend", "--no-edit",
           out: File::NULL, err: File::NULL)

    allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
    allow(Ctree::Prompt).to receive(:read_line).and_return("n")
    stub_clonefile
    stub_sh(docker_capture3: [
      ["", "", true],              # docker info
      ["", "", true],              # docker ps source
      ["src_log\n", "", true],    # docker volume ls — log volume, doubles as the snapshot
      ["", "", true],              # docker images
      ["web\n", "", true],         # docker compose config --services
      ["", "", true],              # docker compose up --no-start --no-build web
      ["", "", true],
    ])

    expect {
      Ctree::CLI.run(["create", "wt1", "wt1"])
    }.to output(/\[empty {2}\].*wt1_log.*\(empty volume\)/).to_stdout

    system("git", "-C", @work.to_s, "worktree", "remove", "--force",
           (@work.parent / "wt1").to_s, out: File::NULL, err: File::NULL)
  end

  def stub_concurrency_tracking_copy(observed)
    tracker = { in_flight: 0, peak: 0, mutex: Mutex.new }
    allow(Ctree::Volume).to receive(:copy) do
      tracker[:mutex].synchronize do
        tracker[:in_flight] += 1
        tracker[:peak] = [tracker[:peak], tracker[:in_flight]].max
      end
      sleep 0.05
      tracker[:mutex].synchronize { tracker[:in_flight] -= 1 }
      observed << :copied
      [fake_status(true), "", 1024]
    end
    tracker
  end

  def three_copyable_volumes_stubs
    [
      ["", "", true],                     # docker info
      ["", "", true],                     # docker ps source
      ["src_a\nsrc_b\nsrc_c\n", "", true], # docker volume ls, doubles as the snapshot
      ["3072\n107374182400\n", "", true], # docker run -- free space, plenty
      ["", "", true],                     # docker images
      ["web\n", "", true],                # docker compose config --services
      ["", "", true],                     # docker compose up --no-start --no-build web
      ["", "", true],                     # docker compose down
    ]
  end

  it "asks every question before creating anything, so the copy runs unattended" do
    sibling = @work.parent / "wt1"
    existence_at_each_prompt = []
    allow(Ctree::Prompt).to receive(:read_line) do
      existence_at_each_prompt << sibling.exist?
      ""
    end
    stub_clonefile
    allow(Ctree::Volume).to receive(:copy).and_return([fake_status(true), "", 1024])
    stub_sh(docker_capture3: three_copyable_volumes_stubs)

    Ctree::CLI.run(["create", "wt1", "wt1"])

    expect(existence_at_each_prompt).not_to be_empty
    expect(existence_at_each_prompt).to all(be(false))
    expect(sibling).to be_directory

    system("git", "-C", @work.to_s, "worktree", "remove", "--force", sibling.to_s,
           out: File::NULL, err: File::NULL)
  end

  it "copies at most volume_copy_concurrency volumes at once" do
    FileUtils.mkdir_p((@work / ".ctree").to_s)
    File.write((@work / ".ctree" / "config.yml").to_s, "volume_copy_concurrency: 2\n")
    system("git", "-C", @work.to_s, "add", ".ctree", out: File::NULL, err: File::NULL)
    system("git", "-C", @work.to_s, "commit", "-q", "--amend", "--no-edit",
           out: File::NULL, err: File::NULL)

    allow(Ctree::Prompt).to receive(:read_line).and_return("")
    stub_clonefile
    copied = []
    tracker = stub_concurrency_tracking_copy(copied)
    stub_sh(docker_capture3: three_copyable_volumes_stubs)

    Ctree::CLI.run(["create", "wt1", "wt1"])

    expect(copied.size).to eq(3)
    expect(tracker[:peak]).to eq(2)

    system("git", "-C", @work.to_s, "worktree", "remove", "--force",
           (@work.parent / "wt1").to_s, out: File::NULL, err: File::NULL)
  end

  it "copies volumes strictly one at a time when volume_copy_concurrency is 1" do
    FileUtils.mkdir_p((@work / ".ctree").to_s)
    File.write((@work / ".ctree" / "config.yml").to_s, "volume_copy_concurrency: 1\n")
    system("git", "-C", @work.to_s, "add", ".ctree", out: File::NULL, err: File::NULL)
    system("git", "-C", @work.to_s, "commit", "-q", "--amend", "--no-edit",
           out: File::NULL, err: File::NULL)

    allow(Ctree::Prompt).to receive(:read_line).and_return("")
    stub_clonefile
    copied = []
    tracker = stub_concurrency_tracking_copy(copied)
    stub_sh(docker_capture3: three_copyable_volumes_stubs)

    Ctree::CLI.run(["create", "wt1", "wt1"])

    expect(copied.size).to eq(3)
    expect(tracker[:peak]).to eq(1)

    system("git", "-C", @work.to_s, "worktree", "remove", "--force",
           (@work.parent / "wt1").to_s, out: File::NULL, err: File::NULL)
  end

  # Makes .env gitignored (as it is in real projects) so create's .env edits
  # don't leave unstaged changes that would block git rebase.
  def untrack_env
    File.write(".gitignore", ".env\n")
    system("git", "rm", "-q", "--cached", ".env", out: File::NULL, err: File::NULL)
    system("git", "add", ".gitignore", out: File::NULL, err: File::NULL)
    system("git", "commit", "-q", "-m", "ignore .env", out: File::NULL, err: File::NULL)
  end

  it "offers to rebase a stale existing branch onto master and rebases when accepted" do
    untrack_env
    system("git", "checkout", "-q", "-b", "stale", out: File::NULL, err: File::NULL)
    system("git", "checkout", "-q", "master", out: File::NULL, err: File::NULL)
    File.write("newer.rb", "# newer")
    system("git", "add", "newer.rb", out: File::NULL, err: File::NULL)
    system("git", "commit", "-q", "-m", "advance master", out: File::NULL, err: File::NULL)

    allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
    allow(Ctree::Prompt).to receive(:read_line) { |prompt| prompt =~ /rebase/ ? "y" : "n" }
    stub_clonefile
    stub_sh(docker_capture3: docker_stubs)

    expect {
      Ctree::CLI.run(["create", "wt1", "stale"])
    }.to output(/branch 'stale' is 1 commit\(s\) behind master/).to_stderr

    sibling = @work.parent / "wt1"
    expect(sibling / "newer.rb").to exist
    expect(`git -C #{sibling} rev-list --count HEAD..master`.strip).to eq("0")

    system("git", "-C", @work.to_s, "worktree", "remove", "--force", sibling.to_s,
           out: File::NULL, err: File::NULL)
  end

  it "leaves a stale branch unrebased when the user declines" do
    untrack_env
    system("git", "checkout", "-q", "-b", "stale", out: File::NULL, err: File::NULL)
    system("git", "checkout", "-q", "master", out: File::NULL, err: File::NULL)
    File.write("newer.rb", "# newer")
    system("git", "add", "newer.rb", out: File::NULL, err: File::NULL)
    system("git", "commit", "-q", "-m", "advance master", out: File::NULL, err: File::NULL)

    allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
    allow(Ctree::Prompt).to receive(:read_line).and_return("n")
    stub_clonefile
    stub_sh(docker_capture3: docker_stubs)

    expect {
      Ctree::CLI.run(["create", "wt1", "stale"])
    }.not_to raise_error

    sibling = @work.parent / "wt1"
    expect(sibling / "newer.rb").not_to exist
    expect(`git -C #{sibling} rev-list --count HEAD..master`.strip).to eq("1")

    system("git", "-C", @work.to_s, "worktree", "remove", "--force", sibling.to_s,
           out: File::NULL, err: File::NULL)
  end

  describe "master branch check" do
    it "does not prompt about master when source is already on master" do
      allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
      allow(Ctree::Prompt).to receive(:read_line).and_return("n")
      expect(Ctree::Prompt).not_to receive(:read_line).with(/master/)
      stub_clonefile
      stub_sh(docker_capture3: docker_stubs)

      expect {
        Ctree::CLI.run(["create", "wt1", "wt1"])
      }.not_to raise_error

      system("git", "-C", @work.to_s, "worktree", "remove", "--force", (@work.parent / "wt1").to_s,
             out: File::NULL, err: File::NULL)
    end

    it "exits when source is not on master, no uncommitted changes, user declines to switch" do
      system("git", "checkout", "-q", "-b", "feature-x", out: File::NULL, err: File::NULL)
      allow(Ctree::Prompt).to receive(:read_line).and_return("n")

      expect {
        Ctree::CLI.run(["create", "wt1", "wt1"])
      }.to raise_error(Ctree::Error)
    end

    it "exits when source is not on master, with uncommitted changes, user declines to stash and switch" do
      system("git", "checkout", "-q", "-b", "feature-x", out: File::NULL, err: File::NULL)
      File.write(".env", "COMPOSE_PROJECT_NAME=src\nDB_PORT=5432\nDIRTY=true\n")
      allow(Ctree::Prompt).to receive(:read_line).and_return("n")

      expect {
        Ctree::CLI.run(["create", "wt1", "wt1"])
      }.to raise_error(Ctree::Error)
    end

    it "switches source to master and continues when not on master, no uncommitted changes, user accepts" do
      system("git", "checkout", "-q", "-b", "feature-x", out: File::NULL, err: File::NULL)
      allow(Ctree::Prompt).to receive(:read_line) { |prompt| prompt =~ /switch source to master/ ? "y" : "n" }
      allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
      stub_clonefile
      stub_sh(docker_capture3: docker_stubs)

      expect {
        Ctree::CLI.run(["create", "wt1", "wt1"])
      }.not_to raise_error

      current = `git -C #{@work} rev-parse --abbrev-ref HEAD`.strip
      expect(current).to eq("master")

      system("git", "-C", @work.to_s, "worktree", "remove", "--force", (@work.parent / "wt1").to_s,
             out: File::NULL, err: File::NULL)
    end

    it "stashes uncommitted changes, switches to master, and continues when user accepts" do
      system("git", "checkout", "-q", "-b", "feature-x", out: File::NULL, err: File::NULL)
      File.write(".env", "COMPOSE_PROJECT_NAME=src\nDB_PORT=5432\nDIRTY=true\n")
      allow(Ctree::Prompt).to receive(:read_line) { |prompt| prompt =~ /stash uncommitted changes/ ? "y" : "n" }
      allow(Ctree::Prompt).to receive(:for_env_var_change) { |_key, value| value }
      stub_clonefile
      stub_sh(docker_capture3: docker_stubs)

      expect {
        Ctree::CLI.run(["create", "wt1", "wt1"])
      }.not_to raise_error

      current = `git -C #{@work} rev-parse --abbrev-ref HEAD`.strip
      expect(current).to eq("master")
      expect(`git -C #{@work} stash list`.strip).not_to be_empty

      system("git", "-C", @work.to_s, "worktree", "remove", "--force", (@work.parent / "wt1").to_s,
             out: File::NULL, err: File::NULL)
    end
  end
end

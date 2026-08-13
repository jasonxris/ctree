# frozen_string_literal: true

RSpec.describe "Ctree::Create.run_many" do
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
    allow(Ctree::Prompt).to receive(:read_line).and_return("")
    allow(Ctree::Clonefile).to receive(:available?).and_return(true)
    allow(Ctree::Clonefile).to receive(:clone) do |src, tgt|
      FileUtils.cp_r(src.to_s, tgt.to_s)
      true
    end
  end

  def write_config(body)
    FileUtils.mkdir_p((@work / ".ctree").to_s)
    File.write((@work / ".ctree" / "config.yml").to_s, body)
    system("git", "-C", @work.to_s, "add", ".ctree", out: File::NULL, err: File::NULL)
    system("git", "-C", @work.to_s, "commit", "-q", "--amend", "--no-edit",
           out: File::NULL, err: File::NULL)
  end

  # One docker call queue serves the whole batch, so it has to hold the calls
  # every tree makes. Volume copies go through Ctree::Volume, not docker.
  def stub_docker_for(tree_count, source_volumes: "src_data\n")
    per_tree = [
      ["", "", true],                 # docker images
      ["web\n", "", true],            # docker compose config --services
      ["", "", true],                 # docker compose up --no-start --no-build web
      ["", "", true]                  # docker compose down
    ]
    stub_sh(docker_capture3: [
      ["", "", true],                       # docker info
      ["", "", true],                       # docker ps source
      [source_volumes, "", true],           # docker volume ls
      ["1024\n107374182400\n", "", true]    # docker run -- free space, plenty
    ] + (per_tree * tree_count))
  end

  def cleanup(*names)
    names.each do |name|
      system("git", "-C", @work.to_s, "worktree", "remove", "--force",
             (@parent / name).to_s, out: File::NULL, err: File::NULL)
    end
  end

  it "builds every requested worktree and reports each one ready" do
    allow(Ctree::Volume).to receive(:copy).and_return([fake_status(true), "", 1024])
    stub_docker_for(2)

    results = Ctree::Create.run_many(trees: [
      { name: "wt1", branch: "wt1" },
      { name: "wt2", branch: "wt2" }
    ])

    expect(results.map(&:name)).to eq(%w[wt1 wt2])
    expect(results.map(&:status)).to eq(%i[ready ready])
    expect(@parent / "wt1").to be_directory
    expect(@parent / "wt2").to be_directory
    cleanup("wt1", "wt2")
  end

  it "asks its questions once for the whole batch, not once per worktree" do
    allow(Ctree::Volume).to receive(:copy).and_return([fake_status(true), "", 1024])
    stub_docker_for(3)

    Ctree::Create.run_many(trees: [
      { name: "wt1", branch: "wt1" },
      { name: "wt2", branch: "wt2" },
      { name: "wt3", branch: "wt3" }
    ])

    expect(Ctree::Prompt).to have_received(:read_line).once
    cleanup("wt1", "wt2", "wt3")
  end

  it "builds at most create_concurrency worktrees at once" do
    write_config("create_concurrency: 2\n")
    in_flight = 0
    peak = 0
    tracker = Mutex.new
    allow(Ctree::Create).to receive(:build).and_wrap_original do |original, *args, **kwargs|
      tracker.synchronize { in_flight += 1; peak = [peak, in_flight].max }
      begin
        original.call(*args, **kwargs)
      ensure
        tracker.synchronize { in_flight -= 1 }
      end
    end
    allow(Ctree::Volume).to receive(:copy) do
      sleep 0.05
      [fake_status(true), "", 1024]
    end
    stub_docker_for(4)

    Ctree::Create.run_many(trees: (1..4).map { |index| { name: "wt#{index}", branch: "wt#{index}" } })

    expect(peak).to eq(2)
    cleanup("wt1", "wt2", "wt3", "wt4")
  end

  it "labels the lines each tree emits with that tree's name" do
    allow(Ctree::Volume).to receive(:copy).and_return([fake_status(true), "", 1024])
    stub_docker_for(2)

    expect {
      Ctree::Create.run_many(trees: [
        { name: "wt1", branch: "wt1" },
        { name: "wt2", branch: "wt2" }
      ])
    }.to output(/wt1: copied source content.*wt2: copied source content/m).to_stdout

    cleanup("wt1", "wt2")
  end

  it "caps volume copies across the whole batch rather than per tree" do
    write_config("create_concurrency: 3\n")
    in_flight = 0
    peak = 0
    tracker = Mutex.new
    allow(Ctree::Volume).to receive(:copy) do
      tracker.synchronize { in_flight += 1; peak = [peak, in_flight].max }
      sleep 0.05
      tracker.synchronize { in_flight -= 1 }
      [fake_status(true), "", 1024]
    end
    stub_docker_for(2, source_volumes: "src_data\nsrc_logs\nsrc_cache\n")

    Ctree::Create.run_many(trees: [
      { name: "wt1", branch: "wt1" },
      { name: "wt2", branch: "wt2" }
    ])

    expect(peak).to eq(3)
    cleanup("wt1", "wt2")
  end

  it "lets healthy worktrees finish when one fails, and rolls the failure back" do
    allow(Ctree::Create).to receive(:rollback)
    allow(Ctree::Volume).to receive(:copy) do |src_vol, tgt_vol|
      raise Ctree::Error, "disk exploded" if tgt_vol.start_with?("wt2_")

      [fake_status(true), "", 1024]
    end
    stub_docker_for(2)

    results = Ctree::Create.run_many(trees: [
      { name: "wt1", branch: "wt1" },
      { name: "wt2", branch: "wt2" }
    ])

    expect(results.find { |result| result.name == "wt1" }.status).to eq(:ready)
    failed = results.find { |result| result.name == "wt2" }
    expect(failed.status).to eq(:failed)
    expect(failed.message).to match(/disk exploded/)
    expect(Ctree::Create).to have_received(:rollback).with(name: "wt2", delete_branch: true)
    expect(@parent / "wt1").to be_directory
    cleanup("wt1", "wt2")
  end

  it "tells rollback not to delete a branch the user brought" do
    system("git", "-C", @work.to_s, "branch", "existing-branch",
           out: File::NULL, err: File::NULL)
    allow(Ctree::Create).to receive(:rollback)
    allow(Ctree::Volume).to receive(:copy).and_raise(Ctree::Error.new("nope"))
    stub_docker_for(1)

    Ctree::Create.run_many(trees: [{ name: "wt1", branch: "existing-branch" }])

    expect(Ctree::Create).to have_received(:rollback).with(name: "wt1", delete_branch: false)
    cleanup("wt1")
  end

  it "refuses the whole batch when the trees together would not fit on disk" do
    stub_sh(docker_capture3: [
      ["", "", true],                          # docker info
      ["", "", true],                          # docker ps source
      ["src_data\n", "", true],                # docker volume ls
      ["5368709120\n8589934592\n", "", true]   # docker run -- 5GB each, 8GB available
    ])

    expect {
      expect {
        Ctree::Create.run_many(trees: [
          { name: "wt1", branch: "wt1" },
          { name: "wt2", branch: "wt2" }
        ])
      }.to raise_error(Ctree::Error, /not enough free space/)
    }.to output(/across 2 worktrees/).to_stderr

    expect(@parent / "wt1").not_to exist
    expect(@parent / "wt2").not_to exist
  end

  it "refuses a batch that asks for the same worktree twice" do
    expect {
      Ctree::Create.run_many(trees: [
        { name: "wt1", branch: "branch-a" },
        { name: "wt1", branch: "branch-b" }
      ])
    }.to raise_error(Ctree::Error, /requested more than once/)
  end

  it "refuses an empty batch" do
    expect {
      Ctree::Create.run_many(trees: [])
    }.to raise_error(Ctree::Error, /no worktrees requested/)
  end
end

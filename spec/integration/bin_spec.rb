# frozen_string_literal: true

require "open3"
require "tmpdir"

RSpec.describe "bin/ctree as a subprocess" do
  BIN = File.expand_path("../../bin/ctree", __dir__)

  it "exits 0 and prints the version" do
    stdout, _, status = Open3.capture3(BIN, "version")
    expect(status.exitstatus).to eq(0)
    expect(stdout).to match(/\Actree \d+\.\d+\.\d+\n\z/)
  end

  it "renders die as a ctree error line on stderr with exit 1" do
    Dir.mktmpdir do |not_a_repo|
      stdout, stderr, status = Open3.capture3(BIN, "config", "list", chdir: not_a_repo)
      expect(status.exitstatus).to eq(1)
      expect(stdout).to eq("")
      expect(stderr).to eq("[ctree] ERROR: not inside a git repository\n")
    end
  end

  it "prints usage and exits 1 for an unknown command" do
    stdout, _, status = Open3.capture3(BIN, "not-a-command")
    expect(status.exitstatus).to eq(1)
    expect(stdout).to include("Usage:")
  end
end

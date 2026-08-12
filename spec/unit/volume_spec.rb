# frozen_string_literal: true

RSpec.describe Ctree::Volume do
  describe ".copy_budget" do
    def stub_capture3(stdout, success: true)
      allow(Ctree::Sh).to receive(:capture3).and_return([stdout, "", fake_status(success)])
    end

    it "returns nil without shelling out when there is nothing to copy" do
      expect(Ctree::Sh).not_to receive(:capture3)
      expect(described_class.copy_budget([])).to be_nil
    end

    it "returns the needed and available byte counts" do
      stub_capture3("10262183526\n21220900864\n")
      expect(described_class.copy_budget(["src_data"])).to eq([10_262_183_526, 21_220_900_864])
    end

    it "mounts every volume read-only under a numbered path" do
      stub_capture3("1\n2\n")
      described_class.copy_budget(%w[src_a src_b])
      expect(Ctree::Sh).to have_received(:capture3).with(
        "docker", "run", "--rm",
        "-v", "src_a:/vol/0:ro",
        "-v", "src_b:/vol/1:ro",
        "alpine", "sh", "-c", a_string_including("du -sb /vol")
      )
    end

    it "measures free space from a mounted volume, not the container root" do
      stub_capture3("1\n2\n")
      described_class.copy_budget(["src_a"])
      expect(Ctree::Sh).to have_received(:capture3).with(
        any_args, "sh", "-c", a_string_including("df -PB1 /vol/0")
      )
    end

    it "returns nil when docker fails" do
      stub_capture3("", success: false)
      expect(described_class.copy_budget(["src_data"])).to be_nil
    end

    it "returns nil when the output cannot be parsed" do
      stub_capture3("not-a-number\nalso-not\n")
      expect(described_class.copy_budget(["src_data"])).to be_nil
    end

    it "returns nil when df reports no available space figure" do
      stub_capture3("10262183526\n")
      expect(described_class.copy_budget(["src_data"])).to be_nil
    end
  end
end

# frozen_string_literal: true

RSpec.describe Ctree::Prompt do
  let(:backend) do
    Class.new do
      attr_reader :calls
      attr_accessor :typed

      def initialize
        @calls = []
        @typed = ""
      end

      def info(message)
        calls << [:info, message]
      end

      def warn(message)
        calls << [:warn, message]
      end

      def debug(message)
        calls << [:debug, message]
      end

      def line(text = "")
        calls << [:line, text]
      end

      def section(title)
        calls << [:section, title]
        yield
      end

      def spin(message)
        calls << [:spin, message]
        yield
      end

      def progress(message)
        calls << [:progress, message]
        yield ->(percent) { calls << [:progress_update, percent] }
      end

      def read_line(prompt, prefixed: true)
        calls << [:read_line, prompt, prefixed]
        typed
      end
    end.new
  end

  before { Ctree.ui_backend = backend }
  after { Ctree.ui_backend = nil }

  def emitted
    backend.calls.map { |call| call[1].to_s }.join("\n")
  end

  describe ".copy_all_env?" do
    it "treats an empty answer as yes, so the common case is one keypress" do
      backend.typed = ""
      expect(described_class.copy_all_env?(%w[INST_DOMAIN DB_PORT], ".env")).to be(true)
    end

    it "accepts y and yes in any case" do
      backend.typed = "y"
      expect(described_class.copy_all_env?(%w[INST_DOMAIN], ".env")).to be(true)
      backend.typed = "YES"
      expect(described_class.copy_all_env?(%w[INST_DOMAIN], ".env")).to be(true)
    end

    it "declines on n, which routes the caller to per-variable prompts" do
      backend.typed = "n"
      expect(described_class.copy_all_env?(%w[INST_DOMAIN], ".env")).to be(false)
    end

    it "treats a nil answer as yes, since backends differ on EOF" do
      backend.typed = nil
      expect(described_class.copy_all_env?(%w[INST_DOMAIN], ".env")).to be(true)
    end

    it "names the keys and the env filename, and prints no values" do
      backend.typed = ""
      described_class.copy_all_env?(%w[INST_DOMAIN ARTIFACTORY_TOKEN], ".env.local")
      expect(emitted).to include("INST_DOMAIN", "ARTIFACTORY_TOKEN", ".env.local")
      expect(emitted).to include("2 .env.local values")
    end

    it "counts a single value in the singular" do
      backend.typed = ""
      described_class.copy_all_env?(%w[INST_DOMAIN], ".env")
      expect(emitted).to include("1 .env value to set")
    end
  end

  describe ".for_env_var_change" do
    it "prints the value for a non-secret key" do
      described_class.for_env_var_change("INST_DOMAIN", "inseng.test")
      expect(emitted).to include("INST_DOMAIN=inseng.test")
    end

    it "never emits the value of a secret key" do
      described_class.for_env_var_change("ARTIFACTORY_TOKEN", "cmVmdGtuOjAx")
      expect(emitted).not_to include("cmVmdGtuOjAx")
      expect(emitted).to include("ARTIFACTORY_TOKEN (hidden, 12 chars)")
    end

    it "never emits sibling worktree values of a secret key" do
      described_class.for_env_var_change(
        "OBSERVE_US_API_TOKEN", "51P1fndD",
        worktree_values: { "review-1" => "51P1fndD", "review-2" => "different-token" }
      )
      expect(emitted).not_to include("51P1fndD")
      expect(emitted).not_to include("different-token")
      expect(emitted).to include("review-1: same as source")
      expect(emitted).to include("review-2: differs")
    end

    it "still shows sibling worktree values of a non-secret key" do
      described_class.for_env_var_change(
        "INST_DOMAIN", "inseng.test", worktree_values: { "review-1" => "inseng.test" }
      )
      expect(emitted).to include("review-1: inseng.test")
    end

    it "offers to copy from source for a secret key" do
      described_class.for_env_var_change("ARTIFACTORY_TOKEN", "tok")
      expect(emitted).to include("enter to copy from source")
    end

    it "keeps the current value when the user presses enter" do
      backend.typed = ""
      expect(described_class.for_env_var_change("ARTIFACTORY_TOKEN", "tok")).to eq("tok")
    end

    it "keeps the current value when read_line returns nil" do
      backend.typed = nil
      expect(described_class.for_env_var_change("ARTIFACTORY_TOKEN", "tok")).to eq("tok")
    end

    it "takes a typed replacement for a secret key" do
      backend.typed = "new-token"
      expect(described_class.for_env_var_change("ARTIFACTORY_TOKEN", "tok")).to eq("new-token")
    end

    it "handles a nil current value without raising" do
      expect { described_class.for_env_var_change("ARTIFACTORY_TOKEN", nil) }.not_to raise_error
      expect(emitted).to include("(hidden, 0 chars)")
    end
  end
end

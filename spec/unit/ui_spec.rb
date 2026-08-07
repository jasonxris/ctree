# frozen_string_literal: true

RSpec.describe Ctree::UI do
  let(:backend) do
    Class.new do
      attr_reader :calls

      def initialize
        @calls = []
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

      def spin(message)
        calls << [:spin, message]
        yield
      end

      def read_line(prompt)
        calls << [:read_line, prompt]
        "typed"
      end
    end.new
  end

  after do
    Ctree.ui_backend = nil
    Ctree::Log.debug_mode = false
  end

  it "defaults to the plain backend" do
    expect(Ctree.ui_backend).to be_a(Ctree::UI::PlainBackend)
  end

  it "routes Log.info through the installed backend" do
    Ctree.ui_backend = backend
    Ctree::Log.info "hello"
    expect(backend.calls).to eq([[:info, "hello"]])
  end

  it "routes Log.warn_ through the installed backend" do
    Ctree.ui_backend = backend
    Ctree::Log.warn_ "careful"
    expect(backend.calls).to eq([[:warn, "careful"]])
  end

  it "gates Log.debug on debug mode before reaching the backend" do
    Ctree.ui_backend = backend
    Ctree::Log.debug "hidden"
    Ctree::Log.debug_mode = true
    Ctree::Log.debug "shown"
    expect(backend.calls).to eq([[:debug, "shown"]])
  end

  it "routes Spinner.with_spinner through the backend and returns the block value" do
    Ctree.ui_backend = backend
    result = Ctree::Spinner.with_spinner("working") { 42 }
    expect(result).to eq(42)
    expect(backend.calls).to eq([[:spin, "working"]])
  end

  it "routes Prompt.read_line through the backend" do
    Ctree.ui_backend = backend
    expect(Ctree::Prompt.read_line("? ")).to eq("typed")
    expect(backend.calls).to eq([[:read_line, "? "]])
  end

  describe Ctree::UI::PlainBackend do
    it "prints info lines with the ctree prefix" do
      expect { Ctree::Log.info "hello" }.to output("[ctree] hello\n").to_stdout
    end

    it "prints warnings with the ctree prefix on stderr" do
      expect { Ctree::Log.warn_ "careful" }.to output("[ctree] WARNING: careful\n").to_stderr
    end

    it "prints the spinner prefix once and returns the block value when stdout is not a tty" do
      result = nil
      expect { result = Ctree::Spinner.with_spinner("working") { 42 } }
        .to output("[ctree] working\n").to_stdout
      expect(result).to eq(42)
    end
  end
end

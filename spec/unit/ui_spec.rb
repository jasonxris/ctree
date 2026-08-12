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

      def line(text = "")
        calls << [:line, text]
      end

      def section(title)
        calls << [:section, title]
        yield
      end

      def progress(message)
        calls << [:progress, message]
        yield ->(percent) { calls << [:progress_update, percent] }
      end

      def group(title)
        calls << [:group, title]
        tasks = []
        yield ->(label, &work) { tasks << [label, work] }
        tasks.map do |label, work|
          calls << [:group_task, label]
          work.call(->(percent) { calls << [:group_update, label, percent] })
        end
      end

      def read_line(prompt, prefixed: true)
        calls << [:read_line, prompt, prefixed]
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
    expect(backend.calls).to eq([[:read_line, "? ", true]])
  end

  it "routes Log.line through the backend, defaulting to an empty line" do
    Ctree.ui_backend = backend
    Ctree::Log.line "detail"
    Ctree::Log.line
    expect(backend.calls).to eq([[:line, "detail"], [:line, ""]])
  end

  it "routes Log.section through the backend and yields its block" do
    Ctree.ui_backend = backend
    Ctree::Log.section("summary") { Ctree::Log.line "inside" }
    expect(backend.calls).to eq([[:section, "summary"], [:line, "inside"]])
  end

  it "routes Spinner.with_progress through the backend with a usable updater" do
    Ctree.ui_backend = backend
    result = Ctree::Spinner.with_progress("copying") { |report_progress| report_progress.call(50); :done }
    expect(result).to eq(:done)
    expect(backend.calls).to eq([[:progress, "copying"], [:progress_update, 50]])
  end

  it "routes Spinner.with_group through the backend and returns task values in registration order" do
    Ctree.ui_backend = backend
    result = Ctree::Spinner.with_group("copying volumes") do |register|
      register.call("first") { :one }
      register.call("second") { |report_progress| report_progress.call(50); :two }
    end
    expect(result).to eq([:one, :two])
    expect(backend.calls).to eq([
      [:group, "copying volumes"],
      [:group_task, "first"],
      [:group_task, "second"],
      [:group_update, "second", 50]
    ])
  end

  it "caps how many with_group tasks hold a permit at once" do
    Ctree.ui_backend = Ctree::UI::PlainBackend.new
    concurrent = 0
    peak = 0
    peak_mutex = Mutex.new

    Ctree::Spinner.with_group("bounded", concurrency: 2) do |register|
      6.times do |index|
        register.call("task #{index}") do
          peak_mutex.synchronize { concurrent += 1; peak = [peak, concurrent].max }
          sleep 0.05
          peak_mutex.synchronize { concurrent -= 1 }
          index
        end
      end
    end

    expect(peak).to eq(2)
  end

  it "returns with_group values in registration order even when tasks finish out of order" do
    Ctree.ui_backend = Ctree::UI::PlainBackend.new
    result = Ctree::Spinner.with_group("ordering", concurrency: 3) do |register|
      register.call("slow") { sleep 0.05; :slow }
      register.call("fast") { :fast }
    end
    expect(result).to eq([:slow, :fast])
  end

  it "re-raises a with_group task's exception after every task has finished" do
    Ctree.ui_backend = Ctree::UI::PlainBackend.new
    finished = []
    finished_mutex = Mutex.new

    expect do
      Ctree::Spinner.with_group("failing", concurrency: 2) do |register|
        register.call("boom") { raise Ctree::Error.new("copy failed", 2) }
        register.call("survivor") do
          sleep 0.02
          finished_mutex.synchronize { finished << :survivor }
        end
      end
    end.to raise_error(Ctree::Error, "copy failed")

    expect(finished).to eq([:survivor])
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

    it "prints lines bare, without the ctree prefix" do
      expect { Ctree::Log.line "  row" }.to output("  row\n").to_stdout
    end

    it "prints a section as a blank line and banner before its body" do
      expect { Ctree::Log.section("worktrees") { Ctree::Log.line "  row" } }
        .to output("\n=== worktrees ===\n  row\n").to_stdout
    end

    it "prints the group title, then one line per task as it completes" do
      output = nil
      expect do
        output = Ctree::Spinner.with_group("copying volumes") do |register|
          register.call("copying pg_data") { :done }
        end
      end.to output("[ctree] copying volumes\n[ctree]   copying pg_data (0s)\n").to_stdout
      expect(output).to eq([:done])
    end

    it "yields progress silently and returns the block value when stdout is not a tty" do
      result = nil
      expect { result = Ctree::Spinner.with_progress("copying") { |report_progress| report_progress.call(10); 7 } }
        .to output("").to_stdout
      expect(result).to eq(7)
    end
  end
end

# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "pathname"
require "yaml"

module Ctree
  begin
    require "readline"
    HAS_READLINE = true
  rescue LoadError
    HAS_READLINE = false
  end

  PROG = "ctree"
  NAME_PATTERN = /\A[a-z0-9][a-z0-9_-]*\z/.freeze
  # Branch names are more permissive than the worktree/compose name (which
  # doubles as a Docker compose project prefix). Allow letters, digits, ., _,
  # -, and /.
  BRANCH_NAME_PATTERN = %r{\A[A-Za-z0-9][A-Za-z0-9._/-]*\z}.freeze

  SPINNER_FRAMES = %w[| / - \\].freeze

  class Error < StandardError
    attr_reader :exit_code

    def initialize(message, exit_code = 1)
      super(message)
      @exit_code = exit_code
    end
  end

  class ExitStatus < StandardError
    attr_reader :exit_code

    def initialize(exit_code)
      super("exit status #{exit_code}")
      @exit_code = exit_code
    end
  end

  class << self
    attr_writer :ui_backend

    def ui_backend
      @ui_backend ||= UI::PlainBackend.new
    end
  end

  module Log
    @debug = false

    module_function

    def debug_mode=(val)
      @debug = val
    end

    def debug?
      @debug
    end

    def debug(msg)
      Ctree.ui_backend.debug(msg) if @debug
    end

    def info(msg)
      Ctree.ui_backend.info(msg)
    end

    def warn_(msg)
      Ctree.ui_backend.warn(msg)
    end

    def line(text = "")
      Ctree.ui_backend.line(text)
    end

    def section(title, &block)
      Ctree.ui_backend.section(title, &block)
    end

    def die(msg, code = 1)
      raise Error.new(msg, code)
    end
  end

  # Single seam for shelling out. Integration tests stub these.
  module Sh
    module_function

    def capture3(*cmd, **opts)
      Open3.capture3(*cmd, **opts)
    end

    def popen3(*cmd, &blk)
      Open3.popen3(*cmd, &blk)
    end

    def system(*cmd, **kw)
      Kernel.system(*cmd, **kw)
    end

    def spawn(*cmd, **kw)
      Process.spawn(*cmd, **kw)
    end

    def detach(pid)
      Process.detach(pid)
    end
  end

  module EnvFile
    module_function

    def parse(path)
      return {} unless File.file?(path)
      result = {}
      File.foreach(path) do |raw|
        line = raw.strip
        next if line.empty? || line.start_with?("#")
        next unless line.include?("=")
        key, value = line.split("=", 2)
        key = key.strip.sub(/\Aexport\s+/, "")
        value = value.strip
        if (value.start_with?('"') && value.end_with?('"')) ||
           (value.start_with?("'") && value.end_with?("'"))
          value = value[1..-2]
        end
        result[key] = value
      end
      result
    end

    def delete(path, key)
      return unless File.file?(path)
      pattern = /\A\s*#{Regexp.escape(key)}\s*=/
      lines = File.readlines(path).reject { |l| l =~ pattern }
      File.write(path, lines.join)
    end

    def upsert(path, key, value)
      new_line = "#{key}=#{value}"
      unless File.file?(path)
        File.write(path, new_line + "\n")
        return :created
      end

      lines = File.readlines(path)
      matched = false
      pattern = /\A\s*#{Regexp.escape(key)}\s*=/
      lines.map! do |line|
        if line =~ pattern
          matched = true
          keep_newline = line.end_with?("\n") ? "\n" : ""
          new_line + keep_newline
        else
          line
        end
      end

      unless matched
        if lines.any? && !lines.last.end_with?("\n")
          lines[-1] = lines.last + "\n"
        end
        lines << new_line + "\n"
      end

      File.write(path, lines.join)
      matched ? :replaced : :appended
    end
  end

  module Naming
    module_function

    def sanitize_compose_project_name(str)
      out = str.downcase.gsub(/[^a-z0-9_-]/, "_")
      out.sub(/\A[^a-z0-9]+/, "")
    end
  end

  module Sizes
    module_function

    def human(bytes)
      return "0B" unless bytes && bytes > 0
      units = %w[B KB MB GB TB]
      i = 0
      size = bytes.to_f
      while size >= 1024 && i < units.length - 1
        size /= 1024
        i += 1
      end
      format("%.1f%s", size, units[i])
    end
  end

  module Spinner
    module_function

    def with_spinner(msg, &block)
      Ctree.ui_backend.spin(msg, &block)
    end

    def with_progress(msg, &block)
      Ctree.ui_backend.progress(msg, &block)
    end
  end

  module Prompt
    module_function

    def read_line(prompt)
      Ctree.ui_backend.read_line(prompt)
    end

    def for_db_port_change(current_port)
      loop do
        prompt = "[#{PROG}] DB_PORT=#{current_port}. Press enter to keep, or type a new port: "
        raw = read_line(prompt)
        return current_port if raw.nil?

        answer = raw.gsub(/[\x00-\x1f\x7f]/, "").strip
        return current_port if answer.empty?

        unless answer =~ /\A\d+\z/
          Log.warn_ "#{answer.inspect} is not a valid port; please enter digits only (1-65535)"
          next
        end
        port = answer.to_i
        unless port.between?(1, 65_535)
          Log.warn_ "port #{port} is out of range; must be 1-65535"
          next
        end
        return port.to_s
      end
    end

    # Generic prompt for any .env variable. Prints key=value as a log line
    # then prompts on a short second line — avoids Readline redraw artifacts
    # caused by prompts longer than the terminal width.
    def for_env_var_change(key, current_value, worktree_values: {})
      Log.info "#{key}=#{current_value}"
      if worktree_values.any?
        pad = worktree_values.keys.map(&:length).max
        worktree_values.each { |wt, val| Log.line "  #{wt.ljust(pad)}: #{val}" }
      end
      raw = read_line("  (enter to keep, or type a new value): ")
      return current_value if raw.nil?
      answer = raw.gsub(/[\x00-\x1f\x7f]/, "").strip
      answer.empty? ? current_value : answer
    end
  end

  module Volume
    RSYNC_IMAGE = "ctree-rsync:1"

    module_function

    def ensure_rsync_image!
      _, _, st = Sh.capture3("docker", "image", "inspect", RSYNC_IMAGE)
      return if st.success?

      _, err, build_st = Spinner.with_spinner("building ctree-rsync image") do
        Sh.capture3(
          "docker", "build", "-t", RSYNC_IMAGE, "-",
          stdin_data: "FROM alpine:3\nRUN apk add --no-cache rsync\n"
        )
      end
      Log.die "failed to build ctree-rsync image: #{err.strip}" unless build_st.success?
      Log.info "built ctree-rsync image"
    end

    def copy_with_progress(src_vol, tgt_vol)
      # The same container that runs cp -a also samples /to size every 1s
      # and emits a PROGRESS line, so we get real byte-level progress
      # without spawning extra docker invocations.
      script = <<~SH
        total=$(du -sb /from 2>/dev/null | awk '{print $1}')
        echo "TOTAL:$total"
        ( cd /from && cp -a . /to/ ) &
        cp_pid=$!
        while kill -0 "$cp_pid" 2>/dev/null; do
          sleep 1
          current=$(du -sb /to 2>/dev/null | awk '{print $1}')
          echo "PROGRESS:$current"
        done
        wait "$cp_pid"
      SH

      cmd = [
        "docker", "run", "--rm",
        "-v", "#{src_vol}:/from:ro",
        "-v", "#{tgt_vol}:/to",
        "alpine", "sh", "-c", script
      ]

      start_time = Time.now
      total_bytes = nil
      current_bytes = 0
      err_buf = +""
      exit_status = nil

      Log.debug "copying #{src_vol} -> #{tgt_vol}" unless $stdout.tty?

      Spinner.with_progress("copying #{src_vol} -> #{tgt_vol}") do |report_progress|
        Sh.popen3(*cmd) do |_stdin, stdout, stderr, wait_thr|
          err_thread = Thread.new { err_buf << stderr.read.to_s }

          stdout.each_line do |raw|
            line = raw.strip
            if line.start_with?("TOTAL:")
              total_bytes = line.sub("TOTAL:", "").to_i
            elsif line.start_with?("PROGRESS:")
              current_bytes = line.sub("PROGRESS:", "").to_i
            end
            percent = (total_bytes && total_bytes > 0) ? [(current_bytes.to_f / total_bytes * 100).round, 100].min : 0
            report_progress.call(percent)
          end

          err_thread.join
          exit_status = wait_thr.value
        end
      end

      elapsed = (Time.now - start_time).to_i
      if exit_status.success?
        size_part = total_bytes && total_bytes > 0 ? "#{Sizes.human(total_bytes)} in " : ""
        Log.debug "copied #{src_vol} -> #{tgt_vol} (#{size_part}#{elapsed}s)"
      end

      [exit_status, err_buf, total_bytes]
    end

    def rsync_with_progress(src_vol, tgt_vol)
      cmd = [
        "docker", "run", "--rm",
        "-v", "#{src_vol}:/from:ro",
        "-v", "#{tgt_vol}:/to",
        RSYNC_IMAGE, "sh", "-c", "rsync -a --delete --stats /from/ /to/"
      ]

      out, err, st = Spinner.with_spinner("updating #{src_vol} -> #{tgt_vol}") do
        Sh.capture3(*cmd)
      end

      transferred_bytes = 0
      out.each_line do |line|
        if line =~ /Total transferred file size:\s+([\d,]+)\s+bytes/
          transferred_bytes = $1.tr(",", "").to_i
          break
        end
      end

      [st, err, transferred_bytes]
    end
  end

  module Images
    module_function

    # Tags every source-project image (<source_project>-<service>) to the
    # corresponding <target_project>-<service> name. Docker tags are metadata
    # pointers, so this is instant and lets the worktree's `docker compose up`
    # skip rebuilding identical images. Re-running picks up freshly built
    # source layers (e.g. after rebuilding source images). Returns the list of
    # [src_img, tgt_img] pairs that were tagged.
    def tag_to_target(source_project, target_project)
      images_out, _, _ = Sh.capture3("docker", "images",
                                     "--format", "{{.Repository}}",
                                     "--filter", "label=com.docker.compose.project=#{source_project}",
                                     "--filter", "reference=#{source_project}-*")
      tagged = []
      images_out.lines.map(&:strip).reject(&:empty?).each do |src_img|
        suffix = src_img.sub("#{source_project}-", "")
        tgt_img = "#{target_project}-#{suffix}"
        _, _, st = Sh.capture3("docker", "tag", src_img, tgt_img)
        if st.success?
          Log.debug "tagged #{src_img} -> #{tgt_img}"
          tagged << [src_img, tgt_img]
        end
      end
      tagged
    end

    # Maps service suffix -> image ID for a project. Source images are matched
    # by both the compose-project label AND the name prefix (the label excludes
    # other worktrees' tags that share the prefix). Worktree-tagged images are
    # matched by name prefix ONLY: `docker tag` copies the image — including the
    # source's com.docker.compose.project label — so the label cannot identify
    # them; the <target>-* name is the only discriminator.
    def ids_by_service(project, by_label:)
      filters = ["--filter", "reference=#{project}-*"]
      filters += ["--filter", "label=com.docker.compose.project=#{project}"] if by_label
      out, _, st = Sh.capture3("docker", "images", "--no-trunc",
                               "--format", "{{.Repository}}\t{{.ID}}", *filters)
      return {} unless st.success?
      out.lines.each_with_object({}) do |line, h|
        repo, id = line.strip.split("\t", 2)
        next if repo.nil? || id.nil?
        h[repo.sub("#{project}-", "")] = id
      end
    end

    # Returns service suffixes whose source image ID differs from (or is
    # missing on) the worktree's tagged image — i.e. a sync would update them.
    def stale_services(source_project, target_project)
      source_ids = ids_by_service(source_project, by_label: true)
      target_ids = ids_by_service(target_project, by_label: false)
      source_ids.filter_map { |svc, src_id| svc if target_ids[svc] != src_id }
    end
  end

  # Wraps the darwin clonefile(2) syscall via FFI so ctree can clone an
  # entire directory tree with a single syscall — dramatically faster than
  # `cp -c -R`, which calls clonefile per file. On non-darwin platforms
  # (or if libSystem can't be loaded), `available?` returns false and
  # callers fall back to the next strategy.
  module Clonefile
    module_function

    begin
      if RUBY_PLATFORM =~ /darwin/
        require "fiddle"
        require "fiddle/import"

        module Lib
          extend Fiddle::Importer
          dlload "libSystem.dylib"
          extern "int clonefile(const char *src, const char *dst, unsigned int flags)"
        end

        AVAILABLE = true
      else
        AVAILABLE = false
      end
    rescue LoadError, Fiddle::DLError, NameError
      AVAILABLE = false
    end

    def available?
      AVAILABLE
    end

    # Single-syscall whole-tree clone. Returns true on success, false
    # otherwise. Target must NOT exist (clonefile fails with EEXIST if it
    # does); caller is responsible for that precondition.
    # Note: clonefile follows symlinks in src regardless of flag 0x0002 on
    # some macOS versions. Callers should handle symlinks via File.symlink?
    # before calling clone() to avoid dereferencing.
    def clone(src, tgt)
      return false unless AVAILABLE
      Lib.clonefile(src.to_s, tgt.to_s, 0) == 0
    end
  end

  module ComposeOverride
    module_function

    # Pure check. Returns {ok: [...], fixable: [...], unfixable: [...]}.
    # ok        = suffixes with correct external reference already present
    # fixable   = suffixes missing from override but source volume exists in Docker
    # unfixable = suffixes missing from override and source volume not in Docker
    def audit(target_path:, override_rel:, share_volumes:, source_project:, source_volumes:)
      override_path = Pathname.new(target_path) / override_rel
      unless override_path.file?
        return { ok: [], fixable: [], unfixable: share_volumes.dup }
      end

      begin
        raw = File.read(override_path.to_s)
        stream = Psych.parse_stream(raw)
        doc_node = stream.children.first
        return { ok: [], fixable: [], unfixable: share_volumes.dup } unless doc_node
        root = doc_node.children.first
        return { ok: [], fixable: [], unfixable: share_volumes.dup } unless root.is_a?(Psych::Nodes::Mapping)

        existing = extract_existing_volumes(root, source_project)

        ok = []
        missing = []
        share_volumes.each do |suffix|
          e = existing[suffix]
          if e && e[:external] && e[:name] == "#{source_project}_#{suffix}"
            ok << suffix
          else
            missing << suffix
          end
        end

        fixable, unfixable = missing.partition { |s| source_volumes.include?("#{source_project}_#{s}") }
        { ok: ok, fixable: fixable, unfixable: unfixable }
      rescue Psych::SyntaxError => e
        Log.warn_ "could not parse #{override_rel}: #{e.message}; skipping shared volume validation"
        { ok: [], fixable: [], unfixable: share_volumes.dup }
      end
    end

    # Returns true when all share_volumes have correct external refs (no Docker call).
    def valid?(target_path:, override_rel:, share_volumes:, source_project:)
      return true if override_rel.empty? || share_volumes.empty?
      all_expected = share_volumes.map { |s| "#{source_project}_#{s}" }
      result = audit(
        target_path: target_path, override_rel: override_rel,
        share_volumes: share_volumes, source_project: source_project,
        source_volumes: all_expected
      )
      result[:fixable].empty? && result[:unfixable].empty?
    end

    # Warn-only, no prompts, no file writes. Called by ctree create.
    def check(target_path:, override_rel:, share_volumes:, source_project:, source_volumes:)
      return if override_rel.empty? || share_volumes.empty?

      result = audit(
        target_path: target_path, override_rel: override_rel,
        share_volumes: share_volumes, source_project: source_project,
        source_volumes: source_volumes
      )

      result[:unfixable].each do |suffix|
        Log.warn_ "share volume '#{suffix}' missing from #{override_rel} " \
                  "and source volume #{source_project}_#{suffix} not found in Docker"
      end

      if result[:fixable].any?
        n = result[:fixable].size
        Log.warn_ "#{n} share volume#{n == 1 ? "" : "s"} missing external reference " \
                  "in #{override_rel}: #{result[:fixable].join(", ")}"
        Log.warn_ "run `ctree compose-config fix` to fix"
      end
    end

    # Fix without prompts. Called by ctree compose-config fix.
    # Returns true if any fixes were applied, false otherwise.
    def fix(target_path:, override_rel:, share_volumes:, source_project:, source_volumes:)
      override_path = Pathname.new(target_path) / override_rel
      unless override_path.file?
        Log.warn_ "#{override_rel} not found; nothing to fix"
        return false
      end

      result = audit(
        target_path: target_path, override_rel: override_rel,
        share_volumes: share_volumes, source_project: source_project,
        source_volumes: source_volumes
      )

      result[:unfixable].each do |suffix|
        src_name = "#{source_project}_#{suffix}"
        Log.warn_ "source volume #{src_name} not found in Docker; skipping #{suffix}"
      end

      return false if result[:fixable].empty?

      begin
        raw = File.read(override_path.to_s)
        stream = Psych.parse_stream(raw)
        doc_node = stream.children.first
        return false unless doc_node
        root = doc_node.children.first
        return false unless root.is_a?(Psych::Nodes::Mapping)

        volumes_node = find_or_create_volumes_node(root)
        unless volumes_node.is_a?(Psych::Nodes::Mapping)
          Log.warn_ "#{override_rel}: 'volumes' is not a mapping; cannot fix"
          return false
        end

        result[:fixable].each do |suffix|
          src_name = "#{source_project}_#{suffix}"
          entry = Psych::Nodes::Mapping.new
          entry.children << Psych::Nodes::Scalar.new("external")
          entry.children << Psych::Nodes::Scalar.new("true", nil, nil, true, false)
          entry.children << Psych::Nodes::Scalar.new("name")
          entry.children << Psych::Nodes::Scalar.new(src_name)
          volumes_node.children << Psych::Nodes::Scalar.new(suffix)
          volumes_node.children << entry
          Log.debug "fixed #{suffix} -> #{src_name} in #{override_rel}"
        end

        File.write(override_path.to_s, stream.to_yaml)
        n = result[:fixable].size
        Log.info "fixed #{n} share volume#{n == 1 ? "" : "s"} in #{override_rel}: #{result[:fixable].join(", ")}"
        true
      rescue Psych::SyntaxError => e
        Log.warn_ "could not parse #{override_rel}: #{e.message}; fix aborted"
        false
      end
    end

    # Internal: extract volume entries from a root mapping node.
    # Returns a hash of suffix => {external:, name:}.
    def extract_existing_volumes(root, _source_project = nil)
      vol_key_idx = find_volumes_key_idx(root)
      existing = {}
      if vol_key_idx
        volumes_node = root.children[vol_key_idx + 1]
        if volumes_node.is_a?(Psych::Nodes::Mapping)
          volumes_node.children.each_slice(2) do |key_node, val_node|
            next unless key_node.is_a?(Psych::Nodes::Scalar)
            suffix = key_node.value
            next unless val_node.is_a?(Psych::Nodes::Mapping)
            ext = false
            name = nil
            val_node.children.each_slice(2) do |k, v|
              next unless k.is_a?(Psych::Nodes::Scalar) && v.is_a?(Psych::Nodes::Scalar)
              ext = true if k.value == "external" && v.value == "true"
              name = v.value if k.value == "name"
            end
            existing[suffix] = { external: ext, name: name }
          end
        end
      end
      existing
    end

    # Internal: find the index of the "volumes" key in a root mapping node.
    def find_volumes_key_idx(root)
      vol_key_idx = nil
      root.children.each_with_index do |child, i|
        if i.even? && child.is_a?(Psych::Nodes::Scalar) && child.value == "volumes"
          vol_key_idx = i
          break
        end
      end
      vol_key_idx
    end

    # Internal: find or create the volumes mapping node under root.
    def find_or_create_volumes_node(root)
      vol_key_idx = find_volumes_key_idx(root)
      if vol_key_idx
        root.children[vol_key_idx + 1]
      else
        m = Psych::Nodes::Mapping.new
        root.children << Psych::Nodes::Scalar.new("volumes")
        root.children << m
        m
      end
    end

    private_class_method :extract_existing_volumes, :find_volumes_key_idx, :find_or_create_volumes_node
  end

end

require_relative "ctree/version"
require_relative "ctree/ui"
require_relative "ctree/config"
require_relative "ctree/cli"
require_relative "ctree/create"
require_relative "ctree/rebase"
require_relative "ctree/delete"
require_relative "ctree/domain"
require_relative "ctree/list"
require_relative "ctree/switch"
require_relative "ctree/update"
require_relative "ctree/free"
require_relative "ctree/env_cmd"
require_relative "ctree/compose_config_cmd"
require_relative "ctree/shell_init"

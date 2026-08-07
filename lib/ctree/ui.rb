# frozen_string_literal: true

module Ctree
  module UI
    class PlainBackend
      def info(message)
        puts "[#{PROG}] #{message}"
      end

      def warn(message)
        Kernel.warn "[#{PROG}] WARNING: #{message}"
      end

      def debug(message)
        puts "[#{PROG}] #{message}"
      end

      def line(text = "")
        puts text
      end

      def section(title)
        puts
        puts "=== #{title} ==="
        yield
      end

      def spin(message)
        prefix = "[#{PROG}] #{message}"
        unless $stdout.tty?
          puts prefix
          return yield
        end

        start_time = Time.now
        state_mutex = Mutex.new
        done = false
        result = nil

        spinner_thread = Thread.new do
          spinner_idx = 0
          until state_mutex.synchronize { done }
            elapsed = (Time.now - start_time).to_i
            line = format("%s (%s) %ds",
                          prefix,
                          SPINNER_FRAMES[spinner_idx % SPINNER_FRAMES.length],
                          elapsed)
            print "\r\e[K#{line}"
            $stdout.flush
            spinner_idx += 1
            sleep 0.1
          end
        end

        begin
          result = yield
        ensure
          state_mutex.synchronize { done = true }
          spinner_thread.join
          print "\r\e[K"
          $stdout.flush
        end

        result
      end

      def progress(message)
        return yield(->(_percent) {}) unless $stdout.tty?

        start_time = Time.now
        state_mutex = Mutex.new
        done = false
        current_percent = 0
        result = nil

        render_thread = Thread.new do
          spinner_idx = 0
          until state_mutex.synchronize { done }
            percent = state_mutex.synchronize { current_percent }
            elapsed = (Time.now - start_time).to_i
            print format("\r\e[K[%s] %s %d%% (%s) %ds",
                         PROG, message, percent,
                         SPINNER_FRAMES[spinner_idx % SPINNER_FRAMES.length], elapsed)
            $stdout.flush
            spinner_idx += 1
            sleep 0.1
          end
        end

        begin
          result = yield ->(percent) { state_mutex.synchronize { current_percent = percent } }
        ensure
          state_mutex.synchronize { done = true }
          render_thread.join
          print "\r\e[K"
          $stdout.flush
        end

        result
      end

      def read_line(prompt)
        if HAS_READLINE
          Readline.readline(prompt, false)
        else
          print prompt
          $stdout.flush
          line = $stdin.gets
          line&.chomp
        end
      end
    end
  end
end

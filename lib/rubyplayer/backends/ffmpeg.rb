require "json"
require "open3"

module RubyPlayer
  module Backends
    # Backend for ordinary audio files handled by FFmpeg: mp3, m4a/aac, flac,
    # alac, ogg/vorbis, opus, wav, aiff, and many others. FFmpeg decodes to the
    # same canonical format as the native backends: interleaved float32 stereo.
    class Ffmpeg
      class Error < StandardError; end

      READ_SIZE = 16 * 1024

      # Tags folded into named metadata fields; everything else lands in
      # :extra rather than being silently dropped.
      CONSUMED_TAGS = %w[title album artist album_artist composer track].freeze

      def name = "ffmpeg"

      def track_count(_path) = 1

      def metadata(path, _subtune_index)
        data = probe(path)
        stream = data.fetch("streams", []).find { |s| s["codec_type"] == "audio" } || {}
        format = data.fetch("format", {})
        tags = merged_tags(format, stream)

        {
          title: presence(tags["title"]) || File.basename(path, ".*"),
          album: presence(tags["album"]),
          artist: presence(tags["artist"]) || presence(tags["album_artist"]),
          album_artist: presence(tags["album_artist"]),
          composer: presence(tags["composer"]),
          track_number: parse_track_number(tags["track"]),
          year: parse_year(tags),
          duration_ms: duration_ms(format, stream),
          format: File.extname(path).delete_prefix(".").downcase,
          extra: extra_tags(tags),
        }
      end

      def open(path, _subtune_index, sample_rate:)
        duration = metadata(path, 0)[:duration_ms]
        Handle.new(path, sample_rate, duration)
      end

      class Handle
        attr_reader :duration_ms

        def initialize(path, sample_rate, duration_ms)
          @path = path
          @sample_rate = sample_rate
          @duration_ms = duration_ms
          @position_ms = 0
          @closed = false
          start_process(0)
        end

        # Returns packed float32 stereo, or nil at EOF. FFmpeg is asked to emit
        # native float32 samples directly, so there is no Ruby-side sample
        # conversion loop in the hot path.
        def read(frames)
          return nil if @closed || @stdout.nil? || @wait_thread.nil?

          bytes_wanted = frames * 2 * 4
          chunk = read_exactly(bytes_wanted)
          return nil if chunk.nil? || chunk.empty?

          @position_ms += ((chunk.bytesize / 8.0) / @sample_rate * 1000).round
          chunk
        end

        # FFmpeg cannot seek an already-running pipe, so seeking restarts the
        # decoder with -ss before -i. For a TUI player this is simple and robust,
        # and FFmpeg handles fast seeking for common file formats.
        def seek(ms)
          return false if @closed

          stop_process
          @position_ms = ms
          start_process(ms)
          true
        end

        def position_ms
          return 0 if @closed

          @position_ms
        end

        def close
          @closed = true
          stop_process
        end

        private

        def start_process(start_ms)
          cmd = [
            "ffmpeg",
            "-hide_banner",
            "-loglevel", "error",
            "-nostdin",
            "-ss", format("%.3f", start_ms / 1000.0),
            "-i", @path,
            "-map", "0:a:0",
            "-vn",
            "-f", "f32le",
            "-acodec", "pcm_f32le",
            "-ac", "2",
            "-ar", @sample_rate.to_s,
            "pipe:1",
          ]

          @stdin, @stdout, @stderr, @wait_thread = Open3.popen3(*cmd)
          @stdin.close
        rescue Errno::ENOENT
          raise Error, "ffmpeg executable not found; install it with `brew install ffmpeg`"
        end

        def stop_process
          @stdout&.close unless @stdout&.closed?
          @stderr&.close unless @stderr&.closed?

          if @wait_thread&.alive?
            Process.kill("TERM", @wait_thread.pid)
            @wait_thread.join(1)
            Process.kill("KILL", @wait_thread.pid) if @wait_thread.alive?
          end
        rescue Errno::ESRCH, IOError
          nil
        ensure
          @stdin = nil
          @stdout = nil
          @stderr = nil
          @wait_thread = nil
        end

        def read_exactly(bytes_wanted)
          out = +"".b
          while out.bytesize < bytes_wanted
            chunk = @stdout.readpartial([READ_SIZE, bytes_wanted - out.bytesize].min)
            out << chunk
          end
          out
        rescue EOFError
          out.empty? ? nil : out
        end
      end

      private

      def probe(path)
        stdout, stderr, status = Open3.capture3(
          "ffprobe",
          "-v", "error",
          "-print_format", "json",
          "-show_format",
          "-show_streams",
          path,
        )
        raise Error, stderr unless status.success?
        JSON.parse(stdout)
      rescue Errno::ENOENT
        raise Error, "ffprobe executable not found; install it with `brew install ffmpeg`"
      rescue JSON::ParserError => e
        raise Error, "ffprobe returned invalid JSON for #{path}: #{e.message}"
      end

      def merged_tags(format, stream)
        format_tags = normalize_tags(format.fetch("tags", {}))
        stream_tags = normalize_tags(stream.fetch("tags", {}))
        format_tags.merge(stream_tags)
      end

      def normalize_tags(tags)
        tags.each_with_object({}) { |(key, value), h| h[key.to_s.downcase] = value.to_s.scrub }
      end

      # ID3v2.3 (TYER), v2.4 (TDRC), MP4 (©day) and Vorbis (DATE) all funnel
      # into these ffprobe tag names; the first plausible 4-digit number wins.
      def parse_year(tags)
        %w[date year tdrc tdrl originaldate].each do |key|
          match = tags[key].to_s[/\b(1\d{3}|2\d{3})\b/]
          return match.to_i if match
        end
        nil
      end

      def extra_tags(tags)
        limit = RubyPlayer::DEFAULTS["library"]["metadata_value_limit"]
        tags.each_with_object({}) do |(key, value), extras|
          next if CONSUMED_TAGS.include?(key) || value.empty?

          # byteslice can split a multibyte character; the second scrub
          # (normalize_tags already scrubbed once) repairs it.
          extras[key] = value.byteslice(0, limit).scrub
        end
      end

      def duration_ms(format, stream)
        seconds = stream["duration"] || format["duration"]
        return nil unless seconds

        (seconds.to_f * 1000).round
      end

      def parse_track_number(value)
        return nil if value.nil? || value.empty?

        value.to_s.split("/", 2).first.to_i
      end

      def presence(str) = str.nil? || str.empty? ? nil : str
    end
  end
end

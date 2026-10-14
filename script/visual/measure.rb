# frozen_string_literal: true

require 'open3'

module Visual
  # Pixel measurements of album art in a window capture. The snapshot cover
  # is solid magenta with a centered cyan square, so the art is found by
  # color alone, and the square's shape reveals distortion independently of
  # the small edge crop the renderer may apply.
  class Measure
    # Channel distance treated as "not background" when scanning outward
    # from the art for a border line; antialiased glyph edges fall below it.
    LINE_THRESHOLD = 60
    # Art pixels must fill a solid square block this many pixels on a side,
    # which excludes border lines (corners included) and text that happen
    # to share the cover's colors (the default theme's active border is cyan).
    MIN_PATCH = 8

    attr_reader :width, :height

    def self.from_png(path)
      dims, status = Open3.capture2('ffprobe', '-v', 'error', '-select_streams', 'v:0',
                                    '-show_entries', 'stream=width,height', '-of', 'csv=p=0', path)
      raise "ffprobe failed on #{path}" unless status.success?

      width, height = dims.strip.split(',').map(&:to_i)
      raw, status = Open3.capture2('ffmpeg', '-v', 'error', '-i', path, '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-',
                                   binmode: true)
      raise "ffmpeg failed on #{path}" unless status.success?

      new(raw, width, height)
    end

    def initialize(rgb, width, height)
      @rgb = rgb
      @width = width
      @height = height
    end

    def pixel(col, row)
      offset = ((row * @width) + col) * 3
      @rgb.byteslice(offset, 3).bytes
    end

    # Everything at once, as plain data for reports and assertions.
    def result
      art = bounding_box { |r, g, b| magenta?(r, g, b) || cyan?(r, g, b) }
      return { found: false } unless art

      square = bounding_box { |r, g, b| cyan?(r, g, b) }
      {
        found: true,
        art: art,
        square: square,
        square_aspect: square && square[:w].fdiv(square[:h]),
        gaps: gaps(art)
      }
    end

    # Background-colored pixels between each art edge and the first
    # non-background pixel beyond it (a border line, text, or nothing).
    def gaps(art)
      background = dominant_color
      mid_x = art[:x] + (art[:w] / 2)
      mid_y = art[:y] + (art[:h] / 2)
      {
        left: run_length(background, (art[:x] - 1).downto(0).map { |x| [x, mid_y] }),
        right: run_length(background, ((art[:x] + art[:w])...@width).map { |x| [x, mid_y] }),
        top: run_length(background, (art[:y] - 1).downto(0).map { |y| [mid_x, y] }),
        bottom: run_length(background, ((art[:y] + art[:h])...@height).map { |y| [mid_x, y] })
      }
    end

    private

    def magenta?(red, green, blue) = red > 190 && green < 90 && blue > 190
    def cyan?(red, green, blue) = red < 90 && green > 190 && blue > 190

    # Bounding box of every MIN_PATCH-square block whose pixels all match,
    # found with a summed-area table so each block test is constant time.
    def bounding_box(&)
      sums = Array.new(@height + 1) { Array.new(@width + 1, 0) }
      @height.times do |y|
        row = @rgb.byteslice(y * @width * 3, @width * 3).bytes
        above = sums[y]
        current = sums[y + 1]
        running = 0
        @width.times do |x|
          running += 1 if yield(row[x * 3], row[(x * 3) + 1], row[(x * 3) + 2])
          current[x + 1] = above[x + 1] + running
        end
      end
      block_box(sums)
    end

    def block_box(sums)
      size = MIN_PATCH
      full = size * size
      min_x = min_y = Float::INFINITY
      max_x = max_y = -1
      (0..(@height - size)).each do |y|
        top = sums[y]
        bottom = sums[y + size]
        (0..(@width - size)).each do |x|
          next unless bottom[x + size] - bottom[x] - top[x + size] + top[x] == full

          min_x = x if x < min_x
          max_x = x if x > max_x
          min_y = y if y < min_y
          max_y = y
        end
      end
      return nil if max_x.negative?

      { x: min_x, y: min_y, w: max_x - min_x + size, h: max_y - min_y + size }
    end

    # Sampled, since a terminal window is overwhelmingly background.
    def dominant_color
      counts = Hash.new(0)
      (0...@height).step(4) do |y|
        (0...@width).step(4) { |x| counts[pixel(x, y)] += 1 }
      end
      counts.max_by { |_color, count| count }.first
    end

    # nil when nothing but background lies beyond the edge.
    def run_length(background, points)
      points.each_with_index do |(x, y), index|
        distance = pixel(x, y).zip(background).sum { |a, b| (a - b).abs }
        return index if distance > LINE_THRESHOLD
      end
      nil
    end
  end
end

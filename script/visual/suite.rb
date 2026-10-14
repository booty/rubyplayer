# frozen_string_literal: true

require_relative 'snapshot'

module Visual
  # The `rake visual` matrix: each case in each terminal, checked for
  # distortion and (inset only) balanced side gaps. Prints one line per
  # capture; passed? runs the matrix and answers whether everything passed.
  class Suite
    CASES = [
      { size: [160, 50], mode: 'inset', cover: [400, 300] },
      { size: [100, 40], mode: 'inset', cover: [300, 400] },
      { size: [120, 40], mode: 'corner', cover: [400, 400] }
    ].freeze
    # The cyan square's width/height may stray this far from 1 before the
    # art counts as distorted; a pixel of edge blending is about 1%.
    MAX_DISTORTION = 0.03
    # iTerm2 draws Kitty images from the window edge, ignoring its own ~5px
    # side margin that text respects, so its art sits that far left of the
    # cell grid and the side gaps differ by about twice the margin.
    SIDE_TOLERANCE = { 'kitty' => 2, 'iterm' => 14 }.freeze

    def initialize(out_dir:, terminals: Snapshot::TERMINALS)
      @out_dir = out_dir
      @terminals = terminals
    end

    def passed?
      @terminals.product(CASES).map { |terminal, spec| passes?(terminal, spec) }.all?
    end

    private

    def passes?(terminal, spec)
      cols, rows = spec[:size]
      snapshot = Snapshot.new(terminal: terminal, cols: cols, rows: rows, mode: spec[:mode], cover: spec[:cover],
                              out_dir: @out_dir).run
      result = snapshot.measurement
      problems = problems(terminal, spec, result)
      report(snapshot, result, problems)
      problems.empty?
    end

    def problems(terminal, spec, result)
      return ['art not found'] unless result[:found]

      gaps = result[:gaps]
      problems = []
      problems << format('distorted (square %.3f)', result[:square_aspect]) if
        (result[:square_aspect] - 1).abs > MAX_DISTORTION
      if spec[:mode] == 'inset' && gaps[:left] && gaps[:right] &&
         (gaps[:left] - gaps[:right]).abs > SIDE_TOLERANCE.fetch(terminal)
        problems << "side gaps #{gaps[:left]}/#{gaps[:right]}"
      end
      problems
    end

    def report(snapshot, result, problems)
      gaps = result[:gaps] || {}
      verdict = problems.empty? ? 'ok' : "FAIL: #{problems.join('; ')}"
      verdict += " (ignored input: #{snapshot.log.lines.size} reads)" unless snapshot.log.empty?
      puts format('%<name>-36s square %<square>-6.3f gaps L%<left>-4s R%<right>-4s B%<bottom>-4s %<verdict>s',
                  name: File.basename(snapshot.png_path), square: result[:square_aspect].to_f,
                  left: gaps[:left], right: gaps[:right], bottom: gaps[:bottom], verdict: verdict)
    end
  end
end

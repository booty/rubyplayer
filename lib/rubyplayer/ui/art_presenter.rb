# frozen_string_literal: true

require_relative 'kitty_image'

module RubyPlayer
  module UI
    # The current track's album art on screen: its bytes and accent, the
    # placement mode, the region this frame's layout reserved for it, and
    # the Kitty image drawn there. App decides whether the current view has
    # room for art at all (modals, live pages); this decides where it goes
    # and when the terminal placement must be redrawn.
    class ArtPresenter
      MODES = %i[off inset pane corner].freeze

      attr_reader :bytes, :accent, :kitty_image
      # mode is writable so App and tests can choose a placement directly;
      # cycle_mode is the user-facing path.
      attr_accessor :mode, :region

      def self.normalize_mode(value)
        mode = value.to_s.to_sym
        MODES.include?(mode) ? mode : :off
      end

      # screen is a callable: App replaces its Screen on some resizes.
      def initialize(screen:, config:, kitty_image:, supported:, mode:)
        @screen_source = screen
        @config = config
        @kitty_image = kitty_image
        @supported = supported
        @mode = self.class.normalize_mode(mode)
        @bytes = nil
        @accent = nil
        @region = nil
        @dirty = false
      end

      def supported? = @supported
      def loaded? = !!(@bytes && @supported)

      def cycle_mode
        @mode = MODES[(MODES.index(@mode) + 1) % MODES.size]
      end

      # Returns whether the bytes changed, so the caller repaints everything.
      # rubocop:disable Naming/PredicateMethod
      def show(bytes, accent: nil)
        @accent = @config['ui', 'art_accent'] ? accent : nil
        return false if bytes == @bytes

        @bytes = bytes
        true
      end
      # rubocop:enable Naming/PredicateMethod

      # The terminal placement lives outside Screen's buffer, so a full
      # repaint must place it again.
      def mark_dirty! = @dirty = true

      def placeable?(view_open) = loaded? && view_open && valid_region?(@region)

      # Art deferred by a resize storm still owes the terminal one image
      # after the storm settles; without this the debt would only be paid on
      # the next unrelated repaint (never, if the app is idle).
      def emit_pending?(unobstructed, settling:) = @dirty && !@region.nil? && loaded? && unobstructed && !settling

      # Called after Screen#flush: placements live outside Screen's buffer,
      # so damaged art must be placed again. Modals hide the placement while
      # keeping pixels resident for the closing repaint.
      def emit(view_open, settling:)
        return withdraw unless placeable?(view_open)

        rows = @region[:y]..(@region[:y] + @region[:h] - 1)
        cols = @region[:x]..(@region[:x] + @region[:w] - 1)
        return unless @dirty || screen.region_damaged?(rows: rows, cols: cols)

        # A window drag is a SIGWINCH storm. Remember placement damage and
        # repair it once after the existing resize debounce settles.
        if settling
          @dirty = true
          return
        end

        @dirty = false
        @kitty_image.render(@bytes, row: @region[:y], col: @region[:x], width_cells: @region[:w],
                                    height_cells: @region[:h], gap_cells: @config['ui', 'art_gap_cells'],
                                    align: @region.fetch(:align, :center), force: true)
      end

      # Frees the image when there is none to show; otherwise only hides the
      # placement (a modal, live page or bad region rules it out for now) so
      # the pixels stay resident for the next placement.
      def withdraw
        if loaded?
          @kitty_image.hide
        else
          @kitty_image.clear
        end
        nil
      end

      def clear = @kitty_image.clear

      # Inset height at the bottom of a lib_width-column Library pane.
      # Cells are roughly twice as tall as wide, so a visually square image
      # spans about half as many rows as columns.
      def inset_rows(lib_width, content_height)
        limit = (content_height - 2) / 2 # leave at least half the pane for the list
        cap = @config['ui', 'art_inset_max_rows']
        limit = [limit, cap].min if cap.positive?
        # Before art arrives (rows_to_fill is nil) a square cover is
        # assumed; the arrival repaints and resizes the inset.
        fill = @kitty_image.rows_to_fill(@bytes, width_cells: lib_width - 2,
                                                 gap_cells: @config['ui', 'art_gap_cells'])
        rows = [fill || ((lib_width - 2) / 2), limit].min
        rows >= @config['ui', 'art_min_rows'] ? rows : 0
      end

      # Reserves the bottom-right corner of the Tracks area, painting a
      # stable backing rectangle: these cells must be identical every frame
      # so the diff never repaints beneath the image while the track list
      # scrolls elsewhere. backing_bg is deliberately the *base* surface
      # color: any per-frame theme variation here would damage this region
      # and re-emit the image (same flood class as the resize storm).
      def place_corner(cols, content_height, backing_bg:)
        height = @config['ui', 'art_corner_rows']
        width = height * 2
        return if height + 2 >= content_height || width + 4 >= cols

        x = cols - width - 2
        y = content_height - 1 - height
        height.times { |i| screen.put(y + i, x, ' ' * width, bg: backing_bg) }
        @region = { x: x, y: y, w: width, h: height }
      end

      private

      def screen = @screen_source.call

      def valid_region?(region)
        return false unless region.is_a?(Hash)

        x = region[:x]
        y = region[:y]
        w = region[:w]
        h = region[:h]
        [x, y, w, h].all?(Integer) && x >= 0 && y >= 0 &&
          w.positive? && h.positive? && x + w <= screen.cols && y + h <= screen.rows
      end
    end
  end
end

# frozen_string_literal: true

module RubyPlayer
  module UI
    # Selection and viewport state for an ordered set of upcoming queue tracks.
    # Rendering stays with each pane because the sidebar has history/header rows
    # while the top-level queue is a flat track list.
    class QueueSelection
      include ScrollableList

      attr_reader :items, :selection, :scroll

      def initialize
        @items = []
        @selection = 0
        @scroll = 0
        @page_size = ScrollableList::PAGE_SIZE_FALLBACK
      end

      def replace(items)
        previous = selected_track
        @items = Array(items).dup
        @selection = matching_index(previous) || @selection.clamp(0, [@items.size - 1, 0].max)
        clamp_selection
        @scroll = @scroll.clamp(0, [@items.size - @page_size, 0].max)
        self
      end

      def restore(identity:, fallback: 0, scroll: 0)
        @selection = @items.index { |item| item.id == identity } || fallback
        @scroll = scroll
        clamp_selection
        @scroll = @scroll.clamp(0, [@items.size - @page_size, 0].max)
        self
      end

      def selected_track
        @items[@selection]
      end

      def selected_index
        selected_track ? @selection : nil
      end

      def handle_action(action) # rubocop:disable Naming/PredicateMethod
        case action
        when :nav_up then move_selection(-1)
        when :nav_down then move_selection(1)
        when :nav_page_up
          @selection = (@selection - @page_size).clamp(0, [@items.size - 1, 0].max)
        when :nav_page_down
          @selection = (@selection + @page_size).clamp(0, [@items.size - 1, 0].max)
        else return false
        end
        clamp_selection
        true
      end

      def set_page_size(height) # rubocop:disable Naming/AccessorMethodName
        @page_size = height.positive? ? height : ScrollableList::PAGE_SIZE_FALLBACK
        nil
      end

      def follow_selection(height)
        return if height <= 0

        @page_size = height
        super(height, @items.size)
      end

      # Returns [visible_tracks, hidden_after_count]. The caller adds any
      # section header or overflow row around this track-only viewport.
      def visible_items(height)
        return [[], 0] unless height.positive?

        follow_selection(height)
        visible = @items[@scroll, height] || []
        [visible, [@items.size - @scroll - visible.size, 0].max]
      end

      private

      def matching_index(previous)
        return nil unless previous

        @items.index { |item| item.equal?(previous) || item.id == previous.id }
      end

      def move_selection(delta)
        @selection = (@selection + delta).clamp(0, [@items.size - 1, 0].max)
      end

      def clamp_selection
        @selection = @selection.clamp(0, [@items.size - 1, 0].max)
      end
    end
  end
end

module RubyPlayer
  # The playback queue. Head of the list = currently playing track (when the
  # engine is playing). Named PlayQueue because ::Queue is Thread::Queue.
  class PlayQueue
    def initialize(undo_depth: 10)
      @items = []
      @undo_depth = undo_depth
      @undo_stack = []
      @redo_stack = []
      @on_change = nil
    end

    def items = @items.dup
    def first = @items.first
    def size = @items.size
    def empty? = @items.empty?
    def on_change(&blk) = @on_change = blk

    def enqueue_now(tracks, playing: false)
      snapshot!
      @items.shift if playing # the interrupted track does not come back
      @items = tracks + @items
      changed!
    end

    def enqueue_front(tracks, playing: false)
      snapshot!
      @items.insert(playing ? 1 : 0, *tracks)
      changed!
    end

    def enqueue_end(tracks)
      snapshot!
      @items.concat(tracks)
      changed!
    end

    def remove_at(index)
      return nil if index.negative? || index >= @items.size
      snapshot!
      removed = @items.delete_at(index)
      changed!
      removed
    end

    # Removes every item whose track id is in `ids` (used to cascade a
    # library deletion into the live queue, which holds Track objects rather
    # than DB rows). Snapshot is skipped when nothing actually matches, so a
    # no-op cascade doesn't pollute the undo stack.
    def remove_track_ids(ids)
      return if ids.empty?
      kept = @items.reject { |t| ids.include?(t.id) }
      return if kept.size == @items.size
      snapshot!
      @items = kept
      changed!
    end

    # Automatic advancement (track ended / skip): drops the head, returns the
    # new head. Deliberately NOT undoable -- undo is scoped to manual queue
    # edits per spec, not to normal playback progression.
    def advance!
      @items.shift
      changed!
      @items.first
    end

    def undo
      return false if @undo_stack.empty?
      @redo_stack.push(@items.dup)
      @items = @undo_stack.pop
      changed!
      true
    end

    def redo
      return false if @redo_stack.empty?
      @undo_stack.push(@items.dup)
      @items = @redo_stack.pop
      changed!
      true
    end

    private

    # Called before every manual mutation. A fresh manual edit invalidates
    # any redo history (standard undo/redo semantics), and the undo stack is
    # capped at undo_depth to bound memory.
    def snapshot!
      @undo_stack.push(@items.dup)
      @undo_stack.shift while @undo_stack.size > @undo_depth
      @redo_stack.clear
    end

    def changed! = @on_change&.call
  end
end

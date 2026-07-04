require "test_helper"

class PlayQueueTest < Minitest::Test
  def setup
    @q = RubyPlayer::PlayQueue.new(undo_depth: 3)
  end

  def test_enqueue_end_and_advance
    @q.enqueue_end(%w[a b c])
    assert_equal "a", @q.first
    assert_equal "b", @q.advance!
    assert_equal %w[b c], @q.items
  end

  def test_enqueue_front_respects_playing_head
    @q.enqueue_end(%w[a b])
    @q.enqueue_front(%w[x], playing: true)
    assert_equal %w[a x b], @q.items
    @q.enqueue_front(%w[y], playing: false)
    assert_equal %w[y a x b], @q.items
  end

  def test_enqueue_now_replaces_playing_head
    @q.enqueue_end(%w[a b])
    @q.enqueue_now(%w[x], playing: true)
    assert_equal %w[x b], @q.items # 'a' was interrupted and discarded
    @q.enqueue_now(%w[y], playing: false)
    assert_equal %w[y x b], @q.items # nothing playing: nothing discarded
  end

  def test_undo_redo_roundtrip
    @q.enqueue_end(%w[a])
    @q.enqueue_end(%w[b])
    assert @q.undo
    assert_equal %w[a], @q.items
    assert @q.redo
    assert_equal %w[a b], @q.items
    refute @q.redo
  end

  def test_new_mutation_clears_redo
    @q.enqueue_end(%w[a])
    @q.enqueue_end(%w[b])
    @q.undo
    @q.enqueue_end(%w[c])
    refute @q.redo
    assert_equal %w[a c], @q.items
  end

  def test_undo_depth_limited
    5.times { |i| @q.enqueue_end([i.to_s]) }
    undos = 0
    undos += 1 while @q.undo
    assert_equal 3, undos # depth 3
  end

  def test_advance_is_not_undoable
    @q.enqueue_end(%w[a b])
    @q.advance!
    @q.undo # undoes the enqueue_end, not the advance
    assert_empty @q.items
  end

  def test_remove_at_and_change_callback
    changes = 0
    @q.on_change { changes += 1 }
    @q.enqueue_end(%w[a b])
    assert_equal "b", @q.remove_at(1)
    assert_nil @q.remove_at(9)
    assert_equal %w[a], @q.items
    assert_equal 2, changes # enqueue + successful remove (failed remove: no change)
  end
end

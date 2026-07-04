require "test_helper"

class EventBusTest < Minitest::Test
  def test_publish_drain_roundtrip
    bus = RubyPlayer::EventBus.new
    bus.publish(:track_started, id: 7)
    bus.publish(:position, ms: 100)
    events = bus.drain
    assert_equal [[:track_started, { id: 7 }], [:position, { ms: 100 }]], events
    assert_empty bus.drain
  end

  def test_publish_wakes_select
    bus = RubyPlayer::EventBus.new
    Thread.new { sleep 0.05; bus.publish(:ping) }
    ready = IO.select([bus.reader], nil, nil, 2)
    refute_nil ready, "publish should make the reader selectable"
    bus.drain
    assert_nil IO.select([bus.reader], nil, nil, 0.05), "drain should clear the pipe"
  end

  def test_many_publishes_never_block
    bus = RubyPlayer::EventBus.new
    100_000.times { |i| bus.publish(:tick, i: i) } # far beyond pipe capacity
    assert_equal 100_000, bus.drain.size
  end
end

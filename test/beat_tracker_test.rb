require "test_helper"

class BeatTrackerTest < Minitest::Test
  def tracker(steps: 8, decay: 0.8)
    RubyPlayer::BeatTracker.new(steps: steps, decay: decay)
  end

  def test_silence_stays_at_step_zero
    t = tracker
    10.times { t.sample([0.0] * 16) }
    assert_equal 0, t.step
  end

  def test_bass_hit_jumps_to_top_step
    t = tracker
    t.sample([0.0] * 16)
    t.sample([1.0, 1.0, 1.0, 1.0] + [0.0] * 12) # bass-heavy frame
    assert_equal 7, t.step
  end

  def test_envelope_decays_between_hits
    t = tracker(decay: 0.5)
    t.sample([1.0] * 16)
    top = t.step
    t.sample([0.0] * 16)
    mid = t.step
    t.sample([0.0] * 16)
    low = t.step

    assert_operator mid, :<, top
    assert_operator low, :<, mid
  end

  def test_sustained_quiet_music_normalizes_instead_of_pinning_low
    # Auto-gain: a track that never exceeds 0.2 should still pulse visibly —
    # the envelope normalizes against the rolling peak, not absolute level.
    t = tracker
    30.times { t.sample([0.05] * 16) }
    t.sample([0.2] * 16)
    assert_operator t.step, :>=, 6
  end

  def test_reset_returns_to_zero
    t = tracker
    t.sample([1.0] * 16)
    t.reset
    assert_equal 0, t.step
  end

  def test_empty_levels_are_safe
    t = tracker
    t.sample([])
    assert_equal 0, t.step
  end
end

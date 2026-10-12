# frozen_string_literal: true

require 'test_helper'
require 'tempfile'
require_relative 'support/vgm_builder'
require 'rubyplayer/vgm/reader'
require 'rubyplayer/vgm/cursor'

class VgmCursorTest < Minitest::Test
  def test_events_apply_at_their_exact_sample_boundary_in_file_order
    builder = VgmBuilder.new(ym2612_clock: 7_670_454)
                        .wait(100).ym2612(0, 0x28, 0xf0).ym2612(0, 0xb0, 0x27)
                        .wait(1).ym2612(0, 0x28, 0x00).end
    cursor = cursor_for(builder.bytes)

    before = ym_row(cursor.advance_to(sample: 99))
    at = ym_row(cursor.advance_to(sample: 100))
    off = ym_row(cursor.advance_to(sample: 101))

    assert_equal :key_off, before.state
    assert_equal :key_on, at.state
    assert_equal 7, at.patch.algorithm
    assert_equal 100, off.last_trigger_sample
    assert_equal :key_off, off.state
  end

  def test_backward_seek_replays_from_an_earlier_checkpoint
    builder = VgmBuilder.new(ym2612_clock: 7_670_454)
                        .ym2612(0, 0x28, 0xf0).wait(44_200).ym2612(0, 0x28, 0x00).end
    cursor = cursor_for(builder.bytes)
    far = ym_row(cursor.advance_to(sample: 44_200))
    near = ym_row(cursor.advance_to(sample: 10))

    assert_equal :key_off, far.state
    assert_equal :key_on, near.state
    assert_equal 0, near.last_trigger_sample
  end

  def test_loop_reuses_register_and_psg_latch_state_across_repetitions
    builder = VgmBuilder.new(sn76489_clock: 3_579_545)
                        .psg(0x85).wait(1).loop_here.raw_command("\x50\x3e".b).wait(1).end
    cursor = cursor_for(builder.bytes)
    first_loop = cursor.advance_to(sample: 1)
    later_loop = cursor.advance_to(sample: 3)
    sought = cursor_for(builder.bytes).advance_to(sample: 3)
    tone = later_loop.chips.find { |chip| chip.id == 'sn76489:0' }.channels.first

    assert_equal 0, first_loop.loop_count
    assert_equal 2, later_loop.loop_count
    assert_equal tone, sought.chips.find { |chip| chip.id == 'sn76489:0' }.channels.first
    assert_equal 997, tone.details.fetch(:period)
  end

  def test_data_blocks_are_spans_and_legacy_dac_reads_the_selected_bank_offset
    builder = VgmBuilder.new(ym2612_clock: 7_670_454)
                        .ym2612(0, 0x2b, 0x80)
                        .data_block(type: 0, data: "\x12\x34".b).pcm_seek(1)
                        .raw_command("\x80".b).wait(1).end
    cursor = cursor_for(builder.bytes)
    snapshot = cursor.advance_to(sample: 0)
    dac = snapshot.chips.find { |chip| chip.id == 'ym2612:0' }.channels[5]

    assert_equal :data, dac.state
    assert_equal 0x34, dac.details.fetch(:dac_value)
  end

  def test_wait_overrides_and_short_waits_keep_exact_source_samples
    builder = VgmBuilder.new(ym2612_clock: 7_670_454)
                        .wait_override(command: 0x62, samples: 2)
                        .raw_command("\x62".b).ym2612(0, 0x28, 0xf0).end
    cursor = cursor_for(builder.bytes)

    assert_equal :key_off, ym_row(cursor.advance_to(sample: 1)).state
    assert_equal :key_on, ym_row(cursor.advance_to(sample: 2)).state
  end

  def test_zero_time_loop_fails_instead_of_spinning
    builder = VgmBuilder.new.loop_here.end
    cursor = cursor_for(builder.bytes)

    error = assert_raises(RubyPlayer::Vgm::Cursor::ReplayError) do
      cursor.advance_to(sample: 1)
    end
    assert_match(/zero-time loop/, error.message)
  end

  def test_cancel_callback_interrupts_a_replay_slice
    cursor = cursor_for(VgmBuilder.new.wait(100_000).end.bytes)

    assert_raises(RubyPlayer::Vgm::Cursor::Cancelled) do
      cursor.advance_to(sample: 100_000, cancel: -> { true })
    end
  end

  def test_checkpoint_storage_is_bounded_and_preserves_the_initial_state
    cursor = cursor_for(VgmBuilder.new.wait(5_650_000).end.bytes)
    snapshot = cursor.advance_to(sample: 5_650_000)

    assert_equal :ended, snapshot.status
    assert_operator cursor.checkpoint_count, :<=, 128
    assert_equal 0, cursor.checkpoint_samples.first
  end

  private

  def cursor_for(bytes)
    Tempfile.create(['rubyplayer-cursor', '.vgm']) do |file|
      file.binmode
      file.write(bytes)
      file.flush
      reader = RubyPlayer::Vgm::Reader.open(file.path, max_bytes: 100_000)
      return RubyPlayer::Vgm::Cursor.new(reader: reader)
    end
  end

  def ym_row(snapshot, channel = 0)
    snapshot.chips.find { |chip| chip.id.start_with?('ym2612:') }.channels.fetch(channel)
  end
end

# frozen_string_literal: true

require 'test_helper'
require 'rubyplayer/backends/gme'
require 'tempfile'
require_relative 'support/vgm_builder'

class GmeVgmTimingTest < Minitest::Test
  VGM_RATE = 44_100
  INTRO_SAMPLES = 22_050

  def setup
    @gme = RubyPlayer::Backends::Gme.new
  end

  def test_vgm_preserves_known_silent_intro
    pcm = decode(silent_intro_vgm)
    onset_sample = first_audible_sample(pcm)

    assert_operator onset_sample, :>=, INTRO_SAMPLES - 441
    # Installed libgme starts within 7 VGM samples; 10ms leaves room for
    # resampling while staying well inside one UI refresh interval.
    assert_in_delta INTRO_SAMPLES, onset_sample, 441
  end

  def test_vgz_uses_same_policy
    pcm = with_temp_file(silent_intro_builder.gzip, '.vgz') { |path| decode_file(path) }
    onset_sample = first_audible_sample(pcm)

    assert_operator onset_sample, :>=, INTRO_SAMPLES - 441
    assert_in_delta INTRO_SAMPLES, onset_sample, 441
  end

  def test_vgm_and_vgz_set_silence_policy_before_start
    [silent_intro_vgm, silent_intro_builder.gzip].each do |bytes|
      extension = bytes.start_with?("\x1f\x8b".b) ? '.vgz' : '.vgm'
      with_temp_file(bytes, extension) do |path|
        calls = spy_gme_calls do
          handle = @gme.open(path, 0, sample_rate: VGM_RATE)
          handle.close
        end

        assert_equal [[:ignore_silence, 1], [:start_track, 0]], calls
      end
    end
  end

  def test_other_chiptunes_keep_existing_silence_policy
    calls = spy_gme_calls do
      handle = @gme.open(File.join(FIXTURES, 'shantae.gbs'), 0, sample_rate: VGM_RATE)
      handle.close
    end

    assert_equal [[:start_track, 0]], calls
  end

  def test_vgm_end_and_fade_still_finish
    handle = with_temp_file(short_tone_vgm, '.vgm') do |path|
      @gme.open(path, 0, sample_rate: VGM_RATE)
    end

    handle.read(44_100)

    assert_nil handle.read(44_100)
  ensure
    handle&.close
  end

  private

  def silent_intro_vgm
    silent_intro_builder.bytes
  end

  def silent_intro_builder
    VgmBuilder.new
              .psg(0x9f) # Channel 0 stays muted during the intro.
              .psg(0xbf).psg(0xdf).psg(0xff)
              .psg(0x80 | 0x08).psg(0x3e) # Tone period 1,000 (~112 Hz).
              .wait(INTRO_SAMPLES)
              .psg(0x90) # Maximum volume begins after the known silent intro.
              .wait(VGM_RATE)
              .end
  end

  def short_tone_vgm
    VgmBuilder.new
              .psg(0x80 | 0x08).psg(0x3e).psg(0x90)
              .wait(VGM_RATE / 2)
              .psg(0x9f)
              .end
              .bytes
  end

  def decode(bytes)
    with_temp_file(bytes, '.vgm') { |path| decode_file(path) }
  end

  def decode_file(path)
    handle = @gme.open(path, 0, sample_rate: VGM_RATE)
    samples = +''.b
    loop do
      data = handle.read(512)
      break unless data

      samples << data
    end
    samples.unpack('e*')
  ensure
    handle&.close
  end

  def with_temp_file(bytes, extension)
    Tempfile.create(['rubyplayer-vgm-timing', extension]) do |file|
      file.binmode
      file.write(bytes)
      file.flush
      yield file.path
    end
  end

  def first_audible_sample(samples)
    samples.each_slice(2).with_index do |(left, right), index|
      return index if [left, right].any? { |value| value.abs > 0.0001 }
    end
    samples.length / 2
  end

  def spy_gme_calls
    lib = RubyPlayer::Backends::GmeLib
    originals = %i[gme_ignore_silence gme_start_track].to_h do |name|
      [name, lib.method(name)]
    end
    calls = []
    lib.define_singleton_method(:gme_ignore_silence) do |emu, value|
      calls << [:ignore_silence, value]
      originals.fetch(:gme_ignore_silence).call(emu, value)
    end
    lib.define_singleton_method(:gme_start_track) do |emu, index|
      calls << [:start_track, index]
      originals.fetch(:gme_start_track).call(emu, index)
    end
    yield
    calls
  ensure
    originals&.each { |name, method| lib.define_singleton_method(name, method) }
  end
end

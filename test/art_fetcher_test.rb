require 'test_helper'
require_relative 'support/async_wait'
require 'rubyplayer/art_fetcher'

class ArtFetcherTest < Minitest::Test
  include TestSupport::AsyncWait

  # Lets the test hold the worker inside one fetch while more requests land.
  class GatedArtwork
    attr_reader :fetched

    def initialize
      @fetched = Queue.new
      @gate = Queue.new
    end

    def release = @gate << true

    def for_track(track)
      @fetched << track.id
      @gate.pop
      "art #{track.id}"
    end

    def average_color(_bytes) = [1, 2, 3]
    def display_bytes(bytes, max_px:) = "#{bytes} @#{max_px}"
  end

  def setup
    @bus = RubyPlayer::EventBus.new
    @artwork = GatedArtwork.new
    @fetcher = RubyPlayer::ArtFetcher.new(artwork: @artwork, event_bus: @bus, display_max_px: -> { 480 })
  end

  def teardown
    3.times { @artwork.release }
    @fetcher.stop
  end

  def test_publishes_display_art_and_accent_for_the_track
    @fetcher.request(track(1))
    @artwork.release

    events = wait_for_events(1)

    assert_equal [[:art_ready, { track_id: 1, bytes: 'art 1 @480', accent: [1, 2, 3] }]], events
  end

  # Regression: every track start spawned its own fetch thread, so skipping
  # quickly ran an ffmpeg extraction per skipped track at once and threw all
  # but the last result away.
  def test_requests_made_during_a_fetch_collapse_to_the_newest
    @fetcher.request(track(1))
    wait_until { @artwork.fetched.size == 1 }
    @fetcher.request(track(2))
    @fetcher.request(track(3))
    2.times { @artwork.release }

    events = wait_for_events(2)

    assert_equal [1, 3], events.map { |_type, payload| payload[:track_id] }
  end

  private

  def track(id) = RubyPlayer::Track.new(id: id, title: "Track #{id}")

  def wait_for_events(count)
    events = []
    wait_until(timeout: 2) do
      events.concat(@bus.drain)
      events.size >= count
    end
    events
  end
end

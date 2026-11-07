# frozen_string_literal: true

require_relative 'chip_live_view'
require_relative 'spc_live_view'
require_relative 'chip_tracker_view'
require_relative 'now_playing_modal'
require_relative '../gbs/tracker'
require_relative '../nsf/tracker'
require_relative '../hes/tracker'

module RubyPlayer
  module UI
    # The Now Playing modal's state: whether it is open, which page it
    # shows, and the live views fed by VGM telemetry and native chip
    # snapshots. App keeps the glue to keys, album art and repaints.
    class NowPlayingController
      # One chip format's Now Playing pages, fed by native chip snapshots
      # (GBS, NSF, HES): the Live page view, the format's ChipTracker that
      # turns snapshots into their model, and the Tracker page view (shown
      # where LIVE_PAGES lists it). One per format for the app's lifetime.
      ChipPages = Data.define(:live_view, :tracker, :tracker_view) do
        def self.for(source, tracker)
          new(live_view: ChipLiveView.new(source: source), tracker: tracker,
              tracker_view: ChipTrackerView.new(source: source))
        end
      end

      # Every S-DSP voice muted: soloing one clears its bit from this.
      ALL_SPC_VOICES_MUTE_MASK = 0xff

      attr_reader :modal, :page, :vgm_live_view, :vgm_tracker_view, :spc_live_view, :chip_pages

      def initialize(engine:, library:, registry:, archive_cache:, event_bus:, telemetry_controller:)
        @engine = engine
        @library = library
        @registry = registry
        @archive_cache = archive_cache
        @bus = event_bus
        @telemetry_controller = telemetry_controller
        @vgm_live_view = ChipLiveView.new
        @vgm_tracker_view = ChipTrackerView.new
        @spc_live_view = SpcLiveView.new
        # GBS, NSF, and HES reuse the VGM page; their rows come from chip
        # snapshots, each kind through its own tracker.
        @chip_pages = { gbs: ChipPages.for('GBS', Gbs::Tracker.new), nsf: ChipPages.for('NSF', Nsf::Tracker.new),
                        hes: ChipPages.for('HES', Hes::Tracker.new) }
        @shown = false
        @modal = nil
        @page = :info
        @last_live_page = nil
      end

      def shown? = @shown
      def live_page? = !!@modal&.live_page?
      def live_pages? = !!@modal&.live_pages&.any?

      # Which live page the current playback supports: VGM register telemetry,
      # SPC DSP or GBS APU snapshots, or none.
      def live_kind
        return :vgm if @engine.vgm_telemetry_request

        @engine.chip_live_kind
      end

      def open(track)
        @shown = true
        prepare(track)
      end

      # A new track while open keeps the page being shown when the track
      # also offers it (such as the VGM Tracker).
      def follow(track) = prepare(track, preferred_page: @page)

      # Track ended mid-render: stop drawing without the full close.
      def hide
        @shown = false
        nil
      end

      def close
        @shown = false
        @telemetry_controller.visible = false
        reset_vgm_views
        @page = :info
        @last_live_page = nil
      end

      def change_page(page)
        was_live = @modal.live_page?
        # The modal normalizes pages its track does not offer; mirror its choice.
        @modal.page = page
        @page = @modal.page
        is_live = @modal.live_page?
        if is_live && !was_live
          reset_vgm_views
          @telemetry_controller.visible = @modal.live_kind == :vgm
        elsif !is_live
          @telemetry_controller.visible = false
        end
      end

      def toggle_info
        if @modal.live_page?
          @last_live_page = @page
          change_page(:info)
        else
          change_page(@last_live_page || @modal.live_pages.first)
        end
      end

      # rubocop:disable Naming/PredicateMethod
      # Technical metadata probed for a modal. Returns whether it was shown:
      # a late answer for a closed or replaced modal is dropped.
      def accept_metadata(modal, metadata, current_track)
        return false unless @shown && modal.equal?(@modal) && @modal.matches?(current_track)

        @modal.update(metadata)
        true
      end
      # rubocop:enable Naming/PredicateMethod

      def vgm_visible? = @shown && live_page? && @modal.live_kind == :vgm

      def show_vgm_snapshot(snapshot)
        @vgm_live_view.update(snapshot)
        @vgm_tracker_view.update(snapshot)
      end

      # rubocop:disable Naming/PredicateMethod
      # Returns whether rows were dropped, so the caller repaints.
      def clear_stale_vgm_views
        return false unless @telemetry_controller.snapshot.nil?
        return false unless @vgm_live_view.snapshot || @vgm_tracker_view.snapshot

        reset_vgm_views
        true
      end
      # rubocop:enable Naming/PredicateMethod

      # Brings the open live page up to date before it is drawn.
      def update_live(position_ms)
        case @modal.live_kind
        when :spc
          @modal.update_spc(state: @engine.spc_live, position_ms: position_ms)
        when :vgm
          @modal.update_chip(now_sample: @engine.vgm_telemetry_request&.sample, mute_mask: @engine.voice_mute_mask)
        when *@chip_pages.keys then update_chip_live(@modal.live_kind, position_ms)
        end
      end

      # Returns whether the key was consumed.
      def handle_mute_key(key)
        case @modal&.live_kind
        when :spc then handle_spc_mute_key(key)
        when :vgm then handle_channel_mute_key(key, @vgm_live_view)
        when *@chip_pages.keys then handle_channel_mute_key(key, @chip_pages.fetch(@modal.live_kind).live_view)
        else false
        end
      end

      private

      # Opens on the preferred page when the track offers it, otherwise on
      # the first live page, or Info when the kind has none (no live state,
      # or a kind whose page does not exist yet).
      def prepare(track, preferred_page: nil)
        kind = live_kind
        pages = NowPlayingModal::LIVE_PAGES.fetch(kind, [])
        live = pages.any?
        @page = pages.include?(preferred_page) ? preferred_page : pages.first || :info
        @last_live_page = live ? @page : nil
        reset_vgm_views
        chip_pages = @chip_pages[kind]
        @modal = NowPlayingModal.new(track, extras: @library.track_metadata_for(track.id),
                                            page: @page,
                                            chip_view: chip_pages&.live_view || @vgm_live_view,
                                            live_available: live, live_kind: (kind if live), spc_view: @spc_live_view,
                                            tracker_view: chip_pages&.tracker_view || @vgm_tracker_view)
        @telemetry_controller.visible = kind == :vgm if @shown
        probe_technical_metadata(track, @modal)
      end

      # Existing library rows predate technical metadata. Probe once when
      # opening, off the UI thread, rather than requiring a destructive rescan.
      def probe_technical_metadata(track, modal)
        Thread.new do
          path = @archive_cache.playable_path(track)
          backend = @registry.backend_for(path)
          next unless backend.technical_metadata?

          metadata = backend.metadata(path, track.subtune_index)
          @bus.publish(:now_playing_metadata_ready, modal: modal, metadata: metadata)
        rescue StandardError
          # File may have disappeared since playback began; retain cached facts.
          nil
        end
      end

      def reset_vgm_views
        @vgm_live_view.update(nil)
        @vgm_tracker_view.update(nil)
      end

      # Feeds every chip snapshot heard since the last frame to the page's
      # tracker, even on the Info page, so note history stays continuous.
      def update_chip_live(kind, position_ms)
        live = @engine.chip_live
        return unless live

        page = @chip_pages.fetch(kind)
        tracker = page.tracker
        changed = tracker.update(live)
        [page.live_view, page.tracker_view].each { |view| view.update(tracker.snapshot) if changed || view.snapshot.nil? }
        page.live_view.paused = live.paused
        @modal.update_chip(now_sample: tracker.now_sample, mute_mask: live.mute_mask, position_ms: position_ms)
      end

      # Digits toggle S-DSP voices 0-7 (as numbered in the table); S solos the
      # selected voice, or unmutes everything if it is already soloed.
      # rubocop:disable Naming/PredicateMethod
      def handle_spc_mute_key(key)
        live = @engine.spc_live
        return false unless live

        mask = live.mute_mask
        case key.to_s.downcase
        when /\A[0-7]\z/ then @engine.mute_voices(mask ^ (1 << key.to_i))
        when 's'
          solo_mute_mask = ALL_SPC_VOICES_MUTE_MASK & ~(1 << @spc_live_view.selected_voice)
          @engine.mute_voices(mask == solo_mute_mask ? 0 : solo_mute_mask)
        else return false
        end
        true
      end

      # M mutes or unmutes the selected channel's libgme voice (some VGM
      # channels share one); S solos it, or unmutes everything if it is
      # already soloed.
      def handle_channel_mute_key(key, view)
        mask = @engine.voice_mute_mask
        selected_voice_bits = view.selected_mute_bits
        return false unless mask && %w[m s].include?(key.to_s.downcase)
        return true if selected_voice_bits.zero?

        if key.to_s.casecmp?('m')
          muted = mask.allbits?(selected_voice_bits)
          @engine.mute_voices(muted ? mask & ~selected_voice_bits : mask | selected_voice_bits)
        else
          # Soloing mutes every other voice.
          solo_mute_mask = view.all_mute_bits & ~selected_voice_bits
          @engine.mute_voices(mask == solo_mute_mask ? 0 : solo_mute_mask)
        end
        true
      end
      # rubocop:enable Naming/PredicateMethod
    end
  end
end

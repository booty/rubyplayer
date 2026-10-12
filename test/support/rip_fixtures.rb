# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'rubyplayer/archive_cache'

module TestSupport
  # The multi-track chiptune rips in fixtures/hes and fixtures/nsf. Several
  # ship as zips holding the rip and its sibling .m3u (track titles and
  # lengths); those are extracted once per run through the app's own
  # ArchiveCache, so libgme sees them as a scan of the archive would.
  module RipFixtures
    # name => [fixtures subdirectory, zip there (nil for a plain file), rip]
    RIPS = {
      air_zonk: ['hes', nil, 'air-zonk.hes'],
      alien_crush: ['hes', 'Alien Crush (EMU).zophar.zip', 'NX63001.hes'],
      blazing_lazers: ['hes', 'Blazing Lazers (EMU).zophar.zip', 'HC89019.hes'],
      dungeon_explorer: ['hes', 'Dungeon Explorer (EMU).zophar.zip', 'HC63015.hes'],
      mega_man_2: ['nsf', nil, 'mega-man-2.nsf'],
      castlevania: ['nsf', nil, 'castlevania.nsf'],
      silver_surfer: ['nsf', nil, 'silver-surfer.nsf'],
      # NES cartridge: no expansion audio. Its FDS original is metroid_fds.
      metroid: ['nsf', 'metroid-b.zip', 'Metroid (1986-08)(Nintendo R&D1)(Nintendo).nsf'],
      # Sunsoft's DPCM bass. The zip also carries box art.
      journey_to_silius: ['nsf', 'journey-to-silius.zip', 'Journey to Silius [RAF World] (1990-08-10)(Sunsoft).nsf'],
      # PAL only (header region bit 0, 50 Hz play rate), and without the
      # Japanese release's Sunsoft 5B: European carts had no expansion audio.
      gimmick_europe: ['nsf', 'gimmick-eur.zip', 'Gimmick! EUR [Mr. Gimmick] (1992-01-31)(-)(Sunsoft).nsf'],
      # Expansion audio, one rip per chip libgme emulates:
      # Konami VRC6: two more pulses and a sawtooth.
      castlevania_3_japan: ['nsf', nil, 'castlevania-3-japan.nsf'],
      # Konami VRC7: six FM channels.
      lagrange_point: ['nsf', 'lagrange-point.zip', 'Lagrange Point (VRC7)(1991-04-26)(-)(Konami).nsf'],
      # Famicom Disk System: one wavetable channel with pitch modulation.
      metroid_fds: ['nsf', 'metroid-a.zip', 'Metroid (FDS)(1986-08-06)(Nintendo R&D1)(Nintendo).nsf'],
      # MMC5: two more pulses and a PCM channel.
      just_breed: ['nsf', 'just-breed.zip', 'Just Breed (1992-12-15)(Random House)(Enix).nsf'],
      # Namco 163: 1-8 wavetable channels, as many as the game enables.
      erika_to_satoru: ['nsf', 'erika-satoru-no-yume-bouken.zip',
                        'Erika to Satoru no Yume Bouken (1988-09-27)(Atlus)(Namco).nsf'],
      rolling_thunder_japan: ['nsf', 'rolling-thunder-jp.zip', 'Rolling Thunder JP (1988-03-17)(Namco).nsf'],
      # Sunsoft 5B: three AY-3-8910-style squares with noise and envelope.
      gimmick: ['nsf', 'gimmick-jp.zip', 'Gimmick! [Mr. Gimmick] (1992-01-31)(-)(Sunsoft).nsf']
    }.freeze

    def self.names(format = nil)
      RIPS.select { |_name, (dir, _zip, _rip)| format.nil? || dir == format }.keys
    end

    def self.zip(name)
      dir, zip, = RIPS.fetch(name)
      File.join(FIXTURES, dir, zip)
    end

    # Path of the rip, with its .m3u (if any) beside it.
    def self.path(name)
      dir, zip, rip = RIPS.fetch(name)
      return File.join(FIXTURES, dir, rip) unless zip

      File.join(cache.extract(File.join(FIXTURES, dir, zip)), rip)
    end

    def self.cache
      @cache ||= begin
        root = Dir.mktmpdir('rubyplayer-rip-fixtures')
        at_exit { FileUtils.remove_entry(root) }
        RubyPlayer::ArchiveCache.new(root: root)
      end
    end
  end
end

require 'rubyplayer/vgm/reader'

module TestSupport
  # Parsed VGM fixtures shared across test files. Reader.open validates the
  # whole command stream up front (~0.9 s for scrap-brean-zone.vgm), and a
  # Reader holds only its bytes and header afterwards: each test advances
  # its own Cursor over it, so one parse per process is safe to share.
  # vgm_reader_test.rb still exercises Reader.open itself.
  module VgmFixtures
    MAX_BYTES = 64 << 20

    def self.reader(name)
      @readers ||= {}
      @readers[name] ||= RubyPlayer::Vgm::Reader.open(File.join(FIXTURES, name), max_bytes: MAX_BYTES)
    end
  end
end

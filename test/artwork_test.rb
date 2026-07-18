require "test_helper"
require "tmpdir"
require "fileutils"
require "open3"

class ArtworkTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir
    @artwork = RubyPlayer::Artwork.new
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def track_for(path, backend: "gme", archive_entry: "")
    RubyPlayer::Track.new(id: 1, physical_path: path, backend: backend,
                          archive_entry: archive_entry, title: "t")
  end

  # Built once per run (ffmpeg is already a hard runtime dependency): an mp3
  # with fixtures/warrior.jpg muxed in as an attached_pic stream. Kept out of
  # fixtures/ because it's derivable and would double the repo's mp3 count.
  def embedded_art_mp3
    @@embedded_art_mp3 ||= begin
      path = File.join(Dir.tmpdir, "rubyplayer-test-embedded-art.mp3")
      unless File.file?(path)
        _, stderr, status = Open3.capture3(
          "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
          "-i", File.join(FIXTURES, "1up.mp3"),
          "-i", File.join(FIXTURES, "warrior.jpg"),
          "-map", "0:a", "-map", "1:v", "-c", "copy",
          "-disposition:v", "attached_pic", path
        )
        flunk "could not build embedded-art fixture: #{stderr}" unless status.success?
      end
      path
    end
  end

  def test_embedded_art_is_extracted_from_ffmpeg_tracks
    bytes = @artwork.for_track(track_for(embedded_art_mp3, backend: "ffmpeg"))
    refute_nil bytes
    # JPEG magic: the extracted stream must be the attached image itself.
    assert_equal "\xFF\xD8".b, bytes.byteslice(0, 2)
  end

  def test_embedded_art_beats_folder_art
    dir = File.join(@tmp, "album")
    FileUtils.mkdir_p(dir)
    File.binwrite(File.join(dir, "cover.png"), "PNGDATA")
    mp3 = File.join(dir, "song.mp3")
    FileUtils.cp(embedded_art_mp3, mp3)

    bytes = @artwork.for_track(track_for(mp3, backend: "ffmpeg"))
    assert_equal "\xFF\xD8".b, bytes.byteslice(0, 2)
  end

  def test_folder_art_prefers_conventional_names_over_other_images
    dir = File.join(@tmp, "album")
    FileUtils.mkdir_p(dir)
    File.binwrite(File.join(dir, "aaa-scan.png"), "SCAN")
    File.binwrite(File.join(dir, "Cover.JPG"), "COVER") # case-insensitive match
    vgm = File.join(dir, "song.vgm")
    File.write(vgm, "")

    assert_equal "COVER", @artwork.for_track(track_for(vgm))
  end

  def test_folder_art_falls_back_to_any_image_in_the_folder
    dir = File.join(@tmp, "album")
    FileUtils.mkdir_p(dir)
    File.binwrite(File.join(dir, "scan01.jpeg"), "SCAN")
    vgm = File.join(dir, "song.vgm")
    File.write(vgm, "")

    assert_equal "SCAN", @artwork.for_track(track_for(vgm))
  end

  def test_archived_track_uses_the_archive_files_own_folder
    dir = File.join(@tmp, "rips")
    FileUtils.mkdir_p(dir)
    File.binwrite(File.join(dir, "folder.jpg"), "ART")
    zip = File.join(dir, "game.zip")
    File.write(zip, "")

    track = track_for(zip, archive_entry: "inner/song.vgm")
    assert_equal "ART", @artwork.for_track(track)
  end

  def test_returns_nil_when_no_art_exists
    dir = File.join(@tmp, "bare")
    FileUtils.mkdir_p(dir)
    vgm = File.join(dir, "song.vgm")
    File.write(vgm, "")

    assert_nil @artwork.for_track(track_for(vgm))
  end

  def test_retro_backends_never_spawn_ffmpeg
    # gme/openmpt formats cannot carry embedded art; resolving must not pay
    # a process spawn per track just to find that out.
    artwork = RubyPlayer::Artwork.new(extractor: ->(_path) { flunk "spawned ffmpeg" })
    dir = File.join(@tmp, "album")
    FileUtils.mkdir_p(dir)
    vgm = File.join(dir, "song.vgm")
    File.write(vgm, "")

    assert_nil artwork.for_track(track_for(vgm, backend: "gme"))
  end

  def test_folder_lookup_is_cached_per_directory
    dir = File.join(@tmp, "album")
    FileUtils.mkdir_p(dir)
    File.binwrite(File.join(dir, "cover.jpg"), "ART")
    a = File.join(dir, "a.vgm")
    b = File.join(dir, "b.vgm")
    File.write(a, "")
    File.write(b, "")

    assert_equal "ART", @artwork.for_track(track_for(a))
    File.delete(File.join(dir, "cover.jpg"))
    # Same directory: served from cache, no re-glob.
    assert_equal "ART", @artwork.for_track(track_for(b))
  end
end

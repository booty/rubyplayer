require 'test_helper'
require 'tmpdir'
require 'fileutils'
require 'open3'

class ArtworkTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir
    @artwork = RubyPlayer::Artwork.new
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def track_for(path, backend: 'gme', archive_entry: '')
    RubyPlayer::Track.new(id: 1, physical_path: path, backend: backend,
                          archive_entry: archive_entry, title: 't')
  end

  # Built once per run (ffmpeg is already a hard runtime dependency): an mp3
  # with fixtures/warrior.jpg muxed in as an attached_pic stream. Kept out of
  # fixtures/ because it's derivable and would double the repo's mp3 count.
  def embedded_art_mp3
    @@embedded_art_mp3 ||= begin
      path = File.join(Dir.tmpdir, 'rubyplayer-test-embedded-art.mp3')
      unless File.file?(path)
        _, stderr, status = Open3.capture3(
          'ffmpeg', '-y', '-hide_banner', '-loglevel', 'error',
          '-i', File.join(FIXTURES, '1up.mp3'),
          '-i', File.join(FIXTURES, 'warrior.jpg'),
          '-map', '0:a', '-map', '1:v', '-c', 'copy',
          '-disposition:v', 'attached_pic', path
        )
        flunk "could not build embedded-art fixture: #{stderr}" unless status.success?
      end
      path
    end
  end

  def test_embedded_art_is_extracted_from_ffmpeg_tracks
    bytes = @artwork.for_track(track_for(embedded_art_mp3, backend: 'ffmpeg'))

    refute_nil bytes
    # JPEG magic: the extracted stream must be the attached image itself.
    assert_equal "\xFF\xD8".b, bytes.byteslice(0, 2)
  end

  def test_embedded_art_beats_folder_art
    dir = File.join(@tmp, 'album')
    FileUtils.mkdir_p(dir)
    File.binwrite(File.join(dir, 'cover.png'), 'PNGDATA')
    mp3 = File.join(dir, 'song.mp3')
    FileUtils.cp(embedded_art_mp3, mp3)

    bytes = @artwork.for_track(track_for(mp3, backend: 'ffmpeg'))

    assert_equal "\xFF\xD8".b, bytes.byteslice(0, 2)
  end

  def test_folder_art_prefers_conventional_names_over_other_images
    dir = File.join(@tmp, 'album')
    FileUtils.mkdir_p(dir)
    File.binwrite(File.join(dir, 'aaa-scan.png'), 'SCAN')
    File.binwrite(File.join(dir, 'Cover.JPG'), 'COVER') # case-insensitive match
    vgm = File.join(dir, 'song.vgm')
    File.write(vgm, '')

    assert_equal 'COVER', @artwork.for_track(track_for(vgm))
  end

  def test_folder_art_falls_back_to_any_image_in_the_folder
    dir = File.join(@tmp, 'album')
    FileUtils.mkdir_p(dir)
    File.binwrite(File.join(dir, 'scan01.jpeg'), 'SCAN')
    vgm = File.join(dir, 'song.vgm')
    File.write(vgm, '')

    assert_equal 'SCAN', @artwork.for_track(track_for(vgm))
  end

  def test_archived_track_uses_the_archive_files_own_folder
    dir = File.join(@tmp, 'rips')
    FileUtils.mkdir_p(dir)
    File.binwrite(File.join(dir, 'folder.jpg'), 'ART')
    zip = File.join(dir, 'game.zip')
    File.write(zip, '')

    track = track_for(zip, archive_entry: 'inner/song.vgm')

    assert_equal 'ART', @artwork.for_track(track)
  end

  # Rip zips often carry their own cover (journey-to-silius.zip: the box
  # art beside the .nsf and .m3u, under a non-conventional name).
  def test_archived_track_uses_art_inside_its_archive
    zip = File.join(FIXTURES, 'nsf', 'journey-to-silius.zip')
    cache = RubyPlayer::ArchiveCache.new(root: File.join(@tmp, 'cache'))
    artwork = RubyPlayer::Artwork.new(archive_cache: cache)
    track = track_for(zip, archive_entry: 'Journey to Silius [RAF World] (1990-08-10)(Sunsoft).nsf')
    expected = File.binread(File.join(cache.extract(zip), 'Journey_to_Silius_box.jpg'))

    assert_equal expected, artwork.for_track(track)
  end

  # Art packed with the rip is about that rip; a folder of many zips may
  # share one image that fits none of them as well.
  def test_art_inside_the_archive_beats_art_beside_it
    dir = File.join(@tmp, 'rips')
    FileUtils.mkdir_p(File.join(dir, 'src', 'inner'))
    File.binwrite(File.join(dir, 'folder.jpg'), 'FOLDER')
    File.binwrite(File.join(dir, 'src', 'inner', 'song.vgm'), 'x')
    File.binwrite(File.join(dir, 'src', 'inner', 'box.png'), 'INSIDE')
    zip = File.join(dir, 'game.zip')
    system('bsdtar', '-cf', zip, '--format', 'zip', '-C', File.join(dir, 'src'), 'inner', exception: true)
    artwork = RubyPlayer::Artwork.new(archive_cache: RubyPlayer::ArchiveCache.new(root: File.join(@tmp, 'cache')))

    assert_equal 'INSIDE', artwork.for_track(track_for(zip, archive_entry: 'inner/song.vgm'))
  end

  # macOS AppleDouble stubs ("._cover.jpg") carry metadata, not pictures;
  # they land beside the real files on non-Mac volumes and in Mac-made zips.
  def test_appledouble_stubs_are_not_art
    dir = File.join(@tmp, 'album')
    FileUtils.mkdir_p(dir)
    File.binwrite(File.join(dir, '._cover.jpg'), 'STUB')
    File.binwrite(File.join(dir, 'zz.jpg'), 'ART')
    vgm = File.join(dir, 'song.vgm')
    File.write(vgm, '')

    assert_equal 'ART', @artwork.for_track(track_for(vgm))
  end

  def test_returns_nil_when_no_art_exists
    dir = File.join(@tmp, 'bare')
    FileUtils.mkdir_p(dir)
    vgm = File.join(dir, 'song.vgm')
    File.write(vgm, '')

    assert_nil @artwork.for_track(track_for(vgm))
  end

  def test_retro_backends_never_spawn_ffmpeg
    # gme/openmpt formats cannot carry embedded art; resolving must not pay
    # a process spawn per track just to find that out.
    artwork = RubyPlayer::Artwork.new(extractor: ->(_path) { flunk 'spawned ffmpeg' })
    dir = File.join(@tmp, 'album')
    FileUtils.mkdir_p(dir)
    vgm = File.join(dir, 'song.vgm')
    File.write(vgm, '')

    assert_nil artwork.for_track(track_for(vgm, backend: 'gme'))
  end

  def test_average_color_of_a_solid_image
    red_png = File.join(Dir.tmpdir, 'rubyplayer-test-red.png')
    unless File.file?(red_png)
      _, stderr, status = Open3.capture3(
        'ffmpeg', '-y', '-hide_banner', '-loglevel', 'error',
        '-f', 'lavfi', '-i', 'color=c=red:s=16x16', '-frames:v', '1', red_png
      )
      flunk "could not build red fixture: #{stderr}" unless status.success?
    end

    color = @artwork.average_color(File.binread(red_png))

    assert_match(/\A#[0-9a-f]{6}\z/, color)
    r, g, b = [color[1, 2], color[3, 2], color[5, 2]].map { |h| h.to_i(16) }

    assert_operator r, :>, 200
    assert_operator g, :<, 60
    assert_operator b, :<, 60
  end

  def test_average_color_of_garbage_is_nil
    assert_nil @artwork.average_color('not an image'.b)
  end

  def test_display_bytes_converts_large_images_to_bounded_png
    big_png = File.join(Dir.tmpdir, 'rubyplayer-test-big.png')
    unless File.file?(big_png)
      _, stderr, status = Open3.capture3(
        'ffmpeg', '-y', '-hide_banner', '-loglevel', 'error',
        '-f', 'lavfi', '-i', 'color=c=blue:s=1600x1200', '-frames:v', '1', big_png
      )
      flunk "could not build big fixture: #{stderr}" unless status.success?
    end

    original = File.binread(big_png)
    scaled = @artwork.display_bytes(original, max_px: 480)

    refute_equal original, scaled

    assert_equal "\x89PNG\r\n\x1a\n".b, scaled.byteslice(0, 8)
    probe = File.join(@tmp, 'scaled.png')
    File.binwrite(probe, scaled)
    dims, = Open3.capture2(
      'ffprobe', '-v', 'error', '-select_streams', 'v:0',
      '-show_entries', 'stream=width,height', '-of', 'csv=p=0', probe
    )
    width, height = dims.strip.split(',').map(&:to_i)

    assert_operator width, :<=, 480
    assert_operator height, :<=, 480
  end

  def test_display_bytes_converts_small_jpeg_to_png_without_upscaling
    small = File.binread(File.join(FIXTURES, 'warrior.jpg')) # 300px-ish

    scaled = @artwork.display_bytes(small, max_px: 480)

    refute_equal small, scaled
    assert_equal "\x89PNG\r\n\x1a\n".b, scaled.byteslice(0, 8)
    dims = probe_dimensions(scaled)

    assert_equal probe_dimensions(small), dims
    assert_operator dims.max, :<=, 480
  end

  def test_display_bytes_converts_small_gif_to_png
    gif = File.join(@tmp, 'small.gif')
    _, stderr, status = Open3.capture3(
      'ffmpeg', '-y', '-hide_banner', '-loglevel', 'error',
      '-f', 'lavfi', '-i', 'color=c=green:s=32x24:d=0.1', '-frames:v', '1', gif
    )
    flunk "could not build GIF fixture: #{stderr}" unless status.success?

    png = @artwork.display_bytes(File.binread(gif), max_px: 480)

    assert_equal "\x89PNG\r\n\x1a\n".b, png.byteslice(0, 8)
    assert_equal [32, 24], probe_dimensions(png)
  end

  def test_display_bytes_caches_successes_and_failures
    bytes = File.binread(File.join(FIXTURES, 'warrior.jpg'))
    displayed = @artwork.display_bytes(bytes, max_px: 480)

    assert_same displayed, @artwork.display_bytes(bytes, max_px: 480)

    calls = 0
    @artwork.define_singleton_method(:display_png) do |_bytes, _max_px|
      calls += 1
      nil
    end

    assert_nil @artwork.display_bytes('not an image'.b, max_px: 480)
    assert_nil @artwork.display_bytes('not an image'.b, max_px: 480)
    assert_nil @artwork.display_bytes('not an image'.b, max_px: 240)
    assert_equal 2, calls # failures are cached by content and pixel limit
  end

  def test_display_bytes_returns_nil_when_ffmpeg_is_missing
    bytes = File.binread(File.join(FIXTURES, 'warrior.jpg'))
    original_path = ENV.fetch('PATH')
    ENV['PATH'] = File.join(@tmp, 'empty-path')

    assert_nil @artwork.display_bytes(bytes, max_px: 480)
  ensure
    ENV['PATH'] = original_path
  end

  def test_display_bytes_returns_nil_for_garbage
    junk = 'not an image'.b

    assert_nil @artwork.display_bytes(junk, max_px: 480)
  end

  def test_folder_lookup_is_cached_per_directory
    dir = File.join(@tmp, 'album')
    FileUtils.mkdir_p(dir)
    File.binwrite(File.join(dir, 'cover.jpg'), 'ART')
    a = File.join(dir, 'a.vgm')
    b = File.join(dir, 'b.vgm')
    File.write(a, '')
    File.write(b, '')

    assert_equal 'ART', @artwork.for_track(track_for(a))
    File.delete(File.join(dir, 'cover.jpg'))
    # Same directory: served from cache, no re-glob.
    assert_equal 'ART', @artwork.for_track(track_for(b))
  end

  private

  def probe_dimensions(bytes)
    path = File.join(@tmp, 'probe.png')
    File.binwrite(path, bytes)
    dims, = Open3.capture2(
      'ffprobe', '-v', 'error', '-select_streams', 'v:0',
      '-show_entries', 'stream=width,height', '-of', 'csv=p=0', path
    )
    dims.strip.split(',').map(&:to_i)
  end
end

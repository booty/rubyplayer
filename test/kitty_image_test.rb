require 'test_helper'

class KittyImageTest < Minitest::Test
  Kitty = RubyPlayer::UI::KittyImage

  def test_detects_kitty_and_rejects_multiplexers
    assert Kitty.supported?({ 'TERM' => 'xterm-kitty' })
    assert Kitty.supported?({ 'TERM_PROGRAM' => 'kitty' })
    assert Kitty.supported?({ 'KITTY_WINDOW_ID' => '12' })
    refute Kitty.supported?({ 'TERM' => 'xterm-kitty', 'TMUX' => '/tmp/tmux' })
    refute Kitty.supported?({ 'TERM_PROGRAM' => 'kitty', 'STY' => '1' })
  end

  def test_detects_only_current_stable_iterm2
    assert Kitty.supported?({ 'TERM_PROGRAM' => 'iTerm.app', 'TERM_PROGRAM_VERSION' => '3.5.4' })
    assert Kitty.supported?({ 'LC_TERMINAL' => 'iTerm2', 'LC_TERMINAL_VERSION' => '3.5.10' })
    refute Kitty.supported?({ 'TERM_PROGRAM' => 'iTerm.app', 'TERM_PROGRAM_VERSION' => '3.5.3' })
    refute Kitty.supported?({ 'TERM_PROGRAM' => 'iTerm.app', 'TERM_PROGRAM_VERSION' => '3.5.4beta1' })
    refute Kitty.supported?({ 'LC_TERMINAL' => 'iTerm2' })
    refute Kitty.supported?({ 'TERM_PROGRAM' => 'iTerm.app', 'TERM_PROGRAM_VERSION' => 'unknown' })
  end

  def test_uploads_png_in_direct_base64_chunks_then_places_with_cursor_preserved
    out = StringIO.new
    image = Kitty.new(output: out)
    png = "\x89PNG\r\n\x1a\n".b + ('x' * 7000)

    image.render(png, row: 4, col: 9, width: 20, height: 10)

    commands = out.string.scan(/\e_G(.*?)\e\\/m).flatten
    uploads = commands.take_while do |command|
      command.start_with?('a=t,', 'q=2,m=')
    end

    assert_operator uploads.length, :>, 1
    assert_match(/\Aa=t,t=d,f=100,i=\d+,q=2,m=1\z/, uploads.first.split(';', 2).first)
    assert uploads.drop(1).all? { |command| command.split(';', 2).first.match?(/\Aq=2,m=[01]\z/) }
    payloads = uploads.map { |command| command.split(';', 2).last }

    assert payloads.all? { |part| part.bytesize <= 4096 }
    assert_match(/\Aq=2,m=0;/, uploads.last)
    encoded = payloads.join

    assert_equal [png].pack('m0'), encoded
    place = commands.find { |command| command.include?('a=p,') }

    assert_match(/a=p,i=\d+,p=\d+,c=20,r=10,C=1,q=2/, place)
    assert_match(/\e\[s\e\[5;10H.*\e\[u/m, out.string)
  end

  def test_reuses_upload_across_repositioning_and_unchanged_render
    out = StringIO.new
    image = Kitty.new(output: out)
    png = "\x89PNG\r\n\x1a\nsmall".b

    image.render(png, row: 0, col: 0, width: 8, height: 4)
    first = out.string.dup
    image.render(png, row: 0, col: 0, width: 8, height: 4)

    assert_equal first, out.string
    image.render(png, row: 1, col: 2, width: 8, height: 4)

    commands = out.string.scan(/\e_G(.*?)\e\\/m).flatten

    assert_equal 1, commands.count { |command| command.include?('a=t,') }
    assert_equal 2, commands.count { |command| command.include?('a=p,') }
  end

  def test_force_repairs_placement_without_reupload
    out = StringIO.new
    image = Kitty.new(output: out)
    png = "\x89PNG\r\n\x1a\nsmall".b
    image.render(png, row: 1, col: 1, width: 8, height: 4)
    out.truncate(0)
    out.rewind

    image.render(png, row: 1, col: 1, width: 8, height: 4, force: true)

    assert_equal 1, out.string.scan('a=p,').length
    refute_includes out.string, 'a=t,'
  end

  def test_replacement_frees_old_image_and_hides_are_idempotent
    out = StringIO.new
    image = Kitty.new(output: out)
    image.render("\x89PNG\r\n\x1a\nfirst".b, row: 0, col: 0, width: 8, height: 4)
    out.truncate(0)
    out.rewind

    image.render("\x89PNG\r\n\x1a\nsecond".b, row: 0, col: 0, width: 8, height: 4)

    assert_match(/a=d,d=I,i=\d+,q=2/, out.string)
    image.hide
    hidden = out.string.dup
    image.hide

    assert_equal hidden, out.string
    assert_match(/a=d,d=i,i=\d+,p=\d+,q=2/, hidden)
    image.clear
    cleared = out.string.dup
    image.clear

    assert_equal cleared, out.string
  end

  def test_invalid_geometry_hides_existing_placement
    out = StringIO.new
    image = Kitty.new(output: out)
    png = "\x89PNG\r\n\x1a\nimage".b
    image.render(png, row: 0, col: 0, width: 8, height: 4)
    out.truncate(0)
    out.rewind

    image.render(png, row: 0, col: 0, width: 0, height: 4)

    assert_match(/a=d,d=i,i=\d+,p=\d+,q=2/, out.string)
    refute_includes out.string, 'a=p,'
  end

  def test_write_uses_current_output_resolver
    out = StringIO.new
    image = Kitty.new(output: -> { out })
    image.render("\x89PNG\r\n\x1a\nimage".b, row: 0, col: 0, width: 8, height: 4)

    refute_empty out.string
  end

  def test_fits_wide_region_to_image_aspect_and_centers_horizontally
    out = StringIO.new
    image = Kitty.new(output: out, cell_size: -> { [10, 20] })

    image.render(png_sized(480, 480), row: 2, col: 3, width: 40, height: 10)

    # 400x200px region holds a 200x200px square: 20 cols x 10 rows.
    assert_match(/a=p,i=\d+,p=\d+,c=20,r=10,C=1,q=2/, out.string)
    assert_match(/\e\[3;14H/, out.string)
  end

  def test_fits_tall_region_to_image_aspect_and_centers_vertically
    out = StringIO.new
    image = Kitty.new(output: out, cell_size: -> { [10, 20] })

    image.render(png_sized(480, 480), row: 0, col: 0, width: 10, height: 20)

    assert_match(/c=10,r=5,/, out.string)
    assert_match(/\e\[8;1H/, out.string)
  end

  def test_crops_source_to_rounded_cell_box_so_pixels_never_stretch
    out = StringIO.new
    image = Kitty.new(output: out, cell_size: -> { [10, 20] })

    # 150x150px fits as 15 cols x 7.5 rows; 8 rows is a 150x160px box, so
    # the source loses 30px of width instead of the image stretching 7%.
    image.render(png_sized(480, 480), row: 0, col: 0, width: 15, height: 10)

    assert_match(/a=p,i=\d+,p=\d+,x=15,y=0,w=450,h=480,c=15,r=8,C=1,q=2/, out.string)
  end

  def test_refits_when_cell_size_changes_at_same_region
    cells = [10, 20]
    out = StringIO.new
    image = Kitty.new(output: out, cell_size: -> { cells })
    png = png_sized(480, 480)
    image.render(png, row: 0, col: 0, width: 40, height: 10)
    cells = [20, 20]

    image.render(png, row: 0, col: 0, width: 40, height: 10)

    assert_match(/c=10,r=10,/, out.string)
  end

  def test_unknown_cell_size_fits_with_configured_aspect_in_whole_cells
    out = StringIO.new
    image = Kitty.new(output: out, cell_size: -> {}, cell_aspect: -> { 2.0 })

    image.render(png_sized(320, 240), row: 0, col: 0, width: 16, height: 8, gap: 1.0)

    # Guessed cell pixels can't drive sub-cell offsets, so the gap snaps to
    # whole cells: one column each side, centered in the leftover rows.
    assert_match(/c=14,r=5,/, out.string)
    assert_match(/\e\[2;2H/, out.string)
    refute_match(/[XY]=/, out.string)
  end

  def test_gap_matches_sides_to_the_bottom_in_whole_cells
    out = StringIO.new
    image = Kitty.new(output: out, cell_size: -> { [10, 23] })

    # A one-cell-width gap is 10px. Below, the border's half row already
    # leaves 11.5px, so no padding row; beside it a padding column makes
    # 15px, nearer 11.5 than the 5px without one.
    image.render(png_sized(480, 480), row: 0, col: 1, width: 47, height: 20, gap: 1.0, align: :bottom)

    assert_match(/a=p,i=\d+,p=\d+,[^c]*c=45,r=20,C=1,q=2/, out.string)
    assert_match(/\e\[1;3H/, out.string)
    refute_match(/[XY]=/, out.string)
  end

  def test_bottom_alignment_puts_spare_rows_above_the_art_without_sub_cell_offsets
    out = StringIO.new
    image = Kitty.new(output: out, cell_size: -> { [10, 20] })

    # Below, the border's half row is already the 10px gap; beside it, a
    # padding column each side is the nearest match. 44 cols x 22 rows of
    # a square leaves two spare rows, both above the art.
    image.render(png_sized(480, 480), row: 3, col: 1, width: 46, height: 24, gap: 1.0, align: :bottom)

    assert_match(/a=p,i=\d+,p=\d+,c=44,r=22,C=1,q=2/, out.string)
    assert_match(/\e\[6;3H/, out.string)
    refute_match(/[XY]=/, out.string)
  end

  def test_height_limited_art_keeps_spare_columns_even_so_sides_match
    out = StringIO.new
    image = Kitty.new(output: out, cell_size: -> { [7, 13] })

    # 19 rows of 4:3 is 47.05 cols, leaving 3 spare: one side would get a
    # whole extra cell. 48 cols splits the spare evenly; the crop absorbs it.
    image.render(png_sized(400, 300), row: 20, col: 1, width: 50, height: 19, gap: 1.0, align: :bottom)

    assert_match(/c=48,r=19,/, out.string)
    assert_match(/\e\[21;3H/, out.string)
  end

  def test_rows_to_fill_sizes_a_region_the_art_spans_edge_to_edge
    whole_cells = Kitty.new(output: StringIO.new, cell_size: -> { [10, 23] })
    even = Kitty.new(output: StringIO.new, cell_size: -> { [10, 20] })
    png = png_sized(480, 480)

    assert_equal 20, whole_cells.rows_to_fill(png, width: 47, gap: 1.0)
    assert_equal 22, even.rows_to_fill(png, width: 46, gap: 1.0)
    assert_nil whole_cells.rows_to_fill("\x89PNG\r\n\x1a\nshort".b, width: 47, gap: 1.0)
  end

  def test_exposes_png_size_and_cell_size_for_layout
    assert_equal [320, 240], Kitty.png_size(png_sized(320, 240))
    assert_nil Kitty.png_size("\x89PNG\r\n\x1a\nshort".b)
    assert_equal [10, 20], Kitty.new(output: StringIO.new, cell_size: -> { [10, 20] }).cell_size
    assert_equal [1, 2.5], Kitty.new(output: StringIO.new, cell_size: -> {}, cell_aspect: -> { 2.5 }).cell_size
  end

  private

  def png_sized(width, height)
    ["\x89PNG\r\n\x1a\n".b, [13].pack('N'), 'IHDR', [width, height].pack('NN'), 'x' * 32].join.b
  end
end

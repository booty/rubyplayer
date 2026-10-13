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
end

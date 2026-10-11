require 'test_helper'
require 'rubyplayer/backends/chiptune_metadata'
require 'tempfile'
require 'zlib'

class ChiptuneMetadataTest < Minitest::Test
  def metadata(data, extension)
    Tempfile.create(['chip', ".#{extension}"]) do |file|
      file.binmode
      file.write(data)
      file.flush
      RubyPlayer::Backends::ChiptuneMetadata.read(file.path)
    end
  end

  def vgm(version: 0x150)
    data = "\0".b * 0x100
    data[0, 4] = 'Vgm '
    data[8, 4] = [version].pack('V')
    data[0x34, 4] = [0xcc].pack('V') if version >= 0x150
    data
  end

  def test_vgm_reads_declared_chips_clocks_and_dual_chip_flag
    data = vgm
    data[0x0c, 4] = [3_579_545].pack('V')
    data[0x2c, 4] = [7_670_454 | 0x40000000].pack('V')
    extras = metadata(data, 'vgm')

    assert_equal '1.50', extras['vgm_version']
    assert_equal 'SN76489 + 2 x YM2612', extras['sound_chips']
    assert_includes extras['chip_clocks'], 'YM2612 7670454 Hz'
    assert_includes extras['voice_layout'], '6 FM (FM 6 can use PCM)'
    refute_includes extras['chip_clocks'], '1081412278'
  end

  def test_gzip_vgm_has_the_same_hardware_metadata
    data = vgm
    data[0x2c, 4] = [7_670_454].pack('V')

    assert_equal metadata(data, 'vgm'), metadata(Zlib.gzip(data), 'vgz')
  end

  def test_vgm_psg_variant_flag_is_not_mistaken_for_two_standard_psg_chips
    data = vgm
    data[0x0c, 4] = [3_072_000 | 0xc0000000].pack('V')
    extras = metadata(data, 'vgm')

    assert_equal 'T6W28', extras['sound_chips']
    assert_includes extras['chip_clocks'], '3072000 Hz'
  end

  def test_vgm_ym3438_variant_preserves_the_fm_voice_layout
    data = vgm
    data[0x2c, 4] = [7_670_454 | 0x80000000].pack('V')
    extras = metadata(data, 'vgm')

    assert_equal 'YM3438', extras['sound_chips']
    assert_includes extras['voice_layout'], '6 FM'
  end

  def test_legacy_vgm_clock_is_not_misidentified_as_ym2413
    data = vgm(version: 0x101)
    data[0x10, 4] = [7_670_454].pack('V')
    extras = metadata(data, 'vgm')

    assert_equal 'YM2612', extras['sound_chips']
    assert_includes extras['chip_clocks'], '7670454 Hz'
  end

  def test_nsf_and_nsfe_include_declared_expansion_hardware
    nsf = "\0".b * 128
    nsf[0, 5] = "NESM\x1a"
    nsf.setbyte(0x7b, 0x05)
    info = "\0".b * 10
    info.setbyte(7, 0x05)
    nsfe = "NSFE#{[10].pack('V')}INFO#{info}#{[0].pack('V')}NEND"
    %w[nsf nsfe].zip([nsf, nsfe]).each do |extension, data|
      extras = metadata(data, extension)

      assert_equal 'NES APU + VRC6 + FDS', extras['sound_chips']
      assert_includes extras['voice_layout'], '2 pulse'
    end
  end

  def test_variable_hardware_formats_respect_header_flags
    assert_equal '2 x POKEY', metadata("SAP\r\nSTEREO\r\n\xff\xff".b, 'sap')['sound_chips']
    assert_equal 'POKEY', metadata("SAP\r\n\xff\xff".b, 'sap')['sound_chips']
    kss = "KSSX#{"\0" * 12}"

    assert_includes metadata(kss, 'kss')['sound_chips'], 'AY-3-8910'
    kss.setbyte(15, 2)

    assert_equal 'SN76489', metadata(kss, 'kss')['sound_chips']
  end

  def test_fixed_hardware_profiles_and_truncated_headers
    %w[gbs spc hes gym ay].each do |extension|
      refute_empty metadata('', extension).fetch('sound_chips')
      refute_empty metadata('', extension).fetch('voice_layout')
    end
    assert_empty metadata('Vgm ', 'vgm')
    assert_empty metadata('', 'nsf')
    assert_empty metadata('', 'nsfe')
    assert_empty metadata('', 'kss')
  end
end

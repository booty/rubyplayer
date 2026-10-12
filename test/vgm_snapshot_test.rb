# frozen_string_literal: true

require 'test_helper'
require 'rubyplayer/vgm/snapshot'

class VgmSnapshotTest < Minitest::Test
  def test_contract_values_deep_freeze_nested_data
    identity = [7, '/tmp/song.vgm', nil, 0]
    capabilities = { ym2612: { rendered: true }, warning: +'partial' }
    source = RubyPlayer::Vgm::Source.new(
      generation: 2, track_identity: identity, path: '/tmp/song.vgm', format: :vgm,
      sample_rate: 44_100, timeline_policy: :preserve_leading_silence,
      decoder_capabilities: capabilities
    )

    assert_predicate source.track_identity, :frozen?
    assert_predicate source.decoder_capabilities.fetch(:ym2612), :frozen?
    assert_predicate source.decoder_capabilities.fetch(:warning), :frozen?
    assert_raises(FrozenError) { source.track_identity << 8 }
    assert_raises(FrozenError) { source.decoder_capabilities.fetch(:ym2612)[:rendered] = false }
    assert_raises(FrozenError) { source.path << '.bak' }
  end

  def test_snapshot_and_operator_contracts_freeze_nested_values
    operator = RubyPlayer::Vgm::Operator.new(index: 1, parameters: { tl: 24 })
    patch = RubyPlayer::Vgm::Patch.new(
      digest: +'a' * 64, algorithm: 4, feedback: 2, operators: [operator], details: {}
    )
    snapshot = RubyPlayer::Vgm::Snapshot.new(
      generation: 1, revision: 0, sample: 12, status: :ready, message: nil,
      loop_count: 0,
      chips: [RubyPlayer::Vgm::ChipSnapshot.new(
        id: 'ym2612:0', name: 'YM2612', clock_hz: 7_670_454, channels: [], details: {}
      )],
      warnings: [+'timer key activity is unmodeled']
    )

    assert_predicate patch.operators, :frozen?
    assert_predicate operator.parameters, :frozen?
    assert_predicate snapshot.chips, :frozen?
    assert_predicate snapshot.warnings.first, :frozen?
    assert_raises(FrozenError) { snapshot.warnings.first << '!' }
  end
end

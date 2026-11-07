# frozen_string_literal: true

module RubyPlayer
  # Session-only settings; native audio output owns all signal processing.
  class EffectsRack
    Effect = Struct.new(:name, :enabled, :intensity_percent, keyword_init: true)
    NAMES = ['AM Radio', 'Arcade Cabinet', 'Tube Amp', 'Cassette Deck',
             'Mega Bass', 'Underwater', 'Music Hall', 'Echo Chamber'].freeze

    attr_reader :effects

    def initialize(audio:)
      @audio = audio
      @effects = NAMES.map { |name| Effect.new(name: name, enabled: false, intensity_percent: 50) }
      @bypassed = false
    end

    def bypassed? = @bypassed

    def toggle(index)
      effect = @effects.fetch(index)
      effect.enabled = !effect.enabled
      @audio.set_effect(index, effect.enabled ? effect.intensity_percent : 0, reset: !effect.enabled)
    end

    def adjust(index, delta_percent)
      effect = @effects.fetch(index)
      effect.intensity_percent = (effect.intensity_percent + delta_percent).clamp(1, 100)
      @audio.set_effect(index, effect.intensity_percent, reset: false) if effect.enabled
    end

    def toggle_bypass
      @bypassed = !@bypassed
      @audio.set_effects_bypass(@bypassed, reset: true)
    end
  end
end

# frozen_string_literal: true

module RubyPlayer
  # Session-only settings; native audio output owns all signal processing.
  class EffectsRack
    Effect = Struct.new(:name, :enabled, :intensity_percent, keyword_init: true)
    # The native control treats 0 as "off", so an enabled effect keeps at
    # least 1 percent; on/off is the separate enabled flag.
    MIN_INTENSITY_PERCENT = 1
    MAX_INTENSITY_PERCENT = 100

    attr_reader :effects

    def initialize(audio:, default_intensity_percent: 50, step_percent: 5)
      @audio = audio
      @step_percent = step_percent
      # Names come from the native rack, so an effect's position is its id.
      @effects = audio.effect_names.map do |name|
        Effect.new(name: name, enabled: false, intensity_percent: clamp_intensity(default_intensity_percent))
      end
      @bypassed = false
    end

    def bypassed? = @bypassed

    def toggle(effect_id)
      effect = @effects.fetch(effect_id)
      effect.enabled = !effect.enabled
      @audio.set_effect(effect_id, effect.enabled ? effect.intensity_percent : 0, reset: !effect.enabled)
    end

    def increase(effect_id) = adjust(effect_id, @step_percent)
    def decrease(effect_id) = adjust(effect_id, -@step_percent)

    def adjust(effect_id, delta_percent)
      effect = @effects.fetch(effect_id)
      effect.intensity_percent = clamp_intensity(effect.intensity_percent + delta_percent)
      @audio.set_effect(effect_id, effect.intensity_percent, reset: false) if effect.enabled
    end

    def toggle_bypass
      @bypassed = !@bypassed
      @audio.set_effects_bypass(@bypassed, reset: true)
    end

    private

    def clamp_intensity(percent) = percent.clamp(MIN_INTENSITY_PERCENT, MAX_INTENSITY_PERCENT)
  end
end

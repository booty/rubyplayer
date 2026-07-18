module RubyPlayer
  # Semantic color palettes for the TUI. Screen#put already accepts either a
  # named ANSI symbol or a "#rrggbb" truecolor string for fg/bg, so a theme
  # is just a Hash of semantic role => one of those two forms; widgets look
  # up roles (border, selection_bg, ...) instead of hardcoding a color.
  module Theme
    # Reproduces the app's original hardcoded colors exactly: nil means "let
    # the terminal use its own default foreground/background" (every call
    # site that used to pass no fg/bg at all), and each named ANSI symbol
    # matches the literal color that specific widget used before theming
    # existed. Selecting Default must look pixel-identical to pre-theme
    # rendering.
    DEFAULT = {
      name: "Default (Terminal)", mode: :dark,
      background: nil, surface: :black, surface_alt: :bright_black,
      text: nil, text_muted: :bright_black, text_subtle: :bright_black, text_inverse: nil,
      border: :bright_black, border_focus: :bright_cyan,
      primary: :bright_white, primary_text: nil,
      accent: :bright_yellow, accent_text: nil,
      success: :green, warning: :yellow, error: :bright_red, info: :cyan,
      selection_bg: :blue, selection_text: :bright_white,
      cursor: :bright_white, disabled: :bright_black,
    }.freeze

    THEMES = {
      basic_terminal: {
        name: "Basic Terminal",
        mode: :dark,

        background: "#000000",
        surface: "#111111",
        surface_alt: "#1a1a1a",

        text: "#f2f2f2",
        text_muted: "#a0a0a0",
        text_subtle: "#6f6f6f",
        text_inverse: "#000000",

        border: "#5f5f5f",
        border_focus: "#ffffff",

        primary: "#ffffff",
        primary_text: "#000000",

        accent: "#00ff00",
        accent_text: "#000000",

        success: "#00ff00",
        warning: "#ffff00",
        error: "#ff5555",
        info: "#55aaff",

        selection_bg: "#ffffff",
        selection_text: "#000000",

        cursor: "#ffffff",
        disabled: "#555555",
      },

      neon_cyberpunk: {
        name: "Neon Cyberpunk",
        mode: :dark,

        background: "#100018",
        surface: "#1d0630",
        surface_alt: "#2a0a45",

        text: "#f7eaff",
        text_muted: "#c49adf",
        text_subtle: "#8d6aa8",
        text_inverse: "#120016",

        border: "#8a2be2",
        border_focus: "#00f5ff",

        primary: "#ff2bd6",
        primary_text: "#120016",

        accent: "#00f5ff",
        accent_text: "#001013",

        success: "#39ff88",
        warning: "#ffe95c",
        error: "#ff3b6b",
        info: "#6c7dff",

        selection_bg: "#ff2bd6",
        selection_text: "#120016",

        cursor: "#00f5ff",
        disabled: "#6f4b82",
      },

      military_olive: {
        name: "Military Olive",
        mode: :dark,

        background: "#1f2417",
        surface: "#2c321f",
        surface_alt: "#394125",

        text: "#f2efd8",
        text_muted: "#c4bea2",
        text_subtle: "#8f886d",
        text_inverse: "#1f2417",

        border: "#69704a",
        border_focus: "#f2a23a",

        primary: "#a6b56c",
        primary_text: "#1f2417",

        accent: "#f28c28",
        accent_text: "#211100",

        success: "#9fbd5c",
        warning: "#f2c14e",
        error: "#d95d39",
        info: "#8aa6a3",

        selection_bg: "#f28c28",
        selection_text: "#211100",

        cursor: "#f2a23a",
        disabled: "#5d6147",
      },

      solarized_light_like: {
        name: "Solarized Light-ish",
        mode: :light,

        background: "#fdf6e3",
        surface: "#eee8d5",
        surface_alt: "#e7dfc6",

        text: "#073642",
        text_muted: "#586e75",
        text_subtle: "#839496",
        text_inverse: "#fdf6e3",

        border: "#93a1a1",
        border_focus: "#268bd2",

        primary: "#268bd2",
        primary_text: "#fdf6e3",

        accent: "#2aa198",
        accent_text: "#fdf6e3",

        success: "#859900",
        warning: "#b58900",
        error: "#dc322f",
        info: "#268bd2",

        selection_bg: "#d6ecf3",
        selection_text: "#073642",

        cursor: "#073642",
        disabled: "#aaa79a",
      },

      solarized_dark_like: {
        name: "Solarized Dark-ish",
        mode: :dark,

        background: "#002b36",
        surface: "#073642",
        surface_alt: "#0b4653",

        text: "#eee8d5",
        text_muted: "#93a1a1",
        text_subtle: "#657b83",
        text_inverse: "#002b36",

        border: "#586e75",
        border_focus: "#268bd2",

        primary: "#268bd2",
        primary_text: "#fdf6e3",

        accent: "#2aa198",
        accent_text: "#002b36",

        success: "#859900",
        warning: "#b58900",
        error: "#dc322f",
        info: "#268bd2",

        selection_bg: "#073642",
        selection_text: "#eee8d5",

        cursor: "#eee8d5",
        disabled: "#586e75",
      },

      sunset_coral: {
        name: "Sunset Coral",
        mode: :light,

        background: "#fff6ea",
        surface: "#ffe8d2",
        surface_alt: "#ffd7b0",

        text: "#2b2230",
        text_muted: "#6f5961",
        text_subtle: "#9b7f7b",
        text_inverse: "#fff6ea",

        border: "#e89a72",
        border_focus: "#ff5a4f",

        primary: "#ff5a4f",
        primary_text: "#ffffff",

        accent: "#f5a623",
        accent_text: "#251500",

        success: "#2f9e73",
        warning: "#d98200",
        error: "#c73535",
        info: "#2f7ca3",

        selection_bg: "#ffb066",
        selection_text: "#2b1500",

        cursor: "#ff5a4f",
        disabled: "#c7afa4",
      },

      ocean_mist: {
        name: "Ocean Mist",
        mode: :light,

        background: "#f1fbfb",
        surface: "#dff4f2",
        surface_alt: "#c7ebe9",

        text: "#183446",
        text_muted: "#3f6f7a",
        text_subtle: "#7fa8ad",
        text_inverse: "#f1fbfb",

        border: "#8bc9c7",
        border_focus: "#2b6f95",

        primary: "#2b6f95",
        primary_text: "#ffffff",

        accent: "#5ed7d2",
        accent_text: "#082829",

        success: "#2f9e73",
        warning: "#c88a00",
        error: "#c44747",
        info: "#2b6f95",

        selection_bg: "#b8ece9",
        selection_text: "#102c3a",

        cursor: "#2b6f95",
        disabled: "#91aeb3",
      },

      twilight_grape: {
        name: "Twilight Grape",
        mode: :dark,

        background: "#21103a",
        surface: "#321d52",
        surface_alt: "#46306d",

        text: "#f3eaff",
        text_muted: "#c7b0e8",
        text_subtle: "#937ab6",
        text_inverse: "#21103a",

        border: "#6d4ba3",
        border_focus: "#d49bf2",

        primary: "#9b5de5",
        primary_text: "#ffffff",

        accent: "#72d8d6",
        accent_text: "#062524",

        success: "#64d28b",
        warning: "#f6c85f",
        error: "#ff5c8a",
        info: "#72d8d6",

        selection_bg: "#9b5de5",
        selection_text: "#ffffff",

        cursor: "#d49bf2",
        disabled: "#665077",
      },

      berry_punch: {
        name: "Berry Punch",
        mode: :dark,

        background: "#18284f",
        surface: "#28335f",
        surface_alt: "#3a3f72",

        text: "#fff0f7",
        text_muted: "#e4b1ca",
        text_subtle: "#a97796",
        text_inverse: "#1b1330",

        border: "#8d3b72",
        border_focus: "#ef3e7b",

        primary: "#ef3e7b",
        primary_text: "#ffffff",

        accent: "#b5367e",
        accent_text: "#ffffff",

        success: "#4fc58a",
        warning: "#f6c85f",
        error: "#ff5a5f",
        info: "#5fa8ff",

        selection_bg: "#ef3e7b",
        selection_text: "#ffffff",

        cursor: "#ff78a3",
        disabled: "#6e5770",
      },

      amber_navy: {
        name: "Amber Navy",
        mode: :dark,

        background: "#151a3d",
        surface: "#20285a",
        surface_alt: "#2f3b7a",

        text: "#f4f0d9",
        text_muted: "#b9c1df",
        text_subtle: "#7f89b6",
        text_inverse: "#151a3d",

        border: "#465193",
        border_focus: "#ffa600",

        primary: "#3fa0f5",
        primary_text: "#07182a",

        accent: "#ffa600",
        accent_text: "#241400",

        success: "#4fc58a",
        warning: "#ffd166",
        error: "#ff5c5c",
        info: "#3fa0f5",

        selection_bg: "#ffa600",
        selection_text: "#241400",

        cursor: "#ffa600",
        disabled: "#555d87",
      },

      cream_forest: {
        name: "Cream Forest",
        mode: :light,

        background: "#fbf0db",
        surface: "#e6ddd0",
        surface_alt: "#d5cbc0",

        text: "#263f36",
        text_muted: "#557267",
        text_subtle: "#8aa196",
        text_inverse: "#fbf0db",

        border: "#91a89d",
        border_focus: "#2f5d50",

        primary: "#2f5d50",
        primary_text: "#ffffff",

        accent: "#f2a23a",
        accent_text: "#231300",

        success: "#467a45",
        warning: "#b87b00",
        error: "#b94b45",
        info: "#2b6f95",

        selection_bg: "#c7d8cc",
        selection_text: "#1e332b",

        cursor: "#2f5d50",
        disabled: "#a8aaa0",
      },

      high_contrast_blue: {
        name: "High Contrast Blue",
        mode: :dark,

        background: "#050814",
        surface: "#0b1430",
        surface_alt: "#13204a",

        text: "#ffffff",
        text_muted: "#b9c7ff",
        text_subtle: "#7888c7",
        text_inverse: "#050814",

        border: "#3351a3",
        border_focus: "#7dd3fc",

        primary: "#7dd3fc",
        primary_text: "#03111a",

        accent: "#facc15",
        accent_text: "#1c1300",

        success: "#22c55e",
        warning: "#facc15",
        error: "#fb7185",
        info: "#60a5fa",

        selection_bg: "#7dd3fc",
        selection_text: "#03111a",

        cursor: "#ffffff",
        disabled: "#4b587f",
      },
    }.freeze

    # :default first (it's the initial/fallback selection), then the named
    # themes in their declared order -- this order also drives the picker
    # modal's list and Up/Down cycling.
    ALL = { default: DEFAULT }.merge(THEMES).freeze
    ALL_IDS = ALL.keys.freeze

    def self.[](id)
      ALL[id&.to_sym] || DEFAULT
    end

    # Which semantic roles each pulse intensity may brighten. Scope doubles
    # as the cost model: the roles are ordered by how many cells they touch,
    # so "low" repaints a few hundred border cells per beat while "high"
    # sweeps the whole frame. (Border glow and selection shimmer are these
    # scopes, not separate effects.)
    PULSE_ROLES = {
      low: %i[border border_focus],
      medium: %i[border border_focus surface surface_alt selection_bg accent],
      high: %i[border border_focus surface surface_alt selection_bg accent
               primary info text_muted text],
    }.freeze

    # Palette-cycling pulse: each pulse-scoped role renders as a named ANSI
    # index (left column — what Screen emits) whose terminal palette slot
    # (right column) is reprogrammed per beat step via OSC 4. Truecolor
    # themes never touch the 16 ANSI slots, so all of them are free to
    # repurpose as role slots while a hex theme is active. The Default
    # (ANSI) theme can't pulse — its slots are the user's real terminal
    # colors.
    PULSE_SLOTS = {
      border: [:black, 0], border_focus: [:red, 1], surface: [:green, 2],
      surface_alt: [:yellow, 3], selection_bg: [:blue, 4], accent: [:magenta, 5],
      primary: [:cyan, 6], info: [:white, 7], text_muted: [:bright_black, 8],
      text: [:bright_red, 9],
    }.freeze

    def self.truecolor?(theme)
      theme[:border].is_a?(String)
    end

    # Derived pulse frames are cached per (theme, mode, step): the beat
    # envelope revisits the same handful of quantized steps continuously, so
    # after the first beat every frame is a Hash lookup — no per-frame color
    # math, and identical Hash objects keep Screen's cell diff cheap.
    # step 0 returns the base theme itself: "no pulse" must be
    # indistinguishable from the feature not existing.
    def self.pulsed(theme, mode:, step:, steps:, shift:)
      return theme if step.zero? || !PULSE_ROLES.key?(mode)

      @pulse_cache ||= {}
      @pulse_cache[[theme.object_id, mode, step, steps, shift]] ||= begin
        fraction = step.to_f / (steps - 1) * shift
        overlay = PULSE_ROLES[mode].to_h { |role| [role, brighten(theme[role], fraction)] }
        theme.merge(overlay).freeze
      end
    end

    # Named-ANSI values (the Default theme) pass through: there is nothing
    # to interpolate toward in a 16-color palette.
    def self.brighten(color, fraction)
      return color unless color.is_a?(String) && color.start_with?("#")

      channels = [color[1, 2], color[3, 2], color[5, 2]].map do |hex|
        value = hex.to_i(16)
        (value + (255 - value) * fraction).round
      end
      format("#%02x%02x%02x", *channels)
    end
  end
end

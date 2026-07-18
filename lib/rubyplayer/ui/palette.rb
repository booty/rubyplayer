module RubyPlayer
  module UI
    # Terminal palette programming via OSC 4 / OSC 104. iTerm2 supports the
    # standard xterm form alongside its proprietary 1337;SetColors — same
    # cost, and this one works in other terminals too. This is what makes
    # palette-cycling pulse possible: repaint nothing, redefine what the
    # already-painted indexed colors mean.
    module Palette
      def self.set(slot, hex)
        "\e]4;#{slot};rgb:#{hex[1, 2]}/#{hex[3, 2]}/#{hex[5, 2]}\a"
      end

      # Resets all indexed slots to the user's profile colors. The alternate
      # screen buffer does NOT restore the palette on exit — this must be
      # emitted explicitly whenever the app stops owning the slots.
      def self.reset = "\e]104\a"
    end
  end
end

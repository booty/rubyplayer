module RubyPlayer
  VERSION = "0.1.0"
end

require_relative "rubyplayer/config"
require_relative "rubyplayer/database"
require_relative "rubyplayer/track"
require_relative "rubyplayer/library"
require_relative "rubyplayer/backends/registry"
require_relative "rubyplayer/scanner"
require_relative "rubyplayer/extractor_pool"
require_relative "rubyplayer/play_queue"
require_relative "rubyplayer/level_tap"
require_relative "rubyplayer/template"
require_relative "rubyplayer/keymap"
require_relative "rubyplayer/event_bus"
require_relative "rubyplayer/ui/screen"
require_relative "rubyplayer/ui/library_pane"
require_relative "rubyplayer/ui/tracks_pane"

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

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'minitest/autorun'
require 'rubyplayer'
require_relative 'support/async_wait'

Minitest::Test.include TestSupport::AsyncWait

FIXTURES = File.expand_path('../fixtures', __dir__)

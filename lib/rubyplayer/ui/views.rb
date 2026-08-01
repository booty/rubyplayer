# frozen_string_literal: true

module RubyPlayer
  module UI
    # Single source of truth for the library's fixed views. Before this table
    # existed, adding a view meant editing five hand-synced case statements
    # (LibraryPane SPECIALS + label_for, TracksPane load_tracks + title,
    # App selected_tracks) — easy to miss one and ship a view with no label
    # or no query. Hash insertion order is the sidebar display order.
    module Views
      View = Struct.new(:label, :glyph, :query, keyword_init: true)

      # query is nil for sources that aren't plain Library reads: the queue
      # and focus rows come from the engine/focus registry, and history needs
      # a config-driven limit plus row unwrapping (see TracksPane#load_tracks).
      # App#selected_tracks relies on those nils too — enqueueing the History
      # sidebar row itself (rather than a track inside it) must stay a no-op.
      ALL = {
        queue: View.new(label: 'Playback Queue', glyph: 'play'),
        history: View.new(label: 'History', glyph: 'playlist'),
        favorites: View.new(label: 'Favorite Tracks', glyph: 'star',
                            query: lambda(&:favorites)),
        focus: View.new(label: 'Focus', glyph: 'focus'),
        recent: View.new(label: 'Recently Added', glyph: 'playlist',
                         query: lambda(&:recently_added)),
        unrated: View.new(label: 'Unrated', glyph: 'playlist',
                          query: lambda(&:unrated)),
        missing: View.new(label: 'Missing', glyph: 'missing',
                          query: lambda(&:missing_tracks)),
        failed: View.new(label: 'Failed to Scan', glyph: 'errored',
                         query: lambda(&:failed_tracks)),
        most_played: View.new(label: 'Most Played', glyph: 'play',
                              query: lambda(&:most_played)),
        # nil query: the parent row is a container — enqueueing it wholesale
        # is a no-op (children carry the tracks), same rule as queue/history.
        playlists: View.new(label: 'Playlists', glyph: 'playlist'),
        all: View.new(label: 'All Songs', glyph: 'dir',
                      query: lambda(&:all_tracks))
      }.freeze

      def self.query(kind, library)
        query = ALL[kind]&.query
        query ? query.call(library) : []
      end

      def self.label(kind) = ALL[kind]&.label
    end
  end
end

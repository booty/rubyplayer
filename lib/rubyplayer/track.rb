# frozen_string_literal: true

module RubyPlayer
  Track = Struct.new(:id, :folder_id, :physical_path, :archive_entry, :subtune_index,
                     :backend, :format, :title, :album, :artist, :composer,
                     :album_artist, :year,
                     :track_number, :duration_ms, :play_length_ms, :duration_source,
                     :rating, :missing, :errored,
                     keyword_init: true) do
    def self.from_row(row)
      new(id: row['id'], folder_id: row['folder_id'], physical_path: row['physical_path'],
          archive_entry: row['archive_entry'], subtune_index: row['subtune_index'],
          backend: row['backend'], format: row['format'], title: row['title'],
          album: row['album'], artist: row['artist'], composer: row['composer'],
          album_artist: row['album_artist'], year: row['year'],
          track_number: row['track_number'], duration_ms: row['duration_ms'],
          play_length_ms: row['play_length_ms'], duration_source: row['duration_source'],
          rating: row['rating'], missing: row['missing'], errored: row['errored'])
    end

    def display_duration_ms = duration_ms || play_length_ms

    def planned_duration? = duration_ms.nil? && !play_length_ms.nil?
  end
end

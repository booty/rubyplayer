# Retro Music Player
#projects

We are creating a Ruby TUI music library/playback application.

## Overview

Target platform is MacOS, using Ruby 4.x. This is a personal app so cross-platform compatibility with Linux or Windows is not an immediate goal. Assume a “Nerd Font” w/ extended glyphs is installed.

It will play retro game music and tracker formats like .MOD, .VGM, .GYM, and and others using a backends like `libgme`, `libopenmpt`, `vgmstream`, and/or other backends. We will need more than one backend so we’ll have to maintain a mapping between filetype and appropriate backend.

Output will be piped to `libao/SDL/PortAudio/miniaudio` (need your help speccing this part out)

Use ncurses or a newer fancier TUI library (need help deciding this — whatever is modern and supported in Ruby in 2026)

Configuration settings are stored in a TOML file for now, we can add a GUI later

## Library Functionality

This is a library style media application. Users can drag/drop folders or individual files to the TUI. The folders will then be recursively scanned for compatible file types, which will be added to the library.

* Library is a .sqlite3 database, containing
  * File paths
  * File names
  * Metadata
    * Common metadata should be stored in dedicated columns
      * Filetype, track name, album name, length, composer, track number, etc
      * Rating: NULL or 1, 2, 3, 4, 5, 6 (nullable int)
    * Less common metadata can be stored in a child key/value table

On application startup scan the library in the background and look for missing, new, and changed files. Update the library accordingly.

Missing files should be flagged as missing but not immediately removed

Back up the current library .sqlite3 file on startup to a timestamped file

Library sqlite3 file should contain a schema version number so we don’t try to load an incompatible scheme version

Any time we make changes to the schema we should up this version number

We do not need to maintain backward compatibility with older schema versions (though this is a future goal)

There is not a 1:1 mapping between physical files and songs in the library. We will support common playlist files, and compressed formats like .zip/.rar./7z. These single physical files are treated like folders in the library view and contain 0 or more songs.

Maintain a playback history table with track_id, playback_start, and playback_end. Don’t bother to insert into this table if less than 5% of the song is listened to
## User Interface

Responsiveness is a priority. When possible perform actions on background threads rather than blocking.

We will eventually support selectable RGB color schemes but for the MVP let’s just use ANSI colors

NOTE: Since compressed archives and playlist files are treated as virtual folders, any time we refer to “folders” we really mean “real folders, compressed archives, and playlist files”

“Tracks” and “songs” are used interchangeabley

* Layout
  * Library pane (left side, default 33% width)
    * First item is the `Playback Queue`
      * First item is the currently playing song, if any
      * Remaining items are the songs that will be played next
    * Second item is `History` showing recently played tracks (up to 100)
    * Third item is `Favorite Tracks` showing all tracks with a rating of at least 4
    * Shows a tree view of folders in the library. Each folder listing display the following
      * NerdFont Icon indicating whether it’s a real folder, playlist, or compressed archive
      * Name of the folder
      * In a different font color, the number of tracks (recursive) under the folder
      * Example: “📁 ~/Music/Sega (304)” where 304 is the number of tracks
      * Don’t display empty folders, or playlists/archives with songs we don’t support, in the user interface.
    * Hotkeys when library view is active
      * Up/down arrows: navigate up and down
      * Left/right arrows: expand/collapse folder to show folders underneath it
    * Will obviously need to scroll
  * Tracks pane (right side, default 67% width)
    * When the `Playback Queue` is selected in the Library Pane
      * Show a list of enqueued tracks
    * When `History` is selected in the Library Pane
      * Show the last 100 tracks played
      * Don’t show a track if less than 5% was played
    * When a folder (real or virtual) is selected in the Library Pane
      * Show a list of tracks, recursively, in this folder
    * Hotkeys
      * G: Toggle grouping of songs by album
      * T: Sort by title
      * N: Sort by track number
      * A: Sort by artist
      * If grouping by album is active, use album info for sorting not track info
      * Song display
        * In the config file, store format strings to represent how tracks should be displayed
        * When grouped by album:
          * #{track.number} #{track.title} #{track.duration} #{track.artist if different from album artist} #{rating}”
        * When not groupd by album:
          * #{track.album} {track.number} #{track.title} #{track.duration} #{track.artist if different from album artist} #{rating}”
        * App should watch the config file and hotload these format strings so we can see changes in real time
    * Will obviously need to scroll
  * Status line (bottom of screen, 1 line, 100% width, under Library and Tracks panes)
    * Default view: number of files/folders in library and global hotkeys
    * After an action has been performed: show results of previous action for 5 seconds then revert to default display
      * Examples:
        * “45 tracks enqueued (CMD+Z to undo)”
        * “Track removed from queue (CMD+Z to undo)”
  * Pane-specific hotkeys line (bottom of screen, 1 line, 100% width, under Status Line)
    * List hotkeys for currently active pane
  * Playback line
    * “Graphic equalizer” animation if currently playing
    * Metadata information for currently playing track, or track at the top of the playback queue
* Global hotkeys
  * TAB: Cycle between Library and Tracks panes as the “active” pane
  * SPACE: Start/pause playback
    * If nothing playing, play the first song in the playback queue
    * If nothing in the playback queue, do nothing
  * CMD+Z / SHIFT+CMD+Z:
    * undo/redo the last queueing operation (any time the user manually adds or remove tracks from the playback queue, save up to 10 previous versions in a stack. CMD+Z pops the previous version from the stack)
    * immediately select Playback Queue in the Library Pane
  * P: Select Playback Queue in the Library Pane
  * ENTER: Enqueue and play selected track or tracks immediately
  * Q: Enqueue selected track or tracks at the front of the queue
  * N: Enqueue selected track or tracks at the end of the queue
  * 0: Remove rating of current song (set to null)
  * 1-6: Set rating of current song
  * S: Skip tracks with a rating of 1 (disliked tracks)
* The currently active pane should have a border in a bright color so the user knows which pane is active

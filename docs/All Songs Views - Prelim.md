# "All Songs" Sortings/Groupings

# Example Data

The below examples will refer to this. Suppose we have the following tracks in our library:

Album Artist, Artist, Album, Year, Track Number, Track Name
Alice, Alice, Apple, 1976, 1, AppleTrack1
Alice, Alice, Apple, 1976, 2, AppleTrack2
Alice, Alice & Bobby, Apple, 1976, 3, AppleTrack3
Alice, Alice, Burrito, 1971, 1, BurritoTrack1
Alice, Alice, Burrito, 1971, 2, BurritoTrack2
Alice, Alice, Burrito, 1971, 3, BurritoTrack3
Bobby, Bobby, Carnitas, 1980, 1, CarnitasTrack1
Bobby, Bobby, Carnitas, 1980, 1, CarnitasTrack1
Bobby, Bobby, Carnitas, 1980, 1, CarnitasTrack1
Carol, Carol, Doritos, 1980, 1, DoritosTrack1
Carol, Carol, Doritos, 1980, 1, DoritosTrack1
Carol, Carol, Doritos, 1980, 1, DoritosTrack1
(null), Debby, (null), (null), (null), DebbysSong

# Overview

Pressing a hotkey in "All Songs" cycles through various sortings/groupings options.

"Album Artist, Album (Alpha)"
  Right (Tracks) Pane:
    Groups by Album Artist, sorted alphabetically
    Groups by Albums, sorted alphabetically
    Then sorts by track number (falls back to track name if no track number)
  Left Pane:
    All Songs [Album Artist, Album (Alpha)]
      - Alice
      - Bobby
      - Carol
      - Others
"Album Artist, Album (Chrono)"
  Right (Tracks) Pane:
    Groups by Album Artist, sorted alphabetically
    Groups by Albums, sorted chronologically
    Then sorts by track number (falls back to track name if no track number)
  Left Pane:
    All Songs [Album Artist, Album (Alpha)]
      - 1971
      - 1976
      - 1980
"Album (Chrono)"
  Right (Tracks) Pane:
    Groups by year, sorted chronolocially
    Groups by albums, sorted alphabetically
    Then sorts by tracknumber|trackname
  Left Pane:
    All Songs [Album Artist, Album (Alpha)]
      - 1971
      - 1976
      - 1980
      - Others
"Artist, Name (Alpha)"
  Groups by Artist Name, sorted alphabetically
  Sorts by track name, alphabetically
"Artist, Track (Chrono)"
  Groups by Artist Name, sorted alphabetically
  Sorts by track name, chronologically
  Sorts by track name, alphabetically
"Album (Chrono)"
  Groups by albums, which are sorted alphabetically
"Folder Name (Alpha)"
  Similar to the current "all songs" view



## Edge Cases

### Missing metadata

If metadata is missing for a particular sort/group field, sort these nulls at the end and lump them into an "Unknown" category at the end.




## Album Artist, Album (Alpha), Track Number

### Library Pane

- All Songs
  - Alice
  - Bobby
  - Carol
  - Others

"Others" is for tracks like `(null), Debby, (null), (null), (null), DebbysSong` where the album is unknown.

### Tracks Pane

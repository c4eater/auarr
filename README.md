Description
-----------
Just another Perl script that fixes ID3 tags and sorts audio files.

It traverses the specified directory searching for music albums (which is a set of audio files in the same format, +optionally logs and scans, with properly set ID3 tags).
If an album is found, the files are copied to the output directory using the destination path as in e.g. "Blackmore's Night/2001 - Fires at Midnight/01 - Written in the Stars.flac". Otherwise, a warning is written to STDERR, and the album is ignored.

An important feature is that this script guarantees processing of an album as an atomic entity.
The album undergoes the tag fixing and relocating procedure ONLY if the ID3 tags of the whole fileset is fine (= no missing tags like performer and title, no tracknumber conflicts, performer name and album name are the same for the whole fileset, etc). Otherwise, the script leaves the whole album in place, and does not attempt to modify anything.

The script also removes insignificant tags (=tags other than: TITLE, ARTIST, ALBUM, DATE, GENRE, TRACKNUMBER, TRACKTOTAL, DISCNUMBER, COMPOSER).

This script is intended strictly for personal use and I cannot guarantee that it sorts out your particular audio collection as expected.



Limitations
-------------------
- As of now, supports only albums in FLAC+tracks format.
Planned support: FLAC+CUE, APE+tracks, APE+CUE, MP3.

- Not able to handle some complicated layouts (eg. directories containing a mix of audio files and nested directories). Remember, the script is intended to use on albums, not on individual tracks, and it ignores anything that it considers to be not an album. If you have some individual audio files which do not form an album, please sort them manually instead of using this script.

- Not able to read ID3 tags from files containing ` and " in filenames.

- ONLY for Ext filesystems! This is because some non-portable symbols are allowed in the output filenames (most notable are \ : ?). I will probably make the script replace the non-portable symbols with _ in future, but for now I just don't care about FS compatibility.

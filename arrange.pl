#!/usr/bin/perl

use strict;
use warnings;
use File::pushd;
use Getopt::Long;
use Term::ANSIColor;



my $outdir = "/mnt/storage/music-sorted";



sub help {
    print "\nUsage: ", colored(['bold'], "arrange.pl"),
          " [-hr]\n\n";
    print "\t", colored(['bold'], "-h, --help\n"),
          "\t\tShow the help screen.\n";
    print "\n";
    print "\t", colored(['bold'], "-r, --remove-source\n"),
          "\t\tRemove source directories in case of successful processing.\n";
}



# A directory is considered a "scans directory" if it meets _all_ of the
# following criteria:
#
#     - Has no directories inside, only files;
#     - All the files inside are of graphical types (jpg, bmp, etc)
#
#
# A directory is considered an "album directory" if it meets _all_ of the
# following criteria:
#
#     - The directory name:
#           - either contains a year and an album name (guessed from the tags)
#           - or:
#               - equals to "CD1", "CD2" etc.
#               - the parent directory name contains a year and an album name
#               - the parent directory contains only child dirs "CD1", "CD2" etc.
#
#     - The directory has no child directories other than a scans directory
#       (optional);
#
#     - The directory contains audio data in one of the following forms:
#           - list of audio tracks (mp3, flac, ape, etc)
#           - an unsplit audio file (flac, wav, wv, iso, etc) + cuesheet +
#             logfile (optional)
#
#     - The directory has no files other than the audio files specified above
#       and, optionally, the following ones:
#           - text files (txt, log) - will be ignored during export;
#           - playlists (m3u, wpl, etc) - will be ignored during export;
#           - image files (jpg, bmp etc) - will be considered scans/booklets
#             and moved to a separate folder (except for "front.jpg" and
#             "cover.jpg") - these will be considered front images and left
#             in place; will be renamed to cover.jpg for consistency though.
#
#
# A directory is considered an "artist directory" if it has only album directories
# underneath and, optionally, audio files.


sub traverse {
    my $dir = shift || $_;

    opendir(my $dh, $dir) or die "Error: can't \"opendir\" " . $dir;
    my $newpath = pushd $dir;

    while (readdir $dh) {
        # Iterate through the directory contents.
        next if /^\.\.?$/;

        my (@files, @dirs);

        -f ? push @files, $_ : push @dirs, $_;

        # TODO: Process files and dirs, detect cuesheets, etc.

        foreach (@dirs) {
            printf "descend into %s\n", $_;
            traverse();
        }
    };

    closedir $dh;
}



# OK, here we start.

if ($#ARGV) {
    print "\nWrong number of arguments.\n";
    help;
    exit;
}

our($opt_help, $opt_remove_source);

GetOptions('help' => \$opt_help, 'remove-source' => \$opt_remove_source)
    or die "Wrong command line options specified";

if (defined $opt_help) {
    help;
    exit;
}

#mkdir "$outdir" unless -e "$outdir";

traverse $ARGV[0];

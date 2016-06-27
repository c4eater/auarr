#!/usr/bin/perl

use strict;
use warnings;
use Cwd "cwd";
use File::pushd;
use File::Spec "abs2rel";
use Getopt::Long;
use Term::ANSIColor;
#use Data::Dumper;



# Print out the help.
sub help {
    print "\nUsage: ", colored(['bold'], "arrange.pl"),
          " [-hr]\n\n";
    print "\t", colored(['bold'], "-h, --help\n"),
          "\t\tShow the help screen.\n";
    print "\n";
    print "\t", colored(['bold'], "-r, --remove-source\n"),
          "\t\tRemove source directories in case of successful processing.\n";
}



# Print out an error message highlighted by red.
sub _error {
    my $msg = shift or return;

    print STDERR colored(['red'], $msg);
}



# Print out a warning message highlighted by yellow.
sub _warn {
    my $msg = shift or return;

    print STDERR colored(['yellow'], $msg);
}



# Accept a directory as an argument, and return the current working
# directory in a relative form, treating the argument as a basedir.
sub rcwd {
    return File::Spec->abs2rel(cwd(), $ARGV[0]);
}



# Given a FLAC file name, return a hash storing this file's Vorbis tags.
sub vorbis_get {
    my $file = shift or die "Error: \"file\" not specified";

    my $command = `metaflac --list --block-type=VORBIS_COMMENT \"$file\"`;

    open(my $fh, '<', \$command);

    my %vorbis_tags = ();

    while (<$fh>) {
        chomp;
        (my $key, my $value) = $_ =~ /comment\[[[:alnum:]]+\]: (.*)=(.*)/;
        $vorbis_tags{$key} = $value if $key && $value;
    }

    close $fh;

    return \%vorbis_tags;
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



# Check if a directory is a scans directory.
sub fetch_scans {
    my ($files, $dirs) = @_;

    return 0 if @$dirs || !@$files;

    foreach (@$files) {
        return 0 unless /\.jpg$/i || /\.bmp$/i || /\.png$/i || /\.tif$/i;
    }

    return 1;
}



# Collect albums from a directory in a recursive way.
#
# If an album is successfully fetched and copied, the function returns 1.
# (This also results in removing the source dir in case --remove-source
# has been activated.)
#
# Otherwise, the function returns 0.
sub fetch_albums {
    my ($files, $dirs) = @_;

    foreach my $i (0..@$dirs-1) {
        if (funcall(\&fetch_scans, ${$dirs}[$i])) {
            my $scans_dir = ${$dirs}[$i];
            delete ${$dirs}[$i];
            last;
        }
    }

    if (@$files and @$dirs) {
        _error sprintf("MIXED_CONTENTS  %s\n", rcwd);
        return 0;
    }

    if (@$dirs) {
        map({ funcall(\&fetch_albums, $_) } @$dirs);
        return 0;
    }

    return 0 if !@$files;

    my (@mp3, @cue, @flac, @ape, @txt, @graphical);

    my %classifier = ( "mp3"  => \@mp3,
                       "cue"  => \@cue,
                       "flac" => \@flac,
                       "ape"  => \@ape,
                       "log"  => \@txt,
                       "txt"  => \@txt,
                       "jpg"  => \@graphical,
                       "bmp"  => \@graphical,
                       "png"  => \@graphical,
                       "tif"  => \@graphical);

    foreach my $file (@$files) {
        (my $ext) = $file =~ /\.([a-z0-9]+)$/i;

        unless ($ext) {
            _warn sprintf("NO_EXT          %s/%s\n", rcwd, $file);

            return 1;
        }

        my $class = $classifier{lc($ext)};

        unless ($class) {
            _warn sprintf("BAD_EXT         %s/%s\n", rcwd, $file);

            return 1;
        }

        push @$class, $file;
    }

    if (@mp3 && !@cue && !@flac && !@ape) {
        _warn sprintf("MP3             %s\n", rcwd);
        return 1;
    } elsif (!@mp3 && @flac==1 && @cue==1 && !@ape) {
        _warn sprintf("FLAC+CUE        %s\n", rcwd);
        return 1;
    } elsif (!@mp3 && @ape==1 && @cue==1 && !@flac) {
        _warn sprintf("APE+CUE         %s\n", rcwd);
        return 1;
    } elsif (!@mp3 && (@flac>1) && !@ape) {
        printf("FLAC            %s\n", rcwd);
        printf("=== DEBUG ===\n%s\n",
               join("\n\n", map({ my $flacdata = vorbis_get($_);
                                  join("\n",
                                       map({ sprintf("%s = %s",
                                                     $_, $flacdata->{$_}) }
                                           keys($flacdata))) }
                                @flac)));
        print "=== DEBUG END ===\n\n";

        return 1;
    } else {
        _warn sprintf("FAILDETECT      %s\n", rcwd);
        return 1;
    }
}



# Apply the given subroutine to files and subdirectories of the given directory.
sub funcall {
    my $fn = shift or die "Error: \"fn\" not specified";
    my $dir = shift or die "Error: \"dir\" not specified";

    opendir(my $dh, $dir) or die "Error: can't \"opendir\" " . $dir;
    my $newpath = pushd $dir;
    my (@files, @dirs);

    while (readdir $dh) {
        next if /^\.\.?$/;
        -f $_ ? push @files, $_ : push @dirs, $_;
    };

    closedir $dh;

    return &$fn(\@files, \@dirs);
}



# OK, here we start.

if ($#ARGV) {
    print "\nWrong number of arguments.\n";
    help;
    exit;
}

our($opt_help, $opt_remove_source);

GetOptions('help'          => \$opt_help,
           'remove-source' => \$opt_remove_source)
    or die "Wrong command line options specified";

if (defined $opt_help) {
    help;
    exit;
}

funcall \&fetch_albums, $ARGV[0];

#!/usr/bin/perl

use strict;
use warnings;
use Cwd "cwd";
use File::pushd;
use File::Spec "abs2rel";
use Getopt::Long;
use Term::ANSIColor;
#use Data::Dumper;



sub help {
    print "\nUsage: ", colored(['bold'], "arrange.pl"),
          " [-hr]\n\n";
    print "\t", colored(['bold'], "-h, --help\n"),
          "\t\tShow the help screen.\n";
    print "\n";
    print "\t", colored(['bold'], "-r, --remove-source\n"),
          "\t\tRemove source directories in case of successful processing.\n";
}


sub _error {
    my $msg = shift or return;

    print STDERR colored(['red'], $msg);
}


sub _warn {
    my $msg = shift or return;

    print STDERR colored(['yellow'], $msg);
}


sub rcwd {
    return File::Spec->abs2rel(cwd(), $ARGV[0]);
}


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



sub fetch_scans {
    my ($files, $dirs) = @_;

    return 0 if @$dirs || !@$files;

    foreach (@$files) {
        return 0 unless /\.jpg$/ || /\.bmp$/ || /\.png$/;
    }

    return 1;
}



sub fetch_album {
    my ($files, $dirs) = @_;

    return 0 if !@$files or @$dirs > 1;

    return 0 if ((@$dirs == 1) && !funcall(\&fetch_scans, @$dirs[0]));

    my (@mp3, @cue, @flac, @ape, @txt, @graphical);

    my %classifier = ( "mp3"  => \@mp3,
                       "cue"  => \@cue,
                       "flac" => \@flac,
                       "ape"  => \@ape,
                       "log"  => \@txt,
                       "txt"  => \@txt,
                       "jpg"  => \@graphical,
                       "png"  => \@graphical,
                       "bmp"  => \@graphical);

    foreach my $file (@$files) {
        (my $ext) = $file =~ /\.([a-z0-9]+)$/;

        unless ($ext) {
            _warn sprintf("File \"%s\" in: \"%s\" has empty extension, giving up scan\n",
                         $file, rcwd);

            return 1;
        }

        my $class = $classifier{$ext};

        unless ($class) {
            _warn sprintf("File \"%s\" in: \"%s\" has unknown extension, giving up scan\n",
                         $file, rcwd);

            return 1;
        }

        push @$class, $file;
    }

    if (@mp3 && !@cue && !@flac && !@ape) {
        printf "Found MP3 album in: %s\n", rcwd;
        return 1;
    } elsif (!@mp3 && @flac==1 && @cue==1 && !@ape) {
        printf "Found FLAC+CUE album in: %s\n", rcwd;
        return 1;
    } elsif (!@mp3 && @ape==1 && @cue==1 && !@flac) {
        printf "Found APE+CUE album in: %s\n", rcwd;
        return 1;
    } elsif (!@mp3 && (@flac>1) && !@ape) {
        printf "Found FLAC album in: %s\n", rcwd;
        return 1;
    } else {
        _warn sprintf("Cannot guess the album format in: %s\n",
                      rcwd);
        return 1;
    }
}



sub collect_albums {
    my ($files, $dirs) = @_;

    foreach my $dir (@$dirs) {
        funcall (\&fetch_album, $dir) or funcall (\&collect_albums, $dir);
    }

    return 0;
}



sub funcall {
    my $fn = shift or die "Error: \"fn\" not specified";
    my $dir = shift || $_ or die "Error: \"dir\" not specified";

    opendir(my $dh, $dir) or die "Error: can't \"opendir\" " . $dir;
    my $newpath = pushd $dir;
    my (@files, @dirs);

    while (readdir $dh) {
        next if /^\.\.?$/;
        -f ? push @files, $_ : push @dirs, $_;
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

GetOptions('help' => \$opt_help, 'remove-source' => \$opt_remove_source)
    or die "Wrong command line options specified";

if (defined $opt_help) {
    help;
    exit;
}

funcall \&collect_albums, $ARGV[0];

#!/usr/bin/perl
#
# Just another Perl script that fixes audio tags and sorts audio files.
#
# TODO: Add a normal workflow description.
#
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
#     - The directory has no child directories other than a scans directory
#       (optional);
#
#     - The directory contains audio data in one of the following forms:
#           - list of audio tracks of the same type (mp3, flac, ape, etc)
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

use strict;
use warnings;
use Cwd "cwd";
use File::pushd;
use File::Spec "abs2rel";
use Getopt::Long;
use Term::ANSIColor;
use Data::Dumper;



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



# Accept a directory name as an argument, and return the current working
# directory name in a relative form, treating the argument as a basedir.
sub rcwd {
    return File::Spec->abs2rel(cwd(), $ARGV[0]);
}



# Given a FLAC file name, return a hashref storing this file's Vorbis tags.
# If there is an error fetching these tags, return 0.
sub fetch_vorbis_tags_file {
    my $file = shift or die "Error: \"file\" argument not specified";
    my $command = `metaflac --list --block-type=VORBIS_COMMENT \"$file\"`;

    return 0 if $?;

    open(my $command_ostream, '<', \$command);

    my %vorbis_tags = ();

    while (<$command_ostream>) {
        chomp;
        (my $key, my $value) = $_ =~ /comment\[[[:alnum:]]+\]: (.*)=(.*)/;
        $vorbis_tags{$key} = $value if $key && $value;
    }

    close $command_ostream;

    return \%vorbis_tags;
}



# Collect Vorbis tags of the given list of FLAC files if these files form a
# valid album, and return it in an arrayref form.
# If not, issue an error message and return 0.
sub fetch_vorbis_tags_fileset {
    my $files = shift;
    my $file0 = shift $files;
    my $tagset0 = fetch_vorbis_tags_file($file0);
    my $has_missing_tag = 0;

    unless ($tagset0) {
        _error sprintf("NO_VORBIS_TAGS  %s/%s\n", rcwd, $file0);
        return 0;
    }

    my @tagsets = ($tagset0);

    # Check tagset0 for empty tags.
    map( { unless ($tagsets[0]->{$_}) {
               _error sprintf("    MISSING_TAG_%-8s    %s/%s\n",
                              $_, rcwd, $$files[0]);
               $has_missing_tag = 1; }
         }
         ("TITLE", "ARTIST", "ALBUM", "DATE", "TRACKNUMBER"));

    return 0 if $has_missing_tag;

    foreach my $file (@{$files}) {
        my $tagset = fetch_vorbis_tags_file($file);

        unless ($tagset) {
            _error sprintf("    NO_VORBIS_TAGS  %s/%s\n", rcwd, $file);
            return 0;
        }

        # Check the remaining tagsets for empty and mismatching tags.
        # Terminate on first error.
        map( { unless ($tagset->{$_}) {
                   _error sprintf("    MISSING_TAG_%-8s    %s/%s\n",
                                  $_, rcwd, $file);
                   $has_missing_tag = 1; }
             }
             ("TITLE", "ARTIST", "ALBUM", "DATE", "TRACKNUMBER"));

        if ($has_missing_tag) {
            return 0;
        } else {
            push(@tagsets, $tagset);
        }
    }

    return \@tagsets;
}



# Check if a directory is a scans directory.
sub fetch_scans {
    my ($files, $dirs) = @_;

    return 0 if @$dirs || !@$files;

    foreach (@$files) {
        return 0 unless /\.jpg$/i || /\.bmp$/i || /\.png$/i || /\.tif$/i;
    }

    return 1;
}



# Collect albums from a directory in a recursive way, copying audio files
# and CD cover scans from album directories to the output directory.
#
# If the function argument is an album directory and the album is successfully
# fetched and copied, the function returns 1.
# (This also results in removing the source dir in case --remove-source
# has been activated.)
#
# Otherwise, the function returns 0. This can happen in two cases:
#   - The directory has no audio files and the function just applied itself
#     recursively to the subdirectories, hoping to fetch albums there;
#   - An error occurred, e.g. the directory has mixed contents (audio files
#     plus non-scans subdirectories).
sub fetch_albums {
    my ($files, $dirs) = @_;

    foreach my $i (0..@$dirs-1) {
        if (apply_fn_to_dir(\&fetch_scans, ${$dirs}[$i])) {
            my $scans_dir = ${$dirs}[$i];
            splice(@$dirs, $i, 1);
            last;
        }
    }

    if (@$files and @$dirs) {
        _error sprintf("MIXED_CONTENTS  %s\n", rcwd);
        return 0;
    }

    if (@$dirs) {
        map({ apply_fn_to_dir(\&fetch_albums, $_) } @$dirs);
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

        my $data = fetch_vorbis_tags_fileset(\@flac);

        return 1;
    } else {
        _warn sprintf("FAILDETECT      %s\n", rcwd);
        return 1;
    }
}



# Apply the given subroutine to files and subdirectories of the given directory.
sub apply_fn_to_dir {
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

apply_fn_to_dir \&fetch_albums, $ARGV[0];

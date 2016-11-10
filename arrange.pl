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
#       (optional).
#
#     - The directory contains audio data in one of the following forms:
#           - list of audio tracks of the same type (mp3, flac, ape, etc);
#           - an unsplit audio file (flac, wav, wv, iso, etc) + cuesheet +
#             logfile (optional).
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
use 5.010;
use Cwd qw(cwd);
use File::pushd;
use File::Basename qw(basename);
use File::Spec qw(abs2rel);
use Getopt::Long;
use Term::ANSIColor;
use Data::Dumper;


our($opt_help, $opt_remove_source, $opt_no_fix_tags, $opt_no_move_to_destdir,
    $opt_guess_year);


# Print out the help.
sub help {
    print "\nUsage: ", colored(['bold'], "arrange.pl"),
          " [OPTION]... SOURCE_DIR DEST_DIR\n\n";
    print "Options:\n";
    print "\t", colored(['bold'], "-h, --help\n"),
          "\t\tShow the help screen.\n";
    print "\n";
    print "\t", colored(['bold'], "-r, --remove-source\n"),
          "\t\tRemove source directories in case of successful processing.\n";
    print "\n";
    print "\t", colored(['bold'], "--no-move-to-destdir\n"),
          "\t\tOnly fix tags, do not copy/move anything to the destination directory.\n";
    print "\n";
    print "\t", colored(['bold'], "--no-fix-tags\n"),
          "\t\tOnly scan tags and print out errors, do not modify anything.\n",
          "\t\tImplies --no-move-to-destdir. DEST_DIR is not required in this case.\n";
    print "\n";
    print "\t", colored(['bold'], "--guess-year\n"),
          "\t\t(Experimental) In case of missing DATE tag (= the release year) try to guess it from the parent directory name.\n\n";
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
# valid album, and return these tags in a form of an array of hashes (1 hash
# object =  1 tagset = 1 file).
#
# Tag scanning includes the tag validation process, which can result in
# encountering what is called a "tag error". The tag errors can be either
# critical or non-critical. The critical tag errors are:
#
#     - A missing required tag in _any_ of the files.
#     Required tags are: "TITLE" "ARTIST" "ALBUM" "DATE" "TRACKNUMBER" "GENRE".
#     Without these tags, it is simply dangerous to perform automatic renaming.
#
#     - A tag mismatch (different values for the different files) in any of the
#     following tags: "TITLE" "ARTIST" "ALBUM" "DATE" "GENRE".
#
#     - A missing track (TRACKNUMBERs not forming a continuous sequence).
#
# If a critical tag error is encountered, issue an error message and return 0.
#
#
# The non-critical tag errors are:
#
#     - A presence of an "unneeded" tag.
#     An unneeded tag is anything that is not a required tag or the TRACKTOTAL
#     tag or the DISCNUMBER tag or the PERFORMER tag. An example would be a
#     COMMENT tag. Normally, no one ever cares of the contents of these tags,
#     and they are simply polluting the Vorbis data. In case of autocorrection
#     enabled, these tags are removed.
#
#     - A non-uppercased tag name.
#     The standart requires the tag names to come in uppercase. If
#     autocorrection is enabled, the tag name will be converted to uppercase.
#
#     - A wrong format of the TRACKNUMBER tag.
#     A trailing zero in TRACKNUMBER is an error, as opposed to file names,
#     where a trailing zero should be normally present (for a better look and
#     a correct lexicographical ordering).
#
#     - A missing TRACKTOTAL tag.
#     In case of autocorrection enabled, TRACKTOTAL is filled automatically.
#
#     - TOTALTRACKS tag instead of TRACKTOTAL.
#     This is simply not standart compliant. Track count should be stored in
#     TRACKTOTAL.
#
# If a non-critical tag error is encountered, there are 2 possible scenarios:
#     - If autocorrection is off (--no-fix-tags), issue an error message and
#     return 0;
#     - Otherwise, issue a warning message, autocorrect the tag and continue.
sub fetch_vorbis_tags_fileset {
    my $files = shift or die "Error: \"files\" argument not specified";
    my @tagsets = ();

    # critical errors (too risky to process; return 0)
    my $has_missing_tag = 0;
    my $has_tag_mismatch = 0;
    my $has_missing_track = 0;
    my $has_critical_error = 0; # any of the above (a fileset-wide flag)

    # shallow errors (can be fixed automatically)
    my $has_recoverable_date_tag = 0;
    my $has_unneeded_tag = 0;
    my $has_non_uppercase_tag = 0;
    my $has_wrong_tracknumber_format = 0;
    my $has_bad_tracktotal = 0;
    my $has_totaltracks_instead_of_tracktotal = 0;
    my $has_shallow_error = 0; # any of the above (a fileset-wide flag)

    foreach my $file (@{$files}) {
        $has_missing_tag = 0;
        $has_tag_mismatch = 0;
        $has_missing_track = 0;
        $has_recoverable_date_tag = 0;
        $has_unneeded_tag = 0;
        $has_non_uppercase_tag = 0;
        $has_wrong_tracknumber_format = 0;
        $has_bad_tracktotal = 0;
        $has_totaltracks_instead_of_tracktotal = 0;
    
        my $tagset = fetch_vorbis_tags_file($file);

        unless ($tagset) {
            _error sprintf("    NO_VORBIS_TAGS  %s/%s\n", rcwd, $file);
            $has_critical_error = 1;
            next;
        }

        # @significant_tags should be a superset of @required_tags
        my @required_tags = ("TITLE", "ARTIST", "ALBUM", "DATE", "GENRE",
                             "TRACKNUMBER");
        my @significant_tags = ("TITLE", "ARTIST", "ALBUM", "DATE", "GENRE",
                                "TRACKNUMBER", "TRACKTOTAL", "DISCNUMBER");

        # Try to guess the value of the DATE tag.
        if (!grep(/date/i, keys %$tagset) && $opt_guess_year
            && ((my $year) = basename(rcwd) =~ /^(\d{4})\D/)) {
            if ($opt_no_fix_tags) {
                _warn sprintf("    MISSING_DATE_RECOVERABLE   %s in %s/%s\n",
                              $year, rcwd, $file);
                $has_recoverable_date_tag = 1;
            } else {
                # TODO: autofill the DATE tag
            }
        }

        # Check the presence of TOTALTRACKS tag.
        if (grep(/totaltracks/i, keys %$tagset) 
            && !grep(/tracktotal/i, keys %$tagset)) {
            if ($opt_no_fix_tags) {
                _warn sprintf("    HAS_TOTALTRACKS            in %s/%s\n",
                              rcwd, $file);
                $has_totaltracks_instead_of_tracktotal = 1;
            } else {
                # TODO: TOTALTRACKS -> TRACKTOTAL
            }
        }

        # Check $tagset for missing tags.
        map( {
                unless ($tagset->{$_}) {
                    my $tag = $_;

                    # For now, allow a case mismatch in order to not confuse the
                    # user with a "missing tag" error while it is actually a
                    # case mismatch error.
                    unless (grep(/$tag/i, keys %$tagset)
                            || (!grep(/date/i, keys %$tagset)
                                && $has_recoverable_date_tag)){
                        _error sprintf("    MISSING_TAG_%-11s    %s/%s\n",
                                       $tag, rcwd, $file);
                        $has_missing_tag = 1;
                    }
                }
             }
             @required_tags);

        # Check $tagset for unneeded/lowercase tags.
        foreach my $key (keys %$tagset) {
            unless (grep /$key/, @significant_tags) {
                if (grep /$key/i, @significant_tags) {
                    if ($opt_no_fix_tags) {
                        _warn sprintf("    NON_UPPERCASE_TAG          %s=\"%s\" in %s/%s\n",
                                      $key, $tagset->{$key}, rcwd, $file);
                        $has_non_uppercase_tag = 1;
                    } else {
                        # TODO fix case mismatch
                    }
                } else {
                    if ($opt_no_fix_tags
                        and (lc($key) ne "totaltracks")
                        or grep(/tracktotal/i, keys %$tagset)) {
                        _warn sprintf("    UNNEDED_TAG                %s=\"%s\" in %s/%s\n",
                                      $key, $tagset->{$key}, rcwd, $file);
                        $has_unneeded_tag = 1;
                    } else {
                        # TODO delete unneeded tag
                    }
                }
            }
        }

        if ($has_missing_tag || $has_non_uppercase_tag) {
            # critical error
            $has_critical_error = 1;
            next;
        } 

        # Check the TRACKNUMBER format correctness.
        if ($tagset->{"TRACKNUMBER"} =~ /^0\d+$/) {
            if ($opt_no_fix_tags) {
                _warn sprintf("    BAD_TRACKNUMBER_FORMAT     %s in %s/%s\n",
                              $tagset->{"TRACKNUMBER"}, rcwd, $file);
                $has_wrong_tracknumber_format = 1;
            } else {
                # TODO fix trailing "0x" in tracknumber
            }
        }

        # Check every $tagset for mismatching tags, except for the first tagset.
        if (@tagsets) {
            map( { my $value0 = $tagsets[0]->{$_};
                   my $value = $tagset->{$_};

                   unless ((!$value0 && !$value) or ($value0 eq $value)) {
                       _error sprintf("    TAG_MISMATCH_%-7s    (\"%s\" vs \"%s\") in %s/%s\n",
                                      $_, $value, $value0, rcwd, $file);
                       $has_tag_mismatch = 1;
                   }
                 }
                 ("ARTIST", "ALBUM", "DATE", "TRACKTOTAL", "GENRE" ));
        }
        
        if ($has_missing_tag || $has_tag_mismatch) {
            # critical error
            $has_critical_error = 1;
            next;
        } elsif ($has_unneeded_tag || $has_non_uppercase_tag
                 || $has_wrong_tracknumber_format
                 || $has_recoverable_date_tag
                 || $has_totaltracks_instead_of_tracktotal) {
            # shallow error
            $has_shallow_error = 1;
        }

        push(@tagsets, $tagset);
    }

    return 0 if $has_critical_error or $has_shallow_error;

    # Check if there are missing tracks.
    my $expected_tracktotal = @tagsets;

    unless (!@tagsets or $has_wrong_tracknumber_format) {
        my @tracknumbers = sort({$a <=> $b} map({ $_->{"TRACKNUMBER"}} @tagsets));
        $expected_tracktotal = $tracknumbers[-1] if @tagsets <= $tracknumbers[-1];
        my @expected_tracknumbers = (1 .. $expected_tracktotal);
        my @missing_tracknumbers = ();

        foreach my $n (@tracknumbers) {
            my $expected_tracknumber = shift @expected_tracknumbers;
            next if $n == $expected_tracknumber;
            push(@missing_tracknumbers, $expected_tracknumber);

            while (@expected_tracknumbers) {
                $expected_tracknumber = shift @expected_tracknumbers;
                last if $n == $expected_tracknumber;
                push(@missing_tracknumbers, $expected_tracknumber);
            }
        }

        if (@missing_tracknumbers) {
            _error sprintf("    MISSING_TRACK             %s in %s\n",
                           join(",", @missing_tracknumbers), rcwd);
            $has_missing_track = 1;
        }
    }

    # Check all tagsets for a wrong TRACKTOTAL value.
    foreach my $tagset (@tagsets) {
        if (!$tagset->{"TRACKTOTAL"}
            or $tagset->{"TRACKTOTAL"} ne $expected_tracktotal) {
            if ($opt_no_fix_tags) {
                _warn sprintf("    BAD_TRACKTOTAL             \"%s\" (expected %s) in %s\n",
                              $tagset->{"TRACKTOTAL"}, $expected_tracktotal, rcwd);
                $has_bad_tracktotal = 1;
            } else {
                # TODO fix TRACKTOTAL
            }
        }
    }

    $has_critical_error &= $has_missing_track;
    $has_shallow_error &= $has_bad_tracktotal;

    return 0 if $has_critical_error or $has_shallow_error;

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
#   - An error occurs, e.g. the directory has mixed contents (audio files
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

        my $vorbis_tags = fetch_vorbis_tags_fileset(\@flac);

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

GetOptions('help'               => \$opt_help,
           'remove-source'      => \$opt_remove_source,
           'no-fix-tags'        => \$opt_no_fix_tags,
           'no-move-to-destdir' => \$opt_no_move_to_destdir,
           'guess-year'         => \$opt_guess_year)
    or die "Wrong command line options specified";

if ((defined $opt_no_fix_tags) and (!defined $opt_no_move_to_destdir)) {
    $opt_no_move_to_destdir = 1;
}

if ((defined $opt_no_move_to_destdir) && ($#ARGV != 0)
    || (!defined $opt_no_move_to_destdir) && ($#ARGV != 1)) {
    print "\nWrong number of arguments.\n";
    help;
    exit;
}

if (defined $opt_help) {
    help;
    exit;
}

apply_fn_to_dir \&fetch_albums, $ARGV[0];

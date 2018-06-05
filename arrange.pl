#!/usr/bin/perl
#
# Just another Perl script that fixes audio tags and sorts audio files.
#
# A proposed workflow is:
#     - Check the GENRE tag of the source files and fix if necessary (suggest
#       to use a third-party tool).
#
#     - Convert file extensions to lowercase. A sample search script:
#       find . -type f | grep "\.[A-Z][^\.]\+$"
#
#     - Run the script in dry-run debug mode (-v --no-fix-tags) and dump the
#       debug output (tag values) to a logfile. Check the logfile for the
#       presence of the following non-printable symbols:
#
#       [^[:alnum:][:punct:]= -/:`]
#
#       OK if they are found in insignificant tags, otherwise they should be
#       reviewed/replaced.
#
#     - For bands performing in English, check the track names for the presence
#       of non-ASCII symbols (like e.g. Cyrillic [А-Яа-я]) - this allows early
#       detection of encoding problems.
#
#     - Actually run the script. Record the log of the script output.
#
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
#       (optionally).
#
#     - The directory contains audio data in one of the following forms:
#           - list of audio tracks of the same type (mp3, flac, ape, etc);
#           - an unsplit audio file (flac, wav, wv, iso, etc) + cuesheet +
#             logfile (optional).
#
#     - The directory has no files other than the audio files specified above
#       and, optionally, the following ones:
#           - text files (txt, log) - will be moved to "logs" directory during
#             export;
#           - image files (jpg, bmp etc) - will be considered scans/booklets
#             and moved to "scans" directory during export.
use strict;
use warnings;
use 5.010;
use Cwd qw(cwd);
use File::pushd;
use File::Copy;
use File::Path qw(make_path);
use File::Basename qw(basename dirname);
use File::Spec qw(abs2rel);
use POSIX qw(strtol);
use Getopt::Long;
use Term::ANSIColor;
use Data::Dumper;


our($opt_help, $opt_verbose, $opt_remove_source, $opt_no_fix_tags,
    $opt_no_output_to_destdir, $opt_guess_year);


# Print out the help.
sub help {
    print "\nUsage: ", colored(['bold'], "arrange.pl"),
          " [OPTION]... SOURCE_DIR DEST_DIR\n\n";
    print "Options:\n";
    print "\t", colored(['bold'], "-h, --help\n"),
          "\t\tShow the help screen.\n";
    print "\n";
    print "\t", colored(['bold'], "-v, --verbose\n"),
          "\t\tMake the script more verbose (print Vorbis tags and other debug info).\n";
    print "\n";
    print "\t", colored(['bold'], "-r, --remove-source\n"),
          "\t\tRemove source directories in case of successful processing.\n";
    print "\n";
    print "\t", colored(['bold'], "--no-output-to-destdir\n"),
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



# Print out a debugging message when the --verbose option is active.
sub _debug {
    return unless $opt_verbose;

    my $msg = shift or return;

    print STDOUT sprintf("\n==== DEBUG ====\n%s\n===============\n",
                         sprintf($msg, @_));
}



# Accept a directory name as an argument, and return the current working
# directory name in a relative form, treating the argument as a basedir.
sub rcwd {
    return File::Spec->abs2rel(cwd(), $ARGV[0]);
}



# Assign the specified value to the specified Vorbis tag in the specified file.
sub set_vorbis_tag {
    my $file = shift or die "Error: \"file\" argument not specified";

    $file = $ARGV[0] . "/" . rcwd . "/" . $file;
    
    my $tag = shift or die "Error: \"tag\" argument not specified";
    my $value = shift or die "Error: \"value\" argument not specified";

    system("metaflac", qq{--set-tag=$tag=$value}, $file);
}



# Delete the specified Vorbis tag in the specified file.
sub delete_vorbis_tag {
    my $file = shift or die "Error: \"file\" argument not specified";

    $file = $ARGV[0] . "/" . rcwd . "/" . $file;
    
    my $tag = shift or die "Error: \"tag\" argument not specified";

    system("metaflac", qq{--remove-tag=$tag}, $file);
}



# Given a FLAC file name, return a hashref storing this file's Vorbis tags.
# If there is an error fetching these tags, return 0.
sub fetch_vorbis_tags_file {
    my $file = shift or die "Error: \"file\" argument not specified";

    open(my $command_ostream, '-|', "metaflac", "--list",
         "--block-type=VORBIS_COMMENT", $file) or return 0;

    my %vorbis_tags = ();

    while (<$command_ostream>) {
        chomp;
        (my $key, my $value) = $_ =~ /comment\[[[:alnum:]]+\]: ([^=]+)=(.*)/;
        $vorbis_tags{$key} = $value if $key;
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
#     following tags: "TITLE" "ARTIST" "ALBUM" "DATE" "GENRE" "DISCNUMBER".
#
#     - A missing track (TRACKNUMBERs not forming a continuous sequence).
#
#     - A conflict between non-empty TRACKTOTAL and an actual # of tracks.
#
# If a critical tag error is encountered, issue an error message and return 0.
#
#
# The non-critical tag errors are:
#
#     - A presence of an "unneeded" tag.
#     An unneeded tag is anything that is not a required tag or the TRACKTOTAL
#     tag or the DISCNUMBER tag or the PERFORMER tag. An example would be the
#     COMMENT tag. Normally, no one ever cares of the contents of these tags,
#     and they are simply polluting the Vorbis data. In case of autocorrection
#     enabled, these tags are removed.
#
#     - A non-uppercased tag name.
#     The standard requires the tag names to come in uppercase. If
#     autocorrection is enabled, the tag name will be converted to uppercase.
#
#     - A wrong format of the TRACKNUMBER tag.
#     A trailing zero in TRACKNUMBER is an error, as opposed to file names,
#     where a trailing zero should be normally present (for a better look and
#     a correct lexicographical ordering). If autocorrection is enabled, the
#     trailing zero will be removed.
#
#     - A missing TRACKTOTAL tag.
#     In case of autocorrection enabled, TRACKTOTAL is filled automatically.
#
#     - TOTALTRACKS tag instead of TRACKTOTAL.
#     This is simply not standard compliant. Track count should be stored in
#     TRACKTOTAL. If autocorrection is enabled, TOTALTRACKS are renamed to
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
    my $has_tracktotal_conflict = 0;
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

        _debug sprintf("%s/%s:\n%s",
                       rcwd, $file, join("\n",
                                         map({ sprintf("%s = %s",
                                                       $_, $tagset->{$_}) }
                                             sort keys %$tagset)));

        # @significant_tags should be a superset of @required_tags
        my @required_tags = ("TITLE", "ARTIST", "ALBUM", "DATE", "GENRE",
                             "TRACKNUMBER");
        my @significant_tags = ("TITLE", "ARTIST", "ALBUM", "DATE", "GENRE",
                                "TRACKNUMBER", "TRACKTOTAL", "DISCNUMBER",
                                "COMPOSER");

        # Try to guess the value of the DATE tag if --guess-year is active.
        if (!grep(/date/i, keys %$tagset) && $opt_guess_year
            && ((my $year) = (basename(rcwd) =~ /^CD/ ?
                              basename(dirname(rcwd)) : basename(rcwd))
                =~ /^(\d{4})\D/)) {
            if ($opt_no_fix_tags) {
                _warn sprintf("    MISSING_DATE_RECOVERABLE (guessed value: %s)   in %s/%s\n",
                              $year, rcwd, $file);
                $has_recoverable_date_tag = 1;
            } else {
                _warn sprintf("    FIX_DATE_RECOVERABLE (new value: %s)   in %s/%s\n",
                              $year, rcwd, $file);
                $tagset->{"DATE"} = $year;
                set_vorbis_tag($file, "DATE", $year);
            }
        }

        # Check the presence of TOTALTRACKS tag.
        if (((my $tag) = grep(/totaltracks/i, keys %$tagset))
            && !grep(/tracktotal/i, keys %$tagset)) {
            if ($opt_no_fix_tags) {
                _warn sprintf("    HAS_TOTALTRACKS_INSTEAD_OF_TRACKTOTAL    in %s/%s\n",
                              rcwd, $file);
                $has_totaltracks_instead_of_tracktotal = 1;
            } else {
                _warn sprintf("    FIXED_TOTALTRACKS_INSTEAD_OF_TRACKTOTAL  in %s/%s\n",
                              rcwd, $file);
                set_vorbis_tag($file, "TRACKTOTAL", $tagset->{$tag});
                $tagset->{"TRACKTOTAL"} = $tagset->{$tag};
                delete_vorbis_tag($file, $tag);
                delete $tagset->{$tag};
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
                            || ((lc($tag) eq "date") and $has_recoverable_date_tag)) {
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
                        _warn sprintf("    FIX_NON_UPPERCASE_TAG      %s=\"%s\" in %s/%s\n",
                                      $key, $tagset->{$key}, rcwd, $file);
                        my $value = $tagset->{$key};
                        delete_vorbis_tag($file, $key);
                        delete $tagset->{$key};
                        set_vorbis_tag($file, uc($key), $value);
                        $tagset->{uc($key)} = $value;
                    }
                } elsif ((lc($key) ne "totaltracks")
                         and (lc($key) ne "tracktotal")) {
                    if ($opt_no_fix_tags) {
                        _warn sprintf("    UNNEEDED_TAG               %s=\"%s\" in %s/%s\n",
                                      $key, $tagset->{$key}, rcwd, $file);
                        $has_unneeded_tag = 1;
                    } else {
                        _warn sprintf("    FIX_UNNEEDED_TAG           %s=\"%s\" in %s/%s\n",
                                      $key, $tagset->{$key}, rcwd, $file);
                        delete_vorbis_tag($file, $key);
                        delete $tagset->{$key};
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
                _warn sprintf("    FIX_BAD_TRACKNUMBER_FORMAT %s in %s/%s\n",
                              $tagset->{"TRACKNUMBER"}, rcwd, $file);
                $tagset->{"TRACKNUMBER"} =~ s/^0//;
                delete_vorbis_tag($file, "TRACKNUMBER");
                set_vorbis_tag($file, "TRACKNUMBER", $tagset->{"TRACKNUMBER"});
            }
        }

        # Check every $tagset for mismatching tags, except for the first tagset.
        if (@tagsets) {
            map( { my $value0 = (exists($tagsets[0]->{$_}) ? $tagsets[0]->{$_}
                                 : "");
                   my $value = (exists($tagset->{$_}) ? $tagset->{$_}
                                : "");

                   unless ($value0 eq $value) {
                       _error sprintf("    TAG_MISMATCH_%-7s    (\"%s\" vs \"%s\") in %s/%s\n",
                                      $_, $value, $value0, rcwd, $file);
                       $has_tag_mismatch = 1;
                   }
                 }
                 ("ARTIST", "ALBUM", "DATE", "TRACKTOTAL", "GENRE",
                  "DISCNUMBER" ));
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
            next;
        }

        push(@tagsets, $tagset);
    }

    return 0 if $has_critical_error or $has_shallow_error;

    # Check if there are missing tracks.
    my $expected_tracktotal = @tagsets;

    # Check all tagsets for a wrong TRACKTOTAL value.
    foreach my $file (@{$files}) {
        my $tagset = fetch_vorbis_tags_file($file);

        if (!$tagset->{"TRACKTOTAL"}) {
            if ($opt_no_fix_tags) {
                _warn sprintf("    NO_TRACKTOTAL              (expected %d) in %s/%s\n",
                              $expected_tracktotal, rcwd, $file);
                $has_bad_tracktotal = 1;
            } else {
                _warn sprintf("    FIX_NO_TRACKTOTAL          (new value: %d) in %s/%s\n",
                              $expected_tracktotal, rcwd, $file);
                set_vorbis_tag($file, "TRACKTOTAL", $expected_tracktotal);
                $tagset->{"TRACKTOTAL"} = $expected_tracktotal;
            }
        } elsif ($tagset->{"TRACKTOTAL"} ne $expected_tracktotal) {
            my $normalized_tracktotal = strtol($tagset->{"TRACKTOTAL"}, 10);

            if ($normalized_tracktotal == $expected_tracktotal) {
                # TRACKTOTAL string-to-int cast yields a correct result.
                # Thus, TRACKTOTAL value is ok, just the markup is wrong
                # (eg leading 0). This can be fixed automatically.
                if ($opt_no_fix_tags) {
                    _warn sprintf("    BAD_TRACKTOTAL             %s (expected %d) in %s/%s\n",
                                  $tagset->{"TRACKTOTAL"}, $expected_tracktotal, rcwd, $file);
                    $has_bad_tracktotal = 1;
                } else {
                    _warn sprintf("    FIX_BAD_TRACKTOTAL         %s -> %d in %s/%s\n",
                                  $tagset->{"TRACKTOTAL"}, $expected_tracktotal, rcwd, $file);
                    set_vorbis_tag($file, "TRACKTOTAL", $expected_tracktotal);
                    $tagset->{"TRACKTOTAL"} = $expected_tracktotal;
                }
            } else {
                # Logical conflict.
                _error sprintf(   "CONFLICT_TRACKTOTAL        %s (expected %d) in %s/%s\n",
                               $tagset->{"TRACKTOTAL"}, $expected_tracktotal, rcwd, $file);
                $has_tracktotal_conflict = 1;
            }
        }
    }

    $has_critical_error &= $has_missing_track;
    $has_critical_error &= $has_tracktotal_conflict;
    $has_shallow_error &= $has_bad_tracktotal;

    return 0 if $has_critical_error or $has_shallow_error;

    return \@tagsets;
}



# Actually process a fileset, fixing the tags and sending the files to
# the output directory.
sub fix_tags_and_relocate_fileset {
    my $files = shift;
    my $scans_dir = shift;
    my $logs_dir = shift;
    my (@mp3, @cue, @flac, @ape, @logs, @scans);

    my %classifier = ( "mp3"  => \@mp3,
                       "cue"  => \@cue,
                       "flac" => \@flac,
                       "ape"  => \@ape,
                       "log"  => \@logs,
                       "txt"  => \@logs,
                       "jpg"  => \@scans,
                       "bmp"  => \@scans,
                       "png"  => \@scans,
                       "tif"  => \@scans);


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
        _error sprintf("MP3             %s\n", rcwd);
        return 1;
    } elsif (!@mp3 && @flac==1 && @cue==1 && !@ape) {
        _error sprintf("FLAC+CUE        %s\n", rcwd);
        return 1;
    } elsif (!@mp3 && @ape==1 && @cue==1 && !@flac) {
        _error sprintf("APE+CUE         %s\n", rcwd);
        return 1;
    } elsif (!@mp3 && (@flac>1) && !@ape) {
        _debug("FLAC            %s\n", rcwd);

        my $vorbis_tags = fetch_vorbis_tags_fileset(\@flac);

        if ($vorbis_tags && !$opt_no_output_to_destdir) {
            my $tagset = @$vorbis_tags[0];
            my $srcdir = sprintf("%s/%s", $ARGV[0], rcwd);
            my $destdir = sprintf("%s/%s/%s - %s", $ARGV[1],
                                  $tagset->{"ARTIST"},
                                  $tagset->{"DATE"},
                                  $tagset->{"ALBUM"});

            if (exists($tagset->{"DISCNUMBER"})) {
                $destdir = sprintf("%s/CD%s", $destdir,
                                   $tagset->{"DISCNUMBER"});
            }

            my $scans_destdir = sprintf("%s/scans", $destdir);
            my $logs_destdir = sprintf("%s/logs", $destdir);

            make_path($destdir) if !-d $destdir;

            # move audio files
            foreach my $flac_file (@flac) {
                my $tagset = fetch_vorbis_tags_file($flac_file);

                # replace nonprintable chars
                foreach my $tag ("ARTIST", "ALBUM", "TITLE") {
                    $tagset->{$tag} =~ s/[\/\\]/_/g;
                }

                my $src = sprintf("%s/%s", $srcdir, $flac_file);
                my $dest = sprintf("%s/%02s - %s.flac",
                                   $destdir,
                                   $tagset->{"TRACKNUMBER"},
                                   $tagset->{"TITLE"});

                if ($opt_remove_source) {
                    move($src, $dest) or die sprintf("move failed: %s -> %s",
                                                     $src, $dest);
                } else {
                    copy($src, $dest) or die sprintf("copy failed: %s -> %s",
                                                     $src, $dest);
                }
            }

            # move scans
            if ($scans_dir) {
                my $src = sprintf("%s/%s", $srcdir, $scans_dir);
                my $dest = $scans_destdir;

                if ($opt_remove_source) {
                    move($src, $dest)
                        or die sprintf("move failed: %s -> %s",
                                       $src, $dest);
                } else {
                    copy($src, $dest)
                        or die sprintf("copy failed: %s -> %s",
                                       $src, $dest);
                }
            }

            if (@scans) {
                make_path($scans_destdir) if !-d $scans_destdir;

                foreach my $scans_file (@scans) {
                    my $src = sprintf("%s/%s", $srcdir, $scans_file);
                    my $dest = sprintf("%s/%s", $scans_destdir, $scans_file);

                    if ($opt_remove_source) {
                        move($src, $dest)
                            or die sprintf("move failed: %s -> %s",
                                           $src, $dest);
                    } else {
                        copy($src, $dest)
                            or die sprintf("copy failed: %s -> %s",
                                           $src, $dest);
                    }
                }
            }

            # move logs
            if ($logs_dir) {
                my $src = sprintf("%s/%s", $srcdir, $logs_dir);
                my $dest = $logs_destdir;

                if ($opt_remove_source) {
                    move($src, $dest)
                        or die sprintf("move failed: %s -> %s",
                                       $src, $dest);
                } else {
                    copy($src, $dest)
                        or die sprintf("copy failed: %s -> %s",
                                       $src, $dest);
                }
            }

            if (@logs) {
                make_path($logs_destdir) if !-d $logs_destdir;

                foreach my $log_file (@logs) {
                    my $src = sprintf("%s/%s", $srcdir, $log_file);
                    my $dest = sprintf("%s/%s", $logs_destdir, $log_file);

                    if ($opt_remove_source) {
                        move($src, $dest)
                            or die sprintf("move failed: %s -> %s",
                                           $src, $dest);
                    } else {
                        copy($src, $dest)
                            or die sprintf("copy failed: %s -> %s",
                                           $src, $dest);
                    }
                }
            }
        }

        return 1;
    } else {
        _error sprintf("FAILDETECT      %s\n", rcwd);
        return 1;
    }
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



# Check if a directory is a logs directory.
sub fetch_logs {
    my ($files, $dirs) = @_;

    return 0 if @$dirs || !@$files;

    foreach (@$files) {
        return 0 unless /\.txt$/i || /\.log$/i;
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
    my $scans_dir = "";
    my $logs_dir = "";

    # find and filter out the scans directory
    foreach my $i (0..@$dirs-1) {
        if (apply_fn_to_dir(\&fetch_scans, ${$dirs}[$i])) {
            $scans_dir = ${$dirs}[$i];
            splice(@$dirs, $i, 1);
            last;
        }
    }

    # find and filter out the logs directory
    foreach my $i (0..@$dirs-1) {
        if (apply_fn_to_dir(\&fetch_logs, ${$dirs}[$i])) {
            $logs_dir = ${$dirs}[$i];
            splice(@$dirs, $i, 1);
            last;
        }
    }

    # if (@$files and @$dirs) {
    #     _error sprintf("MIXED_CONTENTS  %s\n", rcwd);
    #     return 0;
    # }

    if (@$dirs) {
        map({ apply_fn_to_dir(\&fetch_albums, $_) } @$dirs);
        return 0;
    }

    return 0 if !@$files;

    return fix_tags_and_relocate_fileset($files, $scans_dir, $logs_dir);
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

    @files = sort(@files);
    @dirs = sort(@dirs);

    return &$fn(\@files, \@dirs);
}



# OK, here we start.

GetOptions('help'                 => \$opt_help,
           'verbose'              => \$opt_verbose,
           'remove-source'        => \$opt_remove_source,
           'no-fix-tags'          => \$opt_no_fix_tags,
           'no-output-to-destdir' => \$opt_no_output_to_destdir,
           'guess-year'           => \$opt_guess_year)
    or die "Wrong command line options specified";

if (defined $opt_no_fix_tags) {
    $opt_no_output_to_destdir = 1;
}

if ((defined $opt_no_output_to_destdir) && ($#ARGV != 0)
    || (!defined $opt_no_output_to_destdir) && ($#ARGV != 1)) {
    print "\nWrong number of arguments.\n";
    help;
    exit;
}

if (defined $opt_help) {
    help;
    exit;
}

apply_fn_to_dir \&fetch_albums, $ARGV[0];

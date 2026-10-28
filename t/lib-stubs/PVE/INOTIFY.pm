package PVE::INOTIFY;
use strict;
use warnings;
sub nodename { my $h; chomp($h ||= `hostname`); return $h || 'localhost' }
sub file_read_contents { die "stub INOTIFY\n" }
1;

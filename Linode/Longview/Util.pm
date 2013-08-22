package Linode::Longview::Util;
use 5.010;

=head1 COPYRIGHT/LICENSE

Copyright 2013 Linode, LLC.  Longview is made available under the terms
of the Perl Artistic License, or GPLv2 at the recipients discretion.

=head2 Perl Artistic License

Read it at L<http://dev.perl.org/licenses/artistic.html>.

=head2 GNU General Public License (GPL) Version 2

  This program is free software; you can redistribute it and/or
  modify it under the terms of the GNU General Public License
  as published by the Free Software Foundation; either version 2
  of the License, or (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see http://www.gnu.org/licenses/

See the full license at L<http://www.gnu.org/licenses/>.

=cut

use strict;
use warnings;

use Exporter 'import';
our @EXPORT = qw($logger);
our %EXPORT_TAGS = (
	DRIVER  => [qw(constant_push flatten_data slurp_file daemonize_self check_already_running $SLEEP_TIME enable_debug_logging $VERSION post $logger $apikey)],
	BASIC   => [qw(slurp_file $PROCFS $logger)],
	SYSINFO => [qw(slurp_file detect_system $VERSION $PROCFS $ARCH $logger)],
);
our @EXPORT_OK
	= qw(slurp_file detect_system constant_push flatten_data
		 daemonize_self check_already_running enable_debug_logging post ge_UA
		 $PROCFS $ARCH $SLEEP_TIME $TICKS $VERSION $apikey);

use Linode::Longview::Logger;

use File::Path 'make_path';

use Carp;
use POSIX;
use JSON;

use feature 'state';

our $logger = get_logger();

our $gua;
our $post_target   = 'https://longview.linode.com/post';

our $VERSION = '0.2.5';
our $TICKS   = POSIX::sysconf(&POSIX::_SC_CLK_TCK);
our $PROCFS  = find_procfs()      or $logger->logdie("Couldn't find procfs: $!");
our $ARCH    = get_architecture() or $logger->info("Couldn't determine architecture: $!");
our $SLEEP_TIME = 60;

our $apikey;

my $pid_file    = '/var/run/longview.pid';
my $slots = 10;

sub get_UA {
	return $gua if defined $gua;
	$gua = LWP::UserAgent->new(
		timeout => 10,
		agent   => "Linode Longview 1.0 client: $apikey",
		ssl_opts => {MultiHomed => 1, Timeout => 3}
	);
	return $gua;
}

sub post {
	my $payload = shift;
	my $ua = get_UA();
	my $req = $ua->post(
		$post_target,
		Content_Type => 'form-data',
		Content => [
			'data' => [
				undef,
				'json.gz',
				'Content-Type'     => 'application/json',
				'Content-Encoding' => 'gzip',
				'Content'          => Compress::Zlib::memGzip(encode_json($payload))
			]
		]
	);
	return $req;
}

sub get_logger {
	return $logger if defined $logger;
	$logger = Linode::Longview::Logger->new($levels->{info});
	return $logger;
}

sub enable_debug_logging {
	$logger->level($levels->{trace});
}

# For an arbitrarily sized cache ($slots long), we want to remove an element to keep the
# average gap between any two elements as small as possible. Turns out that the right
# sequence to remove elements is a repeating sequence of runs of 1 .. $slots - 2, with
# ($slots -1) x ((2**runNumber) - 1) interleaved before each element of the run.
#
# The first push below handles the inserting ($slots -1) x ((2**runNumber) - 1), while
# the second adds current element of the run. The loop is a while rather than a for,
# as the length of the list becomes MUCH longer than the iteration currently being
# calculated, after just a few runs (~2), so it's easier to measure the length of
# the sequence directly than try to approximate it from the iteration number
sub remove_sequence {
	my $iteration = shift;
	my $current = 0;
	my @sequence;
	while (scalar(@sequence) < $iteration) {
		# We never want to remove element 0, so candidates for removal are 1 through $slots - 1
		# $slots - 1 will be inserted before the beginning of each element starting in the second run,
		# so each run should cover the range 1 to $slots - 2. You can calculate which run you're on
		# by doing the integer division of $current by the top element of a run (ie $slots -2).
		push @sequence, $slots-1 for(1..(2**int($current/($slots-2)))-1);
		push @sequence,($current%($slots-2))+1;
		$current++;
	}
	@sequence = @sequence[0 .. $iteration-1];
	return @sequence if (wantarray);
	return $sequence[-1];
}

# A nice wrapper to memoize and hide the complexities of removeSequence when pushing on to a fixed sized cache
sub constant_push {
	my ($ar,$val) = @_;
	$logger->debug('Array Ref is undefined') unless (defined($ar));
	state %iteration;
	my $addr = substr $ar,6,9;
	$iteration{$addr} = 0 if(scalar(@$ar)==0);
	push @$ar,$val;
	# Remove sequence expects to start at 1, while the first removal doesn't need to happen until $slots
	# so we subtract ($slots -1) to keep the numbers lined up with what each side expects
	splice(@$ar,remove_sequence($iteration{$addr}-($slots-1)),1) if (scalar(@$ar) > $slots);
	$iteration{$addr}++;
}

sub slurp_file {
	my $path = shift;
	open( my $fh, '<', $path ) or return;
	return <$fh> if wantarray;
	chomp(my $data = join( '', <$fh> ));
	return $data;
}

sub detect_system {
	my @cpu = slurp_file( $PROCFS . 'cpuinfo' );

	if ( -f $PROCFS . 'user_beancounters' ) {
		return 'openvz';
	}
	elsif (
		(   slurp_file(
				'/sys/devices/system/clocksource/clocksource0/current_clocksource'
			) eq 'kvm-clock'
		)
		|| (   ( grep {/QEMU Virtual CPU/} @cpu )
			&& ( grep {/hypervisor/} @cpu ) ) )
	{
		return 'kvm';
	}
	elsif ( -e '/dev/vzfs' ) {
		return 'virtuozzo';
	}
	elsif ( -d '/sys/bus/xen' ) {
		return 'xen';
	}
	return 'baremetal';
}

sub flatten_data {
	my ($mlhr,$name) = @_;
	my $ret = {};
	for my $sk (keys %{$mlhr}) {
		if ((ref $mlhr->{$sk}) eq 'HASH'){
			my $children = flatten_data($mlhr->{$sk}, $sk);
			for my $child (keys %{$children}) {
				my $k = $name ? $name . "." . $child : $child;
				$ret->{$k} = $children->{$child};
			}
		}
		else {
			my $k = $name ? $name . "." . $sk : $sk;
			$ret->{$k} = $mlhr->{$sk};
		}
	}
	return $ret;
}

sub get_architecture {
	return ( ( POSIX::uname() )[4] );
}

sub find_procfs {
	return "/proc/" if -d "/proc/$$";
	my @mtab = grep {/\bproc\b/} ( slurp_file('/etc/mtab') )
		or do{
			$logger->info("Couldn't check /etc/mtab: $!");
			return undef;
		};
	return ( split( /\s+/, $mtab[0] ) )[1] . '/';
}

sub daemonize_self {
 	#<<<   perltidy ignore
 	chdir '/'                      or $logger->logdie("Can't chdir to /: $!");
 	open STDIN, '<', '/dev/null'   or $logger->logdie("Can't read /dev/null: $!");
 	open STDOUT, '>>', '/dev/null' or $logger->logdie("Can't write to /dev/null: $!");
 	open STDERR, '>>', '/dev/null' or $logger->logdie("Can't write to /dev/null: $!");
 	defined( my $pid = fork )      or $logger->logdie("Can't fork: $!");
 	exit if $pid;
 	setsid or $logger->logdie("Can't start a new session: $!");
 	umask 022;
 	system "echo $$ > $pid_file";
 	#>>>
}

sub check_already_running {
	return 0 unless (-e $pid_file);
	my $pid = slurp_file($pid_file);
	return 0 unless -e $PROCFS . "$pid/cmdline";
	my $name = slurp_file($PROCFS . "$pid/cmdline");
	return $pid if $name =~ /longview/i;
	return 0;
}

1;

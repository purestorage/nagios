#!/usr/bin/perl
my $Version='0.2';

use Data::Dumper;
use REST::Client;
use JSON;
use Net::SSL;
use strict;
use Getopt::Long;

### Config

my $cookie_file = "/tmp/cookies.txt";

my $max_system_percent = 10;
my $array_warn_percent = 85;
my $array_crit_percent = 90;

our %ENV;
$ENV{PERL_LWP_SSL_VERIFY_HOSTNAME} = 0;

### Nagios exit codes

my %ERRORS=('OK'=>0,'WARNING'=>1,'CRITICAL'=>2,'UNKNOWN'=>3,'DEPENDENT'=>4);

### Parse command line
my $help = undef;
my $host = undef;
my $token = undef;
my $checktype = "space";
my @valid_types = ("space", "performance");
my $vol_warn_percent = undef;
my $vol_crit_percent = undef;
my $perf = undef;
my $debug = undef;

my @critical;
my @warning;
my @info;
my @perfdata;
my $perfoutput = "";

sub print_usage {
	print "Usage: $0 -H <host> -T <api-token> -w <warning level> -c <critical level> [-f] [-d]\n";
}

sub help {
	print "\nA full REST API is available for automation and monitoring Pure Storage arrays, version $Version\n";
	print "Artistic License 2.0\n\n";
	print_usage();
	print <<EOT;
	-H, --hostname=HOST
		Name or IP address of array to check
	-T, --token=UUID
		API token (pureadmin create --api-token)
	-w, --warning=INTEGER
		Array/volume warning percent
	-c, --critical=INTEGER
		Array/volume critical percent
	-f, --perfdata
		Performance data output
	-d, --debug
		Print extra debugging information 
EOT
}

sub check_options {
	Getopt::Long::Configure ("bundling");
	GetOptions(
		'd'     => \$debug,            'debug'         => \$debug,
		'h'     => \$help,             'help'          => \$help,
		'H:s'   => \$host,             'hostname:s'    => \$host,
		'T:s'   => \$token,            'token:s'       => \$token,
		'w:s'   => \$vol_warn_percent, 'warning:s'     => \$vol_warn_percent,
		'c:s'   => \$vol_crit_percent, 'critical:s'    => \$vol_crit_percent,
		'f'     => \$perf,             'perfdata'      => \$perf
	);
	if (defined ($help) ) { help(); exit $ERRORS{"UNKNOWN"}};

	if ( ! defined($host) ) # check host and filter 
		{ print_usage(); exit $ERRORS{"UNKNOWN"}}

	if ( ! defined($token) ) # check API token
		{ print_usage(); exit $ERRORS{"UNKNOWN"}}

	if (!defined($vol_warn_percent) || !defined($vol_crit_percent))
		{ print "put warning and critical info!\n"; print_usage(); exit $ERRORS{"UNKNOWN"}}

	if ($vol_warn_percent > $vol_crit_percent) 
		{ print "warning <= critical ! \n";print_usage(); exit $ERRORS{"UNKNOWN"}}
}

### Bootstrap

check_options();

### Start RESTing

my $client = REST::Client->new( follow => 1 );
$client->setHost('https://'.$host);

$client->addHeader('Content-Type', 'application/json');

$client->getUseragent()->cookie_jar({ file => $cookie_file });
$client->getUseragent()->ssl_opts(verify_hostname => 0);

### Check for API 1.4 support

my $ref = &api_get('/api/api_version');

my %api_versions;
for my $version (@{$ref->{version}}) {
  $api_versions{$version}++;
}

my $api_version = $api_versions{'1.4'} ? '1.4' :
                  $api_versions{'1.3'} ? '1.3' :
                  $api_versions{'1.1'} ? '1.1' :
                  $api_versions{'1.0'} ? '1.0' :
                  undef;

unless ( $api_version ) {
  print "API version 1.3 or 1.4 is not supported by host: $host\n";
  exit $ERRORS{"UNKNOWN"}
}

### Set the Session Cookie

my $ret = &api_post("/api/$api_version/auth/session", { api_token => $token });

### Check the Array overall

my $array_info = &api_get("/api/$api_version/array?space=true");

for my $param (qw/system capacity total data_reduction total_reduction/) {
  next if defined $array_info->{$param};
  print "Array data lacks parameter: $param";
  exit $ERRORS{"UNKNOWN"}
}

if ( (100 * $array_info->{system} / $array_info->{capacity}) >= $max_system_percent ) {
   my $percent = sprintf('%0.2f%%', (100 * $array_info->{system} / $array_info->{capacity}));
   my $usage = human_readable_bytes($array_info->{system});
   push @warning, "System space in use: $usage / $percent";
}

my $array_percent_used = sprintf('%0.2f', (100 * $array_info->{total} / $array_info->{capacity}));
my $array_data_reduction = sprintf('%0.2f', $array_info->{data_reduction});
my $array_total_reduction = sprintf('%0.2f', $array_info->{total_reduction});
my $message = "Array @ $array_percent_used\% (Data reduction is $array_data_reduction, Total reduction is $array_total_reduction)";
my $perfmessage = 'Array=' . $array_info->{total} . 'B;' . $array_info->{capacity}*$array_warn_percent/100 . ';' . $array_info->{capacity}*$array_crit_percent/100 . ';0;' . $array_info->{capacity} . ' Array_total_reduction=' . $array_total_reduction . ';;;0; Array_data_reduction=' . $array_data_reduction . ';;;0;' if ($perf);

if ( $array_percent_used > $array_crit_percent ) {
  push @critical, $message;
} elsif ( $array_percent_used > $array_warn_percent ) {
  push @warning, $message;
} else {
  push @info, $message;
}
push @perfdata, $perfmessage if ($perf);

### Check the volumes

my $vol_info = &api_get("/api/$api_version/volume?space=true");

for my $vol (@$vol_info) {
  for my $param (qw/total size name/) {
    next if defined $vol->{$param};
    print "Volume data lacks parameter: $param";
    exit $ERRORS{"UNKNOWN"}
  }
}

for my $vol ( sort { ($b->{total}/$b->{size}) <=> ($a->{total}/$a->{size}) } @$vol_info) {
  my $vol_percent_used = sprintf('%0.2f', (100 * $vol->{total} / $vol->{size}));
  my $message = "$vol->{name} $vol_percent_used\%";
  my $perfmessage = $vol->{name} . '=' . $vol->{total} . 'B;' . $vol->{size}*$array_warn_percent/100 . ';' . $vol->{size}*$array_crit_percent/100 . ';0;' . $vol->{size} if ($perf);

  if ( $vol_percent_used > $vol_crit_percent ) {
    push @critical, $message;
  } elsif ( $vol_percent_used > $vol_warn_percent ) {
    push @warning, $message;
  } else {
    push @info, $message;
  }
  push @perfdata, $perfmessage if ($perf);
}

# Kill the session

$ret = $client->DELETE("/api/$api_version/auth/session");
unlink($cookie_file);

$perfoutput = '|' . join(' ', @perfdata) if ($perf);

if ( scalar(@critical) > 0 ) {
  print 'CRITICAL - API ' . $api_version . ': ' . (shift @info) . ' ' . join(' ', map { '[ '.$_.' ]' } (@critical,@warning)) . $perfoutput;
  exit $ERRORS{"CRITICAL"};
} elsif ( scalar(@warning) > 0 ) {
  print 'WARNING - API ' . $api_version . ': ' . (shift @info) . ' ' . join(' ', map { '[ '.$_.' ]' } @warning). $perfoutput;
  exit $ERRORS{"WARNING"};
} else {
  print 'OK - API ' . $api_version . ': ' . (shift @info) . ' ' . join(' ', map { '[ '.$_.' ]' } @info) . $perfoutput;
  exit $ERRORS{"OK"};
}

### Subs

sub api_get {
  my $url = shift @_;
  my $ret = $client->GET($url);
  my $num = $ret->responseCode();
  my $con = $ret->responseContent();
  if ( $num == 500 ) {
    print "API returned error 500 for '$url' - $con\n";
    exit $ERRORS{"UNKNOWN"}
  }
  if ( $num != 200 ) {
    print "API returned code $num for URL '$url'\n";
    exit $ERRORS{"UNKNOWN"}
  }
  print 'DEBUG: GET ', $url, ' -> ', $num, ":\n", Dumper(from_json($con)), "\n" if $debug;
  return from_json($con);
}

sub api_post {
  my $url = shift @_;
  my $con = shift @_;
  my $ret = $client->POST($url, to_json($con));
  my $num = $ret->responseCode();
  my $con = $ret->responseContent();
  if ( $num == 500 ) {
    print "API returned error 500 for '$url' - $con\n";
    exit $ERRORS{"UNKNOWN"}
  }
  if ( $num != 200 ) {
    print "API returned code $num for URL '$url'\n";
    exit $ERRORS{"UNKNOWN"}
  }
  print 'DEBUG: POST ', $url, ' -> ', $num, ":\n", Dumper(from_json($con)), "\n" if $debug;
  return from_json($con);
}

sub human_readable_bytes {
  my $raw = shift @_;
  if ( $raw > 500_000_000_000 ) {
    return sprintf('%.2f TB', ($raw/1_000_000_000_000));
  } elsif ( $raw > 500_000_000 ) {
    return sprintf('%.2f GB', ($raw/1_000_000_000));
  } else {
    return sprintf('%.2f MB', ($raw/1_000_000));
  }
}

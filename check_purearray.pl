#!/usr/bin/perl

use Data::Dumper;
use REST::Client;
use JSON;
use Net::SSL;
use strict;

### Config

my $cookie_file = "/tmp/cookies.txt";

# pureadmin create --api-token
my %api_tokens = (
  'my-pure-array1.company.com' => 'XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX',
  'my-pure-array2.company.com' => 'XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX',
);

my $max_system_percent = 1;
my $array_warn_percent = 85;
my $array_crit_percent = 90;
my $vol_warn_percent = 85;
my $vol_crit_percent = 90;

our %ENV;
$ENV{PERL_LWP_SSL_VERIFY_HOSTNAME} = 0;

### Nagios exit codes

my $OKAY     = 0;
my $WARNING  = 1;
my $CRITICAL = 2;
my $UNKNOWN  = 3;

### Parse command line

my $debug = 0;
my $host;

for my $arg (@ARGV) {
  if ( $arg =~ /--debug/i ) {
    $debug++;
  } else {
    $host = $arg;
  }
}

### Bootstrap

unless ( $host ) {
  print "No hostname given to check\n";
  exit $UNKNOWN
}

my $token = $api_tokens{$host};

unless ( $token ) {
  print "No API token for host $host\n";
  exit $UNKNOWN
}

my @critical;
my @warning;
my @info;

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
  exit $UNKNOWN
}

### Set the Session Cookie

my $ret = &api_post("/api/$api_version/auth/session", { api_token => $token });

### Check the Array overall

my $array_info = &api_get("/api/$api_version/array?space=true");

for my $param (qw/system capacity total/) {
  next if defined $array_info->{$param};
  print "Array data lacks parameter: $param";
  exit $UNKNOWN
}

if ( ($array_info->{system}/$array_info->{capacity}) >= $max_system_percent ) {
   push @critical, "System space is in use: [$ret->{system}]";
}

my $array_percent_used = sprintf('%0.2f', (100 * $array_info->{total} / $array_info->{capacity}));
my $message = "Array @ $array_percent_used\%";

if ( $array_percent_used > $array_crit_percent ) {
  push @critical, $message;
} elsif ( $array_percent_used > $array_warn_percent ) {
  push @warning, $message;
} else {
  push @info, $message;
}

### Check the volumes

my $vol_info = &api_get("/api/$api_version/volume?space=true");

for my $vol (@$vol_info) {
  for my $param (qw/total size name/) {
    next if defined $vol->{$param};
    print "Volume data lacks parameter: $param";
    exit $UNKNOWN
  }
}

for my $vol ( sort { ($b->{total}/$b->{size}) <=> ($a->{total}/$a->{size}) } @$vol_info) {

  my $vol_percent_used = sprintf('%0.2f', (100 * $vol->{total} / $vol->{size}));
  my $message = "$vol->{name} $vol_percent_used\%";

  if ( $vol_percent_used > $vol_crit_percent ) {
    push @critical, $message;
  } elsif ( $vol_percent_used > $vol_warn_percent ) {
    push @warning, $message;
  } else {
    push @info, $message;
  }
}

# Kill the session

$ret = $client->DELETE("/api/$api_version/auth/session");
unlink($cookie_file);

if ( scalar(@critical) > 0 ) {
  print join(' ', map { '[ '.$_.' ]' } (@critical,@warning));
  exit $CRITICAL;
} elsif ( scalar(@warning) > 0 ) {
  print join(' ', map { '[ '.$_.' ]' } @warning);
  exit $WARNING;
} else {
  print $api_version . ': '.(shift @info).' '.join(' ', map { '[ '.$_.' ]' } @info);
  exit $OKAY;
}

### Subs

sub api_get {
  my $url = shift @_;
  my $ret = $client->GET($url);
  my $num = $ret->responseCode();
  my $con = $ret->responseContent();
  if ( $num == 500 ) {
    print "API returned error 500 for '$url' - $con\n";
    exit $UNKNOWN
  }
  if ( $num != 200 ) {
    print "API returned code $num for URL '$url'\n";
    exit $UNKNOWN
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
    exit $UNKNOWN
  }
  if ( $num != 200 ) {
    print "API returned code $num for URL '$url'\n";
    exit $UNKNOWN
  }
  print 'DEBUG: POST ', $url, ' -> ', $num, ":\n", Dumper(from_json($con)), "\n" if $debug;
  return from_json($con);
}

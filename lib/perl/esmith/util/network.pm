#----------------------------------------------------------------------
# Copyright 1999-2003 Mitel Networks Corporation
# This program is free software; you can redistribute it and/or
# modify it under the same terms as Perl itself.
#----------------------------------------------------------------------

package esmith::util::network;

use strict;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(isValidIP cleanIP isValidPort cmpIP);
our %EXPORT_TAGS = (
    all => [qw(isValidIP cleanIP isValidPort cmpIP)]
);

use Net::IPv4Addr qw(:all);
use Mail::RFC822::Address;

use constant TRUE  => 1;
use constant FALSE => 0;

=for testing
use_ok('esmith::util::network');


=head1 NAME

esmith::util::network - miscellaneous network utilities

=head1 SYNOPSIS

use esmith::util::network qw(the functions you want);

my $ip       = cleanIP($orig_ip);
my $is_valid = isValidIP($ip);
my $is_valid = isValidPort($port);

=head1 DESCRIPTION

This is a collection of generally useful functions for working with IP
addresses.

Functions are exported only on request.

=head2 Functions

=over 4

=item I<cleanIP>

my $ip = cleanIP($orig_ip);

If the $orig_ip is valid it will be cleaned up into a cannonical form,
stripping any padding zeros and such.

=begin testing

use esmith::util::network qw(cleanIP);

my %ips = (
    '000.000.000.000'      => '0.0.0.0',
    '0.0.0.0'              => '0.0.0.0',
    '001.2.003.4'          => '1.2.3.4',
    '100.2.3.4'            => '100.2.3.4',
    '10.13.14.015'         => '10.13.14.15',
    '10.33.15.109'         => '10.33.15.109',
    '1.2.3.4.5'            => ''
);

while( my($ip, $cleanip) = each %ips ) {
    is( cleanIP($ip), $cleanip,  "cleanIP($ip)" );
}

=end testing

=cut

sub cleanIP {
    my $ip = shift;

    return '' unless isValidIP($ip);
    $ip =~ s/\b0+(\d+)/$1/g;

    return isValidIP($ip) ? $ip : '';
}

=item I<isValidIP>

my $is_valid = isValidIP($ip);

Returns the IP given if $ip is a properly formatted IP address, undef otherwise.

=begin testing

use esmith::util::network qw(isValidIP);

my @goodIPs = qw(1.2.3.4
0.0.0.0
255.255.255.255
001.002.003.004
1.32.123.213
192.168.0.3
02.19.090.19
                );
                foreach my $ip (@goodIPs) {
                    ok( isValidIP($ip), "valid $ip");
                }

                my @badIPs = qw(256.3.2.4
                -1.39.9.23
                0
                1
                255.255.255.255.0
                239..19.23.12
                1.2.3.4.
                foo.bar.com
            );

            foreach my $ip (@badIPs) {
                ok( !isValidIP($ip), "invalid $ip");
            }


=end testing

=cut

sub isValidIP($)
{
    my ($string) = @_;
    return unless defined ipv4_chkip($string);
    return $string eq ipv4_chkip($string);
}

=item I<isValidPort>

my $is_valid = isValidPort($port);

Returns true if $port is a properly formatted port, false otherwise.

=begin testing

@badports = (98765434, -183, 0, 'bad port', 'a');
@goodports = (67, 23, 1, 54736);

foreach $port (@badports) {
    isnt(esmith::util::network::isValidPort($port), 1);
}
foreach $port (@goodports) {
    is(esmith::util::network::isValidPort($port), 1);
}

=end testing

=cut

sub isValidPort($)
{
    my $port = shift;

    return FALSE unless defined $port;

    if (($port =~ /^\d+$/) &&
        ($port > 0) &&
        ($port < 65536))
    {
        return TRUE;
    }
    else {
        return FALSE;
    }
}

=item I<cmpIP>

Performs a cmp operation on two IP addresses. 

=begin testing

$ip1 = '24.123.212.87';
$ip2 = '240.34.216.12';

is(esmith::util::network::cmpIP($ip1, $ip2), -1);
is(esmith::util::network::cmpIP($ip2, $ip1), 1);
is(esmith::util::network::cmpIP($ip1, $ip1), 0);

=end testing

=cut

sub cmpIP($$)
{
    my $ip1 = ipv4_chkip(shift);
    my $ip2 = ipv4_chkip(shift);

    die "The first argument is not a valid IP address.\n" if not $ip1;
    die "The second argument is not a valid IP address.\n" if not $ip2;

    my @ip1cmps = split /\./, $ip1;
    my @ip2cmps = split /\./, $ip2;

    while (@ip1cmps)
    {
        my $cmp1 = shift @ip1cmps;
        my $cmp2 = shift @ip2cmps;

        my $cmp = $cmp1 <=> $cmp2;
        return $cmp if $cmp;
    }
    return 0;
}

=item I<isValidHostname>

This function returns true if it is passed a valid RFC 921 hostname,
false otherwise.

=cut

sub isValidHostname
{
    my $host_or_ip = shift;

    unless (isValidIP($host_or_ip))
    {
        # It's not an IP address. Does it look like a hostname?
        # FIXME: We could do a DNS lookup to be sure.
        # (See RFC 921, "Domain  Name System  Implementation  Schedule,"
        # FIXME: Put this in a library.
        unless ($host_or_ip =~ m{
            # Must begin with an alphabetical character...
            ^[a-z]
            # optionally followed by zero or more alphabetic characters,
            # hyphens, periods and numbers...
            [-a-z.0-9]*
            (
                # followed by one period...
                \.
                # and a repeat of the first pattern
                [a-z]
                [-a-z.0-9]*
            )+
            # which we can repeat one or more times, to the end of the
            # string.
            $
            # Case insensitive.
            }ix)
        {
            return 0;
        }
    }
    return 1;
}

=back

=head1 AUTHOR

Mitel Networks Corp.

=cut

1;

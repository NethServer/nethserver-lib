#
# Copyright (C) 2014 Nethesis S.r.l.
# http://www.nethesis.it - support@nethesis.it
#
# This script is part of NethServer.
#
# NethServer is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License,
# or any later version.
#
# NethServer is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with NethServer.
#

package esmith::config;
use strict;
use vars qw($VERSION);
$VERSION = 1.45;

use Sys::Hostname;
use NethServer::TimeZone;
use Sys::Syslog qw(:DEFAULT);
use Fcntl qw(:DEFAULT :flock);
use Carp qw(cluck);

my $Default_Config = '/var/lib/nethserver/db/configuration';

=pod

=head1 NAME

esmith::config - Access e-smith config files via hashes

=head1 SYNOPSIS

use esmith::config;

my %config;
my $config_obj = tie %config, 'esmith::config', $config_file;

# Read in the value of Wibble from the $config_file.
print $config{Wibble};

# Write out the value of Wibble to the $config_file.
$config{Wibble} = 42;

my $filename = $config_obj->filename;

=head1 DESCRIPTION

The esmith::config package enables Perl programs to read and write
entries from the e-smith configuration file using a simple hash
interface.

The configuration file has a simple ASCII representation,
with one "key=value" entry per line.

=begin testing

use_ok('esmith::config');
chdir '10e-smith-lib';

%Expect = ( foo              => 'bar',
'this key'       => 'has whitespace',
'that key '      => 'has trailing whitespace',
' another key'   => 'has leading whitespace',
'this value'     => ' has leading whitespace',
'that value'     => 'has trailing whitespace ',
'tricky value'   => 'with=equals.',
          );

=end testing

=head2 Tying

tie %config, 'esmith::config', $config_file;

Reads in the configuration from the given $config_file, returning a
tied hash (%config) populated with the keys & values from the
$config_file which you can then use like a normal hash.  Any writes or
deletes are immediately written back to the $config_file.

If no $config_file is supplied it falls back to the environment variable 
ESMITH_CONFIG_DB, and finally defaults to F</var/lib/nethserver/db/configuration>

If the $config_file doesn't exist it will create one for you.

=begin testing

my %config;
tie %config, 'esmith::config', 'dummy.conf';
ok( tied %config,                'tie worked' );
is( $config{foo}, 'bar',         '  theres stuff in it' );
ok( !exists $config{FILENAME},   '  it only contains config info');
is( tied(%config)->{FILENAME},     'dummy.conf',
'  and the real object is inside');

tie %config, 'esmith::config', 'I_dont_exist';
ok( tied %config,        'tying a non-existant file' );
is( keys %config, 0,    '  and its empty' );
$config{foo} = 42;
isnt( -s 'I_dont_exist', 0 );
untie %config;
ok( unlink 'I_dont_exist' );

$ENV{ESMITH_CONFIG_DB} = "dummy.conf";
tie %config, 'esmith::config';
ok( tied %config,                'tie to ESMITH_CONFIG_DB worked' );
is_deeply(\%config, \%Expect, "  picked up data");

=end testing

=head2 Methods

You can get at the underlying esmith::config object by using tied().

my $config_obj = tied %config;

it has a few useful methods.

=over 4

=item filename

my $file = $config_obj->filename;

Gets the config filename this object is tied to.

=begin testing

my %config;
my $obj = tie %config, 'esmith::config', 'dummy.conf';
is( $obj->filename, 'dummy.conf', 'filename()' );

=end testing

=cut

sub filename {
    my($self) = shift;
    return $self->{FILENAME};
}

=back

=begin _private

=head2 Private methods

=over 4

=item _readconf

my $config = _readconf($config_file);

Returns a hash ref of config key/value pairs read out of the given
$config_file.  If $config_file doesn't exist an empty hash ref will be
returned.

_readconf() understands the config file to be formatted as individual
lines of simply:

key=value

any further complexity of parsing the value is handled elsewhere.

=end _private

=begin testing

my $config = esmith::config::_readconf('dummy.conf');
isnt( keys %$config, 0,  '_readconf() got something' );
is_deeply( $config, \%Expect, '  read in the right values' );

$config = esmith::config::_readconf('I_dont_exist');
isa_ok( $config, 'HASH', '_readconf from a non-existent file' );
is( keys %$config, 0,    '  and its empty' );

=end testing

=cut

sub _readconf
{
    my ($self, $filename) = @_;

    my %config = ();

    unless (open (FH, $filename)) 
    {
        if (-f $filename)
        {
            &log("Config: ERROR: \"$filename\" exists but is not readable");
        }
        return \%config;
    }

    my $binmode = $self->_read_binmode;
    binmode(FH, $binmode) if $binmode;
    while (my $line = <FH>)
    {
        chomp $line;

        # BLIND UNTAINT!  Much code wrongly depends on this and
        # they should be moved away from it.
        $line =~ /(.*)/;
        $line = $1;

        # ignore comments and blank lines
        next if $line =~ /^\s*$/ || $line =~ /^\s*#/;

        my($key, $value) = split /=/, $line, 2;
        $config{$key} = $value;
    }

    close(FH);

    if($filename eq $Default_Config) {
        # !!!FIXME!!! configuration DB overrides
        my ($systemName, $domainName) = split(/\./, Sys::Hostname::hostname(), 2);
        $config{'SystemName'} = $systemName || '';
        $config{'DomainName'} = $domainName || '';
        tie $config{'TimeZone'}, 'NethServer::TimeZone', '';
    }

    return \%config;
}

=begin _private

=item _writeconf

my $success = _writeconf($config_file, \%config);

The given $config_file is overwritten using the entries in %config.

Returns whether or not the write succeded.

=end _private

=begin testing

my $scratch = 'scratch.conf';
ok( esmith::config::_writeconf($scratch, \%Expect),  
'_writeconf() says it worked' );
is_deeply( esmith::config::_readconf($scratch), \%Expect,   
'   wrote the right things' );
unlink $scratch;

=end testing

=cut

sub _writeconf
{
    my ($self, $filename, $config) = @_;

    eval {
        if (-f $filename && ! -r $filename)
        {
            die "'$filename' exists but is not readable\n";
        }

        sysopen (FH, "$filename.$$", O_RDWR | O_CREAT, 0660)
            or die "Cannot open $filename.$$: $!\n";
        my $binmode = $self->_write_binmode;
        binmode(FH, $binmode) if $binmode;

        die "Error writing to $filename.$$: $!" unless
        printf FH <<EOF, scalar localtime;
# DO NOT MODIFY THIS FILE.
# This file is automatically maintained by NethServer
# configuration software.  Manually editing this file may put your 
# system in an unknown state.
#
# updated: %s
EOF

        foreach my $key (sort keys %$config)
        {
            print FH "$key=$config->{$key}\n"
                or die "Error writing to $filename.$$: $!";
        }

        close (FH) or die "Error closing $filename.$$: $!";

        rename("$filename.$$", $filename)
            or die "Couldn't rename $filename.$$ to $filename: $!";
    };

    if($@) {
        chomp $@;
        &log($@);
        &log("'$filename' will not be updated");
        return;
    }
    else {
        return 1;
    }
}

=begin _private

=item B<_lock_write>

=item B<_lock_read>

$self->_lock_write;
$self->_lock_read;

Sets up read (shared) or write (exclusive) locks on the config file.
This is actually locking a semaphore file.

Returns if the lock succeeded or failed.

=item B<_unlock>

$self->_unlock

Unlocks the config file.

=end _private

=cut

sub _lock_write { $_[0]->_lock(LOCK_EX) }
sub _lock_read  { $_[0]->_lock(LOCK_SH) }

sub _lock {
    return if $] eq 5.006; # Locking is broken in perl 5.6.0
    my($self, $lock) = @_;

    my $semaphore = $self->{SEMAPHORE_FILE} = $self->{FILENAME}.'.lock';

    eval {
        open(my $fh, ">>$semaphore") or
        die "Can't open '$semaphore' semaphore: $!";
        $self->{SEMAPHORE} = $fh;

        flock($fh, $lock) or
        die "Can't lock '$semaphore' semaphore: $!";
    };
    if( $@ ) {
        warn $@;
        return;
    }
    else {
        return 1;
    }
}


sub _unlock {
    return if $] eq 5.006; # Locking is broken in perl 5.6.0
    my($self) = @_;

    eval {
        flock($self->{SEMAPHORE}, LOCK_UN) or
        die "Can't unlock $self->{SEMAPHORE_FILE}: $!";

        unlink $self->{SEMAPHORE_FILE};
        delete $self->{SEMAPHORE_FILE};
        delete $self->{SEMAPHORE};
    };
    if( $@ ) {
        warn $@;
        return;
    }
    else {
        return 1;
    }
}

=end _private

=back

=cut

#------------------------------------------------------------
# Constructor for the tied hash. If filename not specified,
# defaults to '/var/lib/nethserver/db/configuration'.
#------------------------------------------------------------

sub TIEHASH
{
    my $class    = shift;
    my $filename = shift || $ENV{ESMITH_CONFIG_DB} || $Default_Config;

    if ($filename =~ m:^/home/e-smith/\w+$: )
    {
        cluck "*WARNING* esmith::config($filename) called with old " .
              "database path. The following package needs to be updated: ";

        $filename =~ s:e-smith:e-smith/db:;
    }

    my $self =
        {
            FILENAME => $filename,
            CONFIG   => {},
        };
    bless $self, $class;

    $self->{CONFIG} = $self->_readconf($filename);

    return $self;
}

#------------------------------------------------------------
# Look up a configuration parameter.
#------------------------------------------------------------

sub FETCH
{
    my $self = shift;
    my $key  = shift;

    # Trim leading and trailing whitespace from the key.
    $key =~ s/^\s+|\s+$//g;

    return $self->{CONFIG}{$key};
}

#------------------------------------------------------------
# Store a configuration parameter.
#------------------------------------------------------------

sub STORE
{
    my $self  = shift;
    my $key   = shift;
    my $value = shift;

    die "key not defined" unless defined $key;
    die "value not defined for key $key" unless defined $value;

    if( $value =~ /\n/ or $key =~ /\n/ ) {
        &log("$self->{FILENAME}: esmith::config doesn't support newlines in ".
        "keys or values.  Truncating.");
        $key   =~ s/\n.*//s;
        $value =~ s/\n.*//s;
    }

    # Trim leading and trailing whitespace from the key and value.
    $key =~ s/^\s+|\s+$//g;
    $value =~ s/^\s+|\s+$//g;

    # Make sure that the value has a type. Given the format, it should be
    # sufficient to ensure that it does not begin with a pipe char.
    if ($value =~ /^\|/)
    {
        warn "ERROR: You should not set a config record without a type (key was $key).\n";
    }

    if ($self->{FILENAME} eq '/var/lib/nethserver/db/configuration') {
        if($key eq 'SystemName'
        || $key eq 'DomainName'
        || $key eq 'TimeZone') {
            warn("[WARNING] configuration DB: $key is deprecated on ns7 and read-only!\n");
        }
    }

    # read in config again, just in case it changed
    $self->_lock_write;
    $self->{CONFIG} = $self->_readconf($self->{FILENAME});

    if (exists $self->{CONFIG}{$key} and
    $self->{CONFIG}{$key} eq $value)
    {
        $self->_unlock;
        return undef;
    }

    my $msg = "$self->{FILENAME}: OLD $key=";

    if (exists $self->{CONFIG}{$key})
    {
        $msg .= "$self->{CONFIG}{$key}";
    }
    else
    {
        $msg .= "(undefined)";
    }

    &log($msg);

    $self->{CONFIG} {$key} = $value;
    &log("$self->{FILENAME}: NEW $key=$self->{CONFIG}{$key}");

    $self->_writeconf ($self->{FILENAME}, $self->{CONFIG});
    $self->_unlock;

    return undef;
}

#------------------------------------------------------------
# Delete a configuration parameter.
#------------------------------------------------------------

sub DELETE
{
    my $self = shift;
    my $key = shift;

    # Trim leading and trailing whitespace from the key.
    $key =~ s/^\s+|\s+$//g;

    # read in config again, just in case it changed
    $self->_lock_write;
    $self->{CONFIG} = $self->_readconf($self->{FILENAME});

    my $previous = delete $self->{CONFIG} {$key};
    $self->_writeconf ($self->{FILENAME}, $self->{CONFIG});
    $self->_unlock;

    &log("$self->{FILENAME}: DELETE $key=$previous");

    return $previous;
}

=begin _private

=item CLEAR

tie method: Clear the configuration file

=end _private

=begin testing

my $scratch = 'scratch.conf';
tie %config, 'esmith::config', $scratch;
ok( tied %config,        'tying a non-existant file' );
is( keys %config, 0,    '  and its empty' );
$config{fibble} = 'blah';
isnt( keys %config, 0,  '  and its not empty now' );
%config = ();
is( keys %config, 0,    '  and CLEAR made it empty again' );
unlink $scratch;

=end testing

=cut

sub CLEAR
{
    my $self = shift;

    $self->{CONFIG} = ();
    $self->_writeconf ($self->{FILENAME}, $self->{CONFIG});

    &log("$self->{FILENAME}: CLEAR");

    return undef;
}

#------------------------------------------------------------
# Check whether a particular key exists in the configuration file.
#------------------------------------------------------------

sub EXISTS
{
    my $self = shift;
    my $key = shift;

    # Trim leading and trailing whitespace from the key.
    $key =~ s/^\s+|\s+$//g;

    return exists $self->{CONFIG} {$key};
}

#------------------------------------------------------------
# FIRSTKEY is called whenever we start iterating over the
# configuration table. We cache the configuration table at
# this point to ensure reasonable results if the
# configuration file is changed by another program during
# the iteration.
#------------------------------------------------------------

sub FIRSTKEY
{
    my $self = shift;

    my $discard = keys %{$self->{CONFIG}};    # reset each() iterator

    return each %{$self->{CONFIG}};
}

#------------------------------------------------------------
# NEXTKEY is called for all iterations after the first.  We
# just keep returning results from the cached configuration
# table.  A null array is returned at the end. If the caller
# starts a new iteration, the FIRSTKEY subroutine is called
# again, causing the cache to be reloaded.
#------------------------------------------------------------

sub NEXTKEY
{
    my $self = shift;
    return each %{$self->{CONFIG}};
}


#------------------------------------------------------------
# Log messages to syslog
#------------------------------------------------------------

sub log
{
    # There is a bug in Perl 5.00504 and above. If you are using the unix
    # domain socket, do NOT use ndelay as part of the second argument
    # to openlog().

    my $msg = shift;
    $msg =~ s/[^[:ascii:]]/_/g;
    my $program = $0;

    openlog($program, 'pid', 'local1');
    syslog('info', "%s", $msg);
    closelog();
}

=item _read_binmode

return undef, indicating that by default binmode() need not be called after
file open.

=end _private

=cut

sub _read_binmode
{
    return undef;
}

sub _write_binmode
{
    return undef;
}

=head1 BUGS and CAVEATS

You can't have newlines in keys or values.

While the config values happen to be untainted B<do not depend on this
behavior> as it will change in the future.

=head1 AUTHOR

SME Server Developers <bugs@e-smith.com>

For more information, see http://www.e-smith.org/

=head1 SEE ALSO

esmith::db

=cut

1;

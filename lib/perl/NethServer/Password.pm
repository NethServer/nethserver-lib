#
# NethServer Password
#

#
# Copyright (C) 2013 Nethesis S.r.l.
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
# along with NethServer.  If not, see <http://www.gnu.org/licenses/>.
#

package NethServer::Password;
use strict;

=head1 NAME

NethServer::Password module

    The Module is used to create and store a password to /var/lib/nethserver/secrets
    
=head1 SYNOPSIS

To create, store and retrieve a password do :

    use NethServer::Password;
    my $pw = NethServer::Password::store('mysql');

by default the length is 16 characters

If you need a more stronger password (128 characters by example), you can call it directly

    my $pw = NethServer::Password->new('mysql',{'length' => 128})->save()->getAscii()

It will be created, stored and retrieved when needed

=cut


=head2 new

=cut
sub new
{
    my $class = shift;
    my $fileName = shift;
    my $opts = shift;

    my $self = {
	'fileName' => $fileName,
	'defaultDir' => '/var/lib/nethserver/secrets',
	'dirty' => 1,
	'secret' => undef,
	'symbols' => ['A'..'Z', 'a'..'z', '0'..'9', '_'],
	'length' => 16,
	'autoSave' => $fileName ? 1 : 0,
    };

    for (qw(defaultDir symbols length autoSave)) {
	if(defined $opts->{$_}) {
	    $self->{$_} = $opts->{$_};
	}	
    }

    # Prepend defaultDir if fileName is not an absolute path
    if(defined $self->{'fileName'} && $self->{'fileName'} !~ m|^/|) {
	$self->{'fileName'} = $self->{'defaultDir'} . '/' . $self->{'fileName'};
    }

    bless $self, $class;

    if($self->{'fileName'}) {
	$self->_load();
    } else {
	$self->generate();
    }

    return $self;
}


=head2 getAscii

=cut
sub getAscii
{
    my $self = shift;
    return $self->{'secret'};
}

=head2 generate

=cut
sub generate
{
    my $self = shift;
    my @sym = @{$self->{'symbols'}};
    $self->{'secret'} = join('', map $sym[rand(@sym)], 1..$self->{'length'});
    $self->{'dirty'} = 1;
    return $self;
}

sub _load
{
    my $self = shift;

    if( ! open(F, '<', $self->{'fileName'})) {
	return $self->generate();
    }

    my $data = <F>;
    close(F);

    chomp($data);
    $self->{'secret'} = $data;
    $self->{'dirty'} = 0;

    return $self;
}

=head2 save

=cut
sub save
{
    my $self = shift;
    if($self->{'dirty'}) {
        my $umask = umask 0077;
        if(open(F, ">", $self->{'fileName'})) {
	    print F $self->{'secret'} . "\n";
	    if(close(F)) {	    
		$self->{'dirty'} = 0;
	    }
	} else {
	    warn "[ERROR] could not store secret into '" . $self->{'fileName'} . "': $!\n";
	}
        umask $umask;
    }
    return $self;
}

sub DESTROY
{
    my $self = shift;
    if($self->{'autoSave'}) {
	$self->save();
    }
}

=head2 store

Static shortcut method, compatible with esmith::util::genRandomPassword()

=cut
sub store
{
    my $fileName = shift;
    return NethServer::Password->new($fileName)->save()->getAscii()
}

1;

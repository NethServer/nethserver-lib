#
# Copyright (C) 2016 Nethesis S.r.l.
# http://www.nethesis.it - nethserver@nethesis.it
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
# along with NethServer.  If not, see COPYING.
#

use strict;
package NethServer::TimeZone;
require Tie::Scalar;
use Net::DBus;

our @ISA = qw(Tie::Scalar);
my $bus;

sub TIESCALAR {
    my $class = shift;
    my $value = shift || '';
    return bless \$value, $class;
}

sub FETCH {
    my $ref = shift;
    if( ! defined $bus) {
        $bus = Net::DBus->system();
    }
    my $service = $bus->get_service("org.freedesktop.timedate1");
    my $object = $service->get_object('/org/freedesktop/timedate1');
    return $object->Timezone;
};

1;
#----------------------------------------------------------------------
# Copyright 1999-2003 Mitel Networks Corporation
# This program is free software; you can redistribute it and/or
# modify it under the same terms as Perl itself.
#----------------------------------------------------------------------

package esmith::DB;

use strict;
use warnings;
use Carp;
use File::Basename;
use esmith::templates;

use constant TRUE  => 1;
use constant FALSE => 0;

our $VERSION = sprintf '%d.%03d', q$Revision: 1.40 $ =~ /: (\d+).(\d+)/;
our $Error = undef;

=head1 NAME

esmith::DB - virtual interface to E-Smith databases

=head1 SYNOPSIS

    # Note: Do not instantiate this class directly. Use a subclass.
    # Examples in this documentation where you see it being used directly 
    # are merely for consistency. Substitute a subclass in our examples.
    use esmith::DB;
    my $db = esmith::DB->create($filename) or 
                 die esmith::DB->error;
    my $db = esmith::DB->open($filename)   or 
                 die esmith::DB->error;
    my $db = esmith::DB->open_ro($filename) or
       	     	 die esmith::DB->error;

    my %DB = esmith::DB->as_hash($filename) or
                 die esmith::DB->error;

    $db->reload;

    my $file = $db->file;

    my $record = $db->new_record($key, \%properties);

    my $record              = $db->get($key);
    my @all_records         = $db->get_all;
    my @all_records_by_prop = $db->get_all_by_prop($prop => $val);

    $db->set_prop($key, $prop, $value);
    $db->set_value($key, $value);

    $db->set_prop($key, $prop, $value, type => $type);
    $db->set_value($key, $value, create => 0);

=head1 DESCRIPTION

This module is a general interface to E-Smith's databases of various
types and formats.  It is not intended to be used directly, but that
subclasses will implement the interface presented here to provide a
single interface no matter what the underlying format.

For example, there is esmith::DB::db to interface with esmith::db
flatfile databases.  There could also be esmith::DB::Berkeley to use
Berkeley database files, or even esmith::DB::DBI.

Most of the methods herein are "virtual".  They don't exist.  The
subclass is responsible for impelmenting them.  There are a handful of
concrete methods that have been implemented for you that should work
with any subclass.

=head2 Virtual Methods

This is the esmith::DB interface.  Subclassers are expected to
implement these methods.

=over 4

=item I<create>

    my $db = esmith::DB->create($new_config_file) || 
        die esmith::DB->error;

Creates a brand new, empty configuration database and returns a
subclass of the esmith::DB object representing it.

Should the $new_config_file already exist or for some reason you can't
write to it, esmith::DB->error will return the reason and
create() will return false.

=item I<open>

    my $db = esmith::DB->open($config_file) || 
        die esmith::DB->error

Loads an existing configuration database and returns a
subclass of the esmith::DB::db object representing it.

Should the $config_file not exist or not be openable it will return
false and esmith::DB->error will contain the reason.

=item I<open_ro>

    my $db = esmith::DB->open_ro($config_file) ||
        die esmith::DB->error;

Like open(), but the database is read-only.  new_record() and all methods
which could change a record (set_prop(), merge_props(), delete(), etc...)
will both throw exceptions if used.

=item I<error>

    my $error = esmith::DB->error;

Returns a string describing the error from the last failing method.

=item I<reload>

    $db->reload;

Flushes out the $db's cache (if there is one) and reloads all
configuration data from disk.

=item I<file>

    my $file = $db->file;

File which this $db represents.

=item I<new_record>

    my $record = $db->new_record($key, \%properties);

Adds a new record at $key in the $db setting it to the given
%properties.  Returns a subclass of the esmith::DB::Record object.

If a record already exists for the $key it will return false.

=item I<get>

    my $record = $db->get($key);

Gets an existing record from the $db with the given $key.  Returns an
esmith::DB::Record object representing the data in $key.

If there's no record for the $key it will return false.

=item I<get_all>

    my @records = $db->get_all;

Gets all the records out of the given $db as a list of
esmith::DB::Record objects.

=back

=head2 Concrete methods

These are all implemented in terms of the esmith::DB interface and
its not necessary for a subclass to implement them.

=over 4

=item I<as_hash>

    my %db = $db->as_hash;
    my %db = esmith::DB->as_hash($file);

Returns the entire database as a hash of hashes.  Each key is a key in
the database, and the value is a hash of it's properties.

    my $value = $db{some_key}{some_prop};

When used as an object method it will use the already opened database.
When used as a class method it will open the given $file.

=cut

sub as_hash
{
    my ( $proto, $file ) = @_;
    my $class = ref $proto || $proto;

    my $self;
    if ( ref $proto )
    {    # object method
        $self = $proto;
    }
    else
    {    # class method
        $self = $class->open($file) or return;
    }
    my %hash = ();
    foreach my $rec ( $self->get_all )
    {
        my $key   = $rec->key;
        my %props = $rec->props;

        # Setup the hash
        $hash{$key} = \%props;
    }

    return %hash;
}

=item I<get_all_by_prop>

    my @records_by_prop = $db->get_all_by_prop($property => $value);

Like get_all() except it gets only those records whose $property has
the given $value.  For properties with multiple comma-delimited values 
(ie: name|val1,val2,val3), only one of the properties needs to match.

=cut

sub get_all_by_prop
{
    my ( $self, $prop, @rest ) = @_;
    my %props;

    if ( ref($prop) eq 'HASH' )
    {
	carp "get_all_by_prop called with anonymous hash argument";
	%props = ( %{$prop} );
    }
    else
    {
	%props = ($prop, @rest);
    }
    my @things = sort { $a->key cmp $b->key } grep
	{
	    my $found = 1;
	    while ( my ($p, $v) = each (%props) )
	    {
		$found &= ( defined $_->prop($p) and $_->prop($p) =~ /(?:^|,)$v(?:,|$)/ );
	    }
	    $found;
	} $self->get_all;
    @things;
}

=item I<get_value>

    my $value = $db->get_value( $key );

Shortcut method to get the value from the record defined by the given
key. Returns undef if the record does not exist. 

The following code is unsafe if the key doesn't exist:

    my $value = $db->get("foo")->value || 'default';

and should be:

    my $value = 'default';

    if (my $r = $db->get("foo"))
    {
        $value = $r->value;
    }

With this method, you can use:

    my $value = $db->get_value("foo") || 'default';

=cut

sub get_value
{
    my $self = shift;
    my $item = $self->get(shift);
    return undef unless $item;
    return $item->value;
}

=item I<get_prop>

    my $prop = $db->get_prop( $key, $prop );

Shortcut method to get a property from the record defined by the given key.

Returns undef if the record for that key doesn't exist, or the property does
not exist.

The following code is unsafe if either the key or property doesn't exist:

    my $status = $db->get("foo")->prop('status') || 'disabled';

and should be written as:

my $status;

if (my $s = $db->get("foo"))
{
    $status = $s->prop('status');
}

$status ||= "default";

With this method, you can use:

    my $value = $db->get_prop("foo", "status") || 'default';

=cut

sub get_prop
{
    my $self = shift;
    my $item = $self->get(shift);
    return undef unless $item;
    return $item->prop(shift);
}

=item I<set_value>

    $db->set_value($key, $value)[, create => 1]);

Shortcut method to set a value to a key in the database without extracting the
record first.

If the record is not pre-existing, it will be created, unless the 'create'
option is passed with a value of 0.

Returns 0 for any errors, 1 for success.

=cut

sub set_value
{
    my $self = shift;
    my ($key, $value, %options) = @_;

    my %defaults = (create => 1);
    %options = (%defaults, %options);

    my $record = $self->get($key);
    unless ($record)
    {
        if ($options{create})
        {
            $record = $self->new_record($key, {type => $value})
                or return 0;
        }
        else
        {
            return 0;
        }
    }
    $record->set_value($value)
        or return 0;

    return 1;
}

=item I<set_prop>

    $db->set_prop($key, $prop, $value[, type => $type]);

Shortcut method to set a property on a record without having to extract the
record first.

If the optional type option is passed, it will be used to create the record if
it does not already exist. Otherwise, a non-existent record will cause this
method to return an error.

Returns 0 for any errors, 1 for success.

=cut

sub set_prop
{
    my $self = shift;
    my ($key, $prop, $value, %options) = @_;
    my %defaults = (type => '');
    %options = (%defaults, %options);

    my $record = $self->get($key);
    unless ($record)
    {
        if ($options{type})
        {
            $record = $self->new_record($key, {type => $options{type}})
                or return 0;
        }
        else
        {
            return 0;
        }
    }
    $record->set_prop($prop, $value)
        or return 0;
    return 1;
}

=item I<keys>

    foreach my $key ($db->keys)
    {

A simple convenience function to prevent having to access the config hash
inside the db object (technically private), or calling map across a get_all
call, which is what this is going to do. :)

This method returns a list of keys to the records in the db. It does not sort.

=back

=cut

sub keys
{
    my $self = shift;
    return map { $_->{key} } $self->get_all;
}

=pod

=head2 migrate

Process the fragments in the migration queue for this database, using
processTemplate.

The defaults are loaded from /etc/e-smith/db/<dbname>/migrate by default, but
the environment variable ESMITH_DB_DEFAULTSDIR can be set to use a different
hierarchy if required.

The entries in "migrate" are perl fragments which will be evaluated and
so can munge anything they choose to. But, please be gentle :-)

So you could have

    /etc/e-smith/db/configuration/migrate/sshd/access

which is a perl fragment which does something funky to migrate the access
property from some old value to some new value.

After running all the migration scripts, and reloading the DB's data into
its local cache, the private method _loadDefaults is called to set any
missing default values and any forced settings.

=cut

sub migrate
{
    my ($self) = @_;

    my $dbfile = basename( $self->{file} );
    unless ($dbfile)
    {
        carp "migrate can't determine filename";
        return undef;
    }

    my $defaults_dir = $ENV{ESMITH_DB_DEFAULTSDIR} || "/etc/e-smith/db";
    my $dir          = "$defaults_dir/$dbfile/migrate";

    eval {
        if ( -d $dir )
        {
            processTemplate(
                {
                    MORE_DATA             => { 'DB_FILENAME' => $dbfile },
                    TEMPLATE_PATH         => '',
                    OUTPUT_TYPE           => 'string',
                    TEMPLATE_EXPAND_QUEUE =>
                      [ $dir, "/etc/e-smith/templates-default" ]
                }
            );
            $self->reload;
        }
        $self->_loadDefaults();
    };
    if ($@)
    {
        warn "Warning: Migration of $dbfile failed fatally: $@\n";
        $self->set_error($@);
        return FALSE;
    }
    return TRUE;
}

=pod

=head2 resetToDefaults

Reset all entries to their default values, if defaults exist. This calls
the internal method _loadDefaults with the forceReset flag set. It should
not be used lightly!!

=cut

sub resetToDefaults
{
    my ($self) = @_;

    $self->_loadDefaults(1);
}

=head2 record_has_defaults

Returns true if there are defaults or force directories for the
given record name

=cut

sub record_has_defaults
{
    my ( $self, $name ) = @_;

    my $dbfile = basename( $self->{file} );

    unless ($dbfile)
    {
        carp "record_has_defaults can't determine filename";
        return undef;
    }

    unless ($name)
    {
        carp "record_has_defaults can't determine record name";
        return undef;
    }

    my $defaults_dir = $ENV{ESMITH_DB_DEFAULTSDIR} || "/etc/e-smith/db";
    my $dir          = "$defaults_dir/$dbfile";

    return ( -d "$dir/defaults/$name" ) || ( -d "$dir/force/$name" );
}

=pod

=head2 _loadDefaults ($forceReset)

B<This is a private method.>

Load the default properties for a given database.
Caller can provide a flag to force resetting properties that already exist.

Any forced properties will be evaluated after setting the default properties.

The defaults are loaded from the following directories in order (the 
environment variable ESMITH_DB_DEFAULTSDIR can be set to use a different 
hierarchy if required):

    /etc/e-smith/db/<dbname>/defaults
    /etc/e-smith/db/<dbname>/force

Each of these directories is arranged as a set of subdirectories, with the
directory name equal to the key for the given database. With these
subdirectories are files, which are named by the properties of these
database keys.

The entries in "defaults" will be skipped if the existing key/property
already exists (unless the $forceReset argument is provided). These are
simple files, whose contents are the value to be used for that property.

The entries in "force" are always loaded into the given key/property.
These are again simple files, like "defaults".

To make this concrete, you might have:

    /etc/e-smith/db/configuration/defaults/sshd/access

containing the single word "private", which would be the default. This
value would only be used if no "access" property existed, or the 
$forceReset option is passed.

You can override both "defaults" and "migrate" with

    /etc/e-smith/db/configuration/force/sshd/access

containing the single word "public" to force the value of that property.

=cut

sub _loadDefaults
{
    my ( $self, $force ) = @_;

    my $dbfile = basename( $self->{file} );
    unless ($dbfile)
    {
        carp "_loadDefaults can't determine filename";
        return undef;
    }

    my $defaults_dir = $ENV{ESMITH_DB_DEFAULTSDIR} || "/etc/e-smith/db";

    my @propQueue =
      ( "$defaults_dir/$dbfile/defaults", "$defaults_dir/$dbfile/force", );

    foreach my $dir (@propQueue)
    {

        # Always process the force dir
        $force = 1 if ( $dir =~ /\/force$/ );

        next unless opendir DH, $dir;
        foreach my $key ( grep !/^\./, readdir DH )
        {
            if ( -d "$dir/$key" )
            {
                my %props = ();

                my $rec = $self->get($key);

                opendir DH2, "$dir/$key";
                foreach my $prop ( grep !/^\./, readdir DH2 )
                {
                    unless ($force)
                    {
                        next if ( $rec && defined $rec->prop($prop) );
                    }
                    open FH, "$dir/$key/$prop";
                    my $val = join "", (<FH>);
                    chomp $val;

                    $props{$prop} = $val;
                    close FH;
                }
                closedir DH2;
                if ($rec)
                {
                    $rec->merge_props(%props);
                }
                else
                {
                    $rec = $self->new_record( $key, \%props );
                }
            }
            else
            {
                warn "Found non-directory $key in $dir\n";
            }
        }
        close DH;
    }
    return 1;
}

=pod

=head2 get_value_and_delete ($key)

Retrieve the value of the named key, return it, and delete the record.
If the key does not exist, it returns undef. This is normally called from
migration code.

=cut

sub get_value_and_delete
{
    my ( $self, $key ) = @_;
    my $ret;
    my $rec = $self->get($key);
    if ($rec)
    {
        $ret = $rec->value;
        $rec->delete;
    }
    return $ret;
}

=pod

=head2 get_prop_and_delete ($key, $prop)

Retrieve the named property of the named key, return the value, and delete the
property from the record. Returns undef if the property or key does not exist.
This is normally called from migration code.

=cut

sub get_prop_and_delete
{
    my ( $self, $key, $prop ) = @_;
    my $ret;
    my $rec = $self->get($key);
    if ($rec)
    {
        $ret = $rec->prop($prop);
        $rec->delete_prop($prop);
    }
    return $ret;
}

sub set_error
{
    my $self = shift;
    $Error = shift;
}

sub error
{
    return $Error;
}

=pod

=head1 AUTHOR

SME Server Developers <bugs@e-smith.com>

=cut

1;

#----------------------------------------------------------------------
# Copyright 1999-2007 Mitel Networks Corporation
# This program is free software; you can redistribute it and/or
# modify it under the same terms as Perl itself.
#----------------------------------------------------------------------

package esmith::templates;

use strict;
require Exporter;
our @ISA       = qw(Exporter);
our @EXPORT    = qw(processTemplate);
our @EXPORT_OK = qw(removeBlankLines);

use Text::Template 'fill_in_file';
use Errno;
use esmith::ConfigDB;
use esmith::db;
use vars '$TEMPLATE_COUNT';

use Carp;
use File::Basename;
use File::stat;
use FileHandle;
use DirHandle;

$TEMPLATE_COUNT = 0;

=for testing
use_ok('esmith::templates');


=head1 NAME

esmith::template - Utilities for e-smith server and gateway development

=head1 VERSION

This file documents C<esmith::template> version B<1.7.0>

=head1 SYNOPSIS

    use esmith::template;
    processTemplate(...);

=head1 DESCRIPTION

This is the interface to the E-Smith templating system.  For an
overview of how the system works, see section "3.4 Templated
Configuration System" of the Dev Guide.

esmith::template exports a single function, processTemplate, which, as
you might guess, processes sets of templates into a single output
file.

=head2 Template Variables

The following variables are available to all templates.

=over 4

=item B<$confref>

B<DEPRECATED>.  Contains a reference to the hash passed in via
CONFREF.  If none was given it defaults to a tied esmith::config hash.

=item B<$DB>

Contains a reference to an esmith::ConfigDB object pointing at the
default configurations.  This is to be used to call methods like
C<$DB->services> and *not* for alterting the database.

=back

In addition, each record in the default esmith configuration database
(configuration) is available as a hash if it has
multiple properties (where each key/value is a property of the record)
or if it has a single property (type) then it given as a scalar.

So you can say:

    { $DomainName }     # $configdb->get('DomainName')->value;
    { $sshd{status} }   # $configdb->get('sshd')->prop('status')

Finally, variables from additional databases are usually gotten
via the esmith::DB->as_hash feature.

    {  require esmith::HostsDB;
       my %Hosts = esmith::HostsDB->as_hash;
       ...
    }


=head2 Functions

=over 4

=item B<processTemplate>

  processTemplate({ CONFREF       => \%config,
                    TEMPLATE_PATH => $output_file
                 });

  $filled_in_template = processTemplate({ CONFREF       => \%config,
                                          TEMPLATE_PATH => $output_file
                                          OUTPUT_TYPE   => 'string'
                                        });

processTemplate() expands a set of templates based on the keys/values
in %config.

The options to processTemplate are as follows...

=over 4

=begin deprecated

=item ALL_RECORDS_AS_SCALARS

For backwards compatibility purposes, the expand-template script needs
I<all> keys to be scalars, whether they have multiple properties or
not.  If this variable is true all the variables pulled in from
esmith::ConfigDB->open will be scalars in addition to hashes.

This is B<ONLY> to be used by expand-template.

=end deprecated

=item MORE_DATA

A hash ref containing additional variables you'd like to put into the
template.  Key is the name of the variable, value is it's value.

    # $Foo = 'bar'
    MORE_DATA => { Foo => "bar" }

Any keys in MORE_DATA will override those from the default
esmith::ConfigDB.

This replaces I<CONFREF>.

=item CONFREF

B<DEPRECATED>.  A reference to the hash which will become the
variables in the template.  So $config{Foo} becomes $Foo.  In
addition, there is the $confref variable which contains a reference
back to the original CONFREF.

This is usually a tied esmith::config hash.

This has been replaced by MORE_DATA and cannot be used in conjunction.

=begin testing

use esmith::HostsDB;
eval {
    processTemplate({ CONFREF   => { foo => "bar" },
                      MORE_DATA => { something => 'other' },
                    });
};
like( $@, qr/^ERROR: Can't use CONFREF with MORE_DATA/ );

=end testing

=item TEMPLATE_PATH

Full path to the file which fill result from this template.  For
example, '/etc/hosts'.

=item TEMPLATE_EXPAND_QUEUE

List of directories to scan for templates.  If not specified it
defaults to:

    /etc/e-smith/templates-custom
    /etc/e-smith/templates

it then appends the TEMPLATE_PATH to this, so the resulting search
might be:

    /etc/e-smith/templates-custom/etc/host
    /etc/e-smith/templates/etc/host

All templates found are combined in ASCIIbetical order to produce the
final file.  The exception to this is template-begin, which always
comes first, and template-end, which always comes last.

If no template-begin is found the one in
/etc/e-smith/templates-default/ will be used.

If two directories contain the same template those eariler in the
queue will override those later.  So /etc/e-smith/templates-custom/foo
will be used instead of /etc/e-smith/templates/foo.

=item OUTPUT_PREFIX

Directory which contains the OUTPUT_FILENAME.

=item OUTPUT_FILENAME

The file which results from this template.

Defaults to the TEMPLATE_PATH.

=item FILTER

A code ref through which each line of the resulting text is fed, for
example:

    FILTER => sub { "# $_[0]" }

would put a # in front of each line of the template.

    FILTER => sub { $_[0] =~ /^\s*$/ ? '' : $_[0] }

will remove all lines that contain only whitespace.

=item UID

=item GID

The user and group ID by which the resulting file should be owned.
This obviously means you have to run procTemplate as root.

Defaults to UID 0 and GID 0.

=item PERMS

File permissions which the resulting file should be set to have.

Defaults to 0644.

=item OUTPUT_TYPE

Determines if the filled in template should go straight to a file or
be returned by processTemplate().  The values can be:

    string     return the filled in template
    file       write it to disk

Defaults to 'file'

=back

For example we have a template F</etc/e-smith/templates/etc/hosts>
that we want to expand to F</etc/hosts> using the normal
configuration.

    # Records from esmith::ConfigDB->open will be available by default
    processTemplate({
        TEMPLATE_PATH => '/etc/hosts',
    });

Example 2: we have a template F</etc/e-smith/templates-user/qmail>
that we want to expand to F</home/e-smith/files/users/$username/.qmail>

Solution:

    processTemplate({ 
        TEMPLATE_PATH => '/qmail',
        TEMPLATE_EXPAND_QUEUE => [
            '/etc/e-smith/templates-user-custom',
            '/etc/e-smith/templates-user',
        ],
        OUTPUT_PREFIX => '/home/e-smith/files/users/$username',
        OUTPUT_FILENAME => '.qmail',
        FILTER => sub { $_[0] =~ /^\s*$/ ? '' : $_[0] },
        UID => $username,
        GID => $username,
        PERMS => 0644,
    });

Example 3: we have a template fragment
F</etc/e-smith/templates/etc/httpd/conf/httpd.conf/80VirtualHosts>
that needs to iterate through the given list of VirtualHosts,
process each template and return the results in a string until all the
VirtualHosts have been completed.  The results will be expanded
into the F</etc/httpd/conf/httpd.conf> file.

Solution: In the 80VirtualHosts fragment, we use the OUTPUT_TYPE='string'
option to return the output of processTemplate for each VirtualHost as a
string, and then we add the results to the $OUT variable for inclusion in the
httpd.conf template expansion.  We store the VirtualHosts template in
F</etc/httpd/conf/httpd.conf/VirtualHosts> for clarity and namespace
separation.

    foreach my $ipAddress (keys %ipAddresses)
    {
    	# the $OUT variable stores the output of this template fragment
        use esmith::templates;
        $OUT .= processTemplate (
            {
                MORE_DATA => { ipAddress => $ipAddress, port => $port,
                               virtualHosts => \@virtualHosts,
                               virtualHostContent => \%virtualHostContent },
                TEMPLATE_PATH => "/etc/httpd/conf/httpd.conf/VirtualHosts",
                OUTPUT_TYPE => 'string',
            });
    }


=cut

sub processTemplate {

    ######################################
    # set the default values to use if not
    #  specified in parameters
    # every valid parameter should have a default
    ######################################

    my %defaults = (
        MORE_DATA              => {},
        ALL_RECORDS_AS_SCALARS => 1,
        CONFREF                => undef,
        TEMPLATE_PATH          => '',      # replaces FILE_PATH
        OUTPUT_FILENAME        => '',      # replaces FILE_PATH_LIST
        TEMPLATE_EXPAND_QUEUE  =>
          [ '/etc/e-smith/templates-custom', '/etc/e-smith/templates', ],
        OUTPUT_PREFIX => '',               # replaces TARGET
        FILTER        => undef,
        UID           => 0,
        GID           => 0,
        PERMS         => 0644,
        OUTPUT_TYPE   => 'file',           # [file|string]
        DELETE        => 0,
    );

    # store the valid output types so we can do a quick sanity check
    my @valid_output_types = ( 'file', 'string' );

    my $conf_or_params_ref = shift;
    my $path               = shift;
    my %params_hash;
    if ( defined $path ) {

        # This is the old syntax, so we just grab the the two or maybe
        # three parameters ...
        %params_hash = (
            CONFREF       => $conf_or_params_ref,
            TEMPLATE_PATH => $path,
        );
        if ( my $source = shift ) {
            $params_hash{'TEMPLATE_EXPAND_QUEUE'} = [$source];
        }
    }
    else {
        %params_hash = %$conf_or_params_ref;
    }

    # Read additional metadata assocated with the templated file
    my $metadata_path = "/etc/e-smith/templates.metadata/$params_hash{TEMPLATE_PATH}";
    if (open(FILE, $metadata_path))
    {
	while (<FILE>)
	{
	    /^([^=]+)=(.*)$/;
	    $params_hash{$1} = eval $2;
	}
	close(FILE);
    }
    if (my $d = DirHandle->new($metadata_path))
    {
        while ($_ = $d->read)
        {
	    # skip any directories, including . and ..
            next if -d "$metadata_path/$_";
	    # Untaint filename
            /(\w+)/; my $file = $1;
            unless (open(FILE, "$metadata_path/$file"))
            {
                warn("Could not open metadata file $metadata_path/$file: $!");
                next;
            }
            # Read and untaint content of file
            $params_hash{$file} = eval do { local $/; $_ = <FILE>; /(.*)/s ; "{ $1 }" };
            close(FILE);
        }
    }

    # warn on deprecated or unknown parameters
    foreach my $key ( keys %params_hash ) {
        unless ( exists $defaults{$key} ) {
            carp "WARNING: Unknown parameter '$key' "
              . "passed to processTemplate\n";
        }
    }

    # Check for illegal combinations of variables.
    if ( exists $params_hash{CONFREF} && exists $params_hash{MORE_DATA}) {
        carp "ERROR: Can't use CONFREF with MORE_DATA in processTemplate\n";
	return;
    }

    ### merge incoming parameters with the defaults
    # -this is backwards compatible with the old positional
    #   parameters $confref, $filename, and $source
    my %p = ( %defaults, %params_hash );

    # set OUTPUT_FILENAME to TEMPLATE_PATH if it wasn't explicitly set
    unless ( $p{'OUTPUT_FILENAME'} ) {

        # if OUTPUT_FILENAME exists, it holds an array of target filenames
        $p{'OUTPUT_FILENAME'} = $p{'TEMPLATE_PATH'};
    }

    unless ( exists $p{'TEMPLATE_PATH'} ) {
        carp "ERROR: TEMPLATE_PATH parameter missing in processTemplate\n";
	return;
    }

    my $template_path = $p{'TEMPLATE_PATH'};
    my $outputfile    = $p{'OUTPUT_PREFIX'} . '/' . $p{'OUTPUT_FILENAME'};
    my $tempfile      = "$outputfile.$$";

    # sanity check on OUTPUT_TYPE
    unless ( grep( $p{'OUTPUT_TYPE'}, @valid_output_types ) ) {
        carp
          "ERROR: Invalid OUTPUT_TYPE parameter passed to processTemplate\n";
	return;
    }

    # If OUTPUT_TYPE=file and FILTER is off, then $fh is the output filehandle.
    # If OUTPUT_TYPE=file and FILTER is on, then $ofh is the real output
    # filehandle, and $fh is a temporary file for the pre-filtered output.
    my $fh;
    my $ofh;

    # if OUTPUT_TYPE=string, then $text is the output string
    my $text;

    if ( $p{'OUTPUT_TYPE'} eq 'file' ) {
        ##########################################################
        # open the target file before servicing the template queue
        ##########################################################

        if ( -d "$outputfile" ) {
            carp "ERROR: Could not expand $outputfile template "
              . "- it is a directory\n";
	    return;
        }

	# delete the file and do no more if we're told to by metadata
        if ($p{'DELETE'})
        {
            unlink "$outputfile";
            return 1;
        }

        # use POSIX::open to set permissions on create
        require POSIX;
        my $fd =
          POSIX::open( $tempfile,
            &POSIX::O_CREAT | &POSIX::O_WRONLY | &POSIX::O_TRUNC, 0600);
        unless ($fd)
	{
	    carp "ERROR: Cannot create output file " . "$tempfile $!\n";
	    return;
	}

        # create a filehandle reference to the newly opened file
        $fh = new FileHandle;
        unless ($fh->fdopen( $fd, "w" ))
	{
	    carp "ERROR: Cannot open output file " . "$tempfile: $!\n";
	    return;
	}

        if ( defined $p{FILTER} ) {

            # We have a filter to apply to the output. So we write the output
            # into an anonymous file, to prepare it for postprocessing
            require IO::File;

            $ofh = $fh;
            $fh  = IO::File->new_tmpfile;
        }

    }

    # Construct a hash containing mapping each template fragment
    # to its path.  Subsequent mappings of the same fragment
    # override the previous fragment (ie: merge new fragments
    # and override existing fragments)
    # use queue to store template source directories in order
    my @template_queue = @{ $p{'TEMPLATE_EXPAND_QUEUE'} };

    # use a hash to store template fragments
    my %template_hash = _merge_templates( $template_path, @template_queue );

    # if template hash is empty produce an error
    unless ( keys %template_hash ) {
        unlink $tempfile;
        carp "ERROR: No templates were found for $template_path.\n";
	return;
    }

    #####################################################
    # Process the template fragments and build the target
    #####################################################

    # create unique package namespace for this template
    # namespace is used by all template fragments
    $TEMPLATE_COUNT++;
    my $pkg = "esmith::__TEMPLATE__::${TEMPLATE_COUNT}";

    # Setup the template variables.
    my $tmpl_vars = _init_tmpl_vars( \%p );

    my $errorCount               = 0;
    my $warningCount             = 0;
    my $debug_template_expansion =
      ( $$tmpl_vars[0]{processTemplate}{Debug} || 'no' ) eq 'yes';

    # expand the template fragments into the target file
    foreach my $key ( sort _template_order keys %template_hash ) {
        my $filepath = $template_hash{$key};

        # Text::Template doesn't like zero length files so skip them
        unless ( -s $filepath ) { next }

        $debug_template_expansion
          && print "DEBUG: Expanding template fragment $filepath\n";

        local $SIG{__WARN__} = sub {
            $warningCount++;
            print STDERR "WARNING in $filepath: $_[0]";
        };

        {

            # prime the package namespace
            # use statements will only be run once per template
            # XXX DEPRECATED!
            eval " 
            package $pkg;
            use esmith::db;
            use esmith::util;
            ";

            # Arcane Text::Template error passing.  Don't ask.
            my $broken = sub {
                my %args = @_;
                ( my $error = $args{error} ) =~ s/\n+\z//;
                my $text   = $args{text};
                my $lineno = $args{lineno};
                $errorCount++;
                print STDERR "ERROR in $filepath: "
                  . "Program fragment delivered error <<$error>>"
                  . " at template line $lineno\n";
                return "";
            };

            # process the templates
            if ( $p{'OUTPUT_TYPE'} eq 'file' ) {
                unless (fill_in_file(
                    "$filepath",
                    HASH    => $tmpl_vars,
                    PACKAGE => $pkg,
                    BROKEN  => $broken,
                    UNTAINT => 1,
                    OUTPUT  => \*$fh
                  ))
		{
		    carp "ERROR: Cannot process template $filepath: $Text::Template::ERROR\n";
		    return;
		}
            }
            elsif ( $p{'OUTPUT_TYPE'} eq 'string' ) {
		my $ltext = fill_in_file(
                    "$filepath",
                    HASH    => $tmpl_vars,
                    BROKEN  => $broken,
                    UNTAINT => 1,
                    PACKAGE => $pkg
		);

		if( ! defined $ltext ) {
		    carp "ERROR: Cannot process template $filepath: $Text::Template::ERROR\n";
		    return;
		}

                $text .= $ltext;
            }
        }
    }

    #################################################################
    # Check for errors, and abort template processing if any occurred
    #################################################################
    if ($errorCount) {
        if ( $p{'OUTPUT_TYPE'} eq 'file' ) {
            close $fh;
            unlink $tempfile;
        }

        my $msg = "Template processing failed for $outputfile:";

        if ($warningCount) {
            $msg .= " $warningCount fragment";
            $msg .= "s" if $warningCount != 1;
            $msg .= " generated warnings,";
        }

        $msg .= " $errorCount fragment";
        $msg .= "s" if $errorCount != 1;
        $msg .= " generated errors";
        carp "ERROR: $msg\n";
	return;
    }
    elsif ($warningCount) {
        my $msg = "Template processing succeeded for $outputfile:";
        $msg .= " $warningCount fragment";
        $msg .= "s" if $warningCount != 1;
        $msg .= " generated warnings";
        carp "WARNING: $msg\n";
    }

    ##############################################################
    # Apply filters to the output, and do any necessary clean-up.
    ##############################################################

    if ( $p{'OUTPUT_TYPE'} eq 'file' ) {
        if ( defined $p{FILTER} ) {
            _filter_fh( $fh, $ofh, $p{FILTER} );
        }

        # This should close the file descripter AND file handle
        close $fh;

        # make filename point to new inode
        # NOTE: this is not an atomic operation, so on a non-journaling
        # filesystem it is possible that the template could become corrupt

        my $perms = $p{'PERMS'};
        $perms = oct($perms) if $perms =~ /^0/;

        # error checking and conversions for uid
        my $uid = $p{'UID'};
        if ( $uid =~ /^\d+$/ ) {
            unless ( defined getpwuid $uid ) {
                carp "WARNING: Invalid user: ${uid}, "
                  . "defaulting to 'root' user (0).\n";
                $uid = 0;
            }
        }
        else {
            my $uname = $uid;
            $uid = getpwnam $uid;
            unless ( defined $uid ) {
                carp "WARNING: Invalid user: ${uname}, "
                  . "defaulting to 'root' user (0).\n";
                $uid = 0;
            }
        }

        # error checking and conversions for gid
        my $gid = $p{'GID'};
        if ( $gid =~ /^\d+$/ ) {
            unless ( defined getgrgid $gid ) {
                carp "WARNING: Invalid group: ${gid}, "
                  . "defaulting to 'root' group (0).\n";
                $gid = 0;
            }
        }
        else {
            my $gname = $gid;
            $gid = getgrnam $gid;
            unless ( defined $gid ) {
                carp "WARNING: Invalid group: ${gname}, "
                  . "defaulting to 'root' group (0).\n";
                $gid = 0;
            }
        }

	# now do chown on our new target
	chown( $uid, $gid, $tempfile )
	  || carp "ERROR:  Can't chown file $tempfile: $!\n";

	# Now do chmod as well - POSIX::open does not change permissions
	# of a preexisting file
	chmod( $perms, $tempfile )
	  || carp "ERROR: Can't chmod file $tempfile: $!\n";
	
        unless ( -f $outputfile ) {
            if( ! rename( "$tempfile", "$outputfile" )) {
		carp("ERROR: Could not rename $tempfile " . "to $outputfile: $!\n" );
		return 0;
	    } else {
		return 1;
	    }
        }

        use Digest::MD5;

        open( NEW, "$tempfile" );
        my $newMD5sum = Digest::MD5->new->addfile(*NEW)->hexdigest;
        close NEW;

        open( OLD, "$outputfile" );
        my $oldMD5sum = Digest::MD5->new->addfile(*OLD)->hexdigest;
        close OLD;

        if ( $oldMD5sum eq $newMD5sum ) {
            $debug_template_expansion
              && warn("Not updating $outputfile - unchanged\n");
            unlink "$tempfile";

	    # now do chown and chmod the file, to ensure permissions are correct
	    chown( $uid, $gid, $outputfile )
	      || carp "ERROR:  Can't chown file $tempfile: $!\n";
	    chmod( $perms, $outputfile )
	      || carp "ERROR: Can't chmod file $tempfile: $!\n";
        }
        else {
            $debug_template_expansion
              && warn(
                "Updating $outputfile - MD5 was $oldMD5sum, now $newMD5sum\n");

            rename( "$tempfile", "$outputfile" )
              or carp(
                "ERROR: Could not rename $tempfile " . "to $outputfile: $!\n" );
        }

        # copy any additional files

        # A side effect of this routine is that it removes any old copies or
        # proposed new copies that RPM leaves lying around. (i.e. F<.rpmsave>
        # and F<.rpmnew> files.
        -e "$outputfile.rpmsave" and unlink "$outputfile.rpmsave";
        -e "$outputfile.rpmnew"  and unlink "$outputfile.rpmnew";
    }
    elsif ( $p{'OUTPUT_TYPE'} eq 'string' ) {
        if ( defined $p{FILTER} ) {
            $text = _filter_text( $text, $p{FILTER} );
        }
        return $text;
    }

    return 1;
}

=begin _private

=item _init_tmpl_vars

  my $template_vars = _init_tmpl_vars(\%params);

Given the %params to processTemplate (after being adjusted for
defaults) it will generate a ref suitable for passing into
Text::Template->fill_in(HASH) to generate variables in the template.

=end _private

=begin testing

use esmith::TestUtils qw(scratch_copy);

my $scratch = scratch_copy('10e-smith-lib/configuration.conf');
$ENV{ESMITH_CONFIG_DB} = $scratch;
use esmith::ConfigDB;
my $db = esmith::ConfigDB->open;
my @recs = $db->get_all;

my $vars = esmith::templates::_init_tmpl_vars({});
is( keys %{$vars->[0]}, grep($_->props >  1, @recs),
                               '  multi-prop ConfigDBs are hashes');
is( keys %{$vars->[1]}, grep($_->props <= 1, @recs),
                               '  single-prop are scalars'); 
is( keys %{$vars->[2]}, 2,     '  confref' );
isa_ok( $vars->[2]{DB}, 'REF', '  objects must be scalar refs for T::T' );
isa_ok( ${$vars->[2]{DB}}, 'esmith::ConfigDB' );
is( keys %{$vars->[3]}, 0,     '  no MORE_DATA' );


$vars = esmith::templates::_init_tmpl_vars({ CONFREF => { foo => 42,
                                                          bar => 23,
                                                        } });
is( keys %{$vars->[0]}, grep($_->props >  1, @recs),
                               '  multi-prop ConfigDBs are hashes');
is( keys %{$vars->[1]}, grep($_->props <= 1, @recs),
                               '  single-prop are scalars'); 
is( keys %{$vars->[2]}, 2,     '  confref' );
is_deeply( ${$vars->[2]{confref}}, { foo => 42, bar => 23 } );
is( keys %{$vars->[3]}, 2,     '  MORE_DATA' );
is( $vars->[3]{foo}, 42 );
is( $vars->[3]{bar}, 23 );


$vars = esmith::templates::_init_tmpl_vars({ MORE_DATA => { foo => 42,
                                                            bar => 23,
                                                          } });
is( keys %{$vars->[0]}, grep($_->props >  1, @recs),
                               '  multi-prop ConfigDBs are hashes');
is( keys %{$vars->[1]}, grep($_->props <= 1, @recs),
                               '  single-prop are scalars'); 
is( keys %{$vars->[2]}, 2,     '  confref' );
is( keys %{$vars->[3]}, 2,     '  MORE_DATA' );
is( $vars->[3]{foo}, 42 );
is( $vars->[3]{bar}, 23 );

my $h_scratch = scratch_copy('10e-smith-lib/hosts.conf');
my $a_scratch = scratch_copy('10e-smith-lib/accounts.conf');
my $c_scratch = scratch_copy('10e-smith-lib/configuration.conf');
$ENV{ESMITH_CONFIG_DB}   = $c_scratch;

$vars = esmith::templates::_init_tmpl_vars();

ok( ref ${ $vars->[2]{confref} } eq 'HASH', 'confref is HASH ref' );


=end testing

=cut

sub _init_tmpl_vars {
    my ($p) = shift;

    my @tmpl_vars = ();

    # Start with the default set of ConfigDB vars
    require esmith::ConfigDB;
    my $conf_db = esmith::ConfigDB->open;

    foreach my $rec ( $conf_db->get_all ) {
        my $key   = $rec->key;
        my %props = $rec->props;

        # Setup the hash
        $tmpl_vars[0]{$key} = \%props if keys %props > 1;

        # Setup the scalar
        if (
            $p->{ALL_RECORDS_AS_SCALARS}
            || ( keys %props <= 1
                && exists $props{type} )
          )
        {
            $tmpl_vars[1]{$key} = $conf_db->{config}{$key};
        }
    }

    # Add $confref and $DB
    $tmpl_vars[2]{confref} =
      $p->{CONFREF}
      ? \$p->{CONFREF}
      : \$conf_db->{config};
    $tmpl_vars[2]{DB} = \$conf_db;

    # And any additional data
    my $more_data = $p->{CONFREF} || $p->{MORE_DATA};
    while ( my ( $var, $val ) = each %{$more_data} ) {
        $tmpl_vars[3]{$var} = $val;
    }

    return \@tmpl_vars;
}

# for applying filters to an output filehandle
sub _filter_fh {
    my ( $ifh, $ofh, $filter ) = @_;

    # OK, we have a filter function to apply to the output
    # So we rewind the anonymous output file, and read its contents
    # then squirt it out into the named output file
    $ifh->flush;
    seek $ifh, 0, 0;

    while (<$ifh>) {
        print $ofh
	    join '', map { $filter->("$_\n") } split ( /\n/, $_ );
    }
    close $ifh;
    $ofh->flush;
}

# for applying filters to a text string returns the filtered text
# string
sub _filter_text {
    my ( $text, $filter ) = @_;

    # We have a filter function to apply to the output text
    return join '', map { $filter->("$_\n") } split ( /\n/, $text );
}

=begin testing

my %expect = (
              'templates/template-begin' => 
                                '10e-smith-lib/templates/template-begin',
              'templates/10moof' =>
                                '10e-smith-lib/templates/10moof',
              'templates/template-end' =>
                                '10e-smith-lib/templates/template-end',
             );

my %templates = esmith::templates::_merge_templates('templates', 
                                                    '10e-smith-lib');
is_deeply( \%templates, \%expect, '_merge_templates' );

%expect = (
           'templates2/template-begin' => 
                              '/etc/e-smith/templates-default/template-begin',
           'templates2/10moof' =>
                                '10e-smith-lib/templates2/10moof',
           'templates2/template-end' =>
                                '10e-smith-lib/templates2/template-end',
          );

%templates = esmith::templates::_merge_templates('templates2',
                                                 '10e-smith-lib');
is_deeply( \%templates, \%expect, '_merge_templates() + template-begin' );

%templates = esmith::templates::_merge_templates('templates3',
                                                 '10e-smith-lib');
is( keys %templates, 0 );

# Bug 3110.
%templates = esmith::templates::_merge_templates('templates.t',
                                                 '10e-smith-lib');

%expect = (
    'templates.t' => '10e-smith-lib/templates.t'
);
is_deeply( \%templates, \%expect, 'single file TEMPLATE_PATH' );


%templates = esmith::templates::_merge_templates('10moof',
	     					 '10e-smith-lib/templates2',
						 '10e-smith-lib/templates',
						);

%expect = (
    '10moof' => '10e-smith-lib/templates2/10moof'
);
is_deeply( \%templates, \%expect, 'single file TEMPLATE_PATH' );

=end testing

=cut

# the subroutine that does all the template merging
sub _merge_templates {
    my %templates      = ();
    my $filename       = shift;
    my @template_queue = @_;
    my $saw_dir        = 0;

    foreach my $source ( reverse @template_queue ) {
        my $tmpl_path = "$source/$filename";

        # if template is a flat template file overwrite the hash
        if ( -f $tmpl_path ) {
            %templates = ( $filename => $tmpl_path );
        }

        # otherwise, merge new fragments with the hash
        elsif ( -d $tmpl_path ) {
            $saw_dir = 1;

            delete $templates{"$filename"};

            # if dir exists but can't be opened then we have a problem
            opendir( DIR, $tmpl_path )
              || carp "Can't open template source directory:"
              . " $tmpl_path - skipping." && next;

            # fill the hash with template fragments
            while ( defined( my $file = readdir(DIR) ) ) {
                next if ( $file =~ /^\.{1,2}$/ );

                # Skip over files left over by rpm from upgrade
                # and other temp files etc.
                if ( $file =~ /(~|\.(swp|orig|rpmsave|rpmnew|rpmorig))$/o ) {
                    carp "Skipping $tmpl_path/$file";
                    next;
                }

                if ( -f "$tmpl_path/$file" ) {
                    # Untaint filename, else Text::Template will complain
                    $file =~ /(.*)/;
                    $templates{"$filename/$file"} = "$tmpl_path/$1";
                }
                elsif ( -d "$tmpl_path/$file" ) {

                    # silently ignore sub-directories
                    next;
                }
            }
            closedir(DIR);
        }
        else {
            next;
        }
    }

    # If a directory template is active, and there is no
    # template-default file, add a default one
    if ( $saw_dir && keys %templates ) {
        $templates{"${filename}/template-begin"} ||=
          '/etc/e-smith/templates-default/template-begin';
    }

    return %templates;
}

=begin _private

=item I<_template_order>

  my $cmp = _template_order;

Compares $a and $b returns -1, 0 or 1 if $template_file1 is less than,
equalto or greater than $template_file2.

Intended to be used as a sort function.  
C<sort _template_order @templates>

Templates are ordered in ASCIIbetical order excepting that
template-begin always goes at the front and template-end at the end.

=end _private

=begin testing

use POSIX ':locale_h';
use locale;
setlocale(LC_ALL, "en_US");
$esmith::templates::a = '10Ahhh';
$esmith::templates::b = '10ahhh';
is( esmith::templates::_template_order(), -1 );

=end testing

=cut

# sort subroutine for use by 'sort' function to order template fragments
sub _template_order {

    # so templates are always sorted ASCIIbetically, strictly speaking
    # this is unnecessary as "use locale" is lexical.
    no locale;

    my $file_a = basename($a);
    my $file_b = basename($b);

    return -1 if $file_a eq "template-begin" || $file_b eq "template-end";
    return 1  if $file_a eq "template-end"   || $file_b eq "template-begin";
    return $file_a cmp $file_b;
}

=head2 Filters

Filters are an experimental feature which allow you to filter the output
of a template in various ways.

Filtering functions take a single line at a time and return the
filtered version.

=over 4

=item removeBlankLines

Removes empty lines or those containing only whitespace from a
template.

=begin testing

use esmith::templates qw(removeBlankLines);
is( removeBlankLines("  "), '',         'removeBlankLines whitespace' );
is( removeBlankLines("\t"), '',         '  tabs' );
is( removeBlankLines("\n"), '',         '  newlines' );
is( removeBlankLines(""),   '',         '  empty' );
is( removeBlankLines(" a "), ' a ',     '  not empty' );

=end testing

=cut

sub removeBlankLines {
    $_[0] =~ /^\s*$/ ? '' : $_[0];
}

=head1 SEE ALSO

Section 3.4 "Templated Configuration System" of the E-Smith Dev Guide

=head1 AUTHOR

Mitel Networks Corporation

For more information, see http://www.e-smith.org/

=cut

1;

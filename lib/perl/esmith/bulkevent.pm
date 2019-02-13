#
# Copyright (C) 1999-2005 Mitel Networks Corporation
# http://contribs.org 
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

package esmith::bulkevent;

use strict;
use Exporter;
use File::Find;
use Time::HiRes qw( usleep ualarm gettimeofday tv_interval );
use esmith::Logger;
use File::Basename;
use NethServer::TrackerClient;
use List::MoreUtils qw(uniq);
use DirHandle;
use JSON;
use esmith::templates;


=pod

=head1 NAME

esmith::event - Routines for handling e-smith events

=head1 SYNOPSIS

    use esmith::event;

    my $exitcode = event_signal($event, @args);

=head1 DESCRIPTION

=cut

our $VERSION = sprintf '%d.%03d', q$Revision: 1.16 $ =~ /: (\d+).(\d+)/;
our @ISA         = qw(Exporter);
our @EXPORT      = qw(event_bulk set_json_log);

our @EXPORT_OK   = ();
our %EXPORT_TAGS = ();
our $return_value = undef;
our $json = 0;

tie *LOG, 'esmith::Logger', 'esmith::event';

sub set_json_log
{
    $json = shift;
}

sub _log_json
{
    my $hash = shift;
    if ($json) {
        $hash->{'pid'} = $$;
        print encode_json($hash)."\n";
    }
}

sub event_bulk
{
    my @events = @_;
    my %handlers;
    my %templates;
    my %services;
    foreach my $e (@events) {
        # list handlers
        my $handlerDir = "/etc/e-smith/events/$e";

        opendir (DIR, $handlerDir)
        || die "Can't open directory $handlerDir\n";

        foreach (grep {! -d "$handlerDir/$_"} readdir (DIR)) {
            my $handler = "$handlerDir/$_";
            if(-x $handler) {
                $handlers{basename($handler)} = $handler;
            }
        }
        closedir (DIR);

        # list templates
        my $templates_dir = "/etc/e-smith/events/$e/templates2expand";
        next unless -d $templates_dir;
        chdir $templates_dir or die "Could not chdir to $templates_dir: $!\n";
        find({
             no_chdir => 1,
             follow => 0,
             wanted => sub { if(-f $_) { $templates{$_} = 1; } },
        }, '.');

        # list services
        my $dir = "/etc/e-smith/events/$e";
        chdir $dir or die "Couldn't chdir to event directory $dir: $!";
        my $dh = DirHandle->new("services2adjust");

        if ($dh) {
            foreach (grep { !/^\./ } $dh->read()) {
                my @ops;
                my $f = "/etc/e-smith/events/$e/services2adjust/$_";
                if (-l $f) {
                    @ops = ( readlink "$f" );
                } else {
                    if (open(F, $f)) {
                        # Read list of actions from the file, and untaint
                        @ops = map { chomp; /([a-z]+[12]?)/ ; $1 } <F>;
                        close(F);
                    }
                }
                $services{$_} = \@ops;
            }
        }
    }
    
    # Execute all handlers
    
    $handlers{"S05generic_template_expand"} = "generic_template_expand";
    $handlers{"S90adjust-services"} = "adjust-services";

    my @handlerList = sort { $a cmp $b } keys %handlers;

    # Declare a subtask for each handler (action)
    my $tracker = NethServer::TrackerClient->new();
    my %tasks = ();

    foreach my $handler (@handlerList) {
        $tasks{$handler} = $tracker->declare_task(basename $handler);
    }

    my $i = 0;
    my $event = "bulk-event";
    my $isSuccess = 0;
    my $steps = scalar @handlerList;

    print LOG "Event: $event";
    _log_json({"event" => $event, "args" => "", "steps" =>  $steps});

    foreach my $handler (@handlerList) {
        if ($handler eq "S05generic_template_expand") {
            my @tmp = keys %templates;
            expand(\@tmp);
        } elsif ($handler eq "S90adjust-services") {
            close(STDIN);
            adjust(\%services);
        } else {

            _log_json({"event" => $event, "action" => $handler, "state" => "running", "step" => $i});
            my $startTime = [gettimeofday];
            my $status = _mysystem(\*LOG, $handlers{$handler}, $event, \%tasks);
            if($status != 0) {
                $isSuccess = 0; # 0=FALSE. if any handler fails, the entire event fails
            }
            my $endTime = [gettimeofday];
            my $elapsedTime = tv_interval($startTime, $endTime);
            my $log = "Action: $handler ";
            if($status) {
                if($status & 0xFF) {
                    $log .= 'FAILED: ' . ($status & 0xFF);
                } else {
                    $log .= 'FAILED: ' . ($status >> 8);
                }
            } else {
                $log .= 'SUCCESS';
            }
            $log .= " [$elapsedTime]";
            print LOG $log;
            _log_json({"event" => $event, "time" => $elapsedTime, "action" => $handlers{$handler}, "exit" => $status, "state" => "done", "step" => $i, "progress" => sprintf("%.2f", $i/$steps)});

            $tracker->set_task_done($tasks{$handler}, "", $status);
            $i++;

        }
    }

    if (!$isSuccess) {
        print LOG "Event: $event FAILED";
        _log_json({ "event" => $event, "status" => "failed"});
    } else {
        print LOG "Event: $event SUCCESS";
        _log_json({"event" => $event, "status" => "success"});
    }


}

sub expand
{
    my $templateList = shift;
    my $event = "bulk-event";
    my $errors;

    my $tracker = NethServer::TrackerClient->new();
    my %tasks = ();

    foreach my $filename (@$templateList) {
        $filename =~ s/^\.//;
        $tasks{$filename} = $tracker->declare_task('Template ' . $filename);
    }

    foreach my $filename (@$templateList) {
        my $errorMessage = "";
        # For each file found, read the file to find
        # processTemplate args, then expand the template
        $filename =~ s/^\.//;
        warn "expanding $filename\n";
        $tracker->set_task_progress($tasks{$filename}, 0.1, 'expanding');
        my $result = esmith::templates::processTemplate({
                MORE_DATA => { EVENT => $event },
                TEMPLATE_PATH => $filename,
                OUTPUT_FILENAME => $filename,
            });

        if( ! $result) {
            $errorMessage = "expansion of $filename failed";
            warn "[WARNING] " . $errorMessage . "\n";
            $errors++;
        }
        $tracker->set_task_done($tasks{$filename}, $errorMessage, $result ? 0 : 1);
    }
}


sub adjust
{
    my $services = shift;
    my $errors = 0;

    close(STDIN);

    my $tracker = NethServer::TrackerClient->new();
    my %tasks = ();

    foreach (keys %$services) {
        $tasks{$_} = $tracker->declare_task("Adjust service $_");
    }

    foreach my $service (keys %$services)
    {
        my $s = NethServer::Service->new($service);

        my $errorMessage = "";
        my $successMessage = "";
        my $action = '';
        my @actions = ();
        my $failed = 0;

        # Start or stop the service, if its running state is not what we expect:
        $s->adjust(\$action);

        if ($action eq 'start') {
            $successMessage = sprintf("%s has been started\n", $service);
            # Service just started: avoid doing restart or reload again
            my $tmp = $services->{$service};
            @actions = map {
            my $a = $_;
            (grep { $_ eq $a } qw(restart reload)) ? () : $a;
            } @$tmp;

        } elsif ($action eq 'stop') {
            $successMessage = sprintf("service %s %s and has been stopped\n", $service, get_reason($s));

        } elsif ($s->is_configured() && $s->is_enabled() && $s->is_owned() && ! $s->is_masked() ) {
            my $tmp = $services->{$service};
            @actions = @$tmp;;
            $successMessage = sprintf("service %s %s", $service, join(", ", @actions));

        } else {
            warn sprintf("[INFO] service %s %s: skipped\n", $service, get_reason($s));

        }

        chomp($successMessage);
        if($successMessage) {
            warn "[INFO] " . $successMessage . "\n";
        }

        my $progress = 0.1;
        foreach (@actions) {
            $tracker->set_task_progress($tasks{$service}, $progress, $_);
            if($s->can($_) && ! $s->$_() ) {
                $errorMessage .= sprintf("%s service %s failed!\n", $_, $service);
                $errors++;
                $failed = 1;
            }
            $progress += 0.1;
        }

        chomp($errorMessage);
        if($failed && $errorMessage) {
            warn "[WARNING] " . $errorMessage . "\n";
        }

        $tracker->set_task_done($tasks{$service}, ($failed ? $errorMessage : $successMessage), $failed);

    }

}


sub _mysystem
{
    my ($logger, $filename, $event, $tasks) = @_;

    my $pid = open(PIPE, "-|");
    die "Failed to fork: $!\n" unless defined $pid;

    if ($pid) {
        # Parent
        while (my $line = <PIPE>) {
            print $logger $line;
        }
    } else {
        # Child
        open(STDERR, ">&STDOUT");
        $ENV{'PTRACK_TASKID'} = $tasks->{$filename};
        print "exec($filename, $event);\n";
        exec($filename, $event);
    }
    close(PIPE);
    return $?;
}
sub get_reason
{
    my $s = shift;

    my $r = '';

    if( ! $s->is_configured() ) {
        $r = "is not configured";
    } elsif( ! $s->is_owned()) {
        $r = "is not owned by any package";
    } elsif( $s->is_masked()) {
        $r = "is masked";
    } elsif( ! $s->is_enabled()) {
        $r = "is disabled";
    } else {
        $r = "was running";
    }

    return $r;
}

1;

package Provisioning::Backup::KVM::mergediskimage;

# Copyright (C) 2013 FOSS-Group
#                    Germany
#                    http://www.foss-group.de
#                    support@foss-group.de
#
# Authors:
#  Pat Kläy <pat.klaey@stepping-stone.ch>
#  
# Licensed under the EUPL, Version 1.1 or – as soon they
# will be approved by the European Commission - subsequent
# versions of the EUPL (the "Licence");
# You may not use this work except in compliance with the
# Licence.
# You may obtain a copy of the Licence at:
#
# http://www.osor.eu/eupl
#
# Unless required by applicable law or agreed to in
# writing, software distributed under the Licence is
# distributed on an "AS IS" basis,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either
# express or implied.
# See the Licence for the specific language governing
# permissions and limitations under the Licence.
#
#
################################################################################

################################################################################
# Incorporate code with use (evaluates the included file at compile time).
################################################################################
use warnings;
use strict;

use Getopt::Long;
Getopt::Long::Configure("no_auto_abbrev");
use Sys::Syslog;
use Config::IniFiles;
use Cwd 'abs_path';
use File::Basename;
use Sys::Virt;

#use Provisioning::Backup::KVM::Constants;
#use Provisioning::Backup::KVM::Util;


$| = 1;                        # Turn buffering off, so that the output is flushed immediately

################################################################################
# Start the POD documentation information
################################################################################
=pod

=head1 NAME

.pl

=head1 DESCRIPTION

This script gets the arguments from  ...

The script uses syslog for logging purposes.

Command Line Interface (CLI) parameters:

=head1 USAGE

./

=head1 CREATED

2012-01-01 pat.klaey@stepping-stone.ch created

=head1 VERSION

=over

=item 2012-01-01 pat.klaey@stepping-stone.ch created

=back

=head1 INCORPORATED CODE

Incorporated code with use:

=over

=over

=item warnings;

=item strict;

=item Getopt::Long;

=item Sys::Syslog;

=back

=back

=cut
################################################################################
# End the POD documentation information
################################################################################

################################################################################
# Process the single character or long command line arguments.
################################################################################
my %opts;
GetOptions (
    \%opts,
    "help|h",       # This option will display a short help message.
    "machine|m:s",  # The machine name
    "disk|d:s",     # The disk image to merge
    "running|r:s",  # Is the machine running
    "bandwidth|b:s",# The bandwidth to merge
    "dry-run|y"     # Enables dry run
);

################################################################################
# Read the configuration file
################################################################################
my $location=dirname(abs_path($0));
my $file = basename($0);

#my $cfg=Config::IniFiles->new(-file => "$location/../etc/$file.conf");

################################################################################
# Variable definitions
################################################################################
my $debug             = 0;   # Debug modus: 0: off, 1: on

my $machine_name;
my $machine;
my $image;
my $running;
my $bandwidth = 2000;
my $dry_run = 0;
my $error = 0;

################################################################################
# Constant definitions
################################################################################
use constant SUCCESS_CODE                         => 0;
use constant ERROR_CODE                           => 1;

################################################################################
# Help text
################################################################################
my $help = "\nPlease use pod2text $0 for the online help\n\n";


################################################################################
# Main Programme
################################################################################

# Start syslog
openlog(abs_path($0),"ndelay,pid","local0");

# Check the command line arguments
checkCommandLineArguments();

# Define the VMmanager:
my $vmm = Sys::Virt->new( addr => "qemu:///system" );

# Get the machine according to the name
eval
{
    $machine = $vmm->get_domain_by_name($machine_name);
};

my $libvirt_err = $@;
               
# Test if there was an error
if ( $libvirt_err )
{
    my $error_message = $libvirt_err->message;
    my $error = $libvirt_err->code;
    syslog("LOG_ERR","Error from libvirt (".$error
          ."): libvirt says: $error_message.");
    return undef;
}

# If in dry run just print what we would do
if ( $dry_run )
{
    # Print what we would do to merge the images
    print "DRY-RUN:  ";
    print "virsh qemu-monitor-command --hmp $machine_name 'block_stream ";
    print "drive-virtio-disk0' --speed $bandwidth";
    print "\n\n";

    # Show dots for 30 seconds
    showWait(30);

} else
{
    # Check if the machine is running
    if ( ! $running )
    {
        # Start the machine in pasued state
        syslog("LOG_DEBUG","Machine is not running, starting in paused state");
        eval
        {
            $machine->create(Sys::Virt::Domain::START_PAUSED);
        };

        # Wait for the domain to be started
#        sleep(5);
    }

    # Really merge the disk images
    syslog("LOG_DEBUG","Merge process starts");
    eval
    {
        $machine->block_pull($image, $bandwidth);
    };

    my $libvirt_err = $@;

    # Remember the start time for a timeout
    my $start_time = time;

    # Test if there was an error
    if ( $libvirt_err )
    {
        my $error_message = $libvirt_err->message;
        $error = $libvirt_err->code;
        syslog("LOG_ERR","Error from libvirt (".$error
              ."): libvirt says: $error_message.");
        return $error;
    }

    # Test if the job is done:
    my $job_done = 0;
    while ( $job_done == 0)
    {
        # Get the block job information from the machine and the given image
        my $info = $machine->get_block_job_info($image, my $flags=0);

        # Test if type == 0, if yes the job is done, if test == 1, the job 
        # is still running
        $job_done = 1 if ( $info->{type} == 0 );

        # Wait for a second and retest
        sleep(1);

        # Test if timeout
        if ( time - $start_time > 14400 )
        {
            syslog("LOG_ERR","Machine is now merging for more than 4 "
                  ."hours, merge process timed out.");
            return $error = 1;
        }

    }

    #If the machine was not running, stop it again
    if ( ! $running )
    {
        syslog("LOG_DEBUG","Stopping machine again");
        eval
        {
            $machine->shutdown();
        };
    }
}


# OK merge process finished


# Close log and exit
closelog();
exit SUCCESS_CODE;

################################################################################
# checkCommandLineArguments
################################################################################
# Description:
#  Check the command line arguments
################################################################################
sub checkCommandLineArguments {

  # Check, if help was chosen. If yes, display help and exit
  if ($opts{'help'})
  {
    exec("pod2text $location/$0");
  } # End of if ($opts{'help'})

  # Get the machine name
  if ( !$opts{'machine'} || $opts{'machine'} eq "" )
  {
    syslog("LOG_ERR","No machine name passed to the merge-disk-image.pl script");
    exit 1;
  } else
  {
    $machine_name = $opts{'machine'};
  }

  # Get the disk image name
  if ( !$opts{'disk'} || $opts{'disk'} eq "" )
  {
    syslog("LOG_ERR","No disk image passed to the merge-disk-image.pl script");
    exit 1;
  } else
  {
    $image = $opts{'disk'};
  }

  # Get the disk image name
  if ( !$opts{'running'} || $opts{'running'} eq "" )
  {
    syslog("LOG_ERR","No running parameter passed to the merge-disk-image.pl script");
    exit 1;
  } else
  {
    $running = $opts{'running'};
  }

  # Should we do it in dry run?
  if ( $opts{'dry-run'} )
  {
    $dry_run = 1;
  }

  # Is the bandwidth limited? 
  if ( $opts{'bandwidth'} )
  {
    $bandwidth = $opts{'bandwidth'};
  }

} # End of sub checkCommandLineArguments

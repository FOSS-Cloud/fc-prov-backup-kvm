package Provisioning::Backup::KVM;

# Copyright (C) 2012 FOSS-Group
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

use warnings;
use strict;

use Config::IniFiles;
use Net::LDAP;
use Switch;
use Module::Load;
use Sys::Hostname;

use Provisioning::Log;
use Provisioning::Util;

require Exporter;

=pod

=head1 Name

Virtualization.pm

=head1 Description

=head1 Methods

=cut


our @ISA = qw(Exporter);

our %EXPORT_TAGS = ( 'all' => [ qw(processEntry) ] );

our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

our @EXPORT = qw(processEntry);

our $VERSION = '0.01';


###############################################################################
#####                             Constants                               #####
###############################################################################

use Provisioning::Backup::KVM::Constants;


# get the service for ??
my $service = $Provisioning::cfg->val("Global","SERVICE");

# get the config-file from the master script.
our $service_cfg = $Provisioning::cfg;

# load the nessecary modules
load "$Provisioning::server_module", ':all';


sub processEntry{

=pod

=over

=item processEntry($entry,$state)

This mehtod processes the given entry. It takes as input parameter the entry,
which should be processed, and it's state (add, modify, delete or started). 
First thing done is to check what type the entry is, therefore the entrys DN is 
parsed. According to the entrys type and the state, all necessary informations  
are collected using the Backend library specified in the configuration file.
Then the appropriate action (subroutine) is set up.

=back

=cut

  my ($entry,$state)=@_;

  unless ( needToProcess ($entry) )
  {
    # If we don't need to process the entry ( if the entry is not on our host )
    # let the daemon know by returning -1
    logger("debug","The entry (".getValue($entry,"dn").") is not on this host,"
          ."skipping");
    return -1;
  }

  my $error = 0;

  # $state must be "snapshot", "merge" or "retain" otherwise something went 
  # wrong and we should not be at this point
  switch ( $state )
  {
    case "snapshot" {
                        # First of all we need to let the deamon know that we 
                        # saw the change in the backend and the process is  
                        # started. So write snapshotting to sstProvisioningMode.
                        $state = "snapshotting";
                    }
    case "merge"    {
                        # First of all we need to let the deamon know that we 
                        # saw the change in the backend and the process is  
                        # started. So write merging to sstProvisioningMode.
                        $state = "merging";
                    }
    case "retain"   {
                        # First of all we need to let the deamon know that we 
                        # saw the change in the backend and the process is  
                        # started. So write merging to sstProvisioningMode.
                        $state = "retaining";
                    }
    else            {
                            # Log the error and return error
                            logger("error","The state for the entry "
                                   .getValue($entry,"dn")." is $state. Can only"
                                   ."process entries with one of the following "
                                   ."states: \"snapshot\", \"retain\" or " 
                                   ."\"retain\"");
                            return Provisioning::Backup::KVM::Constants::WRONG_STATE_INFORMATION;
                    }
  }

  # Connect to the backend:
  my $write_connection = connectToBackendServer("connect",1);

  # Check if connection could be established if not we stop the bakup process
  # because we cannot lock the VM. Locking the VM is necessary to avoid 
  # migration or similar what could result in an undefine state
  unless ( $write_connection )
  {
    logger("error","Cannot connect to backend! No backup will be done since the"
           ." VM could be in an undefined state." );
           return Provisioning::Backup::KVM::Constants::CANNOT_CONNECT_TO_BACKEND;
  }

  # The return value to be written to the backend
  my $return_value = 0;

  # If connection is ok, write the changes to the backend
  $return_value = modifyAttribute( $entry,
                                   'sstProvisioningMode',
                                   $state,
                                   $write_connection
                                 );

  # Check if the sstProvisioningMode could be writte, if not exit
  if ( $return_value )
  {
    logger("error","Could not modify sstProvisioningMode, must not backup the "
          ."machine if it is not locked!");
    exit Provisioning::Backup::KVM::Constants::CANNOT_LOCK_MACHINE;
  }

  # Check what kind of virtualization service we need set up therefore get the
  # entrys parent
  my $parent = getParentEntry( $entry );

  # Switch the "ou" backend value:
  switch( getValue($parent,"ou") )
  {

    # Backup the machine
    case "backup"
    { 
       # Call some method in KVMBackup.......
       load "Provisioning::Backup::KVM::KVMBackup",':all';

       # Call the backup method and pass the entry as well as the connection
       # to the backend and the configuration file
       $return_value = backup( $state, $entry, $write_connection, $service_cfg);

    } # End case backup
    else 
    {
        logger("error","Unknown ou: ".getValue($parent,"ou").", cannot set "
              ."up correct method! Stopping here.");
#        $return_value = ??
    }

  } # end switch $entry->get_value("ou")

  # Write the return code from the action 
  modifyAttribute( $entry,
                   'sstProvisioningReturnValue',
                   $return_value,
                   $write_connection
                 );  

  # Disconnect from the backend
  disconnectFromServer($write_connection);

  return $return_value;

} # end sub processEntry


sub needToProcess
{
    my $entry = shift;
    
    # Test if the entry is on the current host
    my $dn = getValue($entry,"dn");

    # Get the current host name
    my $host = hostname;

    # Split the dn into it's parts
    my @parts = split(",",$dn);
    
    # Remove the first parts of the dn until you get the machine
    while( $parts[0] !~ m/^sstVirtualMachine/ )
    {
        shift(@parts);
    }

    # And now joint the parts with a comma -> new shortend dn
    $dn = join(",",@parts);

    # Search the backend for the entry with sstNode = host
    my @result = simpleSearch ( $dn, "(sstnode=$host)","base");

    return scalar(@result);
                                
}


1;

__END__
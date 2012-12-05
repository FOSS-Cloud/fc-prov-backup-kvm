package Provisioning::Backup::KVM::KVMRestore;

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
#

use warnings;
use strict;

use Config::IniFiles;
use Switch;
use Module::Load;
use POSIX;
use Sys::Virt;
use XML::Simple;
use Filesys::Df;
use Sys::Hostname;
use File::Basename;

use Provisioning::Log;
use Provisioning::Util;
use Provisioning::Backup::KVM::Constants;

require Exporter;

=pod

=head1 Name

KVMBackup.pm

=head1 Description

=head1 Methods

=cut


our @ISA = qw(Exporter);

our %EXPORT_TAGS = ( 'all' => [ qw(restore) ] );

our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

our @EXPORT = qw(restore);

our $VERSION = '0.01';

use constant 
{

SUCCESS_CODE => Provisioning::Backup::KVM::Constants::SUCCESS_CODE,
ERROR_CODE => Provisioning::Backup::KVM::Constants::ERROR_CODE,

};


# Get some vars from the provisioning script
my $dry_run = $Provisioning::opt_R;
my $TransportAPI = "Provisioning::TransportAPI::$Provisioning::TransportAPI";
my $gateway_connection = "$Provisioning::gateway_connection";

load "$TransportAPI", ':all';
load "$Provisioning::server_module", ':all';

# Define the VMmanager:
my $vmm = Sys::Virt->new( addr => "qemu:///system" );

# Set a variable to save the intermediate path to the disk image
my $intermediate_path;

################################################################################
# restore
################################################################################
# Description:
#  
################################################################################

sub restore
{

    my ($state, $entry , $backend_connection , $cfg ) = @_;

    # Initialize the var to return any error, initially it is 0 (no error)
    my $error = 0;

    # Get the machine according the the backend entry:
    my $backend = $cfg->val("Database","BACKEND");

    my $machine = getMachineByBackendEntry( $entry, $backend );

    if ( !$machine )
    {
        # Log and exit
        logger("error","Did not find machine according to the backend entry"),
        return Provisioning::Backup::KVM::Constants::CANNOT_FIND_MACHINE;
    }

    # Get the machines name:
    my $machine_name = getMachineName($machine);

    # Test if we could get the machines name
    unless ( defined( $machine_name ) )
    {
        # Return error code cannot save machines state ( we cannot save the
        # machine if we don't know the name)
        return Provisioning::Backup::KVM::Constants::UNDEFINED_ERROR;
    }

    # Get the parents enry because there is the configuration
    my $config_entry = getConfigEntry($entry, $cfg);

    # Test if a configuration entry was found or whether it is the error
    # Provisioning::Backup::KVM::Constants::CANNOT_FIND_CONFIGURATION_ENTRY
    if ( $config_entry == Provisioning::Backup::KVM::Constants::CANNOT_FIND_CONFIGURATION_ENTRY ) 
    {
        return Provisioning::Backup::KVM::Constants::CANNOT_FIND_CONFIGURATION_ENTRY;
    }

    # Now we can get all disk images which includes a test whether LDAP and XML
    # are synchronized
    my @disk_images = getDiskImagesByMachine( $machine, $entry );

    # Check the return code
    if ( $disk_images[0] == Provisioning::Backup::KVM::Constants::BACKEND_XML_UNCONSISTENCY )
    {
        # Log the error and return
        logger("error","The disk information for machine $machine_name is not "
              ."consistent between XML description and backend. Solve this "
              ."inconsistency before creating a backup");
        return Provisioning::Backup::KVM::Constants::BACKEND_XML_UNCONSISTENCY;
    }

    # Get and set the intermediate path for the given machine
    $intermediate_path = getIntermediatePath( $disk_images[0] );

    # Test what kind of state we have and set up the appropriate action
    switch ( $state )
    {
        case "unretaining" {    
                                my $error = 0;

                                # Write that the snapshot process is finished
                                modifyAttribute (  $entry,
                                                   "sstProvisioningMode",
                                                   "unretained",
                                                   $backend_connection,
                                                 );

                               
                                return $error;

                            } # End case snapshotting

        case "restoring"    { # Restore the vm

                                my $error = 0;
                                # Write that the merge process is finished
                                modifyAttribute (  $entry,
                                                   "sstProvisioningMode",
                                                   "restored",
                                                   $backend_connection,
                                                 );

                                return $error;
                            } # End case merging

      
        else                { # If nothing of the above was true we have a
                              # problem, log it and return appropriate error 
                              # code
                              logger("error","State $state is not known in "
                                    ."KVMRestore.pm. Stopping here.");
                              return Provisioning::Backup::KVM::Constants::WRONG_STATE_INFORMATION;
                            }


    } # End switch $state
}


################################################################################
# getMachineByBackendEntry
################################################################################
# Description:
#  
################################################################################

sub getMachineByBackendEntry
{

    my ( $entry, $backend ) = @_;

    # The machines name:
    my $name;

    # Test what kind of backend we have
    switch ( $backend )
    {
        case "LDAP" {
                        # First of all we need the dn because the machine name
                        # is part of the dn
                        my $dn = getValue($entry,"dn");
                        
                        # The attribute is sstVirtualMachine so search for it
                        $dn =~ m/,sstVirtualMachine=(.*),ou=virtual\s/;
                        $name = $1;
                    }
        else        {
                        # We don't know the backend, log it and return undef
                        logger("error","Backend type '$backend' unknown, cannot"
                              ." get machine");
                        return undef;
                    }
    }

    # Then get the machine by the name:
    my $machine;
    eval
    {
        $machine = $vmm->get_domain_by_name($name);
    };

    my $libvirt_err = $@;
               
    # Test if there was an error
    if ( $libvirt_err )
    {
        my $error_message = $libvirt_err->message;
        my $error = $libvirt_err->code;
        logger("error","Error from libvirt (".$error
              ."): libvirt says: $error_message.");
        return undef;
    }
   
    return $machine;
 }


################################################################################
# getMachineName
################################################################################
# Description:
#  
################################################################################

sub getMachineName
{

    my $machine = shift;

    my $name;
    eval
    {
        $name = $machine->get_name();
    };

    my $libvirt_err = $@;
               
    # Test if there was an error
    if ( $libvirt_err )
    {
        my $error_message = $libvirt_err->message;
        my $error = $libvirt_err->code;
        logger("error","Error from libvirt (".$error
              ."): libvirt says: $error_message.");
        return undef;
    }

    return $name;
}

################################################################################
# getIntermediatePath
################################################################################
# Description:
#  
################################################################################

sub getIntermediatePath
{

    my $image_path = shift;

    # Remove the /var/virtualization in front of the path
    $image_path =~ s/\/var\/virtualization\///;

    # Return now the dirname of the file
    return dirname( $image_path );

}



sub getConfigEntry
{

    my ($entry, $cfg) = @_;

    # Create the var which will be returned and will contain the config entry
    my $config_entry;

    # First of all check if the partent entry is the config entry
    my $parent_entry = getParentEntry( $entry );

    # Check if the parent entry is of objectclass
    # sstVirtualizationBackupObjectClass if yes it is the config entry, if no
    # we need to go the the vm-pool and check if this one is the config entry
    my @objectclass = getValue( $parent_entry, "objectclass" );

    # Go through the array and check for sstVirtualizationBackupObjectClass
    foreach my $value ( @objectclass )
    {
        # If the current value is sstVirtualizationBackupObjectClass then the
        # parent entry is the configuration entry, return it
        if ( $value eq "sstVirtualizationBackupObjectClass" )
        {
            logger("info","Backup configuration is VM specific");
            return $parent_entry;
        }
        
    }

    # At this point, the parent entry is not the config entry, go to the parent
    # entrys parent to get the vm pool
    my $grand_parent_entry = getParentEntry( $parent_entry );

    # Get the vm pool from the grand parent entry
    my $vm_pool_name = getValue( $grand_parent_entry, "sstVirtualMachinePool");

    # Search for the given pool
    # Create the subtree for the pool where the object class would be 
    # sstVirtualizationBackupObjectClass if the pool is the config entry
    my $subtree = "ou=backup,sstVirtualMachinePool=$vm_pool_name,"
                 ."ou=virtual machine pools,";
    $subtree .= $cfg->val("Database","SERVICE_SUBTREE");

    my @entries = simpleSearch( $subtree,
                                "(objectclass=sstVirtualizationBackupObjectClass)",
                                "base"
                              );

    # Test if there are more than one result ( that would be veeery strange )
    if ( @entries > 1 ) 
    {
        # Log and return error
        logger("error","There is something very strange, more than one pool "
              ."with name '$vm_pool_name' found. Cannot return configuration "
              ."entry. Stopping here.");
        return Provisioning::Backup::KVM::Constants::CANNOT_FIND_CONFIGURATION_ENTRY;
    }

    # Otherwise there is one or zero entrys, if there is one it is the config
    # entry so return it
    if ( @entries == 1 )
    {
        logger("info","Backup configuration is VM-Pool specific");
        return $entries[0];
    }

    # If the vm pool did not contain the configuration, we get the foss-cloud 
    # wide backup configuration
    my $global_conf = $cfg->val("Database","FOSS_CLOUD_WIDE_CONFIGURATION");

    # Search this entry with objectclass sstVirtualizationBackupObjectClass
    @entries = simpleSearch( $global_conf,
                             "(objectclass=sstVirtualizationBackupObjectClass)",
                             "base"
                           );
    
    # Test if there are more than one result ( that would be veeery strange )
    if ( @entries > 1 ) 
    {
        # Log and return error
        logger("error","There is something very strange, more than one global "
              ."configuration found. Cannot return configuration "
              ."entry. Stopping here.");
        return Provisioning::Backup::KVM::Constants::CANNOT_FIND_CONFIGURATION_ENTRY;
    } elsif ( @entries == 0 )
    {
        # Log and return error
        logger("error","Global configuartion ($global_conf) not found, cannot "
              ."return configuration entry. Stopping here.");
        return Provisioning::Backup::KVM::Constants::CANNOT_FIND_CONFIGURATION_ENTRY;
    }

    # Or we are lucky and can return the configuration entry which is the global
    # one
    logger("info","Backup configuration is default FOSS-Cloud configuration");
    return $entries[0];


}

################################################################################
# getMachineName
################################################################################
# Description:
#  
################################################################################

sub getDiskImagesByMachine
{
    my ($machine, $entry) = @_;

    # First of all get the disk images from the LDAP, to do that, we need the 
    # grandparent entry which will be the machine entry
    my $machine_entry = getParentEntry( getParentEntry( $entry ) );

    # Get the dn from the machine entry
    my $machine_dn = getValue($machine_entry, "dn");

    # Search for all objects under the machine dn which are sstDisk
    my @backend_disks = simpleSearch($machine_dn,
                                  "(&(objectclass=sstVirtualizationVirtualMachineDisk)(sstDevice=disk))",
                                  "sub"
                                 );

    # Now get all the disk image pathes from the backend entries
    my @backend_source_files = ();
    foreach my $backend_disk ( @backend_disks )
    {
        # Get the value sstSourceFile and add it to the backend_source_files 
        # array
        push( @backend_source_files, getValue( $backend_disk,"sstSourceFile") );
    }

    # Log what we have found in the backend
    logger("debug","Found ".@backend_source_files." disk images in backend: "
          ."@backend_source_files");

    # Get the machines xml description 
    my $xml_string;
    eval
    {
        $xml_string = $machine->get_xml_description();
    };

    my $libvirt_err = $@;
               
    # Test if there was an error
    if ( $libvirt_err )
    {
        my $error_message = $libvirt_err->message;
        my $error = $libvirt_err->code;
        logger("error","Error from libvirt (".$error
              ."): libvirt says: $error_message.");
        return undef;
    }

    # Will be used to go through the xml
    my $i = 0;

    # Initialize the XML-object from the string
    my $xml = XMLin( $xml_string,
                     KeepRoot => 1,
                     ForceArray => 1
                   );

    # The array to push all disk images from the xml
    my @xml_disks;

    # Go through all domainsnapshot -> domain -> device -> disks
    while ( $xml->{'domain'}->[0]->{'devices'}->[0]->{'disk'}->[$i] )
    {
        # Check if the disks device is disk and not cdrom, we want the disk
        # image path !
        if ( $xml->{'domain'}->[0]->{'devices'}->[0]->{'disk'}->[$i]->{'device'} eq "disk" )
        {
            # Return the file attribute in the source tag
            push( @xml_disks, $xml->{'domain'}->[0]->{'devices'}->[0]->{'disk'}->[$i]->{'source'}->[0]->{'file'});
        }

        # If it's not the disk disk, try the next one
        $i++;
    }

    # Log what we have found from the xml
    logger("debug","Found ".@xml_disks." disk images in XML description: "
          ."@xml_disks");

    # Check if both arrays have the same length (if not something is not good 
    # for this machine
    if ( @xml_disks != @backend_source_files )
    {
        # Log the error and return 
        logger("error","Backend and XML descirption are not synchronized "
              ."concerning the number of disks");
        return Provisioning::Backup::KVM::Constants::BACKEND_XML_UNCONSISTENCY;
    }

    # Yes same number of disks found, now check if they are the same: Go through
    # all disks found in the backend and check if they are also present in the 
    # xml
    my $match = 0;
    foreach my $backend_disk ( @backend_source_files )
    {
        # Check if the disk is also in the other array
        $match++ if grep {$backend_disk eq $_ } @xml_disks; 

    }

    # Test if the number of matched items is equal to the number of disk images
    # found, if yes, everything is of, if not, something is wrong
    if ( $match == @backend_source_files )
    {
        # Log it and return the disk images
        logger("info","Backend and XML description are synchronized concerning"
              ." the disks");
        return @backend_source_files;
    }

    # There were some disks that were not found in the xml: 
    logger("error","Some disks specified in the backend were not found in the "
          ."XML description. Solve this issue to create a backup for this "
          ."machine");

    return Provisioning::Backup::KVM::Constants::BACKEND_XML_UNCONSISTENCY;
}


1;

__END__

=pod

=cut
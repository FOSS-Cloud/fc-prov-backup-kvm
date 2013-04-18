package Provisioning::Backup::KVM::Util;

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

our @ISA = qw(Exporter);

our %EXPORT_TAGS = ( 'all' => [ qw(setPermissionOnFile createDirectory getMachineByBackendEntry getConfigEntry getDiskImagesByMachine restoreVMFromStateFile defineAndStartMachine defineMachine startMachine getIntermediatePath) ] );

our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

our @EXPORT = qw(setPermissionOnFile createDirectory getMachineByBackendEntry getConfigEntry getDiskImagesByMachine restoreVMFromStateFile defineAndStartMachine defineMachine startMachine getIntermediatePath);

our $VERSION = '0.01';

# Provisioning libs
use Provisioning::Backup::KVM::Constants;
use Provisioning::Log;

# Other libs
use Module::Load;
use Sys::Virt;
use Config::IniFiles;
use XML::Simple;
use POSIX;
use Switch;
use File::Basename;

# Load variable libs:
# Backend
load "$Provisioning::server_module", ':all';
# TransportAPI
load "Provisioning::TransportAPI::$Provisioning::TransportAPI", ':all';


################################################################################
# getMachineByBackendEntry
################################################################################
# Description:
#  
################################################################################

sub getMachineByBackendEntry
{

    my ( $vmm, $entry, $backend ) = @_;

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
        case "File" {
                        # The name of the machine is simply the $entry we get
                        $name = $entry;
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
# getMachineByBackendEntry
################################################################################
# Description:
#  
################################################################################

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
# getDiskImagesByMachine
################################################################################
# Description:
#  
################################################################################

sub getDiskImagesByMachine
{
    my ($machine, $entry, $machine_name, $backend) = @_;

    # First of all get the disk images from the LDAP, to do that, we need the 
    # grandparent entry which will be the machine entry
    my $machine_entry = getParentEntry( getParentEntry( $entry ) );

    # Get the dn from the machine entry
    my $machine_dn;
    switch( $backend )
    {
        case "LDAP" {
                        $machine_dn = getValue($machine_entry, "dn");
                    }
        case "File" {
                        $machine_dn = getValue($machine_name, "dn");
                    }
    }
    

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


################################################################################
# defineAndStartMachine
################################################################################
# Description:
#  
################################################################################

sub restoreVMFromStateFile
{

    my ($state_file, $xml_file, $vmm) = @_;

    my $error = 0;

    # Log what we are doing
    logger("debug","Restoring machine from state file $state_file");

    # Handle the dry_run case, here no files are at retain location so simply 
    # restore the machine form the state file: 
    if ( $dry_run )
    {
        print "DRY-RUN:  virsh restore $state_file\n\n";
        return Provisioning::Backup::KVM::Constants::SUCCESS_CODE;
    }

    # First of all check if the machine was running when it was backed up
    if ( !open( STATE_FILE, "$state_file") )
    {
        # Log that we cannot open the file for reading and return
        logger("error","Cannot open state file ($state_file) for reading, "
              ."please make sure it has correct permission");
        return Provisioning::Backup::KVM::Constants::CANNOT_READ_STATE_FILE;

    } else
    {
        # If the first line of the file is the fake state file text, it means
        # the machine was shut down when it was backed up, so just define and 
        # start the machine
        if ( <STATE_FILE> eq Provisioning::Backup::KVM::Constants::FAKE_STATE_FILE_TEXT )
        {

            # Log it and define and start the machine
            logger("info","Machine was not running when it was backed up, going"
                  ." to define and start it");

            $error = defineAndStartMachine($xml_file, $vmm);
            
            # Test if there was an error
            if ( $error )
            {
                # Log it and return 
                logger("error","Could not define and start the machine");
                return $error;
            } else
            {
                # Log and return
                logger("info","Successfully defined and started machine");
                return $error;
            }
        } # end if <STATE_FILE> eq FAKE_STATE_FILE_TEXT

        close STATE_FILE;

    } # end else from if !open( STATE_FILE, "$state_file")

    # Reaching this point means the machie was running when backed up and the 
    # state file is readable, so simply restore the machine form this state file
    eval
    {
        $vmm->restore_domain($state_file);
    };

    my $libvirt_err = $@;
               
    # Test if there was an error
    if ( $libvirt_err )
    {
        my $error_message = $libvirt_err->message;
        $error = $libvirt_err->code;
        logger("error","Error from libvirt (".$error
              ."): libvirt says: $error_message. Cannot restore machine");
        return $error;
    }

    # Log and return success
    logger("info","Machine successfully restored");
    return $error;

}

################################################################################
# defineAndStartMachine
################################################################################
# Description:
#  
################################################################################

sub defineAndStartMachine
{

    my ($xml_file, $vmm) = @_;

    # Define some vars
    my $error = 0;
    my $machine_object;
    my $machine_name;

    # Define the machine, if everything is ok, we get the machine object which
    # we can start afterwards
    ( $error, $machine_object ) = defineMachine( $xml_file, $vmm );

    # Test if the machine could be defined
    if ( $error )
    {
        # Log it and return 
        logger("error","Machine could not be defined from XML file $xml_file, "
              ."cannot start machine");
        return $error;
    }

    # If everything was fine and the machine could be defiend, we can start it
    ( $error, $machine_name) = startMachine( $machine_object );

    # Check if the machine could be started
    if ( $error )
    {
        # Log it and return 
        logger("error","The machine ($machine_name) could not be started. Since"
              ." it is already defined you can try to start it manually");
        return $error;
    }

    # If everything went fine we can simply return that
    logger("info","Successfully defined and started machine $machine_name");
    return $error;

}


################################################################################
# defineMachine
################################################################################
# Description:
#  
################################################################################

sub defineMachine
{
    my ($xml_file, $vmm) = @_;

    my $error = 0;
    my $machine_object;

    # Define the machine from the given XML file
    logger("info","Defining machine using the following XML file: $xml_file");

    # Handle the dry-run case, since the XML file is not present, we cannot open
    # and check it, so just print the command
    if ( $dry_run )
    {
        print "DRY-RUN:  virsh define $xml_file\n\n";
        return Provisioning::Backup::KVM::Constants::SUCCESS_CODE,"";
    }

    my $xml_fh;
    if ( !open($xml_fh,"$xml_file") )
    {
        # Log it and return
        logger("errro","Cannot open XML file ($xml_file) for reading. Make sure"
              ."it has correct permission");
        return Provisioning::Backup::KVM::Constants::CANNOT_READ_XML_FILE;
    }
    
#    # Create an XML object form the filehandler
#    my $xml_object = XMLin($xml_fh, ForceArray => 1);
#
#    # Close the FH
#    close $xml_fh;
#
#    # Get the XML string from the xml file
#    my $xml_string = XMLout($xml_object, RootName => 'domain');

    # Since the XML lib does some strange thing we gonna read the file ourself
    my $xml_string = "";
    my $line;
    while ( <$xml_fh> )
    {
        # Recover the line, we need to to some things on it
        $line = $_;
        
        # Remove the newline at the end
        chomp($line);
      
        # Remove all whitespaces at the beginning of the line
        $line =~ s/^\s*//;

        # Add he line the the xml string
        $xml_string .= $line;
    }

    # Execute the libvirt command using the libvirt API
    eval
    {
        $machine_object = $vmm->define_domain($xml_string);
    };
               
    # Test if there was an error
    my $libvirt_err = $@;
    if ( $libvirt_err )
    {
        my $error_message = $libvirt_err->message;
        $error = $libvirt_err->code;
        logger("error","Error from libvirt (".$error
              ."): libvirt says: $error_message.");
        return Provisioning::Backup::KVM::Constants::CANNOT_DEFINE_MACHINE,"";
    }

    # If everything went fine return the object which represents the machine
    logger("info","Machine succesfully defined");
    return $error,$machine_object;

}

################################################################################
# startMachine
################################################################################
# Description:
#  
################################################################################

sub startMachine
{

    my $machine_object = shift;

    my $error = 0;

    # Handle the dry-run case, since the XML file is not present, we cannot open
    # and check it, so just print the command
    if ( $dry_run )
    {
        print "DRY-RUN:  virsh start <MACHINE_NAME>\n\n";
        return Provisioning::Backup::KVM::Constants::SUCCESS_CODE;
    }

    # First of all test if the machine object is defined
    if ( !$machine_object )
    {
        # Log it and return 
        logger("error","The machine object which was passed to the method start"
              ."Machine in KVMRestore.pm is not valid, cannot start it");
        return Provisioning::Backup::KVM::Constants::CANNOT_WORK_ON_UNDEFINED_OBJECT;
    }

    # Get the machine name
    my $machine_name;
    eval
    {
        $machine_name = $machine_object->get_name();
    };
               
    # Test if there was an error
    my $libvirt_err = $@;
    if ( $libvirt_err )
    {
        my $error_message = $libvirt_err->message;
        $error = $libvirt_err->code;
        logger("warinig","Error from libvirt (".$error
              ."): libvirt says: $error_message. Cannot get machines name");
        $machine_name = "unknown";
    }

    # Simply start the machine
    logger("info","Starting machine $machine_name");

    eval
    {
        $machine_object->create();
    };
               
    # Test if there was an error
    $libvirt_err = $@;
    if ( $libvirt_err )
    {
        my $error_message = $libvirt_err->message;
        $error = $libvirt_err->code;
        logger("error","Error from libvirt (".$error
              ."): libvirt says: $error_message. Cannot start the machine "
              .$machine_name);
        return Provisioning::Backup::KVM::Constants::CANNOT_START_MACHINE;
    }

    # If everything went fine, log it and return 
    logger("info","Successfully started machine $machine_name");
    return $error;

}

################################################################################
# getIntermediatePath
################################################################################
# Description:
#  
################################################################################

sub getIntermediatePath
{

    my ( $image_path, $machine_name, $entry, $backend ) = @_;

    # Remove the /var/virtualization in front of the path
    $image_path =~ s/\/var\/virtualization\///;

    # Get the path to the image ( without image itself)
    my $path = dirname( $image_path );

    # Get the backup date
    my $backup_date;
    if ( $backend eq "LDAP" )
    {
        $backup_date = getValue($entry,"ou");
    } else
    {
        $backup_date = getValue($entry,"Backup_date");

        # If there is no such backup date, take the current date
        if ( ! $backup_date )
        {
            $backup_date = strftime("%Y%m%d",localtime())."010000";
            chomp($backup_date); 
            logger("warning","Could not find the backup-date in the file "
                  ."backend, taking the following: $backup_date");
        }
    }

    # add the machine name and the backup date to the path
    $path .= "/".$machine_name."/".$backup_date;

    # Log the intermediat path
    logger("debug","Intermediate path set to $path");

    # Return now the dirname of the file
    return $path;

}

################################################################################
# createDirectory
################################################################################
# Description:
#  
################################################################################

sub createDirectory
{
    my  ($directory, $config_entry) = @_;

    # Check if the directory is something defined and not an empty string
    if ( $directory eq "" )
    {
        logger("error","Cannot create undefined directory");
        return Provisioning::Backup::KVM::Constants::CANNOT_CREATE_DIRECTORY;
    }

    # Check if the parent directory exists, if not we need also to create this 
    # one. So spilt the directory into its parts and remove the last one
    my @parts = split( "/", $directory );
    pop( @parts );

    # The parent directory now is the parts put together again
    my $parent_dir = join( "/", @parts );

    # Test if this directory exists, if not create it
    createDirectory ( $parent_dir, $config_entry ) unless ( -d $parent_dir );

    # OK parent directory exists, we can create the actual directory

    # Generate the commands to create the directory
    my @args = ( "mkdir", "'$directory'" );

    # Execute the command
    my ($output , $command_err) = executeCommand( $gateway_connection, @args );

    # Check if there was an error
    if ( $command_err )
    {
        # Write log and return error 
        logger("error","Cannot create directory $directory: $output");
        return Provisioning::Backup::KVM::Constants::CANNOT_CREATE_DIRECTORY;
    }

    # If there was no error, change the owenership and the permission
    my $owner = getValue($config_entry, "sstVirtualizationDiskImageDirectoryOwner");
    my $group = getValue($config_entry, "sstVirtualizationDiskImageDirectoryGroup");
    my $permission = getValue($config_entry, "sstVirtualizationDiskImageDirectoryPermission");

        # Change ownership, generate commands
    @args = ('chown', "$owner:$group", $directory);

    # Execute the commands:
    ($output , $command_err) = executeCommand( $gateway_connection , @args );

    # Test whether or not the command was successfull: 
    if ( $command_err )
    {
        # If there was an error log what happend and return 
        logger("error","Could not set ownership for directory '$directory':"
               ." error: $command_err" );
        return Provisioning::Backup::KVM::Constants::CANNOT_SET_DIRECTORY_OWNERSHIP;
    }

    # Change ownership, generate commands
    @args = ('chmod', $permission, $directory);

    # Execute the commands:
    ($output , $command_err) = executeCommand( $gateway_connection , @args );

    # Test whether or not the command was successfull: 
    if ( $command_err )
    {
        # If there was an error log what happend and return 
        logger("error","Could not set permission for directory '$directory'"
               .": error: $command_err" );
        return Provisioning::Backup::KVM::Constants::CANNOT_SET_DIRECTORY_PERMISSION;
    }

    # Success! Log it and return
    logger("debug", "Directory $directory successfully created");
    return  Provisioning::Backup::KVM::Constants::SUCCESS_CODE;

}

################################################################################
# setPermissionOnFile
################################################################################
# Description:
#  
################################################################################

sub setPermissionOnFile
{

    my ( $config_entry, $file ) = @_;

    my $error = 0;

    # Set correct ownership and permission
    # Get the owner group and permission
    my $owner = getValue($config_entry,"sstVirtualizationDiskImageOwner");
    my $group = getValue($config_entry,"sstVirtualizationDiskImageGroup");
    my $permission = getValue($config_entry,"sstVirtualizationDiskImagePermission");
    my $output;

    # chown owner:group state_file
    my @args = ("chown","'$owner':'$group'",$file);
    ($output, $error) = executeCommand($gateway_connection, @args);
        
    # Log the error if there is one
    if ( $error )
    {
        logger("warning","Could not set correct ownership for file $file");
    }

    # chmod permission state_file
    @args = ("chmod",$permission,$file);
    ($output, $error) = executeCommand($gateway_connection, @args);
        
    # Log the error if there is one
    if ( $error )
    {
        logger("warning","Could not set correct permission for file $file");
    }

    return;

}

1;
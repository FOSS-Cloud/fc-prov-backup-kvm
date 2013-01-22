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
use Provisioning::Backup::KVM::Util;

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

    # The machines name
    my $machine_name;

    my $machine = getMachineByBackendEntry( $vmm, $entry, $backend );

    # Check if the machine could be found or not
    if ( !$machine )
    {
        # Log it and get the machine name from the backend
        logger("info","Did not find machine according to the backend entry,"
              ." machine seems to be completly down");

        # Get the machines name
        # First of all get the entrys grand-parent entry (machine-entry)
        my $machine_entry = getParentEntry( getParentEntry( $entry ) );
        $machine_name = getValue( $machine_entry, "sstVirtualMachine" );

    } else
    {
        $machine_name = getMachineName($machine);
    }
    
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

    # TODO if the disk images cannot be found we need to get the intermediate 
    # path somehow else...

    # Now we can get all disk images from the backend
    my $machine_entry_for_disks = getParentEntry( getParentEntry( $entry ) );

    # Get the dn from the machine entry
    my $machine_dn = getValue($machine_entry_for_disks, "dn");

    # Search for all objects under the machine dn which are sstDisk
    my @backend_disks = simpleSearch($machine_dn,
                                     "(&(objectclass=sstVirtualizationVirtualMachineDisk)(sstDevice=disk))",
                                     "sub"
                                    );

    # Now get all the disk image pathes from the backend entries
    my @disk_images = ();
    foreach my $backend_disk ( @backend_disks )
    {
        # Get the value sstSourceFile and add it to the backend_source_files 
        # array
        push( @disk_images, getValue( $backend_disk,"sstSourceFile") );
    }

#    # Check the return code
#    if ( $disk_images[0] == Provisioning::Backup::KVM::Constants::BACKEND_XML_UNCONSISTENCY )
#    {
#        # Log the error and return
#        logger("error","The disk information for machine $machine_name is not "
#              ."consistent between XML description and backend. Solve this "
#              ."inconsistency before creating a backup");
#        return Provisioning::Backup::KVM::Constants::BACKEND_XML_UNCONSISTENCY;
#    }

    # Get and set the intermediate path for the given machine
    $intermediate_path = getIntermediatePath( $disk_images[0], $machine_name, $entry );

    # Test what kind of state we have and set up the appropriate action
    switch ( $state )
    {
        case "unretaining" {    
                                my $error = 0;

                                # First of all, get the files from the backup
                                # location and copy them to the retain location
                                $error = getFilesFromBackupLocation( $config_entry, $entry, $machine_name, $cfg, $config_entry);

                                # Check if there were errors
                                if ( $error != SUCCESS_CODE )
                                {
                                    # Log the error and return
                                    logger("error","Could not get the files "
                                          ."from the backup location: $error");
                                    return $error;
                                    
                                }

                                # Now check if we have all all necessary files
                                # in the retain location
                                my $retain_location = getValue( $config_entry, "sstBackupRetainDirectory");
                                
                                # Add the intermediate path to the reatin 
                                # location
                                $retain_location .= "/".$intermediate_path;

                                # Remove the file:// in front of the retain
                                # location
                                $retain_location =~ s/file\:\/\///;

                                my ( $have_all_files, @retain_files ) = checkCompletness( $cfg, $config_entry, $machine_name, $retain_location);

                                # If we don't have all files, so log it and 
                                # return
                                if ( $have_all_files != SUCCESS_CODE )
                                {
                                    # Log it and return 
                                    logger("error","Not all necessary files "
                                          ."to restore machine $machine_name "
                                          ."are at backup location. Cannot "
                                          ."continue");
                                    return Provisioning::Backup::KVM::Constants::MISSING_NECESSARY_FILES;
                                }

                                # And finally check the disk images for
                                # healthiness
                                if ( checkDiskImages($config_entry, @retain_files) != SUCCESS_CODE )
                                {
                                    # Log it and return 
                                    logger("error","Cannot restore machine "
                                          ."$machine_name because one of the "
                                          ."disk images is not healthy!");
                                    return Provisioning::Backup::KVM::Constants::CORRUPT_DISK_IMAGE_FOUND;
                                }

                                # Ok so far everything is fine, write that the 
                                # unretain process is finished
                                modifyAttribute (  $entry,
                                                   "sstProvisioningMode",
                                                   "unretained",
                                                   $backend_connection,
                                                 );

                               
                                return $error;

                            } # End case snapshotting

        case "restoring"    { # Restore the vm

                                my $error = 0;
                                my $output;
                                
                                # Get the retain location
                                my $retain_location = getValue($config_entry,
                                                    "sstBackupRetainDirectory");

                                # Remove the file:// in front of the retain 
                                # location
                                $retain_location =~ s/file\:\/\///;

                                # Add the itermediate path to the retain 
                                # location
                                $retain_location = $retain_location."/"
                                                  .$intermediate_path;

                                # Get the backup date
                                my $backup_date = getValue($entry,"ou");

                                # Log what we are doing: 
                                logger("debug","Moving disk image(s) back to "
                                      ."the original location" );

                                # Get the disk images names:
                                foreach my $image ( @disk_images )
                                {
                                    # Get the basename for the current image
                                    my $image_name = basename ( $image );

                                    # Now we can move the disk image form the
                                    # retain location to it's original location
                                    $image_name = $retain_location."/"
                                                 ."/".$image_name.".backup."
                                                 .$backup_date;

                                    # Move the disk image
                                    my @args = ( "mv", $image_name, $image );
                                    ($output, $error ) = executeCommand( $gateway_connection, @args );
                                    
                                    # Check if there was an error
                                    if ( $error )
                                    {
                                        # Log it and return 
                                        logger("error","Cannot move disk image"
                                              ." $image_name to its original "
                                              ."location");
                                        return Provisioning::Backup::KVM::Constants::CANNOT_MOVE_DISK_IMAGE_TO_ORIGINAL_LOCATION;
                                    }
                                } # end foreach

                                # Test if we need to restore from state file
                                my $restore_without_state = getValue($config_entry,"sstRestoreVMWithoutState");
                                if ( $restore_without_state =~ m/false/i )
                                {
                                    # Restore with state, restore the VM from 
                                    # state file in retain location
                                    my $state_file = $retain_location
                                                    ."/".$machine_name.".state"
                                                    .".".$backup_date;

                                    my $xml_file = $retain_location."/"
                                                  .$machine_name.".xml."
                                                  .$backup_date;

                                    $error= restoreVMFromStateFile($state_file, $xml_file ,$vmm);
                                    
                                    # Test if there was an error
                                    if ( $error )
                                    {
                                        # Log it and check if machine should be 
                                        # started normally
                                        my $start_normally = getValue( $entry, "sstVirtualizationVirtualMachineForceStart" );
                                        if ( $start_normally =~ m/true/i )
                                        {
                                            # Log and try to start the vm 
                                            # normally
                                            logger("warning","Could not restore"
                                                  ." machine $machine_name, "
                                                  ."trying to define and start "
                                                  ."normally");

                                            $error= defineAndStartMachine($xml_file, $vmm);
                                            
                                            # Check if the machine could be 
                                            # started normally
                                            if ( $error )
                                            {

                                                # Log and return
                                                logger("error","Could not define"
                                                      ." and start the machine "
                                                      ."$machine_name");
                                                return $error;

                                            } # end if $error

                                        # end if $start_normally =~ m/true/i
                                        } else
                                        {
                                            # Log error and return 
                                            logger("error","Could not restore "
                                                  ."machine $machine_name");
                                            return $error;
                                        } # end else form if $start_normally =~ m/true/i 

                                    } # end if $error
                                
                                # end $restore_without_state =~ m/false/i
                                } else
                                {
                                    # Start the VM, define it from XML in retain
                                    # location and start it
                                    my $xml_file = $retain_location."/"
                                                  .$machine_name.".xml."
                                                  .$backup_date;
                                    $error = defineAndStartMachine( $xml_file, $vmm);

                                    # Check if there was an error
                                    if ( $error ) 
                                    {

                                        # Log it and return the error
                                        logger("error","Could not define and "
                                              ."start the machine $machine_name"
                                              );
                                        return $error;

                                    } # end if $error

                                } # end else form if $restore_without_state =~ m/false/i
                                
                                # Log that we are done
                                logger("debug","Machine $machine_name "
                                      ."successfully restored");

                                # Delete the retain directory
                                logger("debug","Deleting retain directory "
                                      .$retain_location);

                                # Generate the commands and remove the files
                                my @args = ("rm","-rf","'$retain_location'");
                                ( $output, $error ) = executeCommand($gateway_connection, @args);

                                # Check if there was an error
                                if ( $error )
                                {
                                    logger("warning","Could not remove all "
                                          ."files from retain location: "
                                          .$retain_location.": ".$output);
                                    $error = Provisioning::Backup::KVM::Constants::NOT_ALL_FILES_DELETED_FROM_RETAIN_LOCATION;
                                }

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
# getFilesFromBackupLocation
################################################################################
# Description:
#  
################################################################################

sub getFilesFromBackupLocation
{

    my ( $config, $entry, $machine_name, $cfg, $config_entry ) = @_;

    my $error = 0;

    # Log what we are doing
    logger("debug","Getting files from backup location for machine "
          ."$machine_name");

    # Local variables for this method
    my $get_command;
    my $backup_date = getValue($entry, "ou");
    my $backend_file;
    my $output;

    # Get the retain and backup location
    my $backup_location = getValue( $config, "sstBackupRootDirectory");
    my $retain_location = getValue( $config, "sstBackupRetainDirectory");

    # Get the protocol how to get the files from backup server
    $backup_location =~ m/([\w\+]+\:\/\/)([\w\/]+)/;
    $backup_location = $2;
    my $protocol = $1;

    

    # Also get the protocol how to put the files on the retain location 
    # (at the moment only file:// is allowed here)
    $retain_location =~ s/file\:\/\///;

    # Add the intermediate path to the retain location
    $retain_location .= "/".$intermediate_path;

    # Switch the protocol ( at the moment only file:// is supported )
    switch ( $protocol )
    {
        case 'file://' {
                        # Use cp -p to get the files (they are on the same 
                        # physical machine
                        $get_command = "cp -p";
                       }
        else           {
                        # ooups we don't know, support this protocol
                        logger("error","The protocol $protocol is not know/"
                              ."supported for getting the files from backup "
                              ." location: $backup_location");
                        return Provisioning::Backup::KVM::Constants::UNSUPPORTED_FILE_TRANSFER_PROTOCOL;
                       } # end case default
    }

    # Log the get command
    logger("debug","The command to get the files from the backup location will"
          ." be: $get_command");

    # Get the name of the backend fle
    switch ( $cfg->val("Database","BACKEND") )
    {
        case "LDAP" {
                        # Backend file name is ldif
                        $backend_file = "ldif";
                    }
        case "File" {
                        $backend_file = "export";
                    }
        else        {
                        # Ooups we don't know this type
                        logger("error","The backend type ".$cfg->val("Database",
                               "BACKEND")."is not known, cannot get the "
                              ."cbacked up backend file");
                        return Provisioning::Backup::KVM::Constants::UNKNOWN_BACKEND_TYPE;
                    }
    }

    # Now we can get the files from the backup location and put them to the
    # retain location, using the get command we got from according to the 
    # protocol. 
    # First we only get the XML, backend file and state file because there we
    # now the name. We will then use the XML file to get the disk image names 
    # and get them later
    my @files = ("$backup_location/$intermediate_path/$machine_name.xml.$backup_date",
                 "$backup_location/$intermediate_path/$machine_name.state.$backup_date",
                 "$backup_location/$intermediate_path/$machine_name.$backend_file.$backup_date",
                );

    # Open the XML description and get all disk images
    # Create a sting out of the whole xml file:
    my $xml_fh;
    if ( ! open($xml_fh,"$backup_location/$intermediate_path/$machine_name.xml.$backup_date") )
    {
        # Log the error and return 
        logger("error","Cannot read from XML file: $backup_location/"
              ."$intermediate_path/$machine_name.xml.$backup_date, cannot get "
              ."disk images for machine $machine_name");

        return Provisioning::Backup::KVM::Constants::CANNOT_READ_XML_FILE;
    }

    # Will be used to go through the xml
    my $i = 0;

    # Initialize the XML-object from the string
    my $xml = XMLin( $xml_fh,
                     KeepRoot => 1,
                     ForceArray => 1
                   );

    # Close the FH
    close $xml_fh;

    # The array to push all disk images from the xml
    my @disks;

    # Go through all domainsnapshot -> domain -> device -> disks
    while ( $xml->{'domain'}->[0]->{'devices'}->[0]->{'disk'}->[$i] )
    {
        # Check if the disks device is disk and not cdrom, we want the disk
        # image path !
        if ( $xml->{'domain'}->[0]->{'devices'}->[0]->{'disk'}->[$i]->{'device'} eq "disk" )
        {
            # Get the disk image name and put it in the the array
            push( @disks, basename($xml->{'domain'}->[0]->{'devices'}->[0]->{'disk'}->[$i]->{'source'}->[0]->{'file'}) );
        }

        # If it's not the disk disk, try the next one
        $i++;
    }

    # Add all the disks to the files adding the suffix ".backup.$backup_date"
    foreach my $disk (@disks)
    {
        # Get the disks filename
        $disk = basename($disk);

        # Add the backup directory in front to the disk name
        $disk = "$backup_location/$intermediate_path/".$disk;

        # Add it to the array
        push( @files, $disk.".backup.$backup_date");
    }
    
    # Check if the retain location exists if not, create it
    unless ( -d $retain_location )
    {
        $error = createDirectory( $retain_location, $config_entry );
        
        # Test it there was an error
        if ( $error != SUCCESS_CODE )
        {
            # Log it and return 
            logger("error","Could not create retain location for current backup"
                  ." ($retain_location). Fix this first before continuing with "
                  ." the restore process");
            return Provisioning::Backup::KVM::Constants::CANNOT_CREATE_DIRECTORY;
        }
    }

    # Ok so far we have all files we need to bring to the backup location:
    foreach my $file ( @files )
    {
        logger("debug","Getting file $file from backup location");
        
        # Copy the file to the retain location using the transport api and the 
        # get command
        my @args = ( $get_command, $file, $retain_location );
        ( $output, $error ) = executeCommand( $gateway_connection, @args );

        # Check if there was an error
        if ( $error )
        {
            # Log the error and continue
            logger("warning","Cannot get file $file to retain location "
                  ."$retain_location using command $get_command: $output");
        }
    }

    # At this point we have copied the files to the retain location ( even if 
    # a file could not be transfered we return success, this will be handled 
    # later )
    return SUCCESS_CODE;

}

################################################################################
# checkCompletness
################################################################################
# Description:
#  
################################################################################

sub checkCompletness
{
    my ( $cfg, $config, $machine_name, $retain_location ) = @_;

    my $error = 0;

    # Log what we are doing
    logger("debug","Checking if all necessary files are present in retain "
          ."location");

    # Get the disk image format
    my $format = getValue($config, "sstVirtualizationDiskImageFormat");

    # The name of the backend file type
    my $backend;
    
    # switch the backend cases
    switch ( $cfg->val("Database","BACKEND") )
    {
        case "LDAP" {
                        $backend = "ldif";
                    }
        case "File" {
                        $backend = "export";
                    }
        else        {
                        # This is an error, log it and return
                        logger("error","Unknown/unsupported backend type: "
                              .$cfg->val("Database","BACKEND") );
                        return Provisioning::Backup::KVM::Constants::UNKNOWN_BACKEND_TYPE;
                    }
    }

    # Get all files at location
    my @retain_files;
    while ( <$retain_location/*> )
    {
        push( @retain_files, $_ );
    }

    # Create a list of what we need to check 
    my @check_list = ("$machine_name.xml","$machine_name.$backend",
                      "$machine_name.state","$format.backup");

    # A list of all files we have found at the retain location
    my @retain_files_found;

    # Go through the check list and check if we have the file
    foreach my $item ( @check_list )
    {
        # Set found to zero 
        my $found = 0;

        # Go through all files in the retain direcotry
        foreach my $file ( @retain_files )
        {
            # Check if the file matches the item
            if ( $file =~ m/$item/ )
            {
                $found = 1;
                push ( @retain_files_found, $file );
                last;
            }
        }

        # Check if we have that file in the files list if not return it
        unless ( $found )
        {
            # TODO only return if its state or qcow
            # Log it and return 
            logger("error","Cannot find the following item in the retain "
                  ."location: $item.*");
            return Provisioning::Backup::KVM::Constants::MISSING_NECESSARY_FILES;
        } else
        {
            # Log that the item was found
            logger("debug","Found $item.* in retain directory");
            
        }
    }

    # OK all files are present
    logger("debug","All necessary files are present in retain location for "
          ."machine $machine_name");

    return SUCCESS_CODE,@retain_files_found;


}

################################################################################
# checkDiskImages
################################################################################
# Description:
#  
################################################################################

sub checkDiskImages
{
    my ($config, @retain_files ) = @_;

    # Log what we are doing
    logger("debug","Checking disk images for healthiness");

    # Get the disk image format
    my $format = getValue($config, "sstVirtualizationDiskImageFormat");

    if ( $format ne "qcow2" )
    {
        # The check does not support this format (only qcow2 is supported)
        logger("warning","Unfortunatly the image format $format is not "
              ."supported, cannot perform the consistency check");
        return SUCCESS_CODE;
    }

    # Create a counter to remember how many files we have checked
    my $counter = 0;

    # Go through all files if it is a disk image check it
    foreach my $file (@retain_files)
    {
        # Check if it is a disk image file
        if ( $file =~ m/$format/ )
        {
            # Checking disk image!
            $counter++;

            # Generate the command
            my @args = ("qemu-img","check","-f","'$format'","'$file'");
            my ( $output, $error ) = executeCommand($gateway_connection, @args);

            # remove the newline at the end of the output
            chomp($output);

            # Check if the output is: No errors were found on the image. Then 
            # Everything is ok
            if ( $output ne "No errors were found on the image." && !$dry_run )
            {
                # Log what went wrong and return
                logger("error","Found a disk image which is not consistent: "
                      ."$file: $output");
                return Provisioning::Backup::KVM::Constants::CORRUPT_DISK_IMAGE_FOUND;
            } else
            {
                # Log that the disk image is clean
                logger("debug","Disk image $file is healthy");
            }
        }
        
    }

    # If the counter is not bigger or equal to 1 we did not check a single file
    # what is a little bit strange
    unless ( $counter >= 1 )
    {
        # Log it 
        logger("warning","Did not check a single disk image, seems as non of "
              ."the following files matched the disk image format $format: "
              ."@retain_files");
    }

    # Log that all disk images are healthy
    logger("info","All checked disk images are found healthy, everything OK");

    return SUCCESS_CODE;
}

1;

__END__

=pod

=cut

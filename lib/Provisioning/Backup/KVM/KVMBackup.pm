package Provisioning::Backup::KVM::KVMBackup;

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

our %EXPORT_TAGS = ( 'all' => [ qw(backup createNewLibvirtConnection returnIntermediatePath) ] );

our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

our @EXPORT = qw(backup createNewLibvirtConnection returnIntermediatePath);

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
# backup
################################################################################
# Description:
#  
################################################################################

sub backup
{

    my ($state, $entry , $backend_connection , $cfg ) = @_;

    # Initialize the var to return any error, initially it is 0 (no error)
    my $error = 0;

    # Get the machine according the the backend entry:
    my $backend = $cfg->val("Database","BACKEND");

    my $machine = getMachineByBackendEntry($vmm, $entry, $backend );

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
    my @disk_images = getDiskImagesByMachine( $machine, $entry, $machine_name, $backend );

    # Check the return code
    if ( $disk_images[0] =~ m/^\d+$/ && $disk_images[0] == Provisioning::Backup::KVM::Constants::BACKEND_XML_UNCONSISTENCY )
    {
        # Log the error and return
        logger("error","The disk information for machine $machine_name is not "
              ."consistent between XML description and backend. Solve this "
              ."inconsistency before creating a backup");
        return Provisioning::Backup::KVM::Constants::BACKEND_XML_UNCONSISTENCY;
    }

    # Get and set the intermediate path for the given machine
    $intermediate_path = getIntermediatePath( $disk_images[0], $machine_name, $entry, $backend );

    # Test what kind of state we have and set up the appropriate action
    switch ( $state )
    {
        case "snapshotting" {   # Measure the start time:
                                my $start_time = time;

                                # we'll use that later
                                my $retain_directory;

                                # Was the machine running before the backup?
                                my $running_before_snapshot = machineIsRunning($machine, $machine_name);

                                # Create a snapshot of the machine
                                # Save the machines state
                                my $state_file;
                                ( $state_file, $error ) = 
                                saveMachineState( $machine,
                                                  $machine_name,
                                                  $config_entry
                                                 );

                                if ( $error )
                                {
                                    # Log the error
                                    logger("error","Saving machine state for "
                                          ."$machine_name failed with "
                                          ."error code: $error");

                                    # If error is -1 it means that we could not
                                    # create the fake state file, so simply
                                    # return
                                    return Provisioning::Backup::KVM::Constants::CANNOT_SAVE_MACHINE_STATE if ( $error == -1 );

                                    # Test if machine is running, if not start
                                    # it!
                                    my $running;
                                    eval
                                    {
                                        $running = $machine->is_active();
                                    };

                                    # Test if there was an error, if yes log it
                                    my $libvirt_error = $@;
                                    if ( $libvirt_error )
                                    {
                                        logger("error","Could not check machine"
                                              ." state (running or not) for "
                                              ."machine $machine_name, libvirt "
                                              ."says: '".$libvirt_error->message
                                              ."'. Please "
                                              ."execute the following command "
                                              ."on ".hostname." to check "
                                              ."whether or not the machine is "
                                              ."running: virsh list --all"
                                              );

                                        # Set running to true to avoid that
                                        # libvirt tries to start an already 
                                        # started domain
                                        $running = 1;
                                    }
                                    
                                    # If the machine is not running, start it
                                    unless ( $running )
                                    {
                                        # Start the machine
                                        eval
                                        {
                                            $machine->create();
                                        };

                                        # Test if there was an error
                                        my $libvirt_error = $@;
                                        if ( $libvirt_error )
                                        {
                                            logger("error","Could not start the"
                                                  ." machine $machine_name. "
                                                  ."Libvit says: ".
                                                  $libvirt_error->message
                                                  );
                                        }
                                        
                                    }

                                    # Return that the machines state could not
                                    # be saved
                                    return Provisioning::Backup::KVM::Constants::CANNOT_SAVE_MACHINE_STATE;
                                }

                                # Success, log it!
                                logger("debug","Machines ($machine_name) state "
                                       ."successfully saved to $state_file");


                                # Rename the original disk image and create a 
                                # new empty one which will  be used to write 
                                # further changes to.
                                $error = changeDiskImages( $machine_name , 
                                                           $config_entry ,
                                                           @disk_images );

                                # Check if there was an error
                                if ( $error )
                                {
                                    # Log the error
                                    logger("error","Changing disk images for "
                                          ."$machine_name failed with error "
                                          ."code: $error");

                                    # Try to restore the VM if this is not
                                    # successful log it but return the previous
                                    # error!
                                    if ( $running_before_snapshot )
                                    {

                                        logger("info","Trying to restore the VM "
                                              .$machine_name);


                                        if ( restoreVM($machine_name,$state_file) )
                                        {
                                            logger("error","Could not restore VM "
                                                  ."$machine_name!!!"
                                                  );
                                        }


                                        # Return the error
                                        return $error;
                                    }
                                }

                                # Success log it
                                logger("debug","Successfully changed the disk "
                                      ."images for machine $machine_name");

                                if ( $running_before_snapshot )
                                {
                                    # Now we can restore the VM from the saved state
                                    if ($error=restoreVM($machine_name,$state_file))
                                    {
                                        # This is pretty bad, if we cannot restore 
                                        # the VM log it and set up the appropriate 
                                        # action

                                        #TODO maybe change this to disaster or fatal
                                        logger("error","Restoring machine "
                                              ."$machine_name failed with error "
                                              ."code: $error");

                                        # TODO we need to act here, what should be done?

                                        return Provisioning::Backup::KVM::Constants::CANNOT_RESTORE_MACHINE;
                                    }

                                    # Success, log it
                                    logger("debug","Machine $machine_name "
                                          ."successfully restored from $state_file");

                                } # end if machineIsRunning( $machine )
                                else 
                                {
                                    # Log that the machine is not running
                                    logger("info","Machine $machine_name is not"
                                          ." running, nothing to "
                                          ."restore");
                                }

                                # Copy the file from the ram disk to the retain
                                # location if not already there
                                $retain_directory = getValue($config_entry,
                                                   "sstBackupRetainDirectory");

                                # Remove the file:// in front of the retain
                                # directory
                                $retain_directory =~ s/file:\/\///;

                                unless ( $state_file =~ m/$retain_directory/)
                                {
                                    # Log what we are doing
                                    logger("debug","Coping state file to retain"
                                          ." directory");

                                    # Get the state file name
                                    my $state_file_name = basename($state_file);

                                    # Copy the state file to the retain location
                                    if ( $error = exportFileToLocation($state_file, "file://".$retain_directory."/".$intermediate_path, "" ,$config_entry) )
                                    {
                                        # Log what went wrong and return 
                                        # appropriate error code
                                        logger("error","Exporting save file to "
                                              ."retain direcotry failed with "
                                              ."error code $error");

                                        return Provisioning::Backup::KVM::Constants::CANNOT_COPY_STATE_FILE_TO_RETAIN
                                        
                                    } else
                                    {
                                        # Log that everything went fine
                                        logger("debug","State file successfully"
                                              ." copied to retain directory");

                                       # Remove the file from RAM-Disk
                                        deleteFile("file://".$state_file);
                                    }
                                } else
                                {
                                    # Log that the file is already where it
                                    # should be!
                                    logger("debug","State file ($state_file) "
                                          ."already at retain location, nothing"
                                          ." to do.");
                                }

                                # Save the XML of the machine
                                my $xml = $retain_directory."/".
                                          $intermediate_path."/".
                                          $machine_name.".xml";

                                # Save the XML and get back the status
                                $error = saveXMLDescription( $machine, $xml, $config_entry );

                                # Check if there was an error
                                if ( $error )
                                {
                                    # Log it and 
                                    # TODO how do we proceed here? warning and 
                                    # continue or stop
                                    logger("warning","Could not save XML for"
                                          ." machine $machine_name");
                                }

                                # Log success
                                logger("debug","XML description for machine "
                                      ."$machine_name successfully saved");

                                # Save the backend entry
                                my $backend_entry = $retain_directory."/".
                                                    $intermediate_path."/".
                                                    $machine_name.".%backend%";

                                $error = saveBackendEntry( $entry, $backend_entry, $backend, $config_entry, $cfg );

                                # Check if there was an error
                                if ( $error )
                                {
                                    # Log it and 
                                    # TODO how do we proceed here? warning and 
                                    # continue or stop
                                    logger("warning","Could not save backend "
                                          ."entry for machine $machine_name");
                                }

                                # Log success
                                logger("debug","Backend entry for machine "
                                      ."$machine_name successfully saved");

                                # Write that the snapshot process is finished
                                modifyAttribute (  $entry,
                                                   "sstProvisioningMode",
                                                   "snapshotted",
                                                   $backend_connection,
                                                 );

                                # Measure end time
                                my $end_time = time;

                                # Calculate the duration
                                my $duration = $end_time - $start_time;

                                # Write the duration to the LDAP
                                writeDurationToBackend($entry,"snapshot",$duration,$backend_connection);

                                return $error;

                            } # End case snapshotting

        case "merging"      { # Merge the disk images

                                # Measure the start time:
                                my $start_time = time;

                                # Copy the file from the ram disk to the retain
                                # location if not already there
                                my $retain_directory = getValue($config_entry,
                                                   "sstBackupRetainDirectory");

                                # Remove the file:// in front of the retain
                                # directory
                                $retain_directory =~ s/file:\/\///;

                                # Get the bandwidth in MB
                                my $bandwidth = getValue($config_entry,"sstVirtualizationBandwidthMerge");

                                # If the bandwidth is 0, it means unlimited, 
                                # since libvirt does not yet support it, set it
                                # big enough
                                $bandwidth = 2000 if ( $bandwidth == 0 );

                                foreach my $disk_image ( @disk_images )
                                {
                                    my $merge_done = 0;
                                    my $tries = 0;

                                    while ( ! $merge_done && $tries < 9 )
                                    {
                                        $error = mergeDiskImages( $machine, $disk_image, $bandwidth, $machine_name, $config_entry );
   
                                        # Check if error is 55 if yes it means
                                        # the machine was shut down while 
                                        # merging, simply restart the
                                        # merge process since the machine will
                                        # be started and merged!
                                        if ( $error > 0 )
                                        {
                                            # Log and restart merge process
                                            logger("info","Machine was shut down"
                                                  ." while merging, continue merge process");
                                             
                                            # The machine is undefined now so
                                            # define the machine again and 
                                            # restart the merge process
                                            sleep 2;
                                            my $def_xml = $retain_directory."/".
                                                          $intermediate_path."/".
                                                          $machine_name.".xml";
                                            ($error,$machine) = defineMachine( $def_xml, $vmm);
                                            if ( $error )
                                            {
                                                logger("error","Cannot define "
                                                      ."machine again, failed "
                                                      ."merging disk images");
                                                return Provisioning::Backup::KVM::Constants::CANNOT_MERGE_DISK_IMAGES;
                                            } else
                                            {
                                                $tries++;
                                            }

                                        } elsif ( $error == 0 )
                                        {
                                            # Log and continue
                                            logger("info","Merge process "
                                                  ."successfully finished");
                                            $merge_done = 1;
                                        } 

                                    } # end while ! merge_done

                                    if ( ! $merge_done )
                                    {
                                        logger("error","Cannot merge disk image"
                                              ."! Tried three times but the "
                                              ."merge process was always "
                                              ."interrupted!");
                                        return Provisioning::Backup::KVM::Constants::CANNOT_MERGE_DISK_IMAGES;
                                    }

                                } # end foreach disk

                                # Write that the merge process is finished
                                modifyAttribute (  $entry,
                                                   "sstProvisioningMode",
                                                   "merged",
                                                   $backend_connection,
                                                 );

                                # Measure end time
                                my $end_time = time;

                                # Calculate the duration
                                my $duration = $end_time - $start_time;

                                # Write the duration to the LDAP
                                writeDurationToBackend($entry,"merge",$duration,$backend_connection);

                                return $error;
                            } # End case merging

        case "retaining"    { # Retain the old files

                                # Measure the start time:
                                my $start_time = time;
                                my $output;

                                # Get the retain and backup location: 
                                my $retain_location = getValue($config_entry,
                                                    "sstBackupRetainDirectory");
                                my $backup_directory = getValue($config_entry,
                                                      "sstBackupRootDirectory");

                                # Get the protocol to export the files
                                $backup_directory =~ m/([\w\+]+\:\/\/)([\w\/]+)/;
                                $backup_directory = $2;
                                my $protocol = $1;

                                # Test if the protocol was found i.e. if the 
                                # backup directroy is set up correct
                                unless ( $protocol )
                                {
                                    logger("error","No protocol specified in "
                                          ."the sstBackupRootDirectory ("
                                          .getValue($config_entry,
                                                    "sstBackupRootDirectory")
                                          .") attribute. Please specify a "
                                          ."protocol as for example file:// or "
                                          ."similar");
                                    return Provisioning::Backup::KVM::Constants::UNSUPPORTED_CONFIGURATION_PARAMETER;
                                }

                                # Remove file:// in front to test
                                if ( $retain_location =~ m/^file\:\/\// )
                                {
                                    $retain_location =~ s/^file\:\/\///;
                                } else
                                {
                                    logger("error","The retain location must "
                                          ."be located on the same filesystem "
                                          ."as the disk images itself, so the "
                                          ."protocol for the retain location "
                                          ."must be file:// however the "
                                          ."specified retain location ("
                                          .$retain_location.") does not"
                                          );
                                    return Provisioning::Backup::KVM::Constants::UNSUPPORTED_CONFIGURATION_PARAMETER;
                                }

                                # Get disk image and state file
                                # Get the disk image
                                my @source_disk_images;
                                my $source_base_path = $retain_location."/"
                                             .$intermediate_path."/";

                                # Go through all disk images and add the disk 
                                # image name to the base path and add
                                # it to the tar disk images array
                                foreach my $disk_image ( @disk_images )
                                {
                                    # Get the name 
                                    my $disk_image_name = basename($disk_image);
                                    
                                    # Add the disk image to the array
                                    push( @source_disk_images, $source_base_path.$disk_image_name );
                                }
                                             
                                # Get the state file
                                my $state_file = $retain_location."/".
                                                 $intermediate_path."/".
                                                 $machine_name.".state";

                                # Get the xml file
                                my $xml_file = $retain_location."/".
                                               $intermediate_path."/".
                                               $machine_name.".xml";

                                # Get the backend file
                                my $backend_file = $retain_location."/".
                                                   $intermediate_path."/".
                                                   $machine_name;

                                # Add the correct backend extension: 
                                switch ( $backend )
                                {
                                    case "LDAP" { $backend_file .= ".ldif"; }
                                    else { $backend_file .= ".export"; }
                                }

                                # get the ou of the current entry to add as 
                                # suffix to the image and state file
                                my $suffix = getValue($entry,"ou");

                                # If the backend is File, we need to change the
                                # suffix
                                if ( $backend eq "File" )
                                {
                                    $suffix = strftime "%Y%m%d%H%M%S", localtime();
                                }

                                # Create an array with all tarball source files
                                my @source_files = ($state_file,
                                                    $xml_file,
                                                    $backend_file
                                                   );

                                # Add the disk images
                                push ( @source_files, @source_disk_images );

                                # Export all the source files
                                foreach my $source_file ( @source_files )
                                {
                                    if ( $error = exportFileToLocation($source_file,$protocol.$backup_directory."/".$intermediate_path,".$suffix",$config_entry))
                                    {
                                        # If an error occured log it and return 
                                        logger("error","File ('$source_file') "
                                              ."transfer to '$backup_directory"
                                              ."/$intermediate_path' "
                                              ."failed with return code: $error");
                                        return Provisioning::Backup::KVM::Constants::CANNOT_COPY_FILE_TO_BACKUP_LOCATION;
                                    }

                                    # Success, log it!
                                    logger("debug","Successfully exported file "
                                          ."$source_file for machine $machine_name"
                                          ." to '$backup_directory/"
                                          ."$intermediate_path'");

                                }

                                # And finally clean up the no longer needed 
                                # files 
                                # Go through all files in the tarball and delete
                                # them
                                foreach my $file ( @source_files )
                                {
                                    if ( $error = deleteFile( $file ) )
                                    {
                                        # If an error occured log it and return 
                                        logger("warning","Deleting file $file "
                                              ."failed with return code: $error");
                                        $error = Provisioning::Backup::KVM::Constants::CANNOT_REMOVE_FILE;
                                    } 
                                    logger("debug","File $file successfully "
                                          ."deleted");
                                }

                                # And finally remove the created retain
                                # directory (just the date directory the rest 
                                # of the directory structure will be reused 
                                # again)
                                my @args = ("rmdir",$retain_location."/".
                                                    $intermediate_path);
                                ($output,$error) = executeCommand( $gateway_connection, @args );

                                # Check if there was an error
                                if ( $error )
                                {
                                    # Log it
                                    logger("warning","Could not remove the just"
                                          ." created retain direcory: $output");
                                    $error = Provisioning::Backup::KVM::Constants::CANNOT_REMOVE_FILE;
                                }

                                # Write that the merge process is finished
                                modifyAttribute (  $entry,
                                                   "sstProvisioningMode",
                                                   "retained",
                                                   $backend_connection,
                                                 );

                                # Measure end time
                                my $end_time = time;

                                # Calculate the duration
                                my $duration = $end_time - $start_time;

                                # Write the duration to the LDAP
                                writeDurationToBackend($entry,"retain",$duration,$backend_connection);


                                # return the status
                                return $error;


                            } # End case retaining
        case "deleting"     {
                              # Delete the given backup
                              my $backup_to_delete = getValue($entry,"ou");
                              logger("info","Deleting the backup "
                                    ."$backup_to_delete for machine "
                                    ."$machine_name");

                              my $error = 0;

                              # delete the backup
                              deleteBackup($machine_name, $backup_to_delete, $config_entry, @disk_images);
                              

                              # Say that we have deleted the backup
                              modifyAttribute (  $entry,
                                                 "sstProvisioningMode",
                                                 "deleted",
                                                 $backend_connection,
                                               );

                               return $error;

                            } # end case deleting
        else                { # If nothing of the above was true we have a
                              # problem, log it and return appropriate error 
                              # code
                              logger("error","State $state is not known in "
                                    ."KVM-Backup.pm. Stopping here.");
                              return Provisioning::Backup::KVM::Constants::WRONG_STATE_INFORMATION;
                            }


    } # End switch $state
}


################################################################################
# backupSingleMachine
################################################################################
# Description:
#  
################################################################################

sub saveMachineState
{

    my ( $machine, $machine_name, $entry ) = @_;

    # What are we doing?
    logger("debug","Saving state for machine $machine_name");

    # Initialize the var to return any error, initially it is 0 (no error) 
    my $error = 0;

    # State file, this is important because it will be returned on success
    my $state_file;

    # Intialize the variable which holds the path the the state file
    my $save_state_location;

    # Get the retain location in case no ram disk is configured
    my $retain_location = getValue($entry,"sstBackupRetainDirectory");

    # Remove the file:// in front
    $retain_location =~ s/file:\/\///;

    # check if the machine is running
    my $was_running = machineIsRunning( $machine, $machine_name );

# We no longer need this because the directory gets also created
#    # Check if the retain directory as is exists 
#    unless ( -d $retain_location )
#    {
#        # If ot does not, write an log message and return
#        logger("error","Retain directory ($retain_location) does not exist"
#              ." please create it by executing the following command (script "
#              ."stopps here!): mkdir -p $retain_location" );
#        return "",Provisioning::Backup::KVM::Constants::RETAIN_ROOT_DIRECTORY_DOES_NOT_EXIST;
#    }

    # Add the intermediate path to the retain location
    $retain_location .= "/".$intermediate_path;

    # Test if the location where we should put the disk image exists
    unless ( -d $retain_location )
    {
        # Create it
        if ( createDirectory( $retain_location, $entry ) != SUCCESS_CODE )
        {
            # There was an error in creating the directory log it
            logger("error","Failed to create directory $retain_location,"
                  ." cannot move disk image to retain location, stopping here"
                  );
            return "",Provisioning::Backup::KVM::Constants::CANNOT_CREATE_DIRECTORY;
        }
        
    }

    # Check if a ram disk is configured
    my $ram_disk = getValue($entry, "sstBackupRamDiskLocation");

    if ( $ram_disk )
    {
        # We are using RAM-Disk
        logger("debug","RAM-Disk configured, using it to save state");

        # Get the RAM-Disk location
        my $ram_disk_location = $ram_disk;
        
        # Remove the file:// in front of the ram disk location
        $ram_disk_location =~ s/file:\/\///;

        # Test if we can write to the specified location
        if ( -w $ram_disk_location ) 
        {
            # Test if the specified RAM-Disk is large enough
            if ( checkRAMDiskSize($machine,$ram_disk_location) == SUCCESS_CODE )
            {

                # Everything is ok, we can use the RAM-Disk
                $save_state_location = $ram_disk_location;

            } else
            {

                # Log that the RAM-Disk is not large enogh
                logger("warning","Configured RAM-Disk (".$ram_disk_location.") "
                       ."is not large enough to save machine, taking retain "
                       ."backup location to save state file" );

                # If the RAM-Disk is not large enogh, save the state to the 
                # local backup location
                $save_state_location = $retain_location;

            } # End else from if ( checkRAMDiskSize( $entry, $ram_disk_location ) )

        } else
        {
            # If we cannot write to the RAM Disk, log it and use local backup
            # location:
            logger("warning","Configured RAM-Disk (".$ram_disk_location.") is "
                  ."not writable, please make sure it exists and has correct "
                  ."permission, taking retain backup location to save state file"
                  );
            # If the RAM-Disk is not writable take retain location
            $save_state_location = $retain_location;

        } # End else from if ( -w $ram_disk_location )

    } else
    {
        # Log that no RAM-Disk is configured
        logger("debug","No RAM-Disk configured, taking local backup location "
               ."to save state file" );

        # If no RAM-Disk is configured, use the local backup location
        $save_state_location = $retain_location;

    } # End else from if ( $ram_disk )

    # Specify a helpy variable
    $state_file = $save_state_location."/$machine_name.state";

    # Check if the machine is running or nor
    if ( ! $was_running )
    {
        # log that the machine is not running
        logger("debug","Machine $machine_name is not running, creating a fake"
              ." state file");

        # Check if dry-dun or not
        if ( $dry_run )
        {
            # Print what would happen
            print "DRY-RUN:  ";
            print "echo 'Machine $machine_name is not running, no state file'";
            print " > $state_file";
            print "\n\n";

            # Return
            return $state_file,0;

        } else
        {
            # If not in dry run, write to the state file, that the machine is 
            # not running
            if ( open(STATE,">$state_file") ) 
            {
                # Write to the file and close it
                print STATE Provisioning::Backup::KVM::Constants::FAKE_STATE_FILE_TEXT;
                close STATE;
                return $state_file,0;
            } else
            {
                # Cannot open the file 
                logger("error","Cannot open the file $state_file for writing, "
                      ." cannot write state file");
                return "",-1;
            }

        }
    }

    # Log the location we are going to save the machines state
    logger("debug","Saving state of machine $machine_name to "
           ."$save_state_location");

    # Save the VMs state, either in dry run or really
    if ( $dry_run )
    {
        # Print what we would do to save the VMs state
        print "DRY-RUN:  ";
        print "virsh save $machine_name $state_file";
        print "\n\n";
        
        # Show dots for three seconds
        showWait(3);
        
    } else
    {
        # Save the machines state, put it into an eval block to avoid that the 
        # whole programm crashes if something fails
        eval
        {
            $machine->save($state_file);
        };

        my $libvirt_err = $@;
               
        # Test if there was an error
        if ( $libvirt_err )
        {
            my $error_message = $libvirt_err->message;
            $error = $libvirt_err->code;
            logger("error","Error from libvirt (".$error
                  ."): libvirt says: $error_message.");
            return "",$error;
        }

        setPermissionOnFile($entry,$state_file);

    }

    return ( $state_file , $error );

}

################################################################################
# checkRAMDiskSize
################################################################################
# Description:
#  
################################################################################

sub changeDiskImages
{

    my ( $machine_name , $config_entry , @images ) = @_;

    # Initialize the var to return any error, initially it is 0 (no error) 
    my $error = 0;

    # Log what we are currently doing
    logger("debug","Renaming original disk image(s) for machine $machine_name");
    
    # Get the retain locatio:
    my $retain_directory = getValue($config_entry,"sstBackupRetainDirectory");

    # Remove the file:// in front
    $retain_directory =~ s/^file:\/\///;

    # Add the intermediate path to the retain location
    $retain_directory .= "/".$intermediate_path;

    # Test if the location where we should put the disk image exists
    unless ( -d $retain_directory )
    {
        # Create it
        if ( createDirectory( $retain_directory, $config_entry ) != SUCCESS_CODE )
        {
            # There was an error in creating the directory log it
            logger("error","Failed to create directory $retain_directory,"
                  ." cannot move disk image to retain location, stopping here"
                  );
            return Provisioning::Backup::KVM::Constants::CANNOT_CREATE_DIRECTORY;
        }
        
    }
       
    foreach my $disk_image ( @images )
    {
        # If we got the disk image we can rename / move it using the TransportAPI
        # So first generate the commands:
        # Get the disk image name
        my $disk_image_name = basename( $disk_image );

        my @args = ('mv',$disk_image,$retain_directory."/".$disk_image_name);

        # Execute the commands
        my ($output, $command_err) = executeCommand($gateway_connection, @args);

        # Test whether or not the command was successfull: 
        if ( $command_err )
        {
            # If there was an error log what happend and return 
            logger("error","Could not move the disk image $disk_image for "
                   ."machine $machine_name: error: $command_err" );
            return Provisioning::Backup::KVM::Constants::CANNOT_RENAME_DISK_IMAGE;
        }

        # When the disk image could be renamed log it and continue
        logger("debug","Disk image renamed for machine $machine_name");
        logger("debug","Creating new disk image for machine $machine_name");

        # Create a new disk image with the same name as the old (original one) and
        # set correct permission
        if ( $error = createEmptyDiskImage($disk_image,$config_entry,$retain_directory."/".$disk_image_name))
        {
            # Log it and return
            logger("error","Could not create empty disk $disk_image for machine"
                   ." $machine_name: error: $error");
            return $error;
        }
    }

    # If the new image is created and has correct permission this method is done
    return $error
    
}


################################################################################
# checkRAMDiskSize
################################################################################
# Description:
#  
################################################################################

sub restoreVM
{
    my ( $machine_name, $state_file ) = @_;

    # Log what we are doing
    logger("debug","Restoring machine $machine_name from $state_file");

    # Initialize error to no-error
    my $error = 0;

    # Check whether the specified state file is readable (only if not in dry
    # run)
    if ( !(-r $state_file) && !$dry_run )
    {
        # Log it and return error
        logger("error","Cannot read state file '$state_file' for machine "
               .$machine_name );
        $error = 1;
        return $error;
    }

    # Otherwise restore the machine
    if ( $dry_run )
    {
        # Print what we would do to save the VMs state
        print "DRY-RUN:  ";
        print "virsh restore $state_file";
        print "\n\n";
        
        # Show the dots for 5 seconds
        showWait(5);    
    } else
    {
        # Really restore the machine using libvirt api, put it also in an eval 
        # block to avoid the programm to crash if anything goes wrong
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
                  ."): libvirt says: $error_message.");
            return $error;
        }

    }

    # Log success
    logger("debug", "Machine $machine_name successfully restored!");
    return $error;

}


################################################################################
# mergeDiskImages
################################################################################
# Description:
#  
################################################################################

sub mergeDiskImages
{

    my ( $machine, $disk_image, $bandwidth, $machine_name, $config_entry ) = @_;

    # Initialize error to no-error
    my $error = 0;

    # Log what we are doing
    logger("debug","Merging disk images for machine $machine_name which is "
           ."the following file: $disk_image");

    # We need some vars:
    my $retain_location;
    my $disk_image_name;

    # Check if the machine is running or not
    my $running = machineIsRunning( $machine, $machine_name );
#    if ( ! $running )
#    {
#        # Get retain location and disk image name to copy the files
#        $retain_location = getValue($config_entry,"sstBackupRetainDirectory");
#        $disk_image_name = basename( $disk_image );
#
#        # Remove the file:// in front of the retain directory
#        $retain_location =~ s/file\:\/\///;
#
#        # Add the intermediate path to the reatin location
#        $retain_location .= "/".$intermediate_path;
#    }

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
        my $libvirt_err;

        # Check if the machine is running
        if ( ! $running )
        {
            # Start the machine in pasued state
            logger("debug","Machine is not running, starting in paused state");
            eval
            {
                $machine->create(Sys::Virt::Domain::START_PAUSED);
            };

            $libvirt_err = $@;

            # Test if there was an error
            if ( $libvirt_err )
            {
                my $error_message = $libvirt_err->message;
                $error = $libvirt_err->code;
                logger("error","Error from libvirt (".$error
                      ."): libvirt says: $error_message.");
                return $error;
            }

            # Wait for the domain to be started
#            sleep(5);
        }

        # Really merge the disk images
        logger("debug","Merge process starts");
        eval
        {
            $machine->block_pull($disk_image, $bandwidth);
        };

        $libvirt_err = $@;

        # Remember the start time for a timeout
        my $start_time = time;

        # Test if there was an error
        if ( $libvirt_err )
        {
            my $error_message = $libvirt_err->message;
            $error = $libvirt_err->code;
            logger("error","Error from libvirt (".$error
                  ."): libvirt says: $error_message.");
            return $error;
        }

        # Test if the job is done:
        my $job_done = 0;
        while ( $job_done == 0)
        {
            # Get the block job information from the machine and the given image
            my $info;
            eval
            {
                $info = $machine->get_block_job_info($disk_image, my $flags=0);
            };

            $libvirt_err = $@;

            # Remember the start time for a timeout
            my $start_time = time;

            # Test if there was an error
            if ( $libvirt_err )
            {
                my $error_message = $libvirt_err->message;
                $error = $libvirt_err->code;
                logger("error","Error from libvirt (".$error
                      ."): libvirt says: $error_message.");
                return $error;
            }

            # Test if type == 0, if yes the job is done, if test == 1, the job 
            # is still running
            $job_done = 1 if ( $info->{type} == 0 );

            # Wait for a second and retest
            sleep(1);

            # Test if timeout
            if ( time - $start_time > 14400 )
            {
                logger("error","Machine is now merging for more than 4 "
                      ."hours, merge process timed out.");
                return $error = 1;
            }

        }
#        } else
#        {
#            logger("debug","Copy the disk image to retain location");
#            # If the machine is not running we need to copy the image to the 
#            # retain location
#            # Generate to commands to execute
#            my @args = ("cp",
#                        "-p",
#                        $disk_image,
#                        "$retain_location/$disk_image_name");
#
#            # Execute the command using the transport api
#            my $output;
#            ( $output, $error ) = executeCommand($gateway_connection, @args);
#
#            # Check if there was an error: 
#            if ( $error )
#            {
#                # Log if there is 
#                logger("error","Could not copy disk image to retain location: "
#                      .$output);
#                return $error;
#            }
#        }

        # If the state is paused, it means the machine was started just for 
        # merging so stop it again
        my $state;
        my $reason;
        eval
        {
            ( $state, $reason ) = $machine->get_state();
        };

        $libvirt_err = $@;

        # Test if there was an error
        if ( $libvirt_err )
        {
            my $error_message = $libvirt_err->message;
            $error = $libvirt_err->code;
            logger("warning","Error from libvirt (".$error
                      ."): libvirt says: $error_message.");
            logger("warning","Cannot decide whether to destroy the machine "
                  ."or not! Not doing anything for safty reasons!");
        }

        if ( ! $running && $state == Sys::Virt::Domain::STATE_PAUSED_SAVE )
        {
            logger("debug","Stopping machine again");
            sleep 2;
            eval
            {
                $machine->destroy();
            };

            $libvirt_err = $@;

            # Test if there was an error
            if ( $libvirt_err )
            {
                my $error_message = $libvirt_err->message;
                $error = $libvirt_err->code;
                logger("warning","Error from libvirt (".$error
                      ."): libvirt says: $error_message.");
                logger("warning","Could not destroy machine");
            }

        }

    }

    return $error;    
}


################################################################################
# checkRAMDiskSize
################################################################################
# Description:
#  
################################################################################

sub exportFileToLocation
{
    my ($file, $location, $suffix ,$config_entry) = @_;

    # Remove the file:// in front of the file
    $file =~ s/^file:\/\///;

    # Calculate the export command depending on the $location prefix (currently 
    # only file:// => cp -p is supported)
    my $command;
    if ( $location =~ m/^file:\/\// )
    {
        # Remove the file:// in front of the actual path
        $location =~ s/^file:\/\///;
        $command = "cp -p";
    }
    # elsif (other case) {other solution}

    # Get the file name:
    my $file_name = basename($file);

    # Add the siffix at the end of the file name
    $file_name .= $suffix;

    # Test if the destination directory exists, if not, create it
    unless ( -d $location )
    {
        # Create the directory
        if ( createDirectory( $location, $config_entry ) != SUCCESS_CODE )
        {
            # Log it and return
            logger("error", "Failed to create directory $location,"
                  ." cannot move file there. Stopping here");
            return Provisioning::Backup::KVM::Constants::CANNOT_CREATE_DIRECTORY;
        }

        # Log succes
        logger("debug", "Destination directory $location "
              ."successfully created");
    }

    # What are we doing? 
    logger("debug","Exporting $file to $location using $command");

    # Genereate the command
    my @args = ($command,$file,$location."/".$file_name);

    # Execute the command
    my ($output, $error) = executeCommand($gateway_connection, @args);

    # Test whether or not the command was successfull: 
    if ( $error )
    {
        # If there was an error log what happend and return 
        logger("error","Could not export $file to $location. Error: $error" );
        return $error;
    }

    # Return
    return $error;
}

################################################################################
# deleteFile
################################################################################
# Description:
#  
################################################################################

sub deleteFile
{
    my $file = shift;

    # Remove file:// in front of the file
    $file =~ s/file:\/\///;

    # Log what we are doing
    logger("debug","Deleting file $file");

    # Generate the command
    my @args = ("rm",$file);

    # Execute the command
    # Execute the command
    my ($output, $error) = executeCommand($gateway_connection, @args);

    # Test whether or not the command was successfull: 
    if ( $error )
    {
        # If there was an error log what happend and return 
        logger("error","Could delete file $file. Error: $error" );
        return $error;
    }

    # Return
    return $error;
}

################################################################################
# checkRAMDiskSize
################################################################################
# Description:
#  
################################################################################

sub checkRAMDiskSize
{
    my ($machine, $dir ) = @_;

    # Get filesytem information for the specified directory (size in KB)
    my $file_system_info = df($dir);

    my $info;
    eval
    {
        $info = $machine->get_info();
    };

    my $libvirt_err = $@;
               
    # Test if there was an error
    if ( $libvirt_err )
    {
        my $error_message = $libvirt_err->message;
        my $error = $libvirt_err->code;
        logger("error","Error from libvirt (".$error
              ."): libvirt says: $error_message.");
        return $error;
    }

    # Get the current allocated memory of the domain in KB
    my $ram = $info->{memory};

    # Now add add 10%  for the cpu state
    $ram *= 1.05;

    # Check whether the available space on the ram disk is large enogh
    if ( $ram < $file_system_info->{bavail} )
    {
        # Ram disk is large enough
        return SUCCESS_CODE;
    } else
    {
        # Ram disk is too small
        return ERROR_CODE;
    }

    return SUCCESS_CODE;
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
# createEmptyDiskImage
################################################################################
# Description:
#  
################################################################################

sub createEmptyDiskImage
{
    my ( $disk_image, $config_entry , $backing_file ) = @_;

    my $format = getValue( $config_entry, "sstvirtualizationdiskimageformat");

    # Generate the commands to be executed
    my @args = ('qemu-img',
                'create',
                '-f',
                $format,
                '-b',
                $backing_file,
                $disk_image
               );

    # Execute the commands:
    my ($output , $command_err) = executeCommand( $gateway_connection , @args );

    # Test whether or not the command was successfull: 
    if ( $command_err )
    {
        # If there was an error log what happend and return 
        logger("error","Could not create empty disk image '$disk_image': "
               ."error: $command_err" );
        return Provisioning::Backup::KVM::Constants::CANNOT_CREATE_EMPTY_DISK_IMAGE;
    }

    # Set correct permission and ownership
    my $owner = getValue( $config_entry, "sstvirtualizationdiskimageowner");
    my $group = getValue( $config_entry, "sstvirtualizationdiskimagegroup");
    my $octal_permission = getValue( $config_entry, "sstvirtualizationdiskimagepermission");

    # Change ownership, generate commands
    @args = ('chown',"$owner:$group",$disk_image);

    # Execute the commands:
    ($output , $command_err) = executeCommand( $gateway_connection , @args );

    # Test whether or not the command was successfull: 
    if ( $command_err )
    {
        # If there was an error log what happend and return 
        logger("error","Could not set ownership for disk image '$disk_image':"
               ." error: $command_err" );
        return Provisioning::Backup::KVM::Constants::CANNOT_SET_DISK_IMAGE_OWNERSHIP;
    }

    # Change ownership, generate commands
    @args = ('chmod',$octal_permission,$disk_image);

    # Execute the commands:
    ($output , $command_err) = executeCommand( $gateway_connection , @args );

    # Test whether or not the command was successfull: 
    if ( $command_err )
    {
        # If there was an error log what happend and return 
        logger("error","Could not set permission for disk image '$disk_image'"
               .": error: $command_err" );
        return Provisioning::Backup::KVM::Constants::CANNOT_SET_DISK_IMAGE_PERMISSION;
    }


    # if everything is OK we log it and return
    logger("debug","Empty disk image '$disk_image' created");
    return SUCCESS_CODE;
}

################################################################################
# saveXMLDescription
################################################################################
# Description:
#  
################################################################################

sub saveXMLDescription
{
    my ( $machine, $file, $config_entry ) = @_;

    # Get the machines XML description using the libvirt api
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
        return Provisioning::Backup::KVM::Constants::CANNOT_SAVE_XML;
    }

    # If everything is alright we can write the xml string to the file
    if ( $dry_run )
    {
        print "DRY-RUN:  $xml_string > $file\n\n";
    } else
    {
        # Test if the directory already exists
        unless ( -d dirname( $file ) )
        {
            # If it does not exist, create it
            if ( createDirectory( dirname( $file ), $config_entry ) != SUCCESS_CODE )
            {
                logger("error","Cannot create directory ".dirname ($file )
                      ."Cannot save the XML file ($file).");
                return Provisioning::Backup::KVM::Constants::CANNOT_SAVE_XML;
            }
        }

        # Open the file and write the XML string to it
        if ( !open(XML, ">$file") )
        {
            # Failed to open the file
            logger("error","Cannot open the file $file for writing: $!. "
                  ."Stopping here!");
            return Provisioning::Backup::KVM::Constants::CANNOT_SAVE_XML;
        } else
        {
            # Write the XML description to the file and close the filehandler
            print XML $xml_string;
            close XML;

            # Set correct permission
            setPermissionOnFile( $config_entry, $file );
        }
    }

    return SUCCESS_CODE;
}


################################################################################
# saveBackendEntry
################################################################################
# Description:
#  
################################################################################

sub saveBackendEntry
{
    my ( $backend_entry, $file, $backend, $config_entry, $cfg ) = @_;

    # If we are in dry run just return
    return SUCCESS_CODE if ( $dry_run );

    # Get the machine entry
    my $machine_entry = getParentEntry( getParentEntry( $backend_entry ) );

    # Replace the %backend% with the appropriate backend file suffix
    switch ( $backend )
    {
        case "LDAP" { $file =~ s/%backend%/ldif/; }
        else { $file =~ s/%backend%/export/;}
    }

    # Test if the directory already exists
    unless ( -d dirname( $file ) )
    {
        # If it does not exist, create it
        if ( createDirectory( dirname( $file ), $config_entry ) != SUCCESS_CODE )
        {
            logger("error","Cannot create directory ".dirname ($file )
                  ."Cannot save the backend entry ($file).");
            return Provisioning::Backup::KVM::Constants::CANNOT_SAVE_BACKEND_ENTRY;
        }
    }

    # Export the backend entry to the given file
    my $error = exportEntryToFile( $machine_entry, $file, 1 );

    # Check if there was an error
    if ( $error )
    {
        # Log it and return
        logger("error","Could not export the backend entry to the file $file"
              ."Stopping here.");
        return Provisioning::Backup::KVM::Constants::CANNOT_SAVE_BACKEND_ENTRY;
    }

    # Now also add the dhcp entry to the same file, but first of all we need get
    # it
    my $machine_name = getValue($machine_entry, "sstVirtualMachine");
    my $dhcp_base = "cn=config-01,ou=dhcp,ou=networks,".$cfg->val("Database","SERVICE_SUBTREE");
    my @dhcps = simpleSearch( $dhcp_base , "(cn=$machine_name)", "sub" );

    # Check if we have found the dhcp entry for the machine
    if ( @dhcps == 1 )
    {
        $error = exportEntryToFile( $dhcps[0], $file, 0 );
    } else
    {
        logger("warning","Found ".@dhcps." dhcp entries for the machine "
              .$machine_name." cannot save it (search base: $dhcp_base)" );
    }

    setPermissionOnFile( $config_entry, $file );

    # Otherwise log success and return
    logger("debug","Successfully exported backend entry to $file");
    return SUCCESS_CODE;
}

################################################################################
# showWait
################################################################################
# Description:
#  
################################################################################

sub showWait
{

    my $times = shift;

    my $i = 0;

    # Avoid endless loops
    return if ( $times < 0 );

    # Avoid to long loops
    return if ( $times > 60);

    # Print the dots....
    while ( $i++ < $times )
    {
        # Print out a point (.) and sleep for one second
        print ". ";
        sleep 1;
    }

    # Nicer look and feel
    print "\n\n";

}

################################################################################
# writeDurationToBackend
################################################################################
# Description:
#  
################################################################################

sub writeDurationToBackend
{

    my ($entry, $type, $duration, $connection) = @_;

    # Get the initial value of the duration:
    my @list = getValue($entry,"sstProvisioningExecutionTime");

    # Check if the first element of the list is defined, if not, recreate the 
    # list (empty) to avoid strange output
    if ( @list > 0 && !defined( $list[0] ) )
    {
        @list = ();
    }

    # Check if the element is already in the list
    my $found = 0;

    # Go through the list and change the appropriate value
    foreach my $element (@list)
    {
        if ( $element =~ m/$type/ )
        {
            $element = "$type: $duration";
            $found = 1;
        }
    }

    # If the element was not already in the list, add it
    if ( $found == 0)
    {
        push( @list, "$type: $duration" );
    }

    # Modify the list in the backend
    modifyAttribute( $entry,
                     "sstProvisioningExecutionTime",
                     \@list,
                     $connection
                   );

}


################################################################################
# machineIsRunning
################################################################################
# Description:
#  
################################################################################

sub machineIsRunning
{

    my ( $machine, $machine_name )  = @_;

    # Log what we are doing
    logger("debug","Checking if machine $machine_name is running");

    # Test if the machine is running or not
    my $running;
    eval
    {
        $running = $machine->is_active();
    };

    # Test if there was an error, if yes log it
    my $libvirt_error = $@;
    if ( $libvirt_error )
    {
        logger("error","Could not check machine"
        ." state (running or not): $libvirt_error");
        return undef;
    }

    # Log the result
    if ( $running )
    {
        # Yes the machine is running
        logger("debug","Machine $machine_name is running");
    } else
    {
        # No, the machine is not running
        logger("debug","Machine $machine_name is shut down");
    }

    # If everything was fine, return running
    return $running;

}

################################################################################
# deleteBackup
################################################################################
# Description:
#  
################################################################################

sub deleteBackup
{

    my ( $machine_name, $to_delete_date, $config_entry, @disks ) = @_;

    my $error = 0;

    # First of all we need the backup root directory
    my $backup_directory = getValue($config_entry, "sstBackupRootDirectory");

    # Split the backup directory into protocol and backup directory
    $backup_directory =~ m/([\w\+]+\:\/\/)([\w\/]+)/;
    $backup_directory = $2;
    my $protocol = $1;

    # Add the intermediat path
    $backup_directory .= "/$intermediate_path";

    # Create a counter to count how many files were deleted
    my $counter = 0;

    # Go through the backup directory and search for files with the machine name
    # and the same date as to_delete_date
    foreach my $file (<$backup_directory/*>)
    {
        # Check if the file machtes the vm name
        if ( $file =~ m/$machine_name/ )
        {
            # Check if file matches to delete date
            if ( $file =~ m/$to_delete_date$/ )
            {
                # Yes this file needs to be deleted
                $error = deleteFile($protocol.$file);
                if ( $error )
                {
                    # Return that the file could not be dleted
                    return Provisioning::Backup::KVM::Constants::CANNOT_REMOVE_FILE;
                }

                $counter++;
            }
        }
    }
    
    # Check how many files we have deleted, if there were not at least 
    # four files (XML state and backend), something is wrong...
    if ( $counter < 3 )
    {
        # Log it
        logger("warning","Only found $counter files to delete for machine "
              ."$machine_name (without disk iamges) and backup date "
              ."$to_delete_date. Please check the other backups for this "
              ."machine for completeness");
    }

    # Now delete the disk_images
    foreach my $disk (@disks)
    {
        # Claculate the disk image name
        my $disk_name = basename($disk).$to_delete_date;
        
        # remove the current backed up disk image
        $error = deleteFile($protocol.$backup_directory."/$disk_name");

        # Check for errors and return if any
        if ( $error )
        {
            # Return that the file could not be dleted
            return Provisioning::Backup::KVM::Constants::CANNOT_REMOVE_FILE;
        }
    }

    return $error;
}

################################################################################
# createNewLibvirtConnection
################################################################################
# Description:
#  
################################################################################

#sub createNewLibvirtConnection
#{
#
#    # Undefine the $vmm variable
#    undef $vmm;
#
#    # Create a new connection to libvirt
#    $vmm = Sys::Virt->new( addr => "qemu:///system" );
#
#}

################################################################################
# returnIntermediatePath
################################################################################
# Description:
#  
################################################################################

sub returnIntermediatePath
{
    return $intermediate_path;
}

1;

__END__

=pod

=cut

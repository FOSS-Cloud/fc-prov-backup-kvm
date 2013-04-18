package Provisioning::Backup::KVM::Constants;

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

require Exporter;

=pod

=head1 Name

Constants.pm

=head1 Description

=cut


our @ISA = qw(Exporter);

our %EXPORT_TAGS = ( 'all' => [ qw() ] );

our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

our @EXPORT = qw();

our $VERSION = '0.01';


###############################################################################
#####                             Constants                               #####
###############################################################################

use constant SUCCESS_CODE                           => 0;
use constant ERROR_CODE                             => 1;

use constant TRUE                                   => 1;
use constant FALSE                                  => 0;

# Default text to write into the fake state file when machine is shut down when 
# it is backed up
use constant FAKE_STATE_FILE_TEXT => "Machine is not runnung, no state file";

# Constant to tell the calling script that there is no backup needed
use constant NO_BACKUP_NEEDED                       => 999;

### Error codes constants
use constant UNDEFINED_ERROR                            => 1; # Always the first!
use constant MISSING_PARAMETER_IN_CONFIG_FILE           => 2;
use constant CONFIGURED_RAM_DISK_IS_NOT_VALUD           => 3;
use constant NOT_ENOUGH_SPACE_ON_RAM_DISK               => 4;
use constant CANNOT_SAVE_MACHINE_STATE                  => 5;
use constant CANNOT_WRITE_TO_BACKUP_LOCATION            => 6;
use constant CANNOT_COPY_FILE_TO_BACKUP_LOCATION        => 7;
use constant CANNOT_COPY_IMAGE_TO_BACKUP_LOCATION       => 8;
use constant CANNOT_COPY_XML_TO_BACKUP_LOCATION         => 9;
use constant CANNOT_COPY_BACKEND_FILE_TO_BACKUP_LOCATION=> 10;
use constant CANNOT_MERGE_DISK_IMAGES                   => 11;
use constant CANNOT_REMOVE_OLD_DISK_IMAGE               => 12;
use constant CANNOT_REMOVE_FILE                         => 13;
use constant CANNOT_CREATE_EMPTY_DISK_IMAGE             => 15;
use constant CANNOT_RENAME_DISK_IMAGE                   => 16;
use constant CANNOT_CONNECT_TO_BACKEND                  => 17;
use constant WRONG_STATE_INFORMATION                    => 18;
use constant CANNOT_SET_DISK_IMAGE_OWNERSHIP            => 19;
use constant CANNOT_SET_DISK_IMAGE_PERMISSION           => 20;
use constant CANNOT_RESTORE_MACHINE                     => 21;
use constant CANNOT_LOCK_MACHINE                        => 22;
use constant CANNOT_FIND_MACHINE                        => 23;
use constant CANNOT_COPY_STATE_FILE_TO_RETAIN           => 24;
use constant RETAIN_ROOT_DIRECTORY_DOES_NOT_EXIST       => 25;
use constant BACKUP_ROOT_DIRECTORY_DOES_NOT_EXIST       => 26;
use constant CANNOT_CREATE_DIRECTORY                    => 27;
use constant CANNOT_SAVE_XML                            => 28;
use constant CANNOT_SAVE_BACKEND_ENTRY                  => 29;
use constant CANNOT_SET_DIRECTORY_OWNERSHIP             => 30;
use constant CANNOT_SET_DIRECTORY_PERMISSION            => 31;
use constant CANNOT_FIND_CONFIGURATION_ENTRY            => 32;
use constant BACKEND_XML_UNCONSISTENCY                  => 33;
use constant CANNOT_CREATE_TARBALL                      => 34;
use constant UNSUPPORTED_FILE_TRANSFER_PROTOCOL         => 35;
use constant UNKNOWN_BACKEND_TYPE                       => 36;
use constant MISSING_NECESSARY_FILES                    => 37;
use constant CORRUPT_DISK_IMAGE_FOUND                   => 38;
use constant UNSUPPORTED_CONFIGURATION_PARAMETER        => 39;
use constant CANNOT_MOVE_DISK_IMAGE_TO_ORIGINAL_LOCATION=> 40;
use constant CANNOT_DEFINE_MACHINE                      => 41;
use constant CANNOT_START_MACHINE                       => 42;
use constant CANNOT_WORK_ON_UNDEFINED_OBJECT            => 43;
use constant CANNOT_READ_STATE_FILE                     => 44;
use constant CANNOT_READ_XML_FILE                       => 45;
use constant NOT_ALL_FILES_DELETED_FROM_RETAIN_LOCATION => 46;

1;

__END__

package TransportAPI::LocalCLI;

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
#use Net::OpenSSH;
#use Text::CSV::Encoded;
#use IO::String;
use Log;

require Exporter;

our @ISA = qw(Exporter);

our %EXPORT_TAGS = ( 'all' => [ qw(gatewayConnect executeCommand gatewayDisconnect) ] );

our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

our @EXPORT = qw(gatewayConnect executeCommand gatewayDisconnect);

our $VERSION = '0.01';



$|=1;



my @args;
my $output;

# Get some vars from the provisioning script
my $opt_r = $Provisioning::opt_R;
my $service = $Provisioning::cfg->val('Service','SERVICE')."-".$Provisioning::cfg->val('Service','TYPE');
my $service_cfg = $Provisioning::cfg;
my $global_cfg = $Provisioning::global_cfg;

###############################################################################
#####                                General                              #####
###############################################################################

sub gatewayConnect{

  # creates an ssh-connection for the given user on the given host with the given
  # dsa-key-file (no password). 

  my ($host,$user,$dsa_file,$mode,$attempt)=@_;

  # Nothing to do we are local, just return a "valid connection"
  return 1;

} # end sub makeSSHConenction



sub gatewayDisconnect(){

  my $ssh_connection=shift;

  # Nothing to do we are local.
  
}

sub executeCommand{

  my ($connection,@args)=@_;

  # Initialize the var to return any error, initially it is 0 (no error)
  my $error=0;

  # Generate the commands according to the array that was passed
  my $command = join(' ',@args);

  # Check if the script runs in dry-run or not
  if($opt_r)
  {
    # If we are in dry-run only print the command, no changes on the system 
    # are made
    print "DRY-RUN:  $command\n\n";
    logger("debug","Command: $command successfully executed");

  } else
  {
    # If not in dry-run execute the command and grab its output
    $output = `$command`;
    
    # Save the commands return code
    $error = $?;

    # Check if there was an error
    if( $error )
    {
      # If yes, log that the command failed
      logger("error", "Command: $command failed!!! Return-error-message: $output");

    } else
    {
      # Otherwise log that the command was executed successfully
      logger("debug","Command: $command successfully executed");
    }# end  unless($localerror==0)
  
  } # end if($opt_r)

  # Return the output and the return code
  return $output, $error;

} # end sub executeCommand


#end module CLISSH.pm

1;

__END__

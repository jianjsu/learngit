<#
.Synopsis
  Perform health/status checks against an Exchange BackEnd server.

.Description
  This script performs basic status and health checks against
  an Exchange Online BackEnd (BE) server.

.Notes
  The objectve is to do these checks very quickly, and provide on-calls with 
  diagnostics. Additionally, others are encouraged to add checks for their
  process/service. But:
  (1) Keep the structure sane such that adding new code remains simple.
  (2) Keep the execution time under 15 seconds. (Only slower checks when needed.)

.Parameter Server
  The server to perform the checks against.

.Parameter Transport
  If provided, check (Hub) Transport.

.Parameter Submission
  If provided, check MSExchangeSubmission.

.Parameter Delivery
  If provided, check MSExchangeDelivery.

.Parameter Level
  If provided, execute checks up until the provided level. (Maximum is 2.)

.Outputs
  N/A.

.Example
  becheck.ps1 -server BLUPR08MB245
  becheck.ps1 -server BLUPR08MB245 -Transport
#>

[CmdletBinding()] 
param(
  [Parameter(Mandatory = $true)]
  $server,
  [Parameter(Mandatory = $false)]
  [switch]$Transport,
  [Parameter(Mandatory = $false)]
  [switch]$Submission,
  [Parameter(Mandatory = $false)]
  [switch]$Delivery,
  [Parameter(Mandatory = $false)]
  [ValidateRange(1,2)]
  [int]$Level = 1
)

################################################################################
#
# Main part of script
#
################################################################################

# Validate that dependent files exist
$commonCheckLib = "$($PSScriptRoot)\exchecklib.ps1";
$transportCheck = "$($PSScriptRoot)\exchecktransport.ps1";
$deploymentCheck = "$($PSScriptRoot)\DatacenterDeploymentTransportLibrary.ps1";

$requiredFiles = @($commonCheckLib, $transportCheck, $deploymentCheck);
$dependenciesFound = $true;
$isMailbox = $true;

foreach ($requiredFile in $requiredFiles)
{
    if (-not (Test-Path $requiredFile))
    {
        Write-Host "ERROR: Missing dependent file $($requiredFile)";
        $dependenciesFound = $false;
    }
}

if ($dependenciesFound)
{
    # Record the start time
    $startTime = get-date

    # Source the library with common utility functions.
    . $commonCheckLib
    . $deploymentCheck

    # Check the server argument
    $exchangeServer = get-exchangeserver $server -erroraction silentlycontinue

    if ($exchangeServer -eq $null) {
      ExitWithErrorMessage ("Server '" + $server + "' not found.")
    }

    if ($exchangeServer.serverrole -ne "Mailbox" -and $exchangeServer.serverrole -ne "HubTransport") {
      ExitWithErrorMessage ("Server '" + $server + "' is not a Mailbox or HubTransport role.")
    }

    $isMailbox = $exchangeServer.serverrole -eq "Mailbox";

    # Write information about the server
    ServerInfo $exchangeServer

    #
    # Check uptime of edgetransport, MSExchangeSubmission and MSExchangeDelivery
    #

    WriteCheckHeader "Checking uptime of relevant services."
    $edgeTransportUpTime = CheckUptime $server "EdgeTransport"

    if ($isMailbox)
    {
        CheckUptime $server "MSExchangeSubmission" | Out-Null
        CheckUptime $server "MSExchangeDelivery" | Out-Null
    }

    #
    # Check these events: submissions, receives, sends and deliveries
    #

    WriteCheckHeader "Checking current activity using message tracking logs"
    CheckMessageEvents $server $isMailbox

    WriteCheckHeader "Checking Server Health"
    CheckServerHealth $server 'HubTransport'
    CheckServerHealth $server 'MailboxTransport'
    CheckServerHealth $server 'Transport'

    #
    # Invoke any Transport Service specific checks
    #
    $mbxTransport = Get-MailboxTransportService $server -ErrorAction SilentlyContinue
    . $transportCheck
    CheckAnyTransport $exchangeServer $Transport $Submission $Delivery $Level $edgeTransportUpTime $mbxTransport
    
    #
    # Check Repair box history
    #
    $repairBoxFailure = Get-RepairBoxFailure -Filter "Machine -eq '$server'" -ErrorAction SilentlyContinue
    if($repairBoxFailure -ne $null)
    {
        WriteCheckHeader "Repair box history details"
        $repairBoxFailure
    }

    # Done & write the time it took.
    $elapsed = (get-date) - $startTime
    $msg = "Done." + " (Execution time: " + $elapsed.tostring("hh\:mm\:ss") + ")"
    WriteCheckHeader $msg 
}

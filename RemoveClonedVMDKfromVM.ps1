<#
.SYNOPSIS

Removes a hard disk from a VM and the associated pure volume and datastore to
prepare for replacement. Requires a parameter file with details

.DESCRIPTION

***************************************************************************************************
VMWARE POWERCLI AND PURE STORAGE POWERSHELL SDK MUST BE INSTALLED ON THE MACHINE THIS IS RUNNING ON
***************************************************************************************************

For info, refer to www.codyhosterman.com

*******Disclaimer:******************************************************
This scripts are offered "as is" with no warranty.  While this 
scripts is tested and working in my environment, it is recommended that you test 
this script in a test lab before using in a production environment. Everyone can 
use the scripts/commands provided here without any written permission but I
will not be liable for any damage or loss to the system.
************************************************************************

This can be run directly from PowerCLI or from a standard PowerShell prompt. PowerCLI must be installed on the local host regardless.

Supports:
-PowerShell 5.0 or later (note because of Import-PowerShellDataFile cmdlet)
-Pure Storage PowerShell SDK 1.7 or later
-PowerCLI 6.5 Release 1+
-Purity 4.8 and later
-FlashArray 400 Series and //m and //x
-vCenter 6.0 and later

.PARAMETER parameterfile

Path to file which is in psd1 format with contents like this:
@{
    purearray = 'my_pure.array.loc' # fqdn or IP of Pure Array
    vcenter = 'my.vcenter.loc' #fqdn or IP of vcenter
    vcluster = 'vcluster name' #cluster name that contains source VM for cloning operation
    pureusername = 'pureuser' #pure username
    vcenterusername = 'vsphere.local\pureuser' #vcenter username
    purepasswordfile = '.\purepassword.txt' #path to a file containing gnerated pure password
     # see https://blogs.technet.microsoft.com/robcost/2008/05/01/powershell-tip-storing-and-using-password-credentials/ for details
     # of how to update the password file contents 
    vcenterpasswordfile = '.\vcenterpassword.txt' # same deal for vcenter
    purevol = 'purevolname' #name pure volume that holds our current cloned vmdk
    datastore = 'vmwaredatastore' #name of the vmware datastore for the pure vol
    purehostgroup = 'hostgroupname' # name of a pure host group with cluster hosts
    destvm = 'vm' #the target VM that has hard disk from cloned VMDK
    destvmusername = 'vmusername' #dest VM user
    destvmpasswordfile = '.\destvmpassword.txt' #destination VM password file
    destvmdisknumber = 3 #the number of the hard disk that will be removed

}
#>

param ($parameterfile = $(throw "parameterfile is required"))
if (!(Test-Path -Path $parameterfile)) {
    throw "$parameterfile is not accessible"
}

#Import PowerCLI. Requires PowerCLI version 6.3 or later. Will fail here if PowerCLI is not installed
#Will try to install PowerCLI with PowerShellGet if PowerCLI is not present.
if ((!(Get-Module -Name VMware.VimAutomation.Core -ErrorAction SilentlyContinue)) -and (!(get-Module -Name VMware.PowerCLI -ListAvailable))) {
    if (Test-Path "C:\Program Files (x86)\VMware\Infrastructure\PowerCLI\Scripts\Initialize-PowerCLIEnvironment.ps1")
    {
      . "C:\Program Files (x86)\VMware\Infrastructure\PowerCLI\Scripts\Initialize-PowerCLIEnvironment.ps1" |out-null
    }
    elseif (Test-Path "C:\Program Files (x86)\VMware\Infrastructure\vSphere PowerCLI\Scripts\Initialize-PowerCLIEnvironment.ps1")
    {
        . "C:\Program Files (x86)\VMware\Infrastructure\vSphere PowerCLI\Scripts\Initialize-PowerCLIEnvironment.ps1" |out-null
    }
    elseif (!(get-Module -Name VMware.PowerCLI -ListAvailable))
    {
        if (get-Module -name PowerShellGet -ListAvailable)
        {
            try
            {
                Get-PackageProvider -name NuGet -ListAvailable -ErrorAction stop
            }
            catch
            {
                Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser -Confirm:$false
            }
            Install-Module -Name VMware.PowerCLI -confirm:$false -Force -Scope CurrentUser
        }
        else
        {
            write-host ("PowerCLI could not automatically be installed because PowerShellGet is not present. Please install PowerShellGet or PowerCLI") -BackgroundColor Red
            write-host "PowerShellGet can be found here https://www.microsoft.com/en-us/download/details.aspx?id=51451 or is included with PowerShell version 5"
            write-host "Terminating Script" -BackgroundColor Red
            exit 1
        }
    }
    if ((!(Get-Module -Name VMware.VimAutomation.Core -ErrorAction SilentlyContinue)) -and (!(get-Module -Name VMware.PowerCLI -ListAvailable)))
    {
        write-host ("PowerCLI not found. Please verify installation and retry.") -BackgroundColor Red
        write-host "Terminating Script" -BackgroundColor Red
        exit 1
    }
}
set-powercliconfiguration -invalidcertificateaction "ignore" -confirm:$false |out-null
Set-PowerCLIConfiguration -Scope User -ParticipateInCEIP $false  -confirm:$false|out-null
#Set
$ErrorActionPreference = "Stop"

$starttime = $(Get-Date)
# load in required parameters from psd1 file
$scriptparams = Import-PowerShellDataFile $parameterfile
# see https://blogs.technet.microsoft.com/robcost/2008/05/01/powershell-tip-storing-and-using-password-credentials/ for details
# of how to update the password file contents 
Write-Host (get-Date -Format G) "Setting Disk number $scriptparmas.destvmdisknumber on VM $scriptparams.destvm offline" 
try
{
    $destvmpassword = get-content $scriptparams.destvmpasswordfile | convertto-securestring
    $destvmcreds = new-object -typename System.Management.Automation.PSCredential -argumentlist $scriptparams.destvmusername,$destvmpassword
    $mycimsession = New-CimSession -Computername $scriptparams.destvm -Credential $destvmcreds
    Set-Disk -Cimsession $mycimsession -number $scriptparams.destvmdisknumber -IsOffline $true
}
catch
{
    Write-Host (get-Date -Format G) " Failed to connect to $scriptparams.destvm and/or offline disk $($error[0])"
    Exit 1
}

Write-Host (get-Date -Format G) "Connecting to Pure Array $scriptparams.purearray and vcenter $scriptparams.vcenter"
try
{
    $purepassword = get-content $scriptparams.purepasswordfile | convertto-securestring
    $purecreds = new-object -typename System.Management.Automation.PSCredential -argumentlist $scriptparams.pureusername,$purepassword
    $flasharray = New-PfaArray -endpoint $scriptparams.purearray -IgnoreCertificateError -credentials $purecreds
}
catch
{
    Write-Host (get-Date -Fromat G) "Unable to connect to Pure array $scriptparams.purearray $($error[0])"
    Exit 1
}
try {
    $vcenterpassword = get-content $scriptparams.vcenterpasswordfile | convertto-securestring
    $vcentercreds = new-object -typename System.Management.Automation.PSCredential -argumentlist $scriptparams.vcenterusername,$vcenterpassword
    $vcenter = Connect-ViServer -server $scriptparams.vcenter -credential $vcentercreds
}
catch
{
    Write-Host (get-Date -Fromat G) "Unable to connect to vcenter $scriptparams.vcenter $($error[0])"
    Exit 1
}

Write-Host (get-Date -Format G) " Removing Pure hostgroup connection $scriptparams.purehostgroup and volume $scriptparams.purevol"
try
{
    RemovePfaHostGroupVolumeConnection -Array $scriptparams.purearray -VolumeName $scriptparams.purevol -HostGroupName $scriptparams.purehostgroup
}
catch
{
    Write-Host (get-Date -Format G) " FAILED: Failed to remove Pure hostgroup $scriptparams.purehostgroup $($error[0])" 
    Exit 1
}
try
{
    Remove-PfaVolumeOrSnapshot -Array $scriptparams.purearray -Name $scriptparams.purevol
    Remove-PfaVolumeOrSnapshot -Array $scriptparams.purearray -Name $scriptparams.purevol -Eradicate
}
catch
{
    Write-Host (get-Date -Format G) " FAILED: Failed to remove Pure volume $scriptparams.purevol $($error[0])" 
    Exit 1
}

Write-Host (get-Date -Format G) " Rescanning cluster..."
try{
    $targetvm = get-VM -name $scriptparams.destvm
    $targetvm |get-cluster $scriptparams.vcluster | Get-VMHost | Get-VMHostStorage -RescanAllHba -RescanVMFS -ErrorAction stop
    Write-Host (get-Date -Format G) " The recovery datastore has been deleted"
}
catch
{
    Write-Host (get-Date -Format G) " FAILED: Failed to remove datastore $scriptparams.datastore from clsuter $scriptparams.vcluster $($error[0])" 
    Exit 1
}

$endtime = $(Get-date)
$elapsed = $endtime - $starttime
$totalTime = "{0:HH:mm:ss}" -f ([datetime]$elapsed.Ticks)
Write-Host "Finished at $endtime"
Write-Host "Elapsed duration: $totalTime"

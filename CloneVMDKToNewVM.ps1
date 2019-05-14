<#
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
-PowerShell 3.0 or later
-Pure Storage PowerShell SDK 1.7 or later
-PowerCLI 6.5 Release 1+
-Purity 4.8 and later
-FlashArray 400 Series and //m and //x
-vCenter 6.0 and later

#>
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
            return
        }
    }
    if ((!(Get-Module -Name VMware.VimAutomation.Core -ErrorAction SilentlyContinue)) -and (!(get-Module -Name VMware.PowerCLI -ListAvailable)))
    {
        write-host ("PowerCLI not found. Please verify installation and retry.") -BackgroundColor Red
        write-host "Terminating Script" -BackgroundColor Red
        return
    }
}
set-powercliconfiguration -invalidcertificateaction "ignore" -confirm:$false |out-null
Set-PowerCLIConfiguration -Scope User -ParticipateInCEIP $false  -confirm:$false|out-null
#Set
$EndPoint = $null
$Endpoints = @()
$ErrorActionPreference = "Stop"

# load in required parameters from psd1 file
$scriptparams = Import-PowerShellDataFile '.\CloneVMDKParameters.psd1'
# see https://blogs.technet.microsoft.com/robcost/2008/05/01/powershell-tip-storing-and-using-password-credentials/ for details
# of how to update the password file contents 
$purepassword = get-content $scriptparams.purepasswordfile | convertto-securestring
$vcenterpassword = get-content $scriptparams.vcenterpasswordfile | convertto-securestring
$purecreds = new-object -typename System.Management.Automation.PSCredential -argumentlist $scriptparams.pureusername,$purepassword
$vcentercreds = new-object -typename System.Management.Automation.PSCredential -argumentlist $scriptparams.vcenterusername,$vcenterpassword

$flasharray = New-PfaArray -endpoint $scriptparams.purearray -IgnoreCertificateError -credentials $purecreds
$vcenter = Connect-ViServer -server $scriptparams.vcenter -credential $vcentercreds
$purevolsnapshots = Get-PfaVolumeSnapshots -array $flasharray -volume $scriptparams.purevol
#get the last(most recent) snapshot from the list
$puresourcesnapshot = $purevolsnapshots[-1]
Write-Host "Using most recent snapshot, $($puresourcesnapshot.Name) from $($scriptparams.purevol) to create temporary Pure Datastore Volume"
try
{
    $volumename = $scriptparams.purevol + "-snap-" + (Get-Random -Minimum 1000 -Maximum 9999)
    $newpurevol = New-PfaVolume -array $flasharray -source $puresourcesnapshot.name -VolumeName $volumename
    New-PfaHostGroupVolumeConnection -Array $flasharray -VolumeName $newpurevol.name -HostGroupName $scriptparams.purehostgroup
    Write-Host "Pure temporary volume $($newpurevol.name) created and mapped to host group $($scriptparams.purehostgroup)"
    Write-Host "Rescanning Hosts in vsphere cluster $($scriptparams.vcluster)..."
    $cluster = get-cluster $scriptparams.vcluster
    $cluster | Get-VMHost | Get-VMHostStorage -RescanAllHba -RescanVMFS -ErrorAction stop
    $esxi = get-cluster -Name $scriptparams.vcluster | Get-VMHost -ErrorAction stop
    $esxcli=get-esxcli -VMHost $esxi[0] -v2 -ErrorAction stop
    $resigargs =$esxcli.storage.vmfs.snapshot.list.createargs()
    $sourceds = get-datastore $scriptparams.datastore
    $resigargs.volumelabel = $sourceds.Name
    Start-sleep -s 10
    $unresolvedvmfs = $esxcli.storage.vmfs.snapshot.list.invoke($resigargs) 
    if ($unresolvedvmfs.UnresolvedExtentCount -ge 2)
    {
        throw ("ERROR: There is more than one unresolved copy of the source VMFS named " + $sourceds.Name)
    }
    else
    {
        $resigOp = $esxcli.storage.vmfs.snapshot.resignature.createargs()
        $resigOp.volumelabel = $resigargs.volumelabel
        Write-Host " Resignaturing the VMFS... $($scriptparams.purevol)"
        $esxcli.storage.vmfs.snapshot.resignature.invoke($resigOp)
        Start-sleep -s 10
        $cluster | Get-VMHost | Get-VMHostStorage -RescanVMFS -ErrorAction stop 
        $datastores = $esxi[0] | Get-Datastore -ErrorAction stop
        $recoverylun = ("naa.624a9370" + $newpurevol.serial)
        foreach ($ds in $datastores)
        {
            $naa = $ds.ExtensionData.Info.Vmfs.Extent.DiskName
            if ($naa -eq $recoverylun.ToLower())
            {
                $resigds = $ds
            }
        } 
        $resigds = $resigds | Set-Datastore -Name $volumename -ErrorAction stop
        Write-Host " Presented copied VMFS named  $resigds.name "
    }
}
catch
{
    Write-Host "FAILED: Datastore creation Failed: $($error[0])" 
    if ($newpurevol -ne $null)
    {
        Write-Host " Cleaning up volume... $($Error[0])"
        Remove-PfaHostGroupVolumeConnection -Array $flasharray -VolumeName $newpurevol.name -HostGroupName $scriptparams.purehostgroup
        Remove-PfaVolumeOrSnapshot -Array $flasharray -Name $newpurevol.name
        Remove-PfaVolumeOrSnapshot -Array $flasharray -Name $newpurevol.name -Eradicate
        Write-Host " Rescanning cluster..." 
        $esxi = get-cluster -Name $scriptparams.vcluster | Get-VMHost -ErrorAction stop
        $esxi | Get-VMHostStorage -RescanAllHba -RescanVMFS 
        Write-Host " The recovery datastore has been deleted"
    }
}

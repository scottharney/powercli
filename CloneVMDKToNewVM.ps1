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
$ErrorActionPreference = "Stop"

$starttime = $(Get-Date)
Write-Host "Starting VMDK cloning operation: $starttime"
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
Write-Host ((get-Date -Format G) + " Using most recent snapshot, $($puresourcesnapshot.Name) from $($scriptparams.purevol) to create temporary Pure Datastore Volume"
try
{
    $volumename = $scriptparams.purevol + "-snap-" + (Get-Random -Minimum 1000 -Maximum 9999)
    $newpurevol = New-PfaVolume -array $flasharray -source $puresourcesnapshot.name -VolumeName $volumename
    New-PfaHostGroupVolumeConnection -Array $flasharray -VolumeName $newpurevol.name -HostGroupName $scriptparams.purehostgroup
    Write-Host (get-Date -Format G) + " Pure temporary volume $($newpurevol.name) created and mapped to host group $($scriptparams.purehostgroup)"
    $cluster = get-cluster $scriptparams.vcluster
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
        Write-Host (get-Date -Format G) + " Resignaturing the VMFS... $($scriptparams.purevol)"
        $esxcli.storage.vmfs.snapshot.resignature.invoke($resigOp)
        Start-sleep -s 10
        Write-Host (get-Date -Format G) + " Rescanning Hosts in vsphere cluster $($scriptparams.vcluster)..."
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
        Write-Host (get-Date -Format G) + " Presented copied VMFS named  $($resigds.name) "
    }
}
catch
{
    Write-Host (get-Date -Format G) + " FAILED: Datastore creation Failed: $($error[0])" 
    if ($newpurevol -ne $null)
    {
        Write-Host (get-Date -Format G) + " Cleaning up volume... $($Error[0])"
        if ($unresolvedvmfs.UnresolvedExtentCount -eq 1)
        {
            $esxihosts = $resigds |get-vmhost
            foreach ($esxihost in $esxihosts)
            {
                $storageSystem = Get-View $esxihost.Extensiondata.ConfigManager.StorageSystem -ErrorAction stop
	              $StorageSystem.UnmountVmfsVolume($resigds.ExtensionData.Info.vmfs.uuid) 
                $storageSystem.DetachScsiLun((Get-ScsiLun -VmHost $esxihost | where {$_.CanonicalName -eq $resigds.ExtensionData.Info.Vmfs.Extent.DiskName}).ExtensionData.Uuid) 
            }
        }
        Remove-PfaHostGroupVolumeConnection -Array $flasharray -VolumeName $newpurevol.name -HostGroupName $scriptparams.purehostgroup
        Remove-PfaVolumeOrSnapshot -Array $flasharray -Name $newpurevol.name
        Remove-PfaVolumeOrSnapshot -Array $flasharray -Name $newpurevol.name -Eradicate
        Write-Host (get-Date -Format G) + " Rescanning cluster..." 
        $esxi = get-cluster -Name $scriptparams.vcluster | Get-VMHost -ErrorAction stop
        $esxi | Get-VMHostStorage -RescanAllHba -RescanVMFS 
        Write-Host (get-Date -Format G) + " The recovery datastore has been deleted"
    }
    Exit 1
}
try
{
    Start-Sleep -Seconds 6
    $targetvm = Get-VM -name $scriptparams.destvm
    $sourcevm = Get-VM -name $scriptparams.sourcevm
    $datastore = $scriptparams.datastore
    $sourcevmdk = $scriptparams.sourcevmdk
    $filepath = "[$datastore] $($sourcevm.Name)/$sourcevmdk"
    #Write-Host (get-Date -Format G) + " DEBUG: filepath at top of try = $filepath"
    $disk = $sourcevm | get-harddisk |where-object { $_.Filename -eq $filepath } -ErrorAction stop
    if ($targetvm -eq $sourcevm)
    {
        $controller = $disk |Get-ScsiController -ErrorAction stop
    }
    else
    {
        $controller = $targetvm |Get-ScsiController
        $controller = $controller[0]
    }
    $oldname = ($filepath.Split("]")[0]).substring(1)
    #$filepath = $filepath -replace $oldname, $resigds.name
    $filepath = "[$($resigds.name)] $($sourcevm.name)/$sourcevmdk"
    Write-Host (get-Date -Format G) + " DEBUG: Initial target filepath = $filepath"
    Write-Host (get-Date -Format G) + " Adding VMDK from copied datastore $datastore..."
    $vmDisks = $targetvm | get-harddisk
    $vdm = get-view -id (get-view serviceinstance).content.virtualdiskmanager
    $dc=$targetvm |get-datacenter 
    foreach ($vmDisk in $vmDisks)
    {
        $currentUUID=$vdm.queryvirtualdiskuuid($vmDisk.Filename, $dc.id)
        Write-Host (get-Date -Format G) + " DEBUG: vmDisk=$vmDisk and filepath=$filepath"
        if ($currentUUID -eq $oldUUID)
        {
            Write-Host (get-Date -Format G) + " Found duplicate disk UUID on target VM. Assigning a new UUID to the copied VMDK"
            $firstHalf = $oldUUID.split("-")[0]
            $testguid=[Guid]::NewGuid()
            $strGuid=[string]$testguid
            $arrGuid=$strGuid.split("-")
            $secondHalfTemp=$arrGuid[3]+$arrGuid[4]
            $halfUUID=$secondHalfTemp[0]+$secondHalfTemp[1]+" "+$secondHalfTemp[2]+$secondHalfTemp[3]+" "+$secondHalfTemp[4]+$secondHalfTemp[5]+" "+$secondHalfTemp[6]+$secondHalfTemp[7]+" "+$secondHalfTemp[8]+$secondHalfTemp[9]+" "+$secondHalfTemp[10]+$secondHalfTemp[11]+" "+$secondHalfTemp[12]+$secondHalfTemp[13]+" "+$secondHalfTemp[14]+$secondHalfTemp[15]
            $vdm.setVirtualDiskUuid($filePath, $dc.id, $firstHalf+"-"+$halfUUID)
            break
        }
    }
    $newDisk = $targetvm | new-harddisk -DiskPath $filepath -Controller $controller -ErrorAction stop
    Write-Host (get-Date -Format G) + " COMPLETE: VMDK copy added to VM."
    $oldUUID=$vdm.queryvirtualdiskuuid($filePath, $dc.id)
}
catch
{
    Write-Host (get-Date -Format G) + " $($Error[0])"
    Write-Host (get-Date -Format G) + " Attempting to cleanup copied datastore..."
    if ($vms.count -eq 0)
    {
        $esxihosts = $resigds |get-vmhost
        foreach ($esxihost in $esxihosts)
        {
            $storageSystem = Get-View $esxihost.Extensiondata.ConfigManager.StorageSystem -ErrorAction stop
	          $StorageSystem.UnmountVmfsVolume($resigds.ExtensionData.Info.vmfs.uuid) 
            $storageSystem.DetachScsiLun((Get-ScsiLun -VmHost $esxihost | where {$_.CanonicalName -eq $resigds.ExtensionData.Info.Vmfs.Extent.DiskName}).ExtensionData.Uuid) 
        }
        Remove-PfaHostGroupVolumeConnection -Array $flasharray -VolumeName $newpurevol.name -HostGroupName $hostgroup
        Remove-PfaVolumeOrSnapshot -Array $flasharray -Name $newpurevol.name
        Remove-PfaVolumeOrSnapshot -Array $flasharray -Name $newpurevol.name -Eradicate
        Write-Host (get-Date -Format G) + " Rescanning cluster..."
        $targetvm |get-cluster | Get-VMHost | Get-VMHostStorage -RescanAllHba -RescanVMFS -ErrorAction stop 
        Write-Host (get-Date -Format G) + " The recovery datastore has been deleted"
    }
    Exit 1
}
try
{
    Write-Host (get-Date -Format G) + " Moving the VMDK to the original datastore..."
    $targetDatastore = $scriptparams.datastore
    Move-HardDisk -HardDisk $newDisk -Datastore ($targetDatastore) -Confirm:$false -ErrorAction stop
    $vms = $resigds |get-vm
    if ($vms.count -eq 0)
    {
        $esxihosts = $resigds |get-vmhost
        foreach ($esxihost in $esxihosts)
        {
            $storageSystem = Get-View $esxihost.Extensiondata.ConfigManager.StorageSystem -ErrorAction stop
	          $StorageSystem.UnmountVmfsVolume($resigds.ExtensionData.Info.vmfs.uuid) 
            $storageSystem.DetachScsiLun((Get-ScsiLun -VmHost $esxihost | where {$_.CanonicalName -eq $resigds.ExtensionData.Info.Vmfs.Extent.DiskName}).ExtensionData.Uuid) 
        }
        Write-Host (get-Date -Format G) + " Removing copied datastore..."
        Remove-PfaHostGroupVolumeConnection -Array $flasharray -VolumeName $newpurevol.name -HostGroupName $hostgroup
        Remove-PfaVolumeOrSnapshot -Array $flasharray -Name $newpurevol.name
        Remove-PfaVolumeOrSnapshot -Array $flasharray -Name $newpurevol.name -Eradicate
        Write-Host (get-Date -Format G) + " Rescanning cluster..."
        $targetvm |get-cluster | Get-VMHost | Get-VMHostStorage -RescanAllHba -RescanVMFS -ErrorAction stop 
        Write-Host (get-Date -Format G) + " COMPLETE: The VMDK has been moved and the temporary datastore has been deleted"
    }
}
catch
{
    Write-Host (get-Date -Format G) + "  $($Error[0])"
}

$endtime = $(Get-date)
$elapsed = $endtime - $starttime
$totalTime = "{0:HH:mm:ss}" -f ([datetime]$elapsed.Ticks)
Write-Host "Finished at $endtime"
Write-Host "Elapsed duration: $totalTime"

<#
A script to build and maintain a CoreOS cluster
- Builds any machines that don't exist
- Stops and updates machine .vmx file as necessary
- Waits for machine to start before taking down and updating next node

Author: robert.labrie@gmail.com
#>

#list of machines to make - hostname will be set to this unless overridden
$vmlist = @('coreos0','coreos1','coreos2')

#hashmap of machine specific properties
$vminfo = @{}
$vminfo['coreos0'] = @{'interface.0.ip.0.address'='192.168.229.20/24'}
$vminfo['coreos1'] = @{'interface.0.ip.0.address'='192.168.229.21/24'}
$vminfo['coreos2'] = @{'interface.0.ip.0.address'='192.168.229.22/24'}

#hashmap of properties common for all machines
$gProps = @{
    'dns.server.0'='192.168.229.2';
    'interface.0.route.0.gateway'='192.168.229.2';
    'interface.0.route.0.destination'='0.0.0.0/0';
    'interface.0.name' = 'ens192'; 
    'interface.0.role'='private';
    'interface.0.dhcp'='no';}

#pack in the cloud config
if (Test-Path .\cloud-config.yml)
{
    $cc = Get-Content "cloud-config.yml" -raw
    $b = [System.Text.Encoding]::UTF8.GetBytes($cc)
    $gProps['coreos.config.data'] = [System.Convert]::ToBase64String($b)
    $gProps['coreos.config.data.encoding'] = 'base64'
}

#load VMWare snapin and connect
Add-PSSnapin VMware.VimAutomation.Core
if (!($global:DefaultVIServers.Count)) { Connect-VIServer 192.168.229.10 }

#build the VMs as necessary
$template = Get-Template -Name "coreos_alpha"
$vmhost = Get-VMHost
$tasks = @()
foreach ($vmname in $vmlist)
{
    if (get-vm | Where-Object {$_.Name -eq $vmname }) { continue }
    Write-Host "creating $vmname"
    $task = New-VM -Template $template -Name $vmname -host $vmhost -RunAsync
    $tasks += $task
}

#wait for pending builds to complete
if ($tasks)
{
    Write-Host "Waiting for clones to complete"
    foreach ($task in $tasks)
    {
        Wait-Task $task
    }
}

#setup and send the config
foreach ($vmname in $vmlist)
{
    $vmxLocal = "$($ENV:TEMP)\$($vmname).vmx"
    $vm = Get-VM -Name $vmname
    
    #power off if running
    if ($vm.PowerState -eq "PoweredOn") { $vm | Stop-VM -Confirm:$false }

    #fetch the VMX file
    $datastore = $vm | Get-Datastore
    $vmxRemote = "$($datastore.name):\$($vmname)\$($vmname).vmx"
    if (Get-PSDrive | Where-Object { $_.Name -eq $datastore.Name}) { Remove-PSDrive -Name $datastore.Name }
    $null = New-PSDrive -Location $datastore -Name $datastore.Name -PSProvider VimDatastore -Root "\"
    Copy-DatastoreItem -Item $vmxRemote -Destination $vmxLocal
    
    #get the file and strip out any existing guestinfo
    $vmx = ((Get-Content $vmxLocal | Select-String -Pattern guestinfo -NotMatch) -join "`n").Trim()
    $vmx = "$($vmx)`n"

    #build the property bag
    $props = $gProps
    $props['hostname'] = $vmname
    $vminfo[$vmname].Keys | ForEach-Object {
        $props[$_] = $vminfo[$vmname][$_]
    }

    #add to the VMX
    $props.Keys | ForEach-Object {
        $vmx = "$($vmx)guestinfo.$($_) = ""$($props[$_])""`n" 
    }

    #write out the VMX
    $vmx | Out-File $vmxLocal -Encoding ascii

    #replace the VMX in the datastore
    Copy-DatastoreItem -Item $vmxLocal -Destination $vmxRemote

    #start the VM
    $vm | Start-VM
    $status = "toolsNotRunning"
    while ($status -eq "toolsNotRunning")
    {
        Start-Sleep -Seconds 1
        $status = (Get-VM -name $vmname | Get-View).Guest.ToolsStatus
    }
    
}
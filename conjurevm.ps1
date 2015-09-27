#hashmap of props for all machines
$gProps = @{
    'dns.server.0'='192.168.229.2';
    'interface.0.route.0.gateway'='192.168.229.2';
    'interface.0.route.0.destination'='0.0.0.0/0';
    'interface.0.name' = 'ens192'; 
    'interface.0.role'='private';
    'interface.0.dhcp'='no';}

#list of machines to make - hostname will be set to this unless overridden
$vmlist = @('coreos0','coreos1','coreos2')

#vm specific overrides
$vminfo = @{}
$vminfo['coreos0'] = @{'interface.0.ip.0.address'='192.168.229.20/24'}
$vminfo['coreos1'] = @{'interface.0.ip.0.address'='192.168.229.21/24'}
$vminfo['coreos2'] = @{'interface.0.ip.0.address'='192.168.229.22/24'}


#pack in the cloud config
if (Test-Path .\cloud-config.yml)
{
    $cc = Get-Content "cloud-config.yml" -raw
    $b = [System.Text.Encoding]::UTF8.GetBytes($cc)
    $gProps['coreos.config.data'] = [System.Convert]::ToBase64String($b)
    $gProps['coreos.config.data.encoding'] = 'base64'
    #$gProps['coreos.config.data'] = "I2Nsb3VkLWNvbmZpZw0Kd3JpdGVfZmlsZXM6DQogIC0gcGF0aDogL3RtcC90ZXN0DQogICAgY29udGVudDogfA0KICAgICAgICBZQU1MIGlzIGEgbWVuYWNlDQoNCnNzaF9hdXRob3JpemVkX2tleXM6DQogIC0gc3NoLXJzYSBBQUFBQjNOemFDMXljMkVBQUFBREFRQUJBQUFCQVFEdGpUWnhXWGxKTlRjTkxxNDVGN2hDOGZZMDV2bWdueXlWNWhNMVVwRUU3NkNrbHZ3Tzl1TnhiTWw3QVVETDJaOHlTTmNhdXlyZkUxeUVmOTZKd1cxYWl0bkZTSVMraWFWSU1VMmEvdjFGaE0yN09MWUNlK2U5T0oyWU8vWThldHhrRXdXbXZtRUhJRFVXTGFjNW1xQUcxanpNdGhpMm16bFZ1UkVXbWNzV3M3MUtMM0pNVW9qcFFQd0J6WktNUlFiUURsbXU4MjhVWi9icEJKamhiK0t0YldHb2FNUDdiZUordUx3d3BwZ1lkanRUWEsrM2pEajVwSWVUL28wLzlQcm50VjExMXZkeEZNeHVIN1A2bU4vK08raU5WQU9MeUNCc0VwcHhyc2crNXdNaW1jZnUzOGpRSlg1MTY3UUM2b0t0SWliSEtyeGlXWGxMVEhrTHNRbkggcm9iQHVidW50dTANCg=="
}

Add-PSSnapin VMware.VimAutomation.Core
if (!($global:DefaultVIServers.Count)) { Connect-VIServer 192.168.229.10 }

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
if ($tasks)
{
    Write-Host "Waiting for clones to complete"
    foreach ($task in $tasks)
    {
        Wait-Task $task
    }
}
foreach ($vmname in $vmlist)
{
    $vmxLocal = "$($ENV:TEMP)\$($vmname).vmx"
    $vm = Get-VM -Name $vmname
    
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
    #$props

    #add to the VMX
    $props.Keys | ForEach-Object {
        $vmx = "$($vmx)guestinfo.$($_) = ""$($props[$_])""`n" 
    }

    #write out the VMX
    $vmx | Out-File $vmxLocal -Encoding ascii

    #replace the item
    Copy-DatastoreItem -Item $vmxLocal -Destination $vmxRemote

    Write-host "$vmname starting"
    $vm | Start-VM
    $status = "toolsNotRunning"
    while ($status -eq "toolsNotRunning")
    {
        Start-Sleep -Seconds 1
        $status = (Get-VM -name $vmname | Get-View).Guest.ToolsStatus
    }
    
}
$vmDefinitions = @( "../JsonVm/ubugw.json" )
$EXTERNAL_SWITCH = "vsw-LAN"
$INTERNAL_SWITCH = "vsw-phy-TOR"
$OS_DISK_PATH = "C:\temp\ubuvhd\ubuntu-latest.vhdx"


function New-CloudInitIso {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)][string]$JsonConfig,
        [Parameter(Mandatory=$true)][string]$VmPath,
        [Parameter(Mandatory=$true)][hashtable]$InitVariables

    )
    $oscdimgPath = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
    #TODO: solve for windows and linux oscdimg vs mkisofs
    if ($null -eq (Get-Command $oscdimgPath -ErrorAction SilentlyContinue)) {
        throw "oscdimg.exe not found. Please install Windows ADK."
    }

    $vmConfig = $JsonConfig | ConvertFrom-Json
    $vmname = $vmConfig.name

    if ($(Split-Path $vmConfig.cloud_init_path)[0] -eq ".") {
        throw "Relative path is not supported. Please use absolute path."
        #$CoudInitSourcePath = "$($PSScriptRoot)\$($vmConfig.cloud_init_path)"
    }
    else {
        $CloudInitSourcePath = $vmConfig.cloud_init_path
    }

    $vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
    if (!$vm) {
        throw "VM '$VmName' not found."
    }

    #Test if parameter CloudInitSourcePath is existing directory
    if ($CloudInitSourcePath -and !(Test-Path -Path $CloudInitSourcePath -PathType Container)) {
        throw "The specified CloudInitSourcePath '$CloudInitSourcePath' is not a valid directory."
    }

    $vmPath = $vm.Path
    $cidataPath = "$VmPath\cidata"
    if ($(Test-Path $cidataPath)) {
        Remove-Item -Path $cidataPath -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue
    }
    New-Item -Path $cidataPath -ItemType Directory -Force -Confirm:$false -ErrorAction SilentlyContinue



    #add variables to the hashtable
    $vmMacs = $vm | Get-VMNetworkAdapter | Select-Object Name, MacAddress
    foreach ($vmMac in $vmMacs) {
        $value = $vmMac.MacAddress
        $key = $vmMac.Name + "_MAC"
        $InitVariables += (@{$key = $value})
    }
    $InitVariables += (@{"HOSTNAME" = $vmname})

    foreach ($file in Get-ChildItem -Path $CloudInitSourcePath) {
        $fileName = $file.BaseName
        if (! $fileName -in @("user-data", "meta-data", "vendor-data", "network-config"))
        {
            Write-Warning "File '$fileName' is not a valid cloud-init file. Skipping."
            continue
        }
        
        if ($file.Length -gt 0) {
            $fileContent = Get-StringFromTemplate -Template $file.FullName -Variables $InitVariables
        }
        else {
            $fileContent = Get-Content -Path $file.FullName -Raw
        }

        $fileContent | Out-File -Encoding ASCII "$cidataPath\$fileName"            
    }

    # Create the ISO file
    $cloudInitISO = "$VmPath\cloud-init.iso"
    & $oscdimgPath -lcidata -n "$cidataPath" "$cloudInitISO" 
}

function Get-StringFromTemplate {
    param (
        [Parameter(Mandatory=$true)][string]$Template,
        [Parameter(Mandatory=$false)][object]$Variables
    )
    # Get placeholders from the YAML file
    $placeholders = Show-Variables -JsonTemplate $Template

    # Read the YAML file
    $yamlContent = Get-Content -Path $Template -Raw 

    # Replace placeholders with variable values
    foreach ($placeholder in $placeholders) {
        # Get the value of the variable with the same name as the placeholder
        # If variables is null
        if ($null -eq $Variables) {

            try {
                $replacementValue = Get-Variable -Name $placeholder -ValueOnly
            }
            catch {
                Write-Host "Variable '$placeholder' not found. Skipping replacement."
            }
            $replacementValue = Get-Variable -Name $placeholder -ValueOnly
    
            # Replace the placeholder in the YAML content
            if ($replacementValue) {
                $yamlContent = $yamlContent -replace [regex]::Escape("<$placeholder>"), $replacementValue
            }
        }
        else {
            try {
                $replacementValue = $Variables.$placeholder
            }
            catch {
                Write-Host "Variable '$placeholder' not found in provided variables. Skipping replacement."
            }
            # Replace the placeholder in the YAML content
            if ($replacementValue) {
                $yamlContent = $yamlContent -replace [regex]::Escape("<$placeholder>"), $replacementValue
            }
        }
    }
    return $yamlContent
}


function New-HyperVM {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)][string]$JsonConfig,
        [Parameter(Mandatory=$true)][string]$VmPath
    )
    $vmConfig = $JsonConfig | ConvertFrom-Json
    $vmname = $vmConfig.name
    $vm = New-VM -Name $vmname -MemoryStartupBytes $vmConfig.ram -Generation 2 -Path $VmPath -NoVHD
    $vm | Remove-VMNetworkAdapter
    $vm | Set-VMProcessor -Count $vmConfig.Cpu
    if (!$vmConfig.secure_boot) {
        $vm | Set-VMFirmware -EnableSecureBoot Off
    }
    if ($vmConfig.nested_virtualization) {
        $vm | Set-VMProcessor -ExposeVirtualizationExtensions $true
    }
    # Add Hard Disk
    if ($null -eq $vmConfig.disks -or $vmConfig.disks.Count -eq 0) {
        Write-Host "No disks found in the JSON configuration. Skipping disk creation."
    }
    else {
        $count = 0
        foreach ($disk in $vmConfig.disks) {
            if ($disk.source_path) {
                $diskPath = $disk.source_path
                if (! (Test-Path $diskPath)) {
                    Write-Error "Disk source path does not exists: $diskPath"
                    break
                }
                else {
                    Copy-Item -Path $diskPath -Destination "$vmPath\${vmname}\${vmname}-os.vhdx"
                    Add-VMHardDiskDrive -VMName $vmname -Path "$vmPath\${vmname}\${vmname}-os.vhdx"
                }
            }
            else {
                if ($disk.size -eq 0) {
                    Write-Error "Disk size is not specified in the JSON configuration."
                    break
                }
                else {
                    $count++
                    $cntStr = $("{0:D2}" -f $count)
                    $vhdPath = "$vmPath\${vmname}\${vmname}-dat$cntStr.vhdx"
                    $vhd = New-VHD -Path $vhdPath -SizeBytes $disk.size -Dynamic
                    Add-VMHardDiskDrive -VMName $vmname -Path $vhdPath
                }
            }
        }
    }
    # Add Network Adapters
    if ($null -eq $vmConfig.network_adapters -or $vmConfig.network_adapters.Count -eq 0) {
        Write-Host "No network adapters found in the JSON configuration. Skipping network adapter creation."
    }
    else {
        foreach ($adapter in $vmConfig.network_adapters) {
            $vmAdapter = Add-VMNetworkAdapter -VMName $vmname -SwitchName $adapter.switch_name -Name $adapter.adapter_name -Passthru
            if ($adapter.mac_address) {
                $vmAdapter | Set-VMNetworkAdapter -StaticMacAddress $adapter.mac_address
            }
            if ($adapter.trunk) {
                $vmAdapter | Set-VMNetworkAdapterVlan -Trunk -AllowedVlanIdList $adapter.trunk -NativeVlanId $($adapter.vlan_id ?? 0)
            }
            if (!$adapter.trunk -and $adapter.vlan_id) {
                $vmAdapter | Set-VMNetworkAdapterVlan -Access -VlanId $adapter.vlan_id
            }
            if ($adapter.mac_spoofing) {
                $vmAdapter | Set-VMNetworkAdapter -MacAddressSpoofing On
            }
        }
    }

}

function Remove-HyperVM{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)][string]$VmName
    )
    $vm = Get-VM -Name $VmName
    $vmPath = $vm.Path
    if ($vm) {
        Stop-VM -VM $vm -Force -ErrorAction SilentlyContinue
        $vm |Get-VMSnapshot | Remove-VMSnapshot -Confirm:$false -IncludeAllChildSnapshots
        $disks = $vm | Get-VHD -ErrorAction SilentlyContinue | Remove-VMHardDiskDrive -Confirm:$false -Passthru
        foreach ($disk in $disks) {
            if ($null -ne $disk.Path) {
                Remove-Item -Path $disk.Path -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        Remove-VM -VM $vm -Confirm:$false -Force
        Remove-Item -Path $VmPath -Recurse -Force -Confirm:$false 
    }
}
function Get-JsonFromTemplate {
    param (
        [Parameter(Mandatory=$true)][string]$JsonTemplate,
        [Parameter(Mandatory=$false)][object]$Variables
    )
    # Get placeholders from the JSON file
    $placeholders = Show-Variables -JsonTemplate $JsonTemplate

    # Read the JSON file
    $jsonContent = Get-Content -Path $JsonTemplate -Raw 

    # Replace placeholders with variable values
    foreach ($placeholder in $placeholders) {
        # Get the value of the variable with the same name as the placeholder
        # If variables is null
        if ($null -eq $Variables) {

            try {
                $replacementValue = Get-Variable -Name $placeholder -ValueOnly
            }
            catch {
                Write-Host "Variable '$placeholder' not found. Skipping replacement."
            }
            $replacementValue = Get-Variable -Name $placeholder -ValueOnly
    
            # Replace the placeholder in the JSON content
            if ($replacementValue) {
                $jsonContent = $jsonContent -replace [regex]::Escape("<$placeholder>"), $replacementValue
            }
        }
        else {
            try {
                $replacementValue = $Variables.$placeholder
            }
            catch {
                Write-Host "Variable '$placeholder' not found in provided variables. Skipping replacement."
            }
            # Replace the placeholder in the JSON content
            if ($replacementValue) {
                $jsonContent = $jsonContent -replace [regex]::Escape("<$placeholder>"), $replacementValue
            }
        }
    }
    # Convert JSON to PowerShell object
    try {
        $jsonObject = $jsonContent | ConvertFrom-Json
    }
    catch {
        Write-Host "Error converting JSON content to PowerShell object. Please check the JSON syntax."
        Write-Host "Error details: $_"
        return $null
    }
    $jsonObject = $jsonContent

    return $jsonObject
}



<#
.SYNOPSIS
Extracts and displays variable placeholders from a JSON file.

.DESCRIPTION
The `Show-Variables` function reads a JSON file and extracts all placeholders enclosed in angle brackets (`<` and `>`). 
It uses regular expressions to identify and return the content within the angle brackets.

.PARAMETER jsonFile
The path to the JSON file from which variable placeholders will be extracted.

.EXAMPLE
PS> Show-Variables -jsonFile "C:\path\to\file.json"
This command reads the specified JSON file and outputs all placeholders enclosed in angle brackets.

.NOTES
- Ensure the JSON file exists and is accessible at the specified path.
- Placeholders are expected to be in the format `<placeholder>` within the JSON content.
#>
function Show-Variables {
    param (
        [string]$JsonTemplate
    )

    # Read the JSON file
    $jsonContent = Get-Content -Path $JsonTemplate -Raw 

    [regex]::Matches($jsonContent, "<(.*?)>") | ForEach-Object { $_.Groups[1].Value }
}
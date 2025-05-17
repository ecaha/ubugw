## New-HyperVM samples

## Show-Variables
It shows "variables" aka <CAPITAL_STRINGS> from json file

```Powershell
Show-Variables ./JsonVM/ubugw.json
```

## Get-JsonFromTemplate

Replaces variables in a JSON file and returns a JSON object. The replacement can be implicit—environment variables with the same name are used—or explicit, where an object with variables is passed.

Internaly it usess Show-Variables function.

```Powershell
#Implicit
$EXTERNAL_SWITCH = "vsw-LAN"
$INTERNAL_SWITCH = "vsw-phy-TOR"
$OS_DISK_PATH = "C:\temp\ubuvhd\ubuntu-latest.vhdx"

Get-JsonFromTemplate ./JsonVM/ubugw.json
```

```Powershell
#Explicit
$vars = @{
    EXTERNAL_SWITCH = "Internet"
    INTERNAL_SWITCH = "LAN"
    OS_DISK_PATH = "C:\temp\ubuvhd\ubuntu-latest.vhdx"
}

Get-JsonFromTemplate -JsonTemplate ./JsonVM/ubugw.json -Variables $vars
```

## New-HyperVM

```Powershell
#Explicit
$vars = @{
    EXTERNAL_SWITCH = "Internet"
    INTERNAL_SWITCH = "LAN"
    OS_DISK_PATH = "C:\\temp\\ubuvhd\\ubuntu-latest.vhdx"
}
$vmLocation = "C:\VM\test"
$JsonConfig = Get-JsonFromTemplate -JsonTemplate ./JsonVM/ubugw.json -Variables $vars

New-HyperVM -JsonConfig $JsonConfig -VmPath $vmLocation 
```

##  New-CloudInitIso


```Powershell
#Explicit
$vars = @{
    EXTERNAL_SWITCH = "Internet"
    INTERNAL_SWITCH = "LAN"
    OS_DISK_PATH = "C:\\temp\\ubuvhd\\ubuntu-latest.vhdx"
}
$vmLocation = "C:\VM\test"
$JsonConfig = Get-JsonFromTemplate -JsonTemplate ./JsonVM/ubugw.json -Variables $vars

New-CloudInitIso -JsonConfig $JsonConfig -VmPath $vmLocation -InitVariables @{}  
```

```Powershell
$vm = Get-VM ubugw
$vm | Add-vmdv
```
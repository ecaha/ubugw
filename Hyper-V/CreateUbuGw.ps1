# Variables
$vmName = "ubugw"
$sourceVhdxPath = "C:\temp\ubuvhd\ubuntu-latest.vhdx"
$vmSwitchExternal = "vsw-LAN"  # Replace with your external switch name
$vmSwitchInternal = "vsw-phy-TOR"  # Replace with your internal switch name
$memoryStartupBytes = 2GB
$vmPath = "C:\VM\ubugw\$vmName"

# Create VM
New-VM -Name $vmName -MemoryStartupBytes $memoryStartupBytes -Generation 2 -Path $vmPath -NoVHD 

# Attach VHDX
Set-VM -Name $vmName -ProcessorCount 2
Copy-Item -Path $sourceVhdxPath -Destination "$vmPath\$vmName.vhdx"
Add-VMHardDiskDrive -VMName $vmName -Path "$vmPath\$vmName.vhdx"
#Set-VMHardDiskDrive -VMName $vmName -ControllerType SCSI -ControllerNumber 0 -ControllerLocation 0



# Disable Secure Boot
Set-VMFirmware -VMName $vmName -EnableSecureBoot Off

Get-VMNetworkAdapter -VMName $vmName | Remove-VMNetworkAdapter
# Add Network Adapters
Add-VMNetworkAdapter -VMName $vmName -SwitchName $vmSwitchExternal -Name "ExternalNIC"
Add-VMNetworkAdapter -VMName $vmName -SwitchName $vmSwitchInternal -Name "InternalNIC"

# Configure Cloud-Init
$cloudInitISO = "$vmPath\cloud-init.iso"
$cidataPath = "$vmPath\cidata"
New-Item -Path $cidataPath -ItemType Directory -Force
$cloudInitConfig = @"
#cloud-config
hostname: $vmName
chpasswd:
  expire: false
ssh_pwauth: true
package_update: true
users:
  - name: ubuntu
    password: "Slon123456"
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    groups: sudo
    shell: /bin/bash
runcmd:
  - sysctl -w net.ipv4.ip_forward=1
  - iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
  - iptables -A FORWARD -i eth1 -o eth0 -j ACCEPT
  - iptables -A FORWARD -i eth0 -o eth1 -m state --state RELATED,ESTABLISHED -j ACCEPT
  - echo 1 > /proc/sys/net/ipv4/ip_forward
  - echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
  - iptables-save > /etc/iptables/rules.v4
"@
$cloudInitConfig | Out-File -Encoding ASCII "$cidataPath\user-data"
@"
#network-config
version: 2
ethernets:
  eth0:
    dhcp4: true
  eth1:
    dhcp4: false
    dhcp6: false
    vlan:
      id: 1000
      link: eth1
      addresses:
        - 192.168.100.1/24
"@ | Out-File -Encoding ASCII "$cidataPath\network-config"

# Create ISO for Cloud-Init
# Use Windows ADK tools to create the ISO for Cloud-Init
#$oscdimgPath = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\Oscdimg\oscdimg.exe"
oscdimg -lcidata -n "$cidataPath" "$cloudInitISO"

# Attach Cloud-Init ISO
Add-VMDvdDrive -VMName $vmName -Path $cloudInitISO

# Start VM
Start-VM -Name $vmName

#Get-VM -Name $vmName | Stop-VM -Force -Passthru|Remove-VM -Force; Start-Sleep 5; Remove-Item -Path $vmPath -Recurse -Force
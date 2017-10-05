<#
    .SYNOPSIS

        This script will do the following:

            * Create SDN VM Network
            * Create VM Network Subnet within above VM Network
            * Create Static IP Pool for above VM Network
            * Set Existing VM NIC to use above VM Network (multiple VMs can be passed here)
            * Enable NAT on new VM Network


    .DESCRIPTION

        This script should be run once during the deployment of a customer solution. Here are a list of requirements:
            * Customer VMs should be deployed before the script - you can enter as many VMs as required in the -VMName parameter.
            * VMs should have only one NIC at the point this script is run.  You can add more as required.


    .EXAMPLE

        .\Create-SDNVMNetwork.ps1

        The above command shows an example of running the script with no parameters, you will be prompted to enter values for mandatory parameters

    .EXAMPLE

        .\Create-SDNVMNetwork.ps1 -VMNetworkName "Test VM Network" -SubnetIP "10.10.10.0" -SubnetMask "255.255.255.0" -SubnetName "Frontend" -DNSServer "8.8.8.8" -VMName "Test-VM1", "Test-VM2"

        The above command shows an example of running the script specifying all mandatory parameters
#>

Function Create-SDNVMNetwork {
[CmdletBinding()]
Param(
    # Specifies the name of the VM Network being created
    [Parameter(Mandatory=$True)]
    [string]$VMNetworkName,

    # Specifies any IP within your subnet range, the script will work out the correct network address and prefix based on the "SubnetMask" you enter.
    # Example:  For the 10.10.10.0/24 subnet, 10.10.10.0 - 10.10.10.255 will be accepted here
    [Parameter(Mandatory=$True)]
    [ipaddress]$SubnetIP,

    # Specifies the subnet mask for your subnet
    [Parameter(Mandatory=$True)]
    [ipaddress]$SubnetMask,

    # Specifies the name of the subnet being created e.g. Frontend
    # Once created, the final name will be made up of both the VM Network name and Subnet name e.g. "My VM Network - Frontend"
    [Parameter(Mandatory=$True)]
    [string]$SubnetName,

    # Specifies a single DNS server for your static IP pool
    [Parameter(Mandatory=$True)]
    [string]$DNSServer,

    # Specifies a VM or VMs (by name as it appears in SCVMM) to add to the new VM Network
    # Example:  "VMName1", "VMName2", "VMName3"
    [Parameter(Mandatory=$True)]
    [string[]]$VMName
)


#region  Subnet to CIDR Functions
# Function to convert IP address string to binary
function ToBinary ($DottedDecimal){
 $DottedDecimal.split(".") | ForEach-Object {$Binary=$Binary + $([convert]::toString($_,2).padleft(8,"0"))}
 return $Binary
}


# Function to convert binary IP address to dotted decimal string
function ToDottedDecimal ($Binary){
 do {$DottedDecimal += "." + [string]$([convert]::toInt32($Binary.substring($i,8),2)); $i+=8 } while ($i -le 24)
 return $DottedDecimal.substring(1)
}


# Function to convert network mask to wildcard format
function NetMasktoWildcard ($Wildcard) {
    foreach ($Bit in [char[]]$Wildcard) {
        if ($Bit -eq "1") {
            $WildcardMask += "0"
            }
        elseif ($Bit -eq "0") {
            $WildcardMask += "1"
            }
        }
    return $WildcardMask
    }
#endregion


#region obtain Subnet CIDR, Default GW, Subnet Start and End IPs
[string]$SubnetIP = $SubnetIP
[string]$SubnetMask = $SubnetMask

$IPBinary = ToBinary $SubnetIP
$SMBinary = ToBinary $SubnetMask
$WildcardBinary = NetMasktoWildcard ($SMBinary)
$NetBits=$SMBinary.indexOf("0")


# If there is a 0 found then the subnet mask is less than 32 (CIDR).
if ($NetBits -ne -1) {
    $CIDR = $NetBits
    #Validate the subnet mask
    if(($SMBinary.length -ne 32) -or ($SMBinary.substring($NetBits).contains("1") -eq $true)) {
        Write-Warning "Subnet Mask is invalid!"
        Exit
        }
    # Validate the IP address
    if($IPBinary.length -ne 32) {
        Write-Warning "IP Address is invalid!"
        Exit
        }
    #identify subnet boundaries
    $NetworkID = ToDottedDecimal $($IPBinary.substring(0,$NetBits).padright(32,"0"))
    $SubnetGW = ToDottedDecimal $($IPBinary.substring(0,$NetBits).padright(31,"0") + "1")
    [string]$SubnetStartSplit = [int32]$SubnetGW.Split(".")[3] + "3"
    $SubnetStart = $SubnetGW.Split(".")[0,1,2] + $SubnetStartSplit -join "."
    $SubnetEnd = ToDottedDecimal $($IPBinary.substring(0,$NetBits).padright(31,"1") + "0")
    $SubnetCIDR = "$NetworkID/$CIDR"
    }
#endregion



#region Create SDN Networking

# Create Tenant VM Network
Write-Verbose "Creating SDN Tenant VM Network, Subnet and IP Pool" -Verbose
$VMNetwork = New-SCVMNetwork `
    -Name $VMNetworkName `
    -LogicalNetwork (Get-SCLogicalNetwork | ? NetworkVirtualizationEnabled -eq true | ? IsManagedByNetworkController -eq true).Name `
    -IsolationType "WindowsNetworkVirtualization" `
    -CAIPAddressPoolType "IPV4" `
    -PAIPAddressPoolType "IPV4"

# Create Tenant VM Subnet
$Subnet = New-SCSubnetVLan -Subnet "$SubnetCIDR"

$VMSubnet = New-SCVMSubnet -Name ($VMNetworkName + " - " + $SubnetName) `
                           -VMNetwork $VMNetwork `
                           -SubnetVLan $Subnet

# Create Tenant VM Network IP Pool
$DefaultGateway = New-SCDefaultGateway -IPAddress $SubnetGW -Automatic -WarningAction SilentlyContinue

New-SCStaticIPAddressPool -Name ($VMNetworkName + " - " + $SubnetName + " - IP Pool") `
                          -VMSubnet $VMSubnet `
                          -Subnet $SubnetCIDR `
                          -IPAddressRangeStart $SubnetStart `
                          -IPAddressRangeEnd $SubnetEnd `
                          -DefaultGateway $DefaultGateway `
                          -DNSServer $DNSServer `
                          -RunAsynchronously
#endregion

#region Attach VMs to new Tenant VM Network

Write-Verbose "Attaching VM to Tenant SDN VM Network" -Verbose
$VMSwitch = Get-SCLogicalSwitch | ? VirtualSwitchExtensions -like "*Microsoft Network Controller"

$VMNICs = foreach ($VM in $VMName)
            {
            Get-SCVirtualMachine -Name $VM | Get-SCVirtualNetworkAdapter
            }

foreach ($VMNIC in $VMNICs)
        {
        Set-SCVirtualNetworkAdapter -VirtualNetworkAdapter $VMNIC `
                                    -VMNetwork $VMNetwork `
                                    -VMSubnet $VMSubnet `
                                    -VirtualNetwork $VMSwitch `
                                    -IPv4AddressType Dynamic `
                                    -IPv6AddressType Dynamic `
                                    -NoPortClassification
        }
#endregion

#region Enable Outbound NAT on above VM Network

Write-Verbose "Enabling Tenant SDN VM Network NAT Connection" -Verbose
Add-SCNATConnection -VMNetwork $VMNetwork `
                    -Name ($VMNetworkName + "_NatConnection") `
                    -ExternalIPPool (Get-SCStaticIPAddressPool -LogicalNetworkDefinition (Get-SCLogicalNetworkDefinition -LogicalNetwork (Get-SCLogicalNetwork | ? IsPublicIPNetwork -eq $true)))
#endregion
    }

# SIG # Begin signature block
# MIIOQQYJKoZIhvcNAQcCoIIOMjCCDi4CAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUPe+WSAwBt8RNwHtfVrvjpLsp
# 5ACgggt4MIIFkDCCBHigAwIBAgIQGnZ3uXePQtlbRNV1EWeAqTANBgkqhkiG9w0B
# AQsFADB9MQswCQYDVQQGEwJHQjEbMBkGA1UECBMSR3JlYXRlciBNYW5jaGVzdGVy
# MRAwDgYDVQQHEwdTYWxmb3JkMRowGAYDVQQKExFDT01PRE8gQ0EgTGltaXRlZDEj
# MCEGA1UEAxMaQ09NT0RPIFJTQSBDb2RlIFNpZ25pbmcgQ0EwHhcNMTcwNjI2MDAw
# MDAwWhcNMTgwNjI2MjM1OTU5WjCB1TELMAkGA1UEBhMCR0IxEDAOBgNVBBEMB0RE
# MiAxU1cxEDAOBgNVBAgMB1RheXNpZGUxDzANBgNVBAcMBkR1bmRlZTE5MDcGA1UE
# CQwwR2F0ZXdheSBIb3VzZSBMdW5hIFBsYWNlLCBEdW5kZWUgVGVjaG5vbG9neSBQ
# YXJrMSowKAYDVQQKDCFCcmlnaHRTb2xpZCBPbmxpbmUgVGVjaG5vbG9neSBMdGQx
# KjAoBgNVBAMMIUJyaWdodFNvbGlkIE9ubGluZSBUZWNobm9sb2d5IEx0ZDCCASIw
# DQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAOj56njAPXlfyxLvK4r0bdV6+bVL
# Qj2n2FVoU6IZaG4V0YjqbFN8toYdH3fyVn9OYiWneIZpE/1a8QGkUznMYCUnvHAv
# Lv0Zob9HUjEbqLh9Uu+xUurUu97LFd42EJaCO8pCQiLZyUhmradeQoxrveTJAmTN
# tnujL+falNkkz+G5vFi4SLpoLJEugIfQCPLoOsnEgKLmQ5zSAwmMIL29JayySumN
# NaQhKUz6uHgqEy0IKZ5w8lt73nAM1NVuB8XTE/w6/KgBhmykXr8EOXQC9rxCbLmn
# nW4c8pZTUivrur2X2TZaa3yXjh5ik4tq0A2AMptP940+XSFgQmKHqgbGQOkCAwEA
# AaOCAbEwggGtMB8GA1UdIwQYMBaAFCmRYP+KTfrr+aZquM/55ku9Sc4SMB0GA1Ud
# DgQWBBT+0yuVD9skRrKps5OOIn/ZUgFKhDAOBgNVHQ8BAf8EBAMCB4AwDAYDVR0T
# AQH/BAIwADATBgNVHSUEDDAKBggrBgEFBQcDAzARBglghkgBhvhCAQEEBAMCBBAw
# RgYDVR0gBD8wPTA7BgwrBgEEAbIxAQIBAwIwKzApBggrBgEFBQcCARYdaHR0cHM6
# Ly9zZWN1cmUuY29tb2RvLm5ldC9DUFMwQwYDVR0fBDwwOjA4oDagNIYyaHR0cDov
# L2NybC5jb21vZG9jYS5jb20vQ09NT0RPUlNBQ29kZVNpZ25pbmdDQS5jcmwwdAYI
# KwYBBQUHAQEEaDBmMD4GCCsGAQUFBzAChjJodHRwOi8vY3J0LmNvbW9kb2NhLmNv
# bS9DT01PRE9SU0FDb2RlU2lnbmluZ0NBLmNydDAkBggrBgEFBQcwAYYYaHR0cDov
# L29jc3AuY29tb2RvY2EuY29tMCIGA1UdEQQbMBmBF3N1cHBvcnRAYnJpZ2h0c29s
# aWQuY29tMA0GCSqGSIb3DQEBCwUAA4IBAQBrYgfoE6lpQjRBl8lOW8a8tMDb8cwG
# kiGJWJr4Oi9JfOtszaBk7bKu9PrnNZvwTxi8YM25nPHNHfEeIdAmwB556HBuGrqE
# okxlcTg3DbzORLehtaZOlIaWCgWuk7jNwG7cXoyqtJA7iKLeLftMRW3ghY3pj5A6
# xJYFPNdg9BP1wYaOLnC7pob64ClFuAzj3fGVlYYRsZGdJ5eKXjZQ7/hRO4A1jnq3
# OQ8yrgJba5cizbaZp6Dgf731zFs+T3JujeM5cSEuLD+L7XX4accIaz7I5MGLc/X0
# daxtO4KkQNsBSUCT7p9QCmXGsATt6z5zDsJONUmWSeBguYe3XppEhdRyMIIF4DCC
# A8igAwIBAgIQLnyHzA6TSlL+lP0ct800rzANBgkqhkiG9w0BAQwFADCBhTELMAkG
# A1UEBhMCR0IxGzAZBgNVBAgTEkdyZWF0ZXIgTWFuY2hlc3RlcjEQMA4GA1UEBxMH
# U2FsZm9yZDEaMBgGA1UEChMRQ09NT0RPIENBIExpbWl0ZWQxKzApBgNVBAMTIkNP
# TU9ETyBSU0EgQ2VydGlmaWNhdGlvbiBBdXRob3JpdHkwHhcNMTMwNTA5MDAwMDAw
# WhcNMjgwNTA4MjM1OTU5WjB9MQswCQYDVQQGEwJHQjEbMBkGA1UECBMSR3JlYXRl
# ciBNYW5jaGVzdGVyMRAwDgYDVQQHEwdTYWxmb3JkMRowGAYDVQQKExFDT01PRE8g
# Q0EgTGltaXRlZDEjMCEGA1UEAxMaQ09NT0RPIFJTQSBDb2RlIFNpZ25pbmcgQ0Ew
# ggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCmmJBjd5E0f4rR3elnMRHr
# zB79MR2zuWJXP5O8W+OfHiQyESdrvFGRp8+eniWzX4GoGA8dHiAwDvthe4YJs+P9
# omidHCydv3Lj5HWg5TUjjsmK7hoMZMfYQqF7tVIDSzqwjiNLS2PgIpQ3e9V5kAoU
# GFEs5v7BEvAcP2FhCoyi3PbDMKrNKBh1SMF5WgjNu4xVjPfUdpA6M0ZQc5hc9IVK
# aw+A3V7Wvf2pL8Al9fl4141fEMJEVTyQPDFGy3CuB6kK46/BAW+QGiPiXzjbxghd
# R7ODQfAuADcUuRKqeZJSzYcPe9hiKaR+ML0btYxytEjy4+gh+V5MYnmLAgaff9UL
# AgMBAAGjggFRMIIBTTAfBgNVHSMEGDAWgBS7r34CPfqm8TyEjq3uOJjs2TIy1DAd
# BgNVHQ4EFgQUKZFg/4pN+uv5pmq4z/nmS71JzhIwDgYDVR0PAQH/BAQDAgGGMBIG
# A1UdEwEB/wQIMAYBAf8CAQAwEwYDVR0lBAwwCgYIKwYBBQUHAwMwEQYDVR0gBAow
# CDAGBgRVHSAAMEwGA1UdHwRFMEMwQaA/oD2GO2h0dHA6Ly9jcmwuY29tb2RvY2Eu
# Y29tL0NPTU9ET1JTQUNlcnRpZmljYXRpb25BdXRob3JpdHkuY3JsMHEGCCsGAQUF
# BwEBBGUwYzA7BggrBgEFBQcwAoYvaHR0cDovL2NydC5jb21vZG9jYS5jb20vQ09N
# T0RPUlNBQWRkVHJ1c3RDQS5jcnQwJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmNv
# bW9kb2NhLmNvbTANBgkqhkiG9w0BAQwFAAOCAgEAAj8COcPu+Mo7id4MbU2x8U6S
# T6/COCwEzMVjEasJY6+rotcCP8xvGcM91hoIlP8l2KmIpysQGuCbsQciGlEcOtTh
# 6Qm/5iR0rx57FjFuI+9UUS1SAuJ1CAVM8bdR4VEAxof2bO4QRHZXavHfWGshqknU
# fDdOvf+2dVRAGDZXZxHNTwLk/vPa/HUX2+y392UJI0kfQ1eD6n4gd2HITfK7ZU2o
# 94VFB696aSdlkClAi997OlE5jKgfcHmtbUIgos8MbAOMTM1zB5TnWo46BLqioXwf
# y2M6FafUFRunUkcyqfS/ZEfRqh9TTjIwc8Jvt3iCnVz/RrtrIh2IC/gbqjSm/Iz1
# 3X9ljIwxVzHQNuxHoc/Li6jvHBhYxQZ3ykubUa9MCEp6j+KjUuKOjswm5LLY5TjC
# qO3GgZw1a6lYYUoKl7RLQrZVnb6Z53BtWfhtKgx/GWBfDJqIbDCsUgmQFhv/K53b
# 0CDKieoofjKOGd97SDMe12X4rsn4gxSTdn1k0I7OvjV9/3IxTZ+evR5sL6iPDAZQ
# +4wns3bJ9ObXwzTijIchhmH+v1V04SF3AwpobLvkyanmz1kl63zsRQ55ZmjoIs24
# 75iFTZYRPAmK0H+8KCgT+2rKVI2SXM3CZZgGns5IW9S1N5NGQXwH3c/6Q++6Z2H/
# fUnguzB9XIDj5hY5S6cxggIzMIICLwIBATCBkTB9MQswCQYDVQQGEwJHQjEbMBkG
# A1UECBMSR3JlYXRlciBNYW5jaGVzdGVyMRAwDgYDVQQHEwdTYWxmb3JkMRowGAYD
# VQQKExFDT01PRE8gQ0EgTGltaXRlZDEjMCEGA1UEAxMaQ09NT0RPIFJTQSBDb2Rl
# IFNpZ25pbmcgQ0ECEBp2d7l3j0LZW0TVdRFngKkwCQYFKw4DAhoFAKB4MBgGCisG
# AQQBgjcCAQwxCjAIoAKAAKECgAAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQw
# HAYKKwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwIwYJKoZIhvcNAQkEMRYEFKA/
# jV0zS5x+N0lZ6FyVW3MDSdOFMA0GCSqGSIb3DQEBAQUABIIBAGmjzDd1zdbEbWLx
# Ft5Xsff97Tp+jxY+V9txHJD526r+Okm8FjY79MOYICbYLRIlaQsgTF/SgWx2Mthm
# sjs/l5n7zxqu2pUk9/jr+hY3TJD5lOtKgz3x6y1RtPnBchAHCztRjsLSklOhXkvj
# Re9FC408wPU1+7iWfGxiDV4UGblh+sUC0SYdC2d567lUgJuHH/Uaq3+nc3pOHcAo
# UH94/Xm6mclonyBR28Rzc1sYD1DbGjWFPOVX4CKYFlQANR3AX8teMI00LtHieLB8
# lARLKEyOuqFt036lmvjNPak+3cwMWqQpbZzukkpqTK2wf+gxpLhILk9Fytj9tq80
# O9P4jpM=
# SIG # End signature block

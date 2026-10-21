Description: Hayabusa-Bulk-Runner host identity
Author: Hayabusa-Bulk-Runner
Version: 1
Id: 4113c792-e312-40a2-82be-b30998f0e55a
Keys:
#
# A short subset of the entries in RECmd's standard batch files
# (BatchExamples\Kroll_Batch.reb and RECmd_Batch_MC.reb), kept to the host
# identity artifacts lib\HostIdentity.ps1 parses, so the output columns stay
# the same from run to run. Machine hives only: SYSTEM, SOFTWARE and SAM.
# Nothing from NTUSER, and no value that holds a credential, such as
# Winlogon\DefaultPassword.
#
# SYSTEM. ControlSet00* matches every control set in the hive. The parser
# keeps only the active one, named by Select\Current.
    -
        Description: Current Control Set Name
        HiveType: SYSTEM
        Category: Host Identity
        KeyPath: Select
        ValueName: Current
        Recursive: false
        Comment: Number of the active control set
    -
        Description: ComputerName
        HiveType: SYSTEM
        Category: Host Identity
        KeyPath: ControlSet00*\Control\ComputerName\ComputerName
        ValueName: ComputerName
        Recursive: false
        Comment: Computer name
    -
        Description: TimeZoneInformation
        HiveType: SYSTEM
        Category: Host Identity
        KeyPath: ControlSet00*\Control\TimeZoneInformation
        Recursive: false
        DisablePlugin: true
        Comment: Time zone name and biases, as raw values
    -
        Description: Tcpip Domain
        HiveType: SYSTEM
        Category: Host Identity
        KeyPath: ControlSet00*\Services\Tcpip\Parameters
        ValueName: Domain
        Recursive: false
        Comment: DNS domain of the computer
    -
        Description: Tcpip NV Domain
        HiveType: SYSTEM
        Category: Host Identity
        KeyPath: ControlSet00*\Services\Tcpip\Parameters
        ValueName: NV Domain
        Recursive: false
        Comment: DNS domain of the computer, as set
#
# One recursive entry: the NetworkSettings and DHCPNetworkHint plugins read
# the Interfaces key, and the raw values of each interface come with it for
# DefaultGateway and NameServer, which the plugins don't carry. A second
# entry for the same interfaces would only repeat the rows.
    -
        Description: Network Interfaces
        HiveType: SYSTEM
        Category: Host Identity
        KeyPath: ControlSet00*\Services\Tcpip\Parameters\Interfaces
        Recursive: true
        Comment: Interface addressing, leases and DHCP network hints
#
# SOFTWARE
    -
        Description: ProductName
        HiveType: SOFTWARE
        Category: Host Identity
        KeyPath: Microsoft\Windows NT\CurrentVersion
        ValueName: ProductName
        Recursive: false
        Comment: OS name
    -
        Description: EditionID
        HiveType: SOFTWARE
        Category: Host Identity
        KeyPath: Microsoft\Windows NT\CurrentVersion
        ValueName: EditionID
        Recursive: false
        Comment: OS edition
    -
        Description: DisplayVersion
        HiveType: SOFTWARE
        Category: Host Identity
        KeyPath: Microsoft\Windows NT\CurrentVersion
        ValueName: DisplayVersion
        Recursive: false
        Comment: OS release, such as 22H2
    -
        Description: ReleaseId
        HiveType: SOFTWARE
        Category: Host Identity
        KeyPath: Microsoft\Windows NT\CurrentVersion
        ValueName: ReleaseId
        Recursive: false
        Comment: OS release on older builds, such as 1909
    -
        Description: CurrentBuild
        HiveType: SOFTWARE
        Category: Host Identity
        KeyPath: Microsoft\Windows NT\CurrentVersion
        ValueName: CurrentBuild
        Recursive: false
        Comment: OS build
    -
        Description: CurrentBuildNumber
        HiveType: SOFTWARE
        Category: Host Identity
        KeyPath: Microsoft\Windows NT\CurrentVersion
        ValueName: CurrentBuildNumber
        Recursive: false
        Comment: OS build, where CurrentBuild is absent
    -
        Description: InstallDate
        HiveType: SOFTWARE
        Category: Host Identity
        KeyPath: Microsoft\Windows NT\CurrentVersion
        ValueName: InstallDate
        Recursive: false
        Comment: OS install date, seconds since 1970 UTC
    -
        Description: RegisteredOwner
        HiveType: SOFTWARE
        Category: Host Identity
        KeyPath: Microsoft\Windows NT\CurrentVersion
        ValueName: RegisteredOwner
        Recursive: false
        Comment: Registered owner
    -
        Description: RegisteredOrganization
        HiveType: SOFTWARE
        Category: Host Identity
        KeyPath: Microsoft\Windows NT\CurrentVersion
        ValueName: RegisteredOrganization
        Recursive: false
        Comment: Registered organization
    -
        Description: DefaultDomainName
        HiveType: SOFTWARE
        Category: Host Identity
        KeyPath: Microsoft\Windows NT\CurrentVersion\Winlogon
        ValueName: DefaultDomainName
        Recursive: false
        Comment: Domain, or computer name, of the last interactive logon
    -
        Description: CachePrimaryDomain
        HiveType: SOFTWARE
        Category: Host Identity
        KeyPath: Microsoft\Windows NT\CurrentVersion\Winlogon
        ValueName: CachePrimaryDomain
        Recursive: false
        Comment: NetBIOS name of the domain the computer belongs to
#
# SAM. The UserAccounts plugin reads each user under the Users key.
    -
        Description: SAM Users
        HiveType: SAM
        Category: Host Identity
        KeyPath: SAM\Domains\Account\Users
        Recursive: false
        Comment: Local user accounts

$script:CollectionNameMaxLength = 64

# KAPE writes these beside its output. They are expected and skipped quietly.
$script:KapeLogPatterns = @('*_ConsoleLog.txt', '*_CopyLog.csv', '*_SkipLog.csv')

# Folders a drive root carries that are never collections.
$script:SystemFolderNames = @('$RECYCLE.BIN', 'System Volume Information')

# Relative path whose presence marks the root of a Windows volume.
$script:EventLogRelativePath = 'Windows\System32\winevt\Logs'

# Names this tool writes directly under OutputRoot. A collection with one of
# these names would clash with them, since each collection's output folder
# is OutputRoot\<Collection>.
$script:ReservedCollectionNames = @(
    '_work'
    '_mnt'
    '_diff'
    '_runs'
    'run_manifest.csv'
    'run_manifest.csv.tmp'
    'triage_hosts.csv'
    'triage_hosts.csv.tmp'
    'triage_rules.csv'
    'triage_rules.csv.tmp'
    'index.html'
    'index.html.tmp'
)

function ConvertTo-CollectionName {
    <#
    .SYNOPSIS
        Turns an InputRoot entry name into a folder-safe collection name.
    .DESCRIPTION
        Removes the container extension for ZIP and disk image entries,
        replaces anything outside A-Z, a-z, 0-9, dot, underscore and hyphen
        with an underscore, trims trailing dots and spaces, prefixes reserved
        device names, and caps the length.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateSet('Loose', 'Zip', 'Vhdx', 'Vhd')]
        [string]$InputType
    )

    $base = $Name
    if ($InputType -ne 'Loose') {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($Name)
    }

    $clean = ($base -replace '[^A-Za-z0-9._-]', '_').TrimEnd('.', ' ')

    if ($clean.Length -gt $script:CollectionNameMaxLength) {
        $clean = $clean.Substring(0, $script:CollectionNameMaxLength).TrimEnd('.', ' ')
    }
    if ($clean.Length -eq 0) {
        $clean = '_'
    }
    if ($clean.Split('.')[0] -match '^(?i)(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
        $clean = '_' + $clean
    }
    return $clean
}

function Test-VolumeRootLayout {
    # True if Path directly contains Windows\System32\winevt\Logs.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $probe = Join-Path -Path $Path -ChildPath $script:EventLogRelativePath
    return (Test-Path -LiteralPath $probe -PathType Container)
}

function Get-InputCollection {
    <#
    .SYNOPSIS
        Lists the collections at the top level of InputRoot.
    .DESCRIPTION
        A directory is Loose, a .zip is Zip, a .vhdx is Vhdx and a .vhd is
        Vhd. Everything else is skipped: KAPE's own log files quietly, any
        other file with a warning. Reparse points and drive-root system
        folders are skipped with a warning.

        ZIPs are opened read-only to list their entries, which the elevation
        pre-check and the warnings below need. Nothing is extracted or
        mounted.

        Per-collection warnings are returned on the object so they can be
        recorded in the manifest:
        - a Loose entry that directly contains Windows\System32\winevt\Logs
        - a ZIP that cannot be read
        - a ZIP holding more than one disk image
        - a ZIP holding a disk image and loose evtx files, whose loose logs
          will not be processed
        - a ZIP holding nested ZIPs, which are not opened
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$InputRoot
    )

    if (Test-VolumeRootLayout -Path $InputRoot) {
        $message = ("InputRoot {0} directly contains {1}, so it looks like a single collection's volume root. " +
            'Its subfolders, such as Windows and Users, will each be treated as a collection. ' +
            'Point InputRoot at the folder that holds one entry per host.') -f $InputRoot, $script:EventLogRelativePath
        Write-Warning $message
    }

    $collections = New-Object System.Collections.Generic.List[object]

    foreach ($item in @(Get-ChildItem -LiteralPath $InputRoot -Force | Sort-Object -Property Name)) {
        $isDir = $item.PSIsContainer

        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            Write-Warning "Skipping $($item.Name): it is a link or junction, which could point outside InputRoot."
            continue
        }

        $type = $null
        if ($isDir) {
            $hiddenSystem = [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System
            if ($script:SystemFolderNames -contains $item.Name -or (($item.Attributes -band $hiddenSystem) -eq $hiddenSystem)) {
                Write-Verbose "Skipping system folder $($item.Name)."
                continue
            }
            $type = 'Loose'
        }
        else {
            switch ($item.Extension.ToLowerInvariant()) {
                '.zip' { $type = 'Zip' }
                '.vhdx' { $type = 'Vhdx' }
                '.vhd' { $type = 'Vhd' }
            }
        }

        if ($null -eq $type) {
            $isKapeLog = $false
            foreach ($pattern in $script:KapeLogPatterns) {
                if ($item.Name -like $pattern) {
                    $isKapeLog = $true
                    break
                }
            }
            if ($isKapeLog) {
                Write-Verbose "Skipping KAPE log $($item.Name)."
            }
            else {
                Write-Warning "Skipping $($item.Name): not a folder, .zip, .vhd or .vhdx."
            }
            continue
        }

        $warnings = New-Object System.Collections.Generic.List[string]
        $zipInfo = $null

        if ($type -eq 'Loose' -and (Test-VolumeRootLayout -Path $item.FullName)) {
            $warnings.Add("Folder directly contains $($script:EventLogRelativePath). If InputRoot points one level too deep, its siblings may not be hosts.")
        }

        if ($type -eq 'Zip') {
            $zipInfo = Get-ZipEntryInfo -Path $item.FullName
            if (-not $zipInfo.Readable) {
                $warnings.Add("ZIP could not be read: $($zipInfo.ReadError)")
            }
            else {
                $imageCount = @($zipInfo.ImageEntries).Count
                if ($imageCount -gt 1) {
                    $warnings.Add("ZIP holds $imageCount disk images ($(@($zipInfo.ImageEntries) -join ', ')). Only one is supported, so this collection will fail.")
                }
                if ($imageCount -ge 1 -and $zipInfo.EvtxEntryCount -gt 0) {
                    $warnings.Add("Skipped evidence: ZIP holds a disk image and $($zipInfo.EvtxEntryCount) loose evtx file(s). The image is processed and the loose evtx files are not.")
                }
                if (@($zipInfo.NestedZipEntries).Count -gt 0) {
                    $warnings.Add("ZIP holds nested ZIP(s) that are not opened: $(@($zipInfo.NestedZipEntries) -join ', ')")
                }
            }
        }

        foreach ($w in $warnings) {
            Write-Warning "$($item.Name): $w"
        }

        $collections.Add([pscustomobject]@{
                Collection = (ConvertTo-CollectionName -Name $item.Name -InputType $type)
                Source     = $item.Name
                InputType  = $type
                SourcePath = $item.FullName
                Zip        = $zipInfo
                Warnings   = $warnings.ToArray()
            })
    }

    $collections.ToArray()
}

function Assert-UniqueCollectionName {
    <#
    .SYNOPSIS
        Fails if two InputRoot entries map to the same collection name.
    .DESCRIPTION
        Names are compared case-insensitively, as Windows folders are. The
        operator renames the clashing entries. Suffixing automatically would
        let a later run pair output with the wrong evidence if entries are
        added or renamed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Collections
    )

    $clashes = @($Collections | Group-Object -Property Collection | Where-Object { $_.Count -gt 1 })
    if ($clashes.Count -eq 0) {
        return
    }

    $lines = foreach ($group in $clashes) {
        "  {0}: {1}" -f $group.Name, (($group.Group | ForEach-Object { $_.Source }) -join ', ')
    }
    throw ("{0} collection name(s) are used by more than one InputRoot entry. Rename the entries so each maps to a unique name:`n{1}" -f $clashes.Count, ($lines -join "`n"))
}

function Assert-CollectionNameAllowed {
    <#
    .SYNOPSIS
        Fails if a collection name clashes with a file or folder this tool
        writes under OutputRoot.
    .DESCRIPTION
        Compared case-insensitively. The operator renames the entry.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Collections
    )

    $bad = @($Collections | Where-Object { $script:ReservedCollectionNames -contains $_.Collection })
    if ($bad.Count -eq 0) {
        return
    }
    $names = ($bad | ForEach-Object { "$($_.Source) -> $($_.Collection)" }) -join ', '
    throw ("{0} InputRoot entr(ies) map to a name reserved for this tool's own output: {1}. Rename them. Reserved: {2}" -f $bad.Count, $names, ($script:ReservedCollectionNames -join ', '))
}

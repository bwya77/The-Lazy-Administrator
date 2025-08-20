
function New-Shortcut {
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$TargetPath,       
        
        [Parameter()]
        [string]$ShortcutPath = (Join-Path -Path ([Environment]::GetFolderPath("Desktop")) -ChildPath 'New Shortcut.lnk'),

        [Parameter()]
        [string[]]$Arguments,       # a string or string array holding the optional arguments.

        [Parameter()]
        [string[]]$HotKey,          # a string like "CTRL+SHIFT+F" or an array like 'CTRL','SHIFT','F'

        [Parameter()]
        [string]$WorkingDirectory,

        [Parameter()]
        [string]$Description,

        [Parameter(ParameterSetName = 'IconDownload', Mandatory)]
        [string]$IconName,  # Outlook.ico

        [Parameter(ParameterSetName = 'IconDownload', Mandatory)]
        [string]$IconURL,  # https://sapwaicons.blob.core.windows.net/icons/outlook.ico

        [Parameter(ParameterSetName = 'IconDownload', Mandatory)]
        [string]$IconPath = 'C:\Temp', # C:\Temp

        [Parameter()]
        [ValidateSet('Default', 'Maximized', 'Minimized')]
        [string]$WindowStyle = 'Default',

        [Parameter()]
        [switch]$RunAsAdmin # Sets the shortcut to run as administrator
    )
    begin {
        if ($IconURL) {
            Write-Verbose "Downloading icon from $IconURL"
            if (-Not (Test-Path -Path $IconPath)) {
                Write-Verbose "Creating directory $IconPath"
                New-Item -ItemType Directory -Path $IconPath -Force
            }
            $IconPath = $IconPath.TrimEnd('\')
            Write-Verbose "Downloading icon to $IconPath\$IconName"
            Invoke-WebRequest -Uri $IconURL -OutFile "$IconPath\$IconName"
            # Set the IconLocation to the downloaded file
            $IconLocation = "$IconPath\$IconName"
        }
    }
    Process {
        switch ($WindowStyle) {
            'Default' { $style = 1; break }
            'Maximized' { $style = 3; break }
            'Minimized' { $style = 7 }
        }
        $WshShell = New-Object -ComObject WScript.Shell

        # create a new shortcut
        $shortcut = $WshShell.CreateShortcut($ShortcutPath)
        $shortcut.TargetPath = $TargetPath
        $shortcut.WindowStyle = $style
        if ($Arguments) { $shortcut.Arguments = $Arguments -join ' ' }
        if ($HotKey) { $shortcut.Hotkey = ($HotKey -join '+').ToUpperInvariant() }
        if ($IconLocation) { $shortcut.IconLocation = $IconLocation }
        if ($Description) { $shortcut.Description = $Description }
        if ($WorkingDirectory) { $shortcut.WorkingDirectory = $WorkingDirectory }

        # save the link file
        $shortcut.Save()

        if ($RunAsAdmin) {
            # read the shortcut file we have just created as [byte[]]
            [byte[]]$bytes = [System.IO.File]::ReadAllBytes($ShortcutPath)
            # set bit 6 of byte 21 ON
            # ([math]::Pow(2,5) or 1 -shl 5 --> 32)
            # see https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-shllink/16cb4ca1-9339-4d0c-a68d-bf1d6cc0f943
            # page 13
            $bytes[21] = $bytes[21] -bor 32
            [System.IO.File]::WriteAllBytes($ShortcutPath, $bytes)
        }
    }
    End {
        # clean up the COM objects
        [System.Runtime.Interopservices.Marshal]::ReleaseComObject($shortcut) | Out-Null
        [System.Runtime.Interopservices.Marshal]::ReleaseComObject($WshShell) | Out-Null
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
    }
}


$progId = (Get-ItemProperty "HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\http\UserChoice").ProgId
$command = [Microsoft.Win32.Registry]::ClassesRoot.OpenSubKey("$progId\shell\open\command").GetValue("")

if ($command -match '"([^"]*)"') {
    $DefaultBrowserPath = $matches[1]
}

# Example usage

$props = @{
    'ShortcutPath' = Join-Path -Path ([Environment]::GetFolderPath("CommonDesktopDirectory")) -ChildPath 'Microsoft Teams.lnk'
    'TargetPath'   = $DefaultBrowserPath 
    'Arguments'    = '-profile-directory=Default -app=https://teams.cloud.microsoft/'
    'IconName'     = "teams.ico"
    'IconURL'      = "https://sapwaicons.blob.core.windows.net/icons/teams.ico"
    'IconPath'     = "C:\Temp"
}

New-Shortcut @props


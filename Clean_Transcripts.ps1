#  Cleans up PowerShell Transcripts into a neat folder structure
#  Kenny Lowe - 2017

# Get all Files in Folder

function Test-FileLock 
{
    param ([parameter(Mandatory=$true)][string]$Path)
    $oFile = New-Object System.IO.FileInfo $Path

    if ((Test-Path -Path $Path) -eq $false) 
    {
        return $false
    }

    try 
    {
        $oStream = $oFile.Open([System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        if ($oStream) 
        {
            $oStream.Close()
        }
        $false
    } 
    catch 
    {
    # file is locked by a process.
    return $true
    }
}

$PSPath = $env:PSModulePath
$Separator = ";"
$Modulepath = ($PSPath.Split($Separator))[0]
$Path = ($Modulepath.Substring(0,$Modulepath.get_Length()-8)) + "\Transcripts"
$Files = Get-ChildItem -Path $Path -File -Force 


# Parse Date from Filenames and move into folders
foreach ($File in $Files)
{
    $Filename = $File.Name
    $Date = (($File.Name).Substring(($File.Name).get_Length()-18)).SubString(0,14)

    #Create Year
    $Year = $Date.Substring(0,4)
    $YearPath = $Path + "\" + $Year
    If ((Test-Path -Path $YearPath) -eq 0)
    {
        New-Item $YearPath -Type Directory
    }
    
    #Create Month
    $Month = $Date.Substring(4,2)
    $MonthPath = $Path + "\" + $Year + "\" + $Month
    If ((Test-Path -Path $MonthPath) -eq 0)
    {
        New-Item $MonthPath -Type Directory
    }

    #Create Day
    $Day = $Date.Substring(6,2)
    $DayPath = $Path + "\" + $Year + "\" + $Month + "\" + $Day
    If ((Test-Path -Path $DayPath) -eq 0)
    {
        New-Item $DayPath -Type Directory
    }
        if ((Test-FileLock($File.FullName)) -eq $true)
        {
            Write-Host "File in use"
        }
        else
        { 
            Move-Item $File.FullName $DayPath -Force
        }
}

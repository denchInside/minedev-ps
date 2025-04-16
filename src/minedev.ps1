<#
.SYNOPSIS
	Runs the dev tool.

.PARAMETER RunScript
	Execute a build file.

.PARAMETER RunCommand
	Execute a single build command.

.PARAMETER Update
	Force the tooling to update right now.

.PARAMETER Version
	Display current version.

.PARAMETER SetUpdateBranch
	Change the branch the tooling is being updated from.
	Currently, two branches are available: 'main' and 'testing'.

.PARAMETER SetUpdateInterval
	Set how often the tooling checks for updates.
	Setting it to -1 disables update checks entirely.

.EXAMPLE
	./minedev.ps1 -RunScript "./build_my_pack.ps1"
#>


param(
	[string]$RunScript,
	[string]$RunCommand,
	
	[switch]$Update,
	[switch]$Version,
	
	[string]$SetUpdateBranch,
	[int]$SetUpdateInterval = -2,
	
	# Hack: -Fork is set in a subsequent call
	# ( the script is started in a new shell 
	# to prevent any global variables overrides )
	[switch]$Fork
)


### Script forking
if (-not $Fork) {
	$argList = @($PSCommandPath, "-Fork") # Important: do not remove -Fork
	
	foreach ($kvp in $PSBoundParameters.GetEnumerator()) {
		$name = "-$($kvp.Key)"
		$value = $kvp.Value
		if ($value -is [switch]) {
			if ($value.IsPresent) { $argList += $name }
		} else {
			$argList += @($name, "$value")
		}
	}
	
	pwsh @argList 
	return
}


### Powershell enforcements
$ErrorActionPreference = "Stop"
$WarningPreference = "Stop"
$ErrorView = "DetailedView"
[System.IO.Directory]::SetCurrentDirectory($pwd)


### Function declarations
function Stringify-DateTime {
	param([DateTime]$Value)
	return $Value.ToString([CultureInfo]::InvariantCulture)
}

function Parse-DateTime {
	param([string]$Value)
	return [DateTime]::Parse(
		$Value,
		[CultureInfo]::InvariantCulture,
		[System.Globalization.DateTimeStyles]::AdjustToUniversal
	)
}

function No-Output {
	param([ScriptBlock]$f)
	$null = & $f
}

function Assert-IsString {
	param([string]$Path)

	if ($Path -eq $null) {
		throw "Provided string is null."
	}
	if (-not ($Path.GetType() -eq [string])) {
		throw "Provided argument is not a string."
	}
	if ($Path.Length -lt 1) {
		throw "Provided string is empty."
	}
}

function Safe-Join {
	foreach ($arg in $args) {
		Assert-IsString $arg
	}
	return Join-Path @args
}

function New-Directory {
	param([string]$Path)
	
	Assert-IsString $Path
	$null = New-Item -Path $Path `
		-ItemType Directory `
		-Force `
		-ErrorAction SilentlyContinue
}

function Get-TempFileName {
	return Safe-Join `
		([System.IO.Path]::GetTempPath()) `
		([System.IO.Path]::GetRandomFileName())
}

function Exists {
	foreach ($arg in $args) {
		Assert-IsString($arg)
		if (Test-Path -LiteralPath $arg) {
			return $true
		}
		return $false
	}
}

filter To-Json {
	$_ | ConvertTo-Json -Depth 10
}

filter From-Json {
	$_ | ConvertFrom-Json -AsHashtable
}

function Get-GithubLatestRelease {
	param(
		[string]$Author,
		[string]$Repo,
		[string]$TagPattern,
		[string]$NamePattern,
		[switch]$PreRelease
	)

	$apiUrl = "https://api.github.com/repos/$Author/$Repo/releases"
	$request = Invoke-RestMethod `
		-Uri $apiUrl `
		-Headers @{ "User-Agent" = "PowerShell" }
	$release = $request |
		Where-Object { $_.name -like $NamePattern } |
		Where-Object { $_.tag_name -like $TagPattern } |
		Sort-Object -Property published_at -Descending |
		Select-Object -First 1
	
	return $release
}


### Variable declarations
$MD_ROOT = Safe-Join `
	([Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)) `
	".minedev"
$MD_REPO_DIR = Safe-Join $MD_ROOT "repo"
$MD_SCRIPTS_DIR = Safe-Join $MD_REPO_DIR "scripts"
$MD_BINARIES_DIR = Safe-Join $MD_REPO_DIR "binaries"
$MD_INFO_FILE = Safe-Join $MD_ROOT "minedev.json"
$DATE_MIN = Stringify-DateTime ([DateTime]::MinValue)


### Prepare directories
New-Directory $MD_ROOT


### Load config file
$MD_CONFIG = $null
# FIXME: Does not trigger again when interrupted first time and interval is -1
$FIRST_START = $false
try {
	$MD_CONFIG = Get-Content $MD_INFO_FILE -Raw | From-Json
} catch {
	$MD_CONFIG = @{
		last_update_date = $DATE_MIN
		last_version_date = $DATE_MIN
		update_interval_days = 3
		update_branch = "main"
	}
	$FIRST_START = $true
}


### Program-related functions
function Minedev-Exit {
	param([int]$exitCode)
	
	$MD_CONFIG | To-Json > $MD_INFO_FILE
	exit $exitCode
}

function Exit-On-Error {
    param([ScriptBlock]$f)
    try {
        & $f
    } catch {
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor "Red"
		Minedev-Exit 1
    }
}

function Check-For-Updates {
	if (-not $Update) {
		$tsUpdateInterval = `
			[TimeSpan]::FromDays($MD_CONFIG.update_interval_days)
		$tsDaysNotUpdated = `
			[DateTime]::UtcNow - (Parse-DateTime $MD_CONFIG.last_update_date)
		if ($tsUpdateInterval -lt 0) {
			return
		}
		if ($tsDaysNotUpdated -lt $tsUpdateInterval) {
			return
		}
	}
	
	Write-Host "### Checking for updates"

	$MD_CONFIG.last_update_date = `
		Stringify-DateTime ([DateTime]::UtcNow)
	$release = Get-GithubLatestRelease `
		-Author "denchInside" `
		-Repo "minedev-ps" `
		-TagPattern "$($MD_CONFIG.update_branch)-*" `
		-NamePattern '*' `
		-PreRelease
	
	if ($release -eq $null) {
		$branch = $MD_CONFIG.update_branch
		Write-Host "Error: No matching releases found in '$branch'." `
			"Try changing the update branch via '-SetUpdateBranch'." `
			-ForegroundColor "Red" `
			-Separator "`n"
		if ($FIRST_START) { Minedev-Exit 1 }
		return
	}
	
	if ($Update -or $MD_CONFIG.last_update_tag -ne $release.tag_name) {
		$MD_CONFIG.last_update_tag = $release.tag_name
		$MD_CONFIG.last_update_name = $release.name
	} else {
		return
	}
	
	$tmpZip = Get-TempFileName
	$tmpDir = Get-TempFileName
	No-Output {
		Remove-Item -Recurse `
			-ErrorAction SilentlyContinue `
			-LiteralPath $MD_REPO_DIR
		New-Directory $MD_REPO_DIR

		Invoke-WebRequest $release.zipball_url -OutFile $tmpZip
		New-Directory $tmpDir
		Expand-Archive -LiteralPath $tmpZip -DestinationPath $tmpDir
		
		$innerDir = Get-ChildItem `
			-Directory -LiteralPath $tmpDir |
			Select-Object -First 1
		
		Get-ChildItem -LiteralPath $innerDir |
			ForEach-Object {
				$itemPath = Safe-Join $MD_REPO_DIR `
					([System.IO.Path]::GetFileName($_.FullName))
				Move-Item $_.FullName $itemPath
			}
		
		Remove-Item -ErrorAction SilentlyContinue -LiteralPath $tmpZip
		Remove-Item -Recurse -ErrorAction SilentlyContinue -LiteralPath $tmpDir
	}
	$MD_CONFIG.last_version_date = `
		Stringify-DateTime (Parse-DateTime $release.published_at)
}


### Version mode
if ($Version -and $FIRST_START) {
	Write-Host `
		"Tooling version not identified yet." `
		"Try running this command with flag -Update first." `
		-Separator "`n"
	Minedev-Exit 0
}

if ($Version) {
	Write-Host `
		"Minedev tooling, last updated on $($MD_CONFIG.last_version_date)," `
		"Release '$($MD_CONFIG.last_update_name)' on branch '$($MD_CONFIG.update_branch)'." `
		-Separator "`n"
	Minedev-Exit 0
}


### SetUpdateInterval mode
if ($SetUpdateInterval -gt -2) {
	$MD_CONFIG.update_interval_days = `
		Exit-On-Error { [int]$SetUpdateInterval }
	Write-Host "Interval set to" $SetUpdateInterval
	Minedev-Exit 0
}


### SetUpdateBranch mode
if (-not ([string]::IsNullOrEmpty($SetUpdateBranch))) {
	if ($SetUpdateBranch -in @("main", "testing")) {
		$MD_CONFIG.update_branch = $SetUpdateBranch.ToLowerInvariant()
		$MD_CONFIG.last_update_date = $DATE_MIN
	} else {
		Write-Host `
			"Error: invalid branch specified." `
			"Select either 'main' or 'testing'." `
			-ForegroundColor "Red" `
			-Separator "`n"
		Minedev-Exit 1
	}
	
	Write-Host "Update branch changed to" $MD_CONFIG.update_branch
	Minedev-Exit 0
}

### Check for updates
Check-For-Updates

### Finalize exit
Minedev-Exit 0

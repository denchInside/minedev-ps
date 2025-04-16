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

.PARAMETER Verbose
	Makes error logging more verbose.

.EXAMPLE
	./minedev.ps1 -RunScript "./build_my_pack.ps1"
#>


param(
	$RunScript,
	$RunCommand,
	
	[switch]$Update,
	[switch]$Verbose,
	[switch]$Version,
	
	$SetUpdateBranch,
	$SetUpdateInterval,
	
	# Hack: -Forked is set in a subsequent call
	# ( the script is started in a new shell 
	# to prevent any global variable overrides )
	[switch]$Forked
)


### Script forking
if (-not $Forked) {
	pwsh $PSCommandPath -Forked @PSBoundParameters
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
	param($Value, [switch]$AllowNull, [switch]$DisallowEmpty)

	if ($Value -eq $null) {
		if (-not $AllowNull) {
			throw "Provided string is null."
		}
	} elseif ($Value -isnot [string]) {
		throw "Provided argument is not a string."
	} elseif ($DisallowEmpty -and $Value.Length -lt 1) {
		throw "Provided string is empty."
	}
}

function Safe-Join {
	foreach ($arg in $args) {
		Assert-IsString $arg -DisallowEmpty
	}
	return Join-Path @args
}

function New-Directory {
	param([string]$Path)
	
	Assert-IsString $Path -DisallowEmpty
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
		Assert-IsString $arg -DisallowEmpty
		if (Test-Path -LiteralPath $arg) {
			return $true
		}
		return $false
	}
}

filter To-Json {
	$_ | ConvertTo-Json -Depth 16
}

filter From-Json {
	$_ | ConvertFrom-Json -AsHashtable
}

function Github-GetLatestRelease {
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
$MD_GLOBAL_CONFIG_FILE = Safe-Join $MD_ROOT "minedev.json"
$MD_DATE_MIN = Stringify-DateTime ([DateTime]::MinValue)
$MD_CONFIG = $null
$MD_IS_FIRST_START = $false
$MD_PATH_DEFAULT = "$MD_SCRIPTS_DIR;$MD_BINARIES_DIR;$($env:PATH)"
$env:PATH = $MD_PATH_DEFAULT

### Program-related functions
function Md-Save-Config {
	$MD_CONFIG | To-Json > $MD_GLOBAL_CONFIG_FILE
}

function Md-Load-Config {
	$configRef = [ref]$MD_CONFIG
	$isFirstStartRef = [ref]$MD_IS_FIRST_START
	try {
		$configRef.Value = Get-Content $MD_GLOBAL_CONFIG_FILE -Raw | From-Json
	} catch {
		$configRef.Value = @{
			last_update_date = $MD_DATE_MIN
			last_version_date = $MD_DATE_MIN
			update_interval_days = 3
			update_branch = "main"
		}
		$isFirstStartRef.Value = $true
	}
}

function Exit-On-Error {
    param([ScriptBlock]$f)
    try {
        & $f
    } catch {
		$details = if ($Verbose) `
			{ $_.Exception.ToString() } `
			else { $_.Exception.Message }

		Md-Save-Config
        Write-Host "Error:" $details -ForegroundColor "Red"
		exit 1
    }
}

function Md-Update {
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
	$release = Github-GetLatestRelease `
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
		if ($MD_IS_FIRST_START) { exit 1 }
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
	
	$selfUpdate = Ask-User `
		-Prompt "Update this script file?" `
		-Choices @('y', 'n') `
		-Default 'n'
	if ($selfUpdate -eq 'y') {
		$newPSScriptPath = Safe-Join $MD_REPO_DIR "src" "minedev.ps1"
		$newPSScriptText = Get-Content $newPSScriptPath -Raw
		Assert-IsString $newPSScriptText
		$newPSScriptText > $PSCommandPath
	}
}


### Run preparations
Exit-On-Error {
	New-Directory $MD_ROOT
	Md-Load-Config
	Assert-IsString $RunScript -AllowNull
	Assert-IsString $RunCommand -AllowNull
	Assert-IsString $SetUpdateBranch -AllowNull
	$null = [int]$SetUpdateInterval
}


### Version mode
if ($Version -and $MD_IS_FIRST_START) {
	Write-Host `
		"Tooling version not identified yet." `
		"Try running this command with flag -Update first." `
		-Separator "`n"
	exit 0
}

if ($Version) {
	Write-Host `
		"Minedev tooling, last updated on $($MD_CONFIG.last_version_date)," `
		"Release '$($MD_CONFIG.last_update_name)' on branch '$($MD_CONFIG.update_branch)'." `
		-Separator "`n"
	exit 0
}


### SetUpdateInterval mode
if ($SetUpdateInterval) {
	$MD_CONFIG.update_interval_days = $SetUpdateInterval
	
	Md-Save-Config
	Write-Host "Interval set to" $SetUpdateInterval
	exit 0
}


### SetUpdateBranch mode
if ($SetUpdateBranch -ne $null) {
	if ($SetUpdateBranch -in @("main", "testing")) {
		$MD_CONFIG.update_branch = $SetUpdateBranch.ToLowerInvariant()
		$MD_CONFIG.last_update_date = $MD_DATE_MIN
	} else {
		Write-Host `
			"Error: invalid branch specified." `
			"Select either 'main' or 'testing'." `
			-ForegroundColor "Red" `
			-Separator "`n"
		exit 1
	}
	
	Md-Save-Config
	Write-Host "Update branch changed to" $MD_CONFIG.update_branch
	exit 0
}


### Check for updates
Md-Update
Md-Save-Config


### RunScript mode
if ($RunScript) {
	Exit-On-Error {
		if (-not (Exists $RunScript)) {
			throw "The specified script does not exist."
		}
		
		$pwdOld = Get-Location
		$scriptDir = [System.IO.Path]::GetDirectoryName($RunScript)
		try { 
			& $RunScript
		} finally {
			Set-Location $pwdOld
		}
	}
	exit 0
}


### RunCommand mode
if ($RunCommand) {
	Exit-On-Error {
		Invoke-Expression $RunCommand
	}
	exit 0
}

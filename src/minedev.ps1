### MineDev Command-Line Utility
### This script automatically downloads the latest tooling available.

param(
	# Hack: -Fork is set in a subsequent call
	# ( the script is started in a new shell 
	# to prevent any global variables overrides )
	[switch]$Fork,
	[switch]$Update,
	[switch]$Testing
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
function Exit-On-Failure {
    param([ScriptBlock]$f)
    try {
        & $f
    } catch {
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor "Red"
		[Environment]::Exit(1)
    }
}function Assert-IsString {
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
	$null = New-Item -Path $Path -ItemType Directory -Force -ErrorAction SilentlyContinue
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
	$request = Invoke-RestMethod -Uri $apiUrl -Headers @{ "User-Agent" = "PowerShell" }
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


### Prepare directories
New-Directory $MD_ROOT

### Load config file
$MD_CONFIG = $null
$FIRST_START = $false
try {
	$MD_CONFIG = Get-Content $MD_INFO_FILE -Raw | From-Json
} catch {
	$dtDefault = Stringify-DateTime ([DateTime]::MinValue)
	$MD_CONFIG = @{
		last_update_date = $dtDefault
		last_version_date = $dtDefault
	}
	$FIRST_START = $true
}

### Program-related functions
function Check-For-Updates {
	Write-Host "### Checking for updates"
	$pattern = if ($Testing) { "testing-*" } else { "main-*" }
	
	$release = Get-GithubLatestRelease `
		-Author "denchInside" `
		-Repo "minedev-ps" `
		-TagPattern $pattern `
		-NamePattern '*' `
		-PreRelease
	
	if (-not $release) {
		Write-Host "Error: No matching release found." `
			"Try to run this command with flag '-Testing'." `
			-ForegroundColor "Red" `
			-Separator "`n"
		if ($FIRST_START) { exit 1 }
		return
	}
	
	$tmpZip = Get-TempFileName
	$tmpDir = Get-TempFileName
	No-Output {
		Remove-Item -Recurse -ErrorAction SilentlyContinue -LiteralPath $MD_REPO_DIR
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
	$MD_CONFIG.last_update_date = Stringify-DateTime ([DateTime]::UtcNow)
}


if (-not $Update) {
	$tsUpdateInterval = [TimeSpan]::FromDays(3)
	$tsDaysNotUpdated = [DateTime]::UtcNow `
		- (Parse-DateTime $MD_CONFIG.last_update_date)
	$Update = $Update -or ($tsDaysNotUpdated -gt $tsUpdateInterval)
}
if ($Update) {
	Check-For-Updates
}


### Save config file
$MD_CONFIG | To-Json > $MD_INFO_FILE

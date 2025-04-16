param(
	[Parameter(Mandatory = $true)]
	$Value
)

Assert-IsString $Value
$fullPath = Safe-Join $MD_SCRIPTS_DIR $Value
$env:PATH = "$fullPath;$MD_PATH_DEFAULT"

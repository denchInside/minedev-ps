param($Value, [switch]$Get)

if ($Get) {
	if ($MD_GLOBALS.MinecraftVersion -eq $null) {
		throw "Minecraft version is not set."
	}
	return $MD_GLOBALS.MinecraftVersion
}

Assert-IsString $Value -DisallowEmpty
$fullPath = Safe-Join $MD_SCRIPTS_DIR $Value
$env:PATH = "$fullPath;$MD_PATH_DEFAULT"
$MD_GLOBALS.MinecraftVersion = $Value
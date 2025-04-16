param($Value, [switch]$Get)

if ($Get) {
	if ($MD_GLOBALS.PackName -eq $null) {
		throw "The pack name is not set."
	}
	return $MD_GLOBALS.PackName
}

Assert-IsString $Value -DisallowEmpty
$MD_GLOBALS.PackName = $Value

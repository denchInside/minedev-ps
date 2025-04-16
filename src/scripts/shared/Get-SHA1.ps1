param([string]$file)

$hash = Get-FileHash -Algorithm SHA1 -LiteralPath $file
if ($hash) {
	return $hash.Hash.ToLowerInvariant()
}

param ([string]$InputString)

$sb = [System.Text.StringBuilder]::new()
foreach ($char in $InputString.GetEnumerator()) {
	if ([int]$char -gt 127) {
		$null = $sb.AppendFormat("\u{0:X4}", [int]$char)
	} else {
		$null = $sb.Append($char)
	}
}
$sb.ToString()

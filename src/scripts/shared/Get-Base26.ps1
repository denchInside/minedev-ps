param([long]$number); 

$rem = 0; $txt = ""; $sign = ""
if ($number -lt 0) {
	$sign = "-"
	$number = -$number
}

do {
	$tmp = [Math]::DivRem($number, 26)
	$number = $tmp[0]; $rem = $tmp[1]
	$txt = "abcdefghijklmnopqrstuvwxyz"[$rem] + $txt
} while ($number -ne 0)

return $sign + $txt

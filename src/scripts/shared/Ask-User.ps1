param(
	[Parameter(Mandatory = $true)]
	[string]$Prompt,
	
	[Parameter(Mandatory = $true, ValueFromRemainingArguments = $true)]
	[string[]]$Choices,

	[string]$Default
)

$Prompt += " ["
for ($i = 0; $i -lt $Choices.Length; $i+=1) {
	if ($i -gt 0) {
		$Prompt += "/"
	}
	if ($Choices[$i] -eq $Default) {
		$Prompt += $Choices[$i].ToUpperInvariant()
	} else {
		$Prompt += $Choices[$i]
	}
}
$Prompt += "]"

$reply
do {
	$reply = (Read-Host $Prompt).Trim()
} while (
	-not ($reply.Trim() -in $Choices) `
	-and -not ($Default -and [string]::IsNullOrEmpty($reply)) `
)

if ($reply) {
	return $reply
} else {
	return $Default
}

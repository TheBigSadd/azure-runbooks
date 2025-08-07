# 0. Load mapping from Automation variable and parse it
$mappingRaw = Get-AutomationVariable -Name "Autotagging"
Write-Output "Automation variable [Autotagging] contains: $mappingRaw"

# Create model-tag dictionary
$mapping = @{}
$pattern = '\{([^\}]+)\}([^\{]+)'

$matches = [regex]::Matches($mappingRaw, $pattern)
if ($matches.Count -eq 0) {
    Write-Warning "❌ No valid {model}tag entries found in the 'Autotagging' variable."
    return
}

foreach ($match in $matches) {
    $model = $match.Groups[1].Value.Trim()
    $tag   = $match.Groups[2].Value.Trim()
    $mapping[$model] = $tag
    Write-Output "Parsed mapping: Model='$model' → Tag='$tag'"
}

# Connecting to managed identity
Connect-AzAccount -Identity | Out-Null

$token = Get-AzAccessToken -ResourceUrl "https://graph.microsoft.com"
$AccessToken = $token.Token

$Headers     = @{
    "Authorization" = "Bearer $AccessToken"
    "Content-Type"  = "application/json"
}

# 2. Fetch all Autopilot devices
$autopilotUrl = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities"
$allDevices   = @()

do {
    $response      = Invoke-RestMethod -Uri $autopilotUrl -Headers $Headers -Method Get
    $allDevices   += $response.value
    $autopilotUrl  = $response.'@odata.nextLink'
} while ($autopilotUrl)

Write-Output "📦 Total Autopilot devices retrieved: $($allDevices.Count)"

# 3. Apply tags per mapping
foreach ($model in $mapping.Keys) {
    $tag = $mapping[$model]
    $filtered = $allDevices | Where-Object { $_.model.Trim() -eq $model }

    Write-Output "🔎 Found $($filtered.Count) devices with model '$model' to tag as '$tag'"

    foreach ($device in $filtered) {
        $deviceId     = $device.id
        $serialNumber = $device.serialNumber
        $existingTag  = $device.groupTag

        if ([string]::IsNullOrWhiteSpace($existingTag)) {
            $uri  = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities/$deviceId/updateDeviceProperties"
            $body = @{ groupTag = $tag } | ConvertTo-Json

            try {
                Invoke-RestMethod -Uri $uri -Headers $Headers -Method Post -Body $body
                Write-Output "✅ Set tag '$tag' for $serialNumber"
            } catch {
                Write-Warning "❌ Failed to update ${serialNumber}: $($_.Exception.Message)"
            }
        } else {
            Write-Output "⏭️ Skipped $serialNumber (existing tag: '$existingTag')"
        }
    }
}

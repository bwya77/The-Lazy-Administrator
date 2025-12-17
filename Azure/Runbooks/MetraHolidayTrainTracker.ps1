# ============================
# Metra Holiday Train Alert
# ============================
$VerbosePreference = "Continue"
# ----------------------------
# Pushover credentials
# ----------------------------
$PushoverToken = ""
$PushoverUser = ""

# ----------------------------
# Azure Table Storage settings
# ----------------------------
$storageAccountName = ""
$tableName = ""
$sasToken = ""

$tableEndpoint = "https://$storageAccountName.table.core.windows.net/$tableName"

# ----------------------------
# Metra API endpoint
# ----------------------------
$uri = "https://store.transitstat.us/metra/transitStatus"

# Filter to only the following train line or lines, or leave empty for all lines
$filterLines = @("BNSF", "UP-W") # e.g., @("BNSF", "UP-W")

# Initialize notification lines array
$notifyLines = @()

# Helper function: get Table Storage entity
function Get-TableEntity($partitionKey, $rowKey) {
    $url = "$tableEndpoint(PartitionKey='$partitionKey',RowKey='$rowKey')?$sasToken"
    try {
        $resp = Invoke-RestMethod -Uri $url -Method Get -Headers @{Accept = "application/json;odata=nometadata" } -ErrorAction Stop
        return $resp
    }
    catch {
        return $null
    }
}
# Helper function: insert or update Table Storage entity
function Upsert-TableEntity($partitionKey, $rowKey, $destination) {
    $url = "$tableEndpoint(PartitionKey='$partitionKey',RowKey='$rowKey')?$sasToken"
    $body = @{
        PartitionKey = $partitionKey
        RowKey       = $rowKey
        Destination  = $destination
        AlertedAt    = (Get-Date).ToString("o")
    } | ConvertTo-Json -Depth 3

    Invoke-RestMethod -Uri $url -Method Put -Body $body -Headers @{
        "Accept"       = "application/json;odata=nometadata"
        "Content-Type" = "application/json"
    } -ErrorAction Stop
}

try {
    # Fetch Metra transit status
    Try {
        Write-Verbose "Fetching Metra transit status from $uri"
        $response = Invoke-RestMethod -Uri $uri -Method Get
    }
    catch {
        Write-Error "Failed to fetch transit status: $_"
        return
    }
    # Filter for holiday Christmas trains with a valid destination
    $ChristmasTrains = $response.trains.PSObject.Properties | Where-Object {
        $_.Value.extra.holidayChristmas -eq $true -and $_.Value.dest -ne "Nowhere"
    }

    if (-not $ChristmasTrains) {
        Write-Verbose "No holiday trains found" 
        return
    }

    foreach ($train in $ChristmasTrains) {

        #If the train line is not in the filter, skip
        if ($train.Value.line -in $filterLines -or $filterLines.Count -eq 0) {
            Write-Verbose "Processing $($train.Name), line $($train.Value.line) as it is in filter"
        }
        else {
            Write-Verbose "Skipping $($train.Name), line $($train.Value.line) not in filter"
            continue
        }

        $trainNumber = $train.Name
        $partitionKey = $train.Value.line
        $rowKey = $trainNumber

        # Check if alerted within last hour
        Write-Verbose "Checking alert history for $($trainNumber)"
        $existing = Get-TableEntity -partitionKey $partitionKey -rowKey $rowKey
        $sendNotification = $true

        if ($existing -and $existing.AlertedAt) {
            $lastAlerted = [datetime]::Parse($existing.AlertedAt)
            if ((Get-Date) - $lastAlerted -lt [TimeSpan]::FromHours(1)) {
                $sendNotification = $false
                Write-Verbose "Skipping $($trainNumber), alerted less than 1 hour ago"
            }
        }

        if ($sendNotification) {

            # Build upcoming stops
            $upcomingStops = foreach ($p in $train.Value.predictions) {
                if (-not $p.actualETA) { continue }
                $utc = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$p.actualETA)
                $centralTZ = [TimeZoneInfo]::FindSystemTimeZoneById("Central Standard Time")
                $central = [TimeZoneInfo]::ConvertTime($utc, $centralTZ)
                $timeUntil = $central - (Get-Date)

                [PSCustomObject]@{
                    Station   = $p.stationName
                    Time      = $central.ToString("hh:mm:ss")
                    TimeUntil = "{0}h {1}m" -f $timeUntil.Hours, $timeUntil.Minutes
                }
            }

            # Build notification message
            $notifyLines += "🚆 Train $($trainNumber) ($($train.Value.line)) → $($train.Value.dest)"
            if ($upcomingStops.Count -gt 0) {
                $notifyLines += "📍 Next Stop: $($upcomingStops[0].Station) at $($upcomingStops[0].Time)"
                $notifyLines += "`nUpcoming Stops:"
                foreach ($stop in $upcomingStops) {
                    $notifyLines += " • $($stop.Station) at $($stop.Time) ($($stop.TimeUntil))"
                }
            }
            else {
                $notifyLines += "📍 No upcoming stops reported"
            }
            $notifyLines += "" # blank line

            # Log/update alert in Table Storage
            Upsert-TableEntity -partitionKey $partitionKey -rowKey $rowKey -destination $train.Value.dest
        }
    }

    if ($notifyLines.Count -eq 0) {
        Write-Verbose "No new trains to alert." 
        return
    }

    # Send Pushover notification
    $payload = $notifyLines -join "`n"
    Invoke-RestMethod `
        -Uri "https://api.pushover.net/1/messages.json" `
        -Method Post `
        -Body @{
        token   = $PushoverToken
        user    = $PushoverUser
        message = $payload
        title   = "Metra Holiday Train Alert 🚆"
    }
    Write-Verbose "Pushover notification sent!" 
}
catch {
    Write-Error "Error occurred: $_"
}

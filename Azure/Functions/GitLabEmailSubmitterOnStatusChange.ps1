# Azure Function: Run.ps1

param($Request, $TriggerMetadata)

# ----------------------------
# CONFIG
# ----------------------------
[string]$gitlabAccessToken = $env:GitlabPAT
[string]$gitlabApiUrl = "https://gitlab.com/api/graphql"

# ----------------------------
# HELPER FUNCTIONS
# ----------------------------
function Get-StatusLabel {
    param($labels)
    begin {
    }
    process {
        foreach ($label in $labels) {
            if ($label.title -like 'Status::*') {
                return $label.title -replace '^Status::', ''
            }
        }
    }
    end {
        $null
    }
}

# ----------------------------
# PARSE WEBHOOK
# ----------------------------
try {
    $body = $Request.Body | Get-Content -Raw | ConvertFrom-Json
} catch {
    return @{
        status = 400
        body = "Invalid JSON payload"
    }
}

# Only handle label updates
if (-not $body.changes.labels) {
    return @{
        status = 200
        body = "No label changes, nothing to process."
    }
}

$oldStatus = Get-StatusLabel -labels $body.changes.labels.previous
$newStatus = Get-StatusLabel -labels $body.changes.labels.current

# Exit if status didn't change
if ($oldStatus -eq $newStatus) {
    return @{
        status = 200
        body = "Status unchanged."
    }
}

# ----------------------------
# QUERY GITLAB GRAPHQL FOR CRM CONTACT
# ----------------------------
$projectPath = $body.project.path_with_namespace
$issueIid = $body.object_attributes.iid

$query = @"
{
  project(fullPath: "$projectPath") {
    issue(iid: "$issueIid") {
      customerRelationsContacts {
        nodes {
          firstName
          lastName
          email
        }
      }
    }
  }
}
"@

try {
    $response = Invoke-RestMethod -Uri $gitlabApiUrl -Method Post -Headers @{ 
        "Authorization" = "Bearer $gitlabAccessToken" 
    } -Body (@{ query = $query } | ConvertTo-Json)

    $contacts = $response.data.project.issue.customerRelationsContacts.nodes
    $emails = $contacts | ForEach-Object { $_.email } | Where-Object { $_ } # skip nulls
} catch {
    return @{
        status = 500
        body = "Failed to query GitLab: $_"
    }
}

# ----------------------------
# RETURN RESULTS
# ----------------------------
$result = [PSCustomObject]@{
    OldStatus = $oldStatus
    NewStatus = $newStatus
    ContactEmails = $emails -join ', '
}

return @{
    status = 200
    body = $result | ConvertTo-Json -Depth 5
}

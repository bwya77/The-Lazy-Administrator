# Azure Function: Run.ps1

param($Request, $TriggerMetadata)

# ----------------------------
# CONFIG
# ----------------------------
[string]$gitlabAccessToken = $env:GitlabPAT
[string]$gitlabApiUrl = "https://gitlab.com/api/graphql"
[string]$logicAppEndpoint = $env:logicAppEndpoint

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
}
catch {
    return @{
        status = 400
        body   = "Invalid JSON payload"
    }
}

# Only handle label updates
if (-not $body.changes.labels) {
    return @{
        status = 200
        body   = "No label changes, nothing to process."
    }
}

$oldStatus = Get-StatusLabel -labels $body.changes.labels.previous
$newStatus = Get-StatusLabel -labels $body.changes.labels.current

# Exit if status didn't change
if ($oldStatus -eq $newStatus) {
    return @{
        status = 200
        body   = "Status unchanged."
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

    $contact = $response.data.project.issue.customerRelationsContacts.nodes
    $email = $contact.email
}
catch {
    return @{
        status = 500
        body   = "Failed to query GitLab: $_"
    }
}

# ----------------------------
# SEND TO LOGIC APP
# ----------------------------
$payload = [PSCustomObject]@{
    OldStatus    = $oldStatus
    NewStatus    = $newStatus
    ContactEmail = $email
    IssueIid     = $issueIid
    ProjectPath  = $projectPath
}

try {
    Invoke-RestMethod -Uri $logicAppEndpoint -Method Post `
        -ContentType "application/json" `
        -Body ($payload | ConvertTo-Json -Depth 5)
    
    $logicAppStatus = "Success"
    $result = [PSCustomObject]@{
        OldStatus      = $oldStatus
        NewStatus      = $newStatus
        ContactEmail   = $email
        LogicAppStatus = $logicAppStatus
    }

    return @{
        status = 200
        body   = $result | ConvertTo-Json -Depth 5
    }
}
catch {
    $logicAppStatus = "Failed: $_"
    $result = [PSCustomObject]@{
        OldStatus      = $oldStatus
        NewStatus      = $newStatus
        ContactEmail   = $email
        LogicAppStatus = $logicAppStatus
    }

    return @{
        status = 500
        body   = $result | ConvertTo-Json -Depth 5
    }
}


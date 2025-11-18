<#
.SYNOPSIS
    GitLab MR Issue Checkbox Validator

.DESCRIPTION
    This script validates that all checkboxes in the issue linked to a merge request
    are checked before allowing the MR to be merged.

.NOTES
    Requires PowerShell 7+ and the following environment variables:
    - CI_SERVER_URL: GitLab server URL
    - CI_PROJECT_ID: Project ID
    - CI_MERGE_REQUEST_IID: Merge request IID
    - GITLAB_TOKEN: GitLab API token with api scope
#>

[CmdletBinding()]
param()

#region Functions

#region Utility Functions

function Get-EnvironmentVariable {
    <#
    .SYNOPSIS
        Gets an environment variable with validation
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $false)]
        [bool]$Required = $true
    )

    begin {
        Write-Verbose "Getting environment variable: $Name"
    }

    process {
        $value = [Environment]::GetEnvironmentVariable($Name)

        if ($Required -and [string]::IsNullOrEmpty($value)) {
            throw "Required environment variable '$Name' is not set"
        }

        return $value
    }

    end {
    }
}

#endregion

#region API Functions

function Invoke-GitLabAPI {
    <#
    .SYNOPSIS
        Makes a GitLab API request
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $true)]
        [string]$Token,

        [Parameter(Mandatory = $false)]
        [string]$Method = 'GET'
    )

    begin {
        Write-Verbose "Preparing GitLab API request: $Method $Uri"
    }

    process {
        $headers = @{
            'PRIVATE-TOKEN' = $Token
        }

        try {
            Write-Host "  API Request: $Method $Uri" -ForegroundColor Gray
            $response = Invoke-RestMethod -Uri $Uri -Headers $headers -Method $Method -ErrorAction Stop
            return $response
        }
        catch {
            $statusCode = $_.Exception.Response.StatusCode.value__
            $errorMessage = $_.Exception.Message

            if ($statusCode -eq 401) {
                Write-Host ""
                Write-Host "ERROR: 401 Unauthorized - Token authentication failed" -ForegroundColor Red
                Write-Host ""
                Write-Host "Troubleshooting steps:" -ForegroundColor Yellow
                Write-Host "1. Verify GITLAB_TOKEN is set in CI/CD Variables (Settings > CI/CD > Variables)" -ForegroundColor Yellow
                Write-Host "2. Ensure the token has 'api' scope" -ForegroundColor Yellow
                Write-Host "3. Check that the token has not expired" -ForegroundColor Yellow
                Write-Host "4. Verify the variable is not protected-only if running on unprotected branches" -ForegroundColor Yellow
                Write-Host ""
            }

            throw "GitLab API request failed: $statusCode - $errorMessage - URI: $Uri"
        }
    }

    end {
    }
}

function Get-MergeRequestDetails {
    <#
    .SYNOPSIS
        Fetches merge request details from GitLab API
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitLabUrl,

        [Parameter(Mandatory = $true)]
        [string]$ProjectId,

        [Parameter(Mandatory = $true)]
        [string]$MrIid,

        [Parameter(Mandatory = $true)]
        [string]$Token
    )

    begin {
        Write-Verbose "Fetching merge request details for MR #$MrIid"
    }

    process {
        $uri = "$GitLabUrl/api/v4/projects/$ProjectId/merge_requests/$MrIid"
        return Invoke-GitLabAPI -Uri $uri -Token $Token
    }

    end {
    }
}

function Get-IssueDetails {
    <#
    .SYNOPSIS
        Fetches issue details from GitLab API
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitLabUrl,

        [Parameter(Mandatory = $true)]
        [string]$ProjectId,

        [Parameter(Mandatory = $true)]
        [string]$IssueIid,

        [Parameter(Mandatory = $true)]
        [string]$Token
    )

    begin {
        Write-Verbose "Fetching issue details for Issue #$IssueIid"
    }

    process {
        $uri = "$GitLabUrl/api/v4/projects/$ProjectId/issues/$IssueIid"
        return Invoke-GitLabAPI -Uri $uri -Token $Token
    }

    end {
    }
}

function Add-MergeRequestComment {
    <#
    .SYNOPSIS
        Posts a comment on a merge request
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitLabUrl,

        [Parameter(Mandatory = $true)]
        [string]$ProjectId,

        [Parameter(Mandatory = $true)]
        [string]$MrIid,

        [Parameter(Mandatory = $true)]
        [string]$Token,

        [Parameter(Mandatory = $true)]
        [string]$Comment
    )

    begin {
        Write-Verbose "Preparing to post comment to MR #$MrIid"
    }

    process {
        $uri = "$GitLabUrl/api/v4/projects/$ProjectId/merge_requests/$MrIid/notes"

        $body = @{
            body = $Comment
        } | ConvertTo-Json

        $headers = @{
            'PRIVATE-TOKEN' = $Token
            'Content-Type'  = 'application/json'
        }

        try {
            Write-Host "  Posting comment to MR..." -ForegroundColor Gray
            $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method POST -Body $body -ErrorAction Stop
            return $response
        }
        catch {
            Write-Host "  Warning: Failed to post comment to MR: $($_.Exception.Message)" -ForegroundColor Yellow
            # Don't throw - commenting is secondary to validation
        }
    }

    end {
    }
}

#endregion

#region Parsing and Validation Functions

function Get-IssueReferences {
    <#
    .SYNOPSIS
        Extracts issue references from text
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    begin {
        Write-Verbose "Extracting issue references from text"
    }

    process {
        $issueIds = @()

        # Pattern matches: closes #123, fixes #123, resolves #123, #123, /issues/123
        $patterns = @(
            '(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s+#(\d+)',
            '(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s+https?://[^\s]+/issues/(\d+)',
            '#(\d+)',
            '/issues/(\d+)'
        )

        foreach ($pattern in $patterns) {
            $matches = [regex]::Matches($Text, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            foreach ($match in $matches) {
                if ($match.Groups.Count -gt 1) {
                    $issueIds += $match.Groups[1].Value
                }
            }
        }

        # Return unique, sorted issue IDs
        return $issueIds | Select-Object -Unique | Sort-Object
    }

    end {
    }
}

function Test-Checkboxes {
    <#
    .SYNOPSIS
        Checks for unchecked checkboxes in the description
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Description
    )

    begin {
        Write-Verbose "Testing checkboxes in issue description"
    }

    process {
        # Patterns for checkboxes (handles both regular and escaped brackets)
        # Matches: - [x] or - \[x\] or * [x] or * \[x\]
        $checkedPattern = '[-*]\s+\\?\[x\\?\]\s+(.+?)(?:\r?\n|$)'
        # Matches: - [ ] or - \[ \] or * [ ] or * \[ \]
        $uncheckedPattern = '[-*]\s+\\?\[\s\\?\]\s+(.+?)(?:\r?\n|$)'

        $checkedMatches = [regex]::Matches($Description, $checkedPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $uncheckedMatches = [regex]::Matches($Description, $uncheckedPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

        $checked = @()
        $unchecked = @()

        foreach ($match in $checkedMatches) {
            if ($match.Groups.Count -gt 1) {
                $checked += $match.Groups[1].Value.Trim()
            }
        }

        foreach ($match in $uncheckedMatches) {
            if ($match.Groups.Count -gt 1) {
                $unchecked += $match.Groups[1].Value.Trim()
            }
        }

        $total = $checked.Count + $unchecked.Count

        return @{
            Total     = $total
            Checked   = $checked.Count
            Unchecked = $unchecked
        }
    }

    end {
    }
}

#endregion

#region Main Script

try {
    # Get environment variables from GitLab CI
    $gitlabUrl = Get-EnvironmentVariable -Name 'CI_SERVER_URL'
    $projectId = Get-EnvironmentVariable -Name 'CI_PROJECT_ID'
    $mrIid = Get-EnvironmentVariable -Name 'CI_MERGE_REQUEST_IID'
    $token = Get-EnvironmentVariable -Name 'GITLAB_TOKEN'

    Write-Host "---GitLab MR Issue Checkbox Validator---"
    Write-Host "Project: $projectId"
    Write-Host "MR IID: $mrIid"
    Write-Host "GitLab URL: $gitlabUrl"
    Write-Host "Token configured: $(if ($token) { 'Yes (length: ' + $token.Length + ')' } else { 'No' })"
    Write-Host ""

    # Fetch MR details
    Write-Host "Fetching merge request details..."
    $mrData = Get-MergeRequestDetails -GitLabUrl $gitlabUrl -ProjectId $projectId -MrIid $mrIid -Token $token

    # Extract issue references from MR title and description
    $mrText = "$($mrData.title) $($mrData.description)"
    $issueRefs = Get-IssueReferences -Text $mrText

    if ($issueRefs.Count -eq 0) {
        Write-Host "WARNING: No issue references found in MR title or description." -ForegroundColor Yellow
        Write-Host "Please link an issue to this MR using formats like:"
        Write-Host "  - Closes #123"
        Write-Host "  - Fixes #123"
        Write-Host "  - Resolves #123"
        Write-Host "  - #123"
        $commentLines = @()
        $commentLines += "WARNING: No issue references found in MR title or description."
        $commentLines += ''
        $commentLines += "Please link an issue to this MR using formats like:"
        $commentLines += "  - Closes #123"
        $commentLines += "  - Fixes #123"
        $commentLines += "  - Resolves #123"
        $commentLines += "  - #123"
        $comment = $commentLines -join "`n"

        Add-MergeRequestComment -GitLabUrl $gitlabUrl -ProjectId $projectId -MrIid $mrIid -Token $token -Comment $comment
        exit 1
    }

    $issueRefsDisplay = ($issueRefs | ForEach-Object { "#$_" }) -join ', '
    Write-Host "Found issue reference(s): $issueRefsDisplay"
    Write-Host ""

    # Check each linked issue
    $allPassed = $true
    $issuesWithProblems = @()

    foreach ($issueIid in $issueRefs) {
        Write-Host "Checking issue #$issueIid..."

        try {
            $issueData = Get-IssueDetails -GitLabUrl $gitlabUrl -ProjectId $projectId -IssueIid $issueIid -Token $token
            $description = if ($null -eq $issueData.description) { "" } else { $issueData.description }

            $checkboxResult = Test-Checkboxes -Description $description

            if ($checkboxResult.Total -eq 0) {
                Write-Host "  No checkboxes found in issue #$issueIid" -ForegroundColor Yellow
                continue
            }

            Write-Host "  Total checkboxes: $($checkboxResult.Total)"
            Write-Host "  Checked: $($checkboxResult.Checked)"
            Write-Host "  Unchecked: $($checkboxResult.Unchecked.Count)"

            if ($checkboxResult.Unchecked.Count -gt 0) {
                Write-Host ""
                Write-Host "  Unchecked items in issue #${issueIid}:" -ForegroundColor Red
                foreach ($item in $checkboxResult.Unchecked) {
                    Write-Host "    - [ ] $item" -ForegroundColor Red
                }
                $allPassed = $false

                # Store issue info for comment
                $issuesWithProblems += @{
                    IssueIid       = $issueIid
                    IssueUrl       = $issueData.web_url
                    UncheckedItems = $checkboxResult.Unchecked
                }
            }
            else {
                Write-Host "  All checkboxes are checked!" -ForegroundColor Green
            }

            Write-Host ""
        }
        catch {
            Write-Host "  Error fetching issue #${issueIid}: $_" -ForegroundColor Red
            $allPassed = $false

            # Store error info for comment
            $issuesWithProblems += @{
                IssueIid = $issueIid
                Error    = $_.Exception.Message
            }
        }
    }

    # Final result
    Write-Host "=" * 80
    if ($allPassed) {
        Write-Host "SUCCESS: All checkboxes in linked issues are checked!" -ForegroundColor Green
        Write-Host "=" * 80
        exit 0
    }
    else {
        Write-Host "FAILURE: Some checkboxes are not checked or issues could not be fetched." -ForegroundColor Red
        Write-Host "Please ensure all acceptance criteria are completed before merging."
        Write-Host "=" * 80

        # Post comment to MR with details
        if ($issuesWithProblems.Count -gt 0) {
            Write-Host ""
            Write-Host "Posting failure details to merge request..."

            $commentLines = @()
            $commentLines += '## :x: Issue Checkbox Validation Failed'
            $commentLines += ''
            $commentLines += 'The following issues have unchecked acceptance criteria that must be completed before this merge request can be merged:'
            $commentLines += ''

            foreach ($issue in $issuesWithProblems) {
                if ($issue.Error) {
                    $commentLines += "### Issue #$($issue.IssueIid)"
                    $commentLines += (':warning: **Error:** {0}' -f $issue.Error)
                    $commentLines += ''
                }
                else {
                    $commentLines += "### [Issue #$($issue.IssueIid)]($($issue.IssueUrl))"
                    $commentLines += ''
                    $commentLines += "**Unchecked items ($($issue.UncheckedItems.Count)):**"
                    foreach ($item in $issue.UncheckedItems) {
                        $commentLines += "- [ ] $item"
                    }
                    $commentLines += ''
                }
            }

            $commentLines += '---'
            $commentLines += '*Please complete all acceptance criteria and re-run the check again.*'

            $comment = $commentLines -join "`n"

            Add-MergeRequestComment -GitLabUrl $gitlabUrl -ProjectId $projectId -MrIid $mrIid -Token $token -Comment $comment
            Write-Host "Comment posted successfully!" -ForegroundColor Green
        }

        exit 1
    }
}
catch {
    Write-Host "Error: $_" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    exit 1
}

#endregion

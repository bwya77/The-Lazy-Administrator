using namespace System.Net

param($Request, $TriggerMetadata)

function New-ProofpointUser {
    param (
        [Parameter(Mandatory)]
        [string]$OrgDomain,
        [Parameter(Mandatory)]
        [string]$ProofPointUser,
        [Parameter(Mandatory)]
        [string]$ProofPointPassword,
        [Parameter(Mandatory)]
        [string]$FirstName,
        [Parameter(Mandatory)]
        [string]$LastName,
        [Parameter(Mandatory)]
        [string]$Email,
        [ValidateSet("end_user", "channel_admin")]
        [string]$Type = "channel_admin",
        [ValidateSet("US1", "US2", "US3", "US4", "US5", "EU1")]
        [string[]]$Region = @("US1")
    )
    begin {
        $Headers = @{
            "X-User"       = $ProofPointUser
            "X-Password"   = $ProofPointPassword
            "Content-Type" = "application/json"
        }
    }
    process {
        $Body = @{
            firstname     = $FirstName
            surname       = $LastName
            primary_email = $Email
            type          = $Type
        } | ConvertTo-Json

        Try {
            $items = $Region
            foreach ($item in $items) {
                Write-Host "Creating user $Email in Proofpoint region $item"
                $Response = Invoke-RestMethod -Uri "https://$item.proofpointessentials.com/api/v1/orgs/$OrgDomain/users" -Method Post -Headers $Headers -Body $Body -ErrorAction Stop
            }
        }
        Catch {
            $errorMessage = "Failed to create user $Email in Proofpoint: $_"
            Write-Error $errorMessage
            throw $errorMessage
        }
    }
    end {
        return $Response
    }
}

function Get-ProofpointUsers {
    param (
        [Parameter(Mandatory)]
        [string]$OrgDomain,
        [Parameter(Mandatory)]
        [string]$ProofPointUser,
        [Parameter(Mandatory)]
        [string]$ProofPointPassword,
        [ValidateSet("US1", "US2", "US3", "US4", "US5", "EU1")]
        [string[]]$Region = @("US1")
    )
    begin {
        $Headers = @{
            "X-User"       = $ProofPointUser
            "X-Password"   = $ProofPointPassword
            "Content-Type" = "application/json"
        }
        
    }
    process {
        Try {
            $items = $Region
            foreach ($item in $items) {
                Write-Host "Retrieving users from Proofpoint region $item"
                $Uri = "https://$item.proofpointessentials.com/api/v1/orgs/$OrgDomain/users"
                $Response = Invoke-RestMethod -Uri $Uri -Method Get -Headers $Headers -ErrorAction Stop
            }
        }
        Catch {
            $errorMessage = "Failed to retrieve users from Proofpoint: $_"
            Write-Error $errorMessage
            throw $errorMessage
        }
    }
    end {
        return $Response.users
    }
}

function Remove-ProofpointUser {
    param (
        [Parameter(Mandatory)]
        [string]$OrgDomain,
        [Parameter(Mandatory)]
        [string]$ProofPointUser,
        [Parameter(Mandatory)]
        [string]$ProofPointPassword,
        [Parameter(Mandatory)]
        [string]$UserEmail,
        [ValidateSet("US1", "US2", "US3", "US4", "US5", "EU1")]
        [string[]]$Region = @("US1")
    )
    begin {
        $Headers = @{
            "X-User"       = $ProofPointUser
            "X-Password"   = $ProofPointPassword
            "Content-Type" = "application/json"
        }
    }
    process {
        Try {
            $items = $Region
            foreach ($item in $items) {
                Write-Host "Deleting user $UserEmail from Proofpoint region $item"
                $Uri = "https://$item.proofpointessentials.com/api/v1/orgs/$OrgDomain/users/$UserEmail"
                $Response = Invoke-RestMethod -Uri $Uri -Method Delete -Headers $Headers -ErrorAction Stop
            }
        }
        Catch {
            $errorMessage = "Failed to delete user $UserEmail from Proofpoint: $_"
            Write-Error $errorMessage
            throw $errorMessage
        }
    }
    end {
        Write-Verbose "User $UserEmail deleted successfully."  
        return $Response
    }
}

$clientID = $env:EntraIDProofpointUserProvisionclientID
$clientSecret = $env:EntraIDProofpointUserProvisionclientSecret
$tenantID = $env:EntraIDtenantID
$proofPointOrgDomain = $env:proofPointOrgDomain
$proofPointUser = $env:proofPointUser
$proofPointPassword = $env:proofPointPassword
$expectedClientState = $env:clientState
$ProofpointRegions = @("US1","US2", "US3", "US4")

# Handle validation request
if ($Request.Query.validationToken) {
    $validationToken = [System.Web.HttpUtility]::UrlDecode($Request.Query.validationToken)
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode  = [HttpStatusCode]::OK
            ContentType = "text/plain"
            Body        = $validationToken
        })
    return
}

# Handle change notifications
if ($Request.Body) {
    try {
        # Get the single notification from the value array
        $notification = $Request.Body.value[0]
        
        # Verify clientState matches expected value
        if ($notification.clientState -ne $expectedClientState) {
            Write-Warning "ClientState mismatch! The notification will not be processed."
            Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
                    StatusCode = [HttpStatusCode]::Unauthorized
                    Body       = "Invalid client state"
                })
            return
        }
        
        # Extract the group ID
        $groupId = $notification.resourceData.id
        
        # Get the members delta array
        $membersDelta = $notification.resourceData.'members@delta'
        
        if ($membersDelta) {
            # Separate added and removed users
            $addedUsers = @()
            $removedUsers = @()

            # Get Graph Access Token
            try {
                $graphTokenResponse = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$tenantID/oauth2/v2.0/token" -ContentType "application/x-www-form-urlencoded" -Body @{
                    client_id     = $clientID
                    scope         = "https://graph.microsoft.com/.default"
                    client_secret = $clientSecret
                    grant_type    = "client_credentials"
                } -ErrorAction Stop
                $graphToken = $graphTokenResponse.access_token
            }
            catch {
                $errorMessage = "Failed to obtain Graph token: $_"
                Write-Error $errorMessage
                Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
                        StatusCode = [HttpStatusCode]::InternalServerError
                        Body       = $errorMessage
                    })
                return
            }
            
            foreach ($member in $membersDelta) {
                if ($member.'@removed') {
                    $removedUsers += $member.id
                }
                else {
                    $addedUsers += $member.id
                }
            }
            
            # Process removed users
            if ($removedUsers.Count -gt 0) {
                Write-Host "Processing $($removedUsers.Count) removed user(s) from group $groupId"
                foreach ($userId in $removedUsers) {
                    Write-Host "User removed: $userId"
                    
                    try {
                        # Lookup user details in Microsoft Graph
                        Write-Host "Looking up user details in Microsoft Graph for ID: $userId"
                        $userDetails = Invoke-RestMethod -Method Get -Uri "https://graph.microsoft.com/v1.0/users/$userId" -Headers @{
                            Authorization = "Bearer $graphToken"
                        } -ErrorAction Stop
                        
                        Write-Host "User displayname: $($userDetails.displayName) with UserPrincipalName: $($userDetails.userPrincipalName)"
                        $RemoveUser = $userDetails.userPrincipalName
                        $ProofpointRegions | ForEach-Object {
                            Write-Host "Current Proofpoint Regions: $_"
                            # Get current Proofpoint users (will throw if fails)
                            $proofpointUser = Get-ProofpointUsers -OrgDomain $proofPointOrgDomain -ProofPointUser $env:proofPointUser -ProofPointPassword $env:proofPointPassword -Region $_ | Where-Object { $_.primary_email -eq $RemoveUser }
                            if ($proofpointUser) {  
                                Write-Host "Removing user $RemoveUser in Proofpoint."
                                Remove-ProofpointUser -OrgDomain $proofPointOrgDomain -ProofPointUser $env:proofPointUser -ProofPointPassword $env:proofPointPassword -UserEmail $RemoveUser -Region $_
                            }
                            else {
                                Write-Host "User $($userDetails.userPrincipalName) not found in Proofpoint."
                            }
                        }
                    }
                    catch {
                        # Log the error but don't fail the entire operation for one user
                        Write-Warning "Failed to process removed user $userId : $_"
                    }
                }
            }
            
            # Process added users
            if ($addedUsers.Count -gt 0) {
                Write-Host "Processing $($addedUsers.Count) added user(s) to group $groupId"
                foreach ($userId in $addedUsers) {
                    Write-Host "User added: $userId"
                    
                    try {
                        # Lookup user details in Microsoft Graph
                        Write-Host "Looking up user details in Microsoft Graph for ID: $userId"
                        $userDetails = Invoke-RestMethod -Method Get -Uri "https://graph.microsoft.com/v1.0/users/$userId" -Headers @{
                            Authorization = "Bearer $graphToken"
                        } -ErrorAction Stop
                        
                        Write-Host "User displayname: $($userDetails.displayName) with UserPrincipalName: $($userDetails.userPrincipalName)"
                        $AddUser = $userDetails.userPrincipalName
                        $ProofpointRegions | ForEach-Object {
                            Write-Host "Current Proofpoint Regions: $_"
                            # Get current Proofpoint users (will throw if fails)
                            $proofpointUser = Get-ProofpointUsers -OrgDomain $proofPointOrgDomain -ProofPointUser $env:proofPointUser -ProofPointPassword $env:proofPointPassword -Region $_ | Where-Object { $_.primary_email -eq $AddUser }
                            if (-not $proofpointUser) {  
                                Write-Host "Creating user $AddUser in Proofpoint."
                                New-ProofpointUser -OrgDomain $proofPointOrgDomain -ProofPointUser $env:proofPointUser -ProofPointPassword $env:proofPointPassword -FirstName $userDetails.givenName -LastName $userDetails.surname -Email $AddUser -Region $_
                            }
                            else {
                                Write-Host "User $($userDetails.userPrincipalName) already exists in Proofpoint."
                            }
                        }
                    }
                    catch {
                        # Log the error but don't fail the entire operation for one user
                        Write-Warning "Failed to process added user $userId : $_"
                    }
                }
            }
        }
        
        # Return success response - only reached if no critical errors occurred
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::OK
                Body       = "Notification processed successfully"
            })
    }
    catch {
        Write-Error "Error processing notification: $_"
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::InternalServerError
                Body       = "Error processing notification: $_"
            })
    }
}

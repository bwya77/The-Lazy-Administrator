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
        [string]$Type = "channel_admin"
    )
    begin {
        $Headers = @{
            "X-User"       = $ProofPointUser
            "X-Password"   = $ProofPointPassword
            "Content-Type" = "application/json"
        }
        $Uri = "https://us1.proofpointessentials.com/api/v1/orgs/$OrgDomain/users"
    }
    process {
        $Body = @{
            firstname     = $FirstName
            surname       = $LastName
            primary_email = $Email
            type          = $Type
        } | ConvertTo-Json

        Try {
            $Response = Invoke-RestMethod -Uri $Uri -Method Post -Headers $Headers -Body $Body
        }
        Catch {
            Write-Error "Failed to create user: $_"
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
        [string]$ProofPointPassword
    )
    begin {
        $Headers = @{
            "X-User"       = $ProofPointUser
            "X-Password"   = $ProofPointPassword
            "Content-Type" = "application/json"
        }
        $Uri = "https://us1.proofpointessentials.com/api/v1/orgs/$OrgDomain/users"
    }
    process {
        Try {
            $Response = Invoke-RestMethod -Uri $Uri -Method Get -Headers $Headers
        }
        Catch {
            Write-Error "Failed to retrieve users: $_"
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
        [string]$UserEmail
    )
    begin {
        $Headers = @{
            "X-User"       = $ProofPointUser
            "X-Password"   = $ProofPointPassword
            "Content-Type" = "application/json"
        }
        $Uri = "https://us1.proofpointessentials.com/api/v1/orgs/$OrgDomain/users/$UserEmail"
    }
    process {
        Try {
            $Response = Invoke-RestMethod -Uri $Uri -Method Delete -Headers $Headers
        }
        Catch {
            Write-Error "Failed to delete user: $_"
        }
    }
    end {
        Write-Verbose "User $UserEmail deleted successfully."  
        return $Response
    }
}

$clientID = $env:clientID
$clientSecret = $env:clientSecret
$tenantID = $env:tenantID
$proofPointOrgDomain = $env:proofPointOrgDomain
$proofPointUser = $env:proofPointUser
$proofPointPassword = $env:proofPointPassword

# Handle validation request
if ($Request.Query.validationToken) {
    $validationToken = [System.Web.HttpUtility]::UrlDecode($Request.Query.validationToken)
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode  = [HttpStatusCode]::OK
            ContentType = "text/plain"
            Body        = $validationToken
        })
    return  # Exit immediately after validation
}

# Handle change notifications
if ($Request.Body) {
    try {
        # Get the expected clientState from environment variable
        $expectedClientState = $env:clientState
        
        # Get the single notification from the value array
        $notification = $Request.Body.value[0]
        
        # Verify clientState matches expected value
        if ($notification.clientState -ne $expectedClientState) {
            Write-Warning "ClientState mismatch! The notification will not be processed."
            Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
                    StatusCode = [HttpStatusCode]::Unauthorized
                    Body       = "Invalid client state"
                })
            return  # Exit without processing
        }
        
        # Extract the group ID
        $groupId = $notification.resourceData.id
        # Get current Proofpoint users
        $proofpointUsers = Get-ProofpointUsers -OrgDomain $proofPointOrgDomain -ProofPointUser $env:proofPointUser -ProofPointPassword $env:proofPointPassword
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
                }
                $graphToken = $graphTokenResponse.access_token
            }
            catch {
                Write-Error "Failed to obtain Graph token: $_"
                Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
                    StatusCode = [HttpStatusCode]::InternalServerError
                    Body       = "Failed to obtain Graph token"
                })
                return
            }
            
            foreach ($member in $membersDelta) {
                if ($member.'@removed') {
                    # User was removed from the group
                    $removedUsers += $member.id
                }
                else {
                    # User was added to the group
                    $addedUsers += $member.id
                }
            }
            
            # Process removed users
            if ($removedUsers.Count -gt 0) {
                Write-Host "Processing $($removedUsers.Count) removed user(s) from group $groupId"
                foreach ($userId in $removedUsers) {
                    Write-Host "User removed: $userId"
                    
                    # Lookup user details in Microsoft Graph
                    Write-Host "Looking up user details in Microsoft Graph for ID: $userId"
                    $userDetails = Invoke-RestMethod -Method Get -Uri "https://graph.microsoft.com/v1.0/users/$userId" -Headers @{
                        Authorization = "Bearer $graphToken"
                    }
                    if (!$userDetails) {
                        Write-Warning "Failed to retrieve details for user ID: $userId"
                        continue
                    }
                    Write-Host "User displayname: $($userDetails.displayName) with UserPrincipalName: $($userDetails.userPrincipalName)"
                    #Check if user exists in Proofpoint and remove
                    $RemoveUser = $userDetails.userPrincipalName
                    $proofpointUser = $proofpointUsers | Where-Object { $_.primary_email -eq $RemoveUser }
                    if ($proofpointUser) {  
                        Write-Host "Removing user $RemoveUser in Proofpoint."
                        Remove-ProofpointUser -OrgDomain $proofPointOrgDomain -ProofPointUser $env:proofPointUser -ProofPointPassword $env:proofPointPassword -UserEmail $RemoveUser #$proofpointUser.primary_email
                    }
                    else {
                        Write-Host "User $($userDetails.userPrincipalName) not found in Proofpoint."
                    }
                }
            }
            
            # Process added users
            if ($addedUsers.Count -gt 0) {
                Write-Host "Processing $($addedUsers.Count) added user(s) to group $groupId"
                foreach ($userId in $addedUsers) {
                    Write-Host "User added: $userId"
                    
                    # Lookup user details in Microsoft Graph
                    Write-Host "Looking up user details in Microsoft Graph for ID: $userId"
                    $userDetails = Invoke-RestMethod -Method Get -Uri "https://graph.microsoft.com/v1.0/users/$userId" -Headers @{
                        Authorization = "Bearer $graphToken"
                    }
                    if (!$userDetails) {
                        Write-Warning "Failed to retrieve details for user ID: $userId"
                        continue
                    }
                    Write-Host "User displayname: $($userDetails.displayName) with UserPrincipalName: $($userDetails.userPrincipalName)"
                    # Check if user already exists in Proofpoint and add if not 
                    $proofpointUser = $proofpointUsers | Where-Object { $_.primary_email -eq $userDetails.userPrincipalName }
                    if (-not $proofpointUser) {  
                        $NewUser = $userDetails.userPrincipalName
                        Write-Host "Creating user $NewUser in Proofpoint."
                        New-ProofpointUser -OrgDomain $proofPointOrgDomain -ProofPointUser $env:proofPointUser -ProofPointPassword $env:proofPointPassword -FirstName $userDetails.givenName -LastName $userDetails.surname -Email $NewUser
                    }
                    else {
                        Write-Host "User $($userDetails.userPrincipalName) already exists in Proofpoint."
                    }
                }
            }
        }
        
        # Return success response
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::OK
                Body       = "Notification processed successfully"
            })
    }
    catch {
        Write-Error "Error processing notification: $_"
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::InternalServerError
                Body       = "Error processing notification"
            })
    }
}

using namespace System.Net

param($Request, $TriggerMetadata)

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
            Write-Warning "ClientState mismatch. Expected: $expectedClientState, Received: $($notification.clientState)"
            Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
                    StatusCode = [HttpStatusCode]::Unauthorized
                    Body       = "Invalid client state"
                })
            return  # Exit without processing
        }
        
        # Extract the group ID
        $groupId = $notification.resourceData.id
        
        # Get the members delta array
        $membersDelta = $notification.resourceData.'members@delta'
        
        if ($membersDelta) {
            # Separate added and removed users
            $addedUsers = @()
            $removedUsers = @()
            
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
                    
                    # TODO: Add your processing logic for removed users here
                    # Example: Remove-UserFromSystem -UserId $userId -GroupId $groupId
                }
            }
            
            # Process added users
            if ($addedUsers.Count -gt 0) {
                Write-Host "Processing $($addedUsers.Count) added user(s) to group $groupId"
                foreach ($userId in $addedUsers) {
                    Write-Host "User added: $userId"
                    
                    # TODO: Add your processing logic for added users here
                    # Example: Add-UserToSystem -UserId $userId -GroupId $groupId
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

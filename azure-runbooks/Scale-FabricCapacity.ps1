<#
.SYNOPSIS
    Scales a Microsoft Fabric capacity to a different SKU.

.DESCRIPTION
    This runbook scales a Microsoft Fabric capacity to a different SKU using the Microsoft Fabric API.
    It authenticates to Azure using a managed identity.

.PARAMETER CapacityId
    The ID of the Microsoft Fabric capacity to scale.
    This should be in the format: /subscriptions/{subscriptionId}/resourceGroups/{resourceGroupName}/providers/Microsoft.Fabric/capacities/{capacityName}

.PARAMETER TargetSku
    The target SKU to scale to (F2, F4, F8, F16, F32, F64, F128, F256, F512, F1024).

.PARAMETER WaitForCompletion
    Whether to wait for the capacity to be fully scaled before returning. Default: $true

.PARAMETER TimeoutInMinutes
    The maximum time to wait for the capacity to scale, in minutes. Default: 10

.NOTES
    Author: Premier Forge
    Created: 2025-03-07
    Version: 2.0
    Updated: 2025-04-03 - Migrated to managed identity authentication
#>

param (
    [Parameter(Mandatory = $true)]
    [string]$CapacityId,

    [Parameter(Mandatory = $true)]
    [ValidateSet("F2", "F4", "F8", "F16", "F32", "F64", "F128", "F256", "F512", "F1024")]
    [string]$TargetSku,

    [Parameter(Mandatory = $false)]
    [bool]$WaitForCompletion = $true,

    [Parameter(Mandatory = $false)]
    [int]$TimeoutInMinutes = 10
)

# Error action preference
$ErrorActionPreference = "Stop"

# Function to write output
function Write-Log {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet("Info", "Warning", "Error")]
        [string]$Level = "Info"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    if ($Level -eq "Error") {
        Write-Error $logMessage
    }
    elseif ($Level -eq "Warning") {
        Write-Warning $logMessage
    }
    else {
        Write-Output $logMessage
    }
}

# Function to parse the capacity ID
function Get-CapacityDetails {
    param (
        [Parameter(Mandatory = $true)]
        [string]$CapacityId
    )
    
    try {
        # Parse the capacity ID
        $pattern = "^/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/Microsoft\.Fabric/capacities/([^/]+)$"
        $match = [regex]::Match($CapacityId, $pattern)
        
        if (-not $match.Success) {
            throw "Invalid capacity ID format. Expected format: /subscriptions/{subscriptionId}/resourceGroups/{resourceGroupName}/providers/Microsoft.Fabric/capacities/{capacityName}"
        }
        
        $subscriptionId = $match.Groups[1].Value
        $resourceGroupName = $match.Groups[2].Value
        $capacityName = $match.Groups[3].Value
        
        return @{
            SubscriptionId = $subscriptionId
            ResourceGroupName = $resourceGroupName
            CapacityName = $capacityName
        }
    }
    catch {
        Write-Log "Failed to parse capacity ID: $_" -Level "Error"
        throw
    }
}

# Function to get the capacity status
function Get-CapacityStatus {
    param (
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,
        
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        
        [Parameter(Mandatory = $true)]
        [string]$CapacityName
    )
    
    try {
        # Get the capacity
        $apiVersion = "2023-11-01"
        $uri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Fabric/capacities/$CapacityName`?api-version=$apiVersion"
        
        $response = Invoke-RestMethod -Uri $uri -Method Get -Headers @{
            "Authorization" = "Bearer $script:accessToken"
            "Content-Type" = "application/json"
        }
        
        return $response
    }
    catch {
        Write-Log "Failed to get capacity status: $_" -Level "Error"
        throw
    }
}

# Function to start the capacity
function Start-Capacity {
    param (
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,
        
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        
        [Parameter(Mandatory = $true)]
        [string]$CapacityName
    )
    
    try {
        # Start the capacity (resume endpoint)
        $apiVersion = "2023-11-01"
        $uri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Fabric/capacities/$CapacityName/resume`?api-version=$apiVersion"
        
        $response = Invoke-RestMethod -Uri $uri -Method Post -Headers @{
            "Authorization" = "Bearer $script:accessToken"
            "Content-Type" = "application/json"
        }
        
        return $response
    }
    catch {
        # Add specific error logging for starting
        Write-Log "Failed to send start (resume) request for capacity: $_" -Level "Error"
        throw
    }
}

# Function to scale the capacity
function Scale-Capacity {
    param (
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,
        
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        
        [Parameter(Mandatory = $true)]
        [string]$CapacityName,
        
        [Parameter(Mandatory = $true)]
        [string]$TargetSku,
        
        [Parameter(Mandatory = $true)]
        [object]$CurrentCapacity
    )
    
    Write-Output "DEBUG: Entering Scale-Capacity function"
    Write-Log "Entering Scale-Capacity function" -Level "Info"
    
    try {
        # Create the update payload
        $apiVersion = "2023-11-01"
        $uri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Fabric/capacities/$CapacityName`?api-version=$apiVersion"
        Write-Log "URI: $uri" -Level "Info"
        
        # Create a copy of the current capacity properties but update the SKU
        $updatePayload = @{
            location = $CurrentCapacity.location
            sku = @{
                name = $TargetSku
            }
            properties = $CurrentCapacity.properties
        }
        
        $jsonPayload = $updatePayload | ConvertTo-Json -Depth 10
        
        Write-Output "DEBUG: Payload ready and about to call API"
        Write-Log "Prepared payload for scaling: $($jsonPayload.Substring(0, [Math]::Min(500, $jsonPayload.Length)))" -Level "Info"
        Write-Log "About to send scale request to API: $uri" -Level "Info"
        
        # Update the capacity
        Write-Output "DEBUG: Executing Invoke-RestMethod..."
        Write-Log "Executing Invoke-RestMethod..." -Level "Info"
        $response = Invoke-RestMethod -Uri $uri -Method Put -Headers @{
            "Authorization" = "Bearer $script:accessToken"
            "Content-Type" = "application/json"
        } -Body $jsonPayload -Verbose
        
        Write-Output "DEBUG: API call completed successfully"
        Write-Log "Successfully received response from scaling API" -Level "Info"
        return $response
    }
    catch {
        Write-Output "DEBUG: Exception caught in Scale-Capacity: $($_.Exception.Message)"
        Write-Log "Failed to scale capacity with detailed error:" -Level "Error"
        
        # Extract detailed error information
        if ($_.Exception.Response) {
            Write-Log "Status code: $($_.Exception.Response.StatusCode.value__)" -Level "Error"
            
            try {
                # Try to get response body for more details
                $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $reader.BaseStream.Position = 0
                $reader.DiscardBufferedData()
                $responseBody = $reader.ReadToEnd()
                Write-Log "Response body: $responseBody" -Level "Error"
                Write-Output "DEBUG: Response body: $responseBody"
            }
            catch {
                Write-Log "Could not read response body: $_" -Level "Error"
            }
        }
        
        Write-Log "Exception message: $($_.Exception.Message)" -Level "Error"
        Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level "Error"
        throw
    }
}

# Function to wait for the capacity scaling to complete
function Wait-ForCapacityScaling {
    param (
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,
        
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        
        [Parameter(Mandatory = $true)]
        [string]$CapacityName,
        
        [Parameter(Mandatory = $true)]
        [string]$TargetSku,
        
        [Parameter(Mandatory = $true)]
        [int]$TimeoutInMinutes
    )
    
    try {
        $timeout = (Get-Date).AddMinutes($TimeoutInMinutes)
        $status = $null
        $isScaled = $false
        $failed = $false
        $failureReason = ""
        $runningStates = @("Running", "Active") # Define target states
        $failedStates = @("Paused", "Failed", "Error") # Define failure states
        
        Write-Log "Waiting for capacity to scale to $TargetSku..."
        
        while ((Get-Date) -lt $timeout -and -not $isScaled -and -not $failed) {
            $capacity = Get-CapacityStatus -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -CapacityName $CapacityName
            $currentSku = $capacity.sku.name
            $state = $capacity.properties.state
            $provisioningState = $capacity.properties.provisioningState
            
            # Check for failure conditions first
            if ($failedStates -contains $state) {
                $failed = $true
                $failureReason = "Capacity entered $state state during scaling operation. This may indicate a quota limitation or other error."
                Write-Log "Scaling operation failed: $failureReason" -Level "Error"
                break
            }
            
            # Check if provisioning state indicates failure
            if ($provisioningState -eq "Failed") {
                $failed = $true
                $failureReason = "Provisioning state reported as Failed. This often indicates a quota limitation."
                Write-Log "Scaling operation failed: $failureReason" -Level "Error"
                break
            }
            
            # Check for success condition
            if ($currentSku -eq $TargetSku -and ($runningStates -contains $state)) {
                $isScaled = $true
                Write-Log "Capacity has been successfully scaled to $TargetSku and is in $state state."
            }
            else {
                Write-Log "Current SKU: $currentSku (Target: $TargetSku), Status: $state, Provisioning: $provisioningState. Waiting 30 seconds..."
                Start-Sleep -Seconds 30
            }
        }
        
        if (-not $isScaled -and -not $failed) {
            $failed = $true
            $failureReason = "Timeout waiting for capacity to scale. Last SKU: $currentSku, Status: $state"
            Write-Log $failureReason -Level "Error"
        }
        
        if ($failed) {
            throw $failureReason
        }
        
        return $isScaled
    }
    catch {
        Write-Log "Error waiting for capacity to scale: $_" -Level "Error"
        throw
    }
}

# Function to wait for the capacity to start (copied from Start-FabricCapacity.ps1)
function Wait-ForCapacityStart {
    param (
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,
        
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        
        [Parameter(Mandatory = $true)]
        [string]$CapacityName,
        
        [Parameter(Mandatory = $true)]
        [int]$TimeoutInMinutes
    )
    
    try {
        $timeout = (Get-Date).AddMinutes($TimeoutInMinutes)
        $status = $null
        $isStarted = $false
        $validTransitionStates = @("Starting", "Resuming", "PreparingForRunning")
        $runningStates = @("Running", "Active")
        
        Write-Log "Waiting for capacity to start..."
        
        while ((Get-Date) -lt $timeout -and -not $isStarted) {
            # Use the same Get-CapacityStatus function defined earlier in this script
            $capacity = Get-CapacityStatus -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -CapacityName $CapacityName 
            $status = $capacity.properties.state
            
            if ($runningStates -contains $status) {
                $isStarted = $true
                Write-Log "Capacity is now $status. Proceeding with scaling."
            }
            elseif ($status -eq "Paused") {
                Write-Log "Capacity still shows as Paused. Waiting for state transition to begin..."
                Start-Sleep -Seconds 60
            }
            elseif ($validTransitionStates -contains $status) {
                Write-Log "Capacity is in transitional state: $status. Continuing to wait..."
                Start-Sleep -Seconds 30
            }
            else {
                Write-Log "Current status while waiting to start: $status. Waiting 30 seconds..."
                Start-Sleep -Seconds 30
            }
        }
        
        if (-not $isStarted) {
            # Warning instead of throwing an error immediately
            Write-Log "Timeout waiting for capacity to start before scaling attempt. Last status: $status" -Level "Warning"
        }
        
        return $isStarted
    }
    catch {
        Write-Log "Error waiting for capacity to start: $_" -Level "Error"
        # Don't re-throw here, let the main logic decide based on the return value
        return $false 
    }
}

# Main execution
try {
    # Import required modules
    Write-Log "Importing required modules..."
    Import-Module Az.Accounts -ErrorAction Stop
    
    # Parse the capacity ID
    $capacityDetails = Get-CapacityDetails -CapacityId $CapacityId
    $subscriptionId = $capacityDetails.SubscriptionId
    $resourceGroupName = $capacityDetails.ResourceGroupName
    $capacityName = $capacityDetails.CapacityName
    
    Write-Log "Scaling capacity: $capacityName in resource group: $resourceGroupName to SKU: $TargetSku"
    
    # Connect to Azure using managed identity
    Write-Log "Connecting to Azure using managed identity..."
    $azContext = Connect-AzAccount -Identity
    
    # Get an access token using managed identity
    $tokenResponse = Get-AzAccessToken -ResourceUrl "https://management.azure.com/"
    if ($tokenResponse.Token -is [System.Security.SecureString]) {
        # Convert SecureString to plain text (for newer Az module versions)
        $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($tokenResponse.Token)
        $script:accessToken = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
    } else {
        # Use as-is for current Az module versions
        $script:accessToken = $tokenResponse.Token
    }
    
    # Get the current status
    $capacity = Get-CapacityStatus -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -CapacityName $capacityName
    $currentStatus = $capacity.properties.state
    $currentSku = $capacity.sku.name
    
    Write-Log "Current capacity status: $currentStatus, SKU: $currentSku"
    
    # Check if the capacity is already at the target SKU
    if ($currentSku -eq $TargetSku) {
        Write-Log "Capacity is already at the target SKU ($TargetSku). No action needed."
        
        # Return the capacity details
        $result = @{
            CapacityName = $capacityName
            Status = $currentStatus
            SubscriptionId = $subscriptionId
            ResourceGroup = $resourceGroupName
            Region = $capacity.location
            SKU = $currentSku
            LastUpdated = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            Message = "No scaling needed - already at target SKU"
        }
        
        return $result | ConvertTo-Json -Depth 5
    }
    
    # Check if the capacity is running (needs to be running or active to scale)
    $runningStates = @("Running", "Active")
    if (-not ($runningStates -contains $currentStatus)) {
        Write-Log "Capacity is not in a running/active state ($currentStatus). Starting the capacity first..."
        
        # Use the Start-Capacity function
        $startResponse = Start-Capacity -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -CapacityName $capacityName
        
        # Add initial delay (consistent with Start-FabricCapacity.ps1)
        Write-Log "Waiting 30 seconds for capacity state transition to begin..."
        Start-Sleep -Seconds 30
        
        # Wait for the capacity to start before scaling
        if ($WaitForCompletion) {
            # Use the Wait-ForCapacityStart function (adjust timeout maybe? Using half for now)
            $isStarted = Wait-ForCapacityStart -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -CapacityName $capacityName -TimeoutInMinutes ($TimeoutInMinutes / 2)
            
            if (-not $isStarted) {
                # Handle failure to start - maybe exit or throw a more specific error
                throw "Capacity did not reach a running/active state within the allocated time after starting. Cannot proceed with scaling."
            }
            # Refresh capacity status after successful start
            $capacity = Get-CapacityStatus -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -CapacityName $capacityName
            $currentStatus = $capacity.properties.state
            $currentSku = $capacity.sku.name
            Write-Log "Capacity successfully started. Current status: $currentStatus, SKU: $currentSku"
        }
        else {
            # If not waiting, we cannot guarantee it started, so we should probably exit.
            throw "Capacity was not running/active and WaitForCompletion for starting was set to false. Cannot proceed with scaling."
        }
    }
    
    # Scale the capacity
    Write-Log "Scaling capacity from $currentSku to $TargetSku..." -Level "Info"
    Write-Log "About to call Scale-Capacity function" -Level "Info"
    
    try {
        $scaleResponse = Scale-Capacity -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -CapacityName $capacityName -TargetSku $TargetSku -CurrentCapacity $capacity
        
        # Examine and log the response 
        Write-Log "Scale operation response received. Response type: $($scaleResponse.GetType().FullName)" -Level "Info"
        Write-Log "Scale operation response status: $($scaleResponse.properties.provisioningState)" -Level "Info"
        Write-Log "Scale operation response SKU: $($scaleResponse.sku.name)" -Level "Info"
    }
    catch {
        Write-Log "Exception thrown when calling Scale-Capacity: $($_.Exception.Message)" -Level "Error"
        throw
    }
    
    Write-Log "Returned from Scale-Capacity function" -Level "Info"
    
    # Wait for the scaling to complete if requested
    $finalStatus = $currentStatus
    $finalSku = $currentSku
    if ($WaitForCompletion) {
        try {
            $isScaled = Wait-ForCapacityScaling -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -CapacityName $capacityName -TargetSku $TargetSku -TimeoutInMinutes $TimeoutInMinutes
            
            if ($isScaled) {
                $finalStatus = "Running"
                $finalSku = $TargetSku
            }
            else {
                # This should not happen as Wait-ForCapacityScaling will throw an exception if scaling fails
                $finalStatus = "ScalingFailed"
                $finalSku = "Failed to scale to $TargetSku"
                throw "Scaling operation failed to complete successfully"
            }
        }
        catch {
            # Get the updated capacity details after failure
            $updatedCapacity = Get-CapacityStatus -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -CapacityName $capacityName
            
            # Return an error result with capacity details
            $failureResult = @{
                CapacityName = $capacityName
                Status = $updatedCapacity.properties.state
                SubscriptionId = $subscriptionId
                ResourceGroup = $resourceGroupName
                Region = $updatedCapacity.location
                PreviousSKU = $currentSku
                CurrentSKU = $updatedCapacity.sku.name
                TargetSKU = $TargetSku
                LastUpdated = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                Error = $true
                ErrorMessage = "Scaling operation failed: $($_.Exception.Message)"
            }
            
            Write-Log "Scaling operation failed: $($_.Exception.Message)" -Level "Error"
            
            # Output the result but throw an exception to indicate failure
            $failureOutput = $failureResult | ConvertTo-Json -Depth 5
            Write-Output $failureOutput
            throw "Scaling failed. Current capacity state: $($updatedCapacity.properties.state), SKU: $($updatedCapacity.sku.name). This may indicate a quota limitation."
        }
    }
    else {
        $finalStatus = "Scaling"
        $finalSku = "Scaling to $TargetSku"
    }
    
    # Get the updated capacity details
    $capacity = Get-CapacityStatus -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -CapacityName $capacityName
    
    # Perform a final check to make sure we're not reporting success when actually failed
    if ($capacity.sku.name -ne $TargetSku -and $WaitForCompletion) {
        throw "Scaling operation did not result in the expected SKU change. Current SKU: $($capacity.sku.name), Target SKU: $TargetSku. This may indicate a quota limitation."
    }
    
    # Return the capacity details
    $result = @{
        CapacityName = $capacityName
        Status = $capacity.properties.state  # Use actual state instead of our assumed $finalStatus
        SubscriptionId = $subscriptionId
        ResourceGroup = $resourceGroupName
        Region = $capacity.location
        PreviousSKU = $currentSku
        CurrentSKU = $capacity.sku.name
        TargetSKU = $TargetSku
        LastUpdated = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        ScalingSuccessful = ($capacity.sku.name -eq $TargetSku)
    }
    
    return $result | ConvertTo-Json -Depth 5
}
catch {
    Write-Log "An error occurred: $_" -Level "Error"
    throw
} 
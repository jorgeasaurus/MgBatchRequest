<#
.SYNOPSIS
Efficiently retrieves all pages of data from Microsoft Graph API endpoints using batch requests.

.DESCRIPTION
This function provides an optimized way to retrieve large datasets from Microsoft Graph API by:
1. Making an initial request to get the first page of data
2. Extracting skip tokens from paginated responses
3. Batching subsequent requests (up to 20 per batch) to minimize API calls
4. Automatically handling different Azure cloud environments

This approach significantly reduces the time required to retrieve large datasets compared to 
sequential page-by-page requests.

.PARAMETER PageSize
The number of items to retrieve per page. Default is 999 (maximum allowed by Graph API).

.PARAMETER Endpoint
The Microsoft Graph API endpoint to query (without the base URL). 
Example: "users", "deviceManagement/managedDevices", "auditLogs/directoryAudits"

.PARAMETER Filter
Optional OData filter to apply to the query. Will be URL-encoded automatically.
Example: "userType eq 'Member'"

.PARAMETER UseParallelProcessing
When specified, batches will be processed in parallel using background jobs for improved performance.
This can significantly speed up retrieval of large datasets but uses more system resources.

.PARAMETER MaxConcurrentJobs
Number of concurrent background jobs for parallel processing (1-20). Default is 8.
Higher values may improve performance but increase resource usage and API load.

.PARAMETER MemoryThreshold
The threshold (in MB) at which to warn about potential memory impact. Default is 100MB.
Set to 0 to disable memory warnings.

.EXAMPLE
Invoke-mgBatchRequest -Endpoint "users"
Retrieves all users from the tenant.

.EXAMPLE
Invoke-mgBatchRequest -Endpoint "deviceManagement/managedDevices" -Filter "operatingSystem eq 'Windows'"
Retrieves all Windows managed devices.

.EXAMPLE
Invoke-mgBatchRequest -Endpoint "users" -PageSize 500
Retrieves all users with a custom page size.

.EXAMPLE
Invoke-mgBatchRequest -Endpoint "auditLogs/directoryAudits" -UseParallelProcessing
Retrieves all directory audits using parallel batch processing for improved performance.

.EXAMPLE
Invoke-mgBatchRequest -Endpoint "deviceManagement/managedDevices" -MemoryThreshold 200
Retrieves all managed devices with a custom memory warning threshold of 200MB.

.EXAMPLE
Invoke-mgBatchRequest -Endpoint "auditLogs/signIns" -UseParallelProcessing -MaxConcurrentJobs 15
Retrieves all sign-in logs using 15 concurrent jobs for maximum performance.

.EXAMPLE
$signIns = Invoke-mgBatchRequest -Endpoint "auditLogs/signIns" -UseParallelProcessing -MaxConcurrentJobs 15
$signIns | Export-Csv "signins.csv" -NoTypeInformation
Retrieves all sign-in logs using 15 concurrent jobs for maximum performance, then exports to CSV.

.NOTES
Requires an active Microsoft Graph connection (Connect-MgGraph).
Supports Global, USGov, USGovDoD, China, and Germany cloud environments.
#>

#region Helper Functions

function Get-GraphApiBaseUri {
    <#
    .SYNOPSIS
    Determines the appropriate Microsoft Graph API base URI based on the current connection environment.
    
    .DESCRIPTION
    This function examines the current Microsoft Graph context and returns the appropriate
    base URI for the connected cloud environment (Global, USGov, China, Germany, etc.).
    
    .OUTPUTS
    String - The base URI for the Microsoft Graph API
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    
    $mgContext = Get-MgContext
    if (-not $mgContext) {
        throw "No Microsoft Graph connection found. Please connect using Connect-MgGraph."
    }
    
    switch ($mgContext.Environment) {
        "Global" {
            Write-Verbose "Using Global environment."
            return "https://graph.microsoft.com/beta"
        }
        "USGov" {
            Write-Verbose "Using USGov environment."
            return "https://graph.microsoft.us/beta"
        }
        "USGovDoD" {
            Write-Verbose "Using USGovDoD environment."
            return "https://graph.microsoft.us/beta"
        }
        "China" {
            Write-Verbose "Using AzureChinaCloud environment."
            return "https://graph.chinacloudapi.cn/beta"
        }
        "Germany" {
            Write-Verbose "Using AzureGermanyCloud environment."
            return "https://graph.microsoft.de/beta"
        }
        default {
            Write-Verbose "Using custom environment: $($mgContext.Environment)"
            return "https://graph.microsoft.com/beta"  # Default fallback
        }
    }
}

function Get-SkipTokens {
    <#
    .SYNOPSIS
    Extracts skip tokens from Microsoft Graph API response objects.
    
    .DESCRIPTION
    This function parses the @odata.nextLink property from Graph API responses
    to extract skip tokens used for pagination.
    
    .PARAMETER Response
    The response object from a Microsoft Graph API call
    
    .OUTPUTS
    String[] - Array of skip tokens found in the response
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Response
    )
    
    $tokens = @()
    if ($Response.'@odata.nextLink' -match 'skiptoken=([^&]+)') {
        $tokens += $matches[1]
    }
    return $tokens
}

function New-BatchRequest {
    <#
    .SYNOPSIS
    Creates individual batch request objects for Microsoft Graph API batch operations.
    
    .DESCRIPTION
    This function constructs properly formatted batch request objects that can be
    submitted as part of a Graph API batch operation.
    
    .PARAMETER Endpoint
    The Graph API endpoint path
    
    .PARAMETER PageSize
    The number of items to retrieve per page
    
    .PARAMETER SkipTokens
    Array of skip tokens for pagination
    
    .PARAMETER Filter
    Optional URL-encoded OData filter
    
    .OUTPUTS
    PSCustomObject[] - Array of batch request objects
    #>
    [CmdletBinding()]
    [OutputType([psobject[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Endpoint,
        
        [Parameter(Mandatory = $true)]
        [int]$PageSize,
        
        [Parameter(Mandatory = $true)]
        [string[]]$SkipTokens,
        
        [string]$Filter
    )
    
    $batchRequests = @()
    
    for ($i = 0; $i -lt $SkipTokens.Count; $i++) {
        $token = $SkipTokens[$i]
        
        # Construct URL with proper parameter ordering
        if ($Filter -and $Filter -ne "" -and $Filter -ne $null) {
            $batchUrl = "/$Endpoint?`$top=$PageSize&`$filter=$Filter&`$skiptoken=$token"
        } else {
            $batchUrl = "/$Endpoint?`$top=$PageSize&`$skiptoken=$token"
        }
        
        $batchRequests += @{
            id     = ($i + 1).ToString()
            method = "GET"
            url    = $batchUrl
        }
    }
    
    return $batchRequests
}

function Test-MemoryThreshold {
    <#
    .SYNOPSIS
    Monitors memory usage and provides warnings when thresholds are exceeded.
    
    .DESCRIPTION
    This function estimates memory usage based on object count and warns
    when the specified threshold is exceeded.
    
    .PARAMETER ObjectCount
    The current total number of objects retrieved
    
    .PARAMETER ThresholdMB
    The memory threshold in MB (0 to disable warnings)
    
    .OUTPUTS
    Boolean - Returns $true if threshold was exceeded and warning was shown
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [int]$ObjectCount,
        
        [Parameter(Mandatory = $true)]
        [int]$ThresholdMB
    )
    
    if ($ThresholdMB -le 0) {
        return $false
    }
    
    $estimatedMemoryMB = ($ObjectCount * 2048) / 1MB  # Rough estimate: 2KB per object
    if ($estimatedMemoryMB -gt $ThresholdMB) {
        Write-Warning "Memory usage estimated at $([math]::Round($estimatedMemoryMB, 1))MB (threshold: $ThresholdMB MB). Consider processing in smaller batches."
        return $true
    }
    
    return $false
}

function Invoke-BatchRequestSequential {
    <#
    .SYNOPSIS
    Processes Microsoft Graph API batch requests sequentially.
    
    .DESCRIPTION
    This function processes batch requests one at a time in sequential order.
    This is the more conservative approach that uses fewer system resources.
    
    .PARAMETER SkipTokens
    Array of skip tokens to process
    
    .PARAMETER Endpoint
    The Graph API endpoint path
    
    .PARAMETER PageSize
    The number of items to retrieve per page
    
    .PARAMETER Filter
    Optional URL-encoded OData filter
    
    .PARAMETER BaseUri
    The base URI for the Graph API
    
    .PARAMETER MemoryThreshold
    Memory warning threshold in MB
    
    .OUTPUTS
    PSCustomObject - Object containing AllObjects, TotalCount, and RemainingTokens
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$SkipTokens,
        
        [Parameter(Mandatory = $true)]
        [string]$Endpoint,
        
        [Parameter(Mandatory = $true)]
        [int]$PageSize,
        
        [string]$Filter,
        
        [Parameter(Mandatory = $true)]
        [string]$BaseUri,
        
        [Parameter(Mandatory = $true)]
        [ref]$MemoryThreshold
    )
    
    $allObjects = @()
    $totalCount = 0
    $remainingTokens = [System.Collections.Generic.List[string]]::new($SkipTokens)
    
    while ($remainingTokens.Count -gt 0) {
        # Calculate batch size (max 20 due to Graph API limits)
        $batchCount = [Math]::Min(20, $remainingTokens.Count)
        $currentBatch = $remainingTokens[0..($batchCount - 1)]
        
        # Build batch requests
        $batchRequests = New-BatchRequest -Endpoint $Endpoint -PageSize $PageSize -SkipTokens $currentBatch -Filter $Filter
        
        # Remove processed tokens
        $remainingTokens.RemoveRange(0, $batchCount)
        
        # Submit batch request
        Write-Verbose "Submitting batch of $batchCount requests..."
        $body = @{ requests = $batchRequests }
        $response = Invoke-MgGraphRequest -Method POST `
            -Uri "$BaseUri/`$batch" `
            -Body ($body | ConvertTo-Json -Depth 5) `
            -ContentType "application/json"
        
        # Process responses
        foreach ($resp in $response.responses) {
            if ($resp.status -eq 200) {
                $allObjects += $resp.body.value
                $totalCount += $resp.body.value.Count
                
                # Check memory threshold
                if (Test-MemoryThreshold -ObjectCount $totalCount -ThresholdMB $MemoryThreshold.Value) {
                    $MemoryThreshold.Value = 0  # Disable further warnings
                }
                
                # Extract additional skip tokens
                $newTokens = Get-SkipTokens -Response $resp.body
                $remainingTokens.AddRange($newTokens)
            } else {
                Write-Warning "Request $($resp.id) returned HTTP $($resp.status)"
            }
        }
    }
    
    return [PSCustomObject]@{
        AllObjects = $allObjects
        TotalCount = $totalCount
    }
}

function Invoke-BatchRequestParallel {
    <#
    .SYNOPSIS
    Processes Microsoft Graph API batch requests in parallel using background jobs.
    
    .DESCRIPTION
    This function processes batch requests concurrently using PowerShell background jobs
    for improved performance on large datasets.
    
    .PARAMETER SkipTokens
    Array of skip tokens to process
    
    .PARAMETER Endpoint
    The Graph API endpoint path
    
    .PARAMETER PageSize
    The number of items to retrieve per page
    
    .PARAMETER Filter
    Optional URL-encoded OData filter
    
    .PARAMETER BaseUri
    The base URI for the Graph API
    
    .PARAMETER MaxConcurrentJobs
    Maximum number of concurrent background jobs
    
    .PARAMETER MemoryThreshold
    Memory warning threshold in MB
    
    .OUTPUTS
    PSCustomObject - Object containing AllObjects, TotalCount, and RemainingTokens
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$SkipTokens,
        
        [Parameter(Mandatory = $true)]
        [string]$Endpoint,
        
        [Parameter(Mandatory = $true)]
        [int]$PageSize,
        
        [string]$Filter,
        
        [Parameter(Mandatory = $true)]
        [string]$BaseUri,
        
        [Parameter(Mandatory = $true)]
        [int]$MaxConcurrentJobs,
        
        [Parameter(Mandatory = $true)]
        [ref]$MemoryThreshold
    )
    
    $allObjects = @()
    $totalCount = 0
    $remainingTokens = [System.Collections.Generic.List[string]]::new($SkipTokens)
    
    Write-Verbose "Using parallel processing for batch requests..."
    
    while ($remainingTokens.Count -gt 0) {
        $jobs = @()
        
        # Create job groups
        for ($jobIndex = 0; $jobIndex -lt $MaxConcurrentJobs -and $remainingTokens.Count -gt 0; $jobIndex++) {
            $batchCount = [Math]::Min(20, $remainingTokens.Count)
            $currentBatch = $remainingTokens[0..($batchCount - 1)]
            
            # Remove processed tokens
            $remainingTokens.RemoveRange(0, $batchCount)
            
            # Create background job for this batch
            $job = Start-ThreadJob -ScriptBlock {
                param($tokens, $endpoint, $pageSize, $escapedFilter, $uri)
                
                # Build batch requests
                $batchRequests = @()
                for ($i = 0; $i -lt $tokens.Count; $i++) {
                    $token = $tokens[$i]
                    # Construct URL with proper parameter ordering
                    if ($escapedFilter -and $escapedFilter -ne "" -and $escapedFilter -ne $null) {
                        $batchUrl = "/$endpoint?`$top=$pageSize&`$filter=$escapedFilter&`$skiptoken=$token"
                    } else {
                        $batchUrl = "/$endpoint?`$top=$pageSize&`$skiptoken=$token"
                    }
                    $batchRequests += @{
                        id     = ($i + 1).ToString()
                        method = "GET"
                        url    = $batchUrl
                    }
                }
                
                # Submit batch request
                $body = @{ requests = $batchRequests }
                $invokeParams = @{
                    Method      = 'POST'
                    Uri         = "$uri/`$batch"
                    Body        = ($body | ConvertTo-Json -Depth 5)
                    ContentType = 'application/json'
                }
                $response = Invoke-MgGraphRequest @invokeParams
                
                return $response
            } -ArgumentList $currentBatch, $Endpoint, $PageSize, $Filter, $BaseUri
            
            $jobs += $job
        }
        
        # Wait for all jobs to complete and process results
        Write-Verbose "Waiting for $($jobs.Count) parallel batch jobs to complete..."
        $results = $jobs | Receive-Job -Wait
        $jobs | Remove-Job
        
        # Process results from parallel jobs
        foreach ($response in $results) {
            foreach ($resp in $response.responses) {
                if ($resp.status -eq 200) {
                    $allObjects += $resp.body.value
                    $totalCount += $resp.body.value.Count
                    
                    # Check memory threshold
                    if (Test-MemoryThreshold -ObjectCount $totalCount -ThresholdMB $MemoryThreshold.Value) {
                        $MemoryThreshold.Value = 0  # Disable further warnings
                    }
                    
                    # Extract additional skip tokens
                    $newTokens = Get-SkipTokens -Response $resp.body
                    $remainingTokens.AddRange($newTokens)
                } else {
                    Write-Warning "Request $($resp.id) returned HTTP $($resp.status)"
                }
            }
        }
    }
    
    return [PSCustomObject]@{
        AllObjects = $allObjects
        TotalCount = $totalCount
    }
}

#endregion
function Invoke-mgBatchRequest {
    [CmdletBinding()]
    param(
        # The page size for the initial request (default: 999)
        [int]$PageSize = 999,
        # The Graph endpoint to query (mandatory)
        [string]
        [Parameter(Mandatory = $true)]
        $Endpoint,
        # The filter to apply to the query
        [string]
        $Filter,
        # Enable parallel processing of batches for improved performance
        [switch]
        $UseParallelProcessing,
        # Number of concurrent jobs for parallel processing (default: 8, max: 20)
        [ValidateRange(1, 20)]
        [int]
        $MaxConcurrentJobs = 8,
        # Memory threshold in MB for warnings (default: 100MB, set to 0 to disable)
        [int]
        $MemoryThreshold = 100
    )

    # Sanitize the endpoint by removing leading slash if present
    $Endpoint = $Endpoint.TrimStart('/')
    
    # Get the base URI for the current Graph environment
    try {
        $uri = Get-GraphApiBaseUri
    } catch {
        Write-Error $_.Exception.Message
        return
    }

    # Make the initial request to get the first page of data
    Write-Verbose "Retrieving first page for endpoint '$Endpoint'..."
    $firstUri = "$uri/$($Endpoint)?`$top=$PageSize"
    
    # Initialize escaped filter to ensure it's always defined for thread jobs
    $escapedFilter = if ($Filter) {
        Write-Verbose "Applying filter: '$Filter'..."
        # URL-encode the filter to handle special characters
        $encodedFilter = [uri]::EscapeDataString($Filter)
        $firstUri += "&`$filter=$encodedFilter"
        $encodedFilter
    } else {
        $null
    }
    
    $first = Invoke-MgGraphRequest -Method GET -Uri $firstUri

    # Store all objects in memory for batch return
    $allGraphObjects = @($first.value)
    
    # Track object count for memory warnings
    $totalObjectCount = $first.value.Count
    
    # Extract initial skip tokens
    $skipTokens = Get-SkipTokens -Response $first

    # Process remaining pages using batched requests for optimal performance
    if ($skipTokens.Count -gt 0) {
        # Create a reference for memory threshold to allow modification by helper functions
        $memoryThresholdRef = [ref]$MemoryThreshold
        
        if ($UseParallelProcessing) {
            # Use parallel processing for improved performance
            $parallelParams = @{
                SkipTokens        = $skipTokens
                Endpoint          = $Endpoint
                PageSize          = $PageSize
                Filter            = $escapedFilter
                BaseUri           = $uri
                MaxConcurrentJobs = $MaxConcurrentJobs
                MemoryThreshold   = $memoryThresholdRef
            }
            $result = Invoke-BatchRequestParallel @parallelParams
        } else {
            # Use sequential processing (original behavior)
            $sequentialParams = @{
                SkipTokens      = $skipTokens
                Endpoint        = $Endpoint
                PageSize        = $PageSize
                Filter          = $escapedFilter
                BaseUri         = $uri
                MemoryThreshold = $memoryThresholdRef
            }
            $result = Invoke-BatchRequestSequential @sequentialParams
        }
        
        # Add the additional objects to our collection
        $allGraphObjects += $result.AllObjects
        $totalObjectCount += $result.TotalCount
    }
    
    # Return the complete collection of objects
    Write-Verbose "Retrieved $totalObjectCount total objects from endpoint '$Endpoint'"
    return $allGraphObjects
}
<#
Performance comparison examples - uncomment to test execution times:
Write-Host "Performance comparison examples (uncomment to test execution times):"

Write-Host "Get-MgBetaDeviceManagementDetectedApp"
(Measure-Command { Get-MgBetaDeviceManagementDetectedApp }).TotalMilliseconds
Write-Host "Invoke-mgBatchRequest -Endpoint 'deviceManagement/detectedApps'"
(Measure-Command { Invoke-mgBatchRequest -Endpoint "/deviceManagement/detectedApps" }).TotalMilliseconds    
Write-Host "Invoke-mgBatchRequest -Endpoint 'deviceManagement/detectedApps' -UseParallelProcessing -MaxConcurrentJobs 15"
(Measure-Command { Invoke-mgBatchRequest -Endpoint "/deviceManagement/detectedApps" -UseParallelProcessing -MaxConcurrentJobs 15 }).TotalMilliseconds

Write-Host "Get-MgBetaDeviceManagementManagedDevice"
(Measure-Command { Get-MgBetaDeviceManagementManagedDevice }).TotalMilliseconds
Write-Host "Invoke-mgBatchRequest -Endpoint 'deviceManagement/managedDevices'"
(Measure-Command { Invoke-mgBatchRequest -Endpoint "/deviceManagement/managedDevices" }).TotalMilliseconds

Write-Host "Get-MgBetaAuditLogDirectoryAudit -All"
(Measure-Command { Get-MgBetaAuditLogDirectoryAudit -All }).TotalMilliseconds
Write-Host "Invoke-mgBatchRequest -Endpoint 'auditLogs/directoryAudits'"
(Measure-Command { Invoke-mgBatchRequest -Endpoint "/auditLogs/directoryAudits" }).TotalMilliseconds
Write-Host "Invoke-mgBatchRequest -Endpoint 'auditLogs/directoryAudits' -UseParallelProcessing"
(Measure-Command { Invoke-mgBatchRequest -Endpoint "/auditLogs/directoryAudits" -UseParallelProcessing -MaxConcurrentJobs 15 }).TotalMilliseconds


Write-Host "Get-MgBetaAuditLogSignIn -All"
(Measure-Command { Get-MgBetaAuditLogSignIn -All }).TotalMilliseconds
Write-Host "Invoke-mgBatchRequest -Endpoint 'auditLogs/signIns'"
(Measure-Command { Invoke-mgBatchRequest -Endpoint "/auditLogs/signIns" }).TotalMilliseconds
Write-Host "Invoke-mgBatchRequest -Endpoint 'auditLogs/signIns' -UseParallelProcessing"
(Measure-Command { Invoke-mgBatchRequest -Endpoint "/auditLogs/signIns" -UseParallelProcessing }).TotalMilliseconds
Write-Host "Invoke-mgBatchRequest -Endpoint 'auditLogs/signIns' -UseParallelProcessing -MaxConcurrentJobs 15"
  Measure-Command {
      Invoke-mgBatchRequest -Endpoint 'auditLogs/signIns' -UseParallelProcessing -MaxConcurrentJobs 15
  }

#>

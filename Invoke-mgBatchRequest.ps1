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

.PARAMETER AsStream
Output objects as they are retrieved instead of collecting all in memory first.
Significantly reduces memory usage for large datasets and enables real-time processing.

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

    # Debug: Function entry
    Write-Debug "=== Invoke-mgBatchRequest DEBUG START ==="
    Write-Debug "Input Parameters:"
    Write-Debug "  Endpoint: '$Endpoint'"
    Write-Debug "  PageSize: $PageSize"
    Write-Debug "  Filter: '$Filter'"
    Write-Debug "  UseParallelProcessing: $UseParallelProcessing"
    Write-Debug "  MaxConcurrentJobs: $MaxConcurrentJobs"
    Write-Debug "  MemoryThreshold: $MemoryThreshold"

    # Sanitize the endpoint by removing leading slash if present
    $Endpoint = $Endpoint.TrimStart('/')
    Write-Debug "Sanitized Endpoint: '$Endpoint'"

    # Verify Microsoft Graph connection exists
    Write-Debug "Checking Microsoft Graph connection..."
    if (-not ($mgContext = Get-MgContext)) {
        Write-Error "No Microsoft Graph connection found. Please connect using Connect-MgGraph."
        return
    }
    Write-Debug "Microsoft Graph connection found: Environment = $($mgContext.Environment)"
    # Determine the appropriate Graph API base URI based on the connected environment
    Write-Debug "Determining Graph API base URI for environment: $($mgContext.Environment)"
    switch ($mgContext.Environment) {
        "Global" {
            Write-Verbose "Using Global environment."
            $uri = "https://graph.microsoft.com/beta"
        }
        "USGov" {
            Write-Verbose "Using USGov environment."
            $uri = "https://graph.microsoft.us/beta"
        }
        "USGovDoD" {
            Write-Verbose "Using USGovDoD environment."
            $uri = "https://graph.microsoft.us/beta"
        }
        "China" {
            Write-Verbose "Using AzureChinaCloud environment."
            $uri = "https://graph.chinacloudapi.cn/beta"
        }
        "Germany" {
            Write-Verbose "Using AzureGermanyCloud environment."
            $uri = "https://graph.microsoft.de/beta"
        }
        default {
            Write-Verbose "Using custom environment: $($mgContext.Environment)"
            $uri = "https://graph.microsoft.com/beta"  # Default fallback
        }
    }
    Write-Debug "Selected base URI: $uri"

    # Make the initial request to get the first page of data
    Write-Verbose "Retrieving first page for endpoint '$Endpoint'..."
    Write-Debug "Building initial request URI..."
    $firstUri = "$uri/$($Endpoint)?`$top=$PageSize"
    Write-Debug "Base first URI: $firstUri"
    
    # Apply filter if provided
    if ($Filter) {
        Write-Verbose "Applying filter: '$Filter'..."
        Write-Debug "URL-encoding filter..."
        # URL-encode the filter to handle special characters
        $encodedFilter = [uri]::EscapeDataString($Filter)
        $firstUri += "&`$filter=$encodedFilter"
        Write-Debug "Applied filter: $encodedFilter"
    } else {
        Write-Debug "No filter provided"
    }
    Write-Debug "Final first URI: $firstUri"
    
    Write-Debug "Making initial Graph API request..."
    $first = Invoke-MgGraphRequest -Method GET -Uri $firstUri
    Write-Debug "Initial request completed. Items received: $($first.value.Count)"

    # Store all objects in memory for batch return
    $allGraphObjects = @($first.value)
    Write-Debug "Stored $($allGraphObjects.Count) objects from initial request"
    
    # Track object count for memory warnings
    $totalObjectCount = $first.value.Count
    Write-Debug "Total object count initialized: $totalObjectCount"
    
    # Initialize an array to store complete nextLink URLs for subsequent batch requests
    $nextLinks = @()
    Write-Debug "Checking for pagination tokens..."
    if ($first.'@odata.nextLink') {
        Write-Debug "NextLink found: $($first.'@odata.nextLink')"
        # Store the complete nextLink URL instead of extracting skip tokens
        $nextLinks += $first.'@odata.nextLink'
        Write-Debug "Stored complete nextLink URL"
    } else {
        Write-Debug "No NextLink found - single page result"
    }
    Write-Debug "NextLinks array initialized with $($nextLinks.Count) URLs"

    # Process remaining pages using batched requests for optimal performance
    if ($UseParallelProcessing) {
        # Parallel processing mode using background jobs
        Write-Verbose "Using parallel processing for batch requests..."
        Write-Debug "=== PARALLEL PROCESSING MODE ==="
        Write-Debug "MaxConcurrentJobs: $MaxConcurrentJobs"
        $jobs = @()
        $batchRound = 1
        
        while ($nextLinks.Count -gt 0) {
            Write-Debug "--- Batch Round $batchRound ---"
            Write-Debug "Remaining nextLinks: $($nextLinks.Count)"
            # Use configurable number of concurrent jobs for optimal performance
            $maxJobs = $MaxConcurrentJobs
            
            # Create job groups (each job will process one batch of up to 20 requests)
            for ($jobIndex = 0; $jobIndex -lt $maxJobs -and $nextLinks.Count -gt 0; $jobIndex++) {
                $batchCount = [Math]::Min(20, $nextLinks.Count)
                $currentBatch = $nextLinks[0..($batchCount - 1)]
                Write-Debug "Job $($jobIndex + 1): Processing $batchCount nextLinks"
                Write-Debug "Current batch URLs: $($currentBatch -join '; ')"
                
                # Remove processed nextLinks
                if ($nextLinks.Count -gt $batchCount) {
                    $nextLinks = $nextLinks[$batchCount..($nextLinks.Count - 1)]
                    Write-Debug "NextLinks remaining after removal: $($nextLinks.Count)"
                } else {
                    $nextLinks = @()
                    Write-Debug "All nextLinks consumed"
                }
                
                # Create background job for this batch
                $job = Start-ThreadJob -ScriptBlock {
                    param($nextLinkUrls, $uri)
                    
                    # Build batch requests using complete nextLink URLs
                    $batchRequests = @()
                    for ($i = 0; $i -lt $nextLinkUrls.Count; $i++) {
                        $nextLinkUrl = $nextLinkUrls[$i]
                        # Extract the relative path from the complete nextLink URL
                        $parsedUri = [System.Uri]$nextLinkUrl
                        # Remove the API version prefix for batch requests (e.g., /beta/, /v1.0/)
                        $relativePath = $parsedUri.PathAndQuery -replace '^/(beta|v1\.0)/', '/'
                        
                        $batchRequests += @{
                            id     = ($i + 1).ToString()
                            method = "GET"
                            url    = $relativePath
                        }
                    }
                    
                    # Submit batch request
                    $body = @{ requests = $batchRequests }
                    $response = Invoke-MgGraphRequest -Method POST `
                        -Uri "$uri/`$batch" `
                        -Body ($body | ConvertTo-Json -Depth 5) `
                        -ContentType "application/json"
                    
                    return $response
                } -ArgumentList $currentBatch, $uri
                
                $jobs += $job
            }
            
            # Wait for all jobs in this group to complete and process results
            Write-Verbose "Waiting for $($jobs.Count) parallel batch jobs to complete..."
            Write-Debug "Starting job completion wait for $($jobs.Count) jobs..."
            $results = $jobs | Receive-Job -Wait
            Write-Debug "All jobs completed, removing job objects..."
            $jobs | Remove-Job
            $jobs = @()
            Write-Debug "Processing $($results.Count) job results..."
            
            # Process results from parallel jobs
            $responseCount = 0
            foreach ($response in $results) {
                $responseCount++
                Write-Debug "Processing job result $responseCount of $($results.Count)"
                foreach ($resp in $response.responses) {
                    Write-Debug "Processing batch response ID $($resp.id) with status $($resp.status)"
                    if ($resp.status -eq 200) {
                        # Collect objects in memory for batch return
                        $allGraphObjects += $resp.body.value
                        $totalObjectCount += $resp.body.value.Count
                        Write-Debug "Added $($resp.body.value.Count) objects. Total now: $totalObjectCount"
                        
                        # Check memory usage and warn if threshold exceeded
                        if ($MemoryThreshold -gt 0) {
                            $estimatedMemoryMB = ($totalObjectCount * 2048) / 1MB  # Rough estimate: 2KB per object
                            if ($estimatedMemoryMB -gt $MemoryThreshold) {
                                Write-Warning "Memory usage estimated at $([math]::Round($estimatedMemoryMB, 1))MB (threshold: $MemoryThreshold MB). Consider processing in smaller batches."
                                $MemoryThreshold = 0  # Disable further warnings
                                Write-Debug "Memory threshold exceeded, warnings disabled"
                            }
                        }
                        
                        if ($resp.body.'@odata.nextLink') {
                            Write-Debug "Found nextLink: $($resp.body.'@odata.nextLink')"
                            $nextLinks += $resp.body.'@odata.nextLink'
                            Write-Debug "Added new nextLink to queue"
                        } else {
                            Write-Debug "No nextLink in response"
                        }
                    } else {
                        Write-Warning "Request $($resp.id) returned HTTP $($resp.status)"
                        Write-Debug "Error response details: $($resp | ConvertTo-Json -Depth 3)"
                    }
                }
            }
            $batchRound++
            Write-Debug "Batch round $($batchRound - 1) completed. New nextLinks count: $($nextLinks.Count)"
        }
    } else {
        # Sequential processing mode (original behavior)
        Write-Debug "=== SEQUENTIAL PROCESSING MODE ==="
        $batchRound = 1
        while ($nextLinks.Count -gt 0) {
            Write-Debug "--- Sequential Batch Round $batchRound ---"
            Write-Debug "NextLinks remaining: $($nextLinks.Count)"
            # Create a new batch of requests (Graph API supports max 20 requests per batch)
            $batchRequests = @()
            # Calculate the number of requests for this batch (max 20 due to Graph API limits)
            $batchCount = [Math]::Min(20, $nextLinks.Count)
            Write-Debug "Processing batch of $batchCount requests"

            # Build individual requests for each nextLink in the current batch
            for ($i = 0; $i -lt $batchCount; $i++) {
                $nextLinkUrl = $nextLinks[$i]
                Write-Debug "Building request $($i + 1) for nextLink: $nextLinkUrl"
                # Extract the relative path from the complete nextLink URL
                $parsedUri = [System.Uri]$nextLinkUrl
                # Remove the API version prefix for batch requests (e.g., /beta/, /v1.0/)
                $relativePath = $parsedUri.PathAndQuery -replace '^/(beta|v1\.0)/', '/'
                Write-Debug "Request $($i + 1) relative path: $relativePath"
                # Add the individual request to the batch collection
                $batchRequests += @{
                    id     = ($i + 1).ToString()  # Unique identifier for this request within the batch
                    method = "GET"
                    url    = $relativePath
                }
            }
            Write-Debug "Built $($batchRequests.Count) batch requests"

            # Remove the nextLinks that were just added to the batch from the queue
            if ($nextLinks.Count -gt $batchCount) {
                $nextLinks = $nextLinks[$batchCount..($nextLinks.Count - 1)]
                Write-Debug "NextLinks remaining after removal: $($nextLinks.Count)"
            } else {
                $nextLinks = @()
                Write-Debug "All nextLinks consumed"
            }

            # Submit the batch of requests to the Graph API
            Write-Verbose "Submitting batch of $batchCount requests..."
            Write-Debug "Preparing batch request body..."
            $body = @{ requests = $batchRequests }
            Write-Debug "Batch request body: $($body | ConvertTo-Json -Depth 2 -Compress)"
            Write-Debug "Submitting POST to: $uri/`$batch"
            $response = Invoke-MgGraphRequest -Method POST `
                -Uri "$uri/`$batch" `
                -Body ($body | ConvertTo-Json -Depth 5) `
                -ContentType "application/json"
            Write-Debug "Batch request completed. Processing $($response.responses.Count) responses..."

            # Process each response from the batch
            foreach ($resp in $response.responses) {
                Write-Debug "Processing response ID $($resp.id) with status $($resp.status)"
                if ($resp.status -eq 200) {
                    # Add the successfully retrieved objects to our collection
                    $allGraphObjects += $resp.body.value
                    $totalObjectCount += $resp.body.value.Count
                    Write-Debug "Added $($resp.body.value.Count) objects. Total now: $totalObjectCount"
                    
                    # Check memory usage and warn if threshold exceeded
                    if ($MemoryThreshold -gt 0) {
                        $estimatedMemoryMB = ($totalObjectCount * 2048) / 1MB  # Rough estimate: 2KB per object
                        if ($estimatedMemoryMB -gt $MemoryThreshold) {
                            Write-Warning "Memory usage estimated at $([math]::Round($estimatedMemoryMB, 1))MB (threshold: $MemoryThreshold MB). Consider processing in smaller batches."
                            $MemoryThreshold = 0  # Disable further warnings
                            Write-Debug "Memory threshold exceeded, warnings disabled"
                        }
                    }
                    
                    # Check if this response contains a nextLink for future batching
                    if ($resp.body.'@odata.nextLink') {
                        Write-Debug "Found nextLink: $($resp.body.'@odata.nextLink')"
                        $nextLinks += $resp.body.'@odata.nextLink'
                        Write-Debug "Added new nextLink to queue"
                    } else {
                        Write-Debug "No nextLink in response"
                    }
                } else {
                    # Log any failed requests for troubleshooting
                    Write-Warning "Request $($resp.id) returned HTTP $($resp.status)"
                    Write-Debug "Error response details: $($resp | ConvertTo-Json -Depth 3)"
                }
            }
            $batchRound++
            Write-Debug "Sequential batch round $($batchRound - 1) completed. New nextLinks count: $($nextLinks.Count)"
        }
    }
    
    # Return the complete collection of objects
    Write-Debug "=== FUNCTION COMPLETION ==="
    Write-Debug "Final total object count: $totalObjectCount"
    Write-Debug "Final collection size: $($allGraphObjects.Count)"
    Write-Debug "=== Invoke-mgBatchRequest DEBUG END ==="
    return $allGraphObjects
}
<#

applicationTemplates
(Measure-Command { Invoke-mgBatchRequest -Endpoint "/applicationTemplates" }).TotalMilliseconds  
(Measure-Command { Invoke-mgBatchRequest -Endpoint "/admin/windows/updates/catalog/entries" }).TotalMilliseconds
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

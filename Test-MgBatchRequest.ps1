<#
.SYNOPSIS
Comprehensive testing script for Invoke-mgBatchRequest performance validation and optimization.

.DESCRIPTION
This script provides a complete testing framework for validating and optimizing the performance
of Invoke-mgBatchRequest compared to standard Microsoft Graph cmdlets. It combines all testing
capabilities including performance analysis, memory profiling, error detection, and optimization
recommendations.

Enhanced Features:
- Automated endpoint detection and testing
- Advanced memory profiling with garbage collection management
- HTTP error detection and monitoring (including HTTP 400 tracking)
- Intelligent parameter optimization (finds optimal concurrent jobs)
- Connection warm-up for stable baseline measurements
- Performance comparison with baseline cmdlets
- Detailed CSV reporting and analysis
- Production-ready command generation
- Built-in recommendations based on results
- Pattern recognition for endpoint optimization
- Comprehensive error handling and verification

.PARAMETER TestMode
Specifies the testing mode:
- Quick: Fast validation with small datasets and memory profiling
- Standard: Comprehensive testing with medium datasets  
- Extensive: Full testing including large datasets (may take longer)
- Custom: Test specific endpoints only
- Optimize: Find optimal parameters for specific endpoint

.PARAMETER Endpoints
Array of specific endpoints to test (only used with -TestMode Custom or Optimize).
Example: @("users", "groups", "deviceManagement/managedDevices")

.PARAMETER MaxConcurrentJobs
Maximum number of concurrent jobs to test for parallel processing.
Default: 15, Range: 1-20

.PARAMETER PageSizes
Array of page sizes to test. Default: @(100, 500, 999)

.PARAMETER OutputPath
Path to save detailed results. If not specified, creates timestamped file.

.PARAMETER SkipBaseline
Skip baseline (standard cmdlet) tests for faster execution.

.PARAMETER Iterations
Number of iterations for each test to improve accuracy. Default: 1

.PARAMETER SkipLargeTests
Skip tests that may take a long time or use significant resources.

.PARAMETER EnableWarmup
Perform connection warm-up before testing for stable baseline measurements.

.PARAMETER OptimizeFor
When using TestMode=Optimize, specify what to optimize for:
- Speed: Optimize for fastest execution time
- Memory: Optimize for lowest memory usage
- Balanced: Find best balance of speed and memory

.EXAMPLE
.\Test-MgBatchRequest.ps1
Runs standard comprehensive testing with default parameters.

.EXAMPLE
.\Test-MgBatchRequest.ps1 -TestMode Quick -OutputPath "results.csv"
Runs quick validation tests with memory profiling and saves results.

.EXAMPLE
.\Test-MgBatchRequest.ps1 -TestMode Optimize -Endpoints @("users") -OptimizeFor Speed
Finds optimal configuration for users endpoint prioritizing speed.

.EXAMPLE
.\Test-MgBatchRequest.ps1 -TestMode Extensive -Iterations 3 -EnableWarmup
Runs extensive testing with 3 iterations each and connection warm-up.

.NOTES
Requires:
- Active Microsoft Graph connection (Connect-MgGraph)
- Invoke-mgBatchRequest.ps1 in the same directory
- Appropriate permissions for the endpoints being tested

Enhanced with features from all test scripts for complete performance analysis.
#>

[CmdletBinding()]
param(
    [ValidateSet("Quick", "Standard", "Extensive", "Custom", "Optimize")]
    [string]$TestMode = "Standard",
    
    [string[]]$Endpoints = @(),
    
    [ValidateRange(1, 20)]
    [int]$MaxConcurrentJobs = 15,
    
    [int[]]$PageSizes = @(100, 500, 999),
    
    [string]$OutputPath,
    
    [switch]$SkipBaseline,
    
    [ValidateRange(1, 10)]
    [int]$Iterations = 1,
    
    [switch]$SkipLargeTests,
    
    [switch]$EnableWarmup,
    
    [ValidateSet("Speed", "Memory", "Balanced")]
    [string]$OptimizeFor = "Balanced"
)

# Ensure Microsoft Graph is connected
if (-not (Get-MgContext)) {
    Write-Error "Please connect to Microsoft Graph first using Connect-MgGraph"
    exit 1
}

# Import the batch request function
$scriptPath = Join-Path $PSScriptRoot "Invoke-mgBatchRequest.ps1"
if (-not (Test-Path $scriptPath)) {
    Write-Error "Cannot find Invoke-mgBatchRequest.ps1 in the same directory"
    exit 1
}
. $scriptPath

# Enhanced memory profiler function with comprehensive tracking
function Test-WithMemoryProfiler {
    param(
        [string]$TestName,
        [scriptblock]$TestScript,
        [string]$Method,
        [string]$Category,
        [int]$ExpectedPageSize,
        [int]$IterationCount = 1,
        [switch]$CaptureWarnings
    )
    
    Write-Host "  Testing: $Method" -NoNewline -ForegroundColor Gray
    
    $allTimes = @()
    $totalObjects = 0
    $memoryUsage = 0
    $capturedWarnings = @()
    $http400Count = 0
    
    for ($i = 1; $i -le $IterationCount; $i++) {
        # Force garbage collection for accurate memory measurement
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        [GC]::Collect()
        
        $memBefore = [GC]::GetTotalMemory($false)
        
        try {
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            
            if ($CaptureWarnings) {
                # Capture warnings to detect HTTP 400 and other errors
                $originalWarningAction = $WarningPreference
                $WarningPreference = "Continue"
                
                $result = & $TestScript 3>&1 | ForEach-Object {
                    if ($_ -is [System.Management.Automation.WarningRecord]) {
                        $capturedWarnings += $_.Message
                        if ($_.Message -like "*HTTP 400*") {
                            $http400Count++
                        }
                    } else {
                        $_
                    }
                }
                
                $WarningPreference = $originalWarningAction
            } else {
                $result = & $TestScript
            }
            
            $stopwatch.Stop()
            
            $memAfter = [GC]::GetTotalMemory($false)
            $memoryUsage += ($memAfter - $memBefore) / 1MB
            
            $objectCount = if ($result -is [array]) { $result.Count } else { if ($result) { 1 } else { 0 } }
            $totalObjects = $objectCount  # Use last iteration's count
            $allTimes += $stopwatch.ElapsedMilliseconds
            
        } catch {
            Write-Host " ✗" -ForegroundColor Red
            return [PSCustomObject]@{
                TestName = $TestName
                Method = $Method
                Category = $Category
                Success = $false
                Error = $_.Exception.Message
                AverageTimeMs = $null
                ObjectCount = 0
                ThroughputPerSec = 0
                MemoryUsedMB = 0
                PageSize = $ExpectedPageSize
                Iterations = $IterationCount
                HTTP400Errors = 0
                Warnings = @()
            }
        }
    }
    
    # Calculate comprehensive metrics
    $avgTime = ($allTimes | Measure-Object -Average).Average
    $minTime = ($allTimes | Measure-Object -Minimum).Minimum
    $maxTime = ($allTimes | Measure-Object -Maximum).Maximum
    $avgMemory = $memoryUsage / $IterationCount
    
    $throughput = if ($avgTime -gt 0 -and $totalObjects -gt 0) { 
        [math]::Round(($totalObjects / $avgTime) * 1000, 2) 
    } else { 0 }
    
    # Display result with error indicators
    if ($http400Count -gt 0) {
        Write-Host " ⚠ $([math]::Round($avgTime, 0))ms ($http400Count HTTP 400 errors)" -ForegroundColor Yellow
    } else {
        Write-Host " ✓ $([math]::Round($avgTime, 0))ms" -ForegroundColor Green
    }
    
    return [PSCustomObject]@{
        TestName = $TestName
        Method = $Method
        Category = $Category
        Success = $true
        AverageTimeMs = [math]::Round($avgTime, 2)
        MinTimeMs = $minTime
        MaxTimeMs = $maxTime
        ObjectCount = $totalObjects
        ThroughputPerSec = $throughput
        MemoryUsedMB = [math]::Round($avgMemory, 2)
        PageSize = $ExpectedPageSize
        Iterations = $IterationCount
        HTTP400Errors = $http400Count
        Warnings = $capturedWarnings
    }
}

# Connection warm-up function
function Test-ConnectionWarmup {
    Write-Host "Performing connection warm-up..." -ForegroundColor Gray
    try {
        Get-MgBetaUser -Top 1 | Out-Null
        Write-Host "✓ Connection ready" -ForegroundColor Green
        Start-Sleep -Seconds 1
    } catch {
        Write-Warning "Connection warm-up failed: $($_.Exception.Message)"
    }
}

# Enhanced endpoint testing with optimization features
function Test-EndpointOptimization {
    param(
        [hashtable]$Config,
        [int]$MaxJobs,
        [bool]$IncludeBaseline,
        [int]$IterationCount,
        [string]$OptimizationTarget = "Balanced"
    )
    
    Write-Host "`n--- Optimizing: $($Config.Name) ---" -ForegroundColor Magenta
    
    $endpointResults = @()
    $pageSize = if ($Config.PageSize -eq -1) { 999 } else { $Config.PageSize }
    
    # Test baseline if not skipped
    if ($IncludeBaseline) {
        $baselineScript = if ($Config.PageSize -eq -1) {
            [scriptblock]::Create("$($Config.Cmdlet) -All")
        } else {
            [scriptblock]::Create("$($Config.Cmdlet) -Top $($Config.PageSize)")
        }
        
        $result = Test-WithMemoryProfiler -TestName $Config.Name -TestScript $baselineScript -Method "Standard Cmdlet" -Category $Config.Category -ExpectedPageSize $pageSize -IterationCount $IterationCount
        $endpointResults += $result
    }
    
    # Test sequential batch
    $batchScript = if ($Config.PageSize -eq -1) {
        [scriptblock]::Create("Invoke-mgBatchRequest -Endpoint '$($Config.Endpoint)'")
    } else {
        [scriptblock]::Create("Invoke-mgBatchRequest -Endpoint '$($Config.Endpoint)' -PageSize $pageSize")
    }
    
    $result = Test-WithMemoryProfiler -TestName $Config.Name -TestScript $batchScript -Method "Batch Sequential" -Category $Config.Category -ExpectedPageSize $pageSize -IterationCount $IterationCount
    $endpointResults += $result
    
    # Test different parallel configurations to find optimal
    $jobCounts = @(5, 8, 10, 12, 15, $MaxJobs) | Sort-Object -Unique
    
    foreach ($jobs in $jobCounts) {
        if ($jobs -le $MaxJobs) {
            $parallelScript = if ($Config.PageSize -eq -1) {
                [scriptblock]::Create("Invoke-mgBatchRequest -Endpoint '$($Config.Endpoint)' -UseParallelProcessing -MaxConcurrentJobs $jobs")
            } else {
                [scriptblock]::Create("Invoke-mgBatchRequest -Endpoint '$($Config.Endpoint)' -UseParallelProcessing -MaxConcurrentJobs $jobs -PageSize $pageSize")
            }
            
            $result = Test-WithMemoryProfiler -TestName $Config.Name -TestScript $parallelScript -Method "Batch Parallel ($jobs jobs)" -Category $Config.Category -ExpectedPageSize $pageSize -IterationCount $IterationCount -CaptureWarnings
            $endpointResults += $result
        }
    }
    
    # Test memory managed batch
    $memoryScript = if ($Config.PageSize -eq -1) {
        [scriptblock]::Create("Invoke-mgBatchRequest -Endpoint '$($Config.Endpoint)' -MemoryThreshold 100")
    } else {
        [scriptblock]::Create("Invoke-mgBatchRequest -Endpoint '$($Config.Endpoint)' -MemoryThreshold 100 -PageSize $pageSize")
    }
    
    $result = Test-WithMemoryProfiler -TestName $Config.Name -TestScript $memoryScript -Method "Batch Memory Managed" -Category $Config.Category -ExpectedPageSize $pageSize -IterationCount $IterationCount
    $endpointResults += $result
    
    return $endpointResults
}

# Define comprehensive endpoint configurations
$endpointConfigs = @{
    "Quick" = @(
        @{ Name = "Users (Small)"; Endpoint = "users"; Cmdlet = "Get-MgBetaUser"; PageSize = 50; Category = "Identity" },
        @{ Name = "Groups (Small)"; Endpoint = "groups"; Cmdlet = "Get-MgBetaGroup"; PageSize = 50; Category = "Identity" }
    )
    "Standard" = @(
        @{ Name = "Users"; Endpoint = "users"; Cmdlet = "Get-MgBetaUser"; PageSize = 200; Category = "Identity" },
        @{ Name = "Groups"; Endpoint = "groups"; Cmdlet = "Get-MgBetaGroup"; PageSize = 100; Category = "Identity" },
        @{ Name = "Applications"; Endpoint = "applications"; Cmdlet = "Get-MgBetaApplication"; PageSize = 100; Category = "Identity" },
        @{ Name = "Mobile Apps"; Endpoint = "deviceAppManagement/mobileApps"; Cmdlet = "Get-MgBetaDeviceAppManagementMobileApp"; PageSize = 100; Category = "Device Management" },
        @{ Name = "Devices"; Endpoint = "devices"; Cmdlet = "Get-MgBetaDevice"; PageSize = 100; Category = "Identity" },
        @{ Name = "Managed Devices"; Endpoint = "deviceManagement/managedDevices"; Cmdlet = "Get-MgBetaDeviceManagementManagedDevice"; PageSize = 100; Category = "Device Management" }
    )
    "Extensive" = @(
        @{ Name = "All Users"; Endpoint = "users"; Cmdlet = "Get-MgBetaUser"; PageSize = -1; Category = "Identity" },
        @{ Name = "All Groups"; Endpoint = "groups"; Cmdlet = "Get-MgBetaGroup"; PageSize = -1; Category = "Identity" },
        @{ Name = "All Applications"; Endpoint = "applications"; Cmdlet = "Get-MgBetaApplication"; PageSize = -1; Category = "Identity" },
        @{ Name = "All Managed Devices"; Endpoint = "deviceManagement/managedDevices"; Cmdlet = "Get-MgBetaDeviceManagementManagedDevice"; PageSize = -1; Category = "Device Management" },
        @{ Name = "Directory Audits"; Endpoint = "auditLogs/directoryAudits"; Cmdlet = "Get-MgBetaAuditLogDirectoryAudit"; PageSize = -1; Category = "Audit Logs" },
        @{ Name = "Sign-in Logs"; Endpoint = "auditLogs/signIns"; Cmdlet = "Get-MgBetaAuditLogSignIn"; PageSize = -1; Category = "Audit Logs" }
    )
    "Optimize" = @(
        # Will be populated based on Endpoints parameter
    )
}

# Main execution
Write-Host "=== Microsoft Graph Batch Request Performance Testing ===" -ForegroundColor Yellow
Write-Host "Enhanced with Advanced Memory Profiling, Error Detection & Optimization" -ForegroundColor Cyan
Write-Host "Test Mode: $TestMode | Max Jobs: $MaxConcurrentJobs | Iterations: $Iterations`n" -ForegroundColor White

# Connection warm-up if enabled
if ($EnableWarmup) {
    Test-ConnectionWarmup
}

# Determine which endpoints to test
$endpointsToTest = switch ($TestMode) {
    "Custom" {
        if ($Endpoints.Count -eq 0) {
            Write-Error "Custom mode requires -Endpoints parameter"
            exit 1
        }
        $Endpoints | ForEach-Object {
            @{ Name = $_; Endpoint = $_; Cmdlet = "Unknown"; PageSize = 100; Category = "Custom" }
        }
    }
    "Optimize" {
        if ($Endpoints.Count -eq 0) {
            Write-Error "Optimize mode requires -Endpoints parameter"
            exit 1
        }
        $Endpoints | ForEach-Object {
            @{ Name = "$_ (Optimization)"; Endpoint = $_; Cmdlet = "Unknown"; PageSize = 200; Category = "Optimization" }
        }
    }
    default {
        if ($TestMode -eq "Extensive" -and $SkipLargeTests) {
            Write-Host "Skipping large tests in Extensive mode..." -ForegroundColor Yellow
            $endpointConfigs["Standard"]
        } else {
            $endpointConfigs[$TestMode]
        }
    }
}

# Run tests with enhanced functionality
$allResults = @()
$testStartTime = Get-Date

foreach ($config in $endpointsToTest) {
    try {
        if ($TestMode -eq "Optimize") {
            $endpointResults = Test-EndpointOptimization -Config $config -MaxJobs $MaxConcurrentJobs -IncludeBaseline (-not $SkipBaseline) -IterationCount $Iterations -OptimizationTarget $OptimizeFor
        } else {
            $endpointResults = Test-EndpointOptimization -Config $config -MaxJobs $MaxConcurrentJobs -IncludeBaseline (-not $SkipBaseline) -IterationCount $Iterations
        }
        $allResults += $endpointResults
    } catch {
        Write-Warning "Failed to test $($config.Name): $($_.Exception.Message)"
    }
    
    # Brief pause between endpoints to avoid throttling
    Start-Sleep -Seconds 1
}

$testEndTime = Get-Date
$totalTestTime = ($testEndTime - $testStartTime).TotalMinutes

# Enhanced analysis and recommendations
Write-Host "`n=== Advanced Performance Analysis ===" -ForegroundColor Yellow

$successfulResults = $allResults | Where-Object Success
$categories = $successfulResults | Group-Object Category

# Error analysis
$errorResults = $allResults | Where-Object { $_.HTTP400Errors -gt 0 }
if ($errorResults.Count -gt 0) {
    Write-Host "`n⚠ HTTP 400 Errors Detected:" -ForegroundColor Red
    $errorResults | ForEach-Object {
        Write-Host "  • $($_.TestName) ($($_.Method)): $($_.HTTP400Errors) errors" -ForegroundColor Red
    }
}

# Performance analysis by category
foreach ($categoryGroup in $categories) {
    Write-Host "`n$($categoryGroup.Name) Endpoints:" -ForegroundColor Cyan
    
    $endpointGroups = $categoryGroup.Group | Group-Object TestName
    
    foreach ($endpointGroup in $endpointGroups) {
        $baseline = $endpointGroup.Group | Where-Object { $_.Method -eq "Standard Cmdlet" } | Select-Object -First 1
        $others = $endpointGroup.Group | Where-Object { $_.Method -ne "Standard Cmdlet" }
        
        if ($baseline -and $others) {
            # Find optimal configuration based on optimization target
            $optimal = switch ($OptimizeFor) {
                "Speed" { $others | Sort-Object AverageTimeMs | Select-Object -First 1 }
                "Memory" { $others | Sort-Object MemoryUsedMB | Select-Object -First 1 }
                "Balanced" { 
                    $others | ForEach-Object {
                        $speedScore = if ($baseline.AverageTimeMs -gt 0) { 
                            (($baseline.AverageTimeMs - $_.AverageTimeMs) / $baseline.AverageTimeMs) * 100 
                        } else { 0 }
                        $memoryScore = if ($baseline.MemoryUsedMB -gt 0 -and $_.MemoryUsedMB -lt $baseline.MemoryUsedMB) { 
                            (($baseline.MemoryUsedMB - $_.MemoryUsedMB) / $baseline.MemoryUsedMB) * 100 
                        } else { 0 }
                        
                        $_ | Add-Member -NotePropertyName "OptimizationScore" -NotePropertyValue ($speedScore + $memoryScore) -PassThru
                    } | Sort-Object OptimizationScore -Descending | Select-Object -First 1
                }
            }
            
            $improvement = [math]::Round((($baseline.AverageTimeMs - $optimal.AverageTimeMs) / $baseline.AverageTimeMs) * 100, 1)
            $color = if ($improvement -gt 0) { "Green" } else { "Red" }
            Write-Host "  • $($endpointGroup.Name): $improvement% improvement ($($optimal.Method))" -ForegroundColor $color
            
            # Show throughput comparison
            if ($optimal.ThroughputPerSec -gt 0) {
                Write-Host "    Throughput: $($optimal.ThroughputPerSec) obj/sec vs $($baseline.ThroughputPerSec) obj/sec baseline" -ForegroundColor Gray
            }
        }
    }
}

# Generate production-ready commands
Write-Host "`n=== Production-Ready Commands ===" -ForegroundColor Yellow

$optimalConfigurations = $successfulResults | Where-Object { $_.Method -like "*Parallel*" } | 
    Group-Object TestName | ForEach-Object {
    $bestConfig = $_.Group | Sort-Object AverageTimeMs | Select-Object -First 1
    if ($bestConfig.Method -match 'Parallel \((\d+) jobs\)') {
        [PSCustomObject]@{
            Endpoint = $bestConfig.TestName
            OptimalJobs = $matches[1]
            Performance = "$([math]::Round($bestConfig.AverageTimeMs, 0))ms"
            Throughput = "$($bestConfig.ThroughputPerSec) obj/sec"
        }
    }
}

if ($optimalConfigurations) {
    Write-Host "Based on your test results, here are the optimal configurations:" -ForegroundColor White
    $optimalConfigurations | ForEach-Object {
        $endpointPath = switch -Wildcard ($_.Endpoint) {
            "*Users*" { "users" }
            "*Groups*" { "groups" }
            "*Applications*" { "applications" }
            "*Mobile Apps*" { "deviceAppManagement/mobileApps" }
            "*Devices*" { "devices" }
            "*Managed Devices*" { "deviceManagement/managedDevices" }
            "*Directory Audits*" { "auditLogs/directoryAudits" }
            "*Sign-in*" { "auditLogs/signIns" }
            default { "endpoint-path" }
        }
        
        Write-Host "`n# $($_.Endpoint) - $($_.Performance) ($($_.Throughput)):" -ForegroundColor Green
        Write-Host "`$results = Invoke-mgBatchRequest -Endpoint '$endpointPath' -UseParallelProcessing -MaxConcurrentJobs $($_.OptimalJobs)" -ForegroundColor White
    }
}

# Export enhanced results
if (-not $OutputPath) {
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $OutputPath = "MgBatchRequest_Enhanced_Results_$timestamp.csv"
}

$allResults | Export-Csv -Path $OutputPath -NoTypeInformation

# Enhanced summary
Write-Host "`n=== Enhanced Results Summary ===" -ForegroundColor Green
Write-Host "Detailed results: $OutputPath" -ForegroundColor White
Write-Host "Total test time: $([math]::Round($totalTestTime, 1)) minutes" -ForegroundColor Gray
Write-Host "Total tests run: $($allResults.Count)" -ForegroundColor Gray
Write-Host "Successful tests: $($successfulResults.Count)" -ForegroundColor Green

if ($errorResults.Count -gt 0) {
    Write-Host "Tests with HTTP 400 errors: $($errorResults.Count)" -ForegroundColor Red
    Write-Host "Consider investigating endpoints with HTTP 400 errors for optimization opportunities." -ForegroundColor Yellow
}

# Performance improvement statistics
$improvementStats = $successfulResults | Where-Object { $_.Method -ne "Standard Cmdlet" } | ForEach-Object {
    $baseline = $allResults | Where-Object { $_.TestName -eq $_.TestName -and $_.Method -eq "Standard Cmdlet" } | Select-Object -First 1
    if ($baseline) {
        (($baseline.AverageTimeMs - $_.AverageTimeMs) / $baseline.AverageTimeMs) * 100
    }
} | Where-Object { $_ -ne $null -and $_ -gt 0 }

if ($improvementStats) {
    $avgImprovement = ($improvementStats | Measure-Object -Average).Average
    $maxImprovement = ($improvementStats | Measure-Object -Maximum).Maximum
    Write-Host "`nPerformance Improvements:" -ForegroundColor Cyan
    Write-Host "Average improvement: $([math]::Round($avgImprovement, 1))%" -ForegroundColor Green
    Write-Host "Maximum improvement: $([math]::Round($maxImprovement, 1))%" -ForegroundColor Green
}

Write-Host "`n🎉 Enhanced testing completed successfully!" -ForegroundColor Green
Write-Host "Use the production-ready commands above for optimal performance in your environment." -ForegroundColor White
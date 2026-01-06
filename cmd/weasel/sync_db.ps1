# sync user db for weasel
# author: CsHeng
# date: 2025-07-22
# ref: https://github.com/rime/weasel/issues/100#issuecomment-1851849381

$weasel_path = "D:\Applications\ScoopApps\weasel\current\WeaselDeployer.exe"

# Function to check if Weasel process is running
function Test-WeaselProcess {
    $processes = Get-Process -Name "Weasel*" -ErrorAction SilentlyContinue
    return $processes.Count -gt 0
}

# Function to get CPU usage of Weasel process
function Get-WeaselCPUUsage {
    $processes = Get-Process -Name "Weasel*" -ErrorAction SilentlyContinue
    if ($processes) {
        $totalCPU = 0
        foreach ($process in $processes) {
            $totalCPU += $process.CPU
        }
        return $totalCPU
    }
    return 0
}

# Check if Weasel is installed
if (Test-Path $weasel_path) {
    # Check if Weasel process is running
    if (Test-WeaselProcess) {
        $cpuUsage = Get-WeaselCPUUsage
        
        # Check if CPU usage is low (less than 0.5%)
        if ($cpuUsage -le 0.5) {
            Write-Host "Weasel is idle, syncing user db"
            & $weasel_path /sync -v
        } else {
            Write-Host "Weasel is running (CPU: $cpuUsage%), skipping sync"
        }
    } else {
        Write-Host "Weasel is not running, syncing user db"
        & $weasel_path /sync -v
    }
} else {
    Write-Host "Weasel is not installed"
}
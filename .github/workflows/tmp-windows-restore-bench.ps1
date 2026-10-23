# Temporary benchmark: why does restoring the Windows node_modules cache take longer on the larger runners?
$ErrorActionPreference = 'Stop'

function Measure-Tool([string]$Label, [string]$File, [string[]]$Arguments) {
	$info = [System.Diagnostics.ProcessStartInfo]::new($File)
	foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
	$info.UseShellExecute = $false
	$info.RedirectStandardOutput = $true
	$watch = [System.Diagnostics.Stopwatch]::StartNew()
	$process = [System.Diagnostics.Process]::Start($info)
	$output = $process.StandardOutput.ReadToEnd()
	$process.WaitForExit()
	$watch.Stop()
	$line = "RESULT {0}: wall={1:N1}s cpu={2:N1}s exit={3}" -f $Label, $watch.Elapsed.TotalSeconds, $process.TotalProcessorTime.TotalSeconds, $process.ExitCode
	Write-Host $line
	Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value "- $line"
	if ($process.ExitCode -ne 0) { $output -split "`n" | Select-Object -Last 20 | Write-Host }
}

Write-Host '### Machine'
Get-CimInstance Win32_Processor | Format-List Name, NumberOfCores, NumberOfLogicalProcessors, MaxClockSpeed | Out-Host
Get-Volume | Where-Object DriveLetter | Format-Table DriveLetter, FileSystemLabel, FileSystem, Size, SizeRemaining | Out-Host
Get-PhysicalDisk | Format-Table DeviceId, FriendlyName, MediaType, BusType, Size | Out-Host
Get-Partition | Where-Object DriveLetter | Format-Table DiskNumber, DriveLetter, Size | Out-Host
try { Get-MpComputerStatus | Format-List AMServiceEnabled, AntivirusEnabled, RealTimeProtectionEnabled, OnAccessProtectionEnabled | Out-Host } catch { Write-Host "Defender status unavailable: $_" }
try { $preference = Get-MpPreference; Write-Host "DisableRealtimeMonitoring=$($preference.DisableRealtimeMonitoring) ExclusionPath=$($preference.ExclusionPath -join ';')" } catch { Write-Host "Defender preferences unavailable: $_" }
Write-Host "Workspace: $env:GITHUB_WORKSPACE"
& 7z.exe i | Select-Object -First 3 | Out-Host

$archive = (Resolve-Path '.build\node_modules_cache\cache.7z').Path
$quiet = @('-bso0', '-bsp0')

Measure-Tool '7z t (decompress only)' '7z.exe' (@('t', $archive) + $quiet)
Measure-Tool '7z x into the workspace' '7z.exe' (@('x', $archive, '-aoa', "-o$env:GITHUB_WORKSPACE") + $quiet)

$root = [System.IO.Path]::GetPathRoot($env:GITHUB_WORKSPACE)
$fresh = Join-Path $root 'bench-fresh'
Measure-Tool "7z x into a fresh folder on $root" '7z.exe' (@('x', $archive, '-aoa', "-o$fresh") + $quiet)

try {
	$vhd = Join-Path $root 'bench-devdrive.vhdx'
	$script = @"
create vdisk file="$vhd" maximum=30720 type=expandable
select vdisk file="$vhd"
attach vdisk
create partition primary
assign letter=R
"@
	Set-Content -Path (Join-Path $env:RUNNER_TEMP 'diskpart.txt') -Value $script
	diskpart /s (Join-Path $env:RUNNER_TEMP 'diskpart.txt') | Out-Host
	$kind = 'Dev Drive'
	try {
		Format-Volume -DriveLetter R -DevDrive -Confirm:$false -Force | Out-Host
	} catch {
		Write-Host "Dev Drive format failed, using plain ReFS: $_"
		$kind = 'ReFS'
		Format-Volume -DriveLetter R -FileSystem ReFS -Confirm:$false -Force | Out-Host
	}
	fsutil devdrv query R: | Out-Host
	Measure-Tool "7z x into a $kind VHDX on $root" '7z.exe' (@('x', $archive, '-aoa', '-oR:\ws') + $quiet)
} catch {
	Write-Host "Dev Drive benchmark failed: $_"
}

try {
	if ((Get-MpComputerStatus).RealTimeProtectionEnabled) {
		Add-MpPreference -ExclusionPath (Join-Path $root 'bench-excluded')
		Measure-Tool "7z x into a Defender-excluded folder on $root" '7z.exe' (@('x', $archive, '-aoa', "-o$(Join-Path $root 'bench-excluded')") + $quiet)
	}
} catch {
	Write-Host "Defender exclusion benchmark failed: $_"
}

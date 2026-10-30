<#
Stops Documenta on this Windows server and removes the program parts: the startup task, the port
forwarding, the firewall rule, the `documenta` command. The data (the WSL distro "documenta") is
kept unless -Purge is given. Run by the MSI's Uninstall, or by hand as Administrator:

    powershell -ExecutionPolicy Bypass -File uninstall.ps1 [-Purge]
#>
param([switch]$Purge)
$ErrorActionPreference = 'Continue'
$env:WSL_UTF8 = '1'

$reg  = 'HKLM:\SOFTWARE\Documenta'
$info = Get-ItemProperty $reg -ErrorAction SilentlyContinue
$dir  = if ($info.Dir) { $info.Dir } else { 'C:\Documenta' }
$port = if ($info.Port) { $info.Port } elseif (Test-Path "$dir\port") { Get-Content "$dir\port" -First 1 } else { $null }

Stop-ScheduledTask -TaskName 'Documenta' -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName 'Documenta' -Confirm:$false -ErrorAction SilentlyContinue
if ($port) { netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=$port | Out-Null }
Remove-NetFirewallRule -DisplayName 'Documenta' -ErrorAction SilentlyContinue
$path = [Environment]::GetEnvironmentVariable('Path', 'Machine')
[Environment]::SetEnvironmentVariable('Path', (($path -split ';' | Where-Object { $_ -and $_ -ne $dir }) -join ';'), 'Machine')
& wsl.exe --terminate documenta 2>$null   # only works for the user who installed; otherwise it stops at the next reboot

if ($Purge) {
    & wsl.exe --unregister documenta 2>$null
    Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
    Remove-Item -Recurse $reg -ErrorAction SilentlyContinue
    Write-Host 'Documenta and all its data have been removed from this server.'
} else {
    Get-ChildItem $dir -File -ErrorAction SilentlyContinue | Remove-Item -Force   # scripts; the wsl\ data disk stays
    Write-Host "Documenta is stopped and removed. Its data is kept in the WSL distro 'documenta' ($dir\wsl)."
    Write-Host 'To delete the data as well: wsl --unregister documenta'
}

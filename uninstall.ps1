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
$dir  = if ($info.Dir) { $info.Dir } else { "$env:ProgramFiles\Documenta" }
$port = if ($info.Port) { $info.Port } elseif (Test-Path "$dir\port") { Get-Content "$dir\port" -First 1 } else { $null }

Stop-ScheduledTask -TaskName 'Documenta' -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName 'Documenta' -Confirm:$false -ErrorAction SilentlyContinue
if ($port) { netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=$port | Out-Null }
Remove-NetFirewallRule -DisplayName 'Documenta' -ErrorAction SilentlyContinue
$path = [Environment]::GetEnvironmentVariable('Path', 'Machine')
[Environment]::SetEnvironmentVariable('Path', (($path -split ';' | Where-Object { $_ -and $_ -ne $dir }) -join ';'), 'Machine')
& wsl.exe --terminate documenta 2>$null   # only works for the user who installed; otherwise it stops at the next reboot

# Only what install.ps1 generated is removed here; the setup program's own files are the MSI's to remove
$generated = 'start.ps1', 'documenta.ps1', 'documenta.cmd', 'port', 'adapter'
if ($Purge) {
    & wsl.exe --unregister documenta 2>$null
    foreach ($f in @('wsl') + $generated) { Remove-Item "$dir\$f" -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item -Recurse $reg -ErrorAction SilentlyContinue
    if (-not (Get-ChildItem $dir -Force -ErrorAction SilentlyContinue)) { Remove-Item $dir -Force -ErrorAction SilentlyContinue }
    Write-Host 'Documenta and all its data have been removed from this server.'
} else {
    foreach ($f in $generated) { Remove-Item "$dir\$f" -Force -ErrorAction SilentlyContinue }   # the wsl\ data disk stays
    Write-Host "Documenta is stopped and removed. Its data is kept in the WSL distro 'documenta' ($dir\wsl)."
    Write-Host 'To delete the data as well: wsl --unregister documenta'
}

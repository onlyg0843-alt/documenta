<#
Installs or updates Documenta on Windows Server 2022 (or Windows 10/11) with one command, in a
PowerShell window started as Administrator:

    irm https://raw.githubusercontent.com/onlyg0843-alt/documenta/main/install.ps1 | iex

The application runs as Linux containers inside WSL 2. This script enables WSL, imports a small
Ubuntu distro named "documenta", runs the Linux installer (install.sh) inside it, forwards the web
port from Windows to it, and registers a startup task so it comes back after a reboot.
Run the same command again to update (data is kept), or use `documenta update`.

Options, as environment variables set before running:
    $env:DOCUMENTA_PORT     = '80'            web port on Windows; default 80, or 5075 when 80 is taken
                                              (e.g. by IIS); kept on re-runs
    $env:DOCUMENTA_DIR      = 'C:\Program Files\Documenta'   folder for the scripts and the WSL disk
    $env:DOCUMENTA_VERSION  = 'latest'        application version to run, e.g. 1.0.5, or latest to follow
                                              new releases; kept on re-runs
#>
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is much faster without the progress bar
$env:WSL_UTF8 = '1'                        # wsl.exe prints UTF-16 otherwise, which PowerShell garbles

$Repo      = 'onlyg0843-alt/documenta'
$Raw       = "https://raw.githubusercontent.com/$Repo/main"
$Distro    = 'documenta'
$RootfsUrl = 'https://cloud-images.ubuntu.com/wsl/releases/24.04/current/ubuntu-noble-wsl-amd64-wsl.rootfs.tar.gz'
$Port      = if ($env:DOCUMENTA_PORT) { [int]$env:DOCUMENTA_PORT } else { 0 }   # 0: decided below
$ProgFiles = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }   # the 64-bit one, even from a 32-bit PowerShell
$Dir       = if ($env:DOCUMENTA_DIR) { $env:DOCUMENTA_DIR } else { "$ProgFiles\Documenta" }   # the folder the setup program (MSI) uses too
$Version   = $env:DOCUMENTA_VERSION   # empty: keep the installed version (latest on a new install)
$TaskName  = 'Documenta'

function Say($msg)  { Write-Host "==> $msg" -ForegroundColor Cyan }
function Fail($msg) { Write-Host "Error: $msg" -ForegroundColor Red; throw 'Documenta installation stopped.' }
function Test-PortBusy($p) {   # a bind attempt: sees every listener, including IIS (http.sys) and port forwarding
    try { $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $p); $l.Start(); $l.Stop(); $false } catch { $true }
}

# The network card whose address is shown as the app's address. The app answers on every address of the
# server (the port forwarding listens on all of them); this only decides which one is shown. Virtual
# adapters are listed too, except WSL's own: on a Hyper-V host or with NIC teaming the right one is
# virtual. Physical ones come first. With several, the user picks one within 20 seconds, otherwise
# adapter 0 is used. The choice is remembered in <dir>\adapter for later runs.
function Select-Adapter($dir) {
    $candidates = @(Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -eq 'Up' -and $_.Name -notlike 'vEthernet (WSL*' -and $_.InterfaceDescription -notlike '*Loopback*' } |
        Sort-Object -Property @{ Expression = 'Virtual' }, ifIndex |
        ForEach-Object {
            $ip = (Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                   Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1).IPAddress
            if ($ip) { [pscustomobject]@{ Name = $_.Name; Description = $_.InterfaceDescription; IP = $ip; Virtual = [bool]$_.Virtual } }
        })
    if ($candidates.Count -eq 0) { return $null }
    if ($candidates.Count -eq 1) { return $candidates[0] }

    $savedFile = "$dir\adapter"
    if (Test-Path $savedFile) {
        $saved = $candidates | Where-Object Name -eq (Get-Content $savedFile -First 1)
        if ($saved) { return $saved }
    }

    Write-Host ''
    Write-Host 'This server has several network adapters. Which address should people use to reach Documenta?' -ForegroundColor Yellow
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        $kind = if ($candidates[$i].Virtual) { 'virtual' } else { 'physical' }
        Write-Host ("  {0})  {1,-16} {2}  ({3}, {4})" -f $i, $candidates[$i].IP, $candidates[$i].Name, $candidates[$i].Description, $kind)
    }
    $choice = $null
    $canPoll = $true
    try { $null = $Host.UI.RawUI.KeyAvailable } catch { $canPoll = $false }
    if ($canPoll) {
        # Single key press, with a visible countdown
        $deadline = (Get-Date).AddSeconds(20)
        $shown = -1
        while ((Get-Date) -lt $deadline) {
            $left = [int][math]::Ceiling(($deadline - (Get-Date)).TotalSeconds)
            if ($left -ne $shown) {
                Write-Host ("`rPress the number ({0,2} s left, then 0 is used): " -f $left) -NoNewline
                $shown = $left
            }
            try {
                if ($Host.UI.RawUI.KeyAvailable) {
                    $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
                    $char = [string]$key.Character
                    if ($char -match '^\d$' -and [int]$char -lt $candidates.Count) { $choice = [int]$char; break }
                }
            } catch { $canPoll = $false; break }
            Start-Sleep -Milliseconds 100
        }
        Write-Host ''
    }
    if (-not $canPoll) {
        # No live key reading in this window (input redirected): a normal answer, waiting as long as needed
        $answer = Read-Host 'Type the number and press Enter'
        if ($answer -match '^\d+$' -and [int]$answer -lt $candidates.Count) { $choice = [int]$answer }
    }
    if ($null -eq $choice) { $choice = 0 }
    Write-Host "Using adapter $choice ($($candidates[$choice].IP), $($candidates[$choice].Name))"
    Set-Content -Path $savedFile -Value $candidates[$choice].Name
    return $candidates[$choice]
}

function Install-Documenta {

    # ----- administrator -----
    $identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        if ($PSCommandPath) {   # started as a file (Start Menu shortcut): ask Windows for elevation
            Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$PSCommandPath`""
            return
        }
        Fail 'Run this in a PowerShell window started as Administrator.'
    }

    $build = [Environment]::OSVersion.Version.Build
    if ($build -lt 19041) { Fail "Windows Server 2022 / Windows 10 2004 or newer is required (build $build found)." }

    # ----- WSL 2 -----
    & wsl.exe --version 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Say 'Installing WSL 2 (Windows needs one reboot for this)'
        & wsl.exe --install --no-distribution
        Write-Host ''
        Write-Host 'Reboot the server, then run this same command again to continue the installation.' -ForegroundColor Yellow
        return
    }
    try { & wsl.exe --update 2>$null | Out-Null } catch { }   # systemd inside WSL needs a recent version
    & wsl.exe --set-default-version 2 | Out-Null

    New-Item -ItemType Directory -Force -Path "$Dir\wsl" | Out-Null

    # ----- the network adapter, asked now while someone is still watching -----
    $adapter = Select-Adapter $Dir

    # ----- the startup task's account, also asked now -----
    # WSL distros belong to the user who created them, so the task that keeps Documenta running must run as
    # this account. With its password it runs at boot without anyone signing in. A task from an earlier run
    # with a stored password is kept, so the password isn't asked again.
    $user = "$env:USERDOMAIN\$env:USERNAME"
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $keepTask = [bool]($existing -and $existing.Principal.LogonType -eq 'Password' -and $existing.Actions[0].Arguments -like "*$Dir\start.ps1*")
    $taskPassword = ''
    if (-not $keepTask) {
        Write-Host ''
        Write-Host "So that Documenta starts after a reboot without anyone signing in, its startup task runs as $user." -ForegroundColor Yellow
        $secure = Read-Host "Enter this account's password (or press Enter to skip: then it starts when $user signs in and stops when they sign out)" -AsSecureString
        $taskPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
    }

    # ----- the port -----
    # Checked only before the first install: afterwards the port is ours (the forwarding rule listens on it).
    $portFile = "$Dir\port"
    if ($Port) {
        if (-not (Test-Path $portFile) -and (Test-PortBusy $Port)) {
            Fail "Port $Port is already in use on this server. Choose another one: `$env:DOCUMENTA_PORT = '<port>'"
        }
    } elseif (Test-Path $portFile) {
        $Port = [int](Get-Content $portFile)
    } else {
        $Port = 80
        if (Test-PortBusy 80) {
            Say 'Port 80 is in use by another program (IIS?); using port 5075 instead'
            $Port = 5075
            if (Test-PortBusy 5075) { Fail "Ports 80 and 5075 are both in use. Choose another one: `$env:DOCUMENTA_PORT = '<port>'" }
        }
    }

    # ----- the distro -----
    $distros = (& wsl.exe -l -q) -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    $fresh = $distros -notcontains $Distro
    if ($fresh) {
        Say 'Downloading Ubuntu for WSL (about 400 MB)'
        $tar = "$Dir\ubuntu-rootfs.tar.gz"
        Invoke-WebRequest -Uri $RootfsUrl -OutFile $tar -UseBasicParsing
        Say "Creating the '$Distro' WSL distro"
        & wsl.exe --import $Distro "$Dir\wsl" $tar --version 2
        if ($LASTEXITCODE -ne 0) { Fail 'wsl --import failed.' }
        Remove-Item $tar -Force
    }
    # systemd starts Docker and the containers whenever the distro boots; root is its only user; and Windows
    # programs stay out of the Linux PATH, so a docker.exe on Windows can't be mistaken for Docker inside.
    # Written only when it differs, because the distro must then be restarted, which interrupts the app.
    $wanted = '[boot]systemd=true[user]default=root[interop]appendWindowsPath=false'
    $current = ((& wsl.exe -d $Distro -u root -- cat /etc/wsl.conf 2>$null) -join '') -replace '\s', ''
    if ($current -ne $wanted) {
        & wsl.exe -d $Distro -u root -- bash -c "printf '[boot]\nsystemd=true\n[user]\ndefault=root\n[interop]\nappendWindowsPath=false\n' > /etc/wsl.conf"
        & wsl.exe --terminate $Distro
    }

    # ----- the Linux installer, inside the distro -----
    Say 'Running the Linux installer inside WSL (several minutes the first time: Docker and the images are downloaded)'
    & wsl.exe -d $Distro -u root -- bash -c 'apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq curl ca-certificates >/dev/null 2>&1'
    # The version is only passed when asked for; otherwise install.sh keeps the installed one (latest on a new install)
    $versionEnv = if ($Version) { "DOCUMENTA_VERSION=$Version " } else { '' }
    & wsl.exe -d $Distro -u root -- bash -c "curl -fsSL $Raw/install.sh | DOCUMENTA_DIR=/opt/documenta DOCUMENTA_PORT=$Port ${versionEnv}bash"
    if ($LASTEXITCODE -ne 0) { Fail 'The Linux installer failed; see the messages above.' }

    # ----- helper scripts on Windows -----
    $mirrored = (Test-Path "$env:USERPROFILE\.wslconfig") -and ((Get-Content "$env:USERPROFILE\.wslconfig" -Raw) -match 'networkingMode\s*=\s*mirrored')

    # The two scripts below are templates (nothing is expanded inside them); __NAMES__ are filled in afterwards.
    @'
# Started at boot by the "__TASK__" scheduled task (and by install.ps1): boots the WSL distro, where
# systemd starts Docker and the containers, points the Windows port at it, and keeps the distro alive;
# if the keep-alive session ever ends, it starts over. With -NoWait it does one pass and returns.
# Progress goes to start.log next to this file.
param([switch]$NoWait)
$env:WSL_UTF8 = '1'
$distro = '__DISTRO__'; $port = __PORT__; $mirrored = $__MIRRORED__
$log = Join-Path $PSScriptRoot 'start.log'
function Log($m) { try { Add-Content -Path $log -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m" } catch { } }
if ((Test-Path $log) -and (Get-Item $log).Length -gt 1MB) { Remove-Item $log -Force -ErrorAction SilentlyContinue }
while ($true) {
    $boot = (& wsl.exe -d $distro -u root -- true 2>&1) -join ' '
    if ($LASTEXITCODE -ne 0) { Log "could not start the distro: $boot" }
    $ip = ''
    for ($i = 0; $i -lt 30 -and -not $ip; $i++) {
        Start-Sleep -Seconds 2
        $ip = ((& wsl.exe -d $distro -u root -- hostname -I 2>$null) -join ' ').Trim().Split(' ')[0]
    }
    if ($ip -and -not $mirrored) {
        # WSL may get a new internal address on every boot. The forwarding rule is only touched when it is
        # wrong, so open connections survive a re-run of this script.
        $rule = netsh interface portproxy show v4tov4 | Select-String "^\s*0\.0\.0\.0\s+$port\s+(\S+)\s+$port\s*$"
        $target = if ($rule) { $rule.Matches[0].Groups[1].Value } else { '' }
        if ($target -ne $ip) {
            netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=$port | Out-Null
            netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=$port connectaddress=$ip connectport=$port | Out-Null
            Log "forwarding port $port to $ip"
        }
    } elseif (-not $ip) { Log 'the distro gave no address' }
    if ($NoWait) { break }
    Log "distro up at $ip, keeping it alive"
    & wsl.exe -d $distro -u root -- sleep infinity 2>&1 | Out-Null   # an open session keeps WSL from stopping the distro
    Log "the keep-alive session ended (exit $LASTEXITCODE), starting again in 10 s"
    Start-Sleep -Seconds 10
}
'@ -replace '__TASK__', $TaskName -replace '__DISTRO__', $Distro -replace '__PORT__', $Port -replace '__MIRRORED__', $mirrored |
        Set-Content -Path "$Dir\start.ps1" -Encoding UTF8

    @'
# Windows side of the `documenta` command. documenta.cmd sends help, version, start, backup, ip and
# uninstall here; everything else goes straight to the Linux `documenta` inside WSL.
# Arguments are read by position: as named parameters, PowerShell would swallow ones like --purge.
$Command = [string]$args[0]; $Arg = [string]$args[1]
$env:WSL_UTF8 = '1'
$distro = '__DISTRO__'; $dir = '__DIR__'; $port = __PORT__; $task = '__TASK__'

function Show-Help {
    @"
Documenta: shared documents, templates and records, edited in the browser.
On this server it runs inside WSL 2, in the Linux environment '$distro'.

Usage: documenta <command> [options]

Commands:
  update [--force]      Download the newest version and restart. Data, settings and
                        secrets are kept, and users stay signed in. Refuses while files
                        are open in the editor; --force updates anyway.
  status                Show each service and whether it is running.
  logs [service]        Follow the logs live; Ctrl+C stops following. Without a
                        service it shows all of them.
  restart [service]     Restart everything, or one service.
  stop                  Stop everything. Data is kept.
  start                 Start everything again, with the startup task that keeps it running.
  version               Show the installed version and address, and check for a newer one.
  backup [file]         Export the whole system, data included, to a .tar file
                        (default: your Documents folder).
  ip                    Show the internal address of the Linux environment.
  uninstall [--purge]   Remove Documenta and ALL its data; asks first, --purge doesn't.
                        Needs a window started as Administrator.
  help                  Show this help.

Services: api (server), frontend (web app), onlyoffice (document editor),
          telegram-bot, mongodb (database), redis (sign-in sessions).

Examples:
  documenta logs api            follow the server's log
  documenta restart onlyoffice  restart only the document editor

Installed in: $dir
Startup log:  $dir\start.log
"@
}

# The distro belongs to the Windows account that installed Documenta; other accounts can't see it
function Test-Distro {
    if ((& wsl.exe -l -q 2>$null) -replace "`0", '' | ForEach-Object { $_.Trim() } | Where-Object { $_ -eq $distro }) { return $true }
    $owner = (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue).Principal.UserId
    Write-Host "The Linux environment '$distro' was not found for $env:USERDOMAIN\$env:USERNAME." -ForegroundColor Yellow
    if ($owner) { Write-Host "It belongs to the account that installed Documenta ($owner); run documenta as that account." }
    else { Write-Host 'Run the installer ("Install or update Documenta" in the Start Menu) to set it up.' }
    return $false
}

function Show-Version {
    if (-not (Test-Distro)) { exit 1 }
    & wsl.exe -d $distro -u root -- documenta version
    $name = if (Test-Path "$dir\adapter") { Get-Content "$dir\adapter" -TotalCount 1 }
    $ip = if ($name) { (Get-NetIPAddress -InterfaceAlias $name -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1).IPAddress }
    if (-not $ip) { $ip = $env:COMPUTERNAME }
    Write-Host "  Address:      http://$ip$(if ($port -ne 80) { ":$port" })"
    $state = (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue).State
    $taskText = if ($state -eq 'Running') { 'running (it keeps Documenta up)' }
                elseif ($state) { "$($state), not running: Documenta stops without it; documenta start fixes it" }
                else { 'not found: run the installer again' }
    Write-Host "  Startup task: $taskText"
    $setup = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -eq 'Documenta' } | Select-Object -First 1
    Write-Host "  Windows:      $dir$(if ($setup) { "  (setup program $($setup.DisplayVersion))" })"
}

switch ($Command) {
    { $_ -in '', 'help', '-h', '--help' } { Show-Help; break }
    { $_ -in 'version', '-v', '--version' } { Show-Version; break }
    'start' {
        # The startup task keeps the distro alive; without it WSL stops the distro a minute after the last command
        if ((Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue).State -ne 'Running') {
            try { Start-ScheduledTask -TaskName $task -ErrorAction Stop; Start-Sleep -Seconds 5 }
            catch { Write-Host "Could not start the '$task' task ($($_.Exception.Message)). Run this in a window started as Administrator." }
        }
        & wsl.exe -d $distro -u root -- documenta start
    }
    'backup' {
        $file = if ($Arg) { $Arg } else { Join-Path ([Environment]::GetFolderPath('MyDocuments')) ("documenta-backup-{0:yyyy-MM-dd}.tar" -f (Get-Date)) }
        Write-Host "Exporting the whole Documenta system (data included) to $file ..."
        & wsl.exe --export $distro $file
        Write-Host 'Done. Restore on another Windows server with: wsl --import documenta "__DIR__\wsl" <file>, then run install.ps1.'
    }
    'ip' { ((& wsl.exe -d $distro -u root -- hostname -I) -join ' ').Trim() }
    'uninstall' {
        $id = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        if (-not $id.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Write-Host 'Run this in a window started as Administrator.'; return }
        if ($Arg -ne '--purge') {
            $answer = Read-Host 'This removes Documenta AND ALL ITS DATA from this server. Type yes to continue'
            if ($answer -ne 'yes') { return }
        }
        Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
        netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=$port | Out-Null
        Remove-NetFirewallRule -DisplayName 'Documenta' -ErrorAction SilentlyContinue
        & wsl.exe --unregister $distro
        $path = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        [Environment]::SetEnvironmentVariable('Path', (($path -split ';' | Where-Object { $_ -and $_ -ne $dir }) -join ';'), 'Machine')
        # Only what the installer created; the setup program's own files (if it was used) are removed from Apps & features
        foreach ($f in 'wsl', 'start.ps1', 'start.log', 'documenta.cmd', 'port', 'adapter', 'documenta.ps1') { Remove-Item "$dir\$f" -Recurse -Force -ErrorAction SilentlyContinue }
        Remove-Item -Recurse 'HKLM:\SOFTWARE\Documenta' -ErrorAction SilentlyContinue
        if (-not (Get-ChildItem $dir -Force -ErrorAction SilentlyContinue)) { Remove-Item $dir -Force -ErrorAction SilentlyContinue }
        Write-Host 'Documenta and all its data have been removed.'
        if (Test-Path "$dir\uninstall.ps1") { Write-Host 'The setup program is still listed in Apps & features; remove "Documenta" there as well.' }
    }
    default { Write-Host "Unknown command: $Command"; Write-Host ''; Show-Help; exit 1 }
}
'@ -replace '__TASK__', $TaskName -replace '__DISTRO__', $Distro -replace '__PORT__', $Port -replace '__DIR__', $Dir |
        Set-Content -Path "$Dir\documenta.ps1" -Encoding UTF8

    @"
@echo off
rem The ``documenta`` command on Windows. help, version and the Windows-only commands are handled by
rem documenta.ps1 next to this file; everything else goes to the Linux ``documenta`` inside WSL.
if "%~1"=="" goto windows
for %%c in (help -h --help version -v --version start backup ip uninstall) do if /I "%~1"=="%%c" goto windows
wsl.exe -d $Distro -u root -- documenta %*
exit /b %ERRORLEVEL%
:windows
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0documenta.ps1" %*
exit /b %ERRORLEVEL%
"@ | Set-Content -Path "$Dir\documenta.cmd" -Encoding ASCII

    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if (($machinePath -split ';') -notcontains $Dir) {
        [Environment]::SetEnvironmentVariable('Path', "$machinePath;$Dir", 'Machine')
    }

    # ----- network: let the server's address reach the app inside WSL -----
    Set-Content -Path $portFile -Value $Port
    # Where things are, for uninstall.ps1 (the MSI's Uninstall) which may run as another account
    New-Item -Path 'HKLM:\SOFTWARE\Documenta' -Force | Out-Null
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Documenta' -Name 'Dir' -Value $Dir
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Documenta' -Name 'Port' -Value $Port
    Remove-NetFirewallRule -DisplayName 'Documenta' -ErrorAction SilentlyContinue   # recreated, in case the port changed
    New-NetFirewallRule -DisplayName 'Documenta' -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow | Out-Null
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$Dir\start.ps1" -NoWait

    # ----- start at boot -----
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Dir\start.ps1`""
    $settings = New-ScheduledTaskSettingsSet -RestartCount 10 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $settings.ExecutionTimeLimit = 'PT0S'   # never stop it: it keeps the distro alive
    if ($keepTask) {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue   # started again below, with the new start.ps1
    } else {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        $registered = $false
        if ($taskPassword) {
            try {
                Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger (New-ScheduledTaskTrigger -AtStartup) -Settings $settings -User $user -Password $taskPassword -RunLevel Highest -ErrorAction Stop | Out-Null
                $registered = $true
            } catch {
                Write-Host "Windows did not accept the password ($($_.Exception.Message.Trim())). Documenta will start when $user signs in instead; run the installer again to retry." -ForegroundColor Yellow
            }
        }
        if (-not $registered) {
            Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger (New-ScheduledTaskTrigger -AtLogOn -User $user) -Settings $settings -User $user -RunLevel Highest | Out-Null
        }
    }
    Start-ScheduledTask -TaskName $TaskName

    # ----- wait until the app answers through the forwarded port (the API needs a moment after the containers start) -----
    Say 'Waiting for Documenta to answer'
    $up = $false
    for ($i = 0; $i -lt 40 -and -not $up; $i++) {
        try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 "http://127.0.0.1:$Port/api/auth/profile" | Out-Null; $up = $true }
        catch { if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 401) { $up = $true } else { Start-Sleep -Seconds 3 } }
    }
    $taskState = (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue).State

    # ----- done -----
    $url ="http://$(if ($adapter) { $adapter.IP } else { $env:COMPUTERNAME })$(if ($Port -ne 80) { ":$Port" })"
    Write-Host ''
    if ($up) {
        Say "Documenta is running at $url"
    } else {
        Say "Documenta is starting at $url but does not answer yet"
        Write-Host "    Check in a minute with: documenta status, documenta logs api. The startup task's log is $Dir\start.log" -ForegroundColor Yellow
    }
    if ($taskState -ne 'Running') { Write-Host "    Warning: the '$TaskName' startup task is not running (state: $taskState); see $Dir\start.log" -ForegroundColor Yellow }
    if ($adapter) { Write-Host "    Network:      $($adapter.Name) ($($adapter.Description)); the app answers on every address of this server" }
    # The default login only while it is still in use, the same check as at the end of install.sh: the server
    # marks superadmin until someone sets a new password. If the database can't be asked: on a new installation.
    # The check goes in base64 so that no quoting survives the trip through wsl.exe and bash -c.
    $check = 'cd /opt/documenta && docker compose exec -T mongodb mongosh --quiet "$(grep ''^DB_NAME='' .env | cut -d= -f2-)" --eval ''const u = db.users.findOne({username: "superadmin"}); print(u ? (u.mustChangePassword ? "default" : "changed") : "none")'''
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($check))
    $account = ((& wsl.exe -d $Distro -u root -- bash -c "echo $b64 | base64 -d | bash" 2>$null) -join '').Trim()
    $showLogin = if ($account -eq 'default') { $true } elseif ($account -eq 'changed') { $false } else { $fresh }
    if ($showLogin) { Write-Host '    Login:        superadmin / changeme12345  (you will be asked to change it at first sign-in)' }
    Write-Host "    Files:        $Dir  (the app and its data live in the WSL distro '$Distro')"
    Write-Host '    Commands:     documenta help   lists them all: update, status, logs, version, backup, uninstall, ...'
    Write-Host '                  (open a new PowerShell window first, so the command is on the PATH)'
}

Install-Documenta

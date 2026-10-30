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
    $env:DOCUMENTA_DIR      = 'C:\Documenta'  Windows folder for the scripts and the WSL disk
    $env:DOCUMENTA_VERSION  = 'latest'        application version to run, e.g. 1.0.4
#>
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is much faster without the progress bar
$env:WSL_UTF8 = '1'                        # wsl.exe prints UTF-16 otherwise, which PowerShell garbles

$Repo      = 'onlyg0843-alt/documenta'
$Raw       = "https://raw.githubusercontent.com/$Repo/main"
$Distro    = 'documenta'
$RootfsUrl = 'https://cloud-images.ubuntu.com/wsl/releases/24.04/current/ubuntu-noble-wsl-amd64-wsl.rootfs.tar.gz'
$Port      = if ($env:DOCUMENTA_PORT) { [int]$env:DOCUMENTA_PORT } else { 0 }   # 0: decided below
$Dir       = if ($env:DOCUMENTA_DIR) { $env:DOCUMENTA_DIR } else { 'C:\Documenta' }
$Version   = if ($env:DOCUMENTA_VERSION) { $env:DOCUMENTA_VERSION } else { 'latest' }
$TaskName  = 'Documenta'

function Say($msg)  { Write-Host "==> $msg" -ForegroundColor Cyan }
function Fail($msg) { Write-Host "Error: $msg" -ForegroundColor Red; throw 'Documenta installation stopped.' }
function Test-PortBusy($p) { [bool](Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction SilentlyContinue) }

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
    # Written on every run (it's idempotent) and the distro is restarted so it takes effect.
    & wsl.exe -d $Distro -u root -- bash -c "printf '[boot]\nsystemd=true\n[user]\ndefault=root\n[interop]\nappendWindowsPath=false\n' > /etc/wsl.conf"
    & wsl.exe --terminate $Distro

    # ----- the Linux installer, inside the distro -----
    Say 'Running the Linux installer inside WSL (several minutes the first time: Docker and the images are downloaded)'
    & wsl.exe -d $Distro -u root -- bash -c 'apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq curl ca-certificates >/dev/null 2>&1'
    & wsl.exe -d $Distro -u root -- bash -c "curl -fsSL $Raw/install.sh | DOCUMENTA_DIR=/opt/documenta DOCUMENTA_PORT=$Port DOCUMENTA_VERSION=$Version bash"
    if ($LASTEXITCODE -ne 0) { Fail 'The Linux installer failed; see the messages above.' }

    # ----- helper scripts on Windows -----
    $mirrored = (Test-Path "$env:USERPROFILE\.wslconfig") -and ((Get-Content "$env:USERPROFILE\.wslconfig" -Raw) -match 'networkingMode\s*=\s*mirrored')

    @"
# Started at boot by the "$TaskName" scheduled task (and by install.ps1): boots the WSL distro, where
# systemd starts Docker and the containers, points the Windows port at it, and keeps the distro alive.
param([switch]`$NoWait)
`$env:WSL_UTF8 = '1'
`$distro = '$Distro'; `$port = $Port; `$mirrored = `$$mirrored
& wsl.exe -d `$distro -u root -- true
`$ip = ''
for (`$i = 0; `$i -lt 30 -and -not `$ip; `$i++) {
    Start-Sleep -Seconds 2
    `$ip = ((& wsl.exe -d `$distro -u root -- hostname -I 2>`$null) -join ' ').Trim().Split(' ')[0]
}
if (`$ip -and -not `$mirrored) {
    # WSL gets a new internal address on every boot, so refresh the forwarding rule
    netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=`$port | Out-Null
    netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=`$port connectaddress=`$ip connectport=`$port | Out-Null
}
if (-not `$NoWait) { & wsl.exe -d `$distro -u root -- sleep infinity }   # an open session keeps WSL from stopping the distro
"@ | Set-Content -Path "$Dir\start.ps1" -Encoding UTF8

    @"
# Windows-side commands of `documenta`; everything else is passed to the Linux `documenta` inside WSL.
param([string]`$Command, [string]`$Arg)
`$env:WSL_UTF8 = '1'
`$distro = '$Distro'; `$dir = '$Dir'; `$port = $Port; `$task = '$TaskName'
switch (`$Command) {
    'backup' {
        `$file = if (`$Arg) { `$Arg } else { Join-Path `$dir ("documenta-backup-{0:yyyy-MM-dd}.tar" -f (Get-Date)) }
        Write-Host "Exporting the whole Documenta system (data included) to `$file ..."
        & wsl.exe --export `$distro `$file
        Write-Host 'Done. Restore on another Windows server with: wsl --import documenta C:\Documenta\wsl <file>, then run install.ps1.'
    }
    'ip' { ((& wsl.exe -d `$distro -u root -- hostname -I) -join ' ').Trim() }
    'uninstall' {
        if (`$Arg -ne '--purge') {
            `$answer = Read-Host 'This removes Documenta AND ALL ITS DATA from this server. Type yes to continue'
            if (`$answer -ne 'yes') { return }
        }
        Stop-ScheduledTask -TaskName `$task -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName `$task -Confirm:`$false -ErrorAction SilentlyContinue
        netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=`$port | Out-Null
        Remove-NetFirewallRule -DisplayName 'Documenta' -ErrorAction SilentlyContinue
        & wsl.exe --unregister `$distro
        `$path = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        [Environment]::SetEnvironmentVariable('Path', ((`$path -split ';' | Where-Object { `$_ -and `$_ -ne `$dir }) -join ';'), 'Machine')
        Remove-Item -Recurse -Force `$dir
        Write-Host 'Documenta has been removed.'
    }
    default { Write-Host 'Usage: documenta backup [file] | ip | uninstall [--purge]' }
}
"@ | Set-Content -Path "$Dir\documenta.ps1" -Encoding UTF8

    @"
@echo off
if /I "%~1"=="backup" goto windows
if /I "%~1"=="ip" goto windows
if /I "%~1"=="uninstall" goto windows
wsl.exe -d $Distro -u root -- documenta %*
exit /b %ERRORLEVEL%
:windows
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0documenta.ps1" %*
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
    # WSL distros belong to the user who created them, so the task must run as this account.
    $user = "$env:USERDOMAIN\$env:USERNAME"
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Dir\start.ps1`""
    $settings = New-ScheduledTaskSettingsSet -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $settings.ExecutionTimeLimit = 'PT0S'   # never stop it: it keeps the distro alive
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host ''
    Write-Host "So that Documenta starts after a reboot without anyone signing in, the startup task runs as $user." -ForegroundColor Yellow
    $secure = Read-Host "Enter this account's password (or press Enter to skip: then it starts when $user signs in)" -AsSecureString
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
    if ($plain) {
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger (New-ScheduledTaskTrigger -AtStartup) -Settings $settings -User $user -Password $plain -RunLevel Highest | Out-Null
    } else {
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger (New-ScheduledTaskTrigger -AtLogOn -User $user) -Settings $settings -User $user -RunLevel Highest | Out-Null
    }
    Start-ScheduledTask -TaskName $TaskName

    # ----- done -----
    $url ="http://$(if ($adapter) { $adapter.IP } else { $env:COMPUTERNAME })$(if ($Port -ne 80) { ":$Port" })"
    Write-Host ''
    Say "Documenta is running at $url"
    if ($adapter) { Write-Host "    Network:      $($adapter.Name) ($($adapter.Description)); the app answers on every address of this server" }
    if ($fresh) { Write-Host '    First login:  superadmin / changeme12345  (you will be asked to change it)' }
    Write-Host "    Files:        $Dir  (the app and its data live in the WSL distro '$Distro')"
    Write-Host '    Commands:     documenta update | status | logs | restart | stop | start | backup | uninstall'
    Write-Host '                  (open a new PowerShell window first, so the command is on the PATH)'
}

Install-Documenta

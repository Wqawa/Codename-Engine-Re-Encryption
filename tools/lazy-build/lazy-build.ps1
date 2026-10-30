<#
    lazy-build.ps1 - one-click Windows build for this repository.

    Everything this fork needs to go from "fresh machine" to
    export/release/windows/bin/CodenameEngine.exe:

      1. find (or download) a Haxe 4.3.x + Neko toolchain
      2. point haxelib at the repository-local .haxelib folder
      3. make sure the vendored libraries and the lime native ndll are there
      4. make sure a MSVC toolchain (Visual Studio Build Tools) exists
      5. run "haxelib run lime build windows -nocolor"
      6. check that the exe is newer than the build start, translate known errors

    Nothing outside the repository is modified unless a toolchain (or the
    Visual Studio Build Tools) is missing and has to be installed.

    Run it through Build.bat, or directly:
      pwsh -NoProfile -ExecutionPolicy Bypass -File tools/lazy-build/lazy-build.ps1
#>

# no [CmdletBinding()] on purpose: its common parameter -Debug would collide
# with the build configuration switch of the same name
param(
    # Build without reusing intermediate objects (lime build ... -clean)
    [switch]$Clean,
    # Build the debug configuration instead of release
    [switch]$Debug,
    # Print every action instead of running it
    [switch]$DryRun,
    # Never ask a question; take the safe default
    [switch]$Yes,
    # Ignore installed Haxe builds and use the bundled toolchain folder only
    [switch]$ForceToolchain,
    # Download + extract the toolchain even when a usable Haxe is installed
    [switch]$DownloadToolchain,
    # Rebuild lime's native library even when the ndll looks fine
    [switch]$RebuildLime,
    # Explicit Haxe folder (the one that contains haxe.exe)
    [string]$HaxeHome,
    # Explicit repository root (defaults to this script's ../..)
    [string]$RepoRoot,
    # Where a downloaded toolchain is unpacked
    [string]$ToolchainDir
)

$ErrorActionPreference = 'Stop'
try { $PSNativeCommandUseErrorActionPreference = $false } catch { }

# ---------------------------------------------------------------- constants
$HaxeVersion = '4.3.7'
$NekoVersion = '2.3.0'
$HaxeUrl = "https://github.com/HaxeFoundation/haxe/releases/download/$HaxeVersion/haxe-$HaxeVersion-win64.zip"
$NekoUrl = "https://github.com/HaxeFoundation/neko/releases/download/v2-3-0/neko-$NekoVersion-win64.zip"
$VsBuildToolsUrl = 'https://aka.ms/vs/17/release/vs_BuildTools.exe'

$script:LogFile = $null
$script:HaxePath = $null
$script:NekoPath = $null
$script:RepoRoot = $null
$script:ToolchainDir = $null

# ---------------------------------------------------------------- output
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERR', 'CMD', 'DRY')]
        [string]$Level = 'INFO'
    )

    $stamp = (Get-Date).ToString('HH:mm:ss')
    switch ($Level) {
        'OK' { $color = 'Green' }
        'WARN' { $color = 'Yellow' }
        'ERR' { $color = 'Red' }
        'CMD' { $color = 'DarkGray' }
        'DRY' { $color = 'Magenta' }
        default { $color = 'Gray' }
    }
    $line = "[$stamp] $Message"
    Write-Host $line -ForegroundColor $color
    if ($script:LogFile) { Add-Content -Path $script:LogFile -Value $line -Encoding utf8 }
}

function Write-Step {
    param([string]$Text)
    Write-Host ''
    Write-Host "== $Text ==" -ForegroundColor Cyan
    if ($script:LogFile) { Add-Content -Path $script:LogFile -Value "`n== $Text ==" -Encoding utf8 }
}

function Test-Administrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
    } catch {
        return $false
    }
}

function Confirm-Action {
    param([string]$Question, [bool]$DefaultYes = $true)

    if ($Yes) { return $DefaultYes }
    $suffix = if ($DefaultYes) { '[Y/n]' } else { '[y/N]' }
    $answer = Read-Host "$Question $suffix"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $DefaultYes }
    return ($answer.Trim().ToLowerInvariant() -in @('y', 'yes', 'yes!', '是', '好'))
}

# Runs a native command, streams its output to the log, returns the exit code.
# In -DryRun mode nothing is executed.
function Invoke-Tool {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$Label,
        [switch]$AllowFail
    )

    $display = "$FilePath $($Arguments -join ' ')"
    if ([string]::IsNullOrWhiteSpace($Label)) { $Label = $display }

    if ($DryRun) {
        Write-Log "[dryrun] $display" 'DRY'
        return 0
    }

    Write-Log $display 'CMD'
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $FilePath @Arguments 2>&1 | ForEach-Object {
            $text = "$_"
            Write-Host $text
            if ($script:LogFile) { Add-Content -Path $script:LogFile -Value $text -Encoding utf8 }
        }
        $code = $LASTEXITCODE
        if ($null -eq $code) { $code = 0 }
    } finally {
        $ErrorActionPreference = $previous
    }

    if ($code -ne 0) {
        if ($AllowFail) {
            Write-Log "$Label -> exit $code" 'WARN'
        } else {
            Write-Log "$Label -> exit $code" 'ERR'
        }
    }
    return $code
}

function Invoke-Capture {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @()
    )

    # read-only probe: it stays enabled in -DryRun so the plan reflects reality
    if (-not (Test-Path -LiteralPath $FilePath)) { return '' }
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $result = & $FilePath @Arguments 2>&1
        return ($result | Out-String).Trim()
    } catch {
        return ''
    } finally {
        $ErrorActionPreference = $previous
    }
}

# Downloads to $Destination unless it is already there, reusing toolchain\downloads
# as an offline cache (drop the zip in there for a machine without internet).
function Get-RemoteFile {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination
    )

    if (Test-Path -LiteralPath $Destination) {
        Write-Log "already downloaded: $Destination" 'OK'
        return $Destination
    }

    $cache = Join-Path $script:ToolchainDir 'downloads'
    $cached = Join-Path $cache (Split-Path -Leaf $Destination)
    if (Test-Path -LiteralPath $cached) {
        Write-Log "reusing cached download: $cached" 'OK'
        Copy-Item -LiteralPath $cached -Destination $Destination -Force
        return $Destination
    }

    if ($DryRun) {
        Write-Log "[dryrun] download $Url -> $Destination" 'DRY'
        return $Destination
    }

    if (-not (Test-Path -LiteralPath $cache)) { New-Item -ItemType Directory -Path $cache -Force | Out-Null }

    Write-Log "downloading $Url"
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -TimeoutSec 600
            $size = (Get-Item -LiteralPath $Destination).Length
            if ($size -lt 100KB) { throw "download is only $size bytes - probably an error page" }
            Copy-Item -LiteralPath $Destination -Destination $cached -Force
            Write-Log ("downloaded {0:N1} MB" -f ($size / 1MB)) 'OK'
            return $Destination
        } catch {
            Write-Log "download attempt ${attempt} failed: $($_.Exception.Message)" 'WARN'
            if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue }
            if ($attempt -ge 3) { throw }
            Start-Sleep -Seconds 2
        }
    }
    return $Destination
}

function Expand-ZipTo {
    param(
        [Parameter(Mandatory)][string]$Zip,
        [Parameter(Mandatory)][string]$Destination,
        # if this file already exists below $Destination the archive is not
        # unpacked again (second run stays fast)
        [string]$Marker
    )

    if ($Marker) {
        $existing = Resolve-UnpackedExe -Directory $Destination -ExeName $Marker
        if (Test-Path -LiteralPath (Join-Path $existing $Marker)) {
            Write-Log "already unpacked: $existing" 'OK'
            return
        }
    }

    if ($DryRun) {
        Write-Log "[dryrun] expand $Zip -> $Destination" 'DRY'
        return
    }
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Expand-Archive -LiteralPath $Zip -DestinationPath $Destination -Force
    Write-Log "extracted to $Destination" 'OK'
}

# The release zips sometimes contain one top level folder; flatten that case.
function Resolve-UnpackedExe {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$ExeName
    )

    $exe = Join-Path $Directory $ExeName
    if (Test-Path -LiteralPath $exe) { return $Directory }

    $inner = Get-ChildItem -LiteralPath $Directory -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($inner) {
        $nested = Join-Path $inner.FullName $ExeName
        if (Test-Path -LiteralPath $nested) { return $inner.FullName }
    }
    return $Directory
}

# ---------------------------------------------------------------- discovery
function Get-HaxeVersionOf {
    param([string]$HaxeExe)
    $raw = Invoke-Capture -FilePath $HaxeExe -Arguments @('--version')
    if ($raw -match '(\d+\.\d+\.\d+)') { return $Matches[1] }
    return $null
}

# Finds haxe.exe: explicit parameter, bundled toolchain, PATH, usual install dirs.
function Find-HaxeHome {
    $candidates = New-Object System.Collections.ArrayList

    if ($HaxeHome) { [void]$candidates.Add($HaxeHome) }
    if (Test-Path -LiteralPath $script:ToolchainDir) {
        foreach ($dir in (Get-ChildItem -LiteralPath $script:ToolchainDir -Directory -ErrorAction SilentlyContinue)) {
            [void]$candidates.Add($dir.FullName)
            [void]$candidates.Add((Join-Path $dir.FullName 'haxe'))
        }
    }
    if (-not $ForceToolchain) {
        if ($env:HAXEPATH) { [void]$candidates.Add($env:HAXEPATH) }
        $onPath = (Get-Command haxe.exe -ErrorAction SilentlyContinue).Source
        if ($onPath) { [void]$candidates.Add((Split-Path -Parent $onPath)) }
        foreach ($root in @('C:\HaxeToolkit', 'C:\Haxe', 'D:\Haxe', 'D:\FNF\Haxe')) {
            if (-not (Test-Path -LiteralPath $root)) { continue }
            foreach ($dir in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
                [void]$candidates.Add((Join-Path $dir.FullName 'haxe'))
                [void]$candidates.Add($dir.FullName)
            }
        }
    }

    foreach ($candidate in $candidates) {
        $exe = Join-Path $candidate 'haxe.exe'
        if (-not (Test-Path -LiteralPath $exe)) { continue }
        $version = Get-HaxeVersionOf $exe
        if ($version -and $version.StartsWith('4.3.')) {
            Write-Log "found Haxe $version at $candidate" 'OK'
            return (Resolve-Path -LiteralPath $candidate).Path
        }
        if ($version) { Write-Log "ignoring Haxe $version at $candidate (need 4.3.x)" 'WARN' }
    }
    return $null
}

# "haxelib run lime" executes lime's run.n bytecode, so Neko is required too.
function Find-NekoHome {
    $candidates = New-Object System.Collections.ArrayList

    if (-not $ForceToolchain) {
        if ($env:NEKOPATH) { [void]$candidates.Add($env:NEKOPATH) }
        $onPath = (Get-Command neko.exe -ErrorAction SilentlyContinue).Source
        if ($onPath) { [void]$candidates.Add((Split-Path -Parent $onPath)) }
        foreach ($root in @('C:\HaxeToolkit', 'C:\Haxe', 'D:\Haxe', 'D:\FNF\Haxe')) {
            if (-not (Test-Path -LiteralPath $root)) { continue }
            foreach ($dir in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
                [void]$candidates.Add((Join-Path $dir.FullName 'neko'))
                [void]$candidates.Add($dir.FullName)
            }
        }
    }
    if (Test-Path -LiteralPath $script:ToolchainDir) {
        foreach ($dir in (Get-ChildItem -LiteralPath $script:ToolchainDir -Directory -ErrorAction SilentlyContinue)) {
            [void]$candidates.Add($dir.FullName)
        }
    }

    foreach ($candidate in $candidates) {
        $dll = Join-Path $candidate 'neko.dll'
        $exe = Join-Path $candidate 'neko.exe'
        if ((Test-Path -LiteralPath $dll) -and (Test-Path -LiteralPath $exe)) {
            Write-Log "found Neko at $candidate" 'OK'
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    return $null
}

function Install-HaxeToolchain {
    Write-Log "no usable Haxe 4.3.x found - installing $HaxeVersion into $script:ToolchainDir" 'WARN'
    if (-not $DryRun -and -not (Test-Path -LiteralPath $script:ToolchainDir)) {
        New-Item -ItemType Directory -Path $script:ToolchainDir -Force | Out-Null
    }

    $zip = Join-Path $script:ToolchainDir "haxe-$HaxeVersion-win64.zip"
    [void](Get-RemoteFile -Url $HaxeUrl -Destination $zip)
    $target = Join-Path $script:ToolchainDir "haxe-$HaxeVersion"
    Expand-ZipTo -Zip $zip -Destination $target -Marker 'haxe.exe'
    if ($DryRun) { return $target }

    $target = Resolve-UnpackedExe -Directory $target -ExeName 'haxe.exe'
    if (-not (Test-Path -LiteralPath (Join-Path $target 'haxe.exe'))) {
        throw "the Haxe archive did not contain haxe.exe (looked in $target)"
    }
    Write-Log "Haxe installed at $target" 'OK'
    return $target
}

function Install-NekoToolchain {
    Write-Log "installing Neko $NekoVersion into $script:ToolchainDir" 'WARN'
    $zip = Join-Path $script:ToolchainDir "neko-$NekoVersion-win64.zip"
    [void](Get-RemoteFile -Url $NekoUrl -Destination $zip)
    $target = Join-Path $script:ToolchainDir "neko-$NekoVersion"
    Expand-ZipTo -Zip $zip -Destination $target -Marker 'neko.exe'
    if ($DryRun) { return $target }

    $target = Resolve-UnpackedExe -Directory $target -ExeName 'neko.exe'
    Write-Log "Neko installed at $target" 'OK'
    return $target
}

function Find-VisualStudio {
    $programFilesX86 = ${env:ProgramFiles(x86)}
    if ([string]::IsNullOrWhiteSpace($programFilesX86)) { return $null }
    $vswhere = Join-Path $programFilesX86 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) { return $null }

    $install = Invoke-Capture -FilePath $vswhere -Arguments @(
        '-latest', '-products', '*',
        '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
        '-property', 'installationPath'
    )
    if ($install) { return $install.Trim() }
    return $null
}

function Install-VisualStudioBuildTools {
    Write-Log 'no MSVC C++ toolchain found - the C++ output cannot be compiled without one' 'WARN'

    $target = Join-Path $env:TEMP 'vs_BuildTools.exe'
    if (-not (Test-Path -LiteralPath $target)) {
        [void](Get-RemoteFile -Url $VsBuildToolsUrl -Destination $target)
    }

    if (-not (Test-Administrator)) {
        Write-Log 'this window is not elevated, so the installer cannot be started from here' 'ERR'
        Write-Log "run this file as administrator, then run Build.bat again: $target" 'ERR'
        Write-Log 'pick the "Desktop development with C++" workload' 'ERR'
        throw 'Visual Studio Build Tools installation needs administrator rights'
    }

    if (-not (Confirm-Action 'Install the Visual Studio C++ Build Tools now? This is a multi-GB download.')) {
        throw 'Visual Studio Build Tools installation was declined'
    }

    [void](Invoke-Tool -FilePath $target -Arguments @(
            '--quiet', '--wait', '--norestart', '--nocache',
            '--add', 'Microsoft.VisualStudio.Workload.VCTools',
            '--includeRecommended'
        ) -Label 'Visual Studio Build Tools installer' -AllowFail)

    if (-not (Find-VisualStudio)) { throw 'the installer finished but no C++ toolchain was found' }
    Write-Log 'Visual Studio Build Tools installed' 'OK'
}

function Get-VisualStudioOrInstall {
    $visualStudio = Find-VisualStudio
    if ($visualStudio) {
        Write-Log "Visual Studio: $visualStudio" 'OK'
        return $visualStudio
    }
    Install-VisualStudioBuildTools
    return (Find-VisualStudio)
}

# ---------------------------------------------------------------- repo checks
function Resolve-RepoRoot {
    if ($RepoRoot) {
        $candidate = (Resolve-Path -LiteralPath $RepoRoot).Path
    } else {
        $candidate = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
    }
    if (-not (Test-Path -LiteralPath (Join-Path $candidate 'project.xml'))) {
        throw "not a Codename Engine checkout: project.xml not found in $candidate"
    }
    return $candidate
}

function Get-HaxelibExe {
    return (Join-Path $script:HaxePath 'haxelib.exe')
}

function Get-HaxelibRepoPath {
    return (Invoke-Capture -FilePath (Get-HaxelibExe) -Arguments @('config')).Trim()
}

# The vendored libraries live in <repo>/.haxelib. Haxe 4 treats a .haxelib folder
# in the current directory as a local repository, so the build must run from the
# repo root; HAXELIB_PATH makes that explicit even if the cwd ever changes.
function Initialize-HaxelibRepository {
    $repo = Join-Path $script:RepoRoot '.haxelib'

    if (-not (Test-Path -LiteralPath $repo)) {
        Write-Log "the vendored library folder is missing: $repo" 'WARN'
        Write-Log 'this folder ships with the repository; without it the libraries must be downloaded' 'WARN'
        if ($DryRun) {
            Write-Log '[dryrun] haxelib newrepo + haxelib install for the libraries in project.xml' 'DRY'
            return
        }
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        [void](Invoke-Tool -FilePath (Get-HaxelibExe) -Arguments @('newrepo') -Label 'haxelib newrepo')
        Write-Log 'empty repository created - install the libraries from project.xml with: haxelib install <name>' 'ERR'
        throw 'the vendored .haxelib folder is gone; restore it from the repository (it is not rebuilt automatically)'
    }

    $env:HAXELIB_PATH = $repo

    $configured = Get-HaxelibRepoPath
    if ($configured -and -not $DryRun) {
        $expected = $repo.TrimEnd('\', '/')
        $actual = $configured.TrimEnd('\', '/')
        if ($actual -ne $expected) {
            Write-Log "haxelib reports $actual instead of $expected" 'WARN'
        }
    }

    $found = @()
    foreach ($name in @('lime', 'flixel', 'openfl', 'hxcpp')) {
        if (Test-Path -LiteralPath (Join-Path $repo $name)) { $found += $name }
    }
    if ($found.Count -lt 4) {
        Write-Log "the vendored library folder looks incomplete (found: $($found -join ', '))" 'WARN'
    } else {
        Write-Log "using vendored libraries from $repo" 'OK'
    }
}

# Path of the lime native library that matches the version haxelib resolves.
function Get-LimeNativePath {
    param([string]$Architecture = 'Windows64')

    $limeRoot = Join-Path $script:RepoRoot '.haxelib\lime'
    if (-not (Test-Path -LiteralPath $limeRoot)) { return $null }

    $versionDir = $null
    $current = Join-Path $limeRoot '.current'
    if (Test-Path -LiteralPath $current) {
        $name = (Get-Content -LiteralPath $current -TotalCount 1).Trim()
        if ($name) { $versionDir = Join-Path $limeRoot $name }
    }
    if (-not $versionDir -or -not (Test-Path -LiteralPath $versionDir)) {
        $versionDir = Get-ChildItem -LiteralPath $limeRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $versionDir) { return $null }

    $ndll = Join-Path $versionDir "ndll\$Architecture\lime.ndll"
    if (Test-Path -LiteralPath $ndll) { return $ndll }
    return $null
}

function Stop-RunningEngine {
    $processes = @(Get-Process -Name 'CodenameEngine' -ErrorAction SilentlyContinue)
    if ($processes.Count -eq 0) { return }

    Write-Log 'CodenameEngine is running - it locks the exe the linker wants to write' 'WARN'
    if ($DryRun) {
        Write-Log '[dryrun] close CodenameEngine before linking' 'DRY'
        return
    }
    if (-not (Confirm-Action 'Close the running game so the build can finish?')) {
        throw 'the game is still running'
    }

    foreach ($process in $processes) {
        try { [void]$process.CloseMainWindow() } catch { }
    }
    Start-Sleep -Milliseconds 1500
    foreach ($process in @(Get-Process -Name 'CodenameEngine' -ErrorAction SilentlyContinue)) {
        try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch { }
    }
    Start-Sleep -Milliseconds 500
    if (Get-Process -Name 'CodenameEngine' -ErrorAction SilentlyContinue) {
        throw 'could not close CodenameEngine.exe - close it by hand and run again'
    }
    Write-Log 'engine closed' 'OK'
}

# ---------------------------------------------------------------- error advice
function Get-ErrorAdvice {
    param([string]$LogPath)

    $errorLines = @()
    if (Test-Path -LiteralPath $LogPath) {
        $errorLines = Get-Content -LiteralPath $LogPath |
            Where-Object { $_ -match 'error:|Error:|LNK\d{4}|Could not find|cannot open file' } |
            Select-Object -First 25
    }
    if ($errorLines.Count -eq 0) { return }

    Write-Host ''
    Write-Host '--- first error lines -----------------------------------------' -ForegroundColor Red
    $errorLines | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    Write-Host '---------------------------------------------------------------' -ForegroundColor Red

    $all = ($errorLines -join "`n")
    $advice = New-Object System.Collections.ArrayList

    if ($all -match 'Could not find haxelib|Library .* is not installed') {
        [void]$advice.Add('缺 haxelib 库：确认是在仓库根目录编译（本仓库的库在 .haxelib 里，不要删）。')
    }
    if ($all -match 'LNK1104|cannot open file') {
        [void]$advice.Add('exe 被占用：关掉正在运行的 CodenameEngine.exe 再编。')
    }
    if ($all -match 'lime\.ndll|Could not load lime|lime\.n') {
        [void]$advice.Add('lime 原生库缺失或架构不符：用 Build.bat -RebuildLime 重建（需要 VS C++ 工具链）。')
    }
    if ($all -match 'cl\.exe|msvc|Visual Studio|vsvars') {
        [void]$advice.Add('缺 MSVC：安装 Visual Studio Build Tools 的"使用 C++ 的桌面开发"工作负载。')
    }
    if ($all -match 'out of memory|OutOfMemory') {
        [void]$advice.Add('内存不足：关掉其它程序，或用 -Clean 清掉 export 里的中间产物重编。')
    }
    if ($advice.Count -eq 0) {
        [void]$advice.Add('看上面第一个 source\....hx:行号，那通常就是根因。')
    }

    Write-Host ''
    Write-Host '--- what to do ------------------------------------------------' -ForegroundColor Yellow
    foreach ($line in $advice) { Write-Host " * $line" -ForegroundColor Yellow }
    Write-Host '---------------------------------------------------------------' -ForegroundColor Yellow
}

# ---------------------------------------------------------------- main
try {
    try {
        [Console]::OutputEncoding = [Text.Encoding]::UTF8
        $OutputEncoding = [Text.Encoding]::UTF8
    } catch { }

    $script:RepoRoot = Resolve-RepoRoot
    if (-not $ToolchainDir) { $script:ToolchainDir = Join-Path $PSScriptRoot 'toolchain' }
    if (-not $DryRun -and -not (Test-Path -LiteralPath $script:ToolchainDir)) {
        New-Item -ItemType Directory -Path $script:ToolchainDir -Force | Out-Null
    }
    $logDir = Join-Path $PSScriptRoot 'logs'
    if (-not $DryRun) {
        if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        $script:LogFile = Join-Path $logDir ("build-" + (Get-Date).ToString('yyyyMMdd-HHmmss') + ".log")
    }

    # the build has to run from the repo root: that is where project.xml and the
    # local .haxelib repository are found
    Set-Location -LiteralPath $script:RepoRoot

    Write-Host ''
    Write-Host ' Codename Engine - one click Windows build ' -ForegroundColor Black -BackgroundColor Cyan
    Write-Host ''
    Write-Log "repository : $script:RepoRoot"
    Write-Log "log        : $script:LogFile"
    if ($DryRun) { Write-Log 'DRY RUN - nothing will be changed' 'DRY' }

    # 1 - toolchain ---------------------------------------------------------
    Write-Step '1/6 toolchain (Haxe + Neko)'

    if ($DownloadToolchain) {
        $script:HaxePath = Install-HaxeToolchain
    } else {
        $script:HaxePath = Find-HaxeHome
        if (-not $script:HaxePath) { $script:HaxePath = Install-HaxeToolchain }
    }

    $script:NekoPath = Find-NekoHome
    if (-not $script:NekoPath) { $script:NekoPath = Install-NekoToolchain }

    if ($script:HaxePath -and -not $DryRun) { $env:Path = "$script:HaxePath;$env:Path" }
    if ($script:NekoPath -and -not $DryRun) { $env:Path = "$script:NekoPath;$env:Path" }

    if (-not $DryRun) {
        $haxeExe = Join-Path $script:HaxePath 'haxe.exe'
        $version = Get-HaxeVersionOf $haxeExe
        if (-not $version) { throw "haxe.exe at $haxeExe does not run - delete tools\lazy-build\toolchain and try again" }
        Write-Log "haxe --version -> $version" 'OK'
    }

    # 2 - libraries ---------------------------------------------------------
    Write-Step '2/6 libraries (repository-local .haxelib)'
    Initialize-HaxelibRepository

    # 3 - native library ----------------------------------------------------
    Write-Step '3/6 lime native library (lime.ndll)'
    $limeNdll = Get-LimeNativePath
    if ($RebuildLime -or -not $limeNdll) {
        if ($RebuildLime) {
            Write-Log 'rebuilding lime native by request' 'WARN'
        } else {
            Write-Log 'lime.ndll for Windows64 is missing - it has to be compiled' 'WARN'
        }
        [void](Get-VisualStudioOrInstall)
        [void](Invoke-Tool -FilePath (Get-HaxelibExe) `
                -Arguments @('run', 'lime', 'rebuild', 'windows', '-64') -Label 'lime rebuild windows')
        $limeNdll = Get-LimeNativePath
        if ($limeNdll) { Write-Log "lime.ndll ready: $limeNdll" 'OK' }
        else { Write-Log 'lime.ndll is still missing - the C++ build will most likely fail' 'WARN' }
    } else {
        Write-Log "lime.ndll present: $limeNdll" 'OK'
    }

    # 4 - MSVC --------------------------------------------------------------
    Write-Step '4/6 C++ toolchain (MSVC)'
    [void](Get-VisualStudioOrInstall)

    # 5 - build -------------------------------------------------------------
    Write-Step '5/6 building'
    Stop-RunningEngine

    $configuration = if ($Debug) { 'debug' } else { 'release' }
    $buildArgs = @('run', 'lime', 'build', 'windows', '-nocolor')
    if ($Debug) { $buildArgs += '-debug' }
    if ($Clean) { $buildArgs += '-clean' }

    Write-Log "configuration: $configuration$(if ($Clean) { ' (clean)' })"
    $started = Get-Date
    $code = Invoke-Tool -FilePath (Get-HaxelibExe) -Arguments $buildArgs `
        -Label 'lime build windows' -AllowFail

    # 6 - verify ------------------------------------------------------------
    Write-Step '6/6 result'
    $exe = Join-Path $script:RepoRoot "export\$configuration\windows\bin\CodenameEngine.exe"

    if ($code -ne 0) {
        Write-Log "build failed (exit $code)" 'ERR'
        Get-ErrorAdvice -LogPath $script:LogFile
        exit $code
    }

    if ($DryRun) {
        Write-Log "[dryrun] would verify $exe" 'DRY'
        Write-Log 'DRY RUN finished - nothing was built' 'DRY'
        exit 0
    }

    if (-not (Test-Path -LiteralPath $exe)) {
        Write-Log "the build reported success but the exe is missing: $exe" 'ERR'
        Get-ErrorAdvice -LogPath $script:LogFile
        exit 1
    }

    $item = Get-Item -LiteralPath $exe
    Write-Log "exe    : $exe" 'OK'
    Write-Log ("size   : {0:N1} MB" -f ($item.Length / 1MB)) 'OK'
    Write-Log "built  : $($item.LastWriteTime)" 'OK'
    if ($item.LastWriteTime -lt $started.AddSeconds(-5)) {
        Write-Log 'the exe is older than this run - the build was a no-op, try -Clean' 'WARN'
    }

    $warnings = 0
    if (Test-Path -LiteralPath $script:LogFile) {
        $warnings = @(Get-Content -LiteralPath $script:LogFile | Where-Object { $_ -match 'WARNING' }).Count
    }
    Write-Log "warnings: $warnings (the deprecated-API noise from upstream code is normal)" 'INFO'

    Write-Host ''
    Write-Host ' BUILD OK ' -ForegroundColor Black -BackgroundColor Green
    Write-Host " run: $exe" -ForegroundColor Green
    Write-Host " log: $script:LogFile" -ForegroundColor DarkGray
    exit 0
} catch {
    Write-Log "FAILED: $($_.Exception.Message)" 'ERR'
    if ($script:LogFile) { Write-Host " log: $script:LogFile" -ForegroundColor DarkGray }
    Write-Host ''
    Write-Host ' BUILD FAILED ' -ForegroundColor White -BackgroundColor DarkRed
    exit 1
}

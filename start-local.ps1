[CmdletBinding()]
param(
    [string]$Url = "https://localhost",
    [string]$Title = "WordPress Plugin Tester",
    [string]$AdminUser = "admin",
    [string]$AdminEmail = "admin@local.test",
    [int]$MaxAttempts = 30,
    [int]$RetrySeconds = 3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = $PSScriptRoot
$script:LocalhostCertificatesChanged = $false
$script:LogDirectory = Join-Path $RepoRoot "logs"
$script:LogTimestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$script:LogFilePath = Join-Path $script:LogDirectory ("start-local-$script:LogTimestamp.log")
$script:DockerStatusLogFilePath = Join-Path $script:LogDirectory ("docker-compose-$script:LogTimestamp-status.log")
$script:DockerLogsFilePath = Join-Path $script:LogDirectory ("docker-compose-$script:LogTimestamp.log")
$script:TranscriptStarted = $false
Set-Location $RepoRoot

if (-not (Test-Path -LiteralPath $script:LogDirectory)) {
    [void](New-Item -ItemType Directory -Path $script:LogDirectory -Force)
}

try {
    Start-Transcript -Path $script:LogFilePath -Force -IncludeInvocationHeader | Out-Null
    $script:TranscriptStarted = $true
    Write-Host "Script log file: $script:LogFilePath"
} catch {
    Write-Warning "Unable to start transcript logging: $($_.Exception.Message)"
}

function Import-DotEnv {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "No .env file found at $Path. Continuing with existing environment variables."
        return
    }

    Write-Host "Loading local environment from .env..."

    $lineNumber = 0
    foreach ($rawLine in Get-Content -LiteralPath $Path) {
        $lineNumber++
        $line = $rawLine.Trim()

        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) {
            continue
        }

        $match = [regex]::Match($line, "^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$")
        if (-not $match.Success) {
            Write-Warning "Skipping unrecognized .env line $lineNumber."
            continue
        }

        $name = $match.Groups[1].Value
        $value = $match.Groups[2].Value.Trim()

        if (
            ($value.Length -ge 2) -and
            (
                ($value.StartsWith('"') -and $value.EndsWith('"')) -or
                ($value.StartsWith("'") -and $value.EndsWith("'"))
            )
        ) {
            $value = $value.Substring(1, $value.Length - 2)
        }

        $existingValue = [Environment]::GetEnvironmentVariable($name, "Process")
        if ([string]::IsNullOrEmpty($existingValue)) {
            [Environment]::SetEnvironmentVariable($name, $value, "Process")
        }
    }
}

function Invoke-ProcessCapture {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FileName
    $startInfo.WorkingDirectory = $RepoRoot
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $argumentListProperty = $startInfo.GetType().GetProperty("ArgumentList")
    if ($null -ne $argumentListProperty) {
        foreach ($argument in $Arguments) {
            [void]$startInfo.ArgumentList.Add($argument)
        }
    } else {
        $startInfo.Arguments = Join-ProcessArguments -Arguments $Arguments
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo

    [void]$process.Start()
    $standardOutput = $process.StandardOutput.ReadToEnd()
    $standardError = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    $combinedOutput = @(
        $standardOutput.Trim()
        $standardError.Trim()
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Output = ($combinedOutput -join [Environment]::NewLine)
    }
}

function Invoke-DockerCapture {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    Invoke-ProcessCapture -FileName "docker" -Arguments $Arguments
}

function Join-ProcessArguments {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $quotedArguments = foreach ($argument in $Arguments) {
        if ($argument -notmatch '[\s"]') {
            $argument
            continue
        }

        $builder = [System.Text.StringBuilder]::new()
        [void]$builder.Append('"')
        $backslashCount = 0

        foreach ($character in $argument.ToCharArray()) {
            if ($character -eq '\') {
                $backslashCount++
                continue
            }

            if ($character -eq '"') {
                [void]$builder.Append('\' * (($backslashCount * 2) + 1))
                [void]$builder.Append('"')
                $backslashCount = 0
                continue
            }

            if ($backslashCount -gt 0) {
                [void]$builder.Append('\' * $backslashCount)
                $backslashCount = 0
            }

            [void]$builder.Append($character)
        }

        if ($backslashCount -gt 0) {
            [void]$builder.Append('\' * ($backslashCount * 2))
        }

        [void]$builder.Append('"')
        $builder.ToString()
    }

    $quotedArguments -join " "
}

function Write-LogFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Title,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$Result
    )

    $content = @(
        "# $Title"
        "Timestamp: $(Get-Date -Format o)"
        "ExitCode: $($Result.ExitCode)"
        ""
        $Result.Output
    )

    Set-Content -LiteralPath $Path -Value ($content -join [Environment]::NewLine) -Encoding UTF8
}

function Export-DockerDiagnostics {
    if (-not (Test-CommandAvailable -Name "docker")) {
        Write-Warning "Docker is not available; skipping Docker log capture."
        return
    }

    Write-Host "Capturing Docker Compose status: $script:DockerStatusLogFilePath"
    $statusResult = Invoke-DockerCapture -Arguments @("compose", "ps", "--all")
    Write-LogFile -Path $script:DockerStatusLogFilePath -Title "Docker Compose status" -Result $statusResult

    Write-Host "Capturing Docker Compose logs: $script:DockerLogsFilePath"
    $logsResult = Invoke-DockerCapture -Arguments @("compose", "logs", "--no-color", "--timestamps")
    Write-LogFile -Path $script:DockerLogsFilePath -Title "Docker Compose logs" -Result $logsResult
}

function Invoke-WpCliCapture {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$WpArguments
    )

    $dockerArguments = @(
        "compose",
        "run",
        "--rm",
        "-T",
        "--no-deps",
        "--user",
        "33:33",
        "-e",
        "HOME=/tmp",
        "wpcli"
    ) + $WpArguments

    Invoke-DockerCapture -Arguments $dockerArguments
}

function Ensure-ElementorPlugin {
    Write-Host "Ensuring Elementor is installed and active..."

    $installedResult = Invoke-WpCliCapture -WpArguments @("wp", "--url=$Url", "plugin", "is-installed", "elementor")

    if ($installedResult.ExitCode -ne 0) {
        Write-Host "Elementor is not installed. Installing and activating Elementor..."
        $installResult = Invoke-WpCliCapture -WpArguments @("wp", "--url=$Url", "plugin", "install", "elementor", "--activate")

        if ($installResult.ExitCode -ne 0) {
            Write-Warning "Elementor install/activation failed; startup will continue. Output: $($installResult.Output)"
            return
        }

        Write-Host "Elementor installed and activated."
        return
    }

    $activeResult = Invoke-WpCliCapture -WpArguments @("wp", "--url=$Url", "plugin", "is-active", "elementor")

    if ($activeResult.ExitCode -eq 0) {
        Write-Host "Elementor is already active."
        return
    }

    Write-Host "Elementor is installed but inactive. Activating Elementor..."
    $activateResult = Invoke-WpCliCapture -WpArguments @("wp", "--url=$Url", "plugin", "activate", "elementor")

    if ($activateResult.ExitCode -ne 0) {
        Write-Warning "Elementor activation failed; startup will continue. Output: $($activateResult.Output)"
        return
    }

    Write-Host "Elementor activated."
}

function Update-ProcessPath {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $wingetPackageRoot = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages"
    $wingetPackagePaths = @()

    if (Test-Path -LiteralPath $wingetPackageRoot) {
        $wingetPackagePaths = Get-ChildItem -LiteralPath $wingetPackageRoot -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { $_.FullName }
    }

    $commonToolPaths = @(
        (Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links"),
        (Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps"),
        "C:\Program Files\Docker\Docker\resources\bin",
        "C:\Program Files\Git\cmd",
        "C:\Program Files\nodejs"
    )

    $pathEntries = @($machinePath, $userPath) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_ -split ";" } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    $pathEntries += $commonToolPaths | Where-Object { Test-Path -LiteralPath $_ }
    $pathEntries += $wingetPackagePaths
    $env:Path = ($pathEntries | Select-Object -Unique) -join ";"
}

function Test-CommandAvailable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Test-LaragonInstalled {
    if (Test-CommandAvailable -Name "laragon") {
        return $true
    }

    $candidatePaths = @(
        "C:\laragon\laragon.exe",
        "C:\Program Files\Laragon\laragon.exe",
        "C:\Program Files (x86)\Laragon\laragon.exe",
        (Join-Path $env:LOCALAPPDATA "Programs\Laragon\laragon.exe")
    )

    foreach ($candidatePath in $candidatePaths) {
        if (Test-Path -LiteralPath $candidatePath) {
            return $true
        }
    }

    return $false
}

function Show-LaragonInstallAdvice {
    Write-Host "Checking Laragon installation..."

    if (Test-LaragonInstalled) {
        Write-Host "Laragon is installed."
        return
    }

    Write-Warning "Laragon was not found. Install Laragon for a local Windows web stack: https://laragon.org/download/"
}

function Assert-WingetAvailable {
    if (-not (Test-CommandAvailable -Name "winget")) {
        throw "winget is required to install local prerequisites. Install App Installer from Microsoft Store, then run this script again."
    }
}

function Install-WingetPackageIfMissing {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DisplayName,

        [Parameter(Mandatory = $true)]
        [string]$PackageId,

        [Parameter(Mandatory = $true)]
        [string]$CommandName
    )

    if (Test-CommandAvailable -Name $CommandName) {
        Write-Host "$DisplayName is installed."
        return
    }

    Assert-WingetAvailable

    Write-Host "$DisplayName was not found. Installing with winget..."
    $installResult = Invoke-ProcessCapture -FileName "winget" -Arguments @(
        "install",
        "-e",
        "--id",
        $PackageId,
        "--accept-package-agreements",
        "--accept-source-agreements",
        "--disable-interactivity"
    )

    if (-not [string]::IsNullOrWhiteSpace($installResult.Output)) {
        Write-Host $installResult.Output
    }

    if ($installResult.ExitCode -ne 0) {
        throw "$DisplayName install failed with exit code $($installResult.ExitCode)."
    }

    Update-ProcessPath

    if (-not (Test-CommandAvailable -Name $CommandName)) {
        throw "$DisplayName installed, but '$CommandName' is not available in this PowerShell session. Restart PowerShell and run this script again."
    }
}

function Install-UbuntuWslIfMissing {
    if (-not (Test-CommandAvailable -Name "wsl")) {
        throw "wsl.exe was not found. Enable WSL on Windows, then run this script again."
    }

    $listResult = Invoke-ProcessCapture -FileName "wsl" -Arguments @("--list", "--quiet")
    $distributions = @()

    if ($listResult.ExitCode -eq 0) {
        $distributions = $listResult.Output.Replace("`0", "") -split "\r?\n" |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    }

    if ($distributions -contains "Ubuntu") {
        Write-Host "WSL Ubuntu is installed."
        return
    }

    Write-Host "WSL Ubuntu was not found. Installing Ubuntu..."
    $installResult = Invoke-ProcessCapture -FileName "wsl" -Arguments @("--install", "-d", "Ubuntu")

    if (-not [string]::IsNullOrWhiteSpace($installResult.Output)) {
        Write-Host $installResult.Output
    }

    if ($installResult.ExitCode -ne 0) {
        throw "Ubuntu WSL install failed with exit code $($installResult.ExitCode). You may need to run PowerShell as Administrator."
    }

    Write-Warning "Ubuntu WSL was installed. If Windows asks for a reboot or Ubuntu first-run setup, complete that before using Docker."
}

function Get-MkcertCaRoot {
    $caRootResult = Invoke-ProcessCapture -FileName "mkcert" -Arguments @("-CAROOT")

    if ($caRootResult.ExitCode -ne 0) {
        throw "mkcert -CAROOT failed with exit code $($caRootResult.ExitCode)."
    }

    $candidatePaths = $caRootResult.Output -split "\r?\n" |
        ForEach-Object { $_.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($candidatePath in $candidatePaths) {
        if (Test-Path -LiteralPath $candidatePath) {
            return $candidatePath
        }
    }

    throw "mkcert did not return a usable CA root path."
}

function Test-MkcertRootInstalled {
    try {
        $caRootPath = Get-MkcertCaRoot
        $rootCertificatePath = Join-Path $caRootPath "rootCA.pem"

        if (-not (Test-Path -LiteralPath $rootCertificatePath)) {
            return $false
        }

        $rootCertificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($rootCertificatePath)
        $thumbprint = $rootCertificate.Thumbprint

        (Test-Path -LiteralPath "Cert:\CurrentUser\Root\$thumbprint") -or
            (Test-Path -LiteralPath "Cert:\LocalMachine\Root\$thumbprint")
    } catch {
        $false
    }
}

function Install-MkcertTrust {
    if (Test-MkcertRootInstalled) {
        Write-Host "mkcert local CA is trusted."
        return
    }

    Write-Host "Installing mkcert local CA..."
    $installResult = Invoke-ProcessCapture -FileName "mkcert" -Arguments @("-install")

    if (-not [string]::IsNullOrWhiteSpace($installResult.Output)) {
        Write-Host $installResult.Output
    }

    if ($installResult.ExitCode -ne 0) {
        throw "mkcert -install failed with exit code $($installResult.ExitCode)."
    }
}

function Test-LocalhostCertificate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CertificatePath,

        [Parameter(Mandatory = $true)]
        [string]$KeyPath
    )

    if (
        -not (Test-Path -LiteralPath $CertificatePath) -or
        -not (Test-Path -LiteralPath $KeyPath) -or
        (Get-Item -LiteralPath $CertificatePath).Length -le 0 -or
        (Get-Item -LiteralPath $KeyPath).Length -le 0
    ) {
        return $false
    }

    try {
        $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($CertificatePath)

        if ($certificate.NotAfter -le (Get-Date).AddDays(1)) {
            return $false
        }

        $extensionText = ($certificate.Extensions | ForEach-Object { $_.Format($false) }) -join "`n"
        $caRootPath = Get-MkcertCaRoot
        $rootCertificatePath = Join-Path $caRootPath "rootCA.pem"
        $rootCertificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($rootCertificatePath)

        ($extensionText -match "DNS Name=localhost") -and
            ($extensionText -match "IP Address=127\.0\.0\.1") -and
            ($extensionText -match "0000:0000:0000:0000:0000:0000:0000:0001") -and
            ($certificate.Issuer -eq $rootCertificate.Subject)
    } catch {
        $false
    }
}

function Initialize-LocalhostCertificates {
    $certDirectory = Join-Path $RepoRoot "docker\certs"
    $certificatePath = Join-Path $certDirectory "localhost.pem"
    $keyPath = Join-Path $certDirectory "localhost-key.pem"

    if (-not (Test-Path -LiteralPath $certDirectory)) {
        [void](New-Item -ItemType Directory -Path $certDirectory -Force)
    }

    Install-MkcertTrust

    if (Test-LocalhostCertificate -CertificatePath $certificatePath -KeyPath $keyPath) {
        Write-Host "Localhost HTTPS certificates are present."
        return
    }

    Write-Host "Generating localhost HTTPS certificates..."
    $certificateResult = Invoke-ProcessCapture -FileName "mkcert" -Arguments @(
        "-cert-file",
        $certificatePath,
        "-key-file",
        $keyPath,
        "localhost",
        "127.0.0.1",
        "::1"
    )

    if (-not [string]::IsNullOrWhiteSpace($certificateResult.Output)) {
        Write-Host $certificateResult.Output
    }

    if ($certificateResult.ExitCode -ne 0) {
        throw "mkcert certificate generation failed with exit code $($certificateResult.ExitCode)."
    }

    if (-not (Test-LocalhostCertificate -CertificatePath $certificatePath -KeyPath $keyPath)) {
        throw "Generated localhost certificates could not be verified."
    }

    $script:LocalhostCertificatesChanged = $true
}

function Initialize-Prerequisites {
    Write-Host "Checking local prerequisites..."
    Update-ProcessPath

    Install-UbuntuWslIfMissing
    Install-WingetPackageIfMissing -DisplayName "Docker Desktop" -PackageId "Docker.DockerDesktop" -CommandName "docker"
    Install-WingetPackageIfMissing -DisplayName "Git" -PackageId "Git.Git" -CommandName "git"
    Install-WingetPackageIfMissing -DisplayName "Node.js LTS" -PackageId "OpenJS.NodeJS.LTS" -CommandName "node"

    if (-not (Test-CommandAvailable -Name "npm")) {
        throw "Node.js LTS is installed, but npm is not available. Restart PowerShell and run this script again."
    }

    Write-Host "npm is installed."

    Install-WingetPackageIfMissing -DisplayName "mkcert" -PackageId "FiloSottile.mkcert" -CommandName "mkcert"
    Initialize-LocalhostCertificates
}

function Get-WordPressInstallStatus {
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $result = Invoke-WpCliCapture -WpArguments @("wp", "--url=$Url", "core", "is-installed")

        if ($result.ExitCode -eq 0) {
            return "Installed"
        }

        $message = $result.Output
        $isTransient = (
            $message -match "Error establishing a database connection" -or
            $message -match "Connection refused" -or
            $message -match "Could not connect" -or
            $message -match "does not seem to be a WordPress installation" -or
            $message -match "No such container" -or
            $message -match "service .* is not running"
        )

        $isDockerFailure = (
            $message -match "no configuration file provided" -or
            $message -match "unknown flag" -or
            $message -match "Cannot connect to the Docker daemon" -or
            $message -match "permission denied"
        )

        if ($result.ExitCode -eq 1 -and -not $isTransient -and -not $isDockerFailure) {
            return "NotInstalled"
        }

        if ($attempt -lt $MaxAttempts) {
            Write-Host "WordPress is not ready yet. Retrying in $RetrySeconds seconds... ($attempt/$MaxAttempts)"
            Start-Sleep -Seconds $RetrySeconds
            continue
        }

        throw "Timed out waiting for WordPress/WP-CLI to become ready. Last output: $message"
    }
}

try {
    Initialize-Prerequisites
    Import-DotEnv -Path (Join-Path $RepoRoot ".env")

    Write-Host "Starting Docker stack..."
    $composeUpResult = Invoke-DockerCapture -Arguments @("compose", "up", "-d")
    if (-not [string]::IsNullOrWhiteSpace($composeUpResult.Output)) {
        Write-Host $composeUpResult.Output
    }

    if ($composeUpResult.ExitCode -ne 0) {
        throw "docker compose up -d failed with exit code $($composeUpResult.ExitCode)."
    }

    if ($script:LocalhostCertificatesChanged) {
        Write-Host "Restarting Caddy so it serves the regenerated HTTPS certificate..."
        $caddyRestartResult = Invoke-DockerCapture -Arguments @("compose", "restart", "caddy")
        if (-not [string]::IsNullOrWhiteSpace($caddyRestartResult.Output)) {
            Write-Host $caddyRestartResult.Output
        }

        if ($caddyRestartResult.ExitCode -ne 0) {
            throw "docker compose restart caddy failed with exit code $($caddyRestartResult.ExitCode)."
        }
    }

    Write-Host "Checking WordPress install status..."
    $status = Get-WordPressInstallStatus

    if ($status -eq "Installed") {
        Write-Host "WordPress is already installed. Skipping core install."
        Ensure-ElementorPlugin
        Write-Host "Web project URL: $Url"
        exit 0
    }

    $adminPassword = [Environment]::GetEnvironmentVariable("WP_ADMIN_PASSWORD", "Process")
    if ([string]::IsNullOrWhiteSpace($adminPassword)) {
        throw "WP_ADMIN_PASSWORD is required for first-time install. Add it to .env or set it in the current PowerShell session."
    }

    Write-Host "Installing WordPress core..."
    $installResult = Invoke-WpCliCapture -WpArguments @(
        "wp",
        "core",
        "install",
        "--url=$Url",
        "--title=$Title",
        "--admin_user=$AdminUser",
        "--admin_password=$adminPassword",
        "--admin_email=$AdminEmail",
        "--skip-email"
    )

    if ($installResult.ExitCode -ne 0) {
        throw "wp core install failed. Output: $($installResult.Output)"
    }

    Write-Host "WordPress installed successfully."
    Ensure-ElementorPlugin
    Write-Host "Admin user: $AdminUser"
    Write-Host "Web project URL: $Url"
} catch {
    Write-Host "Startup failed: $($_.Exception.Message)"
    Write-Error $_
    throw
} finally {
    try {
        Export-DockerDiagnostics
    } catch {
        Write-Warning "Unable to capture Docker diagnostics: $($_.Exception.Message)"
    }

    try {
        Show-LaragonInstallAdvice
    } catch {
        Write-Warning "Unable to check Laragon installation: $($_.Exception.Message)"
    }

    if ($script:TranscriptStarted) {
        try {
            Stop-Transcript | Out-Null
        } catch {
            # Transcript may already be stopped or unavailable in some environments.
        }
    }
}

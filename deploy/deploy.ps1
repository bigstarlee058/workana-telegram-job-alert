param(
    [Parameter(Mandatory = $true)][string]$HostName,
    [Parameter(Mandatory = $true)][string]$IdentityFile,
    [string]$UserName = 'root',
    [string]$EnvFile = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $EnvFile) { $EnvFile = Join-Path $repoRoot '.env' }
if (-not (Test-Path -LiteralPath $IdentityFile -PathType Leaf)) { throw 'SSH key not found.' }
if (-not (Test-Path -LiteralPath $EnvFile -PathType Leaf)) { throw 'Bot configuration file not found.' }
$destination = "${UserName}@${HostName}"
$sshArguments = @('-i', $IdentityFile, '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=20', '-o', 'ConnectionAttempts=3')
$archive = Join-Path ([System.IO.Path]::GetTempPath()) ("workana-source-" + [guid]::NewGuid() + '.tar')

try {
    & tar -cf $archive -C $repoRoot bot.py config.py storage.py workana.py locale_en.py requirements.txt deploy
    if ($LASTEXITCODE -ne 0) { throw 'Source archive failed.' }
    $stageOutput = & ssh @sshArguments $destination 'mktemp -d /tmp/workana-bot-deploy.XXXXXX'
    if ($LASTEXITCODE -ne 0) { throw 'Could not connect to the VPS.' }
    $remoteStage = ($stageOutput -join "`n").Trim()
    if ($remoteStage -notmatch '^/tmp/workana-bot-deploy\.[A-Za-z0-9]+$') {
        throw 'Could not create a private staging directory on the VPS.'
    }
    & scp @sshArguments $archive "${destination}:$remoteStage/source.tar"
    if ($LASTEXITCODE -ne 0) { throw 'Source upload failed.' }
    & scp @sshArguments $EnvFile "${destination}:$remoteStage/settings.env"
    if ($LASTEXITCODE -ne 0) { throw 'Configuration upload failed.' }
    & scp @sshArguments (Join-Path $PSScriptRoot 'deploy.sh') "${destination}:$remoteStage/deploy.sh"
    if ($LASTEXITCODE -ne 0) { throw 'Deployment script upload failed.' }
    & ssh @sshArguments $destination "test -s /etc/workana-bot.env || install -m 600 $remoteStage/settings.env /etc/workana-bot.env"
    if ($LASTEXITCODE -ne 0) { throw 'Could not install the initial configuration.' }
    & ssh @sshArguments $destination "bash $remoteStage/deploy.sh $remoteStage/source.tar"
    if ($LASTEXITCODE -ne 0) { throw 'Deployment failed. The previous release remains available; inspect the reported check.' }
}
finally {
    if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive }
}

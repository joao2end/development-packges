# Gera Instalar-Ambiente.exe a partir de instalar-ambiente.ps1 (+ icones.ps1) usando o modulo ps2exe.
$ErrorActionPreference = 'Stop'
if (-not (Get-Module -ListAvailable ps2exe)) {
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
    Install-Module ps2exe -Scope CurrentUser -Force
}

# Junta icones + script principal num unico arquivo temporario
$tmp = Join-Path $env:TEMP 'instalar-ambiente-build.ps1'
$conteudo = (Get-Content "$PSScriptRoot\icones.ps1" -Raw) + "`r`n" + (Get-Content "$PSScriptRoot\instalar-ambiente.ps1" -Raw)
[IO.File]::WriteAllText($tmp, $conteudo, (New-Object Text.UTF8Encoding($true)))

Invoke-ps2exe -inputFile $tmp -outputFile "$PSScriptRoot\Instalar-Ambiente.exe" `
              -requireAdmin -noConsole -STA -title 'Instalador do Ambiente de Desenvolvimento'
Remove-Item $tmp -Force -ErrorAction SilentlyContinue
Write-Host 'Gerado: Instalar-Ambiente.exe'

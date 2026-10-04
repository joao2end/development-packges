# Gera dist\Instalar-Ambiente.exe, o unico executavel do projeto.
#
# O .exe embute tudo: o instalador (src\instalador.ps1), os icones (assets\icones),
# e o pacote do Gerenciador de Chaves SSH (pacotes\gerenciador-ssh: script + fontes + icone).
# Arquivos intermediarios ficam em build\ e sao apagados ao final.
#
# Uso:  powershell -ExecutionPolicy Bypass -File .\build.ps1

$ErrorActionPreference = 'Stop'
$raiz   = $PSScriptRoot
$src    = Join-Path $raiz 'src\instalador.ps1'
$pacote = Join-Path $raiz 'pacotes\gerenciador-ssh'
$icones = Join-Path $raiz 'assets\icones'
$dist   = Join-Path $raiz 'dist'
$tmp    = Join-Path $raiz 'build'
$saida  = Join-Path $dist 'Instalar-Ambiente.exe'

if (-not (Get-Module -ListAvailable ps2exe)) {
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
    Install-Module ps2exe -Scope CurrentUser -Force
}
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression.FileSystem

# ---------- Icones desenhados (quadrado arredondado indigo + glifo branco) ----------
function New-IconePng([scriptblock]$glifo, [int]$tamanho = 256) {
    $bmp = New-Object Drawing.Bitmap 256, 256
    $g = [Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'
    $gp = New-Object Drawing.Drawing2D.GraphicsPath
    $gp.AddArc(0, 0, 80, 80, 180, 90); $gp.AddArc(176, 0, 80, 80, 270, 90); $gp.AddArc(176, 176, 80, 80, 0, 90); $gp.AddArc(0, 176, 80, 80, 90, 90); $gp.CloseFigure()
    $g.FillPath((New-Object Drawing.SolidBrush ([Drawing.ColorTranslator]::FromHtml('#6366F1'))), $gp)
    $pen = New-Object Drawing.Pen ([Drawing.Color]::White), 24
    $pen.StartCap = 'Round'; $pen.EndCap = 'Round'; $pen.LineJoin = 'Round'
    & $glifo $g $pen
    $g.Dispose()
    if ($tamanho -ne 256) {
        $peq = New-Object Drawing.Bitmap $tamanho, $tamanho
        $g2 = [Drawing.Graphics]::FromImage($peq); $g2.InterpolationMode = 'HighQualityBicubic'; $g2.DrawImage($bmp, 0, 0, $tamanho, $tamanho); $g2.Dispose()
        $bmp.Dispose(); $bmp = $peq
    }
    $ms = New-Object IO.MemoryStream; $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    return $ms.ToArray()
}

function Save-Ico([byte[]]$png, [string]$caminho) {
    $fs = [IO.File]::Create($caminho); $bw = New-Object IO.BinaryWriter $fs
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]1)
    $bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([uint16]1); $bw.Write([uint16]32)
    $bw.Write([uint32]$png.Length); $bw.Write([uint32]22); $bw.Write($png); $bw.Close()
}

$glifoChave = { param($g, $pen)
    $g.DrawEllipse($pen, 40, 88, 72, 72); $g.DrawLine($pen, 112, 124, 208, 124); $g.DrawLine($pen, 176, 124, 176, 168); $g.DrawLine($pen, 208, 124, 208, 160) }
$glifoSeta = { param($g, $pen)
    $g.DrawLine($pen, 128, 52, 128, 160); $g.DrawLines($pen, [Drawing.Point[]]@((New-Object Drawing.Point 80, 116), (New-Object Drawing.Point 128, 164), (New-Object Drawing.Point 176, 116)))
    $g.DrawLine($pen, 68, 204, 188, 204) }

try {
    if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
    $stage = Join-Path $tmp 'pacote-ssh'
    [void](New-Item -ItemType Directory -Force $stage, $dist)

    # Icone do Gerenciador SSH: PNG do catalogo (assets) + .ico do atalho (dentro do pacote)
    $pngSsh = New-IconePng $glifoChave 256
    Save-Ico $pngSsh (Join-Path $stage 'gerenciador-ssh.ico')
    [IO.File]::WriteAllBytes((Join-Path $icones 'ssh.png'), (New-IconePng $glifoChave 128))
    $icoInstalador = Join-Path $tmp 'instalador.ico'
    Save-Ico (New-IconePng $glifoSeta 256) $icoInstalador

    # Pacote do Gerenciador SSH -> zip -> base64
    Copy-Item -Path (Join-Path $pacote '*') -Destination $stage -Recurse -Force
    $zip = Join-Path $tmp 'gerenciador-ssh.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip)
    $pacoteB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($zip))

    # Dados embutidos + script do instalador num unico arquivo
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine('$script:IconesB64 = @{')
    Get-ChildItem $icones -Filter *.png | ForEach-Object {
        [void]$sb.AppendLine("    '$($_.BaseName)' = '$([Convert]::ToBase64String([IO.File]::ReadAllBytes($_.FullName)))'")
    }
    [void]$sb.AppendLine('}')
    [void]$sb.AppendLine("`$script:PacoteSshB64 = '$pacoteB64'")
    [void]$sb.AppendLine((Get-Content $src -Raw))
    $completo = Join-Path $tmp 'instalador-completo.ps1'
    [IO.File]::WriteAllText($completo, $sb.ToString(), (New-Object Text.UTF8Encoding($true)))

    if (Test-Path $saida) {
        try { Remove-Item -LiteralPath $saida -Force } catch { throw "Nao foi possivel substituir $saida. Feche o instalador e tente novamente." }
    }
    Invoke-ps2exe -inputFile $completo -outputFile $saida -requireAdmin -noConsole -STA `
                  -iconFile $icoInstalador -title 'Instalador do Ambiente de Desenvolvimento'
}
finally {
    if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    Get-ChildItem $dist -Filter '*.win32manifest' -ErrorAction SilentlyContinue | Remove-Item -Force
}

# Garante que existe somente um executavel no projeto
$exes = @(Get-ChildItem $raiz -Recurse -Filter *.exe -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\\.git\\' })
if ($exes.Count -ne 1) { Write-Warning "Esperado 1 executavel, encontrados $($exes.Count):"; $exes | ForEach-Object { Write-Warning $_.FullName } }
Write-Host ("Gerado: {0} ({1:N0} KB)" -f $saida, ((Get-Item $saida).Length / 1KB))

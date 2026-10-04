# Gera Gerenciador-SSH.exe (com icone) a partir de gerenciador-ssh.ps1 usando o modulo ps2exe.
# A pasta "fontes" (Open Sans / Fira Code) deve ficar ao lado do .exe.
$ErrorActionPreference = 'Stop'
if (-not (Get-Module -ListAvailable ps2exe)) {
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
    Install-Module ps2exe -Scope CurrentUser -Force
}

# Icone: quadrado arredondado indigo com uma chave branca (PNG 256px dentro de um .ico)
Add-Type -AssemblyName System.Drawing
$bmp = New-Object Drawing.Bitmap 256, 256
$g = [Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'
$gp = New-Object Drawing.Drawing2D.GraphicsPath
$gp.AddArc(0, 0, 80, 80, 180, 90); $gp.AddArc(176, 0, 80, 80, 270, 90); $gp.AddArc(176, 176, 80, 80, 0, 90); $gp.AddArc(0, 176, 80, 80, 90, 90); $gp.CloseFigure()
$g.FillPath((New-Object Drawing.SolidBrush ([Drawing.ColorTranslator]::FromHtml('#6366F1'))), $gp)
$pen = New-Object Drawing.Pen ([Drawing.Color]::White), 24
$g.DrawEllipse($pen, 40, 88, 72, 72); $g.DrawLine($pen, 112, 124, 208, 124); $g.DrawLine($pen, 176, 124, 176, 168); $g.DrawLine($pen, 208, 124, 208, 160)
$g.Dispose()
$ms = New-Object IO.MemoryStream; $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png); $png = $ms.ToArray()
$ico = "$PSScriptRoot\gerenciador-ssh.ico"
$fs = [IO.File]::Create($ico); $bw = New-Object IO.BinaryWriter $fs
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]1)
$bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([uint16]1); $bw.Write([uint16]32)
$bw.Write([uint32]$png.Length); $bw.Write([uint32]22); $bw.Write($png); $bw.Close()

Invoke-ps2exe -inputFile "$PSScriptRoot\gerenciador-ssh.ps1" -outputFile "$PSScriptRoot\Gerenciador-SSH.exe" `
              -noConsole -STA -iconFile $ico -title 'Gerenciador de Chaves SSH'
Write-Host 'Gerado: Gerenciador-SSH.exe'

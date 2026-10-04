# Instalador do ambiente de desenvolvimento: interface moderna (WPF) com icones, selecao, progresso e log.

$ErrorActionPreference = 'Continue'

# Icones e pacote do Gerenciador SSH: no .exe o build.ps1 embute $script:IconesB64 e $script:PacoteSshB64.
# Rodando o .ps1 direto, os icones sao lidos de assets\icones.
if (-not $script:IconesB64 -and $PSScriptRoot) {
    $dirIcones = Join-Path $PSScriptRoot '..\assets\icones'
    if (Test-Path $dirIcones) {
        $script:IconesB64 = @{}
        Get-ChildItem $dirIcones -Filter *.png | ForEach-Object { $script:IconesB64[$_.BaseName] = [Convert]::ToBase64String([IO.File]::ReadAllBytes($_.FullName)) }
    }
}

# ---------- Auto-elevacao ----------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $self = if ($PSCommandPath) { $PSCommandPath } else { [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName }
    if ($self -like '*.ps1') {
        Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -File `"$self`""
    } else {
        Start-Process $self -Verb RunAs
    }
    exit
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    [void][Windows.MessageBox]::Show('winget nao encontrado. Instale o "App Installer" pela Microsoft Store e tente novamente.', 'Erro', 'OK', 'Error')
    exit 1
}

# ---------- Catalogo ----------
# Tipo: winget | postgres | node | claude
$catalogo = @(
    @{ Grupo = 'Ferramentas base'; Nome = 'NVM for Windows'; Desc = 'Gerenciador de versoes do Node'; Icone = 'nvm'; Chave = 'nvm'; Tipo = 'winget'; Id = 'CoreyButler.NVMforWindows' },
    @{ Grupo = 'Ferramentas base'; Nome = 'Node.js'; Desc = 'Ultima versao, via NVM'; Icone = 'node'; Chave = 'node'; Deps = @('nvm'); Tipo = 'node' },
    @{ Grupo = 'Ferramentas base'; Nome = 'Python 3.13'; Desc = 'Versao estavel com suporte'; Icone = 'python'; Tipo = 'winget'; Id = 'Python.Python.3.13' },
    @{ Grupo = 'Ferramentas base'; Nome = 'Git'; Desc = 'Controle de versao'; Icone = 'git'; Chave = 'git'; Tipo = 'winget'; Id = 'Git.Git' },
    @{ Grupo = 'Ferramentas base'; Nome = 'Docker Desktop'; Desc = 'Containers'; Icone = 'docker'; Tipo = 'winget'; Id = 'Docker.DockerDesktop' },
    @{ Grupo = 'Mobile (Android, Flutter, React Native)'; Nome = 'JDK 17 (Temurin)'; Desc = 'Java para Android/React Native'; Icone = 'jdk'; Chave = 'jdk'; Tipo = 'jdk'; Id = 'EclipseAdoptium.Temurin.17.JDK' },
    @{ Grupo = 'Mobile (Android, Flutter, React Native)'; Nome = 'Android Studio'; Desc = 'IDE e emuladores'; Icone = 'androidstudio'; Tipo = 'winget'; Id = 'Google.AndroidStudio' },
    @{ Grupo = 'Mobile (Android, Flutter, React Native)'; Nome = 'Android SDK'; Desc = 'API 35/36 e ANDROID_HOME'; Icone = 'androidsdk'; Chave = 'androidsdk'; Deps = @('jdk'); Tipo = 'androidsdk' },
    @{ Grupo = 'Mobile (Android, Flutter, React Native)'; Nome = 'Flutter SDK'; Desc = 'Canal stable em C:\src\flutter'; Icone = 'flutter'; Deps = @('git', 'jdk', 'androidsdk'); Tipo = 'flutter' },
    @{ Grupo = 'Mobile (Android, Flutter, React Native)'; Nome = 'React Native'; Desc = 'Node + JDK 17 + Android SDK'; Icone = 'reactnative'; Deps = @('node', 'jdk', 'androidsdk'); Tipo = 'meta' },
    @{ Grupo = 'Ferramentas base'; Nome = 'GitHub CLI'; Desc = 'Comando gh para o GitHub'; Icone = 'ghcli'; Tipo = 'winget'; Id = 'GitHub.cli' },
    @{ Grupo = 'Ferramentas base'; Nome = 'AWS CLI'; Desc = 'Linha de comando da AWS'; Icone = 'aws'; Tipo = 'winget'; Id = 'Amazon.AWSCLI' },
    @{ Grupo = 'Editores e IA'; Nome = 'Visual Studio Code'; Desc = 'Editor de codigo'; Icone = 'vscode'; Tipo = 'winget'; Id = 'Microsoft.VisualStudioCode' },
    @{ Grupo = 'Editores e IA'; Nome = 'Cursor'; Desc = 'Editor com IA'; Icone = 'cursor'; Tipo = 'winget'; Id = 'Anysphere.Cursor' },
    @{ Grupo = 'Editores e IA'; Nome = 'Claude Code'; Desc = 'Instalador oficial'; Icone = 'claude'; Tipo = 'claude' },
    @{ Grupo = 'Editores e IA'; Nome = 'Graft'; Desc = 'Contexto de codigo para agentes (npm)'; Icone = 'graft'; Deps = @('node'); Tipo = 'npm'; Pacote = '@nanonets/graft' },
    @{ Grupo = 'Comunicacao e produtividade'; Nome = 'Slack'; Desc = 'Mensagens da equipe'; Icone = 'slack'; Tipo = 'winget'; Id = 'SlackTechnologies.Slack' },
    @{ Grupo = 'Comunicacao e produtividade'; Nome = 'Obsidian'; Desc = 'Notas em Markdown'; Icone = 'obsidian'; Tipo = 'winget'; Id = 'Obsidian.Obsidian' },
    @{ Grupo = 'Rede e acesso'; Nome = 'Gerenciador de Chaves SSH'; Desc = 'Varias contas Git, chaves ed25519'; Icone = 'ssh'; Deps = @('git'); Tipo = 'sshmanager' },
    @{ Grupo = 'Rede e acesso'; Nome = 'Pritunl Client'; Desc = 'Cliente VPN'; Icone = 'pritunl'; Tipo = 'winget'; Id = 'Pritunl.PritunlClient' },
    @{ Grupo = 'Bancos de dados'; Nome = 'PostgreSQL'; Desc = 'Servidor (v18, fallback v17)'; Icone = 'postgres'; Tipo = 'postgres' },
    @{ Grupo = 'Bancos de dados'; Nome = 'MongoDB Server'; Desc = 'Servidor MongoDB'; Icone = 'mongo'; Tipo = 'winget'; Id = 'MongoDB.Server' },
    @{ Grupo = 'Gerenciadores de banco'; Nome = 'DBeaver Community'; Desc = 'Postgres, Mongo e outros'; Icone = 'dbeaver'; Tipo = 'winget'; Id = 'DBeaver.DBeaver.Community' },
    @{ Grupo = 'Gerenciadores de banco'; Nome = 'MongoDB Compass'; Desc = 'Interface oficial do Mongo'; Icone = 'mongo'; Tipo = 'winget'; Id = 'MongoDB.Compass.Full' },
    @{ Grupo = 'Gerenciadores de banco'; Nome = 'pgAdmin 4'; Desc = 'Interface oficial do Postgres'; Icone = 'pgadmin'; Tipo = 'winget'; Id = 'PostgreSQL.pgAdmin' }
)

# ---------- Interface ----------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:shell="clr-namespace:System.Windows.Shell;assembly=PresentationFramework"
        Title="Instalador do Ambiente de Desenvolvimento" Width="1000" Height="780" MinWidth="760" MinHeight="600"
        WindowStartupLocation="CenterScreen" Background="#0F1115" FontFamily="Segoe UI" FontSize="13">
  <shell:WindowChrome.WindowChrome>
    <shell:WindowChrome CaptionHeight="36" ResizeBorderThickness="6" GlassFrameThickness="0" CornerRadius="0" UseAeroCaptionButtons="False"/>
  </shell:WindowChrome.WindowChrome>
  <Window.Resources>
    <!-- Scrollbar fina, estilo Cursor/VS Code -->
    <Style x:Key="ThumbStyle" TargetType="Thumb">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Thumb">
            <Border x:Name="t" Background="#3A3F4B" CornerRadius="4" Margin="2"/>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="t" Property="Background" Value="#555B6B"/></Trigger>
              <Trigger Property="IsDragging" Value="True"><Setter TargetName="t" Property="Background" Value="#6B7285"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="PageBtn" TargetType="RepeatButton">
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Width" Value="12"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource PageBtn}" Command="ScrollBar.PageUpCommand"/></Track.DecreaseRepeatButton>
                <Track.Thumb><Thumb Style="{StaticResource ThumbStyle}"/></Track.Thumb>
                <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource PageBtn}" Command="ScrollBar.PageDownCommand"/></Track.IncreaseRepeatButton>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/>
          <Setter Property="Height" Value="12"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="ScrollBar">
                <Grid Background="Transparent">
                  <Track x:Name="PART_Track" IsDirectionReversed="False">
                    <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource PageBtn}" Command="ScrollBar.PageLeftCommand"/></Track.DecreaseRepeatButton>
                    <Track.Thumb><Thumb Style="{StaticResource ThumbStyle}"/></Track.Thumb>
                    <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource PageBtn}" Command="ScrollBar.PageRightCommand"/></Track.IncreaseRepeatButton>
                  </Track>
                </Grid>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Trigger>
      </Style.Triggers>
    </Style>
    <!-- Botoes da barra de titulo -->
    <Style x:Key="TitleBtn" TargetType="Button">
      <Setter Property="Width" Value="46"/>
      <Setter Property="Foreground" Value="#C5C9D6"/>
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="shell:WindowChrome.IsHitTestVisibleInChrome" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="Transparent">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#262A33"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Background" Value="#262A33"/>
      <Setter Property="Padding" Value="18,9"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Border x:Name="raiz" BorderBrush="#2A2D37" BorderThickness="1">
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="36"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <Grid Grid.Row="0" Background="#0F1115">
      <TextBlock Text="Instalador do Ambiente de Desenvolvimento" Foreground="#8B90A0" FontSize="12"
                 VerticalAlignment="Center" HorizontalAlignment="Center"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <Button x:Name="btnMin" Content="&#xE921;" Style="{StaticResource TitleBtn}"/>
        <Button x:Name="btnMax" Content="&#xE922;" Style="{StaticResource TitleBtn}"/>
        <Button x:Name="btnClose" Content="&#xE8BB;" Style="{StaticResource TitleBtn}"/>
      </StackPanel>
    </Grid>

  <Grid Grid.Row="1" Margin="28,10,28,20">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <Grid Grid.Row="0" Margin="0,0,0,14">
      <StackPanel>
        <TextBlock Text="Ambiente de Desenvolvimento" Foreground="#F2F3F7" FontSize="26" FontWeight="Bold"/>
        <TextBlock Text="Escolha os programas e clique em Instalar." Foreground="#8B90A0" Margin="0,4,0,0"/>
      </StackPanel>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
        <TextBlock x:Name="lblContagem" Foreground="#8B90A0" VerticalAlignment="Center" Margin="0,0,14,0"/>
        <Button x:Name="btnTodos" Content="Marcar todos" Style="{StaticResource Btn}" Margin="0,0,8,0"/>
        <Button x:Name="btnNenhum" Content="Desmarcar" Style="{StaticResource Btn}"/>
      </StackPanel>
    </Grid>

    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" Margin="0,0,-8,0" Padding="0,0,8,0">
      <StackPanel x:Name="painel"/>
    </ScrollViewer>

    <StackPanel Grid.Row="2" Margin="0,14,0,0">
      <Grid Margin="0,0,0,12">
        <StackPanel x:Name="painelSenha" Orientation="Horizontal" Visibility="Collapsed" HorizontalAlignment="Left" VerticalAlignment="Center">
          <TextBlock Text="Senha do usuario postgres:" Foreground="#C5C9D6" VerticalAlignment="Center" Margin="0,0,10,0"/>
          <PasswordBox x:Name="txtSenha" Width="220" Padding="8,6" Background="#181B22" Foreground="White" BorderBrush="#2C313C" CaretBrush="White"/>
          <TextBlock Text="  (sem espacos ou aspas)" Foreground="#6B7080" VerticalAlignment="Center"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
          <Button x:Name="btnParar" Content="Parar" Style="{StaticResource Btn}" Visibility="Collapsed" Margin="0,0,8,0" Background="#7F1D1D"/>
          <Button x:Name="btnInstalar" Content="Instalar selecionados" Style="{StaticResource Btn}" Background="#6366F1" Padding="26,10"/>
        </StackPanel>
      </Grid>
      <Grid Margin="0,0,0,6">
        <TextBlock x:Name="lblStatus" Text="Aguardando." Foreground="#C5C9D6"/>
        <TextBlock x:Name="lblPct" Foreground="#8B90A0" HorizontalAlignment="Right"/>
      </Grid>
      <ProgressBar x:Name="barra" Height="8" Minimum="0" Maximum="1" Value="0" Foreground="#6366F1" Background="#232732" BorderThickness="0"/>
      <Expander Header="Detalhes (log)" Foreground="#8B90A0" Margin="0,10,0,0">
        <TextBox x:Name="txtLog" Height="150" IsReadOnly="True" VerticalScrollBarVisibility="Auto" TextWrapping="Wrap"
                 Background="#0A0C10" Foreground="#C5C9D6" BorderBrush="#232732" FontFamily="Consolas" FontSize="12" Padding="8" Margin="0,8,0,0"/>
      </Expander>
    </StackPanel>
  </Grid>
  </Grid>
  </Border>
</Window>
'@
$janela = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $xaml))
foreach ($n in 'raiz','btnMin','btnMax','btnClose','lblContagem','btnTodos','btnNenhum','painel','painelSenha','txtSenha','btnParar','btnInstalar','lblStatus','lblPct','barra','txtLog') {
    Set-Variable -Name $n -Value $janela.FindName($n)
}

# Barra de titulo propria (minimizar / maximizar / fechar)
$btnMin.Add_Click({ $janela.WindowState = 'Minimized' })
$btnMax.Add_Click({ $janela.WindowState = if ($janela.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' } })
$btnClose.Add_Click({ $janela.Close() })
$janela.Add_StateChanged({
    if ($janela.WindowState -eq 'Maximized') {
        $raiz.Margin = [Windows.SystemParameters]::WindowResizeBorderThickness   # evita cortar o conteudo ao maximizar
        $btnMax.Content = [string][char]0xE923
    } else {
        $raiz.Margin = New-Object Windows.Thickness(0)
        $btnMax.Content = [string][char]0xE922
    }
})

$conv = New-Object Windows.Media.BrushConverter
function Cor([string]$hex) { return $conv.ConvertFromString($hex) }

function New-Icone($chave, $nome) {
    if ($script:IconesB64 -and $script:IconesB64.ContainsKey($chave)) {
        $bi = New-Object Windows.Media.Imaging.BitmapImage
        $bi.BeginInit()
        $bi.StreamSource = New-Object IO.MemoryStream(, [Convert]::FromBase64String($script:IconesB64[$chave]))
        $bi.CacheOption = 'OnLoad'
        $bi.EndInit(); $bi.Freeze()
        $img = New-Object Windows.Controls.Image
        $img.Source = $bi; $img.Width = 36; $img.Height = 36
        [Windows.Media.RenderOptions]::SetBitmapScalingMode($img, 'HighQuality')
        return $img
    }
    # Sem icone: selo com as iniciais
    $b = New-Object Windows.Controls.Border
    $b.Width = 36; $b.Height = 36; $b.CornerRadius = 9; $b.Background = Cor '#3B3F52'
    $t = New-Object Windows.Controls.TextBlock
    $t.Text = ($nome -split ' ' | Select-Object -First 1).Substring(0, [Math]::Min(3, ($nome -split ' ')[0].Length)).ToUpper()
    $t.Foreground = Cor '#E6E8EE'; $t.FontWeight = 'Bold'; $t.FontSize = 11
    $t.HorizontalAlignment = 'Center'; $t.VerticalAlignment = 'Center'
    $b.Child = $t
    return $b
}

# ---------- Cartoes ----------
$cards = New-Object Collections.ArrayList
$wrapPorGrupo = @{}

function Update-Contagem {
    $sel = @($cards | Where-Object { $_.Check.IsChecked }).Count
    $lblContagem.Text = "$sel de $($cards.Count) selecionados"
    $pg = @($cards | Where-Object { $_.Check.IsChecked -and $_.Item.Tipo -eq 'postgres' }).Count -gt 0
    $painelSenha.Visibility = if ($pg) { 'Visible' } else { 'Collapsed' }
}

foreach ($item in $catalogo) {
    if (-not $wrapPorGrupo.ContainsKey($item.Grupo)) {
        $h = New-Object Windows.Controls.TextBlock
        $h.Text = $item.Grupo.ToUpper(); $h.Foreground = Cor '#7C82F5'; $h.FontSize = 11; $h.FontWeight = 'Bold'
        $h.Margin = '2,14,0,8'
        [void]$painel.Children.Add($h)
        $w = New-Object Windows.Controls.WrapPanel
        [void]$painel.Children.Add($w)
        $wrapPorGrupo[$item.Grupo] = $w
    }

    $borda = New-Object Windows.Controls.Border
    $borda.Width = 290; $borda.Height = 76; $borda.CornerRadius = 12; $borda.Margin = '0,0,12,12'
    $borda.Background = Cor '#181B22'; $borda.BorderThickness = 1.5; $borda.Cursor = 'Hand'

    $g = New-Object Windows.Controls.Grid
    $g.Margin = '14,0,14,0'
    foreach ($wdt in 'Auto', '*', 'Auto') {
        $cd = New-Object Windows.Controls.ColumnDefinition
        $cd.Width = [Windows.GridLength]::Auto
        if ($wdt -eq '*') { $cd.Width = New-Object Windows.GridLength(1, 'Star') }
        [void]$g.ColumnDefinitions.Add($cd)
    }

    $icone = New-Icone $item.Icone $item.Nome
    $icone.VerticalAlignment = 'Center'
    [Windows.Controls.Grid]::SetColumn($icone, 0)
    [void]$g.Children.Add($icone)

    $sp = New-Object Windows.Controls.StackPanel
    $sp.VerticalAlignment = 'Center'; $sp.Margin = '12,0,8,0'
    $tNome = New-Object Windows.Controls.TextBlock
    $tNome.Text = $item.Nome; $tNome.Foreground = Cor '#F2F3F7'; $tNome.FontWeight = 'SemiBold'; $tNome.TextTrimming = 'CharacterEllipsis'
    $tStatus = New-Object Windows.Controls.TextBlock
    $tStatus.Text = $item.Desc; $tStatus.Foreground = Cor '#8B90A0'; $tStatus.FontSize = 11.5; $tStatus.TextTrimming = 'CharacterEllipsis'; $tStatus.Margin = '0,2,0,0'
    $spin = New-Object Windows.Controls.ProgressBar
    $spin.Height = 3; $spin.IsIndeterminate = $true; $spin.Visibility = 'Collapsed'; $spin.Margin = '0,6,0,0'
    $spin.Foreground = Cor '#6366F1'; $spin.Background = Cor '#232732'; $spin.BorderThickness = 0
    [void]$sp.Children.Add($tNome); [void]$sp.Children.Add($tStatus); [void]$sp.Children.Add($spin)
    [Windows.Controls.Grid]::SetColumn($sp, 1)
    [void]$g.Children.Add($sp)

    $chk = New-Object Windows.Controls.CheckBox
    $chk.IsChecked = $true; $chk.VerticalAlignment = 'Center'; $chk.IsHitTestVisible = $false
    $chk.LayoutTransform = New-Object Windows.Media.ScaleTransform(1.25, 1.25)
    [Windows.Controls.Grid]::SetColumn($chk, 2)
    [void]$g.Children.Add($chk)

    $borda.Child = $g
    [void]$wrapPorGrupo[$item.Grupo].Children.Add($borda)

    $card = [pscustomobject]@{ Item = $item; Borda = $borda; Check = $chk; Status = $tStatus; Spin = $spin; Desc = $item.Desc }
    [void]$cards.Add($card)

    $atualizarBorda = {
        param($c)
        $c.Borda.BorderBrush = if ($c.Check.IsChecked) { Cor '#6366F1' } else { Cor '#262A33' }
        $c.Borda.Opacity = if ($c.Check.IsChecked) { 1.0 } else { 0.7 }
    }
    & $atualizarBorda $card
    $borda.Add_MouseLeftButtonUp(({
        if ($script:instalando) { return }
        $card.Check.IsChecked = -not $card.Check.IsChecked
        & $atualizarBorda $card
        Update-Contagem
    }).GetNewClosure())
    $borda.Add_MouseEnter(({ if (-not $script:instalando -and -not $card.Check.IsChecked) { $card.Borda.BorderBrush = Cor '#3A4050' } }).GetNewClosure())
    $borda.Add_MouseLeave(({ & $atualizarBorda $card }).GetNewClosure())
}
Update-Contagem

function Set-Todos([bool]$valor) {
    foreach ($c in $cards) {
        $c.Check.IsChecked = $valor
        $c.Borda.BorderBrush = if ($valor) { Cor '#6366F1' } else { Cor '#262A33' }
        $c.Borda.Opacity = if ($valor) { 1.0 } else { 0.7 }
    }
    Update-Contagem
}
$btnTodos.Add_Click({ if (-not $script:instalando) { Set-Todos $true } })
$btnNenhum.Add_Click({ if (-not $script:instalando) { Set-Todos $false } })

# ---------- Logica ----------
$script:instalando = $false
$script:cancelar = $false
$script:procAtual = $null

function Do-Events {
    $frame = New-Object Windows.Threading.DispatcherFrame
    $acao = [Action]({ $frame.Continue = $false }).GetNewClosure()
    [void][Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke('Background', $acao)
    [Windows.Threading.Dispatcher]::PushFrame($frame)
}

function Write-Log([string]$msg) {
    $txtLog.AppendText($msg + [Environment]::NewLine)
    $txtLog.ScrollToEnd()
}

function Set-Status($card, [string]$texto, [string]$cor, [bool]$ocupado = $false) {
    $card.Status.Text = $texto
    $card.Status.Foreground = Cor $cor
    $card.Spin.Visibility = if ($ocupado) { 'Visible' } else { 'Collapsed' }
    $card.Borda.BringIntoView()
}

function Update-SessionPath {
    $env:Path = "$([Environment]::GetEnvironmentVariable('Path','Machine'));$([Environment]::GetEnvironmentVariable('Path','User'))"
    foreach ($v in 'NVM_HOME', 'NVM_SYMLINK', 'JAVA_HOME', 'ANDROID_HOME', 'ANDROID_SDK_ROOT') {
        $val = [Environment]::GetEnvironmentVariable($v, 'Machine')
        if (-not $val) { $val = [Environment]::GetEnvironmentVariable($v, 'User') }
        if ($val) { Set-Item "Env:$v" $val }
    }
}

# Variaveis de ambiente persistentes (escopo do usuario) e tambem validas na sessao atual
function Set-UserEnv([string]$nome, [string]$valor) {
    [Environment]::SetEnvironmentVariable($nome, $valor, 'User')
    Set-Item "Env:$nome" $valor
}

function Add-UserPath([string]$dir) {
    $atual = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (($atual -split ';') -notcontains $dir) {
        [Environment]::SetEnvironmentVariable('Path', $(if ($atual) { "$atual;$dir" } else { $dir }), 'User')
    }
    if (($env:Path -split ';') -notcontains $dir) { $env:Path += ";$dir" }
}

# Executa um script PowerShell (via -EncodedCommand, sem problemas de aspas) com saida no log
function Invoke-PS([string]$script) {
    $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    return Invoke-Comando 'powershell.exe' "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $b64"
}

# Executa um comando mantendo a interface responsiva e mostrando a saida no log. Retorna o codigo de saida.
function Invoke-Comando([string]$exe, [string]$argumentos) {
    $out = [IO.Path]::GetTempFileName()
    $err = [IO.Path]::GetTempFileName()
    $script:procAtual = Start-Process -FilePath $exe -ArgumentList $argumentos -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $out -RedirectStandardError $err
    $null = $script:procAtual.Handle   # garante leitura do ExitCode
    $leitores = @()
    foreach ($f in $out, $err) {
        $fs = [IO.File]::Open($f, 'Open', 'Read', 'ReadWrite')
        $leitores += New-Object IO.StreamReader($fs)
    }
    $drenar = {
        foreach ($r in $leitores) {
            $txt = $r.ReadToEnd()
            if ($txt) {
                foreach ($linha in ($txt -split "[\r\n]+")) {
                    $l = $linha.Trim()
                    $barraProgresso = $l.Contains([string][char]0x2588) -or $l.Contains([string][char]0x2592)
                    if ($l -and $l -notmatch '^[\-\\|/]$' -and -not $barraProgresso) { Write-Log "  $l" }
                }
            }
        }
    }
    while (-not $script:procAtual.HasExited) {
        & $drenar
        Do-Events
        Start-Sleep -Milliseconds 150
    }
    & $drenar
    foreach ($r in $leitores) { $r.Dispose() }
    Remove-Item $out, $err -Force -ErrorAction SilentlyContinue
    $codigo = $script:procAtual.ExitCode
    $script:procAtual = $null
    return $codigo
}

function Invoke-Winget([string]$id, [string]$extra = '') {
    return Invoke-Comando 'winget' "install --id $id -e --silent --accept-package-agreements --accept-source-agreements $extra"
}

function Test-WingetOk([int]$c) { return ($c -eq 0 -or $c -eq -1978335189) }  # -1978335189 = ja instalado

function Stop-Atual {
    if ($script:procAtual -and -not $script:procAtual.HasExited) {
        try { & taskkill /PID $script:procAtual.Id /T /F | Out-Null } catch {}
    }
}

$btnParar.Add_Click({
    $script:cancelar = $true
    Stop-Atual
    Write-Log '>> Cancelando...'
})

$janela.Add_Closing({
    param($s, $e)
    if ($script:instalando) {
        $r = [Windows.MessageBox]::Show('Ha uma instalacao em andamento. Deseja cancelar e fechar?', 'Atencao', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { $e.Cancel = $true; return }
        $script:cancelar = $true
        Stop-Atual
    }
})

$btnInstalar.Add_Click({
    $marcados = @($cards | Where-Object { $_.Check.IsChecked })
    if ($marcados.Count -eq 0) {
        [void][Windows.MessageBox]::Show('Selecione ao menos um item.', 'Atencao', 'OK', 'Information')
        return
    }
    $senhaPg = $txtSenha.Password
    if (($marcados | Where-Object { $_.Item.Tipo -eq 'postgres' }) -and ([string]::IsNullOrWhiteSpace($senhaPg) -or $senhaPg -match '[\s"]')) {
        [void][Windows.MessageBox]::Show('Informe a senha do PostgreSQL (sem espacos ou aspas).', 'Atencao', 'OK', 'Warning')
        return
    }

    # Dependencias (campo Deps do catalogo): marca o que faltar, repetindo ate estabilizar
    do {
        $mudou = $false
        foreach ($c in @($cards | Where-Object { $_.Check.IsChecked -and $_.Item.Deps })) {
            foreach ($chave in $c.Item.Deps) {
                $d = $cards | Where-Object { $_.Item.Chave -eq $chave }
                if ($d -and -not $d.Check.IsChecked) {
                    $d.Check.IsChecked = $true
                    $d.Borda.BorderBrush = Cor '#6366F1'; $d.Borda.Opacity = 1.0
                    $mudou = $true
                }
            }
        }
    } while ($mudou)
    $fila = @($cards | Where-Object { $_.Check.IsChecked })   # ordem do catalogo

    $script:instalando = $true
    $script:cancelar = $false
    $btnInstalar.IsEnabled = $false; $btnTodos.IsEnabled = $false; $btnNenhum.IsEnabled = $false
    $txtSenha.IsEnabled = $false
    $btnParar.Visibility = 'Visible'
    foreach ($c in $cards) { if (-not $c.Check.IsChecked) { $c.Borda.Opacity = 0.35 } }
    foreach ($c in $fila) { Set-Status $c 'Na fila' '#8B90A0' }
    $barra.Maximum = $fila.Count; $barra.Value = 0; $lblPct.Text = '0%'
    $txtLog.Clear()

    $ok = 0; $falhas = 0; $n = 0
    foreach ($c in $fila) {
        if ($script:cancelar) { Set-Status $c 'Cancelado' '#8B90A0'; continue }
        $n++
        $app = $c.Item
        $lblStatus.Text = "Instalando $n de $($fila.Count): $($app.Nome)"
        Set-Status $c 'Instalando...' '#F5A524' $true
        Write-Log "=== $($app.Nome) ==="
        $sucesso = $false; $motivo = ''
        switch ($app.Tipo) {
            'winget' {
                $cod = Invoke-Winget $app.Id
                $sucesso = Test-WingetOk $cod; $motivo = "codigo $cod"
            }
            'postgres' {
                foreach ($ver in 18, 17) {
                    if ($script:cancelar) { break }
                    $cod = Invoke-Winget "PostgreSQL.PostgreSQL.$ver" "--override `"--mode unattended --unattendedmodeui none --superpassword $senhaPg`""
                    $sucesso = Test-WingetOk $cod; $motivo = "codigo $cod"
                    if ($sucesso) { break }
                }
            }
            'node' {
                Update-SessionPath
                if (Get-Command nvm -ErrorAction SilentlyContinue) {
                    $cod = Invoke-Comando 'cmd.exe' '/c nvm install latest'
                    if ($cod -eq 0) { $cod = Invoke-Comando 'cmd.exe' '/c nvm use latest' }
                    $sucesso = ($cod -eq 0); $motivo = "codigo $cod"
                } else { $motivo = 'nvm nao encontrado no PATH' }
            }
            'jdk' {
                $cod = Invoke-Winget $app.Id
                $sucesso = Test-WingetOk $cod; $motivo = "codigo $cod"
                if ($sucesso) {
                    $jdk = Get-ChildItem "$env:ProgramFiles\Eclipse Adoptium" -Directory -Filter 'jdk-17*' -ErrorAction SilentlyContinue |
                        Sort-Object Name -Descending | Select-Object -First 1
                    if ($jdk) {
                        Set-UserEnv 'JAVA_HOME' $jdk.FullName
                        Add-UserPath "$($jdk.FullName)\bin"
                        Write-Log "  JAVA_HOME = $($jdk.FullName)"
                    } else { $sucesso = $false; $motivo = 'JDK instalado, mas pasta nao encontrada' }
                }
            }
            'androidsdk' {
                Update-SessionPath
                $sdk = "$env:LOCALAPPDATA\Android\Sdk"
                $cmd = "$sdk\cmdline-tools\latest"
                $sm  = "$cmd\bin\sdkmanager.bat"
                $cod = 0
                if (-not (Test-Path $sm)) {
                    Write-Log '  Baixando Android command-line tools (dl.google.com)...'
                    $cod = Invoke-PS @"
`$ErrorActionPreference='Stop'; `$ProgressPreference='SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
`$zip=Join-Path `$env:TEMP 'cmdline-tools.zip'; `$tmp=Join-Path `$env:TEMP 'cmdline-tools-x'
Invoke-WebRequest 'https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip' -OutFile `$zip
if (Test-Path `$tmp) { Remove-Item `$tmp -Recurse -Force }
Expand-Archive `$zip `$tmp
New-Item -ItemType Directory -Force '$sdk\cmdline-tools' | Out-Null
if (Test-Path '$cmd') { Remove-Item '$cmd' -Recurse -Force }
Move-Item "`$tmp\cmdline-tools" '$cmd'
Remove-Item `$zip -Force
"@
                }
                if ($cod -eq 0 -and -not $script:cancelar) {
                    Write-Log '  Aceitando licencas e instalando pacotes do SDK (pode demorar)...'
                    $cod = Invoke-PS @"
`$ErrorActionPreference='Continue'
`$sm='$sm'
1..80 | ForEach-Object { 'y' } | & `$sm --sdk_root='$sdk' --licenses
& `$sm --sdk_root='$sdk' 'platform-tools' 'platforms;android-35' 'platforms;android-36' 'build-tools;35.0.0' 'build-tools;36.0.0'
exit `$LASTEXITCODE
"@
                }
                $sucesso = ($cod -eq 0); $motivo = "codigo $cod"
                if ($sucesso) {
                    Set-UserEnv 'ANDROID_HOME' $sdk
                    Set-UserEnv 'ANDROID_SDK_ROOT' $sdk
                    Add-UserPath "$sdk\platform-tools"
                    Add-UserPath "$cmd\bin"
                    Write-Log "  ANDROID_HOME = $sdk"
                }
            }
            'flutter' {
                Update-SessionPath
                $dest = 'C:\src\flutter'
                if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
                    $motivo = 'git nao encontrado no PATH (reabra o instalador)'
                } else {
                    if (Test-Path "$dest\.git") {
                        $cod = Invoke-Comando 'git' "-C $dest pull --ff-only"
                    } else {
                        $cod = Invoke-Comando 'git' "clone https://github.com/flutter/flutter.git -b stable $dest"
                    }
                    if ($cod -eq 0) {
                        Add-UserPath "$dest\bin"
                        Update-SessionPath
                        $cod = Invoke-Comando 'cmd.exe' '/c flutter --version'
                    }
                    if ($cod -eq 0) {
                        [void](Invoke-Comando 'cmd.exe' "/c flutter config --android-sdk `"$env:LOCALAPPDATA\Android\Sdk`"")
                        Write-Log '  flutter doctor (informativo):'
                        [void](Invoke-Comando 'cmd.exe' '/c flutter doctor')
                    }
                    $sucesso = ($cod -eq 0); $motivo = "codigo $cod"
                }
            }
            'sshmanager' {
                # Extrai o pacote embutido (script + fontes + icone) e cria o atalho no Menu Iniciar
                $dest = Join-Path $env:LOCALAPPDATA 'Programs\GerenciadorSSH'
                try {
                    if (Test-Path $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
                    [void](New-Item -ItemType Directory -Force $dest)
                    if ($script:PacoteSshB64) {
                        $zip = Join-Path $env:TEMP 'gerenciador-ssh.zip'
                        [IO.File]::WriteAllBytes($zip, [Convert]::FromBase64String($script:PacoteSshB64))
                        Add-Type -AssemblyName System.IO.Compression.FileSystem
                        [IO.Compression.ZipFile]::ExtractToDirectory($zip, $dest)
                        Remove-Item -LiteralPath $zip -Force
                    } else {
                        $origem = if ($PSScriptRoot) { Join-Path $PSScriptRoot '..\pacotes\gerenciador-ssh' }
                        if (-not $origem -or -not (Test-Path $origem)) { throw 'pacote do Gerenciador SSH nao encontrado' }
                        Copy-Item -Path (Join-Path $origem '*') -Destination $dest -Recurse -Force
                    }
                    $ps1 = Join-Path $dest 'gerenciador-ssh.ps1'
                    if (-not (Test-Path $ps1)) { throw 'gerenciador-ssh.ps1 ausente no pacote' }
                    $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path ([Environment]::GetFolderPath('Programs')) 'Gerenciador de Chaves SSH.lnk'))
                    $lnk.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
                    $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File `"$ps1`""
                    $lnk.WorkingDirectory = $dest
                    $ico = Join-Path $dest 'gerenciador-ssh.ico'
                    if (Test-Path $ico) { $lnk.IconLocation = $ico }
                    $lnk.Description = 'Gerenciador de Chaves SSH'
                    $lnk.Save()
                    Write-Log "  Instalado em $dest (atalho no Menu Iniciar)"
                    $sucesso = $true
                } catch { $motivo = $_.Exception.Message }
            }
            'meta' {
                Write-Log '  Pre-requisitos atendidos: Node, JDK 17 e Android SDK.'
                Write-Log '  Crie um projeto com: npx @react-native-community/cli init MeuApp'
                $sucesso = $true
            }
            'npm' {
                Update-SessionPath
                if (Get-Command npm -ErrorAction SilentlyContinue) {
                    $cod = Invoke-Comando 'cmd.exe' "/c npm install -g $($app.Pacote)"
                    $sucesso = ($cod -eq 0); $motivo = "codigo $cod"
                } else { $motivo = 'npm indisponivel (instale o Node antes)' }
            }
            'claude' {
                # Instalador oficial da Anthropic (nao depende de Node)
                $cod = Invoke-Comando 'powershell.exe' '-NoProfile -ExecutionPolicy Bypass -Command "irm https://claude.ai/install.ps1 | iex"'
                $sucesso = ($cod -eq 0); $motivo = "codigo $cod"
            }
        }
        if ($script:cancelar -and -not $sucesso) {
            Set-Status $c 'Cancelado' '#8B90A0'
        } elseif ($sucesso) {
            Set-Status $c 'Concluido' '#34D399'; $ok++
        } else {
            Set-Status $c "Falhou ($motivo)" '#F87171'; $falhas++
        }
        $barra.Value = $n
        $lblPct.Text = "{0}%" -f [int](100 * $n / $fila.Count)
    }

    $script:instalando = $false
    $btnParar.Visibility = 'Collapsed'
    $btnInstalar.IsEnabled = $true; $btnTodos.IsEnabled = $true; $btnNenhum.IsEnabled = $true
    $txtSenha.IsEnabled = $true
    foreach ($c in $cards) { if (-not $c.Check.IsChecked) { $c.Borda.Opacity = 0.7 } }
    $lblStatus.Text = if ($script:cancelar) { 'Instalacao cancelada.' } else { "Finalizado: $ok com sucesso, $falhas com falha." }
    Write-Log ''
    Write-Log $lblStatus.Text
    Write-Log 'Reinicie o computador/terminal para atualizar o PATH (o Docker pode exigir reinicio).'
})

[void]$janela.ShowDialog()

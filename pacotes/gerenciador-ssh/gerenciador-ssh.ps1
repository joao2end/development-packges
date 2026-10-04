# Gerenciador de chaves SSH: varias contas (GitHub, Bitbucket, GitLab...) ao mesmo tempo, com instalacao do GitHub CLI.
# Cada conta = 1 chave ed25519 + 1 bloco "Host" no ~/.ssh/config (+ opcionalmente identidade git por pasta).

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

$SshDir     = Join-Path $env:USERPROFILE '.ssh'
$ConfigPath = Join-Path $SshDir 'config'
$DbPath     = Join-Path $SshDir 'ssh-manager.json'
$Hosts      = @{ 'GitHub' = 'github.com'; 'Bitbucket' = 'bitbucket.org'; 'GitLab' = 'gitlab.com'; 'Outro' = '' }
$Paginas    = @{ 'GitHub' = 'https://github.com/settings/ssh/new'; 'Bitbucket' = 'https://bitbucket.org/account/settings/ssh-keys/'; 'GitLab' = 'https://gitlab.com/-/user_settings/ssh_keys' }
$script:Contas = @()
$script:Gh = $null
$script:Instalando = $null
$Utf8 = New-Object Text.UTF8Encoding($false)

# ---------- Utilitarios ----------
function Fwd($p) { ($p -replace '\\', '/') }

function Atualizar-Path {
    $m = [Environment]::GetEnvironmentVariable('Path', 'Machine'); $u = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$m;$u"
}

function Invoke-Tool($exe, $argStr) {
    $o = [IO.Path]::GetTempFileName(); $e = [IO.Path]::GetTempFileName()
    try {
        $p = Start-Process -FilePath $exe -ArgumentList $argStr -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $o -RedirectStandardError $e
        $enc = if ($exe -match 'gh(\.exe|\.cmd)?$') { 'UTF8' } else { 'Default' }   # o gh imprime em UTF-8; ssh e demais usam a pagina de codigo do Windows
        [pscustomobject]@{ Code = $p.ExitCode; Out = ("{0}{1}" -f (Get-Content $o -Raw -Encoding $enc), (Get-Content $e -Raw -Encoding $enc)).Trim() }
    } catch {
        [pscustomobject]@{ Code = -1; Out = $_.Exception.Message }
    } finally {
        Remove-Item $o, $e -Force -ErrorAction SilentlyContinue
    }
}

function Achar-Gh {
    $c = Get-Command gh -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $p = Join-Path $env:ProgramFiles 'GitHub CLI\gh.exe'
    if (Test-Path $p) { return $p }
    return $null
}

function Carregar-Contas {
    $lista = @()
    if (Test-Path $DbPath) {
        try { $lista = @(([IO.File]::ReadAllText($DbPath) | ConvertFrom-Json) | ForEach-Object { $_ }) } catch { $lista = @() }
    }
    foreach ($c in $lista) { Add-Member -InputObject $c -NotePropertyName Etiqueta -NotePropertyValue ("{0}  ({1})" -f $c.Nome, $c.Alias) -Force }
    # Repara textos gravados com a codificacao errada em versoes anteriores (ex.: "JoÃ£o" -> "João")
    $reparou = $false
    foreach ($c in $lista) {
        foreach ($campo in 'Nome', 'GitNome', 'GitEmail', 'Pasta') {
            $v = $c.$campo
            if ($v -and [regex]::IsMatch($v, '[\u00C2\u00C3][\u0080-\u00BF]')) {
                $c.$campo = [Text.Encoding]::UTF8.GetString([Text.Encoding]::GetEncoding(1252).GetBytes($v)); $reparou = $true
            }
        }
    }
    $script:Contas = @($lista)
    if ($reparou) { Salvar-Contas; foreach ($c in $script:Contas) { Gravar-Include $c } }
}

function Salvar-Contas {
    if (-not (Test-Path $SshDir)) { New-Item -ItemType Directory -Path $SshDir -Force | Out-Null }
    $dados = @($script:Contas | ForEach-Object { $_ | Select-Object Alias, Nome, Provedor, HostReal, Chave, GitNome, GitEmail, Pasta, GhUser, Verificada, SenhaProt })
    [IO.File]::WriteAllText($DbPath, (ConvertTo-Json -InputObject $dados -Depth 4), $Utf8)
}

# ---------- ~/.ssh/config (bloco gerenciado por conta) ----------
function Ler-Config { if (Test-Path $ConfigPath) { [IO.File]::ReadAllText($ConfigPath) } else { '' } }

function Remover-Bloco($texto, $alias) {
    $re = "(?ms)^# >>> ssh-manager: $([regex]::Escape($alias)) >>>.*?# <<< ssh-manager: $([regex]::Escape($alias)) <<<\r?\n?"
    [regex]::Replace($texto, $re, '')
}

function Gravar-Bloco($c) {
    $t = Remover-Bloco (Ler-Config) $c.Alias
    if ($t -and -not $t.EndsWith("`n")) { $t += "`n" }
    $t += "# >>> ssh-manager: $($c.Alias) >>>`nHost $($c.Alias)`n  HostName $($c.HostReal)`n  User git`n  IdentityFile $(Fwd $c.Chave)`n  IdentitiesOnly yes`n# <<< ssh-manager: $($c.Alias) <<<`n"
    [IO.File]::WriteAllText($ConfigPath, $t, $Utf8)
}

function Apagar-Bloco($alias) {
    if (Test-Path $ConfigPath) { [IO.File]::WriteAllText($ConfigPath, (Remover-Bloco (Ler-Config) $alias), $Utf8) }
}

# ---------- Identidade git por pasta (includeIf) ----------
function Chave-Include($pasta) { $p = (Fwd $pasta).TrimEnd('/') + '/'; "includeIf.gitdir/i:$p.path" }
function Arquivo-Git($alias) { Join-Path $env:USERPROFILE ".gitconfig-ssh-$alias" }

function Remover-Include($c) {
    if ($c.Pasta -and (Get-Command git -ErrorAction SilentlyContinue)) {
        [void](Invoke-Tool 'git' ("config --global --unset `"{0}`"" -f (Chave-Include $c.Pasta)))
    }
    Remove-Item (Arquivo-Git $c.Alias) -Force -ErrorAction SilentlyContinue
}

function Ssh-Exe {
    $p = Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe'
    if (Test-Path $p) { return $p }
    $c = Get-Command ssh -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    'ssh'
}

function Gravar-Include($c) {
    if (-not $c.Pasta -or -not (Get-Command git -ErrorAction SilentlyContinue)) { return }
    $arq = Arquivo-Git $c.Alias
    $s = "[user]`n"
    if ($c.GitNome)  { $s += "  name = $($c.GitNome)`n" }
    if ($c.GitEmail) { $s += "  email = $($c.GitEmail)`n" }
    $s += "[core]`n  sshCommand = $(Fwd (Ssh-Exe)) -i `"$(Fwd $c.Chave)`" -o IdentitiesOnly=yes`n"
    [IO.File]::WriteAllText($arq, $s, $Utf8)
    [void](Invoke-Tool 'git' ("config --global `"{0}`" `"{1}`"" -f (Chave-Include $c.Pasta), (Fwd $arq)))
}

# ---------- Instancia unica + aplicativo WPF (fica residente na bandeja) ----------
$iniciarOculto = ($args -contains '--tray')
$criado = $false
$mutex = New-Object Threading.Mutex($true, 'Local\GerenciadorSSH_Instancia', [ref]$criado)
$evMostrar = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::AutoReset, 'Local\GerenciadorSSH_Mostrar')
if (-not $criado) { [void]$evMostrar.Set(); exit }   # ja esta rodando: apenas pede para abrir a janela

Add-Type -AssemblyName System.Drawing
$app = New-Object System.Windows.Application
$app.ShutdownMode = 'OnExplicitShutdown'
$script:Sair = $false

# ---------- Fontes (Open Sans / Fira Code) ----------
$AppDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) }
$fontDir = Join-Path $AppDir 'fontes'
$sans = 'Segoe UI'; $mono = 'Consolas'
if (Test-Path $fontDir) {
    $furi = ([Uri]($fontDir.TrimEnd('\') + '\')).AbsoluteUri
    $sans = "$furi#Open Sans, Segoe UI"
    $mono = "$furi#Fira Code, Consolas"
}

# ---------- XAML: janela principal ----------
$xamlRaw = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Gerenciador de Chaves SSH" Width="1060" Height="780" MinWidth="960" MinHeight="700"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" ResizeMode="CanMinimize"
        WindowStartupLocation="CenterScreen" FontFamily="__SANS__" FontSize="13" UseLayoutRounding="True">
  <Window.Resources>__RESOURCES__</Window.Resources>
  <Border Margin="16" CornerRadius="16" Background="{StaticResource Bg}" BorderBrush="{StaticResource Line}" BorderThickness="1" TextElement.Foreground="{StaticResource Text}">
    <Border.Effect><DropShadowEffect BlurRadius="26" ShadowDepth="0" Opacity="0.6" Color="Black"/></Border.Effect>
    <Grid>
      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>

      <Grid x:Name="barra" Grid.Row="0" Background="Transparent" Height="48">
        <StackPanel Orientation="Horizontal" Margin="20,0,0,0" VerticalAlignment="Center">
          <Border Width="12" Height="12" CornerRadius="4" Background="{StaticResource Accent}" Margin="0,0,10,0"/>
          <TextBlock Text="Gerenciador de Chaves SSH" FontWeight="SemiBold" FontSize="14"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,0,10,0" VerticalAlignment="Center">
          <Button x:Name="btnMin" Style="{StaticResource Chrome}" Content="&#xE921;" ToolTip="Minimizar"/>
          <Button x:Name="btnFechar" Style="{StaticResource Chrome}" Content="&#xE8BB;" ToolTip="Fechar (continua na bandeja)"/>
        </StackPanel>
      </Grid>

      <Grid Grid.Row="1" Margin="16,0,16,0">
        <Grid.ColumnDefinitions><ColumnDefinition Width="260"/><ColumnDefinition Width="16"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>

        <DockPanel Grid.Column="0">
          <TextBlock DockPanel.Dock="Top" Text="CONTAS" Style="{StaticResource Rotulo}" Margin="4,0,0,10"/>
          <CheckBox x:Name="chkAuto" DockPanel.Dock="Bottom" Content="Iniciar com o Windows" Margin="4,12,0,0" ToolTip="Abre o app na bandeja ao entrar no Windows"/>
          <Button x:Name="btnNova" DockPanel.Dock="Bottom" Content="+  Nova conta" Style="{StaticResource Primario}" Margin="0,6,0,0"/>
          <ListBox x:Name="lstContas">
            <ListBox.ItemTemplate>
              <DataTemplate>
                <StackPanel>
                  <TextBlock Text="{Binding Nome}" FontWeight="SemiBold" FontSize="14" TextTrimming="CharacterEllipsis"/>
                  <TextBlock Text="{Binding Alias}" FontFamily="__MONO__" FontSize="11" Foreground="#9AA3B5" Margin="0,3,0,0" TextTrimming="CharacterEllipsis"/>
                  <TextBlock Text="{Binding Provedor}" FontSize="11" Foreground="#818CF8" Margin="0,3,0,0"/>
                </StackPanel>
              </DataTemplate>
            </ListBox.ItemTemplate>
          </ListBox>
        </DockPanel>

        <Border Grid.Column="2" Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="14" Padding="26,22,26,16">
          <DockPanel>
            <StackPanel DockPanel.Dock="Top">
              <TextBlock x:Name="txtConta" Style="{StaticResource Rotulo}" Margin="0,0,0,10"/>
              <WrapPanel Margin="0,0,0,18">
                <RadioButton x:Name="rbP1" Tag="1" GroupName="passo" Style="{StaticResource Chip}" Content="1  Criar chave" Margin="0,0,6,0"/>
                <RadioButton x:Name="rbP2" Tag="2" GroupName="passo" Style="{StaticResource Chip}" Content="2  Entrar no GitHub" Margin="0,0,6,0"/>
                <RadioButton x:Name="rbP3" Tag="3" GroupName="passo" Style="{StaticResource Chip}" Content="3  Vincular" Margin="0,0,6,0"/>
                <RadioButton x:Name="rbP4" Tag="4" GroupName="passo" Style="{StaticResource Chip}" Content="4  Enviar e testar" Margin="0,0,6,0"/>
              </WrapPanel>
              <TextBlock x:Name="txtPassoTitulo" FontSize="21" FontWeight="Bold"/>
              <TextBlock x:Name="txtPassoDica" Foreground="{StaticResource Muted}" TextWrapping="Wrap" Margin="0,4,0,18"/>
            </StackPanel>

            <Border DockPanel.Dock="Bottom" BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,0" Padding="0,14,0,0" Margin="0,8,0,0">
              <DockPanel>
                <Button x:Name="btnAvancar" DockPanel.Dock="Right" Style="{StaticResource Primario}" Margin="0" Content="Continuar"/>
                <Button x:Name="btnVoltar" Content="Voltar" HorizontalAlignment="Left" Margin="0"/>
              </DockPanel>
            </Border>

            <ScrollViewer VerticalScrollBarVisibility="Auto">
              <Grid>
                <!-- Passo 1: criar chave -->
                <StackPanel x:Name="pg1">
                  <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="16"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <StackPanel Grid.Column="0">
                      <TextBlock Text="Nome da conta (ex.: Trabalho, Pessoal)" Style="{StaticResource Rotulo}"/>
                      <TextBox x:Name="txtNome"/>
                      <TextBlock Text="Provedor" Style="{StaticResource Rotulo}"/>
                      <WrapPanel>
                        <RadioButton x:Name="rbGitHub" Content="GitHub" Tag="GitHub" GroupName="prov" Style="{StaticResource Chip}"/>
                        <RadioButton x:Name="rbBitbucket" Content="Bitbucket" Tag="Bitbucket" GroupName="prov" Style="{StaticResource Chip}"/>
                        <RadioButton x:Name="rbGitLab" Content="GitLab" Tag="GitLab" GroupName="prov" Style="{StaticResource Chip}"/>
                        <RadioButton x:Name="rbOutro" Content="Outro" Tag="Outro" GroupName="prov" Style="{StaticResource Chip}"/>
                      </WrapPanel>
                    </StackPanel>
                    <StackPanel Grid.Column="2">
                      <TextBlock Text="Servidor (HostName)" Style="{StaticResource Rotulo}"/>
                      <TextBox x:Name="txtHost" Style="{StaticResource Mono}"/>
                      <TextBlock Text="Apelido do host (usado no git clone)" Style="{StaticResource Rotulo}"/>
                      <TextBox x:Name="txtAlias" Style="{StaticResource Mono}" ToolTip="Deixe vazio para gerar automaticamente"/>
                    </StackPanel>
                  </Grid>
                  <StackPanel x:Name="pnlSenha">
                    <TextBlock Text="Senha (passphrase) da nova chave (opcional)" Style="{StaticResource Rotulo}"/>
                    <PasswordBox x:Name="pwdSenha"/>
                    <CheckBox x:Name="chkLembrar" IsChecked="True" Content="Lembrar a senha neste computador (criptografada pelo Windows)" Margin="0,-4,0,6"/>
                  </StackPanel>
                </StackPanel>

                <!-- Passo 2: login no GitHub -->
                <StackPanel x:Name="pg2" Visibility="Collapsed">
                  <Border Background="{StaticResource Bg}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="12" Padding="16">
                    <StackPanel>
                      <DockPanel>
                        <Ellipse x:Name="dotGh" Width="9" Height="9" Fill="#F87171" Margin="0,0,10,0" VerticalAlignment="Center"/>
                        <TextBlock x:Name="txtGh" VerticalAlignment="Center" TextWrapping="Wrap" FontFamily="__MONO__" FontSize="12"/>
                      </DockPanel>
                      <WrapPanel Margin="0,14,0,0">
                        <Button x:Name="btnInstalarGh" Content="Instalar GitHub CLI" Style="{StaticResource Primario}" Margin="0,0,8,0"/>
                        <Button x:Name="btnLoginGh" Content="Entrar com GitHub" Margin="0,0,8,0"/>
                        <Button x:Name="btnListarGh" Content="Ver chaves no GitHub" Margin="0"/>
                      </WrapPanel>
                    </StackPanel>
                  </Border>
                  <TextBlock Foreground="{StaticResource Muted}" TextWrapping="Wrap" Margin="2,16,0,0" LineHeight="21"
                             Text="Clique em &quot;Entrar com GitHub&quot;: abre uma janela com um código; confirme no navegador. Repita para cada conta (pessoal, trabalho...). Todas ficam salvas no gh e você alterna o usuário ativo a qualquer momento pelo ícone na bandeja do Windows."/>
                </StackPanel>

                <!-- Passo 3: vincular usuario / identidade -->
                <StackPanel x:Name="pg3" Visibility="Collapsed">
                  <StackPanel x:Name="pnlGh">
                    <TextBlock Text="Usuário do GitHub vinculado a esta chave" Style="{StaticResource Rotulo}"/>
                    <WrapPanel x:Name="pnlGhUsers" Margin="0,4,0,0"/>
                    <TextBlock x:Name="txtSemUsuarios" Text="Nenhum usuário logado. Volte ao passo 2 e entre com o GitHub." Foreground="#9AA3B5" FontSize="12" Margin="0,4,0,8"/>
                    <Button x:Name="btnAtivar" Content="Tornar este usuário o ativo no gh" HorizontalAlignment="Left" Margin="0,2,0,18"/>
                  </StackPanel>
                  <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="16"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <StackPanel Grid.Column="0">
                      <TextBlock Text="Nome no git (opcional)" Style="{StaticResource Rotulo}"/>
                      <TextBox x:Name="txtGitNome"/>
                    </StackPanel>
                    <StackPanel Grid.Column="2">
                      <TextBlock Text="E-mail no git (opcional)" Style="{StaticResource Rotulo}"/>
                      <TextBox x:Name="txtGitEmail"/>
                    </StackPanel>
                  </Grid>
                  <TextBlock Text="Pasta de projetos (opcional): aplica nome, e-mail e chave a tudo que estiver dentro dela" Style="{StaticResource Rotulo}" TextWrapping="Wrap"/>
                  <DockPanel>
                    <Button x:Name="btnPasta" DockPanel.Dock="Right" Content="Procurar..." Margin="8,4,0,12"/>
                    <TextBox x:Name="txtPasta" Style="{StaticResource Mono}"/>
                  </DockPanel>
                </StackPanel>

                <!-- Passo 4: enviar e testar -->
                <StackPanel x:Name="pg4" Visibility="Collapsed">
                  <Border Background="{StaticResource Bg}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="12" Padding="16" Margin="0,0,0,16">
                    <TextBlock x:Name="txtStatus" TextWrapping="Wrap" Foreground="{StaticResource Muted}" FontFamily="__MONO__" FontSize="12" LineHeight="20"/>
                  </Border>
                  <WrapPanel>
                    <Button x:Name="btnEnviar" Content="Enviar ao GitHub (gh)" Style="{StaticResource Primario}"/>
                    <Button x:Name="btnTestar" Content="Testar conexão"/>
                    <Button x:Name="btnDesbloquear" Content="Liberar chave com senha (ssh-agent)" Visibility="Collapsed"/>
                    <Button x:Name="btnCopiar" Content="Copiar chave pública"/>
                    <Button x:Name="btnAbrir" Content="Abrir página de chaves do site"/>
                  </WrapPanel>
                  <Button x:Name="btnExcluir" Content="Excluir conta" Style="{StaticResource Perigo}" HorizontalAlignment="Left" Margin="0,18,0,0"/>
                </StackPanel>
              </Grid>
            </ScrollViewer>
          </DockPanel>
        </Border>
      </Grid>

      <TextBox x:Name="txtLog" Grid.Row="2" Style="{StaticResource Log}" Margin="16,14,16,16" Height="96" IsReadOnly="True" VerticalScrollBarVisibility="Auto" TextWrapping="Wrap"/>
    </Grid>
  </Border>
</Window>
'@

# ---------- XAML: menu flutuante da bandeja ----------
$popRaw = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" ShowInTaskbar="False" Topmost="True"
        ResizeMode="NoResize" SizeToContent="WidthAndHeight" FontFamily="__SANS__" FontSize="13" UseLayoutRounding="True">
  <Window.Resources>__RESOURCES__</Window.Resources>
  <Border Margin="14" Width="300" CornerRadius="14" Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}" BorderThickness="1" TextElement.Foreground="{StaticResource Text}">
    <Border.Effect><DropShadowEffect BlurRadius="22" ShadowDepth="0" Opacity="0.6" Color="Black"/></Border.Effect>
    <StackPanel Margin="10">
      <TextBlock Text="GITHUB  ·  USUÁRIO ATIVO" Style="{StaticResource Rotulo}" Margin="12,6,0,8"/>
      <StackPanel x:Name="lista"/>
      <TextBlock x:Name="vazio" Foreground="{StaticResource Muted}" TextWrapping="Wrap" Margin="12,4,12,8" FontSize="12"/>
      <Border Height="1" Background="{StaticResource Line}" Margin="0,8,0,8"/>
      <Button x:Name="pAbrir" Style="{StaticResource Item}" Content="Abrir gerenciador"/>
      <Button x:Name="pSair" Style="{StaticResource Item}" Content="Sair"/>
    </StackPanel>
  </Border>
</Window>
'@

$estilosExtras = @'
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{StaticResource Text}"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="CheckBox">
          <StackPanel Orientation="Horizontal" Background="Transparent">
            <Border x:Name="box" Width="18" Height="18" CornerRadius="5" Background="{StaticResource Bg}" BorderBrush="{StaticResource Line}" BorderThickness="1" Margin="0,0,10,0" VerticalAlignment="Center">
              <Path x:Name="tick" Data="M3,9 L7,13 L14,5" Stroke="White" StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Visibility="Collapsed"/>
            </Border>
            <ContentPresenter VerticalAlignment="Center"/>
          </StackPanel>
          <ControlTemplate.Triggers>
            <Trigger Property="IsChecked" Value="True">
              <Setter TargetName="box" Property="Background" Value="{StaticResource Accent}"/><Setter TargetName="box" Property="BorderBrush" Value="{StaticResource Accent}"/>
              <Setter TargetName="tick" Property="Visibility" Value="Visible"/>
            </Trigger>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="box" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>    <Style x:Key="Item" TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource Text}"/><Setter Property="Cursor" Value="Hand"/><Setter Property="Margin" Value="0,0,0,2"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="b" CornerRadius="9" Background="Transparent" Padding="12,9"><ContentPresenter/></Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="{StaticResource Panel2}"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
'@
$recursosBase = @'
    <SolidColorBrush x:Key="Bg" Color="#0E1015"/>
    <SolidColorBrush x:Key="Panel" Color="#161922"/>
    <SolidColorBrush x:Key="Panel2" Color="#1D212C"/>
    <SolidColorBrush x:Key="Line" Color="#292E3B"/>
    <SolidColorBrush x:Key="Text" Color="#E7E9EF"/>
    <SolidColorBrush x:Key="Muted" Color="#9AA3B5"/>
    <SolidColorBrush x:Key="Accent" Color="#6366F1"/>
    <SolidColorBrush x:Key="AccentSoft" Color="#24275A"/>
    <SolidColorBrush x:Key="Danger" Color="#F87171"/>

    <Style TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="Background" Value="{StaticResource Panel2}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="Padding" Value="14,8"/><Setter Property="Margin" Value="0,0,8,8"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="b" CornerRadius="9" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" Padding="{TemplateBinding Padding}">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
            <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.75"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.35"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style x:Key="Primario" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="{StaticResource Accent}"/><Setter Property="BorderBrush" Value="{StaticResource Accent}"/>
      <Setter Property="Foreground" Value="White"/><Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="Perigo" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Foreground" Value="{StaticResource Danger}"/>
    </Style>
    <Style x:Key="Chrome" TargetType="Button">
      <Setter Property="Width" Value="40"/><Setter Property="Height" Value="30"/><Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="FontFamily" Value="Segoe Fluent Icons, Segoe MDL2 Assets"/><Setter Property="FontSize" Value="11"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="b" CornerRadius="8" Background="Transparent">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
              <Setter TargetName="b" Property="Background" Value="{StaticResource Panel2}"/><Setter Property="Foreground" Value="White"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>

    <Style TargetType="TextBox">
      <Setter Property="Foreground" Value="{StaticResource Text}"/><Setter Property="CaretBrush" Value="{StaticResource Text}"/>
      <Setter Property="SelectionBrush" Value="{StaticResource Accent}"/>
      <Setter Property="Background" Value="{StaticResource Bg}"/><Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="Padding" Value="10,6"/><Setter Property="Margin" Value="0,4,0,12"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="TextBox">
          <Border x:Name="b" CornerRadius="9" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1">
            <ScrollViewer x:Name="PART_ContentHost"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.5"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style x:Key="Mono" TargetType="TextBox" BasedOn="{StaticResource {x:Type TextBox}}">
      <Setter Property="FontFamily" Value="__MONO__"/><Setter Property="FontSize" Value="12"/>
    </Style>
    <Style x:Key="Log" TargetType="TextBox" BasedOn="{StaticResource Mono}">
      <Setter Property="Background" Value="{StaticResource Panel}"/><Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="Padding" Value="12,8"/><Setter Property="Margin" Value="0"/>
    </Style>
    <Style TargetType="PasswordBox">
      <Setter Property="Foreground" Value="{StaticResource Text}"/><Setter Property="CaretBrush" Value="{StaticResource Text}"/>
      <Setter Property="Background" Value="{StaticResource Bg}"/><Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="Padding" Value="10,6"/><Setter Property="Margin" Value="0,4,0,12"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="PasswordBox">
          <Border x:Name="b" CornerRadius="9" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1">
            <ScrollViewer x:Name="PART_ContentHost"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style x:Key="Rotulo" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/><Setter Property="FontSize" Value="12"/><Setter Property="FontWeight" Value="SemiBold"/>
    </Style>

    <Style x:Key="Chip" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{StaticResource Muted}"/><Setter Property="Margin" Value="0,4,6,12"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="RadioButton">
          <Border x:Name="b" CornerRadius="9" Background="{StaticResource Bg}" BorderBrush="{StaticResource Line}" BorderThickness="1" Padding="11,5">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.4"/></Trigger>
            <Trigger Property="IsChecked" Value="True">
              <Setter TargetName="b" Property="Background" Value="{StaticResource AccentSoft}"/>
              <Setter TargetName="b" Property="BorderBrush" Value="{StaticResource Accent}"/>
              <Setter Property="Foreground" Value="White"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>

    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/><Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="ScrollBar">
          <Track x:Name="PART_Track" IsDirectionReversed="True">
            <Track.Thumb><Thumb><Thumb.Template><ControlTemplate TargetType="Thumb"><Border Background="#3A4154" CornerRadius="4" Margin="1"/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb>
          </Track>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>

    <Style TargetType="ListBox">
      <Setter Property="Background" Value="Transparent"/><Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="ListBox">
          <ScrollViewer Focusable="False" VerticalScrollBarVisibility="Auto"><ItemsPresenter/></ScrollViewer>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style TargetType="ListBoxItem">
      <Setter Property="Foreground" Value="{StaticResource Text}"/>
      <Setter Property="Margin" Value="0,0,0,8"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="ListBoxItem">
          <Border x:Name="b" CornerRadius="11" Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}" BorderThickness="1" Padding="14,10">
            <ContentPresenter/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="{StaticResource Panel2}"/></Trigger>
            <Trigger Property="IsSelected" Value="True">
              <Setter TargetName="b" Property="Background" Value="{StaticResource AccentSoft}"/>
              <Setter TargetName="b" Property="BorderBrush" Value="{StaticResource Accent}"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
  
'@
$recursos = $recursosBase + $estilosExtras

function Montar-Xaml($raw) { [xml]$raw.Replace('__RESOURCES__', $recursos).Replace('__SANS__', $sans).Replace('__MONO__', $mono) }

[xml]$xaml = Montar-Xaml $xamlRaw
$win = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $xaml))
$ui = @{}
foreach ($n in 'btnInstalarGh','btnLoginGh','btnListarGh','txtGh','dotGh','btnNova','chkAuto','lstContas','txtConta','txtPassoTitulo','txtPassoDica','txtNome','txtHost','txtAlias','txtGitNome','txtGitEmail','txtPasta','btnPasta','pnlSenha','pwdSenha','chkLembrar','txtStatus','btnAvancar','btnVoltar','btnCopiar','btnAbrir','btnEnviar','btnTestar','btnDesbloquear','btnExcluir','txtLog','barra','btnMin','btnFechar','pnlGh','pnlGhUsers','txtSemUsuarios','btnAtivar','pg1','pg2','pg3','pg4','rbP1','rbP2','rbP3','rbP4','rbGitHub','rbBitbucket','rbGitLab','rbOutro') {
    $ui[$n] = $win.FindName($n)
}
$provBtns = @($ui.rbGitHub, $ui.rbBitbucket, $ui.rbGitLab, $ui.rbOutro)
$script:Agente = $null; $script:AgenteConta = $null; $script:GhUsers = @(); $script:GhAtivo = $null; $script:Login = $null; $script:Instalando = $null
$script:Pag = 1; $script:Interno = $false; $script:ManterPagina = $false; $script:Pop = $null; $script:PopFechou = [DateTime]::MinValue

function Cor($hex) { (New-Object Windows.Media.BrushConverter).ConvertFromString($hex) }
function Log($msg) {
    $ui.txtLog.AppendText(("[{0}] {1}`r`n" -f (Get-Date -Format 'HH:mm:ss'), $msg))
    $ui.txtLog.ScrollToEnd()
}
function Aviso($msg, $tipo = 'Information') { [void][Windows.MessageBox]::Show($win, $msg, 'Gerenciador de Chaves SSH', 'OK', $tipo) }
function Conta-Atual { $ui.lstContas.SelectedItem }
function Pub-Da($c) { "$($c.Chave).pub" }
function Mostrar-Janela { $win.Show(); $win.WindowState = 'Normal'; [void]$win.Activate() }

function Get-Prov { foreach ($r in $provBtns) { if ($r.IsChecked) { return [string]$r.Tag } }; 'GitHub' }
function Set-Prov($nome) {
    $alvo = if ($Hosts.ContainsKey($nome)) { $nome } else { 'Outro' }
    foreach ($r in $provBtns) { $r.IsChecked = ([string]$r.Tag -eq $alvo) }
}

# ---------- Bandeja do sistema ----------
function Novo-Icone {
    $bmp = New-Object Drawing.Bitmap 32, 32
    $g = [Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'
    $gp = New-Object Drawing.Drawing2D.GraphicsPath
    $gp.AddArc(0, 0, 10, 10, 180, 90); $gp.AddArc(22, 0, 10, 10, 270, 90); $gp.AddArc(22, 22, 10, 10, 0, 90); $gp.AddArc(0, 22, 10, 10, 90, 90); $gp.CloseFigure()
    $g.FillPath((New-Object Drawing.SolidBrush ([Drawing.ColorTranslator]::FromHtml('#6366F1'))), $gp)
    $pen = New-Object Drawing.Pen ([Drawing.Color]::White), 3
    $g.DrawEllipse($pen, 5, 11, 9, 9); $g.DrawLine($pen, 14, 15.5, 26, 15.5); $g.DrawLine($pen, 22, 15.5, 22, 21); $g.DrawLine($pen, 26, 15.5, 26, 20)
    $g.Dispose()
    [Drawing.Icon]::FromHandle($bmp.GetHicon())
}

$tray = New-Object Windows.Forms.NotifyIcon
$tray.Icon = Novo-Icone
$tray.Text = 'Gerenciador de Chaves SSH'
$tray.Visible = $true

$RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$exeAtual = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
function Cmd-Auto {
    if ($exeAtual -match 'powershell') { "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File `"$PSCommandPath`" --tray" }
    else { "`"$exeAtual`" --tray" }
}
function Get-Auto { [bool](Get-ItemProperty -Path $RunKey -ErrorAction SilentlyContinue).GerenciadorSSH }

$cms = New-Object Windows.Forms.ContextMenuStrip
$miAbrir = $cms.Items.Add('Abrir gerenciador')
$miAuto = New-Object Windows.Forms.ToolStripMenuItem 'Iniciar com o Windows'
$miAuto.CheckOnClick = $true; $miAuto.Checked = (Get-Auto)
[void]$cms.Items.Add($miAuto)
$miSair = $cms.Items.Add('Sair')
$tray.ContextMenuStrip = $cms
$miAbrir.Add_Click({ Mostrar-Janela })
function Definir-Auto($on) {
    if ($on) { Set-ItemProperty -Path $RunKey -Name 'GerenciadorSSH' -Value (Cmd-Auto); Log 'Iniciará com o Windows (na bandeja).' }
    else { Remove-ItemProperty -Path $RunKey -Name 'GerenciadorSSH' -ErrorAction SilentlyContinue; Log 'Início com o Windows desativado.' }
    $script:AutoInterno = $true; $ui.chkAuto.IsChecked = $on; $miAuto.Checked = $on; $script:AutoInterno = $false
}
$script:AutoInterno = $false
$miAuto.Add_Click({ Definir-Auto $miAuto.Checked })
$ui.chkAuto.IsChecked = (Get-Auto)
$ui.chkAuto.Add_Checked({ if (-not $script:AutoInterno) { Definir-Auto $true } })
$ui.chkAuto.Add_Unchecked({ if (-not $script:AutoInterno) { Definir-Auto $false } })
$miSair.Add_Click({ Sair-App })

function Atualizar-Tray {
    $t = if ($script:GhAtivo) { "SSH Manager - ativo: $($script:GhAtivo)" } else { 'SSH Manager - sem login no GitHub' }
    $tray.Text = $t.Substring(0, [Math]::Min(63, $t.Length))
}

function Sair-App {
    $script:Sair = $true
    $tray.Visible = $false; $tray.Dispose()
    try { $script:Pop.Close() } catch {}
    $win.Close(); $app.Shutdown()
}

# ---------- Usuarios logados no gh ----------
function Ler-GhUsers {
    $script:GhUsers = @(); $script:GhAtivo = $null
    if (-not $script:Gh) { return }
    $r = Invoke-Tool $script:Gh 'auth status -h github.com'
    $atual = $null
    foreach ($l in ($r.Out -split "`r?`n")) {
        if ($l -match 'Logged in to github\.com (?:account|as) (\S+)') { $atual = $Matches[1]; $script:GhUsers += $atual }
        elseif ($l -match 'Active account:\s*true' -and $atual) { $script:GhAtivo = $atual }
    }
    if (-not $script:GhAtivo -and $script:GhUsers.Count -eq 1) { $script:GhAtivo = $script:GhUsers[0] }
}

function Trocar-Usuario($u) {
    if (-not $script:Gh -or -not $u) { return }
    $r = Invoke-Tool $script:Gh "auth switch -h github.com -u $u"
    Log "gh auth switch -u $u : $($r.Out)"
    try { $script:Pop.Close() } catch {}
    Atualizar-Gh
    if ($script:GhAtivo -eq $u) { $tray.ShowBalloonTip(2500, 'GitHub', "Usuário ativo: $u", [Windows.Forms.ToolTipIcon]::Info) }
    else { $tray.ShowBalloonTip(3000, 'GitHub', "Não foi possível ativar $u", [Windows.Forms.ToolTipIcon]::Warning) }
}

# ---------- Menu flutuante ----------
function Abrir-Popup {
    if ($script:Gh) { Ler-GhUsers; Atualizar-Tray }
    [xml]$px = Montar-Xaml $popRaw
    $pop = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $px))
    $script:Pop = $pop
    $lista = $pop.FindName('lista'); $vazio = $pop.FindName('vazio')
    foreach ($u in $script:GhUsers) {
        $ativo = ($u -eq $script:GhAtivo)
        $b = New-Object Windows.Controls.Button
        $b.Style = $pop.FindResource('Item'); $b.Tag = $u
        $dp = New-Object Windows.Controls.DockPanel
        $dot = New-Object Windows.Shapes.Ellipse
        $dot.Width = 10; $dot.Height = 10; $dot.Margin = New-Object Windows.Thickness(0, 0, 12, 0)
        $dot.Fill = Cor $(if ($ativo) { '#34D399' } else { '#3A4154' })
        $tx = New-Object Windows.Controls.TextBlock
        $tx.Text = $(if ($ativo) { "$u   (ativo)" } else { $u })
        if ($ativo) { $tx.FontWeight = 'SemiBold' }
        [void]$dp.Children.Add($dot); [void]$dp.Children.Add($tx)
        $b.Content = $dp
        $b.Add_Click({ param($s, $e) Trocar-Usuario ([string]$s.Tag) })
        [void]$lista.Children.Add($b)
    }
    if (-not $script:Gh) { $vazio.Text = 'GitHub CLI não instalado. Abra o gerenciador e use o passo 2.' }
    elseif ($script:GhUsers.Count -eq 0) { $vazio.Text = 'Nenhum usuário logado. Abra o gerenciador e use o passo 2.' }
    else { $vazio.Visibility = 'Collapsed' }
    $pop.FindName('pAbrir').Add_Click({ try { $script:Pop.Close() } catch {}; Mostrar-Janela })
    $pop.FindName('pSair').Add_Click({ Sair-App })
    $pop.Add_Loaded({
        $wa = [Windows.SystemParameters]::WorkArea
        $script:Pop.Left = $wa.Right - $script:Pop.ActualWidth - 6
        $script:Pop.Top = $wa.Bottom - $script:Pop.ActualHeight - 6
    })
    $pop.Add_Deactivated({ $script:PopFechou = Get-Date; try { $script:Pop.Close() } catch {} })
    $pop.Show(); [void]$pop.Activate()
}

$tray.Add_MouseClick({
    param($s, $e)
    if ($e.Button -eq [Windows.Forms.MouseButtons]::Left) {
        if (((Get-Date) - $script:PopFechou).TotalMilliseconds -lt 400) { return }   # clique que acabou de fechar o menu
        Abrir-Popup
    }
})
$tray.Add_DoubleClick({ Mostrar-Janela })

# ---------- Passos do fluxo ----------
$Textos = @{
    1 = @('Criar a chave SSH', 'Cada conta tem a sua própria chave. A chave privada fica só neste computador; a pública é cadastrada no site.')
    2 = @('Entrar no GitHub', 'Faça login com o GitHub CLI. Você pode entrar com várias contas e alternar entre elas depois.')
    3 = @('Vincular o usuário', 'Escolha qual usuário do GitHub é dono desta chave e, se quiser, a identidade do git para uma pasta de projetos.')
    4 = @('Enviar e testar', 'Envia a chave ao usuário vinculado e confirma que o SSH autentica com a conta certa.')
}

function Proxima($n) { $gh = ((Get-Prov) -eq 'GitHub'); switch ($n) { 1 { if ($gh) { 2 } else { 3 } } 2 { 3 } default { 4 } } }
function Anterior($n) { $gh = ((Get-Prov) -eq 'GitHub'); switch ($n) { 4 { 3 } 3 { if ($gh) { 2 } else { 1 } } default { 1 } } }

function Ir-Para($n) {
    $script:Pag = $n
    foreach ($i in 1..4) { $ui["pg$i"].Visibility = $(if ($i -eq $n) { 'Visible' } else { 'Collapsed' }) }
    $rb = $ui["rbP$n"]
    if (-not $rb.IsChecked) { $script:Interno = $true; $rb.IsChecked = $true; $script:Interno = $false }
    $ui.txtPassoTitulo.Text = "Passo $n de 4  ·  " + $Textos[$n][0]
    $ui.txtPassoDica.Text = $Textos[$n][1]
    $ui.btnVoltar.Visibility = $(if ($n -eq 1) { 'Collapsed' } else { 'Visible' })
    $ui.btnAvancar.Visibility = $(if ($n -eq 4) { 'Collapsed' } else { 'Visible' })
    $ui.btnAvancar.Content = $(if ($n -eq 2) { 'Continuar' } else { 'Salvar e continuar' })
}

function Marca($rb, $ok, $texto) {
    $rb.Content = $(if ($ok) { [string][char]0x2713 + '  ' } else { '' }) + $texto
    if ($ok) { $rb.Foreground = Cor '#34D399' } else { $rb.ClearValue([Windows.Controls.Control]::ForegroundProperty) }
}

function Get-GhSel { foreach ($rb in $ui.pnlGhUsers.Children) { if ($rb.IsChecked) { return [string]$rb.Tag } }; $null }

function Atualizar-Passos {
    $c = Conta-Atual
    $ehGh = ((Get-Prov) -eq 'GitHub')
    $u = Get-GhSel
    Marca $ui.rbP1 ([bool]($c -and (Test-Path $c.Chave))) '1  Criar chave'
    Marca $ui.rbP2 ($script:GhUsers.Count -gt 0) '2  Entrar no GitHub'
    Marca $ui.rbP3 ([bool]($c -and (-not $ehGh -or ($u -and $c.GhUser -eq $u -and ($script:GhUsers -contains $u))))) $(if ($ehGh) { '3  Vincular' } else { '3  Identidade' })
    Marca $ui.rbP4 ([bool]($c -and $c.Verificada)) $(if ($ehGh) { '4  Enviar e testar' } else { '4  Cadastrar e testar' })
    $ui.rbP2.Visibility = $(if ($ehGh) { 'Visible' } else { 'Collapsed' })
    $ui.pnlGh.Visibility = $(if ($ehGh) { 'Visible' } else { 'Collapsed' })
    $ui.rbP3.IsEnabled = [bool]$c; $ui.rbP4.IsEnabled = [bool]$c
    $ui.txtConta.Text = $(if ($c) { "CONTA  ·  $($c.Nome)" } else { 'NOVA CONTA' })
}

function Montar-Chips($sel) {
    $ui.pnlGhUsers.Children.Clear()
    $estilo = $win.FindResource('Chip')
    foreach ($u in $script:GhUsers) {
        $rb = New-Object Windows.Controls.RadioButton
        $rb.Style = $estilo; $rb.GroupName = 'ghuser'; $rb.Tag = $u
        $rb.Content = $(if ($u -eq $script:GhAtivo) { "$u  (ativo)" } else { $u })
        if ($u -eq $sel) { $rb.IsChecked = $true }
        $rb.Add_Checked({ Atualizar-Passos })
        [void]$ui.pnlGhUsers.Children.Add($rb)
    }
    $ui.txtSemUsuarios.Visibility = $(if ($script:GhUsers.Count -gt 0) { 'Collapsed' } else { 'Visible' })
}

function Atualizar-Gh {
    if (-not (Achar-Gh)) { Atualizar-Path }
    $script:Gh = Achar-Gh
    $botoes = 'btnLoginGh','btnListarGh','btnEnviar','btnAtivar'
    if (-not $script:Gh) {
        $ui.txtGh.Text = 'GitHub CLI não instalado. Clique em "Instalar GitHub CLI".'
        $ui.dotGh.Fill = Cor '#F87171'
        $ui.btnInstalarGh.Visibility = 'Visible'
        foreach ($b in $botoes) { $ui[$b].IsEnabled = $false }
        $script:GhUsers = @(); $script:GhAtivo = $null
        Montar-Chips $null; Atualizar-Passos; Atualizar-Tray
        return
    }
    $ui.btnInstalarGh.Visibility = 'Collapsed'
    foreach ($b in $botoes) { $ui[$b].IsEnabled = $true }
    $v = ((Invoke-Tool $script:Gh '--version').Out -split "`n" | Select-Object -First 1)
    Ler-GhUsers
    if ($script:GhUsers.Count -gt 0) {
        $ui.dotGh.Fill = Cor '#34D399'
        $ui.txtGh.Text = "$v`r`nativo: $($script:GhAtivo)   |   $($script:GhUsers.Count) conta(s) logada(s): $($script:GhUsers -join ', ')"
    } else {
        $ui.dotGh.Fill = Cor '#FBBF24'
        $ui.txtGh.Text = "$v`r`nnenhum login ainda. Clique em `"Entrar com GitHub`"."
    }
    $c = Conta-Atual
    $ui.btnEnviar.IsEnabled = [bool]($c -and $c.Provedor -eq 'GitHub')
    $sel = Get-GhSel; if (-not $sel -and $c) { $sel = $c.GhUser }
    Montar-Chips $sel
    Atualizar-Passos; Atualizar-Tray
}

function Proximo-Pendente($c) {
    if (-not (Test-Path $c.Chave)) { return 1 }
    if ($c.Provedor -eq 'GitHub') {
        if ($script:GhUsers.Count -eq 0) { return 2 }
        if (-not $c.GhUser) { return 3 }
    }
    return 4
}

function Mostrar-Conta($c) {
    $novo = -not $c
    $ui.pnlSenha.Visibility = $(if ($novo -or -not (Test-Path $c.Chave)) { 'Visible' } else { 'Collapsed' })
    $ui.txtAlias.IsEnabled = $novo
    $ui.pwdSenha.Password = ''
    if ($novo) {
        foreach ($t in 'txtNome','txtAlias','txtGitNome','txtGitEmail','txtPasta') { $ui[$t].Text = '' }
        Set-Prov 'GitHub'; $ui.txtHost.Text = $Hosts['GitHub']
        Montar-Chips $script:GhAtivo
        $ui.txtStatus.Text = 'Salve a conta (passo 1) para ver os detalhes aqui.'
        $ui.btnDesbloquear.Visibility = 'Collapsed'
        foreach ($b in 'btnCopiar','btnAbrir','btnEnviar','btnTestar','btnDesbloquear','btnExcluir') { $ui[$b].IsEnabled = $false }
        Atualizar-Passos
        Ir-Para 1
        return
    }
    Set-Prov $c.Provedor
    $ui.txtNome.Text = $c.Nome; $ui.txtAlias.Text = $c.Alias; $ui.txtHost.Text = $c.HostReal
    $ui.txtGitNome.Text = $c.GitNome; $ui.txtGitEmail.Text = $c.GitEmail; $ui.txtPasta.Text = $c.Pasta
    Montar-Chips $c.GhUser
    $st = "git clone git@$($c.Alias):ORGANIZACAO/REPOSITORIO.git`r`n"
    if ($c.GhUser) { $st += "Usuário GitHub: $($c.GhUser)`r`n" }
    if (Test-Path (Pub-Da $c)) { $st += (Invoke-Tool 'ssh-keygen' ("-lf `"{0}`"" -f (Pub-Da $c))).Out }
    else { $st += 'Chave não encontrada (volte ao passo 1 e salve para gerar).' }
    $ui.txtStatus.Text = $st
    foreach ($b in 'btnCopiar','btnTestar','btnDesbloquear','btnExcluir','btnAtivar') { $ui[$b].IsEnabled = $true }
    $ui.btnAbrir.IsEnabled = $Paginas.ContainsKey($c.Provedor)
    $ui.btnEnviar.IsEnabled = ($c.Provedor -eq 'GitHub' -and [bool]$script:Gh)
    $ui.btnAtivar.IsEnabled = [bool]$script:Gh
    $ui.btnDesbloquear.Visibility = $(if (Chave-ComSenha $c) { 'Visible' } else { 'Collapsed' })
    $ui.btnDesbloquear.IsEnabled = $true
    Atualizar-Passos
    if (-not $script:ManterPagina) { Ir-Para (Proximo-Pendente $c) }
}

function Recarregar-Lista($selecionar) {
    $ui.lstContas.ItemsSource = $null
    $ui.lstContas.ItemsSource = @($script:Contas)
    if ($selecionar) { $ui.lstContas.SelectedItem = ($script:Contas | Where-Object { $_.Alias -eq $selecionar } | Select-Object -First 1) }
}

# ---------- Chaves com senha (passphrase) ----------
# A senha digitada na criacao fica na memoria da sessao e, se o usuario deixar marcado, criptografada (DPAPI, so este usuario do Windows le).
$script:Senhas = @{}

function Proteger($s) { ConvertFrom-SecureString (ConvertTo-SecureString $s -AsPlainText -Force) }
function Ler-Protegida($p) {
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR((ConvertTo-SecureString $p))
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

# Executa uma ferramenta do OpenSSH entregando a senha via SSH_ASKPASS (a senha vai so no ambiente do processo filho, nunca na linha de comando).
function Rodar-Com-Senha($exe, $argStr, $senha) {
    $h = Join-Path $env:TEMP ("askpass-{0}.cmd" -f [guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($h, "@powershell -NoProfile -NonInteractive -Command `"[Console]::Out.WriteLine(`$env:SSHMGR_PASS)`"`r`n", [Text.Encoding]::ASCII)
    $env:SSHMGR_PASS = $senha; $env:SSH_ASKPASS = $h; $env:SSH_ASKPASS_REQUIRE = 'force'; $env:DISPLAY = 'sshmgr:0'
    try { Invoke-Tool $exe $argStr }
    finally {
        foreach ($v in 'SSHMGR_PASS', 'SSH_ASKPASS', 'SSH_ASKPASS_REQUIRE', 'DISPLAY') { [Environment]::SetEnvironmentVariable($v, $null, 'Process') }
        if (Test-Path $h) { [IO.File]::Delete($h) }
    }
}

function Chave-ComSenha($c) {
    if (-not $c -or -not (Test-Path $c.Chave)) { return $false }
    $r = Invoke-Tool 'ssh-keygen' ("-y -P `"`" -f `"{0}`"" -f $c.Chave)
    return ($r.Code -ne 0 -and $r.Out -match 'passphrase')
}

function Senha-Valida($c, $senha) {
    $r = Rodar-Com-Senha 'ssh-keygen' ("-y -f `"{0}`"" -f $c.Chave) $senha
    return ($r.Code -eq 0)
}

$senhaRaw = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" ResizeMode="NoResize" SizeToContent="WidthAndHeight"
        ShowInTaskbar="False" Topmost="True" FontFamily="__SANS__" FontSize="13" UseLayoutRounding="True">
  <Window.Resources>__RESOURCES__</Window.Resources>
  <Border Margin="16" Width="420" CornerRadius="16" Background="{StaticResource Bg}" BorderBrush="{StaticResource Line}" BorderThickness="1" TextElement.Foreground="{StaticResource Text}">
    <Border.Effect><DropShadowEffect BlurRadius="26" ShadowDepth="0" Opacity="0.6" Color="Black"/></Border.Effect>
    <StackPanel Margin="24">
      <TextBlock x:Name="titulo" FontSize="16" FontWeight="Bold" TextWrapping="Wrap"/>
      <TextBlock x:Name="msg" Foreground="{StaticResource Muted}" TextWrapping="Wrap" Margin="0,6,0,16"/>
      <PasswordBox x:Name="pw"/>
      <CheckBox x:Name="lembrar" IsChecked="True" Content="Lembrar neste computador (criptografada)" Margin="0,2,0,18"/>
      <DockPanel>
        <Button x:Name="ok" DockPanel.Dock="Right" IsDefault="True" Style="{StaticResource Primario}" Margin="0" Content="Confirmar"/>
        <Button x:Name="cancel" DockPanel.Dock="Right" IsCancel="True" Content="Cancelar" Margin="0,0,8,0"/>
        <TextBlock/>
      </DockPanel>
    </StackPanel>
  </Border>
</Window>
'@

function Pedir-Senha($c, $erro) {
    [xml]$px = Montar-Xaml $senhaRaw
    $d = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $px))
    if ($win.IsVisible) { $d.Owner = $win; $d.WindowStartupLocation = 'CenterOwner' } else { $d.WindowStartupLocation = 'CenterScreen' }
    $d.FindName('titulo').Text = "Senha da chave de '$($c.Nome)'"
    $d.FindName('msg').Text = $(if ($erro) { 'Senha incorreta. Tente novamente.' } else { 'Informe a senha (passphrase) desta chave SSH.' })
    $script:Dlg = $d; $script:DlgPw = $d.FindName('pw'); $script:DlgChk = $d.FindName('lembrar'); $script:DlgRes = $null
    $d.FindName('ok').Add_Click({ $script:DlgRes = @{ Senha = $script:DlgPw.Password; Lembrar = [bool]$script:DlgChk.IsChecked }; $script:Dlg.Close() })
    $d.Add_Loaded({ [void]$script:DlgPw.Focus() })
    [void]$d.ShowDialog()
    $script:DlgRes
}

# Devolve a senha valida da chave (da memoria, do disco ou perguntando); $null se cancelado.
function Obter-Senha($c) {
    $cand = $script:Senhas[$c.Alias]
    if (-not $cand -and $c.SenhaProt) { try { $cand = Ler-Protegida $c.SenhaProt } catch { $cand = $null } }
    if ($cand -and (Senha-Valida $c $cand)) { $script:Senhas[$c.Alias] = $cand; Log 'Usando a senha da chave informada anteriormente.'; return $cand }
    for ($i = 0; $i -lt 3; $i++) {
        $r = Pedir-Senha $c ($i -gt 0 -or [bool]$cand)
        if (-not $r) { return $null }
        if (Senha-Valida $c $r.Senha) {
            $script:Senhas[$c.Alias] = $r.Senha
            if ($r.Lembrar) { $c.SenhaProt = Proteger $r.Senha; Salvar-Contas }
            return $r.Senha
        }
    }
    Aviso 'Senha incorreta.' 'Warning'
    return $null
}

function Na-Agente($c) {
    if (-not (Test-Path (Pub-Da $c))) { return $false }
    $fp = ((Invoke-Tool 'ssh-keygen' ("-lf `"{0}`"" -f (Pub-Da $c))).Out -split '\s+')[1]
    if (-not $fp) { return $false }
    $l = Invoke-Tool 'ssh-add' '-l'
    return ($l.Code -eq 0 -and $l.Out.Contains($fp))
}

# O servico ssh-agent vem desativado no Windows; ativar exige administrador (pede UAC uma vez).
function Garantir-Agente {
    $svc = Get-Service ssh-agent -ErrorAction SilentlyContinue
    if (-not $svc) { Aviso 'Serviço ssh-agent não encontrado. Ative o "Cliente OpenSSH" nos Recursos Opcionais do Windows.' 'Error'; return $false }
    if ($svc.Status -eq 'Running') { return $true }
    $res = [Windows.MessageBox]::Show($win, "Para manter a chave liberada, o Windows precisa ativar o serviço ssh-agent (inicialização automática).`n`nO Windows vai pedir permissão de administrador. Continuar?", 'Ativar ssh-agent', 'YesNo', 'Question')
    if ($res -ne 'Yes') { return $false }
    try {
        [void](Start-Process powershell -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList '-NoProfile', '-Command', 'Set-Service ssh-agent -StartupType Automatic; Start-Service ssh-agent')
    } catch { Log 'Ativação do ssh-agent cancelada.'; return $false }
    Start-Sleep -Seconds 1
    $svc = Get-Service ssh-agent -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') { Log 'Serviço ssh-agent ativado.'; return $true }
    Aviso 'Não foi possível ativar o ssh-agent.' 'Warning'; return $false
}

function Desbloquear-Chave($c) {
    $senha = Obter-Senha $c; if (-not $senha) { return }
    if (-not (Garantir-Agente)) { return }
    $add = (Get-Command ssh-add -ErrorAction SilentlyContinue).Source
    if (-not $add) { Aviso 'ssh-add não encontrado.' 'Error'; return }
    $r = Rodar-Com-Senha $add ("`"{0}`"" -f $c.Chave) $senha
    Log "ssh-add: $($r.Out)"
    if (Na-Agente $c) { Aviso 'Chave liberada no ssh-agent: git clone/push e o teste não pedirão a senha.' }
    else { Aviso "Não foi possível adicionar a chave ao ssh-agent:`n$($r.Out)" 'Warning' }
}

function Testar-Conexao($c) {
    $senha = $null
    if (Chave-ComSenha $c) {
        $senha = Obter-Senha $c
        if (-not $senha) { Log 'Teste cancelado: senha da chave não informada.'; return }
    }
    $win.Cursor = 'Wait'; Log "Testando ssh -T $($c.Alias) ..."
    if ($senha) { $r = Rodar-Com-Senha 'ssh' "-T -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new $($c.Alias)" $senha }
    else { $r = Invoke-Tool 'ssh' "-T -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new $($c.Alias)" }
    $win.Cursor = $null
    Log $r.Out
    if ($r.Out -match 'successfully authenticated|logged in as|authenticated via|Welcome to GitLab') {
        $quem = $null
        if ($r.Out -match 'Hi (\S+?)!') { $quem = $Matches[1] }
        if ($c.Provedor -eq 'GitHub' -and $c.GhUser -and $quem -and $quem -ne $c.GhUser) {
            $c.Verificada = $false
            Aviso "Esta chave autentica como '$quem' no GitHub, mas está vinculada a '$($c.GhUser)'.`nA chave foi cadastrada na conta errada: remova-a de '$quem' e envie novamente com '$($c.GhUser)' ativo." 'Warning'
        } else {
            $c.Verificada = $true
            Aviso "Conexão OK para '$($c.Nome)'$(if ($quem) { " (GitHub: $quem)" }).`n`n$($r.Out)"
        }
    } elseif ($r.Out -match 'Permission denied') {
        $c.Verificada = $false
        Aviso "Acesso negado. A chave pública já foi cadastrada no site? (Se a chave tiver senha, teste no terminal: ssh -T $($c.Alias))" 'Warning'
    } else {
        $c.Verificada = $false
        Aviso "Resultado:`n$($r.Out)" 'Warning'
    }
    Salvar-Contas; Atualizar-Passos
}

# Cria a chave (se preciso), grava o Host no ~/.ssh/config e vincula o usuario do GitHub. Retorna $true se salvou.
function Salvar-Conta {
    $atual = Conta-Atual
    $nome = $ui.txtNome.Text.Trim(); $prov = Get-Prov; $hostReal = $ui.txtHost.Text.Trim(); $alias = $ui.txtAlias.Text.Trim()
    if (-not $nome -or -not $hostReal) { Aviso 'Informe o nome da conta e o servidor (passo 1).' 'Warning'; Ir-Para 1; return $false }
    if ($atual) { $alias = $atual.Alias }
    elseif (-not $alias) { $alias = (("$prov-$nome").ToLower() -replace '[^a-z0-9]+', '-').Trim('-') }
    if ($alias -notmatch '^[a-z0-9][a-z0-9-]*$') { Aviso 'O apelido deve ter só letras minúsculas, números e hífen.' 'Warning'; Ir-Para 1; return $false }
    if (-not $atual -and ($script:Contas | Where-Object { $_.Alias -eq $alias })) { Aviso "Já existe uma conta com o apelido '$alias'." 'Warning'; Ir-Para 1; return $false }
    if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) { Aviso 'ssh-keygen não encontrado. Ative o "Cliente OpenSSH" nos Recursos Opcionais do Windows.' 'Error'; return $false }

    if (-not (Test-Path $SshDir)) { New-Item -ItemType Directory -Path $SshDir -Force | Out-Null }
    $chave = Join-Path $SshDir "id_ed25519_$alias"
    $email = $ui.txtGitEmail.Text.Trim()
    $senhaProt = $null
    if (-not (Test-Path $chave)) {
        $senhaPura = $ui.pwdSenha.Password
        $senha = $senhaPura -replace '"', '\"'
        $r = Invoke-Tool 'ssh-keygen' ("-t ed25519 -f `"{0}`" -N `"{1}`" -C `"{2}`"" -f $chave, $senha, $(if ($email) { $email } else { "$alias@$env:COMPUTERNAME" }))
        if ($r.Code -ne 0) { Log "ERRO ao gerar chave: $($r.Out)"; Aviso "Falha ao gerar a chave:`n$($r.Out)" 'Error'; return $false }
        Log "Chave gerada: $chave"
        if ($senhaPura) { $script:Senhas[$alias] = $senhaPura; if ($ui.chkLembrar.IsChecked) { $senhaProt = Proteger $senhaPura } }
    } else { Log "Usando chave existente: $chave" }

    $ghUser = $null
    if ($prov -eq 'GitHub') {
        $ghUser = Get-GhSel
        if (-not $ghUser -and $atual) { $ghUser = $atual.GhUser }
        if (-not $ghUser -and $script:Pag -eq 3) { Log 'Atenção: nenhum usuário do GitHub vinculado (faça login no passo 2 e selecione um).' }
    }
    $pasta = $ui.txtPasta.Text.Trim()
    $conta = [pscustomobject]@{
        Alias = $alias; Nome = $nome; Provedor = $prov; HostReal = $hostReal; Chave = $chave
        GitNome = $ui.txtGitNome.Text.Trim(); GitEmail = $email; Pasta = $pasta
        GhUser = $ghUser
        SenhaProt = $(if ($senhaProt) { $senhaProt } elseif ($atual) { $atual.SenhaProt } else { $null })
        Verificada = [bool]($atual -and $atual.Verificada -and $atual.GhUser -eq $ghUser)
        Etiqueta = ("{0}  ({1})" -f $nome, $alias)
    }
    if ($atual) { Remover-Include $atual }
    Gravar-Bloco $conta
    if ($pasta) {
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Log 'Git não encontrado: identidade por pasta não aplicada.' }
        else { Gravar-Include $conta; Log "Identidade git aplicada à pasta $pasta" }
    }
    $script:Contas = @($script:Contas | Where-Object { $_.Alias -ne $alias }) + $conta
    Salvar-Contas
    Log "Conta '$nome' salva (Host $alias -> $hostReal$(if ($ghUser) { ", usuário GitHub $ghUser" }))."
    $script:ManterPagina = $true
    Recarregar-Lista $alias
    $script:ManterPagina = $false
    return $true
}

# ---------- Eventos ----------
foreach ($r in $provBtns) {
    $r.Add_Checked({
        $p = Get-Prov
        if ($Hosts.ContainsKey($p) -and -not (Conta-Atual)) { $ui.txtHost.Text = $Hosts[$p] }
        Atualizar-Passos
    })
}
foreach ($i in 1..4) {
    $ui["rbP$i"].Add_Checked({ param($s, $e) if (-not $script:Interno) { Ir-Para ([int]$s.Tag) } })
}

$ui.barra.Add_MouseLeftButtonDown({ $win.DragMove() })
$ui.btnMin.Add_Click({ $win.WindowState = 'Minimized' })
$ui.btnFechar.Add_Click({ $win.Hide() })
$win.Add_Closing({ param($s, $e) if (-not $script:Sair) { $e.Cancel = $true; $win.Hide() } })

$ui.lstContas.Add_SelectionChanged({ if (Conta-Atual) { Mostrar-Conta (Conta-Atual) } })
$ui.btnNova.Add_Click({ $ui.lstContas.SelectedItem = $null; Mostrar-Conta $null })

$ui.btnPasta.Add_Click({
    $d = New-Object Windows.Forms.FolderBrowserDialog
    $d.Description = 'Pasta que contém os projetos desta conta'
    if ($d.ShowDialog() -eq 'OK') { $ui.txtPasta.Text = $d.SelectedPath }
})

$ui.btnVoltar.Add_Click({ Ir-Para (Anterior $script:Pag) })
$ui.btnAvancar.Add_Click({
    $n = $script:Pag
    if ($n -eq 1 -or $n -eq 3) { if (-not (Salvar-Conta)) { return } }
    Ir-Para (Proxima $n)
})

$ui.btnCopiar.Add_Click({
    $c = Conta-Atual
    if (-not $c -or -not (Test-Path (Pub-Da $c))) { Aviso 'Chave pública não encontrada.' 'Warning'; return }
    [Windows.Clipboard]::SetText((Get-Content (Pub-Da $c) -Raw).Trim())
    Log "Chave pública de '$($c.Nome)' copiada para a área de transferência."
})

$ui.btnAbrir.Add_Click({
    $c = Conta-Atual
    if ($c -and $Paginas.ContainsKey($c.Provedor)) {
        if (Test-Path (Pub-Da $c)) { [Windows.Clipboard]::SetText((Get-Content (Pub-Da $c) -Raw).Trim()); Log 'Chave pública copiada; cole no campo "Key" do site.' }
        Start-Process $Paginas[$c.Provedor]
    }
})

$ui.btnTestar.Add_Click({ $c = Conta-Atual; if ($c) { Testar-Conexao $c } })
$ui.btnDesbloquear.Add_Click({ $c = Conta-Atual; if ($c) { Desbloquear-Chave $c } })

$ui.btnAtivar.Add_Click({
    $u = Get-GhSel
    if (-not $u) { Aviso 'Selecione um usuário do GitHub.' 'Warning'; return }
    Trocar-Usuario $u
})

# Passo 4: ativa o usuario vinculado, envia a chave e testa
$ui.btnEnviar.Add_Click({
    $c = Conta-Atual; if (-not $c -or -not $script:Gh) { return }
    if (-not $c.GhUser) { Aviso 'Selecione o usuário do GitHub desta chave e salve (passo 3).' 'Warning'; Ir-Para 3; return }
    if ($script:GhUsers -notcontains $c.GhUser) { Aviso "O usuário '$($c.GhUser)' não está logado no gh. Entre com essa conta no passo 2." 'Warning'; Ir-Para 2; return }
    $win.Cursor = 'Wait'
    $s = Invoke-Tool $script:Gh "auth switch -h github.com -u $($c.GhUser)"
    Log "gh auth switch -u $($c.GhUser) : $($s.Out)"
    if ($s.Code -ne 0) { $win.Cursor = $null; Aviso "Não foi possível ativar '$($c.GhUser)':`n$($s.Out)" 'Warning'; return }
    $r = Invoke-Tool $script:Gh ("ssh-key add `"{0}`" -t `"{1} - {2}`"" -f (Pub-Da $c), $env:COMPUTERNAME, $c.Alias)
    $win.Cursor = $null
    Log "gh ssh-key add: $($r.Out)"
    Atualizar-Gh
    if ($r.Code -eq 0 -or $r.Out -match 'already in use') { Testar-Conexao $c }
    elseif ($r.Out -match 'scope|admin:public_key') { Aviso 'O login do gh não tem permissão para chaves SSH. Refaça "Entrar com GitHub" (passo 2) e autorize novamente.' 'Warning' }
    else { Aviso $r.Out 'Warning' }
})

$ui.btnExcluir.Add_Click({
    $c = Conta-Atual; if (-not $c) { return }
    $res = [Windows.MessageBox]::Show($win, "Excluir a conta '$($c.Nome)'?`n`nSim = remove também os arquivos da chave (irreversível)`nNão = mantém os arquivos da chave`nCancelar = não faz nada", 'Excluir conta', 'YesNoCancel', 'Warning')
    if ($res -eq 'Cancel') { return }
    Apagar-Bloco $c.Alias
    Remover-Include $c
    if ($res -eq 'Yes') { Remove-Item $c.Chave, (Pub-Da $c) -Force -ErrorAction SilentlyContinue; Log 'Arquivos da chave removidos.' }
    $script:Contas = @($script:Contas | Where-Object { $_.Alias -ne $c.Alias })
    Salvar-Contas; Log "Conta '$($c.Nome)' excluída. Lembre-se de remover a chave também no site."
    Recarregar-Lista $null; Mostrar-Conta $null
})

# --- GitHub CLI: instalacao (winget) e login ---
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(2)
$timer.Add_Tick({
    if ($script:Instalando -and $script:Instalando.HasExited) {
        Log "winget finalizou (código $($script:Instalando.ExitCode))."
        $script:Instalando = $null
        $ui.btnInstalarGh.IsEnabled = $true
        Atualizar-Gh
        if (-not $script:Gh) { Aviso 'Não foi possível confirmar a instalação do GitHub CLI. Veja o log.' 'Warning' }
    }
    if ($script:Login -and $script:Login.HasExited) {
        $script:Login = $null
        Atualizar-Gh
        if ($script:GhAtivo) {
            Montar-Chips $script:GhAtivo
            Atualizar-Passos
            Log "Login concluído. Usuário ativo no gh: $($script:GhAtivo)."
            $tray.ShowBalloonTip(2500, 'GitHub', "Login concluído: $($script:GhAtivo)", [Windows.Forms.ToolTipIcon]::Info)
        } else { Log 'Login não concluído.' }
    }
    if (-not $script:Instalando -and -not $script:Login) { $timer.Stop() }
})

$ui.btnInstalarGh.Add_Click({
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { Aviso 'winget não encontrado. Instale o "App Installer" pela Microsoft Store.' 'Error'; return }
    $ui.btnInstalarGh.IsEnabled = $false
    $ui.txtGh.Text = 'Instalando GitHub CLI via winget... (aceite o aviso do Windows, se aparecer)'
    Log 'winget install GitHub.cli'
    $script:Instalando = Start-Process winget -ArgumentList 'install --id GitHub.cli -e --accept-source-agreements --accept-package-agreements' -WindowStyle Hidden -PassThru
    $timer.Start()
})

# Passo 2: login no GitHub (pode ser repetido para adicionar outras contas)
$ui.btnLoginGh.Add_Click({
    if (-not $script:Gh) { return }
    $script:Login = Start-Process cmd -ArgumentList '/c', ('""{0}" auth login -h github.com -p ssh -w --skip-ssh-key -s admin:public_key,write:ssh_signing_key & echo. & pause"' -f $script:Gh) -PassThru
    Log 'Login do GitHub aberto em outra janela: siga as instruções (código + navegador). Repita para adicionar outra conta.'
    $timer.Start()
})

$ui.btnListarGh.Add_Click({
    if ($script:Gh) { $r = Invoke-Tool $script:Gh 'ssh-key list'; Log "gh ssh-key list (usuário ativo):`r`n$($r.Out)" }
})
$win.Add_Activated({ if (-not $script:Instalando -and -not $script:Login) { Atualizar-Gh } })

# Outra execucao pediu para abrir a janela
$timerMostrar = New-Object Windows.Threading.DispatcherTimer
$timerMostrar.Interval = [TimeSpan]::FromMilliseconds(600)
$timerMostrar.Add_Tick({ if ($evMostrar.WaitOne(0)) { Mostrar-Janela } })
$timerMostrar.Start()

# ---------- Inicio ----------
Carregar-Contas
Recarregar-Lista $null
Atualizar-Gh
Mostrar-Conta $null
if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) { Log 'AVISO: Cliente OpenSSH ausente (ssh-keygen).' }
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Log 'AVISO: Git ausente - a identidade por pasta não será aplicada.' }
Log "Pronto. Chaves e config em $SshDir. O app continua na bandeja ao fechar a janela."
if (-not $iniciarOculto) { Mostrar-Janela }
if ($args -contains '--popup') { Abrir-Popup }   # uso interno: abre o menu flutuante ao iniciar
[void]$app.Run()
$mutex.ReleaseMutex()

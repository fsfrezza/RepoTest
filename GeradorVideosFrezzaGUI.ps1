Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:CancelarGeracao = $false
$script:ProcessoAtual = $null
$script:TemaEscuro = $false
$script:ProjetoAtualPath = ""
$script:CoverPreviewForm = $null
$script:CoverPreviewPicture = $null
$script:CoverCacheDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "FrezzaVideoCoverCache"
try { New-Item -ItemType Directory -Path $script:CoverCacheDirectory -Force -ErrorAction SilentlyContinue | Out-Null } catch { }

$ToleranciaSegundosFixa = 1.5

function Add-Log {
    param(
        [System.Windows.Forms.TextBox]$LogBox,
        [string]$Mensagem
    )

    try {
        if ($null -ne $LogBox) {
            $LogBox.AppendText($Mensagem + [Environment]::NewLine)
            $LogBox.SelectionStart = $LogBox.Text.Length
            $LogBox.ScrollToCaret()
        }
    }
    catch {
        # Mantém o processamento mesmo se a caixa de log estiver indisponível.
    }

    try {
        if (-not [string]::IsNullOrWhiteSpace($script:LogPath)) {
            $LinhaLog = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Mensagem
            Add-Content -LiteralPath $script:LogPath -Value $LinhaLog -Encoding UTF8 -ErrorAction SilentlyContinue
        }
    }
    catch {
        # Não interrompe o aplicativo por falha ao gravar log.
    }

    [System.Windows.Forms.Application]::DoEvents()
}


function Test-SafePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    try {
        return (Test-Path -LiteralPath $Path -ErrorAction SilentlyContinue)
    }
    catch {
        return $false
    }
}

function Remove-SafeItem {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    try {
        if (Test-SafePath -Path $Path) {
            Remove-Item -LiteralPath $Path -Force -Recurse -ErrorAction SilentlyContinue
        }
    }
    catch {
        # Ignora remoção.
    }
}

function New-SafeDirectory {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    try {
        if (-not (Test-SafePath -Path $Path)) {
            New-Item -ItemType Directory -Path $Path -Force -ErrorAction SilentlyContinue | Out-Null
        }

        return (Test-SafePath -Path $Path)
    }
    catch {
        return $false
    }
}

function Join-SafePath {
    param(
        [string]$Base,
        [string]$Child
    )

    if ([string]::IsNullOrWhiteSpace($Base)) {
        return ""
    }

    if ([string]::IsNullOrWhiteSpace($Child)) {
        return $Base
    }

    try {
        return (Join-Path $Base $Child)
    }
    catch {
        return ""
    }
}

function Get-AppRoot {
    try {
        if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
            return $PSScriptRoot
        }

        if ($MyInvocation.MyCommand.Path) {
            $Parent = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
            if (-not [string]::IsNullOrWhiteSpace($Parent)) {
                return $Parent
            }
        }

        $ProcessPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if (-not [string]::IsNullOrWhiteSpace($ProcessPath)) {
            $Parent = Split-Path -Path $ProcessPath -Parent
            if (-not [string]::IsNullOrWhiteSpace($Parent)) {
                return $Parent
            }
        }

        if (-not [string]::IsNullOrWhiteSpace([AppDomain]::CurrentDomain.BaseDirectory)) {
            return [AppDomain]::CurrentDomain.BaseDirectory
        }

        return [Environment]::CurrentDirectory
    }
    catch {
        return [Environment]::CurrentDirectory
    }
}

$script:AppRoot = Get-AppRoot
$script:AppIconPath = Join-SafePath $script:AppRoot "FrezzaApp.ico"
$script:LogDirectory = Join-SafePath $script:AppRoot "logs"
try { New-Item -ItemType Directory -Path $script:LogDirectory -Force -ErrorAction SilentlyContinue | Out-Null } catch { }
$script:LogPath = Join-SafePath $script:LogDirectory ("FrezzaApp_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")
try { Add-Content -LiteralPath $script:LogPath -Value ("Log iniciado em " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss")) -Encoding UTF8 -ErrorAction SilentlyContinue } catch { }

function Split-SafeParent {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    try {
        return (Split-Path -Path $Path -Parent -ErrorAction SilentlyContinue)
    }
    catch {
        return ""
    }
}

function Split-SafeLeaf {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    try {
        return (Split-Path -Path $Path -Leaf -ErrorAction SilentlyContinue)
    }
    catch {
        return ""
    }
}

function Select-Folder {
    param([string]$InitialPath)

    $Dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $Dialog.Description = "Selecione a pasta"
    $Dialog.ShowNewFolderButton = $true

    if (-not [string]::IsNullOrWhiteSpace($InitialPath)) {
        try {
            if (Test-SafePath -Path $InitialPath) {
                $Dialog.SelectedPath = $InitialPath
            }
        }
        catch {
            # Caminho inválido; apenas abre o seletor sem pasta inicial.
        }
    }

    if ($Dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $Dialog.SelectedPath
    }

    return $InitialPath
}

function Resolve-Executable {
    param([string]$Name)

    $Command = Get-Command $Name -ErrorAction SilentlyContinue

    if ($Command) {
        return $Command.Source
    }

    $Local = Join-SafePath $script:AppRoot $Name

    if (Test-SafePath -Path $Local) {
        return $Local
    }

    return $null
}

function Resolve-FontFile {
    $Candidates = @(
        "C:\Windows\Fonts\GOTHIC.TTF",
        "C:\Windows\Fonts\GOTHICB.TTF",
        "C:\Windows\Fonts\arial.ttf"
    )

    foreach ($Candidate in $Candidates) {
        if (Test-Path -LiteralPath $Candidate) {
            return $Candidate
        }
    }

    return $null
}

function Convert-FontPathForFfmpeg {
    param([string]$Path)

    $Converted = $Path -replace "\\", "/"
    $Converted = $Converted -replace ":", "\:"
    return $Converted
}

function Escape-DrawText {
    param([string]$Text)

    $Escaped = $Text
    $Escaped = $Escaped -replace "\\", "\\\\"
    $Escaped = $Escaped -replace ":", "\:"
    $Escaped = $Escaped -replace "'", "\\'"
    $Escaped = $Escaped -replace ",", "\,"
    $Escaped = $Escaped -replace "\[", "\["
    $Escaped = $Escaped -replace "\]", "\]"
    return $Escaped
}

function Format-YouTubeTimestamp {
    param([double]$Seconds)

    if ($Seconds -lt 0) {
        $Seconds = 0
    }

    $TotalSeconds = [int][Math]::Floor($Seconds)

    $Hours = [int][Math]::Floor($TotalSeconds / 3600)
    $Remainder = $TotalSeconds % 3600

    $Minutes = [int][Math]::Floor($Remainder / 60)
    $Secs = $Remainder % 60

    if ($Hours -gt 0) {
        return "{0}:{1:D2}:{2:D2}" -f $Hours, $Minutes, $Secs
    }

    return "{0:D2}:{1:D2}" -f $Minutes, $Secs
}

function Get-CleanTrackTitle {
    param([string]$Title)

    if ([string]::IsNullOrWhiteSpace($Title)) {
        return ""
    }

    return (Remove-TrackNumberPrefix -Title $Title).Trim()
}

function New-AlbumTimestampDescription {
    param(
        [System.IO.FileInfo[]]$Musicas,
        [double[]]$Duracoes,
        [double]$SilencioEntreFaixas = 0
    )

    $Lines = New-Object System.Collections.Generic.List[string]
    $CurrentTime = 0.0

    for ($i = 0; $i -lt $Musicas.Count; $i++) {
        $Timestamp = Format-YouTubeTimestamp -Seconds $CurrentTime
        $TrackName = Get-CleanTrackTitle -Title $Musicas[$i].BaseName

        $Lines.Add("$Timestamp - $TrackName")

        $CurrentTime += [double]$Duracoes[$i]

        if ($i -lt ($Musicas.Count - 1)) {
            $CurrentTime += [double]$SilencioEntreFaixas
        }
    }

    return ($Lines -join [Environment]::NewLine)
}

function Get-AlbumTracksForPublishedVideo {
    param([System.IO.FileInfo]$ArquivoVideo)

    if ($null -eq $ArquivoVideo) {
        return @()
    }

    $AlbumFolderName = Split-SafeLeaf -Path (Split-SafeParent -Path $ArquivoVideo.FullName)

    $Candidates = @()

    if ($null -ne $TextPastaMP3 -and -not [string]::IsNullOrWhiteSpace($TextPastaMP3.Text)) {
        $Candidates += (Join-SafePath $TextPastaMP3.Text $AlbumFolderName)
        $Candidates += $TextPastaMP3.Text
    }

    $Config = Load-AppConfig

    if ($Config -and -not [string]::IsNullOrWhiteSpace([string]$Config.PastaMP3)) {
        $Candidates += (Join-SafePath ([string]$Config.PastaMP3) $AlbumFolderName)
        $Candidates += ([string]$Config.PastaMP3)
    }

    foreach ($Candidate in $Candidates) {
        if ([string]::IsNullOrWhiteSpace($Candidate)) {
            continue
        }

        if (Test-SafePath -Path $Candidate) {
            $Musicas = @(Get-ChildItem -LiteralPath $Candidate -Filter "*.mp3" -File -ErrorAction SilentlyContinue | Sort-Object Name)

            if ($Musicas.Count -gt 0) {
                return $Musicas
            }
        }
    }

    return @()
}

function Apply-AlbumPublishMetadata {
    param([object]$Item)

    if ($null -eq $Item) {
        return
    }

    $BaseName = [System.IO.Path]::GetFileNameWithoutExtension([string]$Item.FileName)

    if (
        $BaseName -notmatch '^\s*Álbum Completo\s*[-–—]\s*(.+)$' -and
        $BaseName -notmatch '^\s*Album Completo\s*[-–—]\s*(.+)$'
    ) {
        return
    }

    $AlbumName = Get-CleanAlbumName -NomeAlbum $Matches[1]
    $Item.Title = "Álbum Completo - $AlbumName"

    $Metadata = Load-AlbumPublishMetadataForVideo -VideoPath ([string]$Item.FilePath)

    if ($Metadata) {
        if (-not [string]::IsNullOrWhiteSpace([string]$Metadata.title)) {
            $Item.Title = [string]$Metadata.title
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$Metadata.description)) {
            $Item.Description = [string]$Metadata.description
        }

        return
    }
}

function Repair-PublishItemFromPath {
    param([object]$Item)

    if ($null -eq $Item) { return $Item }

    $FilePath = [string]$Item.FilePath
    if ([string]::IsNullOrWhiteSpace($FilePath)) { return $Item }

    $ActualFileName = ""
    $ActualBaseName = ""

    try {
        $ActualFileName = [System.IO.Path]::GetFileName($FilePath)
        $ActualBaseName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    }
    catch {
        return $Item
    }

    if (-not [string]::IsNullOrWhiteSpace($ActualFileName)) {
        try { $Item.FileName = $ActualFileName } catch { }
    }

    # Corrige filas antigas salvas com título/nome concatenado quando o arquivo real é de álbum.
    if (
        $ActualBaseName -match '^\s*Álbum Completo\s*[-–—]\s*(.+)$' -or
        $ActualBaseName -match '^\s*Album Completo\s*[-–—]\s*(.+)$'
    ) {
        $AlbumName = Get-CleanAlbumName -NomeAlbum $Matches[1]
        $Item.Title = "Álbum Completo - $AlbumName"
    }
    elseif ([string]::IsNullOrWhiteSpace([string]$Item.Title)) {
        $Item.Title = Remove-TrackNumberPrefix -Title $ActualBaseName
    }

    Apply-AlbumPublishMetadata -Item $Item
    return $Item
}

function AutoSize-PublishGridColumns {
    if ($null -eq $GridPublicacao) { return }

    try {
        $GridPublicacao.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::None

        foreach ($Column in $GridPublicacao.Columns) {
            $Column.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::None
        }

        if ($GridPublicacao.Columns.Contains("Caminho")) {
            $GridPublicacao.Columns["Caminho"].AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
            $GridPublicacao.Columns["Caminho"].MinimumWidth = 260
            $GridPublicacao.Columns["Caminho"].FillWeight = 100
        }
    }
    catch {
    }
}

function Format-Duration {
    param([double]$Segundos)

    $Tempo = [TimeSpan]::FromSeconds($Segundos)

    if ($Tempo.TotalHours -ge 1) {
        return "{0}:{1:D2}:{2:D2}" -f [int]$Tempo.TotalHours, $Tempo.Minutes, $Tempo.Seconds
    }

    return "{0}:{1:D2}" -f [int]$Tempo.TotalMinutes, $Tempo.Seconds
}

function Format-Seconds {
    param([double]$Segundos)

    return $Segundos.ToString("0.##", [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-MediaDuration {
    param(
        [string]$Arquivo,
        [string]$FfprobePath
    )

    if (-not (Test-SafePath -Path $Arquivo)) {
        return $null
    }

    try {
        $Raw = & $FfprobePath `
            -v quiet `
            -show_entries format=duration `
            -of default=noprint_wrappers=1:nokey=1 `
            "$Arquivo" 2>$null

        if ([string]::IsNullOrWhiteSpace($Raw)) {
            return $null
        }

        return [double]::Parse($Raw.Trim(), [System.Globalization.CultureInfo]::InvariantCulture)
    }
    catch {
        return $null
    }
}

function Get-VideoDimensions {
    param(
        [string]$Arquivo,
        [string]$FfprobePath
    )

    $Default = @{ Width = 1920; Height = 1080 }

    if (-not (Test-SafePath -Path $Arquivo)) {
        return $Default
    }

    if ([string]::IsNullOrWhiteSpace($FfprobePath) -or -not (Test-SafePath -Path $FfprobePath)) {
        return $Default
    }

    try {
        $Raw = & $FfprobePath `
            -v error `
            -select_streams v:0 `
            -show_entries stream=width,height `
            -of csv=s=x:p=0 `
            "$Arquivo" 2>$null

        if ([string]::IsNullOrWhiteSpace($Raw)) {
            return $Default
        }

        $Partes = ($Raw.Trim() -split "x")
        if ($Partes.Count -lt 2) {
            return $Default
        }

        $W = 0
        $H = 0
        if (-not [int]::TryParse($Partes[0], [ref]$W)) { return $Default }
        if (-not [int]::TryParse($Partes[1], [ref]$H)) { return $Default }

        if ($W -le 0 -or $H -le 0) {
            return $Default
        }

        return @{ Width = $W; Height = $H }
    }
    catch {
        return $Default
    }
}


function ConvertTo-ArgumentLine {
    param([string[]]$Argumentos)

    return ($Argumentos | ForEach-Object {
        $Arg = [string]$_

        if ($Arg -match '\s|"') {
            '"' + ($Arg -replace '"', '\"') + '"'
        }
        else {
            $Arg
        }
    }) -join ' '
}

function Write-DurationLine {
    param(
        [System.Windows.Forms.TextBox]$LogBox,
        [string]$Rotulo,
        [double]$Segundos
    )

    $Texto = "{0}: {1} ({2} segundos)" -f $Rotulo, (Format-Duration $Segundos), (Format-Seconds $Segundos)
    Add-Log -LogBox $LogBox -Mensagem $Texto
}

function Test-ExistingVideo {
    param(
        [string]$ArquivoVideo,
        [double]$DuracaoEsperada,
        [double]$ToleranciaSegundos,
        [string]$FfprobePath
    )

    if (-not (Test-SafePath -Path $ArquivoVideo)) {
        return [PSCustomObject]@{
            Existe  = $false
            Valido  = $false
            Duracao = $null
        }
    }

    $DuracaoExistente = Get-MediaDuration -Arquivo $ArquivoVideo -FfprobePath $FfprobePath

    if ($null -eq $DuracaoExistente) {
        return [PSCustomObject]@{
            Existe  = $true
            Valido  = $false
            Duracao = $null
        }
    }

    $Diferenca = [math]::Abs($DuracaoExistente - $DuracaoEsperada)

    return [PSCustomObject]@{
        Existe  = $true
        Valido  = ($Diferenca -le $ToleranciaSegundos)
        Duracao = $DuracaoExistente
    }
}

function Invoke-Ffmpeg {
    param(
        [string]$FfmpegPath,
        [string[]]$Argumentos,
        [bool]$Detalhado,
        [System.Windows.Forms.Label]$StatusLabel,
        [System.Windows.Forms.TextBox]$LogBox
    )

    $TempOut = [System.IO.Path]::GetTempFileName()
    $TempErr = [System.IO.Path]::GetTempFileName()

    try {
        $ArgumentLine = ConvertTo-ArgumentLine -Argumentos $Argumentos

        $Processo = Start-Process `
            -FilePath $FfmpegPath `
            -ArgumentList $ArgumentLine `
            -RedirectStandardOutput $TempOut `
            -RedirectStandardError $TempErr `
            -WindowStyle Hidden `
            -PassThru

        $script:ProcessoAtual = $Processo

        $Pontos = 0

        while (-not $Processo.HasExited) {
            if ($script:CancelarGeracao) {
                try {
                    if (-not $Processo.HasExited) {
                        $Processo.Kill()
                    }

                    $Processo.WaitForExit()
                }
                catch {
                    # Processo já encerrado ou inacessível.
                }

                $StatusLabel.Text = "Interrompido."
                $StatusLabel.Refresh()
                return -999
            }

            $StatusLabel.Text = "Processando" + ("." * $Pontos)
            $StatusLabel.Refresh()

            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Seconds 1
            $Pontos++

            if ($Pontos -gt 3) {
                $Pontos = 0
            }
        }

        $Processo.WaitForExit()

        if ($script:CancelarGeracao) {
            $StatusLabel.Text = "Interrompido."
            $StatusLabel.Refresh()
            return -999
        }

        $ExitCode = $Processo.ExitCode

        if ($Detalhado) {
            $OutText = Get-Content -LiteralPath $TempOut -Raw -ErrorAction SilentlyContinue
            $ErrText = Get-Content -LiteralPath $TempErr -Raw -ErrorAction SilentlyContinue

            if (-not [string]::IsNullOrWhiteSpace($OutText)) {
                Add-Log -LogBox $LogBox -Mensagem $OutText.TrimEnd()
            }

            if (-not [string]::IsNullOrWhiteSpace($ErrText)) {
                Add-Log -LogBox $LogBox -Mensagem $ErrText.TrimEnd()
            }
        }
        elseif ($ExitCode -ne 0 -and -not $script:CancelarGeracao) {
            $ErrText = Get-Content -LiteralPath $TempErr -Raw -ErrorAction SilentlyContinue

            if (-not [string]::IsNullOrWhiteSpace($ErrText)) {
                Add-Log -LogBox $LogBox -Mensagem $ErrText.TrimEnd()
            }
        }

        $StatusLabel.Text = "Pronto"
        $StatusLabel.Refresh()

        return $ExitCode
    }
    catch {
        if ($script:CancelarGeracao) {
            $StatusLabel.Text = "Interrompido."
            $StatusLabel.Refresh()
            return -999
        }

        Add-Log -LogBox $LogBox -Mensagem "ERRO ao executar ffmpeg: $($_.Exception.Message)"
        $StatusLabel.Text = "Erro."
        return -1
    }
    finally {
        $script:ProcessoAtual = $null

        foreach ($ArquivoTemp in @($TempOut, $TempErr)) {
            if (-not [string]::IsNullOrWhiteSpace($ArquivoTemp)) {
                try {
                    if (Test-SafePath -Path $ArquivoTemp) {
                        Remove-SafeItem -Path $ArquivoTemp
                    }
                }
                catch {
                    # Ignora limpeza de temporários.
                }
            }
        }
    }
}

function New-Label {
    param(
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$Width = 140
    )

    $Control = New-Object System.Windows.Forms.Label
    $Control.Text = $Text
    $Control.Location = New-Object System.Drawing.Point($X, $Y)
    $Control.Size = New-Object System.Drawing.Size($Width, 22)
    $Control.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    return $Control
}

function New-TextBox {
    param(
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$Width = 520
    )

    $Control = New-Object System.Windows.Forms.TextBox
    $Control.Text = $Text
    $Control.Location = New-Object System.Drawing.Point($X, $Y)
    $Control.Size = New-Object System.Drawing.Size($Width, 24)
    return $Control
}

function Apply-ThemeToControl {
    param(
        [System.Windows.Forms.Control]$Control,
        [bool]$Dark
    )

    if ($null -eq $Control) {
        return
    }

    $FormColor = if ($Dark) {
        [System.Drawing.Color]::FromArgb(28, 28, 28)
    }
    else {
        [System.Drawing.SystemColors]::Control
    }

    $PanelColor = if ($Dark) {
        [System.Drawing.Color]::FromArgb(36, 36, 36)
    }
    else {
        [System.Drawing.SystemColors]::Control
    }

    $TabPageColor = if ($Dark) {
        [System.Drawing.Color]::FromArgb(32, 32, 32)
    }
    else {
        [System.Drawing.SystemColors]::Control
    }

    $InputColor = if ($Dark) {
        [System.Drawing.Color]::FromArgb(22, 22, 22)
    }
    else {
        [System.Drawing.SystemColors]::Window
    }

    $TextColor = if ($Dark) {
        [System.Drawing.Color]::Gainsboro
    }
    else {
        [System.Drawing.SystemColors]::ControlText
    }

    $ButtonColor = if ($Dark) {
        [System.Drawing.Color]::FromArgb(55, 55, 55)
    }
    else {
        [System.Drawing.SystemColors]::Control
    }

    try {
        if ($Control -is [System.Windows.Forms.Form]) {
            $Control.BackColor = $FormColor
            $Control.ForeColor = $TextColor
        }
        elseif ($Control -is [System.Windows.Forms.TabControl]) {
            $Control.BackColor = $TabPageColor
            $Control.ForeColor = $TextColor
        }
        elseif ($Control -is [System.Windows.Forms.TabPage]) {
            $Control.UseVisualStyleBackColor = $false
            $Control.BackColor = $TabPageColor
            $Control.ForeColor = $TextColor
        }
        elseif ($Control -is [System.Windows.Forms.LinkLabel]) {
            $Control.BackColor = $PanelColor
            $Control.ForeColor = $TextColor

            if ($Dark) {
                $Control.LinkColor = [System.Drawing.Color]::FromArgb(120, 200, 255)
                $Control.ActiveLinkColor = [System.Drawing.Color]::White
                $Control.VisitedLinkColor = [System.Drawing.Color]::FromArgb(170, 210, 255)
                $Control.DisabledLinkColor = [System.Drawing.Color]::Gray
            }
            else {
                $Control.LinkColor = [System.Drawing.Color]::Blue
                $Control.ActiveLinkColor = [System.Drawing.Color]::Red
                $Control.VisitedLinkColor = [System.Drawing.Color]::Purple
                $Control.DisabledLinkColor = [System.Drawing.Color]::Gray
            }
        }
        elseif ($Control -is [System.Windows.Forms.Label]) {
            $Control.BackColor = [System.Drawing.Color]::Transparent
            $Control.ForeColor = $TextColor
        }
        elseif ($Control -is [System.Windows.Forms.TextBox] -or
                $Control -is [System.Windows.Forms.RichTextBox] -or
                $Control -is [System.Windows.Forms.ComboBox] -or
                $Control -is [System.Windows.Forms.NumericUpDown]) {

            $Control.BackColor = $InputColor
            $Control.ForeColor = $TextColor
        }
        elseif ($Control -is [System.Windows.Forms.Button]) {
            $Control.BackColor = $ButtonColor
            $Control.ForeColor = $TextColor
            $Control.FlatStyle = [System.Windows.Forms.FlatStyle]::Standard
            $Control.UseVisualStyleBackColor = $false
        }
        elseif ($Control -is [System.Windows.Forms.CheckBox]) {
            $Control.BackColor = $PanelColor
            $Control.ForeColor = $TextColor
            $Control.UseVisualStyleBackColor = $false
        }
        elseif ($Control -is [System.Windows.Forms.GroupBox] -or
                $Control -is [System.Windows.Forms.Panel] -or
                $Control -is [System.Windows.Forms.TableLayoutPanel]) {

            $Control.BackColor = $PanelColor
            $Control.ForeColor = $TextColor
        }
        elseif ($Control -is [System.Windows.Forms.DataGridView]) {
            $Control.BackgroundColor = if ($Dark) {
                [System.Drawing.Color]::FromArgb(30, 30, 30)
            }
            else {
                [System.Drawing.SystemColors]::AppWorkspace
            }

            $Control.DefaultCellStyle.BackColor = if ($Dark) {
                [System.Drawing.Color]::FromArgb(38, 38, 38)
            }
            else {
                [System.Drawing.SystemColors]::Window
            }

            $Control.DefaultCellStyle.ForeColor = $TextColor

            $Control.DefaultCellStyle.SelectionBackColor = if ($Dark) {
                [System.Drawing.Color]::FromArgb(75, 75, 75)
            }
            else {
                [System.Drawing.SystemColors]::Highlight
            }

            $Control.DefaultCellStyle.SelectionForeColor = if ($Dark) {
                [System.Drawing.Color]::White
            }
            else {
                [System.Drawing.SystemColors]::HighlightText
            }

            $Control.ColumnHeadersDefaultCellStyle.BackColor = if ($Dark) {
                [System.Drawing.Color]::FromArgb(50, 50, 50)
            }
            else {
                [System.Drawing.SystemColors]::Control
            }

            $Control.ColumnHeadersDefaultCellStyle.ForeColor = $TextColor
            $Control.EnableHeadersVisualStyles = -not $Dark
        }
        else {
            $Control.BackColor = $PanelColor
            $Control.ForeColor = $TextColor
        }
    }
    catch {
        # Alguns controles podem não aceitar determinada cor.
    }

    foreach ($Child in $Control.Controls) {
        Apply-ThemeToControl -Control $Child -Dark $Dark
    }
}

function Update-TabHeaderFillPanel {
    if ($null -eq $TabControl -or $null -eq $TabHeaderFillPanel) {
        return
    }

    if ($TabControl.TabPages.Count -eq 0) {
        return
    }

    try {
        $LastIndex = $TabControl.TabPages.Count - 1
        $LastRect = $TabControl.GetTabRect($LastIndex)

        $X = $TabControl.Left + $LastRect.Right + 1
        $Y = $TabControl.Top + $LastRect.Top

        if ($null -ne $ButtonAlternarTema) {
            $RightLimit = $ButtonAlternarTema.Left - 8
        }
        else {
            $RightLimit = $TabControl.Left + $TabControl.Width
        }

        $W = $RightLimit - $X
        $H = $LastRect.Height + 2

        if ($W -lt 0) {
            $W = 0
        }

        $TabHeaderFillPanel.Location = New-Object System.Drawing.Point($X, $Y)
        $TabHeaderFillPanel.Size = New-Object System.Drawing.Size($W, $H)
        $TabHeaderFillPanel.BringToFront()

        if ($null -ne $ButtonAlternarTema) {
            $ButtonAlternarTema.BringToFront()
        }
    }
    catch {
    }
}

function Set-ControlBoundsSafe {
    param(
        [System.Windows.Forms.Control]$Control,
        [int]$X,
        [int]$Y,
        [int]$W,
        [int]$H
    )

    if ($null -eq $Control) { return }
    if ($W -lt 1) { $W = 1 }
    if ($H -lt 1) { $H = 1 }

    $Control.Location = New-Object System.Drawing.Point($X, $Y)
    $Control.Size = New-Object System.Drawing.Size($W, $H)
}

function Update-MainLayout {
    if ($null -eq $Form -or $null -eq $TabControl) { return }

    $FormMargin = 10
    $TopTabs = 12
    $BottomMargin = 10

    Set-ControlBoundsSafe -Control $TabControl `
        -X $FormMargin `
        -Y $TopTabs `
        -W ($Form.ClientSize.Width - ($FormMargin * 2)) `
        -H ($Form.ClientSize.Height - $TopTabs - $BottomMargin)

    if ($null -ne $ButtonAlternarTema) {
        $ButtonAlternarTema.Location = New-Object System.Drawing.Point(
            ($Form.ClientSize.Width - $ButtonAlternarTema.Width - 12),
            12
        )
        $ButtonAlternarTema.Anchor = "Top,Right"
        $ButtonAlternarTema.BringToFront()
    }

    # ========================================================
    # Aba inicial: escaneamento/configuração
    # ========================================================
    if ($null -ne $TabPrincipal) {
        $PageW = [Math]::Max(700, $TabPrincipal.ClientSize.Width)
        $InnerW = [Math]::Max(680, $PageW - 30)

        if ($null -ne $GroupEntrada) { Set-ControlBoundsSafe -Control $GroupEntrada -X 15 -Y 15 -W $InnerW -H 140 }
        if ($null -ne $GroupOpcoes)  { Set-ControlBoundsSafe -Control $GroupOpcoes  -X 15 -Y 165 -W $InnerW -H 140 }
        if ($null -ne $GroupAcoes)   { Set-ControlBoundsSafe -Control $GroupAcoes   -X 15 -Y 315 -W $InnerW -H 85 }

        if ($null -ne $GroupEntrada) {
            $LabelX = 15
            $TextX = 150
            $ButtonW = 130
            $ButtonGap = 16
            $ButtonX = $GroupEntrada.ClientSize.Width - $ButtonW - 15
            $TextW = $ButtonX - $TextX - $ButtonGap
            if ($TextW -lt 220) { $TextW = 220 }

            Set-ControlBoundsSafe -Control $LabelPastaMP3      -X $LabelX -Y 30  -W 130 -H 24
            Set-ControlBoundsSafe -Control $TextPastaMP3       -X $TextX  -Y 30  -W $TextW -H 24
            Set-ControlBoundsSafe -Control $ButtonPastaMP3     -X $ButtonX -Y 27 -W $ButtonW -H 30

            Set-ControlBoundsSafe -Control $LabelPastaLegendas -X $LabelX -Y 65  -W 130 -H 24
            Set-ControlBoundsSafe -Control $TextPastaLegendas  -X $TextX  -Y 65  -W $TextW -H 24
            Set-ControlBoundsSafe -Control $ButtonPastaLegendas -X $ButtonX -Y 62 -W $ButtonW -H 30

            Set-ControlBoundsSafe -Control $LabelModoLeitura   -X $LabelX -Y 100 -W 130 -H 24
            $ComboW = [Math]::Min(500, $GroupEntrada.ClientSize.Width - $TextX - 30)
            if ($ComboW -lt 250) { $ComboW = 250 }
            Set-ControlBoundsSafe -Control $ComboModoLeitura   -X $TextX -Y 100 -W $ComboW -H 24
        }

        if ($null -ne $GroupOpcoes) {
            $Col1X = 15
            $Col2X = [Math]::Max(315, [int]($GroupOpcoes.ClientSize.Width * 0.28))
            $Col3X = [Math]::Max(690, [int]($GroupOpcoes.ClientSize.Width * 0.60))

            Set-ControlBoundsSafe -Control $CheckGerarMusicas -X $Col1X -Y 30 -W 260 -H 24
            Set-ControlBoundsSafe -Control $CheckGerarAlbum   -X $Col1X -Y 65 -W 260 -H 24

            Set-ControlBoundsSafe -Control $LabelExtra -X $Col2X -Y 30 -W 220 -H 24
            Set-ControlBoundsSafe -Control $NumericExtra -X ($Col2X + 225) -Y 30 -W 90 -H 24
            Set-ControlBoundsSafe -Control $LabelSilencioEntreFaixas -X $Col2X -Y 65 -W 230 -H 24
            Set-ControlBoundsSafe -Control $NumericSilencioEntreFaixas -X ($Col2X + 225) -Y 65 -W 90 -H 24

            Set-ControlBoundsSafe -Control $CheckDetalhado -X $Col3X -Y 30 -W 240 -H 24
            Set-ControlBoundsSafe -Control $CheckValidarDuracao -X $Col3X -Y 65 -W 340 -H 24
        }

        if ($null -ne $GroupAcoes) {
            Set-ControlBoundsSafe -Control $LabelGrupoGeracao -X 15 -Y 18 -W 180 -H 18
            Set-ControlBoundsSafe -Control $ButtonEscanear -X 15 -Y 38 -W 220 -H 34
            Set-ControlBoundsSafe -Control $ButtonGerarTodos -X 255 -Y 38 -W 230 -H 34
            $ProgW = [Math]::Max(160, $GroupAcoes.ClientSize.Width - 760)
            Set-ControlBoundsSafe -Control $ProgressEscanear -X 505 -Y 44 -W $ProgW -H 20
            Set-ControlBoundsSafe -Control $LabelProgressoEscanear -X (515 + $ProgW) -Y 42 -W 230 -H 24
        }
    }

    # ========================================================
    # Abas Músicas e Álbuns
    # ========================================================
    foreach ($Pack in @(
        [PSCustomObject]@{ Page=$TabMusicas; Grid=$GridMusicas; B1=$ButtonMarcarTodosMusicas; B2=$ButtonDesmarcarTodosMusicas; B3=$ButtonMarcarPendentesMusicas; B4=$ButtonReplicarImagemAlbum; B5=$ButtonGerarSelecionadosMusicas },
        [PSCustomObject]@{ Page=$TabAlbuns;  Grid=$GridAlbuns;  B1=$ButtonMarcarTodosAlbuns;  B2=$ButtonDesmarcarTodosAlbuns;  B3=$ButtonMarcarPendentesAlbuns;  B4=$null;                    B5=$ButtonGerarSelecionadosAlbuns }
    )) {
        if ($null -eq $Pack.Page) { continue }

        $PageW = [Math]::Max(700, $Pack.Page.ClientSize.Width)
        $PageH = [Math]::Max(420, $Pack.Page.ClientSize.Height)
        $RightButtonX = $PageW - 255
        if ($RightButtonX -lt 650) { $RightButtonX = 650 }

        Set-ControlBoundsSafe -Control $Pack.B1 -X 15 -Y 20 -W 125 -H 34
        Set-ControlBoundsSafe -Control $Pack.B2 -X 155 -Y 20 -W 145 -H 34
        Set-ControlBoundsSafe -Control $Pack.B3 -X 315 -Y 20 -W 155 -H 34
        if ($null -ne $Pack.B4) { Set-ControlBoundsSafe -Control $Pack.B4 -X 485 -Y 20 -W 210 -H 34 }
        Set-ControlBoundsSafe -Control $Pack.B5 -X $RightButtonX -Y 20 -W 240 -H 34

        Set-ControlBoundsSafe -Control $Pack.Grid -X 15 -Y 70 -W ($PageW - 30) -H ($PageH - 95)
    }

    # ========================================================
    # Aba Legendas
    # ========================================================
    if ($null -ne $TabLegendas) {
        $PageW = [Math]::Max(900, $TabLegendas.ClientSize.Width)
        $PageH = [Math]::Max(650, $TabLegendas.ClientSize.Height)
        $InnerW = $PageW - 30

        if ($null -ne $GroupLegOrigem) {
            Set-ControlBoundsSafe -Control $GroupLegOrigem -X 15 -Y 15 -W $InnerW -H 120

            $LegButtonW = 140
            $LegButtonX = $GroupLegOrigem.ClientSize.Width - $LegButtonW - 30
            $LegTextW = $LegButtonX - 160 - 20
            if ($LegTextW -lt 360) { $LegTextW = 360 }

            Set-ControlBoundsSafe -Control $TextLegPastaLegendas -X 160 -Y 50 -W $LegTextW -H 24
            Set-ControlBoundsSafe -Control $ButtonLegPastaLegendas -X $LegButtonX -Y 47 -W $LegButtonW -H 30
            if ($null -ne $ComboLegMusica) {
                $BrowseW = 95
                $ComboW = [Math]::Max(260, [Math]::Min(520, $GroupLegOrigem.ClientSize.Width - 720))
                Set-ControlBoundsSafe -Control $ComboLegMusica -X 245 -Y 87 -W $ComboW -H 24
                $BrowseX = 245 + $ComboW + 10
                if ($null -ne $ButtonLegExplorarMusica) { Set-ControlBoundsSafe -Control $ButtonLegExplorarMusica -X $BrowseX -Y 84 -W $BrowseW -H 28 }
                $DurX = $BrowseX + $BrowseW + 15
                if ($null -ne $LabelLegDuracao) { Set-ControlBoundsSafe -Control $LabelLegDuracao -X $DurX -Y 88 -W 160 -H 22 }
                if ($null -ne $LabelLegStatus) { Set-ControlBoundsSafe -Control $LabelLegStatus -X ($DurX + 175) -Y 88 -W 230 -H 22 }
            }
        }

        $LeftW = [Math]::Max(360, [int]($InnerW * 0.36))
        $RightX = 15 + $LeftW + 15
        $RightW = $InnerW - $LeftW - 15
        if ($RightW -lt 560) { $RightW = 560 }

        $MidY = 150
        $BottomGroupH = 130
        $MidH = $PageH - $MidY - $BottomGroupH - 45
        if ($MidH -lt 405) { $MidH = 405 }

        if ($null -ne $GroupLegLetra) {
            Set-ControlBoundsSafe -Control $GroupLegLetra -X 15 -Y $MidY -W $LeftW -H $MidH
            Set-ControlBoundsSafe -Control $ButtonLegImportarLetra -X 15 -Y 25 -W 155 -H 30
            Set-ControlBoundsSafe -Control $ButtonLegAplicarLetra -X 185 -Y 25 -W 155 -H 30
            Set-ControlBoundsSafe -Control $TextLegLetra -X 15 -Y 68 -W ($GroupLegLetra.ClientSize.Width - 30) -H ($GroupLegLetra.ClientSize.Height - 145)
            Set-ControlBoundsSafe -Control $LabelLegLetraInfo -X 15 -Y ($GroupLegLetra.ClientSize.Height - 68) -W ($GroupLegLetra.ClientSize.Width - 30) -H 58
        }

        if ($null -ne $GroupLegEditor) {
            Set-ControlBoundsSafe -Control $GroupLegEditor -X $RightX -Y $MidY -W $RightW -H $MidH
            $EditorW = $GroupLegEditor.ClientSize.Width
            Set-ControlBoundsSafe -Control $TextLegArquivoMP3 -X 15 -Y 25 -W ($EditorW - 30) -H 24
            Set-ControlBoundsSafe -Control $TextLegArquivoSrt -X 15 -Y 55 -W ($EditorW - 30) -H 24
            Set-ControlBoundsSafe -Control $LabelLegMarcacaoStatus -X 15 -Y 125 -W ($EditorW - 30) -H 22
            Set-ControlBoundsSafe -Control $GridLegendas -X 15 -Y 150 -W ($EditorW - 30) -H ($GroupLegEditor.ClientSize.Height - 285)

            $BottomY1 = $GroupLegEditor.ClientSize.Height - 112
            $BottomY2 = $GroupLegEditor.ClientSize.Height - 62
            Set-ControlBoundsSafe -Control $ButtonLegAdicionarLinha -X 15 -Y $BottomY1 -W 120 -H 42
            Set-ControlBoundsSafe -Control $ButtonLegRemoverLinha -X 145 -Y $BottomY1 -W 120 -H 42
            Set-ControlBoundsSafe -Control $ButtonLegLimpar -X 275 -Y $BottomY1 -W 80 -H 42
            Set-ControlBoundsSafe -Control $ButtonLegAbrirSrt -X 365 -Y $BottomY1 -W 120 -H 42
            Set-ControlBoundsSafe -Control $ButtonLegRedistribuir -X 495 -Y $BottomY1 -W 120 -H 42
            Set-ControlBoundsSafe -Control $ButtonLegVideoLegendado -X 15 -Y $BottomY2 -W 190 -H 42
            Set-ControlBoundsSafe -Control $ButtonLegSalvarSrt -X ([Math]::Max(220, $EditorW - 165)) -Y $BottomY2 -W 150 -H 42
        }

        if ($null -ne $GroupLegAlbum) {
            Set-ControlBoundsSafe -Control $GroupLegAlbum -X 15 -Y ($PageH - $BottomGroupH - 20) -W $InnerW -H $BottomGroupH

            $AlbumGroupW = [Math]::Max(500, $GroupLegAlbum.ClientSize.Width)
            $AlbumComboW = $AlbumGroupW - 115
            if ($AlbumComboW -lt 260) { $AlbumComboW = 260 }

            Set-ControlBoundsSafe -Control $LabelLegAlbum -X 15 -Y 30 -W 65 -H 22
            Set-ControlBoundsSafe -Control $ComboLegAlbum -X 85 -Y 30 -W $AlbumComboW -H 24

            Set-ControlBoundsSafe -Control $LabelLegSilencio -X 15 -Y 65 -W 180 -H 22
            Set-ControlBoundsSafe -Control $NumericLegSilencioAlbum -X 200 -Y 63 -W 90 -H 24
            Set-ControlBoundsSafe -Control $ButtonLegGerarAlbum -X 315 -Y 58 -W 190 -H 34

            Set-ControlBoundsSafe -Control $LabelLegAlbumInfo -X 15 -Y 96 -W ($AlbumGroupW - 30) -H 22
        }
    }



    # ========================================================
    # Aba Separar Áudio
    # ========================================================
    if ($null -ne $TabSepararAudio) {
        $PageW = [Math]::Max(900, $TabSepararAudio.ClientSize.Width)
        $PageH = [Math]::Max(520, $TabSepararAudio.ClientSize.Height)
        $InnerW = $PageW - 30

        if ($null -ne $GroupSepOrigem) {
            Set-ControlBoundsSafe -Control $GroupSepOrigem -X 15 -Y 15 -W $InnerW -H 170
            Set-ControlBoundsSafe -Control $ButtonSepAtualizar -X 15 -Y 62 -W 150 -H 32
            Set-ControlBoundsSafe -Control $ComboSepMusica -X 185 -Y 66 -W ([Math]::Max(420, $GroupSepOrigem.ClientSize.Width - 520)) -H 24
            Set-ControlBoundsSafe -Control $LabelSepDuracao -X ($GroupSepOrigem.ClientSize.Width - 315) -Y 68 -W 140 -H 22
            Set-ControlBoundsSafe -Control $LabelSepStatus -X ($GroupSepOrigem.ClientSize.Width - 170) -Y 68 -W 150 -H 22
            Set-ControlBoundsSafe -Control $TextSepArquivoMP3 -X 15 -Y 102 -W ($GroupSepOrigem.ClientSize.Width - 30) -H 24
            Set-ControlBoundsSafe -Control $TextSepDestino -X 15 -Y 132 -W ($GroupSepOrigem.ClientSize.Width - 160) -H 24
            Set-ControlBoundsSafe -Control $ButtonSepAbrirPasta -X ($GroupSepOrigem.ClientSize.Width - 135) -Y 129 -W 120 -H 30
        }

        if ($null -ne $GroupSepOpcoes) {
            Set-ControlBoundsSafe -Control $GroupSepOpcoes -X 15 -Y 200 -W $InnerW -H 165
            Set-ControlBoundsSafe -Control $CheckSepGerarVocal -X 15 -Y 28 -W 220 -H 24
            Set-ControlBoundsSafe -Control $CheckSepGerarInstrumental -X 260 -Y 28 -W 220 -H 24
            Set-ControlBoundsSafe -Control $LabelSepInfo -X 15 -Y 62 -W ($GroupSepOpcoes.ClientSize.Width - 30) -H 45
            Set-ControlBoundsSafe -Control $ButtonSepSelecionada -X 15 -Y 115 -W 210 -H 36
            Set-ControlBoundsSafe -Control $ButtonSepAlbum -X 245 -Y 115 -W 210 -H 36
        }
    }


    # ========================================================
    # Aba Publicação
    # ========================================================
    if ($null -ne $TabPublicacao) {
        $PageW = [Math]::Max(900, $TabPublicacao.ClientSize.Width)
        $PageH = [Math]::Max(650, $TabPublicacao.ClientSize.Height)
        $InnerW = $PageW - 30

        if ($null -ne $GroupPubOrigem) {
            Set-ControlBoundsSafe -Control $GroupPubOrigem -X 15 -Y 15 -W $InnerW -H 80
            $OrigemW = $GroupPubOrigem.ClientSize.Width
            Set-ControlBoundsSafe -Control $LabelPubPasta -X 15 -Y 32 -W 120 -H 22
            Set-ControlBoundsSafe -Control $TextPubPasta -X 140 -Y 32 -W ([Math]::Max(260, $OrigemW - 700)) -H 24
            Set-ControlBoundsSafe -Control $ButtonPubPasta -X ([Math]::Max(410, $OrigemW - 560)) -Y 29 -W 105 -H 30
            Set-ControlBoundsSafe -Control $ButtonPubUsarSaida -X ([Math]::Max(525, $OrigemW - 445)) -Y 29 -W 135 -H 30
            Set-ControlBoundsSafe -Control $ButtonPubConfig -X ([Math]::Max(670, $OrigemW - 300)) -Y 29 -W 165 -H 30
            Set-ControlBoundsSafe -Control $ButtonPubConectar -X ([Math]::Max(845, $OrigemW - 115)) -Y 29 -W 95 -H 30
        }

        if ($null -ne $GroupPubAcoes) {
            Set-ControlBoundsSafe -Control $GroupPubAcoes -X 15 -Y 105 -W $InnerW -H 90
            $AcoesW = $GroupPubAcoes.ClientSize.Width
            $AcaoY1 = 28
            $AcaoY2 = 28
            $AcaoX = 15
            $Gap = 10
            foreach ($Btn in @($ButtonPubEscanear, $ButtonPubMarcarTodos, $ButtonPubDesmarcarTodos, $ButtonPubMarcarPendentes, $ButtonPubValidar, $ButtonPubExportar, $ButtonPubAplicarUltimos, $ButtonPubEnviarSelecionados, $ButtonPubEnviarPendentes)) {
                if ($null -eq $Btn) { continue }
                if (($AcaoX + $Btn.Width) -gt ($AcoesW - 15)) {
                    $AcaoX = 15
                    $AcaoY1 = 58
                }
                Set-ControlBoundsSafe -Control $Btn -X $AcaoX -Y $AcaoY1 -W $Btn.Width -H 30
                $AcaoX += $Btn.Width + $Gap
            }
        }

        if ($null -ne $GroupPubLegendas) {
            Set-ControlBoundsSafe -Control $GroupPubLegendas -X 15 -Y 205 -W $InnerW -H 80
            $LegW = $GroupPubLegendas.ClientSize.Width
            Set-ControlBoundsSafe -Control $LabelPubModoLegenda -X 15 -Y 32 -W 55 -H 22
            Set-ControlBoundsSafe -Control $ComboPubModoLegenda -X 70 -Y 29 -W 210 -H 24
            Set-ControlBoundsSafe -Control $CheckPubAnexarTodosSrt -X 300 -Y 31 -W 330 -H 24
            Set-ControlBoundsSafe -Control $ButtonPubAplicarLegenda -X ([Math]::Max(650, $LegW - 375)) -Y 26 -W 165 -H 30
            Set-ControlBoundsSafe -Control $LabelPubLegInfo -X ([Math]::Max(825, $LegW - 200)) -Y 28 -W 185 -H 42
        }

        if ($null -ne $GridPublicacao) {
            $GridY = if ($null -ne $GroupPubLegendas) { $GroupPubLegendas.Bottom + 10 } else { 295 }
            $GridH = [Math]::Max(150, [int]($PageH * 0.24))
            Set-ControlBoundsSafe -Control $GridPublicacao -X 15 -Y $GridY -W $InnerW -H $GridH
            AutoSize-PublishGridColumns
        }
        if ($null -ne $GroupPubMetadados) {
            Set-ControlBoundsSafe -Control $GroupPubMetadados -X 15 -Y ($GridPublicacao.Bottom + 15) -W $InnerW -H 205
            $MetaW = $GroupPubMetadados.ClientSize.Width
            Set-ControlBoundsSafe -Control $LabelPubTitulo -X 15 -Y 28 -W 80 -H 22
            Set-ControlBoundsSafe -Control $TextPubTitulo -X 100 -Y 28 -W ([Math]::Max(360, [int]($MetaW * 0.42))) -H 24
            Set-ControlBoundsSafe -Control $LabelPubVisibilidade -X ([Math]::Max(570, [int]($MetaW * 0.52))) -Y 28 -W 95 -H 22
            Set-ControlBoundsSafe -Control $ComboPubVisibilidade -X ([Math]::Max(670, [int]($MetaW * 0.61))) -Y 28 -W 130 -H 24
            Set-ControlBoundsSafe -Control $LabelPubCategoria -X ([Math]::Max(815, [int]($MetaW * 0.74))) -Y 28 -W 80 -H 22
            Set-ControlBoundsSafe -Control $TextPubCategoria -X ([Math]::Max(900, [int]($MetaW * 0.82))) -Y 28 -W 60 -H 24
            Set-ControlBoundsSafe -Control $LabelPubDescricao -X 15 -Y 63 -W 80 -H 22
            Set-ControlBoundsSafe -Control $TextPubDescricao -X 100 -Y 63 -W ([Math]::Max(360, [int]($MetaW * 0.42))) -H 95
            Set-ControlBoundsSafe -Control $LabelPubTags -X ([Math]::Max(570, [int]($MetaW * 0.52))) -Y 63 -W 80 -H 22
            Set-ControlBoundsSafe -Control $TextPubTags -X ([Math]::Max(670, [int]($MetaW * 0.61))) -Y 63 -W ([Math]::Max(300, $MetaW - ([Math]::Max(670, [int]($MetaW * 0.61))) - 25)) -H 24
            Set-ControlBoundsSafe -Control $LabelPubPlaylist -X ([Math]::Max(570, [int]($MetaW * 0.52))) -Y 98 -W 90 -H 22
            Set-ControlBoundsSafe -Control $TextPubPlaylist -X ([Math]::Max(670, [int]($MetaW * 0.61))) -Y 98 -W ([Math]::Max(300, $MetaW - ([Math]::Max(670, [int]($MetaW * 0.61))) - 25)) -H 24
            Set-ControlBoundsSafe -Control $LabelPubThumbnail -X ([Math]::Max(570, [int]($MetaW * 0.52))) -Y 133 -W 90 -H 22
            Set-ControlBoundsSafe -Control $TextPubThumbnail -X ([Math]::Max(670, [int]($MetaW * 0.61))) -Y 133 -W ([Math]::Max(250, $MetaW - ([Math]::Max(670, [int]($MetaW * 0.61))) - 140)) -H 24
            Set-ControlBoundsSafe -Control $ButtonPubThumbnail -X ($MetaW - 120) -Y 130 -W 105 -H 30
            Set-ControlBoundsSafe -Control $ButtonPubAplicarLinha -X 100 -Y 165 -W 130 -H 30
            Set-ControlBoundsSafe -Control $ButtonPubAplicarSelecionados -X 240 -Y 165 -W 180 -H 30
        }
        if ($null -ne $TextPubLog) { Set-ControlBoundsSafe -Control $TextPubLog -X 15 -Y ($GroupPubMetadados.Bottom + 10) -W $InnerW -H ([Math]::Max(60, $PageH - $GroupPubMetadados.Bottom - 25)) }
    }

    # ========================================================
    # Aba Ajuda
    # ========================================================
    if ($null -ne $TabAjuda) {
        $PageW = [Math]::Max(900, $TabAjuda.ClientSize.Width)
        $PageH = [Math]::Max(650, $TabAjuda.ClientSize.Height)
        if ($null -ne $AjudaIndicePanel) { Set-ControlBoundsSafe -Control $AjudaIndicePanel -X 20 -Y 45 -W ($PageW - 40) -H 120 }
        if ($null -ne $AjudaBox) { Set-ControlBoundsSafe -Control $AjudaBox -X 20 -Y 180 -W ($PageW - 40) -H ($PageH - 205) }
    }

    Update-TabHeaderFillPanel
}

function Apply-AppTheme {
    param([bool]$Dark)

    $script:TemaEscuro = $Dark

    if ($null -ne $Form) {
        Apply-ThemeToControl -Control $Form -Dark $Dark
    }

    if ($null -ne $TabControl) {
        foreach ($Page in $TabControl.TabPages) {
            $Page.UseVisualStyleBackColor = $false

            if ($Dark) {
                $Page.BackColor = [System.Drawing.Color]::FromArgb(32, 32, 32)
                $Page.ForeColor = [System.Drawing.Color]::Gainsboro
            }
            else {
                $Page.BackColor = [System.Drawing.SystemColors]::Control
                $Page.ForeColor = [System.Drawing.SystemColors]::ControlText
            }
        }

        $TabControl.Invalidate()
        $TabControl.Refresh()
    }

    if ($null -ne $TabHeaderFillPanel) {
        Update-TabHeaderFillPanel

        if ($Dark) {
            $TabHeaderFillPanel.BackColor = [System.Drawing.Color]::FromArgb(28, 28, 28)
            $TabHeaderFillPanel.Visible = $true
        }
        else {
            $TabHeaderFillPanel.BackColor = [System.Drawing.SystemColors]::Control
            $TabHeaderFillPanel.Visible = $false
        }

        $TabHeaderFillPanel.BringToFront()
    }

    if ($null -ne $ButtonAlternarTema) {
        if ($Dark) {
            $ButtonAlternarTema.Text = "Tema claro"
        }
        else {
            $ButtonAlternarTema.Text = "Tema escuro"
        }

        $ButtonAlternarTema.BringToFront()
    }

    Refresh-PublishGrid

    if ($null -ne $script:ItensEscaneados) {
        Populate-MediaTabs
    }
}

function Set-FormIcon {
    param([System.Windows.Forms.Form]$TargetForm)

    if ($null -eq $TargetForm) {
        return
    }

    try {
        if (Test-SafePath -Path $script:AppIconPath) {
            $TargetForm.Icon = New-Object System.Drawing.Icon($script:AppIconPath)
        }
    }
    catch {
        # Mantém o ícone padrão se houver qualquer problema.
    }
}


# ============================================================
# CONFIGURAÇÃO, CAPAS E RELATÓRIO
# ============================================================

function Get-ConfigPath {
    return (Join-SafePath $script:AppRoot "config.json")
}

function Load-AppConfig {
    $ConfigPath = Get-ConfigPath

    if (-not (Test-SafePath -Path $ConfigPath)) {
        return $null
    }

    try {
        $Raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
        return $Raw | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Save-AppConfig {
    param(
        [string]$PastaMP3,
        [string]$PastaVideo,
        [string]$PastaLegendas,
        [string]$NomeCapa,
        [bool]$GerarMusicas,
        [bool]$GerarAlbum,
        [double]$SegundosExtras,
        [double]$SilencioEntreFaixas,
        [bool]$Detalhado,
        [bool]$ValidarDuracao,
        [string]$ModoLeitura,
        [bool]$SaidaAutomatica
    )

    $Config = [PSCustomObject]@{
        PastaMP3            = $PastaMP3
        PastaVideo          = $PastaVideo
        PastaLegendas       = $PastaLegendas
        NomeCapa            = $NomeCapa
        GerarMusicas        = $GerarMusicas
        GerarAlbum          = $GerarAlbum
        SegundosExtras      = $SegundosExtras
        SilencioEntreFaixas = $SilencioEntreFaixas
        Detalhado           = $Detalhado
        ValidarDuracao      = $ValidarDuracao
        ModoLeitura         = $ModoLeitura
        SaidaAutomatica     = $SaidaAutomatica
    }

    try {
        $ConfigPath = Get-ConfigPath
        $Config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
    }
    catch {
        # Não impede o uso do programa.
    }
}

function Get-AutoOutputPath {
    param([string]$PastaMP3)

    if ([string]::IsNullOrWhiteSpace($PastaMP3)) {
        return ""
    }

    try {
        $Normalized = ([string]$PastaMP3).Trim().TrimEnd('\', '/')

        if ([string]::IsNullOrWhiteSpace($Normalized)) {
            return ""
        }

        $Parent = Split-SafeParent -Path $Normalized

        if ([string]::IsNullOrWhiteSpace($Parent)) {
            return (Join-SafePath $Normalized "VÍDEOS")
        }

        return (Join-SafePath $Parent "VÍDEOS")
    }
    catch {
        return ""
    }
}


function Get-AutoSubtitlePath {
    param([string]$PastaMP3)

    if ([string]::IsNullOrWhiteSpace($PastaMP3)) {
        return ""
    }

    try {
        $Normalized = ([string]$PastaMP3).Trim().TrimEnd('\', '/')

        if ([string]::IsNullOrWhiteSpace($Normalized)) {
            return ""
        }

        $Parent = Split-SafeParent -Path $Normalized

        if ([string]::IsNullOrWhiteSpace($Parent)) {
            return (Join-SafePath $Normalized "LEGENDAS")
        }

        return (Join-SafePath $Parent "LEGENDAS")
    }
    catch {
        return ""
    }
}


function Get-PropertyValueFlexible {
    param(
        [object]$Obj,
        [string[]]$Names
    )

    if ($null -eq $Obj) { return $null }

    foreach ($Name in $Names) {
        try {
            $Prop = $Obj.PSObject.Properties | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1
            if ($Prop -and $null -ne $Prop.Value) { return $Prop.Value }
        }
        catch { }
    }

    return $null
}

function Resolve-DemucsExecutable {
    $LocalCandidates = @(
        (Join-SafePath $script:AppRoot "demucs.bat"),
        (Join-SafePath $script:AppRoot "demucs.cmd"),
        (Join-SafePath $script:AppRoot "demucs.exe"),
        (Join-SafePath $script:AppRoot "whisper_env\Scripts\demucs.exe"),
        (Join-SafePath $script:AppRoot "whisper_env\Scripts\demucs.cmd"),
        (Join-SafePath $script:AppRoot "whisper_env\Scripts\demucs.bat")
    )

    foreach ($Candidate in $LocalCandidates) {
        if (Test-SafePath -Path $Candidate) {
            return $Candidate
        }
    }

    foreach ($Candidate in @("demucs.exe", "demucs")) {
        $Resolved = Resolve-Executable $Candidate
        if ($Resolved) { return $Resolved }
    }

    return $null
}

function Get-SeparatedAudioOutputDirectory {
    param(
        [object]$Item,
        [string]$BaseDirectory
    )

    if ([string]::IsNullOrWhiteSpace($BaseDirectory)) {
        $BaseDirectory = Get-AutoSubtitlePath -PastaMP3 $TextPastaMP3.Text
    }

    $AlbumName = "Sem Álbum"
    if ($null -ne $Item -and -not [string]::IsNullOrWhiteSpace([string]$Item.Album)) {
        $AlbumName = [string]$Item.Album
    }

    return (Join-SafePath (Join-SafePath $BaseDirectory $AlbumName) "Audio_Separado")
}

function Invoke-DemucsSeparation {
    param(
        [string]$ArquivoMP3,
        [string]$OutputDirectory,
        [string]$DemucsPath,
        [bool]$Detalhado,
        [System.Windows.Forms.Label]$StatusLabel,
        [System.Windows.Forms.TextBox]$LogBox,
        [bool]$Overwrite = $false
    )

    if (-not (Test-SafePath -Path $ArquivoMP3)) {
        Add-Log -LogBox $LogBox -Mensagem "ERRO: Arquivo de áudio não encontrado para separar: $ArquivoMP3"
        return [PSCustomObject]@{ Status = "Erro"; VocalsPath = ""; InstrumentalPath = ""; Tempo = "ÁUDIO NÃO ENCONTRADO" }
    }

    if ([string]::IsNullOrWhiteSpace($DemucsPath)) {
        Add-Log -LogBox $LogBox -Mensagem "ERRO: Demucs não encontrado. Instale o Demucs no ambiente whisper_env ou coloque demucs.exe/demucs.bat na pasta do aplicativo."
        return [PSCustomObject]@{ Status = "Erro"; VocalsPath = ""; InstrumentalPath = ""; Tempo = "DEMUCS NÃO ENCONTRADO" }
    }

    if (-not (New-SafeDirectory -Path $OutputDirectory)) {
        Add-Log -LogBox $LogBox -Mensagem "ERRO: Não foi possível criar/acessar a pasta de áudio separado: $OutputDirectory"
        return [PSCustomObject]@{ Status = "Erro"; VocalsPath = ""; InstrumentalPath = ""; Tempo = "ERRO DE PASTA" }
    }

    $NomeBase = [System.IO.Path]::GetFileNameWithoutExtension($ArquivoMP3)
    $FinalVocals = Join-SafePath $OutputDirectory ($NomeBase + "_vocals.wav")
    $FinalInstrumental = Join-SafePath $OutputDirectory ($NomeBase + "_instrumental.wav")

    if ((Test-SafePath -Path $FinalVocals) -and (Test-SafePath -Path $FinalInstrumental) -and -not $Overwrite) {
        Add-Log -LogBox $LogBox -Mensagem "Áudio separado já existe, reutilizando: $OutputDirectory"
        return [PSCustomObject]@{ Status = "Existente"; VocalsPath = $FinalVocals; InstrumentalPath = $FinalInstrumental; Tempo = "-" }
    }

    if ($Overwrite) {
        Remove-SafeItem -Path $FinalVocals
        Remove-SafeItem -Path $FinalInstrumental
    }

    Add-Log -LogBox $LogBox -Mensagem ""
    Add-Log -LogBox $LogBox -Mensagem "Separando vocal e instrumental: $NomeBase"
    Add-Log -LogBox $LogBox -Mensagem "Origem: $ArquivoMP3"
    Add-Log -LogBox $LogBox -Mensagem "Destino: $OutputDirectory"
    Add-Log -LogBox $LogBox -Mensagem "Demucs: $DemucsPath"
    Add-Log -LogBox $LogBox -Mensagem "Log desta execução: $script:LogPath"

    try {
        $FfmpegLocal = Join-SafePath $script:AppRoot "ffmpeg.exe"
        if (Test-SafePath -Path $FfmpegLocal) {
            $FfmpegDir = Split-Path -Path $FfmpegLocal -Parent
            if ($env:PATH -notlike "*$FfmpegDir*") {
                $env:PATH = $FfmpegDir + ";" + $env:PATH
                Add-Log -LogBox $LogBox -Mensagem "FFmpeg local adicionado ao PATH para o Demucs: $FfmpegDir"
            }
        }
    }
    catch { }

    $Inicio = Get-Date
    $TempOut = [System.IO.Path]::GetTempFileName()
    $TempErr = [System.IO.Path]::GetTempFileName()
    $TempRoot = Join-SafePath ([System.IO.Path]::GetTempPath()) ("frezza_demucs_" + [System.Guid]::NewGuid().ToString("N"))

    try {
        New-SafeDirectory -Path $TempRoot | Out-Null

        $Argumentos = @(
            "--two-stems", "vocals",
            "-o", $TempRoot,
            $ArquivoMP3
        )

        $ArgumentLine = ConvertTo-ArgumentLine -Argumentos $Argumentos
        Add-Log -LogBox $LogBox -Mensagem "Comando Demucs: `"$DemucsPath`" $ArgumentLine"
        $Processo = Start-Process `
            -FilePath $DemucsPath `
            -ArgumentList $ArgumentLine `
            -RedirectStandardOutput $TempOut `
            -RedirectStandardError $TempErr `
            -WindowStyle Hidden `
            -PassThru

        $script:ProcessoAtual = $Processo
        $Pontos = 0

        while (-not $Processo.HasExited) {
            if ($script:CancelarGeracao) {
                try {
                    if (-not $Processo.HasExited) { $Processo.Kill() }
                    $Processo.WaitForExit()
                }
                catch { }

                if ($null -ne $StatusLabel) {
                    $StatusLabel.Text = "Separação interrompida."
                    $StatusLabel.Refresh()
                }

                return [PSCustomObject]@{ Status = "Interrompido"; VocalsPath = $FinalVocals; InstrumentalPath = $FinalInstrumental; Tempo = "INTERROMPIDO" }
            }

            if ($null -ne $StatusLabel) {
                $StatusLabel.Text = "Separando vocal/instrumental" + ("." * $Pontos)
                $StatusLabel.Refresh()
            }

            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Seconds 1
            $Pontos++
            if ($Pontos -gt 3) { $Pontos = 0 }
        }

        $Processo.WaitForExit()
        $ExitCode = $Processo.ExitCode

        $OutText = Get-Content -LiteralPath $TempOut -Raw -ErrorAction SilentlyContinue
        $ErrText = Get-Content -LiteralPath $TempErr -Raw -ErrorAction SilentlyContinue

        if ($Detalhado) {
            if (-not [string]::IsNullOrWhiteSpace($OutText)) { Add-Log -LogBox $LogBox -Mensagem $OutText.TrimEnd() }
            if (-not [string]::IsNullOrWhiteSpace($ErrText)) { Add-Log -LogBox $LogBox -Mensagem $ErrText.TrimEnd() }
        }
        elseif ($ExitCode -ne 0 -and -not [string]::IsNullOrWhiteSpace($ErrText)) {
            Add-Log -LogBox $LogBox -Mensagem $ErrText.TrimEnd()
        }

        $GeneratedVocals = Get-ChildItem -LiteralPath $TempRoot -Recurse -File -Filter "vocals.wav" -ErrorAction SilentlyContinue | Select-Object -First 1
        $GeneratedNoVocals = Get-ChildItem -LiteralPath $TempRoot -Recurse -File -Filter "no_vocals.wav" -ErrorAction SilentlyContinue | Select-Object -First 1

        $Fim = Get-Date
        $Tempo = $Fim - $Inicio
        $TempoFormatado = "{0:hh\:mm\:ss}" -f $Tempo

        if ($ExitCode -eq 0 -and $null -ne $GeneratedVocals -and $null -ne $GeneratedNoVocals) {
            Copy-Item -LiteralPath $GeneratedVocals.FullName -Destination $FinalVocals -Force
            Copy-Item -LiteralPath $GeneratedNoVocals.FullName -Destination $FinalInstrumental -Force

            Add-Log -LogBox $LogBox -Mensagem "Separação concluída."
            Add-Log -LogBox $LogBox -Mensagem "Vocal: $FinalVocals"
            Add-Log -LogBox $LogBox -Mensagem "Instrumental: $FinalInstrumental"
            Add-Log -LogBox $LogBox -Mensagem "Tempo gasto na separação: $TempoFormatado"

            return [PSCustomObject]@{ Status = "Gerado"; VocalsPath = $FinalVocals; InstrumentalPath = $FinalInstrumental; Tempo = $TempoFormatado }
        }

        Add-Log -LogBox $LogBox -Mensagem "ERRO: Demucs terminou, mas não gerou vocals.wav e no_vocals.wav no formato esperado."
        Add-Log -LogBox $LogBox -Mensagem "ExitCode do Demucs: $ExitCode"
        if (-not [string]::IsNullOrWhiteSpace($OutText)) { Add-Log -LogBox $LogBox -Mensagem "STDOUT Demucs: $($OutText.TrimEnd())" }
        if (-not [string]::IsNullOrWhiteSpace($ErrText)) { Add-Log -LogBox $LogBox -Mensagem "STDERR Demucs: $($ErrText.TrimEnd())" }
        $ArquivosGerados = Get-ChildItem -LiteralPath $TempRoot -Recurse -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
        if ($ArquivosGerados) {
            Add-Log -LogBox $LogBox -Mensagem "Arquivos encontrados na pasta temporária do Demucs:"
            foreach ($ArquivoGerado in $ArquivosGerados) { Add-Log -LogBox $LogBox -Mensagem " - $ArquivoGerado" }
        }
        else {
            Add-Log -LogBox $LogBox -Mensagem "Nenhum arquivo encontrado na pasta temporária do Demucs: $TempRoot"
        }
        return [PSCustomObject]@{ Status = "Erro"; VocalsPath = $FinalVocals; InstrumentalPath = $FinalInstrumental; Tempo = "ERRO após $TempoFormatado" }
    }
    catch {
        if ($script:CancelarGeracao) {
            if ($null -ne $StatusLabel) {
                $StatusLabel.Text = "Separação interrompida."
                $StatusLabel.Refresh()
            }
            return [PSCustomObject]@{ Status = "Interrompido"; VocalsPath = $FinalVocals; InstrumentalPath = $FinalInstrumental; Tempo = "INTERROMPIDO" }
        }

        Add-Log -LogBox $LogBox -Mensagem "ERRO ao executar Demucs: $($_.Exception.Message)"
        return [PSCustomObject]@{ Status = "Erro"; VocalsPath = $FinalVocals; InstrumentalPath = $FinalInstrumental; Tempo = "ERRO" }
    }
    finally {
        $script:ProcessoAtual = $null
        foreach ($ArquivoTemp in @($TempOut, $TempErr)) {
            if (-not [string]::IsNullOrWhiteSpace($ArquivoTemp)) { Remove-SafeItem -Path $ArquivoTemp }
        }
        if (-not [string]::IsNullOrWhiteSpace($TempRoot)) { Remove-SafeItem -Path $TempRoot }
    }
}

function ConvertFrom-SrtTime {
    param([string]$TimeText)

    if ($TimeText -match '^(\d+):(\d{2}):(\d{2}),(\d{3})$') {
        return (
            ([double]$Matches[1] * 3600) +
            ([double]$Matches[2] * 60) +
            ([double]$Matches[3]) +
            ([double]$Matches[4] / 1000)
        )
    }

    return 0.0
}

function Format-SrtTime {
    param([double]$Seconds)

    if ($Seconds -lt 0) {
        $Seconds = 0
    }

    $TotalMilliseconds = [int][Math]::Round($Seconds * 1000)

    $Hours = [int][Math]::Floor($TotalMilliseconds / 3600000)
    $Remainder = $TotalMilliseconds % 3600000

    $Minutes = [int][Math]::Floor($Remainder / 60000)
    $Remainder = $Remainder % 60000

    $Secs = [int][Math]::Floor($Remainder / 1000)
    $Millis = $Remainder % 1000

    return "{0:D2}:{1:D2}:{2:D2},{3:D3}" -f $Hours, $Minutes, $Secs, $Millis
}

function Read-SrtEntries {
    param([string]$Path)

    $Entries = @()

    if (-not (Test-SafePath -Path $Path)) {
        return $Entries
    }

    $Raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction SilentlyContinue

    if ([string]::IsNullOrWhiteSpace($Raw)) {
        return $Entries
    }

    $Pattern = '(?ms)^\s*\d+\s*\r?\n(?<start>\d{2,}:\d{2}:\d{2},\d{3})\s*-->\s*(?<end>\d{2,}:\d{2}:\d{2},\d{3}).*?\r?\n(?<text>.*?)(?=\r?\n\s*\r?\n|\z)'
    $MatchesSrt = [regex]::Matches($Raw, $Pattern)

    foreach ($Match in $MatchesSrt) {
        $Entries += [PSCustomObject]@{
            Start = ConvertFrom-SrtTime -TimeText ([string]$Match.Groups["start"].Value)
            End   = ConvertFrom-SrtTime -TimeText ([string]$Match.Groups["end"].Value)
            Text  = ([string]$Match.Groups["text"].Value).Trim()
        }
    }

    return $Entries
}

function Write-SrtEntries {
    param(
        [object[]]$Entries,
        [string]$Path
    )

    $Lines = New-Object System.Collections.Generic.List[string]
    $Index = 1

    foreach ($Entry in $Entries) {
        if ([string]::IsNullOrWhiteSpace([string]$Entry.Text)) {
            continue
        }

        $Lines.Add([string]$Index)
        $Lines.Add("{0} --> {1}" -f (Format-SrtTime -Seconds ([double]$Entry.Start)), (Format-SrtTime -Seconds ([double]$Entry.End)))
        $Lines.Add([string]$Entry.Text)
        $Lines.Add("")
        $Index++
    }

    [System.IO.File]::WriteAllLines($Path, $Lines, [System.Text.Encoding]::UTF8)
}

function New-AlbumSrtFromTrackSubtitles {
    param(
        [string]$NomeAlbum,
        [System.IO.FileInfo[]]$Musicas,
        [double[]]$Duracoes,
        [double]$SilencioEntreFaixas,
        [string]$SubtitleDirectory,
        [System.Windows.Forms.TextBox]$LogBox
    )

    if (-not (New-SafeDirectory -Path $SubtitleDirectory)) {
        Add-Log -LogBox $LogBox -Mensagem "ERRO: Não foi possível criar/acessar a pasta de legendas do álbum: $SubtitleDirectory"
        return $null
    }

    $NomeAlbumLimpo = Get-CleanAlbumName -NomeAlbum $NomeAlbum
    $AlbumSrt = Join-SafePath $SubtitleDirectory ("Álbum Completo - " + $NomeAlbumLimpo + ".srt")

    $AllEntries = @()
    $CurrentTime = 0.0

    for ($i = 0; $i -lt $Musicas.Count; $i++) {
        $TrackSrt = Join-SafePath $SubtitleDirectory ($Musicas[$i].BaseName + ".srt")
        $Entries = @(Read-SrtEntries -Path $TrackSrt)

        foreach ($Entry in $Entries) {
            $AllEntries += [PSCustomObject]@{
                Start = ([double]$Entry.Start + $CurrentTime)
                End   = ([double]$Entry.End + $CurrentTime)
                Text  = [string]$Entry.Text
            }
        }

        $CurrentTime += [double]$Duracoes[$i]

        if ($i -lt ($Musicas.Count - 1)) {
            $CurrentTime += [double]$SilencioEntreFaixas
        }
    }

    if ($AllEntries.Count -eq 0) {
        Add-Log -LogBox $LogBox -Mensagem "AVISO: Nenhuma entrada SRT encontrada para montar legenda do álbum: $NomeAlbum"
        return $null
    }

    Write-SrtEntries -Entries $AllEntries -Path $AlbumSrt
    Add-Log -LogBox $LogBox -Mensagem "Legenda do álbum salva em: $AlbumSrt"

    return $AlbumSrt
}

function Get-ItemSubtitleDirectory {
    param(
        [string]$Album
    )

    if ([string]::IsNullOrWhiteSpace($SubtitleRoot)) {
        return ""
    }

    if ([string]::IsNullOrWhiteSpace($Album)) {
        return $SubtitleRoot
    }

    return (Join-SafePath $SubtitleRoot $Album)
}

function Get-EmbeddedCoverArtPath {
    param([string]$Mp3Path)

    if ([string]::IsNullOrWhiteSpace($Mp3Path) -or -not (Test-SafePath -Path $Mp3Path)) { return "" }
    $FfmpegPath = Resolve-Executable "ffmpeg.exe"
    if (-not $FfmpegPath) { $FfmpegPath = Resolve-Executable "ffmpeg" }
    if (-not $FfmpegPath) { return "" }

    try {
        $KeyText = ([System.IO.Path]::GetFullPath($Mp3Path).ToLowerInvariant() + "|" + (Get-Item -LiteralPath $Mp3Path).LastWriteTimeUtc.Ticks)
        $Sha = [System.Security.Cryptography.SHA1]::Create()
        try {
            $Hash = ([System.BitConverter]::ToString($Sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($KeyText)))).Replace("-", "").ToLowerInvariant()
        } finally { $Sha.Dispose() }
        $Out = Join-SafePath $script:CoverCacheDirectory ($Hash + ".jpg")
        if (Test-SafePath -Path $Out) { return $Out }

        $Args = @("-hide_banner","-loglevel","error","-y","-i",$Mp3Path,"-map","0:v:0","-frames:v","1","-q:v","2",$Out)
        & $FfmpegPath @Args 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0 -and (Test-SafePath -Path $Out)) { return $Out }
    } catch { }
    return ""
}

function Get-PreferredCoverForMusic {
    param([System.IO.FileInfo]$MusicFile, [string]$AlbumFolder, [string]$PreferredName)
    if ($null -ne $MusicFile) {
        $Embedded = Get-EmbeddedCoverArtPath -Mp3Path $MusicFile.FullName
        if (-not [string]::IsNullOrWhiteSpace($Embedded)) { return $Embedded }
    }
    return (Find-CoverFile -Folder $AlbumFolder -PreferredName $PreferredName)
}

function Find-CoverFile {
    param(
        [string]$Folder,
        [string]$PreferredName
    )

    if ([string]::IsNullOrWhiteSpace($Folder)) {
        return $null
    }

    try {
        if (-not (Test-SafePath -Path $Folder)) {
            return $null
        }
    }
    catch {
        return $null
    }

    if (-not [string]::IsNullOrWhiteSpace($PreferredName)) {
        $PreferredPath = Join-SafePath $Folder $PreferredName

        try {
            if (Test-SafePath -Path $PreferredPath) {
                return $PreferredPath
            }
        }
        catch {
            # Ignora e tenta os candidatos.
        }
    }

    $CandidateNames = @(
        "frezza - capa.png",
        "capa.png",
        "capa.jpg",
        "capa.jpeg",
        "cover.png",
        "cover.jpg",
        "cover.jpeg",
        "folder.png",
        "folder.jpg",
        "front.png",
        "front.jpg",
        "album.png",
        "album.jpg"
    )

    foreach ($Name in $CandidateNames) {
        $CandidatePath = Join-SafePath $Folder $Name

        try {
            if (Test-SafePath -Path $CandidatePath) {
                return $CandidatePath
            }
        }
        catch {
            # Continua procurando.
        }
    }

    try {
        $Image = Get-ChildItem -LiteralPath $Folder -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -match '^\.(png|jpg|jpeg|webp)$' } |
            Sort-Object Name |
            Select-Object -First 1

        if ($Image) {
            return $Image.FullName
        }
    }
    catch {
        return $null
    }

    return $null
}

function Add-AlbumItemsFromFolder {
    param(
        [System.Collections.ArrayList]$Itens,
        [string]$AlbumFolder,
        [string]$AlbumName,
        [string]$PastaVideo,
        [string]$NomeCapa,
        [bool]$IncluirMusicas,
        [bool]$IncluirAlbuns
    )

    $Musicas = Get-AlbumTracks -SubpastaMP3 $AlbumFolder

    if (-not $Musicas -or $Musicas.Count -eq 0) {
        return
    }
    $CapaAlbum = ""

    $SubpastaVideo = Join-SafePath $PastaVideo $AlbumName

    if ($IncluirMusicas) {
        foreach ($Musica in $Musicas) {
            [System.Windows.Forms.Application]::DoEvents()
            $CapaMusica = Get-PreferredCoverForMusic -MusicFile $Musica -AlbumFolder $AlbumFolder -PreferredName $NomeCapa
            if ([string]::IsNullOrWhiteSpace($CapaAlbum) -and -not [string]::IsNullOrWhiteSpace($CapaMusica)) { $CapaAlbum = $CapaMusica }
            $OutputPath = Join-SafePath $SubpastaVideo ($Musica.BaseName + ".mp4")

            [void]$Itens.Add((New-GenerationItem `
                -Type "Música" `
                -Album $AlbumName `
                -Name $Musica.BaseName `
                -MusicFile $Musica `
                -Tracks $null `
                -CoverPath $CapaMusica `
                -OutputDirectory $SubpastaVideo `
                -OutputPath $OutputPath))
        }
    }

    if ($IncluirAlbuns) {
        $NomeAlbumLimpo = Get-CleanAlbumName -NomeAlbum $AlbumName
        $OutputPath = Join-SafePath $SubpastaVideo ("Álbum Completo - " + $NomeAlbumLimpo + ".mp4")

        [void]$Itens.Add((New-GenerationItem `
            -Type "Álbum" `
            -Album $AlbumName `
            -Name "Álbum Completo - $NomeAlbumLimpo" `
            -MusicFile $null `
            -Tracks $Musicas `
            -CoverPath $(if (-not [string]::IsNullOrWhiteSpace($CapaAlbum)) { $CapaAlbum } else { Find-CoverFile -Folder $AlbumFolder -PreferredName $NomeCapa }) `
            -OutputDirectory $SubpastaVideo `
            -OutputPath $OutputPath))
    }
}

function Write-GenerationReport {
    param(
        [string]$OutputRoot,
        [object[]]$Relatorio,
        [int]$TotalGerados,
        [int]$TotalPulados,
        [int]$TotalErros,
        [int]$TotalInterrompidos,
        [string]$TempoTotalFormatado
    )

    if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
        return $null
    }

    try {
        if (-not (Test-SafePath -Path $OutputRoot)) {
            New-SafeDirectory -Path $OutputRoot | Out-Null
        }

        $ReportPath = Join-SafePath $OutputRoot ("relatorio-geracao-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".txt")
        $Lines = New-Object System.Collections.Generic.List[string]

        $Lines.Add("RELATÓRIO DE GERAÇÃO - FREZZA")
        $Lines.Add("Data: " + (Get-Date -Format "dd/MM/yyyy HH:mm:ss"))
        $Lines.Add("")
        $Lines.Add("RESUMO")
        $Lines.Add("Vídeos gerados: $TotalGerados")
        $Lines.Add("Vídeos pulados: $TotalPulados")
        $Lines.Add("Interrompidos: $TotalInterrompidos")
        $Lines.Add("Erros: $TotalErros")
        $Lines.Add("Tempo total: $TempoTotalFormatado")
        $Lines.Add("")
        $Lines.Add("ITENS PROCESSADOS")
        $Lines.Add("Nome | Path | Tempo Gasto")

        foreach ($Item in $Relatorio) {
            $Lines.Add("$($Item.Nome) | $($Item.Path) | $($Item.'Tempo Gasto')")
        }

        [System.IO.File]::WriteAllLines($ReportPath, $Lines, [System.Text.Encoding]::UTF8)
        return $ReportPath
    }
    catch {
        return $null
    }
}


function Get-AlbumTracks {
    param(
        [string]$SubpastaMP3
    )

    return Get-ChildItem -LiteralPath $SubpastaMP3 -Filter "*.mp3" -File | Sort-Object Name
}

function Get-AlbumExpectedDuration {
    param(
        [System.IO.FileInfo[]]$Musicas,
        [double]$SilencioEntreFaixas,
        [string]$FfprobePath
    )

    $DuracaoTotal = 0

    foreach ($Musica in $Musicas) {
        $Duracao = Get-MediaDuration -Arquivo $Musica.FullName -FfprobePath $FfprobePath

        if ($null -eq $Duracao) {
            return $null
        }

        $DuracaoTotal += $Duracao
    }

    if ($Musicas.Count -gt 1) {
        $DuracaoTotal += (($Musicas.Count - 1) * $SilencioEntreFaixas)
    }

    return $DuracaoTotal
}


function New-SingleTrackLayoutImage {
    param(
        [string]$NomeMusica,
        [string]$Capa
    )

    $OutputImage = Join-Path ([System.IO.Path]::GetTempPath()) ("frezza_track_layout_" + [System.Guid]::NewGuid().ToString("N") + ".png")

    $Bitmap = New-Object System.Drawing.Bitmap 1920, 1920
    $Graphics = [System.Drawing.Graphics]::FromImage($Bitmap)

    $CoverImage = $null
    $BrushBackground = $null
    $BrushOverlay = $null
    $BrushWhite = $null
    $BrushShadow = $null
    $TitleFont = $null
    $StringFormat = $null

    try {
        $Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $Graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $Graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit

        $BrushBackground = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::Black)
        $Graphics.FillRectangle($BrushBackground, 0, 0, 1920, 1920)

        $CoverImage = [System.Drawing.Image]::FromFile($Capa)

        $MaxW = 1920
        $MaxH = 1920
        $Scale = [Math]::Min($MaxW / $CoverImage.Width, $MaxH / $CoverImage.Height)
        $CoverW = [int]($CoverImage.Width * $Scale)
        $CoverH = [int]($CoverImage.Height * $Scale)
        $CoverX = [int](($MaxW - $CoverW) / 2)
        $CoverY = [int](($MaxH - $CoverH) / 2)

        $Graphics.DrawImage($CoverImage, $CoverX, $CoverY, $CoverW, $CoverH)

        try {
            $FontFamily = New-Object System.Drawing.FontFamily "Century Gothic"
        }
        catch {
            $FontFamily = New-Object System.Drawing.FontFamily "Arial"
        }

        $Texto = Limit-TextForImage -Text $NomeMusica -MaxChars 42

        $FontSize = 92

        if ($Texto.Length -gt 28) {
            $FontSize = 90
        }

        if ($Texto.Length -gt 36) {
            $FontSize = 75
        }

        $TitleFont = New-Object System.Drawing.Font($FontFamily, $FontSize, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)

        $StringFormat = New-Object System.Drawing.StringFormat
        $StringFormat.Alignment = [System.Drawing.StringAlignment]::Center
        $StringFormat.LineAlignment = [System.Drawing.StringAlignment]::Center

        $RectOverlay = New-Object System.Drawing.RectangleF(0, 790, 1920, 340)
        $BrushOverlay = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(150, 0, 0, 0))
        $Graphics.FillRectangle($BrushOverlay, $RectOverlay)

        $RectShadow = New-Object System.Drawing.RectangleF(5, 795, 1920, 340)
        $RectText = New-Object System.Drawing.RectangleF(0, 790, 1920, 340)

        $BrushShadow = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(220, 0, 0, 0))
        $BrushWhite = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)

        $Graphics.DrawString($Texto, $TitleFont, $BrushShadow, $RectShadow, $StringFormat)
        $Graphics.DrawString($Texto, $TitleFont, $BrushWhite, $RectText, $StringFormat)

        $Bitmap.Save($OutputImage, [System.Drawing.Imaging.ImageFormat]::Png)
        return $OutputImage
    }
    finally {
        if ($CoverImage) { $CoverImage.Dispose() }
        if ($TitleFont) { $TitleFont.Dispose() }
        if ($StringFormat) { $StringFormat.Dispose() }
        if ($BrushBackground) { $BrushBackground.Dispose() }
        if ($BrushOverlay) { $BrushOverlay.Dispose() }
        if ($BrushWhite) { $BrushWhite.Dispose() }
        if ($BrushShadow) { $BrushShadow.Dispose() }
        if ($Graphics) { $Graphics.Dispose() }
        if ($Bitmap) { $Bitmap.Dispose() }
    }
}

function Invoke-SingleTrackVideo {
    param(
        [System.IO.FileInfo]$Musica,
        [string]$Capa,
        [string]$SubpastaVideo,
        [double]$SegundosExtras,
        [bool]$Detalhado,
        [bool]$ValidarDuracaoExistentes,
        [double]$ToleranciaSegundos,
        [string]$FfmpegPath,
        [string]$FfprobePath,
        [System.Windows.Forms.TextBox]$LogBox,
        [System.Windows.Forms.Label]$StatusLabel
    )

    $ArquivoMP3 = $Musica.FullName
    $NomeBase = $Musica.BaseName
    $ArquivoVideo = Join-Path $SubpastaVideo ($NomeBase + ".mp4")

    $DuracaoMP3 = Get-MediaDuration -Arquivo $ArquivoMP3 -FfprobePath $FfprobePath

    if ($null -eq $DuracaoMP3) {
        Add-Log -LogBox $LogBox -Mensagem "ERRO: Não foi possível obter a duração do MP3: $ArquivoMP3"
        return [PSCustomObject]@{
            Status = "Erro"
            Nome = $NomeBase
            Path = $ArquivoVideo
            Tempo = "ERRO"
        }
    }

    $DuracaoVideoEsperada = $DuracaoMP3 + $SegundosExtras

    if (Test-SafePath -Path $ArquivoVideo) {
        if (-not $ValidarDuracaoExistentes) {
            Add-Log -LogBox $LogBox -Mensagem ""
            Add-Log -LogBox $LogBox -Mensagem "Vídeo já existe, pulando: $ArquivoVideo"

            return [PSCustomObject]@{
                Status = "Pulado"
                Nome = $NomeBase
                Path = $ArquivoVideo
                Tempo = "-"
            }
        }

        $Validacao = Test-ExistingVideo `
            -ArquivoVideo $ArquivoVideo `
            -DuracaoEsperada $DuracaoVideoEsperada `
            -ToleranciaSegundos $ToleranciaSegundos `
            -FfprobePath $FfprobePath

        if ($Validacao.Existe -and $Validacao.Valido) {
            Add-Log -LogBox $LogBox -Mensagem ""
            Add-Log -LogBox $LogBox -Mensagem "Vídeo já existe e está completo, pulando: $ArquivoVideo"

            return [PSCustomObject]@{
                Status = "Pulado"
                Nome = $NomeBase
                Path = $ArquivoVideo
                Tempo = "-"
            }
        }

        Add-Log -LogBox $LogBox -Mensagem ""
        Add-Log -LogBox $LogBox -Mensagem "Vídeo existente incompleto ou incorreto. Será recriado."
        Remove-SafeItem -Path $ArquivoVideo
    }

    Add-Log -LogBox $LogBox -Mensagem ""
    Add-Log -LogBox $LogBox -Mensagem "Gerando vídeo da música: $NomeBase.mp4"
    Write-DurationLine -LogBox $LogBox -Rotulo "Duração do vídeo" -Segundos $DuracaoVideoEsperada
    Add-Log -LogBox $LogBox -Mensagem "Destino: $ArquivoVideo"

    $ImagemMusicaTemporaria = New-SingleTrackLayoutImage `
        -NomeMusica $NomeBase `
        -Capa $Capa

    $DuracaoVideoArgumento = $DuracaoVideoEsperada.ToString("0.######", [System.Globalization.CultureInfo]::InvariantCulture)

    $Argumentos = @(
        "-y",
        "-loop", "1",
        "-framerate", "2",
        "-i", $ImagemMusicaTemporaria,
        "-i", $ArquivoMP3,
        "-map", "0:v:0",
        "-map", "1:a:0",
        "-t", $DuracaoVideoArgumento,
        "-c:v", "libx264",
        "-preset", "veryfast",
        "-tune", "stillimage",
        "-vf", "scale=1920:1920:force_original_aspect_ratio=decrease,pad=1920:1920:(ow-iw)/2:(oh-ih)/2",
        "-c:a", "aac",
        "-b:a", "320k",
        "-pix_fmt", "yuv420p",
        "-movflags", "+faststart",
        $ArquivoVideo
    )

    if (-not $Detalhado) {
        $Argumentos = @("-hide_banner", "-nostats", "-loglevel", "error") + $Argumentos
    }

    $InicioGeracao = Get-Date

    $CodigoSaida = Invoke-Ffmpeg `
        -FfmpegPath $FfmpegPath `
        -Argumentos $Argumentos `
        -Detalhado $Detalhado `
        -StatusLabel $StatusLabel `
        -LogBox $LogBox

    if ($ImagemMusicaTemporaria -and (Test-SafePath -Path $ImagemMusicaTemporaria)) {
        Remove-SafeItem -Path $ImagemMusicaTemporaria
    }

    $FimGeracao = Get-Date
    $TempoGeracao = $FimGeracao - $InicioGeracao
    $TempoFormatado = "{0:hh\:mm\:ss}" -f $TempoGeracao

    if ($CodigoSaida -eq -999) {
        Add-Log -LogBox $LogBox -Mensagem "Geração interrompida pelo usuário."
        Add-Log -LogBox $LogBox -Mensagem "Tempo até a interrupção: $TempoFormatado"

        if (Test-SafePath -Path $ArquivoVideo) {
            Remove-SafeItem -Path $ArquivoVideo
            Add-Log -LogBox $LogBox -Mensagem "Arquivo incompleto removido: $ArquivoVideo"
        }

        return [PSCustomObject]@{
            Status = "Interrompido"
            Nome = $NomeBase
            Path = $ArquivoVideo
            Tempo = "INTERROMPIDO após $TempoFormatado"
        }
    }

    $ValidacaoPosGeracao = Test-ExistingVideo `
        -ArquivoVideo $ArquivoVideo `
        -DuracaoEsperada $DuracaoVideoEsperada `
        -ToleranciaSegundos $ToleranciaSegundos `
        -FfprobePath $FfprobePath

    $CodigoSaidaVazio = [string]::IsNullOrWhiteSpace([string]$CodigoSaida)
    $VideoFinalValido = $ValidacaoPosGeracao.Existe -and $ValidacaoPosGeracao.Valido
    $FfmpegRetornouSucesso = ($CodigoSaida -eq 0)

    if ($FfmpegRetornouSucesso -or $VideoFinalValido) {
        Add-Log -LogBox $LogBox -Mensagem "Concluído."
        Add-Log -LogBox $LogBox -Mensagem "Tempo gasto nesta música: $TempoFormatado"

        return [PSCustomObject]@{
            Status = "Gerado"
            Nome = $NomeBase
            Path = $ArquivoVideo
            Tempo = $TempoFormatado
        }
    }

    Add-Log -LogBox $LogBox -Mensagem "ERRO ao gerar: $ArquivoVideo"
    Add-Log -LogBox $LogBox -Mensagem "Tempo até o erro: $TempoFormatado"

    return [PSCustomObject]@{
        Status = "Erro"
        Nome = $NomeBase
        Path = $ArquivoVideo
        Tempo = "ERRO após $TempoFormatado"
    }
}

function New-AlbumVideoFilter {
    param(
        [System.IO.FileInfo[]]$Musicas,
        [double]$DuracaoEsperada,
        [string]$NomeAlbum,
        [string]$FontPath
    )

    $DuracaoArgumento = $DuracaoEsperada.ToString("0.######", [System.Globalization.CultureInfo]::InvariantCulture)
    $FontFfmpeg = Convert-FontPathForFfmpeg -Path $FontPath
    $Titulo = Escape-DrawText -Text $NomeAlbum

    $VideoFilters = @()
    $VideoFilters += "[0:v]scale=860:860:force_original_aspect_ratio=decrease,pad=960:1080:(ow-iw)/2:(oh-ih)/2:color=0x101010[left]"
    $VideoFilters += "color=c=0x111111:s=960x1080:d=$DuracaoArgumento[right]"
    $VideoFilters += "[left][right]hstack=inputs=2[v0]"

    $CurrentLabel = "v0"
    $NextIndex = 1

    $VideoFilters += "[$CurrentLabel]drawtext=fontfile='$FontFfmpeg':text='$Titulo':x=1020:y=70:fontsize=42:fontcolor=white[v$NextIndex]"
    $CurrentLabel = "v$NextIndex"
    $NextIndex++

    $VideoFilters += "[$CurrentLabel]drawtext=fontfile='$FontFfmpeg':text='TRACKLIST':x=1020:y=135:fontsize=34:fontcolor=0xdddddd[v$NextIndex]"
    $CurrentLabel = "v$NextIndex"
    $NextIndex++

    $Y = 205
    $LineHeight = 40
    $FontSize = 26

    if ($Musicas.Count -gt 18) {
        $LineHeight = 33
        $FontSize = 22
    }

    if ($Musicas.Count -gt 24) {
        $LineHeight = 28
        $FontSize = 18
    }

    for ($i = 0; $i -lt $Musicas.Count; $i++) {
        $Faixa = $Musicas[$i].BaseName
        $TextoFaixa = Escape-DrawText -Text $Faixa

        $VideoFilters += "[$CurrentLabel]drawtext=fontfile='$FontFfmpeg':text='$TextoFaixa':x=1020:y=$Y:fontsize=$FontSize:fontcolor=white[v$NextIndex]"
        $CurrentLabel = "v$NextIndex"
        $NextIndex++
        $Y += $LineHeight
    }

    $VideoFilters += "[$CurrentLabel]format=yuv420p[vout]"

    return $VideoFilters
}



function Get-CleanAlbumName {
    param([string]$NomeAlbum)

    if ([string]::IsNullOrWhiteSpace($NomeAlbum)) {
        return $NomeAlbum
    }

    return ($NomeAlbum -replace '^\s*\d+\s*[-–—]\s*', '').Trim()
}

function Format-AssTime {
    param([double]$Seconds)

    if ($Seconds -lt 0) {
        $Seconds = 0
    }

    $TotalCentiseconds = [int][Math]::Floor($Seconds * 100)

    $Hours = [int][Math]::Floor($TotalCentiseconds / 360000)
    $Remainder = $TotalCentiseconds % 360000

    $Minutes = [int][Math]::Floor($Remainder / 6000)
    $Remainder = $Remainder % 6000

    $Secs = [int][Math]::Floor($Remainder / 100)
    $Centis = $Remainder % 100

    return "{0}:{1:D2}:{2:D2}.{3:D2}" -f $Hours, $Minutes, $Secs, $Centis
}

function Escape-AssText {
    param([string]$Text)

    if ($null -eq $Text) {
        return ""
    }

    $Escaped = $Text
    $Escaped = $Escaped -replace '\{', '\{'
    $Escaped = $Escaped -replace '\}', '\}'
    $Escaped = $Escaped -replace "`r?`n", " "
    return $Escaped
}

function New-AlbumHighlightSubtitleWithDurations {
    param(
        [System.IO.FileInfo[]]$Musicas,
        [double[]]$Duracoes,
        [double]$SilencioEntreFaixas,
        [string]$FontName
    )

    # Gera um caminho temporário único para o arquivo ASS
    $OutputAss = Join-Path ([System.IO.Path]::GetTempPath()) ("frezza_album_highlight_" + [System.Guid]::NewGuid().ToString("N") + ".ass")

    $TrackCount = $Musicas.Count
    
    # --- CORREÇÃO 3: Tabela Dinâmica e Ampliada de Tracklist ---
    # Valores base para tracklists curtas (até 18 faixas), como no seu exemplo.
    $Y = 240           # Posição Y inicial (mais para baixo)
    $LineHeight = 56   # Espaçamento vertical entre linhas (aumentado de 44)
    $FontSize = 40     # Tamanho da fonte das faixas (aumentado de 34)
    $MaxChars = 48     # Limite de caracteres mais rigoroso para fonte maior

    # Se a tracklist for média, reduz o tamanho e espaçamento
    if ($TrackCount -gt 18) {
        $Y = 210
        $LineHeight = 38
        $FontSize = 30
        $MaxChars = 60
    }

    # Se a tracklist for muito grande, reduz ainda mais
    if ($TrackCount -gt 26) {
        $Y = 205
        $LineHeight = 30
        $FontSize = 24
        $MaxChars = 72
    }

    # Calcula o início de cada faixa.
    $StartTimes = @()
    $CurrentTime = 0.0

    for ($i = 0; $i -lt $Musicas.Count; $i++) {
        $StartTimes += [double]$CurrentTime
        $CurrentTime += [double]$Duracoes[$i]
        if ($i -lt ($Musicas.Count - 1)) {
            $CurrentTime += [double]$SilencioEntreFaixas
        }
    }

    $TotalDuration = [Math]::Max($CurrentTime, 0.1)

    # Inicia a construção do arquivo ASS
    $Lines = New-Object System.Collections.Generic.List[string]

    # Cabeçalho padrão do ASS
    $Lines.Add("[Script Info]")
    $Lines.Add("ScriptType: v4.00+")
    if ($PlayResX -le 0) { $PlayResX = 1920 }
    if ($PlayResY -le 0) { $PlayResY = 1080 }

    $Lines.Add("PlayResX: $PlayResX")
    $Lines.Add("PlayResY: $PlayResY")
    $Lines.Add("ScaledBorderAndShadow: yes")
    $Lines.Add("")
    $Lines.Add("[V4+ Styles]")
    $Lines.Add("Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding")
    
    # Define estilos: faixas brancas e faixa destacada (amarela)
    # Outline 1 e Shadow 1 para legibilidade contra a capa se necessário.
    $Lines.Add("Style: TrackWhite,$FontName,$FontSize,&H00FFFFFF,&H00FFFFFF,&H00000000,&H00000000,-1,0,0,0,100,100,0,0,1,1,1,7,0,0,0,1")
    $Lines.Add("Style: Highlight,$FontName,$FontSize,&H0000FFFF,&H0000FFFF,&H00000000,&H00000000,-1,0,0,0,100,100,0,0,1,1,1,7,0,0,0,1")
    $Lines.Add("")
    $Lines.Add("[Events]")
    $Lines.Add("Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text")

    # Gera os eventos de legenda. Cada bloco de tempo redesenha a lista inteira
    # para garantir sobreposição e alinhamento perfeitos.
    for ($currentTrack = 0; $currentTrack -lt $Musicas.Count; $currentTrack++) {
        # Define o intervalo de tempo para a faixa atual estar destacada
        $Start = Format-AssTime -Seconds ([double]$StartTimes[$currentTrack])
        if ($currentTrack -lt ($Musicas.Count - 1)) {
            $End = Format-AssTime -Seconds ([double]$StartTimes[$currentTrack + 1])
        }
        else {
            $End = Format-AssTime -Seconds $TotalDuration
        }

        # Redesenha a lista inteira para este bloco de tempo
        for ($lineTrack = 0; $lineTrack -lt $Musicas.Count; $lineTrack++) {
            # Obtém e formata o título
            $TrackText = Get-CleanTrackTitle -Title $Musicas[$lineTrack].BaseName
            $TrackText = Limit-TextForImage -Text $TrackText -MaxChars $MaxChars
            $TrackText = Escape-AssText -Text $TrackText # Limpa caracteres especiais de ASS

            # Calcula posição Y para esta linha
            $Ypos = $Y + ($lineTrack * $LineHeight)

            # Define estilo e layer (camada)
            if ($lineTrack -eq $currentTrack) {
                $Style = "Highlight" # Amarelo
                $Layer = 1
            }
            else {
                $Style = "TrackWhite" # Branco
                $Layer = 0
            }

            # Adiciona a linha de diálogo
            $Lines.Add("Dialogue: $Layer,$Start,$End,$Style,,0,0,0,,{\an7\pos(1020,$Ypos)}$TrackText")
        }
    }

    # Salva o arquivo ASS
    [System.IO.File]::WriteAllLines($OutputAss, $Lines, [System.Text.Encoding]::UTF8)

    return $OutputAss
}

function Limit-TextForImage {
    param(
        [string]$Text,
        [int]$MaxChars
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }

    if ($Text.Length -le $MaxChars) {
        return $Text
    }

    return $Text.Substring(0, [Math]::Max(0, $MaxChars - 3)) + "..."
}

function New-AlbumLayoutImage {
    param(
        [string]$NomeAlbum,
        [System.IO.FileInfo[]]$Musicas,
        [string]$Capa,
        [string]$FontPath
    )

    # Gera um caminho de arquivo temporário único
    $OutputImage = Join-Path ([System.IO.Path]::GetTempPath()) ("frezza_album_layout_" + [System.Guid]::NewGuid().ToString("N") + ".png")

    # Cria o bitmap
    $Bitmap = New-Object System.Drawing.Bitmap 1920, 1080
    $Graphics = [System.Drawing.Graphics]::FromImage($Bitmap)

    # Pré-define objetos para limpeza segura
    $CoverImage = $null
    $BrushTotalBlack = $null # Fundo total
    $BrushWhite = $null
    $BrushGray = $null
    $TitleFont = $null
    $HeadingFont = $null
    # $TrackFont = $null # Não desenhado aqui, mas definido para contexto de layout

    try {
        # Configura qualidade gráfica
        $Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $Graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $Graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit

        # --- CORREÇÃO 1: Fundo Totalmente Preto ---
        # Cria um pincel preto puro e preenche toda a área 1920x1080
        $BrushTotalBlack = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::Black)
        $Graphics.FillRectangle($BrushTotalBlack, 0, 0, 1920, 1080)

        # --- Carrega e Desenha a Capa ---
        if (Test-SafePath -Path $Capa) {
            $CoverImage = [System.Drawing.Image]::FromFile($Capa)
            $MaxCoverW = 860
            $MaxCoverH = 860
            $Scale = [Math]::Min($MaxCoverW / $CoverImage.Width, $MaxCoverH / $CoverImage.Height)
            $CoverW = [int]($CoverImage.Width * $Scale)
            $CoverH = [int]($CoverImage.Height * $Scale)
            # Centraliza a capa na metade esquerda (0 a 960)
            $CoverX = [int]((960 - $CoverW) / 2)
            $CoverY = [int]((1080 - $CoverH) / 2)
            $Graphics.DrawImage($CoverImage, $CoverX, $CoverY, $CoverW, $CoverH)
        }

        # --- Configuração de Fontes ---
        try {
            $FontFamily = New-Object System.Drawing.FontFamily "Century Gothic"
        }
        catch {
            $FontFamily = New-Object System.Drawing.FontFamily "Arial"
        }

        # Pincéis de texto
        $BrushWhite = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
        $BrushGray = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(220, 220, 220)) # TRACKLIST

        # --- CORREÇÃO 2: Ampliação do Título do Álbum ---
        # Aumentado de 40 para 72 pixels, Negrito
        $TitleFontSizeBase = 72
        $TitleText = Limit-TextForImage -Text (Get-CleanAlbumName -NomeAlbum $NomeAlbum) -MaxChars 38
        
        # Ajuste dinâmico do título se ele for muito longo
        if ($TitleText.Length -gt 24) { $TitleFontSizeBase = 56 }
        if ($TitleText.Length -gt 32) { $TitleFontSizeBase = 44 }

        $TitleFont = New-Object System.Drawing.Font($FontFamily, $TitleFontSizeBase, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        
        # Heading "TRACKLIST", aumentado de 32 para 38
        $HeadingFont = New-Object System.Drawing.Font($FontFamily, 38, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)

        # --- Desenha os Textos ---
        # Posições X padrão para o bloco de texto (lado direito)
        $TextStartX = 1020

        # Desenha Título e Heading
        $Graphics.DrawString($TitleText, $TitleFont, $BrushWhite, $TextStartX, 70)
        $Graphics.DrawString("TRACKLIST", $HeadingFont, $BrushGray, $TextStartX, 160) # Y ajustado para dar mais espaço

        # Nota: As faixas em si são desenhadas via legenda ASS por outra função
        # ($New-AlbumHighlightSubtitleWithDurations$) para suporte a destaque colorido.

        # Salva o resultado
        $Bitmap.Save($OutputImage, [System.Drawing.Imaging.ImageFormat]::Png)
        return $OutputImage
    }
    finally {
        # Limpeza segura de objetos
        if ($CoverImage) { $CoverImage.Dispose() }
        if ($TitleFont) { $TitleFont.Dispose() }
        if ($HeadingFont) { $HeadingFont.Dispose() }
        if ($BrushTotalBlack) { $BrushTotalBlack.Dispose() }
        if ($BrushWhite) { $BrushWhite.Dispose() }
        if ($BrushGray) { $BrushGray.Dispose() }
        if ($Graphics) { $Graphics.Dispose() }
        if ($Bitmap) { $Bitmap.Dispose() }
    }
}

function Invoke-AlbumVideo {
    param(
        [string]$NomeAlbum,
        [System.IO.FileInfo[]]$Musicas,
        [string]$Capa,
        [string]$SubpastaVideo,
        [double]$SilencioEntreFaixas,
        [bool]$Detalhado,
        [bool]$ValidarDuracaoExistentes,
        [double]$ToleranciaSegundos,
        [string]$FfmpegPath,
        [string]$FfprobePath,
        [System.Windows.Forms.TextBox]$LogBox,
        [System.Windows.Forms.Label]$StatusLabel
    )

    $NomeAlbumLimpo = Get-CleanAlbumName -NomeAlbum $NomeAlbum
    $NomeAlbumCompleto = "Álbum Completo - $NomeAlbumLimpo"

    if ($Musicas.Count -eq 0) {
        Add-Log -LogBox $LogBox -Mensagem "Nenhum MP3 encontrado para gerar vídeo do álbum: $NomeAlbum"
        return [PSCustomObject]@{
            Status = "Erro"
            Nome = $NomeAlbumCompleto
            Path = ""
            Tempo = "SEM MP3"
        }
    }

    $ArquivoAlbum = Join-SafePath $SubpastaVideo ("Álbum Completo - " + $NomeAlbumLimpo + ".mp4")
    $DuracaoEsperada = Get-AlbumExpectedDuration -Musicas $Musicas -SilencioEntreFaixas $SilencioEntreFaixas -FfprobePath $FfprobePath

    if ($null -eq $DuracaoEsperada) {
        Add-Log -LogBox $LogBox -Mensagem "ERRO: Não foi possível calcular a duração total do álbum: $NomeAlbum"
        return [PSCustomObject]@{
            Status = "Erro"
            Nome = $NomeAlbumCompleto
            Path = $ArquivoAlbum
            Tempo = "ERRO"
        }
    }

    $DuracoesFaixas = @()
    foreach ($Musica in $Musicas) {
        $DuracaoFaixa = Get-MediaDuration -Arquivo $Musica.FullName -FfprobePath $FfprobePath

        if ($null -eq $DuracaoFaixa) {
            Add-Log -LogBox $LogBox -Mensagem "ERRO: Não foi possível obter a duração da faixa: $($Musica.FullName)"
            return [PSCustomObject]@{
                Status = "Erro"
                Nome = $NomeAlbumCompleto
                Path = $ArquivoAlbum
                Tempo = "ERRO"
            }
        }

        $DuracoesFaixas += [double]$DuracaoFaixa
    }
	
	$DescricaoCapitulos = New-AlbumTimestampDescription `
		-Musicas $Musicas `
		-Duracoes $DuracoesFaixas `
		-SilencioEntreFaixas $SilencioEntreFaixas

	if ($Detalhado) {
		Add-Log -LogBox $LogBox -Mensagem "Capítulos do álbum:"
		Add-Log -LogBox $LogBox -Mensagem $DescricaoCapitulos
	}

    if (Test-SafePath -Path $ArquivoAlbum) {
        if (-not $ValidarDuracaoExistentes) {
            Add-Log -LogBox $LogBox -Mensagem ""
            Add-Log -LogBox $LogBox -Mensagem "Vídeo do álbum já existe, pulando: $ArquivoAlbum"

            return [PSCustomObject]@{
                Status = "Pulado"
                Nome = $NomeAlbumCompleto
                Path = $ArquivoAlbum
                Tempo = "-"
            }
        }

        $Validacao = Test-ExistingVideo `
            -ArquivoVideo $ArquivoAlbum `
            -DuracaoEsperada $DuracaoEsperada `
            -ToleranciaSegundos $ToleranciaSegundos `
            -FfprobePath $FfprobePath

        if ($Validacao.Existe -and $Validacao.Valido) {
            Add-Log -LogBox $LogBox -Mensagem ""
            Add-Log -LogBox $LogBox -Mensagem "Vídeo do álbum já existe e está completo, pulando: $ArquivoAlbum"

            return [PSCustomObject]@{
                Status = "Pulado"
                Nome = $NomeAlbumCompleto
                Path = $ArquivoAlbum
                Tempo = "-"
            }
        }

        Add-Log -LogBox $LogBox -Mensagem ""
        Add-Log -LogBox $LogBox -Mensagem "Vídeo do álbum existente incompleto ou incorreto. Será recriado."
        Remove-SafeItem -Path $ArquivoAlbum
    }

    $FontPath = Resolve-FontFile

    if (-not $FontPath) {
        Add-Log -LogBox $LogBox -Mensagem "ERRO: Nenhuma fonte compatível encontrada em C:\Windows\Fonts."
        return [PSCustomObject]@{
            Status = "Erro"
            Nome = $NomeAlbumCompleto
            Path = $ArquivoAlbum
            Tempo = "SEM FONTE"
        }
    }

    Add-Log -LogBox $LogBox -Mensagem ""
    Add-Log -LogBox $LogBox -Mensagem "Gerando vídeo do álbum: $NomeAlbum"
    Add-Log -LogBox $LogBox -Mensagem "Layout: capa à esquerda, faixas à direita."
    if ($Detalhado) {
        Add-Log -LogBox $LogBox -Mensagem "Fonte usada: $FontPath"
    }
    Add-Log -LogBox $LogBox -Mensagem "Faixas: $($Musicas.Count)"
    Write-DurationLine -LogBox $LogBox -Rotulo "Duração estimada do álbum" -Segundos $DuracaoEsperada
    Add-Log -LogBox $LogBox -Mensagem "Destino: $ArquivoAlbum"

    $ImagemAlbumTemporaria = New-AlbumLayoutImage `
        -NomeAlbum $NomeAlbum `
        -Musicas $Musicas `
        -Capa $Capa `
        -FontPath $FontPath

    $ArquivoAssTemporario = New-AlbumHighlightSubtitleWithDurations `
        -Musicas $Musicas `
        -Duracoes $DuracoesFaixas `
        -SilencioEntreFaixas $SilencioEntreFaixas `
        -FontName "Century Gothic"

    $ArquivoAssFfmpeg = Convert-FontPathForFfmpeg -Path $ArquivoAssTemporario
    $FontsDirFfmpeg = Convert-FontPathForFfmpeg -Path "C:\Windows\Fonts"
    $SubtitleFilter = "subtitles='$ArquivoAssFfmpeg':fontsdir='$FontsDirFfmpeg'"

    $Argumentos = @(
        "-y",
        "-loop", "1",
        "-framerate", "2",
        "-i", $ImagemAlbumTemporaria
    )

    $AudioLabels = @()
    $InputIndex = 1
    $AudioIndex = 0

    for ($i = 0; $i -lt $Musicas.Count; $i++) {
        $Argumentos += @("-i", $Musicas[$i].FullName)
        $AudioLabels += [PSCustomObject]@{
            InputIndex = $InputIndex
            Label = "a$AudioIndex"
        }
        $InputIndex++
        $AudioIndex++

        if ($i -lt ($Musicas.Count - 1) -and $SilencioEntreFaixas -gt 0) {
            $SilencioArgumento = "anullsrc=channel_layout=stereo:sample_rate=48000"
            $SilencioDuracao = $SilencioEntreFaixas.ToString("0.######", [System.Globalization.CultureInfo]::InvariantCulture)

            $Argumentos += @("-f", "lavfi", "-t", $SilencioDuracao, "-i", $SilencioArgumento)
            $AudioLabels += [PSCustomObject]@{
                InputIndex = $InputIndex
                Label = "a$AudioIndex"
            }
            $InputIndex++
            $AudioIndex++
        }
    }

    $FilterParts = @()
    $ConcatInputs = ""

    foreach ($Audio in $AudioLabels) {
        $FilterParts += "[$($Audio.InputIndex):a:0]aformat=sample_rates=48000:channel_layouts=stereo[$($Audio.Label)]"
        $ConcatInputs += "[$($Audio.Label)]"
    }

    $FilterParts += "$ConcatInputs" + "concat=n=$($AudioLabels.Count):v=0:a=1[aout]"
    $FilterComplex = $FilterParts -join ";"

    $DuracaoArgumento = $DuracaoEsperada.ToString("0.######", [System.Globalization.CultureInfo]::InvariantCulture)

    $Argumentos += @(
        "-filter_complex", $FilterComplex,
        "-map", "0:v:0",
        "-map", "[aout]",
        "-t", $DuracaoArgumento,
        "-vf", $SubtitleFilter,
        "-c:v", "libx264",
        "-preset", "veryfast",
        "-tune", "stillimage",
        "-pix_fmt", "yuv420p",
        "-c:a", "aac",
        "-b:a", "320k",
        "-movflags", "+faststart",
        $ArquivoAlbum
    )

    if (-not $Detalhado) {
        $Argumentos = @("-hide_banner", "-nostats", "-loglevel", "error") + $Argumentos
    }

    $InicioGeracao = Get-Date

    $CodigoSaida = Invoke-Ffmpeg `
        -FfmpegPath $FfmpegPath `
        -Argumentos $Argumentos `
        -Detalhado $Detalhado `
        -StatusLabel $StatusLabel `
        -LogBox $LogBox

    if ($ImagemAlbumTemporaria -and (Test-SafePath -Path $ImagemAlbumTemporaria)) {
        Remove-SafeItem -Path $ImagemAlbumTemporaria
    }

    if ($ArquivoAssTemporario -and (Test-SafePath -Path $ArquivoAssTemporario)) {
        Remove-SafeItem -Path $ArquivoAssTemporario
    }

    $FimGeracao = Get-Date
    $TempoGeracao = $FimGeracao - $InicioGeracao
    $TempoFormatado = "{0:hh\:mm\:ss}" -f $TempoGeracao

    if ($CodigoSaida -eq -999) {
        Add-Log -LogBox $LogBox -Mensagem "Geração do álbum interrompida pelo usuário."
        Add-Log -LogBox $LogBox -Mensagem "Tempo até a interrupção: $TempoFormatado"

        if (Test-SafePath -Path $ArquivoAlbum) {
            Remove-SafeItem -Path $ArquivoAlbum
            Add-Log -LogBox $LogBox -Mensagem "Arquivo incompleto removido: $ArquivoAlbum"
        }
        return [PSCustomObject]@{
            Status = "Interrompido"
            Nome = $NomeAlbumCompleto
            Path = $ArquivoAlbum
            Tempo = "INTERROMPIDO após $TempoFormatado"
        }
    }

    $ValidacaoPosGeracao = Test-ExistingVideo `
        -ArquivoVideo $ArquivoAlbum `
        -DuracaoEsperada $DuracaoEsperada `
        -ToleranciaSegundos $ToleranciaSegundos `
        -FfprobePath $FfprobePath

    $CodigoSaidaVazio = [string]::IsNullOrWhiteSpace([string]$CodigoSaida)
    $VideoFinalValido = $ValidacaoPosGeracao.Existe -and $ValidacaoPosGeracao.Valido
    $FfmpegRetornouSucesso = ($CodigoSaida -eq 0)

	if ($FfmpegRetornouSucesso -or $VideoFinalValido) {
		Save-AlbumPublishMetadataForVideo `
			-VideoPath $ArquivoAlbum `
			-AlbumName $NomeAlbum `
			-Musicas $Musicas `
			-Duracoes $DuracoesFaixas `
			-SilencioEntreFaixas $SilencioEntreFaixas

		Add-Log -LogBox $LogBox -Mensagem "Álbum concluído."
		Add-Log -LogBox $LogBox -Mensagem "Tempo gasto no álbum: $TempoFormatado"

		$MetadataPath = Get-AlbumPublishMetadataPath -VideoPath $ArquivoAlbum
		if (Test-SafePath -Path $MetadataPath) {
			Add-Log -LogBox $LogBox -Mensagem "Metadados de publicação salvos em: $MetadataPath"
		}

		return [PSCustomObject]@{
			Status = "Gerado"
			Nome = $NomeAlbumCompleto
			Path = $ArquivoAlbum
			Tempo = $TempoFormatado
		}
	}
    Add-Log -LogBox $LogBox -Mensagem "ERRO ao gerar vídeo do álbum: $ArquivoAlbum"
    Add-Log -LogBox $LogBox -Mensagem "Tempo até o erro: $TempoFormatado"

    return [PSCustomObject]@{
        Status = "Erro"
        Nome = $NomeAlbumCompleto
        Path = $ArquivoAlbum
        Tempo = "ERRO após $TempoFormatado"
    }
}



function Start-Generation {
    param(
        [string]$PastaMP3,
        [string]$PastaVideo,
        [string]$NomeCapa,
        [bool]$GerarVideosMusicas,
        [bool]$GerarVideoAlbum,
        [double]$SegundosExtras,
        [double]$SilencioEntreFaixas,
        [bool]$Detalhado,
        [bool]$ValidarDuracaoExistentes,
        [System.Windows.Forms.TextBox]$LogBox,
        [System.Windows.Forms.Label]$StatusLabel
    )

    $InicioTotal = Get-Date

    $TotalGerados = 0
    $TotalPulados = 0
    $TotalErros = 0
    $TotalInterrompidos = 0
    $Relatorio = @()

    if (-not $GerarVideosMusicas -and -not $GerarVideoAlbum) {
        Add-Log -LogBox $LogBox -Mensagem "Nenhuma opção de geração foi selecionada."
        return
    }

    $FfmpegPath = Resolve-Executable "ffmpeg.exe"
    if (-not $FfmpegPath) { $FfmpegPath = Resolve-Executable "ffmpeg" }

    $FfprobePath = Resolve-Executable "ffprobe.exe"
    if (-not $FfprobePath) { $FfprobePath = Resolve-Executable "ffprobe" }

    if (-not $FfmpegPath) {
        Add-Log -LogBox $LogBox -Mensagem "ERRO: ffmpeg não encontrado no PATH nem na pasta do aplicativo."
        return
    }

    if (-not $FfprobePath) {
        Add-Log -LogBox $LogBox -Mensagem "ERRO: ffprobe não encontrado no PATH nem na pasta do aplicativo."
        return
    }

    if (-not (Test-SafePath -Path $PastaMP3)) {
        Add-Log -LogBox $LogBox -Mensagem "ERRO: Pasta de MP3 não encontrada: $PastaMP3"
        return
    }

    if (-not (Test-Path -LiteralPath $PastaVideo)) {
        New-Item -ItemType Directory -Path $PastaVideo -Force | Out-Null
    }

    Add-Log -LogBox $LogBox -Mensagem "Modo: $(if ($Detalhado) { 'Detalhado' } else { 'Simples' })"
    Add-Log -LogBox $LogBox -Mensagem "Gerar vídeo de cada música: $(if ($GerarVideosMusicas) { 'Sim' } else { 'Não' })"
    Add-Log -LogBox $LogBox -Mensagem "Gerar vídeo do álbum inteiro: $(if ($GerarVideoAlbum) { 'Sim' } else { 'Não' })"
    Add-Log -LogBox $LogBox -Mensagem "Validação de duração dos existentes: $(if ($ValidarDuracaoExistentes) { 'Sim' } else { 'Não' })"
    Add-Log -LogBox $LogBox -Mensagem "Tolerância fixa: $ToleranciaSegundosFixa segundos"
    Add-Log -LogBox $LogBox -Mensagem "Pasta MP3: $PastaMP3"
    Add-Log -LogBox $LogBox -Mensagem "Pasta VÍDEOS: $PastaVideo"
    Add-Log -LogBox $LogBox -Mensagem ""

    $Subpastas = Get-ChildItem -LiteralPath $PastaMP3 -Directory

    foreach ($Subpasta in $Subpastas) {
        if ($script:CancelarGeracao) { break }

        $SubpastaMP3 = $Subpasta.FullName
        $NomeAlbum = $Subpasta.Name
        $SubpastaVideo = Join-SafePath $PastaVideo $NomeAlbum
        $Capa = Join-SafePath $SubpastaMP3 $NomeCapa

        Add-Log -LogBox $LogBox -Mensagem ""
        Add-Log -LogBox $LogBox -Mensagem "Processando pasta: $NomeAlbum"

        if (-not (Test-Path -LiteralPath $Capa)) {
            Add-Log -LogBox $LogBox -Mensagem "AVISO: Capa não encontrada: $Capa"
            Add-Log -LogBox $LogBox -Mensagem "Pulando esta pasta..."
            continue
        }

        if (-not (Test-Path -LiteralPath $SubpastaVideo)) {
            New-SafeDirectory -Path $SubpastaVideo | Out-Null
            Add-Log -LogBox $LogBox -Mensagem "Pasta criada: $SubpastaVideo"
        }

        $Musicas = Get-AlbumTracks -SubpastaMP3 $SubpastaMP3

        if ($GerarVideosMusicas) {
            foreach ($Musica in $Musicas) {
                if ($script:CancelarGeracao) { break }

                $Resultado = Invoke-SingleTrackVideo `
                    -Musica $Musica `
                    -Capa $Capa `
                    -SubpastaVideo $SubpastaVideo `
                    -SegundosExtras $SegundosExtras `
                    -Detalhado $Detalhado `
                    -ValidarDuracaoExistentes $ValidarDuracaoExistentes `
                    -ToleranciaSegundos $ToleranciaSegundosFixa `
                    -FfmpegPath $FfmpegPath `
                    -FfprobePath $FfprobePath `
                    -LogBox $LogBox `
                    -StatusLabel $StatusLabel

                switch ($Resultado.Status) {
                    "Gerado" { $TotalGerados++ }
                    "Pulado" { $TotalPulados++ }
                    "Erro" { $TotalErros++ }
                    "Interrompido" { $TotalInterrompidos++; $script:CancelarGeracao = $true }
                }

                if ($Resultado.Status -ne "Pulado") {
                    $Relatorio += [PSCustomObject]@{
                        "Nome"        = $Resultado.Nome
                        "Path"        = $Resultado.Path
                        "Tempo Gasto" = $Resultado.Tempo
                    }
                }
            }
        }

        if ($script:CancelarGeracao) { break }

        if ($GerarVideoAlbum) {
            $ResultadoAlbum = Invoke-AlbumVideo `
                -NomeAlbum $NomeAlbum `
                -Musicas $Musicas `
                -Capa $Capa `
                -SubpastaVideo $SubpastaVideo `
                -SilencioEntreFaixas $SilencioEntreFaixas `
                -Detalhado $Detalhado `
                -ValidarDuracaoExistentes $ValidarDuracaoExistentes `
                -ToleranciaSegundos $ToleranciaSegundosFixa `
                -FfmpegPath $FfmpegPath `
                -FfprobePath $FfprobePath `
                -LogBox $LogBox `
                -StatusLabel $StatusLabel

            switch ($ResultadoAlbum.Status) {
                "Gerado" { $TotalGerados++ }
                "Pulado" { $TotalPulados++ }
                "Erro" { $TotalErros++ }
                "Interrompido" { $TotalInterrompidos++; $script:CancelarGeracao = $true }
            }

            if ($ResultadoAlbum.Status -ne "Pulado") {
                $Relatorio += [PSCustomObject]@{
                    "Nome"        = $ResultadoAlbum.Nome
                    "Path"        = $ResultadoAlbum.Path
                    "Tempo Gasto" = $ResultadoAlbum.Tempo
                }
            }
        }
    }

    $FimTotal = Get-Date
    $TempoTotal = $FimTotal - $InicioTotal
    $TempoTotalFormatado = "{0:hh\:mm\:ss}" -f $TempoTotal

    Add-Log -LogBox $LogBox -Mensagem ""
    Add-Log -LogBox $LogBox -Mensagem "============================================"
    Add-Log -LogBox $LogBox -Mensagem "TABELA DE TEMPO"
    Add-Log -LogBox $LogBox -Mensagem "============================================"

    if ($Relatorio.Count -gt 0) {
        foreach ($Item in $Relatorio) {
            $Nome = $Item.Nome
            $Path = $Item.Path
            $Tempo = $Item."Tempo Gasto"
            Add-Log -LogBox $LogBox -Mensagem "$Nome | $Path | $Tempo"
        }
    }
    else {
        Add-Log -LogBox $LogBox -Mensagem "Nenhum vídeo novo foi gerado nesta execução."
    }

    Add-Log -LogBox $LogBox -Mensagem ""
    Add-Log -LogBox $LogBox -Mensagem "Tempo Total Gasto: $TempoTotalFormatado"
    Add-Log -LogBox $LogBox -Mensagem ""
    Add-Log -LogBox $LogBox -Mensagem "============================================"
    Add-Log -LogBox $LogBox -Mensagem "RESUMO FINAL"
    Add-Log -LogBox $LogBox -Mensagem "============================================"
    Add-Log -LogBox $LogBox -Mensagem "Vídeos gerados: $TotalGerados"
    Add-Log -LogBox $LogBox -Mensagem "Vídeos pulados: $TotalPulados"
    Add-Log -LogBox $LogBox -Mensagem "Interrompidos: $TotalInterrompidos"
    Add-Log -LogBox $LogBox -Mensagem "Erros: $TotalErros"
    Add-Log -LogBox $LogBox -Mensagem "Tempo total do processo: $TempoTotalFormatado"

    if ($script:CancelarGeracao) {
        Add-Log -LogBox $LogBox -Mensagem "Processo interrompido."
        $StatusLabel.Text = "Processo interrompido."
    }
    else {
        Add-Log -LogBox $LogBox -Mensagem "Processo finalizado."
        $StatusLabel.Text = "Processo finalizado."
    }

    $StatusLabel.Refresh()
}

function Save-FrezzaProject {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        if ($null -ne $GridMusicas) { [void](Get-SelectedGenerationItems -ListView $GridMusicas) }
        if ($null -ne $GridAlbuns) { [void](Get-SelectedGenerationItems -ListView $GridAlbuns) }
        $ItemStates = @()
        foreach ($I in @($script:ItensEscaneados)) {
            $MusicPath = ""; try { if ($I.MusicFile) { $MusicPath = [string]$I.MusicFile.FullName } } catch { }
            $ItemStates += [PSCustomObject]@{ Type=[string]$I.Type; Album=[string]$I.Album; Name=[string]$I.Name; MusicPath=$MusicPath; CoverPath=[string]$I.CoverPath; Selected=[bool]$I.Selected; Status=[string]$I.Status }
        }
        $Rows = @(); try { $Rows = @(Get-SubtitleRowsFromGrid) } catch { }
        $Data = [PSCustomObject]@{
            Version=1; SavedAt=(Get-Date).ToString('o'); PastaMP3=[string]$TextPastaMP3.Text; PastaVideo=[string]$TextPastaVideo.Text; PastaLegendas=[string]$TextLegPastaLegendas.Text;
            ModoLeitura=[string]$ComboModoLeitura.SelectedItem; GerarMusicas=[bool]$CheckGerarMusicas.Checked; GerarAlbum=[bool]$CheckGerarAlbum.Checked;
            Extra=[double]$NumericExtra.Value; SilencioAlbum=[double]$NumericSilencioEntreFaixas.Value; ValidarDuracao=[bool]$CheckValidarDuracao.Checked;
            Itens=$ItemStates; LegendaSelecionada=$(try { [string]$TextLegArquivoSrt.Text } catch { '' }); LegendaRows=$Rows
        }
        $Data | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding UTF8
        $script:ProjetoAtualPath = $Path
        return $true
    } catch { [System.Windows.Forms.MessageBox]::Show("Falha ao salvar projeto:`n$($_.Exception.Message)","Salvar projeto") | Out-Null; return $false }
}

function Open-FrezzaProject {
    param([string]$Path)
    if (-not (Test-SafePath -Path $Path)) { return $false }
    try {
        $D = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        $TextPastaMP3.Text=[string]$D.PastaMP3; $TextPastaVideo.Text=[string]$D.PastaVideo; $TextPastaLegendas.Text=[string]$D.PastaLegendas; $TextLegPastaLegendas.Text=[string]$D.PastaLegendas
        if ($D.ModoLeitura) { $ComboModoLeitura.SelectedItem=[string]$D.ModoLeitura }
        $CheckGerarMusicas.Checked=[bool]$D.GerarMusicas; $CheckGerarAlbum.Checked=[bool]$D.GerarAlbum
        try { $NumericExtra.Value=[decimal]$D.Extra } catch { }; try { $NumericSilencioEntreFaixas.Value=[decimal]$D.SilencioAlbum } catch { }; try { $CheckValidarDuracao.Checked=[bool]$D.ValidarDuracao } catch { }
        if (Test-SafePath -Path $TextPastaMP3.Text) {
            $script:ItensEscaneados = Scan-GenerationItems -PastaMP3 $TextPastaMP3.Text -PastaVideo $TextPastaVideo.Text -NomeCapa "" -IncluirMusicas $true -IncluirAlbuns $true -ModoLeitura ([string]$ComboModoLeitura.SelectedItem)
            foreach ($I in @($script:ItensEscaneados)) {
                $S = @($D.Itens | Where-Object { [string]$_.Type -eq [string]$I.Type -and [string]$_.Album -eq [string]$I.Album -and [string]$_.Name -eq [string]$I.Name } | Select-Object -First 1)
                if ($S.Count -gt 0) { if (-not [string]::IsNullOrWhiteSpace([string]$S[0].CoverPath) -and (Test-SafePath -Path ([string]$S[0].CoverPath))) { $I.CoverPath=[string]$S[0].CoverPath }; $I.Selected=[bool]$S[0].Selected; $I.Status=[string]$S[0].Status }
            }
            Populate-MediaTabs; Refresh-SubtitleMusicList; Load-SelectedSubtitleInfo
        }
        if ($D.LegendaRows) { try { Fill-SubtitleGrid -Rows @($D.LegendaRows) } catch { } }
        $script:ProjetoAtualPath=$Path; Update-UiState
        return $true
    } catch { [System.Windows.Forms.MessageBox]::Show("Falha ao abrir projeto:`n$($_.Exception.Message)","Abrir projeto") | Out-Null; return $false }
}

# ============================================================
# NOVA INTERFACE: SELEÇÃO NA TELA PRINCIPAL + PROCESSAMENTO EM TELA SEPARADA
# ============================================================

function New-GenerationItem {
    param(
        [string]$Type,
        [string]$Album,
        [string]$Name,
        [System.IO.FileInfo]$MusicFile,
        [System.IO.FileInfo[]]$Tracks,
        [string]$CoverPath,
        [string]$OutputDirectory,
        [string]$OutputPath
    )

    return [PSCustomObject]@{
        Selected        = $true
        Type            = $Type
        Album           = $Album
        Name            = $Name
        MusicFile       = $MusicFile
        Tracks          = $Tracks
        CoverPath       = $CoverPath
        OutputDirectory = $OutputDirectory
        OutputPath      = $OutputPath
        Status          = "Pendente"
    }
}


function Scan-GenerationItems {
    param(
        [string]$PastaMP3,
        [string]$PastaVideo,
        [string]$NomeCapa,
        [bool]$IncluirMusicas,
        [bool]$IncluirAlbuns,
        [string]$ModoLeitura
    )

    if (-not (Test-SafePath -Path $PastaMP3)) {
        throw "Pasta de MP3 não encontrada: $PastaMP3"
    }

    $Itens = New-Object System.Collections.ArrayList

    $UsarRaiz = $false
    $UsarSubpastas = $false

    switch ($ModoLeitura) {
        "Pasta selecionada é um álbum único" {
            $UsarRaiz = $true
            $UsarSubpastas = $false
        }
        "Cada subpasta é um álbum" {
            $UsarRaiz = $false
            $UsarSubpastas = $true
        }
        default {
            $TemMp3NaRaiz = @(Get-ChildItem -LiteralPath $PastaMP3 -Filter "*.mp3" -File -ErrorAction SilentlyContinue).Count -gt 0
            $TemSubpastas = @(Get-ChildItem -LiteralPath $PastaMP3 -Directory -ErrorAction SilentlyContinue).Count -gt 0

            $UsarRaiz = $TemMp3NaRaiz
            $UsarSubpastas = $TemSubpastas
        }
    }

    if ($UsarRaiz) {
        $AlbumName = Split-SafeLeaf -Path ($PastaMP3.TrimEnd('\', '/'))

        Add-AlbumItemsFromFolder `
            -Itens $Itens `
            -AlbumFolder $PastaMP3 `
            -AlbumName $AlbumName `
            -PastaVideo $PastaVideo `
            -NomeCapa $NomeCapa `
            -IncluirMusicas $IncluirMusicas `
            -IncluirAlbuns $IncluirAlbuns
    }

    if ($UsarSubpastas) {
        $Subpastas = Get-ChildItem -LiteralPath $PastaMP3 -Directory

        foreach ($Subpasta in $Subpastas) {
            Add-AlbumItemsFromFolder `
                -Itens $Itens `
                -AlbumFolder $Subpasta.FullName `
                -AlbumName $Subpasta.Name `
                -PastaVideo $PastaVideo `
                -NomeCapa $NomeCapa `
                -IncluirMusicas $IncluirMusicas `
                -IncluirAlbuns $IncluirAlbuns
        }
    }

    $Ordenados = @($Itens | Sort-Object `
        @{ Expression = { if ($_.Type -eq "Álbum") { 0 } else { 1 } } }, `
        @{ Expression = { $_.Album } }, `
        @{ Expression = { $_.Name } })

    return $Ordenados
}


function Select-ImageFile {
    param([string]$InitialPath)

    $Dialog = New-Object System.Windows.Forms.OpenFileDialog
    $Dialog.Title = "Escolher imagem"
    $Dialog.Filter = "Imagens|*.png;*.jpg;*.jpeg;*.webp|PNG|*.png|JPG/JPEG|*.jpg;*.jpeg|WEBP|*.webp|Todos os arquivos|*.*"
    $Dialog.Multiselect = $false

    if (-not [string]::IsNullOrWhiteSpace($InitialPath)) {
        try {
            $Folder = Split-SafeParent -Path $InitialPath

            if (Test-SafePath -Path $Folder) {
                $Dialog.InitialDirectory = $Folder
            }
        }
        catch {
            # Abre sem pasta inicial.
        }
    }

    if ($Dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $Dialog.FileName
    }

    return $null
}

function Validate-SelectedImages {
    param(
        [object[]]$Itens
    )

    $SemImagem = @()

    foreach ($Item in $Itens) {
        if ([string]::IsNullOrWhiteSpace([string]$Item.CoverPath) -or -not (Test-SafePath -Path $Item.CoverPath)) {
            $SemImagem += $Item
        }
    }

    if ($SemImagem.Count -gt 0) {
        $Exemplos = ($SemImagem | Select-Object -First 10 | ForEach-Object { "$($_.Type): $($_.Album) - $($_.Name)" }) -join [Environment]::NewLine

        [System.Windows.Forms.MessageBox]::Show(
            "Não é possível gerar sem imagem escolhida para cada música ou álbum selecionado." + [Environment]::NewLine + [Environment]::NewLine +
            "Itens sem imagem:" + [Environment]::NewLine + $Exemplos,
            "Imagem obrigatória",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null

        return $false
    }

    return $true
}

function Get-ImageDisplayName {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return "SEM IMAGEM"
    }

    try {
        return (Split-Path -Path $Path -Leaf)
    }
    catch {
        return $Path
    }
}

function Fill-ListView {
    param(
        [System.Windows.Forms.DataGridView]$ListView,
        [object[]]$Itens
    )

    $ListView.Rows.Clear()

    foreach ($Item in $Itens) {
        $ImagemTexto = Get-ImageDisplayName -Path $Item.CoverPath

        if ([string]::IsNullOrWhiteSpace([string]$Item.CoverPath)) {
            $Item.Status = "Sem imagem"
        }
        elseif ($Item.Status -eq "Sem imagem") {
            $Item.Status = "Pendente"
        }

        $RowIndex = $ListView.Rows.Add(
            [bool]$Item.Selected,
            $Item.Type,
            $Item.Album,
            $Item.Name,
            $Item.Status,
            "Escolher...",
            $ImagemTexto,
            $Item.OutputPath
        )

        $ListView.Rows[$RowIndex].Tag = $Item

        if ($Item.Type -eq "Álbum") {
            $ListView.Rows[$RowIndex].DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(232, 242, 255)
        }
        else {
            $ListView.Rows[$RowIndex].DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(245, 245, 245)
        }
    }

    $ListView.Refresh()
}

function Update-ItemStatus {
    param(
        [System.Windows.Forms.DataGridView]$ListView,
        [object]$Item,
        [string]$Status
    )

    $Item.Status = $Status

    foreach ($Row in $ListView.Rows) {
        if ($Row.Tag -eq $Item) {
            $Row.Cells["Status"].Value = $Status
            $ListView.Refresh()
            [System.Windows.Forms.Application]::DoEvents()
            break
        }
    }
}

function Update-ItemImageInGrid {
    param(
        [System.Windows.Forms.DataGridView]$ListView,
        [object]$Item
    )

    if ($null -eq $ListView -or $null -eq $Item) { return }

    try {
        if ($ListView -eq $GridMusicas -and -not [string]::IsNullOrWhiteSpace([string]$Item.CoverPath)) {
            if ($null -eq $script:CoverPathByMusicKey) { $script:CoverPathByMusicKey = @{} }
            $MusicPathKey = ""
            try { if ($null -ne $Item.MusicFile) { $MusicPathKey = [string]$Item.MusicFile.FullName } } catch { }
            if (-not [string]::IsNullOrWhiteSpace($MusicPathKey)) { $script:CoverPathByMusicKey["PATH|" + $MusicPathKey.ToLowerInvariant()] = [string]$Item.CoverPath }
            if (-not [string]::IsNullOrWhiteSpace([string]$Item.Album) -and -not [string]::IsNullOrWhiteSpace([string]$Item.Name)) {
                $script:CoverPathByMusicKey["ALBUMNAME|" + ([string]$Item.Album).ToLowerInvariant() + "|" + ([string]$Item.Name).ToLowerInvariant()] = [string]$Item.CoverPath
            }
        }
    } catch { }

    foreach ($Row in $ListView.Rows) {
        if ($Row.Tag -eq $Item) {
            $Row.Cells["ArquivoImagem"].Value = Get-ImageDisplayName -Path $Item.CoverPath

            if ([string]::IsNullOrWhiteSpace([string]$Item.CoverPath)) {
                $Item.Status = "Sem imagem"
                $Row.Cells["Status"].Value = "Sem imagem"
            }
            elseif ($Item.Status -eq "Sem imagem") {
                $Item.Status = "Pendente"
                $Row.Cells["Status"].Value = "Pendente"
            }

            $ListView.Refresh()
            break
        }
    }
}

function Get-SelectedGenerationItems {
    param([System.Windows.Forms.DataGridView]$ListView)

    $Selecionados = @()

    foreach ($Row in $ListView.Rows) {
        $Item = $Row.Tag

        if ($null -eq $Item) {
            continue
        }

        $Checked = $false

        try {
            $Checked = [bool]$Row.Cells["Selecionar"].Value
        }
        catch {
            $Checked = $false
        }

        $Item.Selected = $Checked

        if ($Checked) {
            $Selecionados += $Item
        }
    }

    return $Selecionados
}

function Show-ProcessingForm {
    param([System.Windows.Forms.Form]$MainForm)

    $ProcessingForm = New-Object System.Windows.Forms.Form
    $ProcessingForm.Text = "Processamento - Log e Interrupção"
    $ProcessingForm.Size = New-Object System.Drawing.Size(960, 700)
    $ProcessingForm.StartPosition = "CenterScreen"
    $ProcessingForm.Font = New-Object System.Drawing.Font("Century Gothic", 9)
    $ProcessingForm.MinimumSize = New-Object System.Drawing.Size(860, 600)
	
	Set-FormIcon -TargetForm $ProcessingForm

    $StatusLabelProcessamento = New-Object System.Windows.Forms.Label
    $StatusLabelProcessamento.Text = "Aguardando..."
    $StatusLabelProcessamento.Location = New-Object System.Drawing.Point(20, 20)
    $StatusLabelProcessamento.Size = New-Object System.Drawing.Size(700, 28)
    $StatusLabelProcessamento.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft

    $ButtonInterromperProcessamento = New-Object System.Windows.Forms.Button
    $ButtonInterromperProcessamento.Text = "Interromper"
    $ButtonInterromperProcessamento.Location = New-Object System.Drawing.Point(790, 18)
    $ButtonInterromperProcessamento.Size = New-Object System.Drawing.Size(120, 34)

    $LogBoxProcessamento = New-Object System.Windows.Forms.TextBox
    $LogBoxProcessamento.Multiline = $true
    $LogBoxProcessamento.ScrollBars = "Vertical"
    $LogBoxProcessamento.ReadOnly = $true
    $LogBoxProcessamento.WordWrap = $false
    $LogBoxProcessamento.Font = New-Object System.Drawing.Font("Consolas", 9)
    $LogBoxProcessamento.Location = New-Object System.Drawing.Point(20, 65)
    $LogBoxProcessamento.Size = New-Object System.Drawing.Size(890, 560)
    $LogBoxProcessamento.Anchor = "Top,Bottom,Left,Right"

    $ProcessingForm.Controls.AddRange(@(
        $StatusLabelProcessamento,
        $ButtonInterromperProcessamento,
        $LogBoxProcessamento
    ))

    $ButtonInterromperProcessamento.Add_Click({
        $script:CancelarGeracao = $true

        Add-Log -LogBox $LogBoxProcessamento -Mensagem ""
        Add-Log -LogBox $LogBoxProcessamento -Mensagem "Interrupção solicitada pelo usuário..."

        $StatusLabelProcessamento.Text = "Interrompendo..."
        $StatusLabelProcessamento.Refresh()
        $ButtonInterromperProcessamento.Enabled = $false
    })

    $ProcessingForm.Add_FormClosing({
        if ($script:ProcessoAtual -and -not $script:ProcessoAtual.HasExited) {
            $script:CancelarGeracao = $true

            try {
                $script:ProcessoAtual.Kill()
            }
            catch {
                # O processo pode já ter sido finalizado.
            }
        }
    })

    $MainForm.Hide()
    $ProcessingForm.Show()
    [System.Windows.Forms.Application]::DoEvents()

    return [PSCustomObject]@{
        Form              = $ProcessingForm
        LogBox            = $LogBoxProcessamento
        StatusLabel       = $StatusLabelProcessamento
        ButtonInterromper = $ButtonInterromperProcessamento
    }
}

function Process-GenerationItems {
    param(
        [object[]]$Itens,
        [bool]$GerarVideosMusicas,
        [bool]$GerarVideoAlbum,
        [double]$SegundosExtras,
        [double]$SilencioEntreFaixas,
        [bool]$Detalhado,
        [bool]$ValidarDuracaoExistentes,
        [string]$OutputRoot,
        [System.Windows.Forms.TextBox]$LogBox,
        [System.Windows.Forms.Label]$StatusLabel
    )

    $InicioTotal = Get-Date

    $TotalGerados = 0
    $TotalPulados = 0
    $TotalErros = 0
    $TotalInterrompidos = 0
    $Relatorio = @()

    $FfmpegPath = Resolve-Executable "ffmpeg.exe"
    if (-not $FfmpegPath) { $FfmpegPath = Resolve-Executable "ffmpeg" }

    $FfprobePath = Resolve-Executable "ffprobe.exe"
    if (-not $FfprobePath) { $FfprobePath = Resolve-Executable "ffprobe" }

    if ($GerarVideosMusicas -or $GerarVideoAlbum) {
        if (-not $FfmpegPath) {
            Add-Log -LogBox $LogBox -Mensagem "ERRO: ffmpeg não encontrado no PATH nem na pasta do aplicativo."
            return
        }

        if (-not $FfprobePath) {
            Add-Log -LogBox $LogBox -Mensagem "ERRO: ffprobe não encontrado no PATH nem na pasta do aplicativo."
            return
        }
    }

    if ($GerarVideoAlbum -and -not $FfprobePath) {
        Add-Log -LogBox $LogBox -Mensagem "ERRO: ffprobe não encontrado. Ele é necessário para gerar vídeo de álbum."
        return
    }

    Add-Log -LogBox $LogBox -Mensagem "Itens selecionados: $($Itens.Count)"
    Add-Log -LogBox $LogBox -Mensagem "Gerar vídeo de cada música: $(if ($GerarVideosMusicas) { 'Sim' } else { 'Não' })"
    Add-Log -LogBox $LogBox -Mensagem "Gerar vídeo do álbum inteiro: $(if ($GerarVideoAlbum) { 'Sim' } else { 'Não' })"
    Add-Log -LogBox $LogBox -Mensagem "Validação de duração dos existentes: $(if ($ValidarDuracaoExistentes) { 'Sim' } else { 'Não' })"
    Add-Log -LogBox $LogBox -Mensagem "Tolerância fixa: $ToleranciaSegundosFixa segundos"
    Add-Log -LogBox $LogBox -Mensagem ""

    foreach ($Item in $Itens) {
        if ($script:CancelarGeracao) { break }

        if (($GerarVideosMusicas -or $GerarVideoAlbum) -and -not (Test-SafePath -Path $Item.OutputDirectory)) {
            New-SafeDirectory -Path $Item.OutputDirectory | Out-Null
        }

        Update-ItemStatusInAllGrids -Item $Item -Status "Processando"

        $GerouAlgo = $false

        if ($Item.Type -eq "Música" -and $GerarVideosMusicas) {
            $Resultado = Invoke-SingleTrackVideo `
                -Musica $Item.MusicFile `
                -Capa $Item.CoverPath `
                -SubpastaVideo $Item.OutputDirectory `
                -SegundosExtras $SegundosExtras `
                -Detalhado $Detalhado `
                -ValidarDuracaoExistentes $ValidarDuracaoExistentes `
                -ToleranciaSegundos $ToleranciaSegundosFixa `
                -FfmpegPath $FfmpegPath `
                -FfprobePath $FfprobePath `
                -LogBox $LogBox `
                -StatusLabel $StatusLabel

            $GerouAlgo = $true

            switch ($Resultado.Status) {
                "Gerado" {
                    $TotalGerados++
                    Update-ItemStatusInAllGrids -Item $Item -Status "Vídeo concluído"
                }
                "Pulado" {
                    $TotalPulados++
                    Update-ItemStatusInAllGrids -Item $Item -Status "Vídeo pulado"
                }
                "Erro" {
                    $TotalErros++
                    Update-ItemStatusInAllGrids -Item $Item -Status "Erro"
                }
                "Interrompido" {
                    $TotalInterrompidos++
                    Update-ItemStatusInAllGrids -Item $Item -Status "Interrompido"
                    $script:CancelarGeracao = $true
                }
            }

            if ($Resultado.Status -ne "Pulado") {
                $Relatorio += [PSCustomObject]@{
                    "Nome"        = $Resultado.Nome
                    "Path"        = $Resultado.Path
                    "Tempo Gasto" = $Resultado.Tempo
                }
            }
        }

        if ($script:CancelarGeracao) { break }

        if ($Item.Type -eq "Álbum" -and $GerarVideoAlbum) {
            $Resultado = Invoke-AlbumVideo `
                -NomeAlbum $Item.Album `
                -Musicas $Item.Tracks `
                -Capa $Item.CoverPath `
                -SubpastaVideo $Item.OutputDirectory `
                -SilencioEntreFaixas $SilencioEntreFaixas `
                -Detalhado $Detalhado `
                -ValidarDuracaoExistentes $ValidarDuracaoExistentes `
                -ToleranciaSegundos $ToleranciaSegundosFixa `
                -FfmpegPath $FfmpegPath `
                -FfprobePath $FfprobePath `
                -LogBox $LogBox `
                -StatusLabel $StatusLabel

            $GerouAlgo = $true

            switch ($Resultado.Status) {
                "Gerado" {
                    $TotalGerados++
                    Update-ItemStatusInAllGrids -Item $Item -Status "Vídeo concluído"
                }
                "Pulado" {
                    $TotalPulados++
                    Update-ItemStatusInAllGrids -Item $Item -Status "Vídeo pulado"
                }
                "Erro" {
                    $TotalErros++
                    Update-ItemStatusInAllGrids -Item $Item -Status "Erro"
                }
                "Interrompido" {
                    $TotalInterrompidos++
                    Update-ItemStatusInAllGrids -Item $Item -Status "Interrompido"
                    $script:CancelarGeracao = $true
                }
            }

            if ($Resultado.Status -ne "Pulado") {
                $Relatorio += [PSCustomObject]@{
                    "Nome"        = $Resultado.Nome
                    "Path"        = $Resultado.Path
                    "Tempo Gasto" = $Resultado.Tempo
                }
            }
        }

        if ($script:CancelarGeracao) { break }
        if (-not $GerouAlgo) {
            Update-ItemStatusInAllGrids -Item $Item -Status "Ignorado"
        }
    }

    $FimTotal = Get-Date
    $TempoTotal = $FimTotal - $InicioTotal
    $TempoTotalFormatado = "{0:hh\:mm\:ss}" -f $TempoTotal

    Add-Log -LogBox $LogBox -Mensagem ""
    Add-Log -LogBox $LogBox -Mensagem "============================================"
    Add-Log -LogBox $LogBox -Mensagem "TABELA DE TEMPO"
    Add-Log -LogBox $LogBox -Mensagem "============================================"

    if ($Relatorio.Count -gt 0) {
        foreach ($Item in $Relatorio) {
            $Nome = $Item.Nome
            $Path = $Item.Path
            $Tempo = $Item."Tempo Gasto"
            Add-Log -LogBox $LogBox -Mensagem "$Nome | $Path | $Tempo"
        }
    }
    else {
        Add-Log -LogBox $LogBox -Mensagem "Nenhum arquivo novo foi gerado nesta execução."
    }

    Add-Log -LogBox $LogBox -Mensagem ""
    Add-Log -LogBox $LogBox -Mensagem "Tempo Total Gasto: $TempoTotalFormatado"
    Add-Log -LogBox $LogBox -Mensagem ""
    Add-Log -LogBox $LogBox -Mensagem "============================================"
    Add-Log -LogBox $LogBox -Mensagem "RESUMO FINAL"
    Add-Log -LogBox $LogBox -Mensagem "============================================"
    Add-Log -LogBox $LogBox -Mensagem "Vídeos gerados: $TotalGerados"
    Add-Log -LogBox $LogBox -Mensagem "Arquivos pulados: $TotalPulados"
    Add-Log -LogBox $LogBox -Mensagem "Interrompidos: $TotalInterrompidos"
    Add-Log -LogBox $LogBox -Mensagem "Erros: $TotalErros"
    Add-Log -LogBox $LogBox -Mensagem "Tempo total do processo: $TempoTotalFormatado"

    $ReportPath = Write-GenerationReport `
        -OutputRoot $OutputRoot `
        -Relatorio $Relatorio `
        -TotalGerados $TotalGerados `
        -TotalPulados $TotalPulados `
        -TotalErros $TotalErros `
        -TotalInterrompidos $TotalInterrompidos `
        -TempoTotalFormatado $TempoTotalFormatado

    if ($ReportPath) {
        Add-Log -LogBox $LogBox -Mensagem "Relatório salvo em: $ReportPath"
    }

    if ($script:CancelarGeracao) {
        Add-Log -LogBox $LogBox -Mensagem "Processo interrompido."
        $StatusLabel.Text = "Processo interrompido."
    }
    else {
        Add-Log -LogBox $LogBox -Mensagem "Processo finalizado."
        $StatusLabel.Text = "Processo finalizado."
    }

    $StatusLabel.Refresh()
}



function Update-AutoOutputFromInput {
    $AutoPath = Get-AutoOutputPath -PastaMP3 $TextPastaMP3.Text

    if (-not [string]::IsNullOrWhiteSpace($AutoPath)) {
        $TextPastaVideo.Text = $AutoPath
    }

    $AutoSubtitlePath = Get-AutoSubtitlePath -PastaMP3 $TextPastaMP3.Text

    if ($null -ne $TextPastaLegendas -and -not [string]::IsNullOrWhiteSpace($AutoSubtitlePath)) {
        $TextPastaLegendas.Text = $AutoSubtitlePath
    }
}

function Validate-MainPaths {
    if ([string]::IsNullOrWhiteSpace($TextPastaMP3.Text)) {
        [System.Windows.Forms.MessageBox]::Show(
            "Informe a pasta de MP3.",
            "Validação",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null

        return $false
    }

    if (-not (Test-SafePath -Path $TextPastaMP3.Text)) {
        [System.Windows.Forms.MessageBox]::Show(
            "A pasta de MP3 informada não existe.",
            "Validação",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null

        return $false
    }

    Update-AutoOutputFromInput

    if ([string]::IsNullOrWhiteSpace($TextPastaVideo.Text)) {
        [System.Windows.Forms.MessageBox]::Show(
            "Não foi possível calcular automaticamente a pasta de saída.",
            "Validação",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null

        return $false
    }
    return $true
}


function New-MediaGrid {
    $Grid = New-Object System.Windows.Forms.DataGridView
    $Grid.AllowUserToAddRows = $false
    $Grid.AllowUserToDeleteRows = $false
    $Grid.AllowUserToResizeRows = $false
    $Grid.MultiSelect = $false
    $Grid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $Grid.AutoSizeRowsMode = [System.Windows.Forms.DataGridViewAutoSizeRowsMode]::None
    $Grid.RowHeadersVisible = $false
    $Grid.Anchor = "Top,Bottom,Left,Right"

    $ColSelecionar = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $ColSelecionar.Name = "Selecionar"
    $ColSelecionar.HeaderText = ""
    $ColSelecionar.Width = 35
    $Grid.Columns.Add($ColSelecionar) | Out-Null

    $ColTipo = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $ColTipo.Name = "Tipo"
    $ColTipo.HeaderText = "Tipo"
    $ColTipo.Width = 75
    $ColTipo.ReadOnly = $true
    $Grid.Columns.Add($ColTipo) | Out-Null

    $ColAlbum = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $ColAlbum.Name = "Album"
    $ColAlbum.HeaderText = "Álbum"
    $ColAlbum.Width = 165
    $ColAlbum.ReadOnly = $true
    $Grid.Columns.Add($ColAlbum) | Out-Null

    $ColNome = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $ColNome.Name = "Nome"
    $ColNome.HeaderText = "Nome"
    $ColNome.Width = 280
    $ColNome.ReadOnly = $true
    $Grid.Columns.Add($ColNome) | Out-Null

    $ColStatus = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $ColStatus.Name = "Status"
    $ColStatus.HeaderText = "Status"
    $ColStatus.Width = 110
    $ColStatus.ReadOnly = $true
    $Grid.Columns.Add($ColStatus) | Out-Null

    $ColImagem = New-Object System.Windows.Forms.DataGridViewButtonColumn
    $ColImagem.Name = "Imagem"
    $ColImagem.HeaderText = "Imagem"
    $ColImagem.Text = "Escolher..."
    $ColImagem.UseColumnTextForButtonValue = $true
    $ColImagem.Width = 95
    $Grid.Columns.Add($ColImagem) | Out-Null

    $ColArquivoImagem = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $ColArquivoImagem.Name = "ArquivoImagem"
    $ColArquivoImagem.HeaderText = "Arquivo da imagem"
    $ColArquivoImagem.Width = 180
    $ColArquivoImagem.ReadOnly = $true
    $Grid.Columns.Add($ColArquivoImagem) | Out-Null

    $ColDestino = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $ColDestino.Name = "Destino"
    $ColDestino.HeaderText = "Destino"
    $ColDestino.Width = 250
    $ColDestino.ReadOnly = $true
    $Grid.Columns.Add($ColDestino) | Out-Null

    return $Grid
}

function Populate-MediaTabs {
    $ItensMusica = @($script:ItensEscaneados | Where-Object { $_.Type -eq "Música" })
    $ItensAlbum = @($script:ItensEscaneados | Where-Object { $_.Type -eq "Álbum" })

    Fill-ListView -ListView $GridMusicas -Itens $ItensMusica
    Fill-ListView -ListView $GridAlbuns -Itens $ItensAlbum

    $script:ItemImagemParaReplicar = $null
    $ButtonReplicarImagemAlbum.Enabled = $false
}

function Get-AllSelectedItems {
    $SelecionadosAlbuns = @()
    $SelecionadosMusicas = @()

    if ($null -ne $GridAlbuns) {
        $SelecionadosAlbuns = @(Get-SelectedGenerationItems -ListView $GridAlbuns)
    }

    if ($null -ne $GridMusicas) {
        $SelecionadosMusicas = @(Get-SelectedGenerationItems -ListView $GridMusicas)
    }

    return @($SelecionadosAlbuns + $SelecionadosMusicas)
}

function Set-GridSelectionAll {
    param(
        [System.Windows.Forms.DataGridView]$Grid,
        [bool]$Value
    )

    foreach ($Row in $Grid.Rows) {
        $Row.Cells["Selecionar"].Value = $Value
        if ($Row.Tag) { $Row.Tag.Selected = $Value }
    }
}

function Set-GridSelectionPendentes {
    param([System.Windows.Forms.DataGridView]$Grid)

    foreach ($Row in $Grid.Rows) {
        $IsPendente = ($Row.Cells["Status"].Value -eq "Pendente" -or $Row.Cells["Status"].Value -eq "Sem imagem")
        $Row.Cells["Selecionar"].Value = $IsPendente
        if ($Row.Tag) { $Row.Tag.Selected = $IsPendente }
    }
}

function Update-ItemStatusInAllGrids {
    param(
        [object]$Item,
        [string]$Status
    )

    if ($null -ne $GridMusicas) {
        Update-ItemStatus -ListView $GridMusicas -Item $Item -Status $Status
    }

    if ($null -ne $GridAlbuns) {
        Update-ItemStatus -ListView $GridAlbuns -Item $Item -Status $Status
    }
}

function Sync-AlbumImageFromMusicItems {
    param([string]$AlbumNome)

    if ([string]::IsNullOrWhiteSpace($AlbumNome)) {
        return
    }

    $AlbumItem = $script:ItensEscaneados | Where-Object { $_.Type -eq "Álbum" -and $_.Album -eq $AlbumNome } | Select-Object -First 1
    $MusicItem = $script:ItensEscaneados | Where-Object { $_.Type -eq "Música" -and $_.Album -eq $AlbumNome -and -not [string]::IsNullOrWhiteSpace([string]$_.CoverPath) } | Select-Object -First 1

    if ($AlbumItem -and $MusicItem) {
        $AlbumItem.CoverPath = $MusicItem.CoverPath

        if ($null -ne $GridAlbuns) {
            Update-ItemImageInGrid -ListView $GridAlbuns -Item $AlbumItem
        }
    }
}

function Hide-CoverHoverPreview {
    try { if ($null -ne $script:CoverPreviewForm) { $script:CoverPreviewForm.Hide() } } catch { }
}
function Show-CoverHoverPreview {
    param([string]$Path, [System.Drawing.Point]$ScreenPoint)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-SafePath -Path $Path)) { Hide-CoverHoverPreview; return }
    try {
        if ($null -eq $script:CoverPreviewForm) {
            $F=New-Object System.Windows.Forms.Form; $F.FormBorderStyle=[System.Windows.Forms.FormBorderStyle]::FixedSingle; $F.ShowInTaskbar=$false; $F.TopMost=$true; $F.StartPosition='Manual'; $F.ClientSize=New-Object System.Drawing.Size(280,280)
            $P=New-Object System.Windows.Forms.PictureBox; $P.Dock='Fill'; $P.SizeMode=[System.Windows.Forms.PictureBoxSizeMode]::Zoom; $F.Controls.Add($P); $script:CoverPreviewForm=$F; $script:CoverPreviewPicture=$P
        }
        if($script:CoverPreviewPicture.Image){ $Old=$script:CoverPreviewPicture.Image; $script:CoverPreviewPicture.Image=$null; $Old.Dispose() }
        $Bytes=[System.IO.File]::ReadAllBytes($Path); $Ms=New-Object System.IO.MemoryStream(,$Bytes); $Img=[System.Drawing.Image]::FromStream($Ms); $script:CoverPreviewPicture.Image=New-Object System.Drawing.Bitmap($Img); $Img.Dispose(); $Ms.Dispose()
        $script:CoverPreviewForm.Location=New-Object System.Drawing.Point(($ScreenPoint.X+18),($ScreenPoint.Y+18)); $script:CoverPreviewForm.Show(); $script:CoverPreviewForm.BringToFront()
    } catch { Hide-CoverHoverPreview }
}

function Wire-GridBasicEvents {
    param([System.Windows.Forms.DataGridView]$Grid)

    $Grid.Add_CurrentCellDirtyStateChanged({
        if ($Grid.IsCurrentCellDirty) {
            $Grid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
        }
    })

    $Grid.Add_CellValueChanged({
        Update-UiState
    })
}

function Update-UiState {
    $TemOpcaoGeracao = $CheckGerarMusicas.Checked -or $CheckGerarAlbum.Checked
    $TemMusicasSelecionadas = $false
    $TemAlbunsSelecionados = $false

    if ($null -ne $GridMusicas) {
        foreach ($Row in $GridMusicas.Rows) {
            try {
                if ([bool]$Row.Cells["Selecionar"].Value) {
                    $TemMusicasSelecionadas = $true
                    break
                }
            }
            catch { }
        }
    }

    if ($null -ne $GridAlbuns) {
        foreach ($Row in $GridAlbuns.Rows) {
            try {
                if ([bool]$Row.Cells["Selecionar"].Value) {
                    $TemAlbunsSelecionados = $true
                    break
                }
            }
            catch { }
        }
    }

    # Escanear não depende das opções de geração: serve apenas para listar músicas e álbuns.
    $ButtonEscanear.Enabled = $true

    $TemItemSelecionadoParaGeracao = (($CheckGerarMusicas.Checked -and $TemMusicasSelecionadas) -or ($CheckGerarAlbum.Checked -and $TemAlbunsSelecionados))
    $ButtonGerarTodos.Enabled = ($TemOpcaoGeracao -and $TemItemSelecionadoParaGeracao)
    $ButtonGerarSelecionadosMusicas.Enabled = ($CheckGerarMusicas.Checked -and $TemMusicasSelecionadas)
    $ButtonGerarSelecionadosAlbuns.Enabled = ($CheckGerarAlbum.Checked -and $TemAlbunsSelecionados)
    $NumericExtra.Enabled = $CheckGerarMusicas.Checked
    $NumericSilencioEntreFaixas.Enabled = $CheckGerarAlbum.Checked
    $TextPastaLegendas.Enabled = $true
    $ButtonPastaLegendas.Enabled = $true
    $ButtonReplicarImagemAlbum.Enabled = $false
}


# ============================================================
# PUBLICAÇÃO NO YOUTUBE
# ============================================================

$script:ItensPublicacao = @()
$script:BurnedSubtitleStyle = [PSCustomObject]@{
    FontName = "Century Gothic"
    FontSize = 90
    Position = "Inferior"
    MarginV = 0
    FontColor = [System.Drawing.Color]::White
    ShadowColor = [System.Drawing.Color]::Black
    ShadowIntensity = 100
    ShadowSpread = 4
    ShowTrackTitle = $true
    TrackTitle = ""
    CustomX = $null
    CustomY = $null
}

$script:UltimosMetadadosPublicacao = $null
$script:YoutubePlaylists = @()
$script:YoutubeTokenPath = Join-SafePath $script:AppRoot "youtube_token.json"
$script:YoutubeConfigPath = Join-SafePath $script:AppRoot "youtube_config.json"

function Get-GeneratedVideosMetadataFolder {
    $Folder = Join-SafePath $script:AppRoot "videos_gerados"

    if (-not (Test-SafePath -Path $Folder)) {
        New-SafeDirectory -Path $Folder | Out-Null
    }

    return $Folder
}

function Get-SafeMetadataFileNameFromVideoPath {
    param([string]$VideoPath)

    if ([string]::IsNullOrWhiteSpace($VideoPath)) {
        return ""
    }

    $HashProvider = [System.Security.Cryptography.SHA256]::Create()

    try {
        $Bytes = [System.Text.Encoding]::UTF8.GetBytes($VideoPath.ToLowerInvariant())
        $HashBytes = $HashProvider.ComputeHash($Bytes)
        $Hash = ([System.BitConverter]::ToString($HashBytes)).Replace("-", "").Substring(0, 16)

        $BaseName = [System.IO.Path]::GetFileNameWithoutExtension($VideoPath)
        $SafeBaseName = $BaseName -replace '[\\/:*?"<>|]', '_'

        return "$SafeBaseName-$Hash.youtube.json"
    }
    finally {
        if ($HashProvider) {
            $HashProvider.Dispose()
        }
    }
}

function Get-AlbumPublishMetadataPath {
    param([string]$VideoPath)

    $Folder = Get-GeneratedVideosMetadataFolder
    $FileName = Get-SafeMetadataFileNameFromVideoPath -VideoPath $VideoPath

    if ([string]::IsNullOrWhiteSpace($FileName)) {
        return ""
    }

    return (Join-SafePath $Folder $FileName)
}

function Save-AlbumPublishMetadataForVideo {
    param(
        [string]$VideoPath,
        [string]$AlbumName,
        [System.IO.FileInfo[]]$Musicas,
        [double[]]$Duracoes,
        [double]$SilencioEntreFaixas
    )

    if ([string]::IsNullOrWhiteSpace($VideoPath)) {
        return
    }

    if ($null -eq $Musicas -or $Musicas.Count -eq 0) {
        return
    }

    if ($null -eq $Duracoes -or $Duracoes.Count -ne $Musicas.Count) {
        return
    }

    $AlbumNameClean = Get-CleanAlbumName -NomeAlbum $AlbumName

    $Description = New-AlbumTimestampDescription `
        -Musicas $Musicas `
        -Duracoes $Duracoes `
        -SilencioEntreFaixas $SilencioEntreFaixas

    $Tracks = @()
    $CurrentTime = 0.0

    for ($i = 0; $i -lt $Musicas.Count; $i++) {
        $Tracks += [PSCustomObject]@{
            index      = ($i + 1)
            timestamp  = (Format-YouTubeTimestamp -Seconds $CurrentTime)
            title      = (Get-CleanTrackTitle -Title $Musicas[$i].BaseName)
            file       = [string]$Musicas[$i].FullName
            duration   = [double]$Duracoes[$i]
            start_time = [double]$CurrentTime
        }

        $CurrentTime += [double]$Duracoes[$i]

        if ($i -lt ($Musicas.Count - 1)) {
            $CurrentTime += [double]$SilencioEntreFaixas
        }
    }

    $Metadata = [PSCustomObject]@{
        type                   = "album"
        video_path             = [string]$VideoPath
        video_file             = [System.IO.Path]::GetFileName($VideoPath)
        title                  = "Álbum Completo - $AlbumNameClean"
        album                  = $AlbumNameClean
        description            = $Description
        silence_between_tracks = [double]$SilencioEntreFaixas
        total_duration_seconds = [double]$CurrentTime
        created_at             = (Get-Date).ToString("o")
        tracks                 = $Tracks
    }

    $Path = Get-AlbumPublishMetadataPath -VideoPath $VideoPath

    try {
        $Metadata |
            ConvertTo-Json -Depth 10 |
            Set-Content -LiteralPath $Path -Encoding UTF8
    }
    catch {
        # Não impede a geração do vídeo.
    }
}

function Load-AlbumPublishMetadataForVideo {
    param([string]$VideoPath)

    $Path = Get-AlbumPublishMetadataPath -VideoPath $VideoPath

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-SafePath -Path $Path)) {
        return $null
    }

    try {
        $Raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8

        if ([string]::IsNullOrWhiteSpace($Raw)) {
            return $null
        }

        return ($Raw | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Get-PublishHistoryPath {
    return (Join-SafePath $script:AppRoot "publicacao_historico.json")
}

function Get-PublishQueuePath {
    return (Join-SafePath $script:AppRoot "publicacao_fila.json")
}

function Get-YoutubeConfigPath {
    if ([string]::IsNullOrWhiteSpace($script:YoutubeConfigPath)) {
        $script:YoutubeConfigPath = Join-SafePath $script:AppRoot "youtube_config.json"
    }

    return $script:YoutubeConfigPath
}

function Load-PublishHistory {
    $Path = Get-PublishHistoryPath
    if (-not (Test-SafePath -Path $Path)) { return @() }
    try {
        $Raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($Raw)) { return @() }
        return @($Raw | ConvertFrom-Json)
    }
    catch { return @() }
}

function Save-PublishHistory {
    param([object[]]$Historico)
    try { $Historico | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Get-PublishHistoryPath) -Encoding UTF8 } catch { }
}

function Add-PublishHistoryItem {
    param([object]$Item, [string]$YoutubeId, [string]$Status, [string]$Erro = "")
    $Historico = @(Load-PublishHistory)
    $Historico += [PSCustomObject]@{
        Data      = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Arquivo   = [string]$Item.FilePath
        Titulo    = [string]$Item.Title
        YoutubeId = $YoutubeId
        Link      = $(if ([string]::IsNullOrWhiteSpace($YoutubeId)) { "" } else { "https://www.youtube.com/watch?v=$YoutubeId" })
        Status    = $Status
        Erro      = $Erro
    }
    Save-PublishHistory -Historico $Historico
}


function Ensure-PublishSubtitleProperties {
    param([object]$Item)
    if ($null -eq $Item) { return }
    foreach ($Spec in @(
        @{N="SubtitleMode";V="Nenhuma"},
        @{N="AttachAllSrt";V=$true},
        @{N="BurnedVideoPath";V=""},
        @{N="CaptionLanguages";V=""}
    )) {
        try {
            if ($null -eq ($Item.PSObject.Properties[$Spec.N])) {
                $Item | Add-Member -NotePropertyName $Spec.N -NotePropertyValue $Spec.V -Force
            }
        } catch { }
    }
}

function Get-DefaultSubtitleLanguageCode {
    # Fallback apenas para SRTs sem código de idioma no nome.
    return "en"
}

function Get-SubtitleLanguageCodeForFileName {
    param([object]$Item)
    return (Get-DefaultSubtitleLanguageCode)
}

function Get-LegacySubtitleSrtPathForItem {
    param([object]$Item)
    if ($null -eq $Item) { return "" }
    $Root = [string]$TextLegPastaLegendas.Text
    if ([string]::IsNullOrWhiteSpace($Root)) { return "" }
    $Dir = Join-SafePath $Root ([string]$Item.Album)
    return (Join-SafePath $Dir (([string]$Item.BaseName) + ".srt"))
}

function Get-PublishVideoBaseNameForSubtitleLookup {
    param([object]$Item)
    $Base = ""
    try { $Base = [System.IO.Path]::GetFileNameWithoutExtension([string]$Item.FilePath) } catch { }
    if ([string]::IsNullOrWhiteSpace($Base)) { return "" }
    $Base = $Base -replace '\s+-\s+legendado$', ''
    $Base = $Base -replace '\s+-\s+Legendado$', ''
    return $Base
}

function Get-PublishSubtitleDirectories {
    param([object]$Item)
    $Dirs = New-Object System.Collections.Generic.List[string]
    $Album = ""
    try { $Album = Split-SafeLeaf -Path (Split-SafeParent -Path ([string]$Item.FilePath)) } catch { }

    foreach ($Root in @(
        $(try { [string]$TextLegPastaLegendas.Text } catch { "" }),
        $(try { Get-AutoSubtitlePath -PastaMP3 ([string]$TextPastaMP3.Text) } catch { "" })
    )) {
        if (-not [string]::IsNullOrWhiteSpace($Root)) {
            foreach ($Candidate in @($Root, (Join-SafePath $Root $Album))) {
                if (-not [string]::IsNullOrWhiteSpace($Candidate) -and (Test-SafePath -Path $Candidate) -and -not $Dirs.Contains($Candidate)) { $Dirs.Add($Candidate) }
            }
        }
    }

    try {
        $VideoDir = Split-SafeParent -Path ([string]$Item.FilePath)
        if (-not [string]::IsNullOrWhiteSpace($VideoDir)) {
            $Derived = $VideoDir -replace [regex]::Escape("\VÍDEOS\"), "\LEGENDAS\"
            $Derived = $Derived -replace [regex]::Escape("\VIDEOS\"), "\LEGENDAS\"
            foreach ($Candidate in @($Derived)) {
                if (-not [string]::IsNullOrWhiteSpace($Candidate) -and (Test-SafePath -Path $Candidate) -and -not $Dirs.Contains($Candidate)) { $Dirs.Add($Candidate) }
            }
        }
    } catch { }

    return @($Dirs)
}

function Get-LanguageCodeFromSrtPath {
    param([string]$Path)
    $Default = Get-DefaultSubtitleLanguageCode
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Default }
    $Base = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $Candidate = ""
    if ($Base -match '\.([a-z]{2}(?:-[A-Za-z]{2})?)$') { $Candidate = $Matches[1] }
    elseif ($Base -match '\[([a-z]{2}(?:-[A-Za-z]{2})?)\]$') { $Candidate = $Matches[1] }
    if ([string]::IsNullOrWhiteSpace($Candidate)) { return $Default }
    return $Candidate
}

function Get-CaptionDisplayNameFromLanguage {
    param([string]$LanguageCode)
    switch -Regex ($LanguageCode) {
        '^pt-BR$' { return 'Português (Brasil)' }
        '^pt' { return 'Português' }
        '^en' { return 'English' }
        '^es' { return 'Español' }
        '^ru' { return 'Русский' }
        '^fr' { return 'Français' }
        '^it' { return 'Italiano' }
        '^de' { return 'Deutsch' }
        default { return $LanguageCode }
    }
}

function Find-SrtFilesForPublishItem {
    param([object]$Item)
    if ($null -eq $Item) { return @() }
    $Base = Get-PublishVideoBaseNameForSubtitleLookup -Item $Item
    if ([string]::IsNullOrWhiteSpace($Base)) { return @() }
    $Found = New-Object System.Collections.Generic.List[object]
    foreach ($Dir in @(Get-PublishSubtitleDirectories -Item $Item)) {
        foreach ($Pattern in @(("{0}.srt" -f $Base), ("{0}.*.srt" -f $Base), ("{0} [*.srt" -f $Base))) {
            foreach ($File in @(Get-ChildItem -LiteralPath $Dir -File -Filter $Pattern -ErrorAction SilentlyContinue | Sort-Object Name)) {
                if ($Found | Where-Object { $_.Path -eq $File.FullName }) { continue }
                $Lang = Get-LanguageCodeFromSrtPath -Path $File.FullName
                $Found.Add([PSCustomObject]@{ Path=[string]$File.FullName; Language=[string]$Lang; Name=(Get-CaptionDisplayNameFromLanguage -LanguageCode $Lang) }) | Out-Null
            }
        }
    }
    return @($Found)
}

function Get-PrimarySrtInfoForPublishItem {
    param([object]$Item)
    $SrtFiles = @(Find-SrtFilesForPublishItem -Item $Item)
    if ($SrtFiles.Count -eq 0) { return $null }
    $Preferred = Get-DefaultSubtitleLanguageCode
    $Match = $SrtFiles | Where-Object { $_.Language -ieq $Preferred } | Select-Object -First 1
    if ($null -ne $Match) { return $Match }
    return $SrtFiles[0]
}

function Update-PublishItemSubtitleSummary {
    param([object]$Item)
    if ($null -eq $Item) { return }
    Ensure-PublishSubtitleProperties -Item $Item
    try {
        $Srts = @(Find-SrtFilesForPublishItem -Item $Item)
        $Item.CaptionLanguages = (($Srts | ForEach-Object { [string]$_.Language } | Select-Object -Unique) -join ', ')
    } catch { }
}

function Upload-YoutubeCaptionTrack {
    param(
        [string]$VideoId,
        [string]$SrtPath,
        [string]$LanguageCode,
        [string]$CaptionName,
        [System.Windows.Forms.TextBox]$LogBox
    )
    if ([string]::IsNullOrWhiteSpace($VideoId)) { throw "VideoId não informado para upload de legenda." }
    if (-not (Test-SafePath -Path $SrtPath)) { throw "Arquivo SRT não encontrado: $SrtPath" }
    if ([string]::IsNullOrWhiteSpace($LanguageCode)) { $LanguageCode = Get-LanguageCodeFromSrtPath -Path $SrtPath }
    if ([string]::IsNullOrWhiteSpace($CaptionName)) { $CaptionName = Get-CaptionDisplayNameFromLanguage -LanguageCode $LanguageCode }

    $AccessToken = Refresh-YoutubeAccessToken
    $Boundary = "frezza_caption_" + [System.Guid]::NewGuid().ToString("N")
    $Metadata = [PSCustomObject]@{
        snippet = [PSCustomObject]@{
            videoId  = $VideoId
            language = $LanguageCode
            name     = $CaptionName
            isDraft  = $false
        }
    } | ConvertTo-Json -Depth 10

    $Header1 = "--$Boundary`r`nContent-Type: application/json; charset=UTF-8`r`n`r`n$Metadata`r`n"
    $Header2 = "--$Boundary`r`nContent-Type: application/octet-stream`r`n`r`n"
    $Footer  = "`r`n--$Boundary--`r`n"
    $Utf8 = [System.Text.Encoding]::UTF8
    $Bytes1 = $Utf8.GetBytes($Header1)
    $Bytes2 = $Utf8.GetBytes($Header2)
    $SrtBytes = [System.IO.File]::ReadAllBytes($SrtPath)
    $Bytes3 = $Utf8.GetBytes($Footer)
    $Body = New-Object byte[] ($Bytes1.Length + $Bytes2.Length + $SrtBytes.Length + $Bytes3.Length)
    [System.Buffer]::BlockCopy($Bytes1,0,$Body,0,$Bytes1.Length)
    [System.Buffer]::BlockCopy($Bytes2,0,$Body,$Bytes1.Length,$Bytes2.Length)
    [System.Buffer]::BlockCopy($SrtBytes,0,$Body,$Bytes1.Length+$Bytes2.Length,$SrtBytes.Length)
    [System.Buffer]::BlockCopy($Bytes3,0,$Body,$Bytes1.Length+$Bytes2.Length+$SrtBytes.Length,$Bytes3.Length)

    Add-Log -LogBox $LogBox -Mensagem ("Enviando legenda anexada: {0} ({1})" -f (Split-SafeLeaf -Path $SrtPath), $LanguageCode)
    Invoke-RestMethod -Method Post -Uri "https://www.googleapis.com/upload/youtube/v3/captions?part=snippet&uploadType=multipart" -Headers @{ Authorization="Bearer $AccessToken" } -Body $Body -ContentType "multipart/related; boundary=$Boundary" | Out-Null
}

function New-BurnedVideoForPublishItem {
    param([object]$Item, [System.Windows.Forms.TextBox]$LogBox, [System.Windows.Forms.Label]$StatusLabel)
    $SrtInfo = Get-PrimarySrtInfoForPublishItem -Item $Item
    if ($null -eq $SrtInfo) { throw "Nenhum SRT encontrado para embutir no vídeo: $($Item.FileName)" }
    $Rows = @(Read-SrtFileRows -Path ([string]$SrtInfo.Path))
    if ($Rows.Count -eq 0) { throw "SRT sem blocos legíveis: $($SrtInfo.Path)" }
    $InputVideo = [string]$Item.FilePath
    $OutputPath = [string]$Item.BurnedVideoPath
    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $Dir = Split-SafeParent -Path $InputVideo
        $Base = [System.IO.Path]::GetFileNameWithoutExtension($InputVideo)
        if ($Base -notmatch '\s+-\s+legendado$') { $Base = $Base + " - legendado" }
        $OutputPath = Join-SafePath $Dir ($Base + ".mp4")
    }
    $Style = $script:BurnedSubtitleStyle
    Add-Log -LogBox $LogBox -Mensagem "Gerando MP4 com legenda embutida para publicação..."
    $Ok = Invoke-BurnSubtitlesIntoVideo `
        -VideoPath $InputVideo `
        -Rows $Rows `
        -OutputPath $OutputPath `
        -FontName ([string]$Style.FontName) `
        -FontSize ([int]$Style.FontSize) `
        -Position ([string]$Style.Position) `
        -MarginV ([int]$Style.MarginV) `
        -FontColor $Style.FontColor `
        -ShadowColor $Style.ShadowColor `
        -ShadowIntensity ([int]$Style.ShadowIntensity) `
        -ShadowSpread ([int]$Style.ShadowSpread) `
        -CustomX $Style.CustomX `
        -CustomY $Style.CustomY `
        -StatusLabel $StatusLabel `
        -LogBox $LogBox
    if (-not $Ok) { throw "Não foi possível gerar o vídeo com legenda embutida." }
    $Item.BurnedVideoPath = $OutputPath
    return $OutputPath
}

function Get-UploadItemForSubtitleMode {
    param([object]$Item, [System.Windows.Forms.TextBox]$LogBox, [System.Windows.Forms.Label]$StatusLabel)
    Ensure-PublishSubtitleProperties -Item $Item
    $Mode = [string]$Item.SubtitleMode
    if ($Mode -eq "Embutir no vídeo" -or $Mode -eq "Embutir + anexar SRT") {
        $Burned = New-BurnedVideoForPublishItem -Item $Item -LogBox $LogBox -StatusLabel $StatusLabel
        $Clone = $Item.PSObject.Copy()
        $Clone.FilePath = $Burned
        $Clone.FileName = Split-SafeLeaf -Path $Burned
        return $Clone
    }
    return $Item
}

function New-PublishGrid {
    $Grid = New-Object System.Windows.Forms.DataGridView
    $Grid.AllowUserToAddRows = $false
    $Grid.AllowUserToDeleteRows = $false
    $Grid.AllowUserToResizeRows = $false
    $Grid.MultiSelect = $false
    $Grid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $Grid.RowHeadersVisible = $false
    $Grid.Anchor = "Top,Bottom,Left,Right"

    $ColSelecionar = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $ColSelecionar.Name = "Selecionar"; $ColSelecionar.HeaderText = ""; $ColSelecionar.Width = 35
    $Grid.Columns.Add($ColSelecionar) | Out-Null

    foreach ($Def in @(
        @{Name="Arquivo";Text="Arquivo";Width=220},
        @{Name="Titulo";Text="Título";Width=260},
        @{Name="Status";Text="Status";Width=95},
        @{Name="Visibilidade";Text="Visibilidade";Width=95},
        @{Name="Playlist";Text="Playlist ID";Width=140},
        @{Name="Thumbnail";Text="Thumbnail";Width=150},
        @{Name="Legendas";Text="Legendas";Width=130},
        @{Name="SRTs";Text="SRTs";Width=120},
        @{Name="Caminho";Text="Caminho completo";Width=315}
    )) {
        $Col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $Col.Name = $Def.Name; $Col.HeaderText = $Def.Text; $Col.Width = $Def.Width; $Col.ReadOnly = $true
        if ($Def.Name -eq "Caminho") {
            $Col.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
            $Col.MinimumWidth = 260
            $Col.FillWeight = 100
        }
        $Grid.Columns.Add($Col) | Out-Null
    }
    return $Grid
}

function New-PublishItemFromFile {
    param([System.IO.FileInfo]$Arquivo)

    $Titulo = [System.IO.Path]::GetFileNameWithoutExtension($Arquivo.Name)
    $Titulo = Remove-TrackNumberPrefix -Title $Titulo

    $Item = [PSCustomObject]@{
        Selected    = $false
        FilePath    = $Arquivo.FullName
        FileName    = $Arquivo.Name
        Title       = $Titulo
        Description = ""
        Tags        = ""
        Privacy     = "private"
        PlaylistId  = ""
        CategoryId  = "10"
        Thumbnail   = ""
        Status      = "Pendente"
        YoutubeId   = ""
        Error       = ""
        SubtitleMode = "Nenhuma"
        AttachAllSrt = $true
        BurnedVideoPath = ""
        CaptionLanguages = ""
    }

    Repair-PublishItemFromPath -Item $Item | Out-Null

    return $Item
}

function Get-YoutubeAcceptedVideoExtensions {
    return @(
        ".mp4",
        ".mov",
        ".mkv",
        ".webm",
        ".avi",
        ".wmv",
        ".flv",
        ".mpeg",
        ".mpg",
        ".m4v",
        ".3gp",
        ".3gpp"
    )
}

function Scan-PublishVideos {
    param([string]$Folder)

    if ([string]::IsNullOrWhiteSpace($Folder) -or -not (Test-SafePath -Path $Folder)) {
        throw "Selecione uma pasta de vídeos válida."
    }

    $ExtensoesAceitas = Get-YoutubeAcceptedVideoExtensions

    $Arquivos = @(
        Get-ChildItem `
            -LiteralPath $Folder `
            -File `
            -Recurse `
            -ErrorAction SilentlyContinue |
        Where-Object {
            $ExtensoesAceitas -contains $_.Extension.ToLowerInvariant()
        } |
        Sort-Object FullName
    )

    $Historico = @(Load-PublishHistory)
    $Itens = @()

    foreach ($Arquivo in $Arquivos) {
        $Item = New-PublishItemFromFile -Arquivo $Arquivo

        $Registro = $Historico |
            Where-Object {
                $_.Arquivo -eq $Arquivo.FullName -and
                -not [string]::IsNullOrWhiteSpace([string]$_.YoutubeId)
            } |
            Select-Object -Last 1

        if ($Registro) {
            $Item.Status = "Enviado"
            $Item.YoutubeId = [string]$Registro.YoutubeId
        }

        $Itens += $Item
    }

    return $Itens
}

function Refresh-PublishGrid {
    if ($null -eq $GridPublicacao) { return }
    $GridPublicacao.Rows.Clear()
    foreach ($Item in $script:ItensPublicacao) {
        Repair-PublishItemFromPath -Item $Item | Out-Null
        Ensure-PublishSubtitleProperties -Item $Item
        Update-PublishItemSubtitleSummary -Item $Item

        $RowIndex = $GridPublicacao.Rows.Add()
        $Row = $GridPublicacao.Rows[$RowIndex]
        $Row.Cells["Selecionar"].Value = [bool]$Item.Selected
        $Row.Cells["Arquivo"].Value = [string]$Item.FileName
        $Row.Cells["Titulo"].Value = [string]$Item.Title
        $Row.Cells["Status"].Value = [string]$Item.Status
        $Row.Cells["Visibilidade"].Value = [string]$Item.Privacy
        $Row.Cells["Playlist"].Value = [string]$Item.PlaylistId
        $Row.Cells["Thumbnail"].Value = Split-SafeLeaf -Path ([string]$Item.Thumbnail)
        $Row.Cells["Legendas"].Value = [string]$Item.SubtitleMode
        $Row.Cells["SRTs"].Value = [string]$Item.CaptionLanguages
        $Row.Cells["Caminho"].Value = [string]$Item.FilePath
        $Row.Tag = $Item
        if ($Item.Status -eq "Enviado") { $Row.DefaultCellStyle.BackColor = [System.Drawing.Color]::Honeydew }
        elseif ($Item.Status -eq "Erro") { $Row.DefaultCellStyle.BackColor = [System.Drawing.Color]::MistyRose }
    }

    AutoSize-PublishGridColumns
}

function Get-SelectedPublishItems {
    $Selecionados = @()
    if ($null -eq $GridPublicacao) { return $Selecionados }
    foreach ($Row in $GridPublicacao.Rows) {
        try {
            $Item = $Row.Tag
            if ($Item -and [bool]$Row.Cells["Selecionar"].Value) { $Item.Selected = $true; $Selecionados += $Item }
            elseif ($Item) { $Item.Selected = $false }
        } catch { }
    }
    return $Selecionados
}

function Set-PublishSelectionAll {
    param([bool]$Value)

    foreach ($Row in $GridPublicacao.Rows) {
        $Row.Cells["Selecionar"].Value = $Value
        if ($Row.Tag) { $Row.Tag.Selected = $Value }
    }
}

function Set-PublishSelectionPending {
    foreach ($Row in $GridPublicacao.Rows) {
        $Item = $Row.Tag
        $Value = ($Item -and $Item.Status -ne "Enviado")
        $Row.Cells["Selecionar"].Value = $Value
        if ($Item) { $Item.Selected = $Value }
    }
}

function Set-PublishEditorFromItem {
    param([object]$Item)
    if ($null -eq $Item) { return }
    $TextPubTitulo.Text = [string]$Item.Title
    $TextPubDescricao.Text = [string]$Item.Description
    $TextPubTags.Text = [string]$Item.Tags
    $TextPubPlaylist.Text = [string]$Item.PlaylistId
    $TextPubCategoria.Text = [string]$Item.CategoryId
    $TextPubThumbnail.Text = [string]$Item.Thumbnail
    if ($ComboPubVisibilidade.Items.Contains([string]$Item.Privacy)) { $ComboPubVisibilidade.SelectedItem = [string]$Item.Privacy } else { $ComboPubVisibilidade.SelectedItem = "private" }
}

function Apply-PublishEditorToItems {
    param([object[]]$Itens)
    foreach ($Item in $Itens) {
        $Item.Title = [string]$TextPubTitulo.Text
        $Item.Description = [string]$TextPubDescricao.Text
        $Item.Tags = [string]$TextPubTags.Text
        $Item.Privacy = [string]$ComboPubVisibilidade.SelectedItem
        $Item.PlaylistId = [string]$TextPubPlaylist.Text
        $Item.CategoryId = [string]$TextPubCategoria.Text
        $Item.Thumbnail = [string]$TextPubThumbnail.Text
    }
    Refresh-PublishGrid
}

function Validate-PublishItems {
    param([object[]]$Itens)
    $Erros = New-Object System.Collections.Generic.List[string]
    foreach ($Item in $Itens) {
        if ([string]::IsNullOrWhiteSpace([string]$Item.FilePath) -or -not (Test-SafePath -Path $Item.FilePath)) { $Erros.Add("Arquivo não encontrado: $($Item.FileName)") }
        if ([string]::IsNullOrWhiteSpace([string]$Item.Title)) { $Erros.Add("Título vazio: $($Item.FileName)") }
        if ([string]$Item.Privacy -notin @("private", "unlisted", "public")) { $Erros.Add("Visibilidade inválida em $($Item.FileName): $($Item.Privacy)") }
        if (-not [string]::IsNullOrWhiteSpace([string]$Item.Thumbnail) -and -not (Test-SafePath -Path $Item.Thumbnail)) { $Erros.Add("Thumbnail não encontrada: $($Item.Thumbnail)") }
        Ensure-PublishSubtitleProperties -Item $Item
        if ([string]$Item.SubtitleMode -ne "Nenhuma") {
            $Srts = @(Find-SrtFilesForPublishItem -Item $Item)
            if ($Srts.Count -eq 0) { $Erros.Add("Nenhum SRT encontrado para a legenda de: $($Item.FileName)") }
        }
    }
    return $Erros
}

function Export-PublishQueue { param([object[]]$Itens) $Path = Get-PublishQueuePath; $Itens | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8; return $Path }
function Import-PublishQueue {
    $Path = Get-PublishQueuePath
    if (-not (Test-SafePath -Path $Path)) { return @() }

    try {
        $Items = @((Get-Content -LiteralPath $Path -Raw -Encoding UTF8) | ConvertFrom-Json)
        foreach ($Item in $Items) {
            Repair-PublishItemFromPath -Item $Item | Out-Null
        }
        return $Items
    }
    catch {
        return @()
    }
}

function Load-YoutubeConfig {
    $Path = Get-YoutubeConfigPath

    if (-not (Test-SafePath -Path $Path)) {
        return $null
    }

    try {
        $Raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8

        if ([string]::IsNullOrWhiteSpace($Raw)) {
            return $null
        }

        return ($Raw | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Save-YoutubeConfig {
    param(
        [string]$ClientId,
        [string]$ClientSecret
    )

    if ([string]::IsNullOrWhiteSpace($ClientId)) {
        throw "Informe o Client ID do OAuth Desktop."
    }

    if ([string]::IsNullOrWhiteSpace($ClientSecret)) {
        throw "Informe o Client Secret do OAuth Desktop."
    }

    $Path = Get-YoutubeConfigPath

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Não foi possível definir o caminho de youtube_config.json."
    }

    $Config = [PSCustomObject]@{
        client_id     = $ClientId.Trim()
        client_secret = $ClientSecret.Trim()
        updated_at    = (Get-Date).ToString("o")
    }

    $Config |
        ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath $Path -Encoding UTF8
}

function Import-YoutubeOAuthJson {
    param([string]$JsonPath)

    if (-not (Test-SafePath -Path $JsonPath)) {
        throw "Arquivo JSON não encontrado."
    }

    $Raw = Get-Content -LiteralPath $JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json

    $Client = $null

    if ($Raw.installed) {
        $Client = $Raw.installed
    }
    elseif ($Raw.web) {
        $Client = $Raw.web
    }

    if ($null -eq $Client) {
        throw "JSON fora do formato esperado. Baixe uma credencial OAuth do tipo Desktop no Google Cloud."
    }

    if (
        [string]::IsNullOrWhiteSpace([string]$Client.client_id) -or
        [string]::IsNullOrWhiteSpace([string]$Client.client_secret)
    ) {
        throw "O JSON não contém client_id e client_secret."
    }

    Save-YoutubeConfig `
        -ClientId ([string]$Client.client_id) `
        -ClientSecret ([string]$Client.client_secret)

    return [PSCustomObject]@{
        client_id     = [string]$Client.client_id
        client_secret = [string]$Client.client_secret
    }
}

function Show-YoutubeConfigForm {
    $Config = Load-YoutubeConfig

    $ConfigForm = New-Object System.Windows.Forms.Form
    $ConfigForm.Text = "Configuração YouTube"
    $ConfigForm.Size = New-Object System.Drawing.Size(720, 260)
    $ConfigForm.StartPosition = "CenterParent"
    $ConfigForm.Font = New-Object System.Drawing.Font("Century Gothic", 9)
    $ConfigForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $ConfigForm.MaximizeBox = $false
    $ConfigForm.MinimizeBox = $false
	
	Set-FormIcon -TargetForm $ConfigForm

    $LabelClientId = New-Object System.Windows.Forms.Label
    $LabelClientId.Text = "Client ID:"
    $LabelClientId.Location = New-Object System.Drawing.Point(20, 25)
    $LabelClientId.Size = New-Object System.Drawing.Size(120, 24)
    $TextClientId = New-Object System.Windows.Forms.TextBox
    $TextClientId.Location = New-Object System.Drawing.Point(145, 25)
    $TextClientId.Size = New-Object System.Drawing.Size(530, 24)

    $LabelClientSecret = New-Object System.Windows.Forms.Label
    $LabelClientSecret.Text = "Client Secret:"
    $LabelClientSecret.Location = New-Object System.Drawing.Point(20, 65)
    $LabelClientSecret.Size = New-Object System.Drawing.Size(120, 24)

    $TextClientSecret = New-Object System.Windows.Forms.TextBox
    $TextClientSecret.Location = New-Object System.Drawing.Point(145, 65)
    $TextClientSecret.Size = New-Object System.Drawing.Size(530, 24)

    $LabelInfo = New-Object System.Windows.Forms.Label
    $LabelInfo.Text = "Importe o JSON OAuth Desktop do Google Cloud ou preencha os campos manualmente. A configuração será salva em youtube_config.json."
    $LabelInfo.Location = New-Object System.Drawing.Point(20, 105)
    $LabelInfo.Size = New-Object System.Drawing.Size(655, 42)

    $ButtonImportar = New-Object System.Windows.Forms.Button
    $ButtonImportar.Text = "Importar JSON..."
    $ButtonImportar.Location = New-Object System.Drawing.Point(145, 160)
    $ButtonImportar.Size = New-Object System.Drawing.Size(140, 32)

    $ButtonSalvar = New-Object System.Windows.Forms.Button
    $ButtonSalvar.Text = "Salvar"
    $ButtonSalvar.Location = New-Object System.Drawing.Point(405, 160)
    $ButtonSalvar.Size = New-Object System.Drawing.Size(120, 32)

    $ButtonFechar = New-Object System.Windows.Forms.Button
    $ButtonFechar.Text = "Fechar"
    $ButtonFechar.Location = New-Object System.Drawing.Point(555, 160)
    $ButtonFechar.Size = New-Object System.Drawing.Size(120, 32)

    if ($Config) {
        $TextClientId.Text = [string]$Config.client_id
        $TextClientSecret.Text = [string]$Config.client_secret
    }

    $ButtonImportar.Add_Click({
        $Dialog = New-Object System.Windows.Forms.OpenFileDialog
        $Dialog.Title = "Importar JSON OAuth do Google Cloud"
        $Dialog.Filter = "JSON|*.json|Todos os arquivos|*.*"
        $Dialog.Multiselect = $false

        if ($Dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            try {
                $Imported = Import-YoutubeOAuthJson -JsonPath $Dialog.FileName

                $TextClientId.Text = [string]$Imported.client_id
                $TextClientSecret.Text = [string]$Imported.client_secret

                [System.Windows.Forms.MessageBox]::Show(
                    "Credencial importada e salva com sucesso.",
                    "Configuração YouTube",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Information
                ) | Out-Null
            }
            catch {
                [System.Windows.Forms.MessageBox]::Show(
                    $_.Exception.Message,
                    "Erro ao importar JSON",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Error
                ) | Out-Null
            }
        }
    })

    $ButtonSalvar.Add_Click({
        try {
            Save-YoutubeConfig `
                -ClientId $TextClientId.Text `
                -ClientSecret $TextClientSecret.Text

            [System.Windows.Forms.MessageBox]::Show(
                "Configuração salva com sucesso.",
                "Configuração YouTube",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null

            $ConfigForm.Close()
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(
                $_.Exception.Message,
                "Erro ao salvar configuração",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
        }
    })

    $ButtonFechar.Add_Click({
        $ConfigForm.Close()
    })

    $ConfigForm.Controls.AddRange(@(
        $LabelClientId,
        $TextClientId,
        $LabelClientSecret,
        $TextClientSecret,
        $LabelInfo,
        $ButtonImportar,
        $ButtonSalvar,
        $ButtonFechar
    ))

	Apply-ThemeToControl -Control $ConfigForm -Dark $script:TemaEscuro
	[void]$ConfigForm.ShowDialog()
}


function Get-YoutubeClientInfo {
    $Config = Load-YoutubeConfig

    if (
        $null -eq $Config -or
        [string]::IsNullOrWhiteSpace([string]$Config.client_id) -or
        [string]::IsNullOrWhiteSpace([string]$Config.client_secret)
    ) {
        throw "Configuração do YouTube não encontrada. Clique em 'Configurar YouTube', importe o JSON OAuth Desktop do Google Cloud e salve."
    }

    return [PSCustomObject]@{
        client_id     = [string]$Config.client_id
        client_secret = [string]$Config.client_secret
    }
}

function Save-YoutubeToken {
    param([object]$Token)

    if ([string]::IsNullOrWhiteSpace($script:YoutubeTokenPath)) {
        $script:YoutubeTokenPath = Join-SafePath $script:AppRoot "youtube_token.json"
    }

    if ([string]::IsNullOrWhiteSpace($script:YoutubeTokenPath)) {
        throw "Não foi possível definir o caminho de youtube_token.json."
    }

    $Token |
        ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $script:YoutubeTokenPath -Encoding UTF8
}

function Load-YoutubeToken {
    if (-not (Test-SafePath -Path $script:YoutubeTokenPath)) {
        return $null
    }

    try {
        return (Get-Content -LiteralPath $script:YoutubeTokenPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Test-YoutubeTokenExpired { param([object]$Token) if ($null -eq $Token -or [string]::IsNullOrWhiteSpace([string]$Token.access_token) -or [string]::IsNullOrWhiteSpace([string]$Token.expires_at)) { return $true }; try { return ((Get-Date).AddMinutes(2) -ge [DateTime]::Parse([string]$Token.expires_at)) } catch { return $true } }

function Refresh-YoutubeAccessToken {
    $Token = Load-YoutubeToken
    if ($null -eq $Token) { throw "Conta do YouTube ainda não conectada." }
    if (-not (Test-YoutubeTokenExpired -Token $Token)) { return $Token.access_token }
    if ([string]::IsNullOrWhiteSpace([string]$Token.refresh_token)) { throw "Token expirado. Conecte a conta novamente." }
    $Client = Get-YoutubeClientInfo
    $Response = Invoke-RestMethod -Method Post -Uri "https://oauth2.googleapis.com/token" -Body @{ client_id=$Client.client_id; client_secret=$Client.client_secret; refresh_token=$Token.refresh_token; grant_type="refresh_token" } -ContentType "application/x-www-form-urlencoded"
    $Token.access_token = $Response.access_token; $Token.expires_at = (Get-Date).AddSeconds([int]$Response.expires_in).ToString("o")
    Save-YoutubeToken -Token $Token
    return $Token.access_token
}

function Get-FreeTcpPort {
    $TcpListener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)

    try {
        $TcpListener.Start()
        return $TcpListener.LocalEndpoint.Port
    }
    finally {
        $TcpListener.Stop()
    }
}

function Connect-YoutubeAccount {
    param([System.Windows.Forms.TextBox]$LogBox)

    $Client = Get-YoutubeClientInfo

    $Port = Get-FreeTcpPort
    $RedirectUri = "http://localhost:$Port/"

    $Scope = [System.Uri]::EscapeDataString("https://www.googleapis.com/auth/youtube.upload https://www.googleapis.com/auth/youtube.force-ssl")
    $State = [guid]::NewGuid().ToString("N")

    $AuthUrl =
        "https://accounts.google.com/o/oauth2/v2/auth" +
        "?client_id=$([System.Uri]::EscapeDataString($Client.client_id))" +
        "&redirect_uri=$([System.Uri]::EscapeDataString($RedirectUri))" +
        "&response_type=code" +
        "&scope=$Scope" +
        "&access_type=offline" +
        "&prompt=consent" +
        "&state=$State"

    Add-Log -LogBox $LogBox -Mensagem "Abrindo navegador para autorização..."
    Add-Log -LogBox $LogBox -Mensagem "Aguardando retorno do Google por até 2 minutos..."
    Add-Log -LogBox $LogBox -Mensagem "URL local de retorno: $RedirectUri"

    $Listener = New-Object System.Net.HttpListener
    $Listener.Prefixes.Add($RedirectUri)

    try {
        try {
            $Listener.Start()
        }
        catch {
            throw "Não foi possível abrir o servidor local OAuth em $RedirectUri. Detalhe: $($_.Exception.Message)"
        }

        Start-Process $AuthUrl | Out-Null

        $AsyncResult = $Listener.BeginGetContext($null, $null)
        $InicioEspera = Get-Date
        $TimeoutSegundos = 120
        $Context = $null

        while ($true) {
            if ($AsyncResult.AsyncWaitHandle.WaitOne(250)) {
                $Context = $Listener.EndGetContext($AsyncResult)
                break
            }

            [System.Windows.Forms.Application]::DoEvents()

            $TempoDecorrido = ((Get-Date) - $InicioEspera).TotalSeconds

            if ($TempoDecorrido -ge $TimeoutSegundos) {
                throw "Tempo esgotado aguardando o retorno do Google. Se você fechou a aba do navegador, clique em Conectar novamente."
            }
        }

        $Code = $Context.Request.QueryString["code"]
        $ReturnedState = $Context.Request.QueryString["state"]
        $Error = $Context.Request.QueryString["error"]

        $Html = @"
<html>
<head>
<meta charset="utf-8">
<title>Autorização concluída</title>
</head>
<body style="font-family: Arial, sans-serif;">
<h2>Autorização concluída.</h2>
<p>Você já pode voltar ao Gerador de Vídeos FREZZA.</p>
</body>
</html>
"@

        $Buffer = [System.Text.Encoding]::UTF8.GetBytes($Html)
        $Context.Response.ContentType = "text/html; charset=utf-8"
        $Context.Response.ContentLength64 = $Buffer.Length
        $Context.Response.OutputStream.Write($Buffer, 0, $Buffer.Length)
        $Context.Response.OutputStream.Close()

        if (-not [string]::IsNullOrWhiteSpace($Error)) {
            throw "O Google retornou erro na autorização: $Error"
        }

        if ([string]::IsNullOrWhiteSpace($Code)) {
            throw "O Google não retornou o código de autorização."
        }

        if ($ReturnedState -ne $State) {
            throw "Estado OAuth inválido."
        }

        try {
            $Token = Invoke-RestMethod `
                -Method Post `
                -Uri "https://oauth2.googleapis.com/token" `
                -Body @{
                    code          = $Code
                    client_id     = $Client.client_id
                    client_secret = $Client.client_secret
                    redirect_uri  = $RedirectUri
                    grant_type    = "authorization_code"
                } `
                -ContentType "application/x-www-form-urlencoded"
        }
        catch {
            $Detalhe = $_.Exception.Message

            try {
                $Stream = $_.Exception.Response.GetResponseStream()
                $Reader = New-Object System.IO.StreamReader($Stream)
                $RespostaGoogle = $Reader.ReadToEnd()

                if (-not [string]::IsNullOrWhiteSpace($RespostaGoogle)) {
                    $Detalhe += [Environment]::NewLine + $RespostaGoogle
                }
            }
            catch {
            }

            throw "Erro ao trocar autorização por token: $Detalhe"
        }

        $Token | Add-Member `
            -NotePropertyName expires_at `
            -NotePropertyValue ((Get-Date).AddSeconds([int]$Token.expires_in).ToString("o")) `
            -Force

        Save-YoutubeToken -Token $Token

        Add-Log -LogBox $LogBox -Mensagem "Conta conectada com sucesso."

        return $true
    }
    finally {
        try {
            if ($Listener -and $Listener.IsListening) {
                $Listener.Stop()
            }

            if ($Listener) {
                $Listener.Close()
            }
        }
        catch {
        }
    }
}

function Start-YoutubeVideoUpload {
    param([object]$Item, [System.Windows.Forms.TextBox]$LogBox)
    $AccessToken = Refresh-YoutubeAccessToken
    $Arquivo = Get-Item -LiteralPath $Item.FilePath
    $Tags = @(); if (-not [string]::IsNullOrWhiteSpace([string]$Item.Tags)) { $Tags = @(([string]$Item.Tags).Split(',') | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) }
    $Metadata = [PSCustomObject]@{ snippet = [PSCustomObject]@{ title=[string]$Item.Title; description=[string]$Item.Description; tags=$Tags; categoryId=$(if ([string]::IsNullOrWhiteSpace([string]$Item.CategoryId)) { "10" } else { [string]$Item.CategoryId }) }; status = [PSCustomObject]@{ privacyStatus=[string]$Item.Privacy; selfDeclaredMadeForKids=$false } }
    $InitResponse = Invoke-WebRequest -Method Post -Uri "https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&part=snippet,status" -Headers @{ Authorization="Bearer $AccessToken"; "X-Upload-Content-Length"=$Arquivo.Length; "X-Upload-Content-Type"="video/*" } -Body ($Metadata | ConvertTo-Json -Depth 10) -ContentType "application/json; charset=UTF-8" -UseBasicParsing
    $UploadUrl = $InitResponse.Headers.Location
    if ([string]::IsNullOrWhiteSpace($UploadUrl)) { throw "O YouTube não retornou URL de upload." }
    Add-Log -LogBox $LogBox -Mensagem "Enviando arquivo: $($Item.FileName)"
    $UploadResponse = Invoke-WebRequest -Method Put -Uri $UploadUrl -Headers @{ Authorization="Bearer $AccessToken" } -InFile $Arquivo.FullName -ContentType "video/*" -UseBasicParsing
    $VideoInfo = $UploadResponse.Content | ConvertFrom-Json; $VideoId = [string]$VideoInfo.id
    if ([string]::IsNullOrWhiteSpace($VideoId)) { throw "Upload concluído, mas sem ID do vídeo." }
    if (-not [string]::IsNullOrWhiteSpace([string]$Item.Thumbnail)) { Set-YoutubeThumbnail -VideoId $VideoId -ThumbnailPath ([string]$Item.Thumbnail) -LogBox $LogBox }
    if (-not [string]::IsNullOrWhiteSpace([string]$Item.PlaylistId)) { Add-YoutubeVideoToPlaylist -VideoId $VideoId -PlaylistId ([string]$Item.PlaylistId) -LogBox $LogBox }
    return $VideoId
}

function Set-YoutubeThumbnail {
    param([string]$VideoId, [string]$ThumbnailPath, [System.Windows.Forms.TextBox]$LogBox)
    if (-not (Test-SafePath -Path $ThumbnailPath)) { return }
    $AccessToken = Refresh-YoutubeAccessToken; $Ext = ([System.IO.Path]::GetExtension($ThumbnailPath)).ToLowerInvariant(); $ContentType = $(if ($Ext -eq ".png") { "image/png" } else { "image/jpeg" })
    Add-Log -LogBox $LogBox -Mensagem "Enviando thumbnail..."
    Invoke-WebRequest -Method Post -Uri "https://www.googleapis.com/upload/youtube/v3/thumbnails/set?videoId=$VideoId" -Headers @{ Authorization="Bearer $AccessToken" } -InFile $ThumbnailPath -ContentType $ContentType -UseBasicParsing | Out-Null
}

function Add-YoutubeVideoToPlaylist {
    param([string]$VideoId, [string]$PlaylistId, [System.Windows.Forms.TextBox]$LogBox)
    $AccessToken = Refresh-YoutubeAccessToken
    $Body = [PSCustomObject]@{ snippet = [PSCustomObject]@{ playlistId=$PlaylistId; resourceId=[PSCustomObject]@{ kind="youtube#video"; videoId=$VideoId } } } | ConvertTo-Json -Depth 10
    Add-Log -LogBox $LogBox -Mensagem "Adicionando à playlist..."
    Invoke-RestMethod -Method Post -Uri "https://www.googleapis.com/youtube/v3/playlistItems?part=snippet" -Headers @{ Authorization="Bearer $AccessToken" } -Body $Body -ContentType "application/json; charset=UTF-8" | Out-Null
}

function Publish-SelectedVideosToYoutube {
    param([object[]]$Itens)
    if ($Itens.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show("Nenhum vídeo selecionado.", "Publicação", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null; return }
    $Erros = Validate-PublishItems -Itens $Itens
    if ($Erros.Count -gt 0) { [System.Windows.Forms.MessageBox]::Show(($Erros -join [Environment]::NewLine), "Corrija antes de publicar", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null; return }
    $Confirmacao = [System.Windows.Forms.MessageBox]::Show("Enviar $($Itens.Count) vídeo(s) ao YouTube agora?", "Confirmar publicação", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($Confirmacao -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    $ButtonPubEnviarSelecionados.Enabled = $false; $ButtonPubEnviarPendentes.Enabled = $false
    try {
        foreach ($Item in $Itens) {
            try {
                $Item.Status = "Preparando"; Refresh-PublishGrid; [System.Windows.Forms.Application]::DoEvents()
                Ensure-PublishSubtitleProperties -Item $Item
                $UploadItem = Get-UploadItemForSubtitleMode -Item $Item -LogBox $TextPubLog -StatusLabel $null
                $Item.Status = "Enviando"; Refresh-PublishGrid; [System.Windows.Forms.Application]::DoEvents()
                $VideoId = Start-YoutubeVideoUpload -Item $UploadItem -LogBox $TextPubLog
                $Item.YoutubeId = $VideoId

                if ([string]$Item.SubtitleMode -eq "Anexar SRT ao YouTube" -or [string]$Item.SubtitleMode -eq "Embutir + anexar SRT") {
                    $Srts = @(Find-SrtFilesForPublishItem -Item $Item)
                    if (-not [bool]$Item.AttachAllSrt) {
                        $Primary = Get-PrimarySrtInfoForPublishItem -Item $Item
                        if ($null -ne $Primary) { $Srts = @($Primary) } else { $Srts = @() }
                    }
                    if ($Srts.Count -eq 0) { Add-Log -LogBox $TextPubLog -Mensagem "AVISO: nenhum SRT encontrado para anexar." }
                    foreach ($Srt in $Srts) {
                        Upload-YoutubeCaptionTrack -VideoId $VideoId -SrtPath ([string]$Srt.Path) -LanguageCode ([string]$Srt.Language) -CaptionName ([string]$Srt.Name) -LogBox $TextPubLog
                    }
                }

                $Item.Status = "Enviado"; Add-PublishHistoryItem -Item $Item -YoutubeId $VideoId -Status "Enviado"
                Add-Log -LogBox $TextPubLog -Mensagem "Publicado: https://www.youtube.com/watch?v=$VideoId"
            }
            catch { $Item.Status = "Erro"; $Item.Error = $_.Exception.Message; Add-PublishHistoryItem -Item $Item -YoutubeId "" -Status "Erro" -Erro $_.Exception.Message; Add-Log -LogBox $TextPubLog -Mensagem "ERRO em $($Item.FileName): $($_.Exception.Message)" }
            finally { Refresh-PublishGrid; [System.Windows.Forms.Application]::DoEvents() }
        }
        Export-PublishQueue -Itens $script:ItensPublicacao | Out-Null
    }
    finally { $ButtonPubEnviarSelecionados.Enabled = $true; $ButtonPubEnviarPendentes.Enabled = $true }
}

function Remove-TrackNumberPrefix {
    param([string]$Title)

    if ([string]::IsNullOrWhiteSpace($Title)) {
        return ""
    }

    $Clean = $Title.Trim()

    # Remove padrões como:
    # 01 - Música
    # 01. Música
    # 01_ Música
    # Faixa 01 - Música
    # Track 01 - Música
    # 1 - Música
    # 001 - Música
    $Patterns = @(
        '^\s*(faixa|track)\s*\d{1,3}\s*[-–—._)]\s*',
        '^\s*\d{1,3}\s*[-–—._)]\s*',
        '^\s*\d{1,3}\s+'
    )

    foreach ($Pattern in $Patterns) {
        $Clean = $Clean -replace $Pattern, ''
    }

    return $Clean.Trim()
}

function Copy-PublishMetadata {
    param([object]$SourceItem)

    if ($null -eq $SourceItem) {
        return $null
    }

    return [PSCustomObject]@{
        Title       = [string]$SourceItem.Title
        Description = [string]$SourceItem.Description
        Tags        = [string]$SourceItem.Tags
        Privacy     = [string]$SourceItem.Privacy
        PlaylistId  = [string]$SourceItem.PlaylistId
        CategoryId  = [string]$SourceItem.CategoryId
        Thumbnail   = [string]$SourceItem.Thumbnail
        Status      = [string]$SourceItem.Status
    }
}

function Apply-PublishMetadataToItem {
    param(
        [object]$Item,
        [object]$Metadata,
        [bool]$ApplyTitle = $false,
        [bool]$ApplyStatus = $false
    )

    if ($null -eq $Item -or $null -eq $Metadata) {
        return
    }

    if ($ApplyTitle) {
        $Item.Title = [string]$Metadata.Title
    }

    if ($ApplyStatus) {
        $Item.Status = [string]$Metadata.Status
    }

    $Item.Description = [string]$Metadata.Description
    $Item.Tags        = [string]$Metadata.Tags
    $Item.Privacy     = [string]$Metadata.Privacy
    $Item.PlaylistId  = [string]$Metadata.PlaylistId
    $Item.CategoryId  = [string]$Metadata.CategoryId
    $Item.Thumbnail   = [string]$Metadata.Thumbnail
}

function Get-YoutubePlaylists {
    $AccessToken = Refresh-YoutubeAccessToken
    $Playlists = @()
    $PageToken = ""

    do {
        $Uri = "https://www.googleapis.com/youtube/v3/playlists?part=snippet&mine=true&maxResults=50"

        if (-not [string]::IsNullOrWhiteSpace($PageToken)) {
            $Uri += "&pageToken=$([System.Uri]::EscapeDataString($PageToken))"
        }

        $Response = Invoke-RestMethod `
            -Method Get `
            -Uri $Uri `
            -Headers @{ Authorization = "Bearer $AccessToken" }

        foreach ($Item in $Response.items) {
            $Playlists += [PSCustomObject]@{
                Id    = [string]$Item.id
                Title = [string]$Item.snippet.title
            }
        }

        $PageToken = [string]$Response.nextPageToken
    }
    while (-not [string]::IsNullOrWhiteSpace($PageToken))

    $script:YoutubePlaylists = @($Playlists | Sort-Object Title)

    return $script:YoutubePlaylists
}

function Show-PublishEditForm {
    param([object]$Item)

    if ($null -eq $Item) {
        return
    }

    $EditForm = New-Object System.Windows.Forms.Form
    $EditForm.Text = "Editar dados do vídeo"
    $EditForm.Size = New-Object System.Drawing.Size(800, 540)
    $EditForm.StartPosition = "CenterParent"
    $EditForm.Font = New-Object System.Drawing.Font("Century Gothic", 9)
    $EditForm.MinimumSize = New-Object System.Drawing.Size(760, 500)
	
	Set-FormIcon -TargetForm $EditForm

    $LabelArquivo = New-Object System.Windows.Forms.Label
    $LabelArquivo.Text = "Arquivo:"
    $LabelArquivo.Location = New-Object System.Drawing.Point(20, 20)
    $LabelArquivo.Size = New-Object System.Drawing.Size(90, 24)

    $TextArquivo = New-Object System.Windows.Forms.TextBox
    $TextArquivo.Text = [string]$Item.FilePath
    $TextArquivo.Location = New-Object System.Drawing.Point(120, 20)
    $TextArquivo.Size = New-Object System.Drawing.Size(610, 24)
    $TextArquivo.ReadOnly = $true

    $LabelTitulo = New-Object System.Windows.Forms.Label
    $LabelTitulo.Text = "Título:"
    $LabelTitulo.Location = New-Object System.Drawing.Point(20, 60)
    $LabelTitulo.Size = New-Object System.Drawing.Size(90, 24)

    $TextTitulo = New-Object System.Windows.Forms.TextBox
    $TextTitulo.Text = [string]$Item.Title
    $TextTitulo.Location = New-Object System.Drawing.Point(120, 60)
    $TextTitulo.Size = New-Object System.Drawing.Size(475, 24)

    $ButtonLimparTitulo = New-Object System.Windows.Forms.Button
    $ButtonLimparTitulo.Text = "Remover número da faixa"
    $ButtonLimparTitulo.Location = New-Object System.Drawing.Point(605, 55)
    $ButtonLimparTitulo.Size = New-Object System.Drawing.Size(135, 36)

    $LabelDescricao = New-Object System.Windows.Forms.Label
    $LabelDescricao.Text = "Descrição:"
    $LabelDescricao.Location = New-Object System.Drawing.Point(20, 100)
    $LabelDescricao.Size = New-Object System.Drawing.Size(90, 24)

    $TextDescricao = New-Object System.Windows.Forms.TextBox
    $TextDescricao.Text = [string]$Item.Description
    $TextDescricao.Location = New-Object System.Drawing.Point(120, 100)
    $TextDescricao.Size = New-Object System.Drawing.Size(610, 120)
    $TextDescricao.Multiline = $true
    $TextDescricao.ScrollBars = "Vertical"

    $LabelTags = New-Object System.Windows.Forms.Label
    $LabelTags.Text = "Tags:"
    $LabelTags.Location = New-Object System.Drawing.Point(20, 235)
    $LabelTags.Size = New-Object System.Drawing.Size(90, 24)

    $TextTags = New-Object System.Windows.Forms.TextBox
    $TextTags.Text = [string]$Item.Tags
    $TextTags.Location = New-Object System.Drawing.Point(120, 235)
    $TextTags.Size = New-Object System.Drawing.Size(610, 24)

    $LabelVisibilidade = New-Object System.Windows.Forms.Label
    $LabelVisibilidade.Text = "Visibilidade:"
    $LabelVisibilidade.Location = New-Object System.Drawing.Point(20, 275)
    $LabelVisibilidade.Size = New-Object System.Drawing.Size(90, 24)

    $ComboVisibilidade = New-Object System.Windows.Forms.ComboBox
    $ComboVisibilidade.Location = New-Object System.Drawing.Point(120, 275)
    $ComboVisibilidade.Size = New-Object System.Drawing.Size(140, 24)
    $ComboVisibilidade.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    [void]$ComboVisibilidade.Items.Add("private")
    [void]$ComboVisibilidade.Items.Add("unlisted")
    [void]$ComboVisibilidade.Items.Add("public")

    if ($ComboVisibilidade.Items.Contains([string]$Item.Privacy)) {
        $ComboVisibilidade.SelectedItem = [string]$Item.Privacy
    }
    else {
        $ComboVisibilidade.SelectedItem = "private"
    }

    $LabelCategoria = New-Object System.Windows.Forms.Label
    $LabelCategoria.Text = "Categoria:"
    $LabelCategoria.Location = New-Object System.Drawing.Point(290, 275)
    $LabelCategoria.Size = New-Object System.Drawing.Size(80, 24)

    $TextCategoria = New-Object System.Windows.Forms.TextBox
    $TextCategoria.Text = [string]$Item.CategoryId
    $TextCategoria.Location = New-Object System.Drawing.Point(380, 275)
    $TextCategoria.Size = New-Object System.Drawing.Size(80, 24)
	
	$LabelStatus = New-Object System.Windows.Forms.Label
	$LabelStatus.Text = "Status:"
	$LabelStatus.Location = New-Object System.Drawing.Point(490, 275)
	$LabelStatus.Size = New-Object System.Drawing.Size(60, 24)

	$ComboStatus = New-Object System.Windows.Forms.ComboBox
	$ComboStatus.Location = New-Object System.Drawing.Point(555, 275)
	$ComboStatus.Size = New-Object System.Drawing.Size(175, 24)
	$ComboStatus.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList

	[void]$ComboStatus.Items.Add("Pendente")
	[void]$ComboStatus.Items.Add("Enviado")
	[void]$ComboStatus.Items.Add("Erro")
	[void]$ComboStatus.Items.Add("Enviando")

	if ($ComboStatus.Items.Contains([string]$Item.Status)) {
		$ComboStatus.SelectedItem = [string]$Item.Status
	}
	else {
		$ComboStatus.SelectedItem = "Pendente"
	}

    $LabelPlaylist = New-Object System.Windows.Forms.Label
    $LabelPlaylist.Text = "Playlist:"
    $LabelPlaylist.Location = New-Object System.Drawing.Point(20, 315)
    $LabelPlaylist.Size = New-Object System.Drawing.Size(90, 24)

    $ComboPlaylist = New-Object System.Windows.Forms.ComboBox
    $ComboPlaylist.Location = New-Object System.Drawing.Point(120, 315)
    $ComboPlaylist.Size = New-Object System.Drawing.Size(490, 24)
    $ComboPlaylist.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList

    $ButtonAtualizarPlaylists = New-Object System.Windows.Forms.Button
    $ButtonAtualizarPlaylists.Text = "Atualizar"
    $ButtonAtualizarPlaylists.Location = New-Object System.Drawing.Point(620, 312)
    $ButtonAtualizarPlaylists.Size = New-Object System.Drawing.Size(110, 30)

    function Fill-PlaylistComboInEditForm {
        $ComboPlaylist.Items.Clear()

        [void]$ComboPlaylist.Items.Add([PSCustomObject]@{
            Id    = ""
            Title = "(sem playlist)"
        })

        foreach ($Playlist in $script:YoutubePlaylists) {
            [void]$ComboPlaylist.Items.Add($Playlist)
        }

        $ComboPlaylist.DisplayMember = "Title"
        $ComboPlaylist.ValueMember = "Id"

        $Selecionado = $null

        foreach ($Obj in $ComboPlaylist.Items) {
            if ([string]$Obj.Id -eq [string]$Item.PlaylistId) {
                $Selecionado = $Obj
                break
            }
        }

        if ($Selecionado) {
            $ComboPlaylist.SelectedItem = $Selecionado
        }
        else {
            $ComboPlaylist.SelectedIndex = 0
        }
    }

    Fill-PlaylistComboInEditForm

    $ButtonAtualizarPlaylists.Add_Click({
        try {
            Get-YoutubePlaylists | Out-Null
            Fill-PlaylistComboInEditForm

            [System.Windows.Forms.MessageBox]::Show(
                "Playlists atualizadas.",
                "Playlists",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(
                $_.Exception.Message,
                "Erro ao buscar playlists",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
        }
    })

    $LabelThumbnail = New-Object System.Windows.Forms.Label
    $LabelThumbnail.Text = "Thumbnail:"
    $LabelThumbnail.Location = New-Object System.Drawing.Point(20, 355)
    $LabelThumbnail.Size = New-Object System.Drawing.Size(90, 24)

    $TextThumbnail = New-Object System.Windows.Forms.TextBox
    $TextThumbnail.Text = [string]$Item.Thumbnail
    $TextThumbnail.Location = New-Object System.Drawing.Point(120, 355)
    $TextThumbnail.Size = New-Object System.Drawing.Size(490, 24)

    $ButtonThumbnail = New-Object System.Windows.Forms.Button
    $ButtonThumbnail.Text = "Escolher..."
    $ButtonThumbnail.Location = New-Object System.Drawing.Point(620, 352)
    $ButtonThumbnail.Size = New-Object System.Drawing.Size(110, 30)

	$CheckAplicarTitulo = New-Object System.Windows.Forms.CheckBox
	$CheckAplicarTitulo.Text = "Copiar também o título"
	$CheckAplicarTitulo.Location = New-Object System.Drawing.Point(120, 395)
	$CheckAplicarTitulo.Size = New-Object System.Drawing.Size(220, 24)
	$CheckAplicarTitulo.Checked = $false

	$CheckAplicarStatus = New-Object System.Windows.Forms.CheckBox
	$CheckAplicarStatus.Text = "Copiar também o status"
	$CheckAplicarStatus.Location = New-Object System.Drawing.Point(360, 395)
	$CheckAplicarStatus.Size = New-Object System.Drawing.Size(240, 24)
	$CheckAplicarStatus.Checked = $false

    $ButtonSalvar = New-Object System.Windows.Forms.Button
    $ButtonSalvar.Text = "Salvar"
    $ButtonSalvar.Location = New-Object System.Drawing.Point(300, 425)
    $ButtonSalvar.Size = New-Object System.Drawing.Size(120, 40)

    $ButtonSalvarAplicar = New-Object System.Windows.Forms.Button
    $ButtonSalvarAplicar.Text = "Salvar e aplicar aos selecionados"
    $ButtonSalvarAplicar.Location = New-Object System.Drawing.Point(435, 425)
    $ButtonSalvarAplicar.Size = New-Object System.Drawing.Size(230, 40)

    $ButtonCancelar = New-Object System.Windows.Forms.Button
    $ButtonCancelar.Text = "Cancelar"
    $ButtonCancelar.Location = New-Object System.Drawing.Point(680, 425)
    $ButtonCancelar.Size = New-Object System.Drawing.Size(90, 40)

    $ButtonLimparTitulo.Add_Click({
        $TextTitulo.Text = Remove-TrackNumberPrefix -Title $TextTitulo.Text
    })

    $ButtonThumbnail.Add_Click({
        $Imagem = Select-ImageFile -InitialPath $TextThumbnail.Text
        if (-not [string]::IsNullOrWhiteSpace($Imagem)) {
            $TextThumbnail.Text = $Imagem
        }
    })

    $SalvarNoItem = {
        $Item.Title       = [string]$TextTitulo.Text
        $Item.Description = [string]$TextDescricao.Text
        $Item.Tags        = [string]$TextTags.Text
        $Item.Privacy     = [string]$ComboVisibilidade.SelectedItem
        $Item.CategoryId  = [string]$TextCategoria.Text
        $Item.Thumbnail   = [string]$TextThumbnail.Text
		$Item.Status      = [string]$ComboStatus.SelectedItem

        if ($ComboPlaylist.SelectedItem) {
            $Item.PlaylistId = [string]$ComboPlaylist.SelectedItem.Id
        }
        else {
            $Item.PlaylistId = ""
        }

        $script:UltimosMetadadosPublicacao = Copy-PublishMetadata -SourceItem $Item

        Refresh-PublishGrid
        Set-PublishEditorFromItem -Item $Item
    }

    $ButtonSalvar.Add_Click({
        & $SalvarNoItem
        Export-PublishQueue -Itens $script:ItensPublicacao | Out-Null
        $EditForm.Close()
    })

    $ButtonSalvarAplicar.Add_Click({
        & $SalvarNoItem

        $Metadata = Copy-PublishMetadata -SourceItem $Item
        $Selecionados = @(Get-SelectedPublishItems)

        if ($Selecionados.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                "Nenhum vídeo marcado. Marque os vídeos que devem receber esses dados.",
                "Aplicar aos selecionados",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
            return
        }

        foreach ($Destino in $Selecionados) {
            if ($Destino -ne $Item) {
                Apply-PublishMetadataToItem -Item $Destino -Metadata $Metadata -ApplyTitle ([bool]$CheckAplicarTitulo.Checked) -ApplyStatus ([bool]$CheckAplicarStatus.Checked)
            }
        }

        Refresh-PublishGrid
        Export-PublishQueue -Itens $script:ItensPublicacao | Out-Null

        [System.Windows.Forms.MessageBox]::Show(
            "Dados aplicados aos vídeos selecionados.",
            "Aplicar aos selecionados",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null

        $EditForm.Close()
    })

    $ButtonCancelar.Add_Click({
        $EditForm.Close()
    })

    $EditForm.Controls.AddRange(@(
        $LabelArquivo,
        $TextArquivo,
        $LabelTitulo,
        $TextTitulo,
        $ButtonLimparTitulo,
        $LabelDescricao,
        $TextDescricao,
        $LabelTags,
        $TextTags,
        $LabelVisibilidade,
        $ComboVisibilidade,
        $LabelCategoria,
        $TextCategoria,
		$LabelStatus,
		$ComboStatus,
		$LabelPlaylist,
        $ComboPlaylist,
        $ButtonAtualizarPlaylists,
        $LabelThumbnail,
        $TextThumbnail,
        $ButtonThumbnail,
        $CheckAplicarTitulo,
		$CheckAplicarStatus,
        $ButtonSalvar,
        $ButtonSalvarAplicar,
        $ButtonCancelar
    ))

	Apply-ThemeToControl -Control $EditForm -Dark $script:TemaEscuro
    [void]$EditForm.ShowDialog()
}


# ============================================================
# LEGENDAS MANUAIS / IMPORTAÇÃO DE LETRA
# ============================================================

$script:ItensLegenda = @()
$script:LinhasLegendaAtuais = @()
if ($null -eq $script:CoverPathByMusicKey) { $script:CoverPathByMusicKey = @{} }

function Format-SrtTime {
    param([double]$Seconds)

    if ($Seconds -lt 0) { $Seconds = 0 }

    $TotalMilliseconds = [int][Math]::Round($Seconds * 1000)
    $Hours = [int][Math]::Floor($TotalMilliseconds / 3600000)
    $Remainder = $TotalMilliseconds % 3600000
    $Minutes = [int][Math]::Floor($Remainder / 60000)
    $Remainder = $Remainder % 60000
    $Secs = [int][Math]::Floor($Remainder / 1000)
    $Millis = $Remainder % 1000

    return "{0:D2}:{1:D2}:{2:D2},{3:D3}" -f $Hours, $Minutes, $Secs, $Millis
}

function Parse-SrtTime {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return 0.0 }

    $Clean = ([string]$Text).Trim().Replace('.', ',')

    if ($Clean -match '^(\d{1,2}):(\d{2}):(\d{2}),(\d{1,3})$') {
        $MsText = $Matches[4].PadRight(3, '0').Substring(0, 3)
        return ([int]$Matches[1] * 3600) + ([int]$Matches[2] * 60) + [int]$Matches[3] + ([int]$MsText / 1000.0)
    }

    if ($Clean -match '^(\d{1,2}):(\d{2}),(\d{1,3})$') {
        $MsText = $Matches[3].PadRight(3, '0').Substring(0, 3)
        return ([int]$Matches[1] * 60) + [int]$Matches[2] + ([int]$MsText / 1000.0)
    }

    try {
        return [double]::Parse($Clean.Replace(',', '.'), [System.Globalization.CultureInfo]::InvariantCulture)
    }
    catch {
        return 0.0
    }
}

function Get-LyricsLinesFromText {
    param([string]$Text)

    if ($null -eq $Text) { return @() }

    return @(([string]$Text -split "`r?`n") |
        ForEach-Object { ([string]$_).Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function New-SubtitleRowsFromLyrics {
    param(
        [string[]]$Lines,
        [double]$DurationSeconds
    )

    $Rows = @()

    if ($null -eq $Lines -or $Lines.Count -eq 0) {
        return $Rows
    }

    if ($DurationSeconds -le 0) {
        $DurationSeconds = [Math]::Max($Lines.Count * 4.0, 4.0)
    }

    $Gap = 0.15
    $Segment = [Math]::Max($DurationSeconds / $Lines.Count, 0.8)

    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $Start = $i * $Segment
        $End = (($i + 1) * $Segment) - $Gap

        if ($i -eq ($Lines.Count - 1)) {
            $End = $DurationSeconds
        }

        if ($End -le $Start) {
            $End = $Start + 0.7
        }

        $Rows += [PSCustomObject]@{
            Index = ($i + 1)
            Start = (Format-SrtTime -Seconds $Start)
            End   = (Format-SrtTime -Seconds $End)
            Text  = [string]$Lines[$i]
        }
    }

    return $Rows
}

function Read-SrtFileRows {
    param([string]$Path)

    if (-not (Test-SafePath -Path $Path)) {
        return @()
    }

    $Raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($Raw)) { return @() }

    $Normalized = $Raw -replace "`r`n", "`n"
    $Blocks = @($Normalized -split "`n\s*`n")
    $Rows = @()
    $Index = 1

    foreach ($Block in $Blocks) {
        $Lines = @($Block -split "`n" | ForEach-Object { ([string]$_).TrimEnd() })
        if ($Lines.Count -lt 2) { continue }

        $TimeLineIndex = -1
        for ($i = 0; $i -lt $Lines.Count; $i++) {
            if ($Lines[$i] -match '-->') {
                $TimeLineIndex = $i
                break
            }
        }

        if ($TimeLineIndex -lt 0) { continue }

        $TimeLine = $Lines[$TimeLineIndex]
        if ($TimeLine -notmatch '^\s*(.+?)\s*-->\s*(.+?)\s*$') { continue }

        $TextLines = @()
        for ($j = $TimeLineIndex + 1; $j -lt $Lines.Count; $j++) {
            if (-not [string]::IsNullOrWhiteSpace($Lines[$j])) {
                $TextLines += $Lines[$j]
            }
        }

        $Rows += [PSCustomObject]@{
            Index = $Index
            Start = ([string]$Matches[1]).Trim()
            End   = ([string]$Matches[2]).Trim()
            Text  = ($TextLines -join "`n")
        }
        $Index++
    }

    return $Rows
}

function Convert-SubtitleRowsToSrtText {
    param([object[]]$Rows)

    $Lines = New-Object System.Collections.Generic.List[string]
    $Index = 1

    foreach ($Row in $Rows) {
        if ($null -eq $Row) { continue }

        $Texto = [string]$Row.Text
        if ([string]::IsNullOrWhiteSpace($Texto)) { continue }

        $StartSeconds = Parse-SrtTime -Text ([string]$Row.Start)
        $EndSeconds = Parse-SrtTime -Text ([string]$Row.End)

        if ($EndSeconds -le $StartSeconds) {
            $EndSeconds = $StartSeconds + 1.0
        }

        $Lines.Add([string]$Index)
        $Lines.Add((Format-SrtTime -Seconds $StartSeconds) + " --> " + (Format-SrtTime -Seconds $EndSeconds))

        foreach ($TextLine in @($Texto -split "`r?`n")) {
            $Lines.Add([string]$TextLine)
        }

        $Lines.Add("")
        $Index++
    }

    return ($Lines -join [Environment]::NewLine)
}

function Get-SubtitleRowsFromGrid {
    $Rows = @()

    if ($null -eq $GridLegendas) { return $Rows }

    foreach ($GridRow in $GridLegendas.Rows) {
        if ($GridRow.IsNewRow) { continue }

        $Texto = [string]$GridRow.Cells["Texto"].Value
        if ([string]::IsNullOrWhiteSpace($Texto)) { continue }

        $Rows += [PSCustomObject]@{
            Index = [int]$GridRow.Cells["Numero"].Value
            Start = [string]$GridRow.Cells["Inicio"].Value
            End   = [string]$GridRow.Cells["Fim"].Value
            Text  = $Texto
        }
    }

    return $Rows
}

function Fill-SubtitleGrid {
    param([object[]]$Rows)

    if ($null -eq $GridLegendas) { return }

    $GridLegendas.Rows.Clear()
    $Index = 1

    foreach ($Row in $Rows) {
        $RowIndex = $GridLegendas.Rows.Add(
            $Index,
            [string]$Row.Start,
            [string]$Row.End,
            [string]$Row.Text
        )
        $Index++
    }

    $GridLegendas.Refresh()
}



$script:LegPlayer = $null
$script:LegPlayerArquivo = ""
$script:LegLinhasMarcacao = @()
$script:LegMarcacoes = @()
$script:LegIndiceMarcacao = 0

# Relógio de alta resolução para a marcação manual.
# O currentPosition do Windows Media Player pode atualizar em saltos perceptíveis;
# o Stopwatch interpola a posição entre Play/Pause/Seek com precisão de milissegundos.
$script:LegClock = [System.Diagnostics.Stopwatch]::New()
$script:LegClockBaseSeconds = 0.0
$script:LegClockRunning = $false

function Reset-LegendPlaybackClock {
    param([double]$Seconds = 0.0)

    if ($Seconds -lt 0) { $Seconds = 0.0 }
    $script:LegClockBaseSeconds = [double]$Seconds
    try { $script:LegClock.Reset() } catch { }
    $script:LegClockRunning = $false
}

function Start-LegendPlaybackClockFromPlayer {
    $MediaPos = [double]$script:LegClockBaseSeconds
    try {
        if ($null -ne $script:LegPlayer) {
            $MediaPos = [double]$script:LegPlayer.controls.currentPosition
        }
    }
    catch { }

    if ($MediaPos -lt 0) { $MediaPos = 0.0 }
    $script:LegClockBaseSeconds = $MediaPos
    try {
        $script:LegClock.Reset()
        $script:LegClock.Start()
        $script:LegClockRunning = $true
    }
    catch {
        $script:LegClockRunning = $false
    }
}

function Initialize-LegendPlayer {
    if ($null -ne $script:LegPlayer) {
        return $true
    }

    try {
        $script:LegPlayer = New-Object -ComObject WMPlayer.OCX
        $script:LegPlayer.settings.autoStart = $false
        Reset-LegendPlaybackClock -Seconds 0
        return $true
    }
    catch {
        return $false
    }
}

function Set-LegendPlayerFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-SafePath -Path $Path)) {
        return $false
    }

    if (-not (Initialize-LegendPlayer)) {
        return $false
    }

    try {
        if ($script:LegPlayerArquivo -ne $Path) {
            $script:LegPlayer.URL = $Path
            $script:LegPlayerArquivo = $Path
            Start-Sleep -Milliseconds 150
            $script:LegPlayer.controls.stop()
            Reset-LegendPlaybackClock -Seconds 0
        }

        return $true
    }
    catch {
        return $false
    }
}

function Get-LegendPlayerPosition {
    try {
        $Pos = [double]$script:LegClockBaseSeconds
        if ($script:LegClockRunning -and $null -ne $script:LegClock -and $script:LegClock.IsRunning) {
            $Pos += [double]$script:LegClock.Elapsed.TotalSeconds
        }
        if ($Pos -lt 0) { $Pos = 0.0 }
        return $Pos
    }
    catch {
        return 0.0
    }
}

function Set-LegendPlayerPosition {
    param([double]$Seconds)

    try {
        if ($Seconds -lt 0) { $Seconds = 0 }
        $WasRunning = [bool]$script:LegClockRunning

        if ($null -ne $script:LegPlayer) {
            $script:LegPlayer.controls.currentPosition = $Seconds
        }

        $script:LegClockBaseSeconds = [double]$Seconds
        $script:LegClock.Reset()
        if ($WasRunning) {
            $script:LegClock.Start()
            $script:LegClockRunning = $true
        }
        else {
            $script:LegClockRunning = $false
        }
    }
    catch {
    }
}

function Play-SelectedSubtitleAudio {
    $Item = Get-SelectedSubtitleItem
    if ($null -eq $Item) {
        [System.Windows.Forms.MessageBox]::Show("Selecione uma música antes de tocar.", "Legendas", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }

    if (-not (Set-LegendPlayerFile -Path ([string]$Item.FilePath))) {
        [System.Windows.Forms.MessageBox]::Show("Não foi possível tocar o MP3. Verifique se o Windows Media Player está disponível no Windows.", "Legendas", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    try {
        $script:LegPlayer.controls.play()

        for ($i = 0; $i -lt 50; $i++) {
            $State = 0
            try { $State = [int]$script:LegPlayer.playState } catch { }
            if ($State -eq 3) { break }
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 10
        }

        Start-LegendPlaybackClockFromPlayer
    }
    catch {
    }
}

function Pause-SelectedSubtitleAudio {
    try {
        if ($null -ne $script:LegPlayer) {
            $Pos = Get-LegendPlayerPosition
            $script:LegPlayer.controls.pause()
            $script:LegClockBaseSeconds = [double]$Pos
            $script:LegClock.Stop()
            $script:LegClockRunning = $false
        }
    }
    catch {
    }
}

function Stop-SelectedSubtitleAudio {
    try {
        if ($null -ne $script:LegPlayer) {
            $script:LegPlayer.controls.stop()
        }
        Reset-LegendPlaybackClock -Seconds 0
    }
    catch {
    }
}

function Seek-SelectedSubtitleAudio {
    param([double]$OffsetSeconds)

    if ($null -eq $script:LegPlayer) { return }

    $Current = Get-LegendPlayerPosition
    Set-LegendPlayerPosition -Seconds ($Current + $OffsetSeconds)
}

function Sync-LegendClockWithPlayerState {
    if ($null -eq $script:LegPlayer) { return }

    $State = 0
    try { $State = [int]$script:LegPlayer.playState } catch { return }

    if ($State -eq 3) {
        if (-not $script:LegClockRunning) {
            Start-LegendPlaybackClockFromPlayer
        }
        return
    }

    if ($State -in @(1, 2, 8, 10)) {
        if ($script:LegClockRunning) {
            $Pos = Get-LegendPlayerPosition
            $script:LegClockBaseSeconds = [double]$Pos
            try { $script:LegClock.Stop() } catch { }
            $script:LegClockRunning = $false
        }
    }
}

function Update-SubtitleRowFromPlayback {
    if ($null -eq $GridLegendas -or $null -eq $script:LegPlayer) { return }
    if (-not $script:LegClockRunning) { return }

    try {
        if ($GridLegendas.IsCurrentCellInEditMode) { return }
    }
    catch { }

    $State = 0
    try { $State = [int]$script:LegPlayer.playState } catch { return }
    if ($State -ne 3) { return }

    $Pos = Get-LegendPlayerPosition
    $BestRow = $null
    $BestStart = -1.0

    foreach ($Row in $GridLegendas.Rows) {
        if ($Row.IsNewRow) { continue }

        $InicioText = [string]$Row.Cells["Inicio"].Value
        $FimText = [string]$Row.Cells["Fim"].Value
        if ([string]::IsNullOrWhiteSpace($InicioText) -or [string]::IsNullOrWhiteSpace($FimText)) { continue }

        $Inicio = Parse-SrtTime -Text $InicioText
        $Fim = Parse-SrtTime -Text $FimText
        if ($Fim -le $Inicio) { continue }

        if ($Pos -ge $Inicio -and $Pos -lt $Fim -and $Inicio -ge $BestStart) {
            $BestRow = $Row
            $BestStart = $Inicio
        }
    }

    if ($null -eq $BestRow) { return }

    $JaSelecionada = $false
    try {
        $JaSelecionada = ($GridLegendas.CurrentRow -and $GridLegendas.CurrentRow.Index -eq $BestRow.Index -and $BestRow.Selected)
    }
    catch { }

    if (-not $JaSelecionada) {
        try {
            $GridLegendas.ClearSelection()
            $BestRow.Selected = $true
            $GridLegendas.CurrentCell = $BestRow.Cells["Texto"]

            if (-not $BestRow.Displayed) {
                $GridLegendas.FirstDisplayedScrollingRowIndex = [Math]::Max(0, $BestRow.Index - 2)
            }
        }
        catch { }
    }
}

function Update-ManualMarkerStatus {
    if ($null -eq $LabelLegMarcacaoStatus) { return }

    $Selecionada = Get-SelectedSubtitleGridRow

    if ($null -eq $Selecionada) {
        $LabelLegMarcacaoStatus.Text = "Marcação: selecione uma linha na grade. F9 marca o início; F10 marca o fim. Se a grade estiver vazia, a primeira marcação cria uma linha."
        return
    }

    $Numero = [string]$Selecionada.Cells["Numero"].Value
    $Texto = [string]$Selecionada.Cells["Texto"].Value
    if ($Texto.Length -gt 58) { $Texto = $Texto.Substring(0, 55) + "..." }

    $LabelLegMarcacaoStatus.Text = "Linha selecionada $($Numero): marque início e fim do trecho. $Texto"
}

function Renumber-SubtitleGridRows {
    if ($null -eq $GridLegendas) { return }

    $Index = 1
    foreach ($Row in $GridLegendas.Rows) {
        if ($Row.IsNewRow) { continue }
        $Row.Cells["Numero"].Value = $Index
        $Index++
    }
}

function Get-SelectedSubtitleGridRow {
    if ($null -eq $GridLegendas) { return $null }

    if ($GridLegendas.SelectedRows.Count -gt 0) {
        $Row = $GridLegendas.SelectedRows[0]
        if ($null -ne $Row -and -not $Row.IsNewRow) { return $Row }
    }

    if ($GridLegendas.CurrentRow -and -not $GridLegendas.CurrentRow.IsNewRow) {
        return $GridLegendas.CurrentRow
    }

    return $null
}

function Get-SubtitleGridRowCount {
    if ($null -eq $GridLegendas) { return 0 }

    $Count = 0
    foreach ($Row in $GridLegendas.Rows) {
        if (-not $Row.IsNewRow) { $Count++ }
    }

    return $Count
}

function Select-SubtitleGridRowByIndex {
    param(
        [int]$Index,
        [string]$ColumnName = "Texto"
    )

    if ($null -eq $GridLegendas) { return $null }
    if ($Index -lt 0 -or $Index -ge $GridLegendas.Rows.Count) { return $null }
    if ($GridLegendas.Rows[$Index].IsNewRow) { return $null }

    if (-not $GridLegendas.Columns.Contains($ColumnName)) {
        $ColumnName = "Texto"
    }

    $GridLegendas.ClearSelection()
    $GridLegendas.Rows[$Index].Selected = $true
    $GridLegendas.CurrentCell = $GridLegendas.Rows[$Index].Cells[$ColumnName]
    try { $GridLegendas.Focus() | Out-Null } catch { }
    return $GridLegendas.Rows[$Index]
}

function Select-NextSubtitleStartCell {
    param([int]$CurrentIndex)

    if ($null -eq $GridLegendas) { return }

    $NextIndex = $CurrentIndex + 1
    $RealCount = Get-SubtitleGridRowCount

    if ($NextIndex -ge $RealCount) {
        # Cria uma nova linha ao final/abaixo da atual e depois posiciona no Início.
        if ($CurrentIndex -ge 0 -and $CurrentIndex -lt $GridLegendas.Rows.Count -and -not $GridLegendas.Rows[$CurrentIndex].IsNewRow) {
            $GridLegendas.CurrentCell = $GridLegendas.Rows[$CurrentIndex].Cells["Texto"]
        }
        $NewRow = Add-BlankSubtitleGridLine
        if ($null -ne $NewRow) {
            $NextIndex = $NewRow.Index
        }
    }

    Select-SubtitleGridRowByIndex -Index $NextIndex -ColumnName "Inicio" | Out-Null
    try { $GridLegendas.BeginEdit($true) | Out-Null } catch { }
    Update-ManualMarkerStatus
}

function Seek-SubtitleAudioToGridTime {
    param(
        [string]$TimeText,
        [int]$RowIndex = -1
    )

    if ([string]::IsNullOrWhiteSpace($TimeText)) { return }

    $Item = Get-SelectedSubtitleItem
    if ($null -eq $Item) { return }

    $WasPlaying = $false
    try {
        if ($null -ne $script:LegPlayer -and [int]$script:LegPlayer.playState -eq 3) {
            $WasPlaying = $true
        }
    }
    catch { }

    if (-not (Set-LegendPlayerFile -Path ([string]$Item.FilePath))) { return }

    $Seconds = Parse-SrtTime -Text $TimeText
    Set-LegendPlayerPosition -Seconds $Seconds

    if ($RowIndex -ge 0 -and $RowIndex -lt $GridLegendas.Rows.Count -and -not $GridLegendas.Rows[$RowIndex].IsNewRow) {
        $GridLegendas.Rows[$RowIndex].Selected = $true
    }

    if ($WasPlaying) {
        try { $script:LegPlayer.controls.play() } catch { }
    }
}

function Add-BlankSubtitleGridLine {
    $InsertIndex = Get-SubtitleGridRowCount
    if ($GridLegendas.CurrentRow -and -not $GridLegendas.CurrentRow.IsNewRow) {
        $InsertIndex = $GridLegendas.CurrentRow.Index + 1
    }

    $NewRowIndex = $GridLegendas.Rows.Add()

    if ($NewRowIndex -ne $InsertIndex -and $InsertIndex -ge 0 -and $InsertIndex -lt $GridLegendas.Rows.Count) {
        $Values = @(
            $GridLegendas.Rows[$NewRowIndex].Cells["Numero"].Value,
            $GridLegendas.Rows[$NewRowIndex].Cells["Inicio"].Value,
            $GridLegendas.Rows[$NewRowIndex].Cells["Fim"].Value,
            $GridLegendas.Rows[$NewRowIndex].Cells["Texto"].Value
        )
        $GridLegendas.Rows.RemoveAt($NewRowIndex)
        $GridLegendas.Rows.Insert($InsertIndex, $Values)
        $NewRowIndex = $InsertIndex
    }

    $GridLegendas.Rows[$NewRowIndex].Cells["Inicio"].Value = ""
    $GridLegendas.Rows[$NewRowIndex].Cells["Fim"].Value = ""
    $GridLegendas.Rows[$NewRowIndex].Cells["Texto"].Value = ""
    Renumber-SubtitleGridRows
    return (Select-SubtitleGridRowByIndex -Index $NewRowIndex)
}

function Get-OrCreateSelectedSubtitleGridRow {
    param([switch]$CreateWhenEmpty)

    $Row = Get-SelectedSubtitleGridRow
    if ($null -ne $Row) { return $Row }

    if ($CreateWhenEmpty -and (Get-SubtitleGridRowCount) -eq 0) {
        return (Add-BlankSubtitleGridLine)
    }

    return $null
}

function Try-Normalize-SrtTimeText {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }

    # Sempre completa para a direita:
    # 01 -> 01:00:00,000
    # 00:01 -> 00:01:00,000
    # 1:2:3 -> 01:02:03,000
    # 1:2:3,5 -> 01:02:03,500
    $Clean = ([string]$Text).Trim().Replace('.', ',')
    $Clean = $Clean -replace '\s', ''

    if ($Clean -notmatch '^\d+(?::\d{0,2})?(?::\d{0,2}(?:,\d{0,3})?)?$') {
        return $null
    }

    $Parts = @($Clean.Split(':'))
    if ($Parts.Count -lt 1 -or $Parts.Count -gt 3) { return $null }

    $Hours = 0
    $Minutes = 0
    $Seconds = 0
    $Millis = 0

    try {
        if (-not [string]::IsNullOrWhiteSpace($Parts[0])) {
            $Hours = [int]$Parts[0]
        }

        if ($Parts.Count -ge 2 -and -not [string]::IsNullOrWhiteSpace($Parts[1])) {
            $Minutes = [int]$Parts[1]
        }

        if ($Parts.Count -ge 3) {
            $SecPart = [string]$Parts[2]
            if ($SecPart -match '^(\d{0,2})(?:,(\d{0,3}))?$') {
                if (-not [string]::IsNullOrWhiteSpace($Matches[1])) {
                    $Seconds = [int]$Matches[1]
                }

                $MsText = [string]$Matches[2]
                if (-not [string]::IsNullOrWhiteSpace($MsText)) {
                    $MsText = $MsText.PadRight(3, '0').Substring(0, 3)
                    $Millis = [int]$MsText
                }
            }
            else {
                return $null
            }
        }
    }
    catch {
        return $null
    }

    if ($Minutes -lt 0 -or $Minutes -ge 60) { return $null }
    if ($Seconds -lt 0 -or $Seconds -ge 60) { return $null }
    if ($Hours -lt 0) { return $null }

    return ("{0:D2}:{1:D2}:{2:D2},{3:D3}" -f $Hours, $Minutes, $Seconds, $Millis)
}

function Set-SubtitleGridTextCellFromMultilinePaste {
    param([string]$Text)

    if ($null -eq $GridLegendas) { return $false }
    if ([string]::IsNullOrEmpty($Text)) { return $false }

    $NormalizedText = ([string]$Text) -replace "`r`n", "`n"
    $NormalizedText = $NormalizedText -replace "`r", "`n"

    if ($NormalizedText -notmatch "`n") { return $false }

    $Lines = @(
        $NormalizedText -split "`n" |
            ForEach-Object { ([string]$_).Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    if ($Lines.Count -le 1) { return $false }

    # A colagem multilinha só deve agir na coluna Texto.
    if ($GridLegendas.CurrentCell -and $GridLegendas.Columns[$GridLegendas.CurrentCell.ColumnIndex].Name -ne "Texto") {
        return $false
    }

    # Guarda a linha selecionada ANTES de encerrar/cancelar edição, pois o editor ativo pode alterar a seleção.
    $StartIndex = -1
    if ($GridLegendas.CurrentCell -and $GridLegendas.CurrentCell.RowIndex -ge 0) {
        $StartIndex = $GridLegendas.CurrentCell.RowIndex
    }
    elseif ($GridLegendas.CurrentRow -and -not $GridLegendas.CurrentRow.IsNewRow) {
        $StartIndex = $GridLegendas.CurrentRow.Index
    }

    # Se a grade estiver vazia, cria a primeira linha.
    if ($StartIndex -lt 0 -or $StartIndex -ge $GridLegendas.Rows.Count -or $GridLegendas.Rows[$StartIndex].IsNewRow) {
        $StartIndex = $GridLegendas.Rows.Add()
    }

    # Cancela a edição ativa para impedir que o TextBox do DataGridView sobrescreva o conteúdo colado depois.
    try { $GridLegendas.CancelEdit() | Out-Null } catch { }

    # 1) A primeira linha do texto colado entra exatamente na linha onde o usuário colou.
    $GridLegendas.Rows[$StartIndex].Cells["Inicio"].Value = [string]$GridLegendas.Rows[$StartIndex].Cells["Inicio"].Value
    $GridLegendas.Rows[$StartIndex].Cells["Fim"].Value = [string]$GridLegendas.Rows[$StartIndex].Cells["Fim"].Value
    $GridLegendas.Rows[$StartIndex].Cells["Texto"].Value = [string]$Lines[0]

    # 2) Cada linha restante é inserida abaixo, na mesma ordem, no campo Texto.
    for ($i = 1; $i -lt $Lines.Count; $i++) {
        $InsertIndex = $StartIndex + $i
        if ($InsertIndex -gt $GridLegendas.Rows.Count) {
            $InsertIndex = $GridLegendas.Rows.Count
        }

        # Insere a linha já com 4 células: Numero, Inicio, Fim, Texto.
        $GridLegendas.Rows.Insert($InsertIndex, @("", "", "", [string]$Lines[$i]))
    }

    Renumber-SubtitleGridRows
    Select-SubtitleGridRowByIndex -Index $StartIndex | Out-Null
    Update-ManualMarkerStatus
    $GridLegendas.Refresh()

    return $true
}

function Paste-MultilineTextIntoSubtitleGrid {
    try {
        if (-not [System.Windows.Forms.Clipboard]::ContainsText()) { return $false }
        $ClipboardText = [System.Windows.Forms.Clipboard]::GetText()
        return (Set-SubtitleGridTextCellFromMultilinePaste -Text $ClipboardText)
    }
    catch {
        return $false
    }
}

function Ensure-SubtitleGridFromLyrics {
    if ($null -eq $GridLegendas) { return }

    $HasRows = $false
    foreach ($Row in $GridLegendas.Rows) {
        if (-not $Row.IsNewRow) { $HasRows = $true; break }
    }

    if ($HasRows) { return }

    $Lines = @(Get-LyricsLinesFromText -Text $TextLegLetra.Text)
    if ($Lines.Count -le 0) { return }

    $Rows = @()
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $Rows += [PSCustomObject]@{
            Index = ($i + 1)
            Start = ""
            End   = ""
            Text  = [string]$Lines[$i]
        }
    }

    Fill-SubtitleGrid -Rows $Rows
}

function Add-SubtitleGridLine {
    Ensure-SubtitleGridFromLyrics

    $Row = Add-BlankSubtitleGridLine
    if ($null -ne $Row) {
        Update-ManualMarkerStatus
    }
}

function Remove-SelectedSubtitleGridLine {
    $Row = Get-SelectedSubtitleGridRow
    if ($null -eq $Row) { return }

    $Index = $Row.Index
    $GridLegendas.Rows.Remove($Row)
    Renumber-SubtitleGridRows

    $Count = 0
    foreach ($R in $GridLegendas.Rows) { if (-not $R.IsNewRow) { $Count++ } }

    if ($Count -gt 0) {
        $NewIndex = [Math]::Min($Index, $Count - 1)
        $GridLegendas.ClearSelection()
        $GridLegendas.Rows[$NewIndex].Selected = $true
        $GridLegendas.CurrentCell = $GridLegendas.Rows[$NewIndex].Cells["Texto"]
    }

    Update-ManualMarkerStatus
}

function Set-SelectedSubtitleLineStart {
    $Row = Get-OrCreateSelectedSubtitleGridRow -CreateWhenEmpty
    if ($null -eq $Row) {
        [System.Windows.Forms.MessageBox]::Show("Selecione uma linha para marcar o início do trecho.", "Legendas", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }

    $Pos = Get-LegendPlayerPosition
    $Row.Cells["Inicio"].Value = Format-SrtTime -Seconds $Pos

    $FimAtual = [string]$Row.Cells["Fim"].Value
    if (-not [string]::IsNullOrWhiteSpace($FimAtual)) {
        $FimSeg = Parse-SrtTime -Text $FimAtual
        if ($FimSeg -le $Pos) {
            $Row.Cells["Fim"].Value = Format-SrtTime -Seconds ($Pos + 0.5)
        }
    }

    Update-ManualMarkerStatus
}

function Set-SelectedSubtitleLineEnd {
    $Row = Get-OrCreateSelectedSubtitleGridRow -CreateWhenEmpty
    if ($null -eq $Row) {
        [System.Windows.Forms.MessageBox]::Show("Selecione uma linha para marcar o fim do trecho.", "Legendas", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }

    $Pos = Get-LegendPlayerPosition
    $InicioAtual = [string]$Row.Cells["Inicio"].Value
    $InicioSeg = 0.0

    if ([string]::IsNullOrWhiteSpace($InicioAtual)) {
        $InicioSeg = 0.0
        $Row.Cells["Inicio"].Value = Format-SrtTime -Seconds $InicioSeg
    }
    else {
        $InicioSeg = Parse-SrtTime -Text $InicioAtual
    }

    if ($Pos -le $InicioSeg) { $Pos = $InicioSeg + 0.5 }

    $Row.Cells["Fim"].Value = Format-SrtTime -Seconds $Pos
    $CurrentIndex = $Row.Index
    Update-ManualMarkerStatus
    Select-NextSubtitleStartCell -CurrentIndex $CurrentIndex
}

function Update-SubtitleGridFromManualMarks {
    $Item = Get-SelectedSubtitleItem
    $Duration = 0.0
    if ($null -ne $Item) { $Duration = [double]$Item.Duration }

    $Rows = @()

    for ($i = 0; $i -lt $script:LegMarcacoes.Count; $i++) {
        $Start = [double]$script:LegMarcacoes[$i]
        if ($i -lt ($script:LegMarcacoes.Count - 1)) {
            $End = [double]$script:LegMarcacoes[$i + 1] - 0.15
        }
        elseif ($Duration -gt $Start) {
            $End = $Duration
        }
        else {
            $End = $Start + 3.0
        }

        if ($End -le $Start) {
            $End = $Start + 0.5
        }

        $Rows += [PSCustomObject]@{
            Index = ($i + 1)
            Start = (Format-SrtTime -Seconds $Start)
            End   = (Format-SrtTime -Seconds $End)
            Text  = [string]$script:LegLinhasMarcacao[$i]
        }
    }

    Fill-SubtitleGrid -Rows $Rows
    Update-ManualMarkerStatus
}

function Prepare-ManualSubtitleMarking {
    $Item = Get-SelectedSubtitleItem
    if ($null -eq $Item) {
        [System.Windows.Forms.MessageBox]::Show("Selecione uma música antes de preparar a marcação.", "Legendas", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }

    $Lines = @(Get-LyricsLinesFromText -Text $TextLegLetra.Text)
    if ($Lines.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Digite ou importe a letra primeiro.", "Legendas", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }

    $script:LegLinhasMarcacao = $Lines
    $script:LegMarcacoes = @()
    $script:LegIndiceMarcacao = 0
    $GridLegendas.Rows.Clear()

    if (-not (Set-LegendPlayerFile -Path ([string]$Item.FilePath))) {
        [System.Windows.Forms.MessageBox]::Show("Não foi possível preparar o player do MP3. Você ainda pode editar os tempos manualmente na grade.", "Legendas", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    }

    Update-ManualMarkerStatus
}

function Mark-NextSubtitleLine {
    if ($null -eq $script:LegLinhasMarcacao -or $script:LegLinhasMarcacao.Count -eq 0) {
        Prepare-ManualSubtitleMarking
        if ($null -eq $script:LegLinhasMarcacao -or $script:LegLinhasMarcacao.Count -eq 0) { return }
    }

    if ($script:LegIndiceMarcacao -ge $script:LegLinhasMarcacao.Count) {
        [System.Windows.Forms.MessageBox]::Show("Todas as linhas já foram marcadas.", "Legendas", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }

    $Pos = Get-LegendPlayerPosition

    if ($script:LegMarcacoes.Count -gt 0) {
        $Ultima = [double]$script:LegMarcacoes[$script:LegMarcacoes.Count - 1]
        if ($Pos -lt $Ultima) {
            $Pos = $Ultima + 0.10
        }
    }

    $script:LegMarcacoes += [double]$Pos
    $script:LegIndiceMarcacao++

    Update-SubtitleGridFromManualMarks
}

function Undo-LastSubtitleMark {
    $Row = Get-SelectedSubtitleGridRow
    if ($null -eq $Row) { return }

    $Row.Cells["Inicio"].Value = ""
    $Row.Cells["Fim"].Value = ""
    Update-ManualMarkerStatus
}

function Get-SelectedSubtitleItem {
    if ($null -eq $ComboLegMusica -or $null -eq $ComboLegMusica.SelectedItem) {
        return $null
    }

    return $ComboLegMusica.SelectedItem
}

function Resolve-CoverPathForSubtitleItem {
    param([object]$Item)

    if ($null -eq $Item) { return "" }

    $ResolveImagePathValue = {
        param(
            [string]$PathValue,
            [string]$AlbumName
        )

        if ([string]::IsNullOrWhiteSpace($PathValue)) { return "" }
        $Value = [string]$PathValue
        if ($Value -eq "SEM IMAGEM") { return "" }

        try {
            if (Test-SafePath -Path $Value) { return $Value }
        } catch { }

        $Leaf = ""
        try { $Leaf = [System.IO.Path]::GetFileName($Value) } catch { $Leaf = $Value }
        if ([string]::IsNullOrWhiteSpace($Leaf) -or $Leaf -eq "SEM IMAGEM") { return "" }

        $CandidateDirs = New-Object System.Collections.Generic.List[string]
        try {
            if (-not [string]::IsNullOrWhiteSpace([string]$Item.FilePath)) {
                $CandidateDirs.Add((Split-SafeParent -Path ([string]$Item.FilePath))) | Out-Null
            }
        } catch { }
        try {
            if (-not [string]::IsNullOrWhiteSpace([string]$TextPastaMP3.Text)) {
                $CandidateDirs.Add([string]$TextPastaMP3.Text) | Out-Null
                if (-not [string]::IsNullOrWhiteSpace($AlbumName)) {
                    $CandidateDirs.Add((Join-SafePath ([string]$TextPastaMP3.Text) $AlbumName)) | Out-Null
                }
            }
        } catch { }
        try { $CandidateDirs.Add([string]$script:AppRoot) | Out-Null } catch { }
        try {
            if (-not [string]::IsNullOrWhiteSpace([string]$TextPastaVideo.Text)) {
                $CandidateDirs.Add([string]$TextPastaVideo.Text) | Out-Null
                if (-not [string]::IsNullOrWhiteSpace($AlbumName)) {
                    $CandidateDirs.Add((Join-SafePath ([string]$TextPastaVideo.Text) $AlbumName)) | Out-Null
                }
            }
        } catch { }

        foreach ($Dir in @($CandidateDirs | Select-Object -Unique)) {
            if ([string]::IsNullOrWhiteSpace($Dir)) { continue }
            try {
                $CandidatePath = Join-SafePath $Dir $Leaf
                if (Test-SafePath -Path $CandidatePath) { return $CandidatePath }
            } catch { }
        }

        # Último recurso: procura pelo nome do arquivo dentro da pasta de MP3 e da pasta do APP.
        # Isso corrige casos em que a grade mostra apenas "frezza - capa.png" em vez do caminho completo.
        $SearchRoots = New-Object System.Collections.Generic.List[string]
        try { if (-not [string]::IsNullOrWhiteSpace([string]$TextPastaMP3.Text)) { $SearchRoots.Add([string]$TextPastaMP3.Text) | Out-Null; $SearchRoots.Add((Split-SafeParent -Path ([string]$TextPastaMP3.Text))) | Out-Null } } catch { }
        try { if (-not [string]::IsNullOrWhiteSpace([string]$script:AppRoot)) { $SearchRoots.Add([string]$script:AppRoot) | Out-Null; $SearchRoots.Add((Split-SafeParent -Path ([string]$script:AppRoot))) | Out-Null } } catch { }
        try { if (-not [string]::IsNullOrWhiteSpace([string]$TextPastaVideo.Text)) { $SearchRoots.Add([string]$TextPastaVideo.Text) | Out-Null; $SearchRoots.Add((Split-SafeParent -Path ([string]$TextPastaVideo.Text))) | Out-Null } } catch { }

        foreach ($Root in @($SearchRoots | Select-Object -Unique)) {
            if ([string]::IsNullOrWhiteSpace($Root) -or -not (Test-SafePath -Path $Root)) { continue }
            try {
                $Found = Get-ChildItem -LiteralPath $Root -Filter $Leaf -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($null -ne $Found) { return [string]$Found.FullName }
            } catch { }
        }

        return ""
    }

    $ApplyCoverToSubtitleItem = {
        param([string]$Path)
        if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
        $ResolvedPath = & $ResolveImagePathValue $Path $ItemAlbum
        if ([string]::IsNullOrWhiteSpace($ResolvedPath)) { return "" }
        if (-not (Test-SafePath -Path $ResolvedPath)) { return "" }
        try {
            if ($null -eq $Item.PSObject.Properties["CoverPath"]) {
                $Item | Add-Member -MemberType NoteProperty -Name CoverPath -Value $ResolvedPath -Force
            }
            else {
                $Item.CoverPath = $ResolvedPath
            }
        } catch { }
        return $ResolvedPath
    }

    $ItemFilePath = ""
    $ItemAlbum = ""
    $ItemBaseName = ""
    $ItemName = ""
    try { $ItemFilePath = [string]$Item.FilePath } catch { }
    try { $ItemAlbum = [string]$Item.Album } catch { }
    try { $ItemBaseName = [string]$Item.BaseName } catch { }
    try { $ItemName = [string]$Item.Name } catch { }
    if ([string]::IsNullOrWhiteSpace($ItemName)) { $ItemName = $ItemBaseName }

    # 0) Usa o mapa de imagens escolhidas na aba Músicas quando disponível.
    # Esse mapa corrige o caso em que a grade exibe a imagem escolhida, mas o item de Legendas não recebeu CoverPath.
    try {
        if ($null -ne $script:CoverPathByMusicKey) {
            $Keys = New-Object System.Collections.Generic.List[string]
            if (-not [string]::IsNullOrWhiteSpace($ItemFilePath)) { $Keys.Add("PATH|" + $ItemFilePath.ToLowerInvariant()) | Out-Null }
            if (-not [string]::IsNullOrWhiteSpace($ItemAlbum) -and -not [string]::IsNullOrWhiteSpace($ItemName)) { $Keys.Add("ALBUMNAME|" + $ItemAlbum.ToLowerInvariant() + "|" + $ItemName.ToLowerInvariant()) | Out-Null }
            if (-not [string]::IsNullOrWhiteSpace($ItemAlbum) -and -not [string]::IsNullOrWhiteSpace($ItemBaseName)) { $Keys.Add("ALBUMNAME|" + $ItemAlbum.ToLowerInvariant() + "|" + $ItemBaseName.ToLowerInvariant()) | Out-Null }

            foreach ($K in @($Keys | Select-Object -Unique)) {
                if ($script:CoverPathByMusicKey.ContainsKey($K)) {
                    $MappedCover = [string]$script:CoverPathByMusicKey[$K]
                    $Resolved = & $ApplyCoverToSubtitleItem $MappedCover
                    if (-not [string]::IsNullOrWhiteSpace($Resolved)) { return $Resolved }
                }
            }
        }
    } catch { }

    # 1) Se o próprio item de Legendas já tiver imagem válida, usa diretamente.
    try {
        $DirectCover = [string]$Item.CoverPath
        $Resolved = & $ApplyCoverToSubtitleItem $DirectCover
        if (-not [string]::IsNullOrWhiteSpace($Resolved)) { return $Resolved }
    } catch { }

    $GetCandidateFilePath = {
        param([object]$Candidate)
        $CandidateFilePath = ""
        try { $CandidateFilePath = [string]$Candidate.FilePath } catch { }
        if ([string]::IsNullOrWhiteSpace($CandidateFilePath)) {
            try {
                if ($null -ne $Candidate.MusicFile) {
                    $CandidateFilePath = [string]$Candidate.MusicFile.FullName
                }
            } catch { }
        }
        return $CandidateFilePath
    }

    $GetCandidateName = {
        param([object]$Candidate)
        $CandidateName = ""
        try { $CandidateName = [string]$Candidate.BaseName } catch { }
        if ([string]::IsNullOrWhiteSpace($CandidateName)) {
            try { $CandidateName = [string]$Candidate.Name } catch { }
        }
        if ([string]::IsNullOrWhiteSpace($CandidateName)) {
            try {
                if ($null -ne $Candidate.MusicFile) {
                    $CandidateName = [string]$Candidate.MusicFile.BaseName
                }
            } catch { }
        }
        return $CandidateName
    }

    $GetCandidateAlbum = {
        param([object]$Candidate)
        $CandidateAlbum = ""
        try { $CandidateAlbum = [string]$Candidate.Album } catch { }
        return $CandidateAlbum
    }

    $GetCandidateType = {
        param([object]$Candidate)
        $CandidateType = ""
        try { $CandidateType = [string]$Candidate.Type } catch { }
        return $CandidateType
    }

    $GetCandidateCover = {
        param([object]$Candidate)
        $CandidateCover = ""
        try { $CandidateCover = [string]$Candidate.CoverPath } catch { }
        return $CandidateCover
    }

    $MatchesSameItem = {
        param([object]$Candidate)
        if ($null -eq $Candidate) { return $false }

        $CandidateType = & $GetCandidateType $Candidate
        if (-not [string]::IsNullOrWhiteSpace($CandidateType) -and $CandidateType -ne "Música") { return $false }

        $CandidateFilePath = & $GetCandidateFilePath $Candidate
        $CandidateAlbum = & $GetCandidateAlbum $Candidate
        $CandidateName = & $GetCandidateName $Candidate

        # Melhor correspondência: caminho absoluto do MP3.
        if (-not [string]::IsNullOrWhiteSpace($ItemFilePath) -and -not [string]::IsNullOrWhiteSpace($CandidateFilePath)) {
            if ($CandidateFilePath.Equals($ItemFilePath, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        }

        # Fallback: álbum + nome/base name. A aba Músicas usa Name; a aba Legendas costuma usar BaseName.
        if (-not [string]::IsNullOrWhiteSpace($ItemAlbum) -and -not [string]::IsNullOrWhiteSpace($ItemName) -and -not [string]::IsNullOrWhiteSpace($CandidateAlbum) -and -not [string]::IsNullOrWhiteSpace($CandidateName)) {
            if ($CandidateAlbum.Equals($ItemAlbum, [System.StringComparison]::OrdinalIgnoreCase) -and $CandidateName.Equals($ItemName, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        }

        return $false
    }

    # 2) Procura primeiro nas linhas atuais da grade Músicas, pois elas refletem a imagem escolhida no botão "Escolher...".
    try {
        if ($null -ne $GridMusicas) {
            foreach ($Row in @($GridMusicas.Rows)) {
                if ($null -eq $Row -or $Row.IsNewRow) { continue }
                $Candidate = $Row.Tag

                $RowAlbum = ""
                $RowName = ""
                $RowCoverText = ""
                try { $RowAlbum = [string]$Row.Cells["Album"].Value } catch { }
                try { $RowName = [string]$Row.Cells["Nome"].Value } catch { }
                try { $RowCoverText = [string]$Row.Cells["ArquivoImagem"].Value } catch { }

                $RowMatches = $false
                if (& $MatchesSameItem $Candidate) { $RowMatches = $true }
                elseif (-not [string]::IsNullOrWhiteSpace($ItemAlbum) -and -not [string]::IsNullOrWhiteSpace($ItemName) -and -not [string]::IsNullOrWhiteSpace($RowAlbum) -and -not [string]::IsNullOrWhiteSpace($RowName)) {
                    if ($RowAlbum.Equals($ItemAlbum, [System.StringComparison]::OrdinalIgnoreCase) -and $RowName.Equals($ItemName, [System.StringComparison]::OrdinalIgnoreCase)) { $RowMatches = $true }
                }

                if ($RowMatches) {
                    $CandidateCover = & $GetCandidateCover $Candidate
                    $Resolved = & $ApplyCoverToSubtitleItem $CandidateCover
                    if (-not [string]::IsNullOrWhiteSpace($Resolved)) { return $Resolved }

                    $Resolved = & $ApplyCoverToSubtitleItem $RowCoverText
                    if (-not [string]::IsNullOrWhiteSpace($Resolved)) { return $Resolved }
                }
            }
        }
    } catch { }

    # 3) Procura no conjunto escaneado pela primeira aba.
    try {
        if ($null -ne $script:ItensEscaneados) {
            foreach ($Candidate in @($script:ItensEscaneados)) {
                if (& $MatchesSameItem $Candidate) {
                    $CandidateCover = & $GetCandidateCover $Candidate
                    $Resolved = & $ApplyCoverToSubtitleItem $CandidateCover
                    if (-not [string]::IsNullOrWhiteSpace($Resolved)) { return $Resolved }
                }
            }
        }
    } catch { }

    return ""
}

function Get-SubtitleSrtPathForItem {
    param([object]$Item)

    if ($null -eq $Item) { return "" }

    $Root = [string]$TextLegPastaLegendas.Text
    if ([string]::IsNullOrWhiteSpace($Root)) { return "" }

    $Dir = Join-SafePath $Root ([string]$Item.Album)
    $LangCode = Get-SubtitleLanguageCodeForFileName -Item $Item
    if ([string]::IsNullOrWhiteSpace($LangCode)) { $LangCode = "en" }
    return (Join-SafePath $Dir (([string]$Item.BaseName) + ".$LangCode.srt"))
}

function Get-SubtitleMusicItems {
    param(
        [string]$PastaMP3,
        [string]$PastaLegendas,
        [string]$ModoLeitura,
        [string]$FfprobePath
    )

    $Items = @()

    if (-not (Test-SafePath -Path $PastaMP3)) {
        return $Items
    }

    $UsarRaiz = $false
    $UsarSubpastas = $false

    switch ($ModoLeitura) {
        "Pasta selecionada é um álbum único" { $UsarRaiz = $true; $UsarSubpastas = $false }
        "Cada subpasta é um álbum" { $UsarRaiz = $false; $UsarSubpastas = $true }
        default {
            $UsarRaiz = @(Get-ChildItem -LiteralPath $PastaMP3 -Filter "*.mp3" -File -ErrorAction SilentlyContinue).Count -gt 0
            $UsarSubpastas = @(Get-ChildItem -LiteralPath $PastaMP3 -Directory -ErrorAction SilentlyContinue).Count -gt 0
        }
    }

    $Folders = @()

    if ($UsarRaiz) {
        $Folders += [PSCustomObject]@{
            Album = Split-SafeLeaf -Path ($PastaMP3.TrimEnd('\', '/'))
            Path  = $PastaMP3
        }
    }

    if ($UsarSubpastas) {
        foreach ($Sub in @(Get-ChildItem -LiteralPath $PastaMP3 -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $Folders += [PSCustomObject]@{
                Album = [string]$Sub.Name
                Path  = [string]$Sub.FullName
            }
        }
    }

    foreach ($Folder in $Folders) {
        foreach ($Mp3 in @(Get-ChildItem -LiteralPath $Folder.Path -Filter "*.mp3" -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $Duration = 0.0
            if (-not [string]::IsNullOrWhiteSpace($FfprobePath)) {
                $D = Get-MediaDuration -Arquivo $Mp3.FullName -FfprobePath $FfprobePath
                if ($null -ne $D) { $Duration = [double]$D }
            }

            $SrtDir = Join-SafePath $PastaLegendas ([string]$Folder.Album)
            $SrtPath = Join-SafePath $SrtDir ($Mp3.BaseName + "." + (Get-DefaultSubtitleLanguageCode) + ".srt")
            $LegacySrtPath = Join-SafePath $SrtDir ($Mp3.BaseName + ".srt")
            $HasSrt = (Test-SafePath -Path $SrtPath) -or (Test-SafePath -Path $LegacySrtPath) -or (@(Get-ChildItem -LiteralPath $SrtDir -File -Filter ($Mp3.BaseName + ".*.srt") -ErrorAction SilentlyContinue).Count -gt 0)
            $Status = if ($HasSrt) { "SRT existente" } else { "Sem SRT" }
            $Items += [PSCustomObject]@{
                Album       = [string]$Folder.Album
                Title       = (Remove-TrackNumberPrefix -Title $Mp3.BaseName)
                BaseName    = [string]$Mp3.BaseName
                FilePath    = [string]$Mp3.FullName
                Duration    = [double]$Duration
                SrtPath     = [string]$SrtPath
                Status      = [string]$Status
                DisplayName = "[$($Folder.Album)] $($Mp3.BaseName)"
            }
        }
    }

    return @($Items | Sort-Object Album, BaseName)
}


function New-SubtitleMusicItemFromMp3 {
    param(
        [string]$Mp3Path,
        [string]$AlbumName,
        [string]$PastaLegendas,
        [string]$FfprobePath
    )

    if (-not (Test-SafePath -Path $Mp3Path)) { return $null }

    $Mp3 = Get-Item -LiteralPath $Mp3Path -ErrorAction SilentlyContinue
    if ($null -eq $Mp3) { return $null }

    if ([string]::IsNullOrWhiteSpace($AlbumName)) {
        if ($null -ne $Mp3.Directory -and -not [string]::IsNullOrWhiteSpace($Mp3.Directory.Name)) {
            $AlbumName = [string]$Mp3.Directory.Name
        }
        else {
            $AlbumName = "Músicas avulsas"
        }
    }

    $Duration = 0.0
    if (-not [string]::IsNullOrWhiteSpace($FfprobePath)) {
        $D = Get-MediaDuration -Arquivo $Mp3.FullName -FfprobePath $FfprobePath
        if ($null -ne $D) { $Duration = [double]$D }
    }

    if ([string]::IsNullOrWhiteSpace($PastaLegendas)) {
        $PastaLegendas = Get-AutoSubtitlePath -PastaMP3 $TextPastaMP3.Text
    }

    $SrtDir = Join-SafePath $PastaLegendas $AlbumName
    $SrtPath = Join-SafePath $SrtDir ($Mp3.BaseName + "." + (Get-DefaultSubtitleLanguageCode) + ".srt")
    $LegacySrtPath = Join-SafePath $SrtDir ($Mp3.BaseName + ".srt")
    $HasSrt = (Test-SafePath -Path $SrtPath) -or (Test-SafePath -Path $LegacySrtPath) -or (@(Get-ChildItem -LiteralPath $SrtDir -File -Filter ($Mp3.BaseName + ".*.srt") -ErrorAction SilentlyContinue).Count -gt 0)
    $Status = if ($HasSrt) { "SRT existente" } else { "Sem SRT" }

    return [PSCustomObject]@{
        Album       = [string]$AlbumName
        Title       = (Remove-TrackNumberPrefix -Title $Mp3.BaseName)
        BaseName    = [string]$Mp3.BaseName
        FilePath    = [string]$Mp3.FullName
        Duration    = [double]$Duration
        SrtPath     = [string]$SrtPath
        Status      = [string]$Status
        DisplayName = "[$AlbumName] $($Mp3.BaseName)"
    }
}

function Add-DirectSubtitleMusicFile {
    param([string]$Mp3Path)

    if ([string]::IsNullOrWhiteSpace($Mp3Path) -or -not (Test-SafePath -Path $Mp3Path)) {
        return
    }

    if ([string]::IsNullOrWhiteSpace($TextLegPastaLegendas.Text)) {
        $TextLegPastaLegendas.Text = Get-AutoSubtitlePath -PastaMP3 $TextPastaMP3.Text
        $TextPastaLegendas.Text = $TextLegPastaLegendas.Text
    }

    $FfprobePath = Resolve-Executable "ffprobe.exe"
    if (-not $FfprobePath) { $FfprobePath = Resolve-Executable "ffprobe" }

    $AlbumName = $null
    try {
        $Mp3Item = Get-Item -LiteralPath $Mp3Path -ErrorAction Stop
        $PastaBase = [string]$TextPastaMP3.Text
        $DirName = if ($Mp3Item.Directory) { [string]$Mp3Item.Directory.FullName } else { "" }

        if (-not [string]::IsNullOrWhiteSpace($PastaBase) -and -not [string]::IsNullOrWhiteSpace($DirName)) {
            $BaseFull = [System.IO.Path]::GetFullPath($PastaBase).TrimEnd('\', '/')
            $DirFull = [System.IO.Path]::GetFullPath($DirName).TrimEnd('\', '/')
            if ($DirFull.Equals($BaseFull, [System.StringComparison]::OrdinalIgnoreCase)) {
                $AlbumName = Split-SafeLeaf -Path $BaseFull
            }
            else {
                $AlbumName = $Mp3Item.Directory.Name
            }
        }
        elseif ($Mp3Item.Directory) {
            $AlbumName = $Mp3Item.Directory.Name
        }
    }
    catch { }

    $Item = New-SubtitleMusicItemFromMp3 `
        -Mp3Path $Mp3Path `
        -AlbumName $AlbumName `
        -PastaLegendas $TextLegPastaLegendas.Text `
        -FfprobePath $FfprobePath

    if ($null -eq $Item) { return }

    if ($null -eq $script:ItensLegenda) { $script:ItensLegenda = @() }

    $Existing = $script:ItensLegenda | Where-Object { ([string]$_.FilePath).Equals([string]$Item.FilePath, [System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
    if ($null -eq $Existing) {
        $script:ItensLegenda = @($script:ItensLegenda + $Item | Sort-Object Album, BaseName)
    }
    else {
        $Item = $Existing
    }

    if ($null -ne $ComboLegMusica) {
        $ComboLegMusica.Items.Clear()
        foreach ($LegendaItem in $script:ItensLegenda) { [void]$ComboLegMusica.Items.Add($LegendaItem) }
        $ComboLegMusica.DisplayMember = "DisplayName"
    }

    if ($null -ne $ComboSepMusica) {
        $ComboSepMusica.Items.Clear()
        foreach ($LegendaItem in $script:ItensLegenda) { [void]$ComboSepMusica.Items.Add($LegendaItem) }
        $ComboSepMusica.DisplayMember = "DisplayName"
    }

    if ($null -ne $ComboLegAlbum) {
        $CurrentAlbum = if ($ComboLegAlbum.SelectedItem) { [string]$ComboLegAlbum.SelectedItem } else { "" }
        $ComboLegAlbum.Items.Clear()
        foreach ($Album in @($script:ItensLegenda | Select-Object -ExpandProperty Album -Unique | Sort-Object)) {
            [void]$ComboLegAlbum.Items.Add([string]$Album)
        }
        if ($ComboLegAlbum.Items.Contains($CurrentAlbum)) { $ComboLegAlbum.SelectedItem = $CurrentAlbum }
        elseif ($ComboLegAlbum.Items.Count -gt 0) { $ComboLegAlbum.SelectedIndex = 0 }
    }

    if ($null -ne $ComboLegMusica) {
        for ($i = 0; $i -lt $ComboLegMusica.Items.Count; $i++) {
            if (([string]$ComboLegMusica.Items[$i].FilePath).Equals([string]$Item.FilePath, [System.StringComparison]::OrdinalIgnoreCase)) {
                $ComboLegMusica.SelectedIndex = $i
                break
            }
        }
    }

    if ($null -ne $ComboSepMusica) {
        for ($i = 0; $i -lt $ComboSepMusica.Items.Count; $i++) {
            if (([string]$ComboSepMusica.Items[$i].FilePath).Equals([string]$Item.FilePath, [System.StringComparison]::OrdinalIgnoreCase)) {
                $ComboSepMusica.SelectedIndex = $i
                break
            }
        }
    }

    if ($null -ne $LabelLegStatus) { $LabelLegStatus.Text = "Músicas encontradas: $($script:ItensLegenda.Count)" }
    if ($null -ne $LabelSepStatus) { $LabelSepStatus.Text = "Músicas: $($script:ItensLegenda.Count)" }

    Load-SelectedSubtitleInfo
    if (Get-Command Load-SelectedSeparateAudioInfo -ErrorAction SilentlyContinue) { Load-SelectedSeparateAudioInfo }
}

function Refresh-SubtitleMusicList {
    if ($null -eq $ComboLegMusica) { return }

    $FfprobePath = Resolve-Executable "ffprobe.exe"
    if (-not $FfprobePath) { $FfprobePath = Resolve-Executable "ffprobe" }

    $script:ItensLegenda = @(Get-SubtitleMusicItems `
        -PastaMP3 $TextPastaMP3.Text `
        -PastaLegendas $TextLegPastaLegendas.Text `
        -ModoLeitura ([string]$ComboModoLeitura.SelectedItem) `
        -FfprobePath $FfprobePath)

    $ComboLegMusica.Items.Clear()
    $ComboLegAlbum.Items.Clear()
    if ($null -ne $ComboSepMusica) { $ComboSepMusica.Items.Clear() }

    foreach ($Item in $script:ItensLegenda) {
        [void]$ComboLegMusica.Items.Add($Item)
        if ($null -ne $ComboSepMusica) { [void]$ComboSepMusica.Items.Add($Item) }
    }

    $Albums = @($script:ItensLegenda | Select-Object -ExpandProperty Album -Unique | Sort-Object)
    foreach ($Album in $Albums) {
        [void]$ComboLegAlbum.Items.Add([string]$Album)
    }

    $ComboLegMusica.DisplayMember = "DisplayName"
    if ($null -ne $ComboSepMusica) { $ComboSepMusica.DisplayMember = "DisplayName" }

    if ($ComboLegMusica.Items.Count -gt 0) {
        $ComboLegMusica.SelectedIndex = 0
    }

    if ($null -ne $ComboSepMusica -and $ComboSepMusica.Items.Count -gt 0) {
        $ComboSepMusica.SelectedIndex = 0
    }

    if ($ComboLegAlbum.Items.Count -gt 0) {
        $ComboLegAlbum.SelectedIndex = 0
    }

    $LabelLegStatus.Text = "Músicas encontradas: $($script:ItensLegenda.Count)"
    if ($null -ne $LabelSepStatus) { $LabelSepStatus.Text = "Músicas: $($script:ItensLegenda.Count)" }
}

function Get-SubtitleFilesForItem {
    param([object]$Item)
    if ($null -eq $Item) { return @() }
    $Root=[string]$TextLegPastaLegendas.Text; if ([string]::IsNullOrWhiteSpace($Root)) { return @() }
    $Dir=Join-SafePath $Root ([string]$Item.Album); if (-not (Test-SafePath -Path $Dir)) { return @() }
    $Files=@(Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq ($Item.BaseName + '.srt') -or $_.Name -like ($Item.BaseName + '.*.srt') } | Sort-Object Name)
    return $Files
}

function Refresh-SubtitleFileChoices {
    param([object]$Item)
    if ($null -eq $TextLegArquivoSrt) { return }
    $Old=''; try { $Old=[string]$TextLegArquivoSrt.Text } catch { }
    try { $TextLegArquivoSrt.Items.Clear() } catch { return }
    $Files=@(Get-SubtitleFilesForItem -Item $Item)
    foreach($F in $Files){ [void]$TextLegArquivoSrt.Items.Add([string]$F.FullName) }
    if ($Files.Count -eq 0) { [void]$TextLegArquivoSrt.Items.Add((Get-SubtitleSrtPathForItem -Item $Item)) }
    $idx=0
    for($i=0;$i -lt $TextLegArquivoSrt.Items.Count;$i++){ if(([string]$TextLegArquivoSrt.Items[$i]).Equals($Old,[System.StringComparison]::OrdinalIgnoreCase)){ $idx=$i; break } }
    if($TextLegArquivoSrt.Items.Count -gt 0){ $TextLegArquivoSrt.SelectedIndex=$idx }
}

function Load-SelectedSubtitleInfo {
    $Item = Get-SelectedSubtitleItem
    if ($null -eq $Item) { return }

    $TextLegArquivoMP3.Text = [string]$Item.FilePath
    Refresh-SubtitleFileChoices -Item $Item
    $LabelLegDuracao.Text = "Duração: " + (Format-Duration ([double]$Item.Duration))
    Set-LegendPlayerFile -Path ([string]$Item.FilePath) | Out-Null
    Update-ManualMarkerStatus
}

function Save-SubtitleGridToFile {
    $Item = Get-SelectedSubtitleItem
    if ($null -eq $Item) {
        [System.Windows.Forms.MessageBox]::Show("Selecione uma música.", "Legendas", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }

    $Path = [string]$TextLegArquivoSrt.Text
    if ([string]::IsNullOrWhiteSpace($Path)) { $Path = Get-SubtitleSrtPathForItem -Item $Item }
    if ([string]::IsNullOrWhiteSpace($Path)) {
        [System.Windows.Forms.MessageBox]::Show("Não foi possível definir o caminho do SRT.", "Legendas", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    $Dir = Split-SafeParent -Path $Path
    New-SafeDirectory -Path $Dir | Out-Null

    $Rows = @(Get-SubtitleRowsFromGrid)
    $SrtText = Convert-SubtitleRowsToSrtText -Rows $Rows
    [System.IO.File]::WriteAllText($Path, $SrtText, [System.Text.Encoding]::UTF8)

    $TextLegArquivoSrt.Text = $Path
    $Item.SrtPath = $Path
    $Item.Status = "SRT existente"

    [System.Windows.Forms.MessageBox]::Show("Legenda salva em:`n$Path", "Legendas", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
}


function Get-DefaultSubtitleVideoPathForItem {
    param([object]$Item)

    if ($null -eq $Item) { return "" }
    if ($null -eq $TextPastaVideo -or [string]::IsNullOrWhiteSpace($TextPastaVideo.Text)) { return "" }

    $AlbumDir = Join-SafePath ([string]$TextPastaVideo.Text) ([string]$Item.Album)
    return (Join-SafePath $AlbumDir (([string]$Item.BaseName) + ".mp4"))
}

function Get-DefaultBurnedSubtitleVideoPath {
    param(
        [object]$Item,
        [string]$VideoPath
    )

    $BaseDir = ""
    $BaseName = ""

    if (-not [string]::IsNullOrWhiteSpace($VideoPath)) {
        $BaseDir = Split-SafeParent -Path $VideoPath
        $BaseName = [System.IO.Path]::GetFileNameWithoutExtension($VideoPath)
    }

    if ([string]::IsNullOrWhiteSpace($BaseDir) -and $null -ne $Item -and $null -ne $TextPastaVideo -and -not [string]::IsNullOrWhiteSpace($TextPastaVideo.Text)) {
        $BaseDir = Join-SafePath ([string]$TextPastaVideo.Text) ([string]$Item.Album)
    }

    if ([string]::IsNullOrWhiteSpace($BaseName) -and $null -ne $Item) {
        $BaseName = [string]$Item.BaseName
    }

    if ([string]::IsNullOrWhiteSpace($BaseDir)) {
        $BaseDir = [Environment]::GetFolderPath("Desktop")
    }

    if ([string]::IsNullOrWhiteSpace($BaseName)) {
        $BaseName = "video"
    }

    return (Join-SafePath $BaseDir ($BaseName + " - legendado.mp4"))
}

function Escape-AssSubtitleText {
    param([string]$Text)

    if ($null -eq $Text) { return "" }

    $Escaped = [string]$Text
    $Escaped = $Escaped -replace "`r`n", "`n"
    $Escaped = $Escaped -replace "`r", "`n"
    $Escaped = $Escaped -replace "\\", "\\\\"
    $Escaped = $Escaped -replace "\{", "\\{"
    $Escaped = $Escaped -replace "\}", "\\}"
    $Escaped = $Escaped -replace "`n", "\N"
    return $Escaped
}

function Convert-ColorToAssColor {
    param([System.Drawing.Color]$Color)

    if ($null -eq $Color) { $Color = [System.Drawing.Color]::White }

    # ASS/libass usa o formato &HAABBGGRR. AA=00 significa opaco.
    return ("&H00{0:X2}{1:X2}{2:X2}" -f [int]$Color.B, [int]$Color.G, [int]$Color.R)
}

function Convert-ColorToAssColorWithOpacity {
    param(
        [System.Drawing.Color]$Color,
        [int]$OpacityPercent = 100
    )

    if ($null -eq $Color) { $Color = [System.Drawing.Color]::Black }
    if ($OpacityPercent -lt 0) { $OpacityPercent = 0 }
    if ($OpacityPercent -gt 100) { $OpacityPercent = 100 }

    # ASS/libass usa &HAABBGGRR. AA=00 é opaco; AA=FF é totalmente transparente.
    $Alpha = [int](255 - [Math]::Round(255.0 * ([double]$OpacityPercent / 100.0)))
    if ($Alpha -lt 0) { $Alpha = 0 }
    if ($Alpha -gt 255) { $Alpha = 255 }
    return ("&H{0:X2}{1:X2}{2:X2}{3:X2}" -f $Alpha, [int]$Color.B, [int]$Color.G, [int]$Color.R)
}

function Format-MinSecDisplay {
    param([double]$Seconds)
    if ($Seconds -lt 0) { $Seconds = 0 }
    $Total = [int][Math]::Ceiling($Seconds)
    $Minutes = [int][Math]::Floor($Total / 60)
    $Secs = $Total % 60
    return ("{0:D2}m:{1:D2}s" -f $Minutes, $Secs)
}

function Parse-MinSecDisplay {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $T = ([string]$Text).Trim()
    if ($T -match '^(\d+)\s*m\s*:\s*(\d{1,2})\s*s$') {
        $M = [int]$Matches[1]; $S = [int]$Matches[2]
        if ($S -ge 60) { return $null }
        return [double](($M * 60) + $S)
    }
    if ($T -match '^(\d+)\s*:\s*(\d{1,2})$') {
        $M = [int]$Matches[1]; $S = [int]$Matches[2]
        if ($S -ge 60) { return $null }
        return [double](($M * 60) + $S)
    }
    return $null
}

function Clip-SubtitleRowsToWindow {
    param([object[]]$Rows,[double]$StartAt = 0,[double]$EndAt = [double]::PositiveInfinity)
    $Result = @()
    foreach ($Row in @($Rows)) {
        $Text = [string]$Row.Text
        if ([string]::IsNullOrWhiteSpace($Text)) { continue }
        $S = Parse-SrtTime -Text ([string]$Row.Start)
        $E = Parse-SrtTime -Text ([string]$Row.End)
        if ($E -le $S) { $E = $S + 1.0 }
        if ($E -le $StartAt -or $S -ge $EndAt) { continue }
        $NewS = [Math]::Max([double]$S, [double]$StartAt)
        $NewE = [Math]::Min([double]$E, [double]$EndAt)
        if ($NewE -le $NewS) { continue }
        $Result += [PSCustomObject]@{ Start=(Format-SrtTime -Seconds $NewS); End=(Format-SrtTime -Seconds $NewE); Text=$Text }
    }
    return @($Result)
}

function New-AssFileFromSubtitleRows {
    param(
        [object[]]$Rows,
        [string]$OutputAss,
        [string]$FontName = "Century Gothic",
        [int]$FontSize = 90,
        [string]$Position = "Inferior",
        [int]$MarginV = 0,
        [int]$PlayResX = 1920,
        [int]$PlayResY = 1080,
        [System.Drawing.Color]$FontColor = [System.Drawing.Color]::White,
        [System.Drawing.Color]$ShadowColor = [System.Drawing.Color]::Black,
        [int]$ShadowIntensity = 100,
        [int]$ShadowSpread = 4,
        [Nullable[int]]$CustomX = $null,
        [Nullable[int]]$CustomY = $null
    )

    if ($null -eq $Rows -or $Rows.Count -eq 0) {
        throw "Não há linhas de legenda para embutir."
    }

    $Alignment = 2
    switch ([string]$Position) {
        "Superior" { $Alignment = 8 }
        "Centro"   { $Alignment = 5 }
        default    { $Alignment = 2 }
    }

    if ($FontSize -lt 18) { $FontSize = 18 }
    if ($FontSize -gt 180) { $FontSize = 180 }
    if ($MarginV -lt 0) { $MarginV = 0 }
    if ($MarginV -gt 500) { $MarginV = 500 }
    if ($ShadowIntensity -lt 0) { $ShadowIntensity = 0 }
    if ($ShadowIntensity -gt 100) { $ShadowIntensity = 100 }
    if ($ShadowSpread -lt 0) { $ShadowSpread = 0 }
    if ($ShadowSpread -gt 20) { $ShadowSpread = 20 }

    $UseCustomPosition = ($null -ne $CustomX -and $null -ne $CustomY)
    if ($UseCustomPosition) {
        if ([int]$CustomX -lt 0) { $CustomX = 0 }
        if ([int]$CustomY -lt 0) { $CustomY = 0 }
        if ([int]$CustomX -gt [int]$PlayResX) { $CustomX = [int]$PlayResX }
        if ([int]$CustomY -gt [int]$PlayResY) { $CustomY = [int]$PlayResY }
    }

    $Lines = New-Object System.Collections.Generic.List[string]
    $Lines.Add("[Script Info]")
    $Lines.Add("ScriptType: v4.00+")
    $Lines.Add(("PlayResX: {0}" -f [int]$PlayResX))
    $Lines.Add(("PlayResY: {0}" -f [int]$PlayResY))
    $Lines.Add("WrapStyle: 0")
    $Lines.Add("ScaledBorderAndShadow: yes")
    $Lines.Add("")
    $SafeFontName = ([string]$FontName).Replace(",", " ").Trim()
    if ([string]::IsNullOrWhiteSpace($SafeFontName)) { $SafeFontName = "Century Gothic" }

    $PrimaryColour = Convert-ColorToAssColor -Color $FontColor
    $ShadowColour = Convert-ColorToAssColorWithOpacity -Color $ShadowColor -OpacityPercent $ShadowIntensity
    $ShadowSize = if ($ShadowIntensity -le 0 -or $ShadowSpread -le 0) { 0 } else { [int]$ShadowSpread }

    $Lines.Add("[V4+ Styles]")
    $Lines.Add("Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding")
    $Lines.Add(("Style: Default,{0},{1},{2},&H000000FF,&H00000000,{3},0,0,0,0,100,100,0,0,1,3,{4},{5},110,110,{6},1" -f $SafeFontName, $FontSize, $PrimaryColour, $ShadowColour, $ShadowSize, $Alignment, $MarginV))
    $Lines.Add("")
    $Lines.Add("[Events]")
    $Lines.Add("Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text")

    foreach ($Row in $Rows) {
        $Texto = [string]$Row.Text
        if ([string]::IsNullOrWhiteSpace($Texto)) { continue }

        $StartSeconds = Parse-SrtTime -Text ([string]$Row.Start)
        $EndSeconds = Parse-SrtTime -Text ([string]$Row.End)
        if ($EndSeconds -le $StartSeconds) {
            $EndSeconds = $StartSeconds + 1.0
        }

        $StartAss = Format-AssTime -Seconds $StartSeconds
        $EndAss = Format-AssTime -Seconds $EndSeconds
        $AssText = Escape-AssSubtitleText -Text $Texto
        if ($UseCustomPosition) {
            $AssText = ("{\an5\pos({0},{1})}" -f [int]$CustomX, [int]$CustomY) + $AssText
        }
        $Lines.Add(("Dialogue: 0,{0},{1},Default,,0,0,0,,{2}" -f $StartAss, $EndAss, $AssText))
    }

    New-SafeDirectory -Path (Split-SafeParent -Path $OutputAss) | Out-Null
    [System.IO.File]::WriteAllLines($OutputAss, $Lines, [System.Text.Encoding]::UTF8)
    return $OutputAss
}

function Invoke-BurnSubtitlesIntoVideo {
    param(
        [string]$VideoPath,
        [object[]]$Rows,
        [string]$OutputPath,
        [string]$FontName = "Century Gothic",
        [int]$FontSize = 90,
        [string]$Position = "Inferior",
        [int]$MarginV = 0,
        [System.Drawing.Color]$FontColor = [System.Drawing.Color]::White,
        [System.Drawing.Color]$ShadowColor = [System.Drawing.Color]::Black,
        [int]$ShadowIntensity = 100,
        [int]$ShadowSpread = 4,
        [double]$SubtitleStartSeconds = 0,
        [double]$SubtitleEndSeconds = [double]::PositiveInfinity,
        [bool]$ShowTrackTitle = $false,
        [string]$TrackTitle = "",
        [double]$TrackTitleStartSeconds = 0,
        [double]$TrackTitleEndSeconds = [double]::PositiveInfinity,
        [Nullable[int]]$CustomX = $null,
        [Nullable[int]]$CustomY = $null,
        [System.Windows.Forms.Label]$StatusLabel,
        [System.Windows.Forms.TextBox]$LogBox = $null
    )

    $FfmpegPath = Resolve-Executable "ffmpeg.exe"
    if (-not $FfmpegPath) {
        throw "FFmpeg não encontrado. Coloque o ffmpeg.exe na pasta do app ou no PATH."
    }

    $FfprobePath = Resolve-Executable "ffprobe.exe"
    if (-not $FfprobePath) { $FfprobePath = Resolve-Executable "ffprobe" }

    if (-not (Test-SafePath -Path $VideoPath)) {
        throw "Vídeo de origem não encontrado: $VideoPath"
    }

    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        throw "Informe o arquivo de saída."
    }

    $OutputDir = Split-SafeParent -Path $OutputPath
    New-SafeDirectory -Path $OutputDir | Out-Null

    $TempAss = Join-Path ([System.IO.Path]::GetTempPath()) ("frezza_subtitle_burn_" + [System.Guid]::NewGuid().ToString("N") + ".ass")

    try {
        $VideoDim = Get-VideoDimensions -Arquivo $VideoPath -FfprobePath $FfprobePath

        $RowsJanela = @(Clip-SubtitleRowsToWindow -Rows $Rows -StartAt $SubtitleStartSeconds -EndAt $SubtitleEndSeconds)
        if ($RowsJanela.Count -eq 0) { throw "A legenda não possui conteúdo dentro do intervalo de exibição escolhido." }

        New-AssFileFromSubtitleRows `
            -Rows $RowsJanela `
            -OutputAss $TempAss `
            -FontName $FontName `
            -FontSize $FontSize `
            -Position $Position `
            -MarginV $MarginV `
            -PlayResX ([int]$VideoDim.Width) `
            -PlayResY ([int]$VideoDim.Height) `
            -FontColor $FontColor `
            -ShadowColor $ShadowColor `
            -ShadowIntensity $ShadowIntensity `
            -ShadowSpread $ShadowSpread `
            -CustomX $CustomX `
            -CustomY $CustomY | Out-Null

        $ArquivoAssFfmpeg = Convert-FontPathForFfmpeg -Path $TempAss
        # Não usamos fontsdir=C:\Windows\Fonts aqui.
        # O libass/DirectWrite localiza fontes instaladas no Windows, e evitar fontsdir impede milhares de avisos sobre arquivos .fon.
        $SubtitleFilter = "subtitles='$ArquivoAssFfmpeg'"
        $VideoFilter = $SubtitleFilter

        if ($ShowTrackTitle -and -not [string]::IsNullOrWhiteSpace($TrackTitle)) {
            $FontTitlePath = Resolve-FontFile
            if ($FontTitlePath) {
                $FontTitleFfmpeg = Convert-FontPathForFfmpeg -Path $FontTitlePath
                $TrackTitleEscaped = Escape-DrawText -Text $TrackTitle
                $TitleFontSize = [Math]::Max(28, [int]([double]$VideoDim.Height * 0.050))
                $TitleBandHeight = [Math]::Max(64, [int]([double]$VideoDim.Height * 0.177))
                $TitleBandY = [int]([double]$VideoDim.Height * 0.411)
                $TitleTextY = "(h-text_h)/2"
                $TitleStartArg = ([double]$TrackTitleStartSeconds).ToString("0.###", [System.Globalization.CultureInfo]::InvariantCulture)
                $TitleEndArg = ([double]$TrackTitleEndSeconds).ToString("0.###", [System.Globalization.CultureInfo]::InvariantCulture)
                $TitleEnable = "between(t\,$TitleStartArg\,$TitleEndArg)"
                $TitleOverlay = "drawbox=x=0:y=$TitleBandY:w=iw:h=$TitleBandHeight:color=black@0.68:t=fill:enable='$TitleEnable',drawtext=fontfile='$FontTitleFfmpeg':text='$TrackTitleEscaped':x=(w-text_w)/2:y=$TitleTextY:fontsize=$TitleFontSize:fontcolor=white:borderw=2:bordercolor=black@0.85:enable='$TitleEnable'"
                $VideoFilter = $SubtitleFilter + "," + $TitleOverlay
            }
        }

        $Argumentos = @(
            "-y",
            "-i", $VideoPath,
            "-vf", $VideoFilter,
            "-c:v", "libx264",
            "-preset", "veryfast",
            "-crf", "18",
            "-c:a", "copy",
            "-movflags", "+faststart",
            $OutputPath
        )

        Add-Log -LogBox $LogBox -Mensagem ""
        Add-Log -LogBox $LogBox -Mensagem "Gerando vídeo com legenda embutida..."
        Add-Log -LogBox $LogBox -Mensagem "Origem: $VideoPath"
        Add-Log -LogBox $LogBox -Mensagem "Destino: $OutputPath"
        Add-Log -LogBox $LogBox -Mensagem "Fonte: $FontName | Tamanho: $FontSize | Posição: $Position | Margem: $MarginV | Cor: $($FontColor.Name) | Sombra: $($ShadowColor.Name) / $ShadowIntensity% | Espessura: $ShadowSpread"
        if ($null -ne $CustomX -and $null -ne $CustomY) {
            Add-Log -LogBox $LogBox -Mensagem ("Posição personalizada da legenda: X={0}, Y={1}" -f [int]$CustomX, [int]$CustomY)
        }
        try { Add-Log -LogBox $LogBox -Mensagem ("Resolução detectada: {0}x{1}" -f [int]$VideoDim.Width, [int]$VideoDim.Height) } catch { }
        try { Add-Log -LogBox $LogBox -Mensagem ("Filtro FFmpeg: -vf " + $VideoFilter) } catch { }

        $Detalhado = $false
        try { if ($null -ne $CheckLogDetalhado) { $Detalhado = [bool]$CheckLogDetalhado.Checked } } catch { }

        $CodigoSaida = Invoke-Ffmpeg `
            -FfmpegPath $FfmpegPath `
            -Argumentos $Argumentos `
            -Detalhado $Detalhado `
            -StatusLabel $StatusLabel `
            -LogBox $LogBox

        if ($CodigoSaida -eq -999) {
            Add-Log -LogBox $LogBox -Mensagem "Geração do vídeo legendado interrompida."
            return $false
        }

        $ArquivoSaidaOk = $false
        try {
            if (Test-SafePath -Path $OutputPath) {
                $InfoSaida = Get-Item -LiteralPath $OutputPath -ErrorAction Stop
                $ArquivoSaidaOk = ($InfoSaida.Length -gt 0)
            }
        } catch {
            $ArquivoSaidaOk = $false
        }

        if ($ArquivoSaidaOk -and (($null -eq $CodigoSaida) -or ([string]::IsNullOrWhiteSpace([string]$CodigoSaida)))) {
            Add-Log -LogBox $LogBox -Mensagem "FFmpeg gerou o arquivo, mas não retornou código de saída legível. Considerando sucesso porque o MP4 foi criado."
        }
        elseif ($ArquivoSaidaOk -and $CodigoSaida -ne 0) {
            Add-Log -LogBox $LogBox -Mensagem "Aviso: FFmpeg retornou código $CodigoSaida, mas o MP4 foi criado. Considerando sucesso."
        }
        elseif ($CodigoSaida -ne 0 -or -not $ArquivoSaidaOk) {
            throw "FFmpeg não conseguiu gerar o vídeo legendado. Código de saída: $CodigoSaida"
        }

        Add-Log -LogBox $LogBox -Mensagem "Vídeo legendado gerado: $OutputPath"
        return $true
    }
    finally {
        if ($TempAss -and (Test-SafePath -Path $TempAss)) {
            try { Remove-SafeItem -Path $TempAss } catch { }
        }
    }
}

function Invoke-BurnMultipleSubtitlesIntoVideo {
    param(
        [string]$VideoPath,[object[]]$Layers,[string]$OutputPath,
        [string]$FontName="Century Gothic",[int]$FontSize=90,[int]$MarginV=0,
        [System.Drawing.Color]$FontColor=[System.Drawing.Color]::White,[System.Drawing.Color]$ShadowColor=[System.Drawing.Color]::Black,
        [int]$ShadowIntensity=100,[int]$ShadowSpread=4,[bool]$ShowTrackTitle=$false,[string]$TrackTitle="",
        [double]$TrackTitleStartSeconds=0,[double]$TrackTitleEndSeconds=[double]::PositiveInfinity,[System.Windows.Forms.Label]$StatusLabel,[System.Windows.Forms.TextBox]$LogBox=$null
    )
    if($null -eq $Layers -or $Layers.Count -eq 0){ throw "Nenhuma legenda foi selecionada." }
    $FfmpegPath=Resolve-Executable "ffmpeg.exe"; if(-not $FfmpegPath){$FfmpegPath=Resolve-Executable "ffmpeg"}; if(-not $FfmpegPath){throw "FFmpeg não encontrado."}
    $FfprobePath=Resolve-Executable "ffprobe.exe"; if(-not $FfprobePath){$FfprobePath=Resolve-Executable "ffprobe"}
    $Dim=Get-VideoDimensions -Arquivo $VideoPath -FfprobePath $FfprobePath
    $Temp=@(); $Filters=@()
    try{
        $N=0
        foreach($L in $Layers){
            $N++; $RowsL=@($L.Rows); if($RowsL.Count -eq 0){continue}
            $LayerStart=0.0; $LayerEnd=[double]::PositiveInfinity
            try { if($null -ne $L.StartAt){$LayerStart=[double]$L.StartAt} } catch {}
            try { if($null -ne $L.EndAt){$LayerEnd=[double]$L.EndAt} } catch {}
            $RowsL=@(Clip-SubtitleRowsToWindow -Rows $RowsL -StartAt $LayerStart -EndAt $LayerEnd)
            if($RowsL.Count -eq 0){continue}
            $Ass=Join-Path ([System.IO.Path]::GetTempPath()) ("frezza_multi_"+[Guid]::NewGuid().ToString('N')+".ass"); $Temp+=$Ass
            New-AssFileFromSubtitleRows -Rows $RowsL -OutputAss $Ass -FontName $FontName -FontSize $FontSize -Position ([string]$L.Position) -MarginV $MarginV -PlayResX ([int]$Dim.Width) -PlayResY ([int]$Dim.Height) -FontColor $FontColor -ShadowColor $ShadowColor -ShadowIntensity $ShadowIntensity -ShadowSpread $ShadowSpread | Out-Null
            $F=Convert-FontPathForFfmpeg -Path $Ass; $Filters += "subtitles='$F'"
        }
        if($Filters.Count -eq 0){throw "As legendas selecionadas estão vazias."}
        New-SafeDirectory -Path (Split-SafeParent -Path $OutputPath) | Out-Null
        $FilterChain=($Filters -join ',')
        if($ShowTrackTitle -and -not [string]::IsNullOrWhiteSpace($TrackTitle)){
            $FontTitlePath=Resolve-FontFile
            if($FontTitlePath){
                $FontTitleFfmpeg=Convert-FontPathForFfmpeg -Path $FontTitlePath
                $TrackTitleEscaped=Escape-DrawText -Text $TrackTitle
                $TitleFontSize=[Math]::Max(28,[int]([double]$Dim.Height*0.050))
                $TitleBandHeight=[Math]::Max(64,[int]([double]$Dim.Height*0.177))
                $TitleBandY=[int]([double]$Dim.Height*0.411)
                $TitleStartArg=([double]$TrackTitleStartSeconds).ToString("0.###",[System.Globalization.CultureInfo]::InvariantCulture)
                $TitleEndArg=([double]$TrackTitleEndSeconds).ToString("0.###",[System.Globalization.CultureInfo]::InvariantCulture)
                $TitleEnable="between(t\,$TitleStartArg\,$TitleEndArg)"
                $TitleOverlay="drawbox=x=0:y=$TitleBandY:w=iw:h=$TitleBandHeight:color=black@0.68:t=fill:enable='$TitleEnable',drawtext=fontfile='$FontTitleFfmpeg':text='$TrackTitleEscaped':x=(w-text_w)/2:y=(h-text_h)/2:fontsize=$TitleFontSize:fontcolor=white:borderw=2:bordercolor=black@0.85:enable='$TitleEnable'"
                $FilterChain=$FilterChain+","+$TitleOverlay
            }
        }
        Add-Log -LogBox $LogBox -Mensagem ("Gerando vídeo com {0} legendas simultâneas." -f $Filters.Count)
        $Args=@('-y','-i',$VideoPath,'-vf',$FilterChain,'-c:v','libx264','-preset','veryfast','-crf','18','-c:a','copy','-movflags','+faststart',$OutputPath)
        $Code=Invoke-Ffmpeg -FfmpegPath $FfmpegPath -Argumentos $Args -Detalhado $false -StatusLabel $StatusLabel -LogBox $LogBox
        if($Code -eq -999){return $false}
        return (Test-SafePath -Path $OutputPath)
    } finally { foreach($T in $Temp){ if(Test-SafePath -Path $T){Remove-SafeItem -Path $T} } }
}

function Show-BurnSubtitleVideoDialog {
    $Item = Get-SelectedSubtitleItem
    if ($null -eq $Item) {
        [System.Windows.Forms.MessageBox]::Show("Selecione uma música na aba Legendas antes de gerar o vídeo legendado.", "Vídeo legendado", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }

    $Rows = @(Get-SubtitleRowsFromGrid)
    $SrtPath = Get-SubtitleSrtPathForItem -Item $Item

    if ($Rows.Count -eq 0 -and (Test-SafePath -Path $SrtPath)) {
        $Rows = @(Read-SrtFileRows -Path $SrtPath)
    }

    if ($Rows.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Não há legenda na grade nem SRT salvo para esta música.", "Vídeo legendado", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }

    $DefaultVideo = Get-DefaultSubtitleVideoPathForItem -Item $Item
    if (-not (Test-SafePath -Path $DefaultVideo)) { $DefaultVideo = "" }
    $DefaultOutput = Get-DefaultBurnedSubtitleVideoPath -Item $Item -VideoPath $DefaultVideo

    $VideoDurationSeconds = 0.0
    $FfprobeDuration = Resolve-Executable "ffprobe.exe"
    if (-not $FfprobeDuration) { $FfprobeDuration = Resolve-Executable "ffprobe" }
    try {
        if (-not [string]::IsNullOrWhiteSpace($DefaultVideo) -and $FfprobeDuration) { $D=Get-MediaDuration -Arquivo $DefaultVideo -FfprobePath $FfprobeDuration; if($null -ne $D){$VideoDurationSeconds=[double]$D} }
        elseif ($null -ne $Item.MusicFile -and $FfprobeDuration) { $D=Get-MediaDuration -Arquivo ([string]$Item.MusicFile.FullName) -FfprobePath $FfprobeDuration; if($null -ne $D){$VideoDurationSeconds=[double]$D} }
    } catch {}
    if ($VideoDurationSeconds -le 0) { $VideoDurationSeconds = 1.0 }

    $SubtitleLayers = New-Object System.Collections.ArrayList
    [void]$SubtitleLayers.Add([PSCustomObject]@{ Source="Grade atual"; Path=""; Position="Inferior"; Rows=@($Rows); StartAt=0.0; EndAt=[double]$VideoDurationSeconds })

    $Dialog = New-Object System.Windows.Forms.Form
    $Dialog.Text = "Gerar vídeo com legenda embutida"
    $Dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $Dialog.Size = New-Object System.Drawing.Size(920, 805)
    $Dialog.MinimumSize = New-Object System.Drawing.Size(920, 805)
    $Dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $Dialog.MaximizeBox = $false
    $Dialog.MinimizeBox = $false

    $LblInfo = New-Object System.Windows.Forms.Label
    $LblInfo.Text = "Gera uma cópia do MP4 com texto sincronizado. Use Legenda padrão para texto inferior ou Lyric video para letra grande centralizada."
    $LblInfo.Location = New-Object System.Drawing.Point(15, 15)
    $LblInfo.Size = New-Object System.Drawing.Size(860, 36)

    $LblVideo = New-Label -Text "Vídeo MP4:" -X 15 -Y 62 -Width 110
    $TxtVideo = New-Object System.Windows.Forms.TextBox
    $TxtVideo.Location = New-Object System.Drawing.Point(130, 62)
    $TxtVideo.Size = New-Object System.Drawing.Size(620, 24)
    $TxtVideo.Text = $DefaultVideo
    $BtnVideo = New-Object System.Windows.Forms.Button
    $BtnVideo.Text = "Explorar..."
    $BtnVideo.Location = New-Object System.Drawing.Point(765, 59)
    $BtnVideo.Size = New-Object System.Drawing.Size(100, 28)

    $LblSaida = New-Label -Text "Salvar como:" -X 15 -Y 98 -Width 110
    $TxtSaida = New-Object System.Windows.Forms.TextBox
    $TxtSaida.Location = New-Object System.Drawing.Point(130, 98)
    $TxtSaida.Size = New-Object System.Drawing.Size(620, 24)
    $TxtSaida.Text = $DefaultOutput
    $BtnSaida = New-Object System.Windows.Forms.Button
    $BtnSaida.Text = "Escolher..."
    $BtnSaida.Location = New-Object System.Drawing.Point(765, 95)
    $BtnSaida.Size = New-Object System.Drawing.Size(100, 28)

    $LblFonte = New-Label -Text "Fonte:" -X 15 -Y 145 -Width 110
    $ComboFonte = New-Object System.Windows.Forms.ComboBox
    $ComboFonte.Location = New-Object System.Drawing.Point(130, 145)
    $ComboFonte.Size = New-Object System.Drawing.Size(190, 24)
    $ComboFonte.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown
    @("Century Gothic", "Arial", "Segoe UI", "Calibri") | ForEach-Object { [void]$ComboFonte.Items.Add($_) }
    $ComboFonte.Text = "Century Gothic"

    $LblTamanho = New-Label -Text "Tamanho:" -X 350 -Y 145 -Width 75
    $NumTamanho = New-Object System.Windows.Forms.NumericUpDown
    $NumTamanho.Location = New-Object System.Drawing.Point(430, 145)
    $NumTamanho.Size = New-Object System.Drawing.Size(75, 24)
    $NumTamanho.Minimum = 18
    $NumTamanho.Maximum = 180
    $NumTamanho.Value = 90

    $CorLegendaSelecionada = [System.Drawing.Color]::White

    $LblCor = New-Label -Text "Cor do texto:" -X 540 -Y 145 -Width 90
    $PanelCor = New-Object System.Windows.Forms.Panel
    $PanelCor.Location = New-Object System.Drawing.Point(630, 146)
    $PanelCor.Size = New-Object System.Drawing.Size(28, 22)
    $PanelCor.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $PanelCor.BackColor = $CorLegendaSelecionada

    $BtnCor = New-Object System.Windows.Forms.Button
    $BtnCor.Text = "Cor..."
    $BtnCor.Location = New-Object System.Drawing.Point(665, 142)
    $BtnCor.Size = New-Object System.Drawing.Size(60, 28)

    $CorSombraSelecionada = [System.Drawing.Color]::Black

    $LblSombra = New-Label -Text "Sombra:" -X 15 -Y 221 -Width 65
    $PanelSombra = New-Object System.Windows.Forms.Panel
    $PanelSombra.Location = New-Object System.Drawing.Point(80, 222)
    $PanelSombra.Size = New-Object System.Drawing.Size(28, 22)
    $PanelSombra.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $PanelSombra.BackColor = $CorSombraSelecionada

    $BtnSombra = New-Object System.Windows.Forms.Button
    $BtnSombra.Text = "Cor..."
    $BtnSombra.Location = New-Object System.Drawing.Point(115, 218)
    $BtnSombra.Size = New-Object System.Drawing.Size(60, 28)

    $LblSombraIntensidade = New-Label -Text "Intensidade:" -X 200 -Y 221 -Width 82
    $NumSombraIntensidade = New-Object System.Windows.Forms.NumericUpDown
    $NumSombraIntensidade.Location = New-Object System.Drawing.Point(285, 221)
    $NumSombraIntensidade.Size = New-Object System.Drawing.Size(55, 24)
    $NumSombraIntensidade.Minimum = 0
    $NumSombraIntensidade.Maximum = 100
    $NumSombraIntensidade.Value = 100
    $NumSombraIntensidade.Increment = 5

    $LblSombraExpansao = New-Label -Text "Espessura:" -X 365 -Y 221 -Width 82
    $NumSombraExpansao = New-Object System.Windows.Forms.NumericUpDown
    $NumSombraExpansao.Location = New-Object System.Drawing.Point(450, 221)
    $NumSombraExpansao.Size = New-Object System.Drawing.Size(60, 24)
    $NumSombraExpansao.Minimum = 0
    $NumSombraExpansao.Maximum = 20
    $NumSombraExpansao.Value = 4
    $NumSombraExpansao.Increment = 1

    $LblPosicao = New-Label -Text "Posição:" -X 15 -Y 183 -Width 110
    $ComboPosicao = New-Object System.Windows.Forms.ComboBox
    $ComboPosicao.Location = New-Object System.Drawing.Point(130, 183)
    $ComboPosicao.Size = New-Object System.Drawing.Size(190, 24)
    $ComboPosicao.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    @("Inferior", "Centro", "Superior", "Personalizada") | ForEach-Object { [void]$ComboPosicao.Items.Add($_) }
    $ComboPosicao.SelectedIndex = 0

    $LblMargem = New-Label -Text "Margem vertical:" -X 350 -Y 183 -Width 120
    $NumMargem = New-Object System.Windows.Forms.NumericUpDown
    $NumMargem.Location = New-Object System.Drawing.Point(475, 183)
    $NumMargem.Size = New-Object System.Drawing.Size(75, 24)
    $NumMargem.Minimum = 0
    $NumMargem.Maximum = 500
    $NumMargem.Value = 0

    $LblModoExibicao = New-Label -Text "Formato do texto:" -X 15 -Y 259 -Width 110
    $ComboModoExibicao = New-Object System.Windows.Forms.ComboBox
    $ComboModoExibicao.Location = New-Object System.Drawing.Point(130, 257)
    $ComboModoExibicao.Size = New-Object System.Drawing.Size(190, 24)
    $ComboModoExibicao.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    @("Legenda padrão", "Lyric video") | ForEach-Object { [void]$ComboModoExibicao.Items.Add($_) }
    $ComboModoExibicao.SelectedIndex = 0

    $BtnMultiplasLegendas = New-Object System.Windows.Forms.Button
    $BtnMultiplasLegendas.Text = "Configurar legendas..."
    $BtnMultiplasLegendas.Location = New-Object System.Drawing.Point(350, 254)
    $BtnMultiplasLegendas.Size = New-Object System.Drawing.Size(180, 30)

    $LblMultiplasLegendasStatus = New-Object System.Windows.Forms.Label
    $QtdLegendasAtivas = if ($SubtitleLayers.Count -gt 0) { [int]$SubtitleLayers.Count } else { 1 }
    $LblMultiplasLegendasStatus.Text = if ($QtdLegendasAtivas -eq 1) { "1 legenda ativa" } else { "{0} legendas ativas" -f $QtdLegendasAtivas }
    $LblMultiplasLegendasStatus.Location = New-Object System.Drawing.Point(540, 259)
    $LblMultiplasLegendasStatus.Size = New-Object System.Drawing.Size(150, 22)
    $LblMultiplasLegendasStatus.ForeColor = [System.Drawing.Color]::DimGray
    $LblMultiplasLegendasStatus.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft

    $LblModoAjuda = New-Object System.Windows.Forms.Label
    $LblModoAjuda.Text = "O preset altera apenas a apresentação. Os tempos e o texto da legenda continuam os mesmos."
    $LblModoAjuda.Location = New-Object System.Drawing.Point(15, 294)
    $LblModoAjuda.Size = New-Object System.Drawing.Size(860, 22)
    $LblModoAjuda.ForeColor = [System.Drawing.Color]::DimGray

    $LblPreview = New-Label -Text "Prévia da posição:" -X 15 -Y 350 -Width 160

    $CheckMostrarFaixaTitulo = New-Object System.Windows.Forms.CheckBox
    $CheckMostrarFaixaTitulo.Text = "Mostrar faixa com o nome da música"
    $CheckMostrarFaixaTitulo.Location = New-Object System.Drawing.Point(15, 319)
    $CheckMostrarFaixaTitulo.Size = New-Object System.Drawing.Size(320, 24)
    $CheckMostrarFaixaTitulo.Checked = $true

    $LblTituloInicio = New-Label -Text "Início:" -X 350 -Y 319 -Width 48
    $TxtTituloInicio = New-Object System.Windows.Forms.TextBox
    $TxtTituloInicio.Location = New-Object System.Drawing.Point(400, 319)
    $TxtTituloInicio.Size = New-Object System.Drawing.Size(82, 24)
    $TxtTituloInicio.Text = "00m:00s"
    $LblTituloFim = New-Label -Text "Fim:" -X 500 -Y 319 -Width 38
    $TxtTituloFim = New-Object System.Windows.Forms.TextBox
    $TxtTituloFim.Location = New-Object System.Drawing.Point(540, 319)
    $TxtTituloFim.Size = New-Object System.Drawing.Size(82, 24)
    $TxtTituloFim.Text = Format-MinSecDisplay -Seconds $VideoDurationSeconds
    $LblTituloTempoInfo = New-Object System.Windows.Forms.Label
    $LblTituloTempoInfo.Text = "quando a faixa aparece e desaparece"
    $LblTituloTempoInfo.Location = New-Object System.Drawing.Point(635, 319)
    $LblTituloTempoInfo.Size = New-Object System.Drawing.Size(240, 24)
    $LblTituloTempoInfo.ForeColor = [System.Drawing.Color]::DimGray

    $PreviewPanel = New-Object System.Windows.Forms.Panel
    $PreviewPanel.Location = New-Object System.Drawing.Point(15, 375)
    $PreviewPanel.Size = New-Object System.Drawing.Size(860, 300)
    $PreviewPanel.BackColor = [System.Drawing.Color]::FromArgb(26, 26, 30)
    $PreviewPanel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

    $PreviewSurface = New-Object System.Windows.Forms.Panel
    $PreviewSurface.BackColor = [System.Drawing.Color]::FromArgb(10, 10, 12)
    $PreviewSurface.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

    $PreviewTitle = New-Object System.Windows.Forms.Label
    $PreviewTitle.Text = if ($null -ne $Item -and -not [string]::IsNullOrWhiteSpace([string]$Item.BaseName)) { [string]$Item.BaseName } else { "Nome da música" }
    $PreviewTitle.ForeColor = [System.Drawing.Color]::White
    $PreviewTitle.BackColor = [System.Drawing.Color]::FromArgb(20, 20, 20)
    $PreviewTitle.Font = New-Object System.Drawing.Font("Century Gothic", 16, [System.Drawing.FontStyle]::Bold)
    $PreviewTitle.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $PreviewTitle.Location = New-Object System.Drawing.Point(0, 120)
    $PreviewTitle.Size = New-Object System.Drawing.Size(860, 48)
    $PreviewTitle.Visible = $false

    $PreviewSubtitle = New-Object System.Windows.Forms.Label
    $PreviewSubtitle.Text = "Prévia da legenda centralizada"
    try {
        $PrimeiraLinha = @($Rows | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Text) } | Select-Object -First 1)
        if ($PrimeiraLinha.Count -gt 0) { $PreviewSubtitle.Text = [string]$PrimeiraLinha[0].Text }
    } catch { }
    $PreviewSubtitle.ForeColor = [System.Drawing.Color]::White
    $PreviewSubtitle.BackColor = [System.Drawing.Color]::Transparent
    $PreviewSubtitle.Font = New-Object System.Drawing.Font("Century Gothic", 14, [System.Drawing.FontStyle]::Regular)
    $PreviewSubtitle.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $PreviewSubtitle.AutoSize = $false
    $PreviewSubtitle.Size = New-Object System.Drawing.Size(760, 50)
    $PreviewSubtitle.Cursor = [System.Windows.Forms.Cursors]::SizeNS
    $PreviewSubtitleTextOriginal = [string]$PreviewSubtitle.Text
    $PreviewSubtitle.Text = ""
    $PreviewSubtitle.Add_Paint({
        param($Sender, $E)
        try {
            $G = $E.Graphics
            $G.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $G.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
            $FmtSub = New-Object System.Drawing.StringFormat
            $FmtSub.Alignment = [System.Drawing.StringAlignment]::Center
            $FmtSub.LineAlignment = [System.Drawing.StringAlignment]::Center
            $TextoSub = [string]$PreviewState.SubtitleText
            if ([string]::IsNullOrWhiteSpace($TextoSub)) { $TextoSub = "Prévia da legenda centralizada" }
            $Intensidade = 70
            try { $Intensidade = [int]$NumSombraIntensidade.Value } catch { }
            if ($Intensidade -lt 0) { $Intensidade = 0 }
            if ($Intensidade -gt 100) { $Intensidade = 100 }
            $Alpha = [int]([Math]::Round(255.0 * ([double]$Intensidade / 100.0)))
            $CorSombraAtual = $PanelSombra.BackColor
            $BrushSombraSub = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb($Alpha, $CorSombraAtual.R, $CorSombraAtual.G, $CorSombraAtual.B))
            $BrushTextoSub = New-Object System.Drawing.SolidBrush ($PanelCor.BackColor)
            $Expansao = 4
            try { $Expansao = [int]$NumSombraExpansao.Value } catch { }
            if ($Expansao -lt 0) { $Expansao = 0 }
            if ($Expansao -gt 20) { $Expansao = 20 }
            $OffsetBase = [Math]::Max(1.0, [double]$PreviewState.Scale * [double]$Expansao)
            $RectSub = New-Object System.Drawing.RectangleF(0, 0, [single]$Sender.ClientSize.Width, [single]$Sender.ClientSize.Height)
            if ($Intensidade -gt 0 -and $Expansao -gt 0) {
                $OffsetsPreview = @(
                    @($OffsetBase, $OffsetBase),
                    @(-$OffsetBase, $OffsetBase),
                    @($OffsetBase, -$OffsetBase),
                    @(-$OffsetBase, -$OffsetBase),
                    @(0, $OffsetBase),
                    @($OffsetBase, 0)
                )
                foreach ($ParOffset in $OffsetsPreview) {
                    $RectSombraSub = New-Object System.Drawing.RectangleF([single]$ParOffset[0], [single]$ParOffset[1], [single]$Sender.ClientSize.Width, [single]$Sender.ClientSize.Height)
                    $G.DrawString($TextoSub, $Sender.Font, $BrushSombraSub, $RectSombraSub, $FmtSub)
                }
            }
            $G.DrawString($TextoSub, $Sender.Font, $BrushTextoSub, $RectSub, $FmtSub)
            $FmtSub.Dispose(); $BrushSombraSub.Dispose(); $BrushTextoSub.Dispose()
        } catch { }
    })

    $LblPreviewDica = New-Object System.Windows.Forms.Label
    $LblPreviewDica.Text = "Arraste a legenda verticalmente na prévia para ajustar a posição. A margem vertical é atualizada automaticamente."
    $LblPreviewDica.ForeColor = [System.Drawing.Color]::Gainsboro
    $LblPreviewDica.BackColor = [System.Drawing.Color]::Transparent
    $LblPreviewDica.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Regular)
    $LblPreviewDica.Location = New-Object System.Drawing.Point(12, 290)
    $LblPreviewDica.Size = New-Object System.Drawing.Size(835, 22)

    [void]$PreviewSurface.Controls.Add($PreviewTitle)
    [void]$PreviewSurface.Controls.Add($PreviewSubtitle)
    [void]$PreviewPanel.Controls.Add($PreviewSurface)
    [void]$PreviewPanel.Controls.Add($LblPreviewDica)

    $PreviewCoverPathInicial = ""
    try {
        # Ao abrir a tela, sincroniza a imagem escolhida na aba Músicas para esta música.
        $PreviewCoverPathInicial = Resolve-CoverPathForSubtitleItem -Item $Item
    } catch { $PreviewCoverPathInicial = "" }

    $PreviewState = @{
        Dragging = $false
        OffsetX = 0
        OffsetY = 0
        CustomX = $null
        CustomY = $null
        VideoW = 1920
        VideoH = 1920
        Scale = 1.0
        Updating = $false
        SuppressMarginEvent = $false
        CoverPath = $PreviewCoverPathInicial
        SubtitleText = [string]$PreviewSubtitleTextOriginal
        CoverImage = $null
        CoverImagePath = ""
        ShowTrackTitle = $true
    }

    $GetTrackTitleFontSize = {
        param([string]$Text)
        $BaseSize = 92
        if ($Text.Length -gt 28) { $BaseSize = 90 }
        if ($Text.Length -gt 36) { $BaseSize = 75 }
        return $BaseSize
    }

    $GetSubtitleVideoMarginFromPreview = {
        $ScaleAtual = [double]$PreviewState.Scale
        if ($ScaleAtual -le 0) { $ScaleAtual = 1.0 }
        $BottomPreview = [int]($PreviewSurface.ClientSize.Height - ($PreviewSubtitle.Top + $PreviewSubtitle.Height))
        if ($BottomPreview -lt 0) { $BottomPreview = 0 }
        return [int]([double]$BottomPreview / $ScaleAtual)
    }

    $SetMarginFromPreviewPosition = {
        try {
            $NovoValor = & $GetSubtitleVideoMarginFromPreview
            if ($NovoValor -lt [int]$NumMargem.Minimum) { $NovoValor = [int]$NumMargem.Minimum }
            if ($NovoValor -gt [int]$NumMargem.Maximum) { $NovoValor = [int]$NumMargem.Maximum }
            $PreviewState.SuppressMarginEvent = $true
            $NumMargem.Value = [decimal]$NovoValor
        }
        catch { }
        finally { $PreviewState.SuppressMarginEvent = $false }
    }

    $PreviewSurface.Add_Paint({
        param($Sender, $E)
        try {
            $G = $E.Graphics
            $G.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $G.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $G.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit

            $G.Clear([System.Drawing.Color]::Black)

            $CoverPathPreview = [string]$PreviewState.CoverPath
            if (-not [string]::IsNullOrWhiteSpace($CoverPathPreview) -and (Test-SafePath -Path $CoverPathPreview)) {
                try {
                    if ($null -eq $PreviewState.CoverImage -or ([string]$PreviewState.CoverImagePath -ne $CoverPathPreview)) {
                        if ($null -ne $PreviewState.CoverImage) { try { $PreviewState.CoverImage.Dispose() } catch { } }
                        $PreviewState.CoverImage = [System.Drawing.Image]::FromFile($CoverPathPreview)
                        $PreviewState.CoverImagePath = $CoverPathPreview
                    }
                    $Img = $PreviewState.CoverImage
                    if ($null -ne $Img) {
                        $ScaleImg = [Math]::Min([double]$PreviewSurface.ClientSize.Width / [double]$Img.Width, [double]$PreviewSurface.ClientSize.Height / [double]$Img.Height)
                        $ImgW = [int]([double]$Img.Width * $ScaleImg)
                        $ImgH = [int]([double]$Img.Height * $ScaleImg)
                        $ImgX = [int](($PreviewSurface.ClientSize.Width - $ImgW) / 2)
                        $ImgY = [int](($PreviewSurface.ClientSize.Height - $ImgH) / 2)
                        $G.DrawImage($Img, $ImgX, $ImgY, $ImgW, $ImgH)
                    }
                } catch { }
            }

            $EscalaVideo = [double]$PreviewState.Scale
            if ($EscalaVideo -le 0) { $EscalaVideo = [Math]::Min([double]$PreviewSurface.ClientSize.Width / 1920.0, [double]$PreviewSurface.ClientSize.Height / 1920.0) }

            if ([bool]$PreviewState.ShowTrackTitle) {
            $TituloPreview = if ($null -ne $Item -and -not [string]::IsNullOrWhiteSpace([string]$Item.BaseName)) { [string]$Item.BaseName } else { "Nome da música" }
            $TituloPreview = Limit-TextForImage -Text $TituloPreview -MaxChars 42
            $TitleSizeBase = & $GetTrackTitleFontSize $TituloPreview
            $TitleSizePreview = [single]([Math]::Max(7, [double]$TitleSizeBase * $EscalaVideo))

            try { $TitleFontPreview = New-Object System.Drawing.Font("Century Gothic", $TitleSizePreview, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel) }
            catch { $TitleFontPreview = New-Object System.Drawing.Font("Arial", $TitleSizePreview, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel) }

            $YOverlay = [single](790.0 * $EscalaVideo)
            $HOverlay = [single](340.0 * $EscalaVideo)
            if ($HOverlay -lt 28) { $HOverlay = 28 }
            if ($YOverlay + $HOverlay -gt $PreviewSurface.ClientSize.Height) { $YOverlay = [single](($PreviewSurface.ClientSize.Height - $HOverlay) / 2) }
            if ($YOverlay -lt 0) { $YOverlay = 0 }

            $Fmt = New-Object System.Drawing.StringFormat
            $Fmt.Alignment = [System.Drawing.StringAlignment]::Center
            $Fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
            $BrushOverlayPreview = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(150, 0, 0, 0))
            $BrushShadowPreview = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(220, 0, 0, 0))
            $BrushWhitePreview = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
            $RectOverlayPreview = New-Object System.Drawing.RectangleF(0, $YOverlay, [single]$PreviewSurface.ClientSize.Width, $HOverlay)
            $RectShadowPreview = New-Object System.Drawing.RectangleF(([single](5.0 * $EscalaVideo)), ($YOverlay + [single](5.0 * $EscalaVideo)), [single]$PreviewSurface.ClientSize.Width, $HOverlay)
            $G.FillRectangle($BrushOverlayPreview, $RectOverlayPreview)
            $G.DrawString($TituloPreview, $TitleFontPreview, $BrushShadowPreview, $RectShadowPreview, $Fmt)
            $G.DrawString($TituloPreview, $TitleFontPreview, $BrushWhitePreview, $RectOverlayPreview, $Fmt)

            $TitleFontPreview.Dispose(); $Fmt.Dispose(); $BrushOverlayPreview.Dispose(); $BrushShadowPreview.Dispose(); $BrushWhitePreview.Dispose()
            }
        } catch { }
    })

    $Dialog.Add_FormClosed({
        try { if ($null -ne $PreviewState.CoverImage) { $PreviewState.CoverImage.Dispose(); $PreviewState.CoverImage = $null } } catch { }
    })

    $UpdatePreview = {
        try {
            if ($PreviewState.Updating) { return }
            $PreviewState.Updating = $true

            $VideoW = [int]$PreviewState.VideoW
            $VideoH = [int]$PreviewState.VideoH
            if ($VideoW -le 0) { $VideoW = 1920 }
            if ($VideoH -le 0) { $VideoH = 1920 }

            $MaxW = [Math]::Max(120, $PreviewPanel.ClientSize.Width - 20)
            $MaxH = [Math]::Max(120, $PreviewPanel.ClientSize.Height - 42)
            $Scale = [Math]::Min([double]$MaxW / [double]$VideoW, [double]$MaxH / [double]$VideoH)
            if ($Scale -le 0) { $Scale = 1.0 }
            $PreviewState.Scale = [double]$Scale

            $SurfW = [int]([double]$VideoW * $Scale)
            $SurfH = [int]([double]$VideoH * $Scale)
            if ($SurfW -lt 120) { $SurfW = 120 }
            if ($SurfH -lt 120) { $SurfH = 120 }
            $SurfX = [int](($PreviewPanel.ClientSize.Width - $SurfW) / 2)
            $SurfY = [int](($PreviewPanel.ClientSize.Height - 34 - $SurfH) / 2)
            if ($SurfY -lt 8) { $SurfY = 8 }
            $PreviewSurface.Location = New-Object System.Drawing.Point($SurfX, $SurfY)
            $PreviewSurface.Size = New-Object System.Drawing.Size($SurfW, $SurfH)

            # A prévia usa a mesma escala do vídeo real.
            # Ex.: fonte 52 em vídeo 1920x1920 vira aproximadamente 9 px numa prévia de 340x340.
            $FontPreviewSize = [single]([Math]::Max(6.0, [double]$NumTamanho.Value * [double]$Scale))
            $PreviewSubtitle.Font = New-Object System.Drawing.Font([string]$ComboFonte.Text, $FontPreviewSize, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
            $PreviewSubtitle.ForeColor = $PanelCor.BackColor
            $PreviewSubtitle.Invalidate()

            $MarginLPreview = [int]([double]110 * [double]$Scale)
            if ($MarginLPreview -lt 6) { $MarginLPreview = 6 }
            $PreviewSubtitle.Width = [Math]::Max(60, $PreviewSurface.ClientSize.Width - (2 * $MarginLPreview))
            $PreviewSubtitle.Height = [Math]::Max(14, [int]($PreviewSubtitle.Font.Height * 2.3))

            $Pos = [string]$ComboPosicao.SelectedItem
            if ([string]::IsNullOrWhiteSpace($Pos)) { $Pos = "Inferior" }
            $MarginVideo = [int]$NumMargem.Value
            $MarginPreview = [int]([double]$MarginVideo * [double]$Scale)

            if ($Pos -ne "Personalizada") {
                $PreviewState.CustomX = $null
                $PreviewState.CustomY = $null
                $X = [int](($PreviewSurface.ClientSize.Width - $PreviewSubtitle.Width) / 2)
                switch ($Pos) {
                    "Superior" { $Y = $MarginPreview }
                    "Centro"   { $Y = [int](($PreviewSurface.ClientSize.Height - $PreviewSubtitle.Height) / 2) }
                    default    { $Y = [int]($PreviewSurface.ClientSize.Height - $PreviewSubtitle.Height - $MarginPreview) }
                }
                if ($Y -lt 0) { $Y = 0 }
                if ($Y -gt ($PreviewSurface.ClientSize.Height - $PreviewSubtitle.Height)) { $Y = $PreviewSurface.ClientSize.Height - $PreviewSubtitle.Height }
                $PreviewSubtitle.Location = New-Object System.Drawing.Point($X, $Y)
            }
            else {
                # Em posição personalizada, a personalização é apenas vertical.
                # O X permanece sempre centralizado, para que a legenda não saia do alinhamento horizontal do vídeo.
                $PreviewState.CustomX = [int]($PreviewSurface.ClientSize.Width / 2)
                if ($null -eq $PreviewState.CustomY) {
                    $PreviewState.CustomY = [int]($PreviewSurface.ClientSize.Height - $PreviewSubtitle.Height - $MarginPreview + ($PreviewSubtitle.Height / 2))
                }
                $X = [int](($PreviewSurface.ClientSize.Width - $PreviewSubtitle.Width) / 2)
                $Y = [int]($PreviewState.CustomY - ($PreviewSubtitle.Height / 2))
                if ($X -lt 0) { $X = 0 }
                if ($Y -lt 0) { $Y = 0 }
                if ($X -gt ($PreviewSurface.ClientSize.Width - $PreviewSubtitle.Width)) { $X = $PreviewSurface.ClientSize.Width - $PreviewSubtitle.Width }
                if ($Y -gt ($PreviewSurface.ClientSize.Height - $PreviewSubtitle.Height)) { $Y = $PreviewSurface.ClientSize.Height - $PreviewSubtitle.Height }
                $PreviewSubtitle.Location = New-Object System.Drawing.Point($X, $Y)
                $PreviewState.CustomX = [int]($PreviewSubtitle.Left + ($PreviewSubtitle.Width / 2))
                $PreviewState.CustomY = [int]($PreviewSubtitle.Top + ($PreviewSubtitle.Height / 2))
            }

            $PreviewSurface.Invalidate()
            $PreviewSubtitle.BringToFront()
        }
        catch { }
        finally { $PreviewState.Updating = $false }
    }

    $LblStatus = New-Object System.Windows.Forms.Label
    $LblStatus.Text = "Pronto."
    $LblStatus.Location = New-Object System.Drawing.Point(15, 690)
    $LblStatus.Size = New-Object System.Drawing.Size(860, 24)

    $BtnGerar = New-Object System.Windows.Forms.Button
    $BtnGerar.Text = "Gerar vídeo legendado"
    $BtnGerar.Location = New-Object System.Drawing.Point(575, 725)
    $BtnGerar.Size = New-Object System.Drawing.Size(180, 36)

    $BtnFechar = New-Object System.Windows.Forms.Button
    $BtnFechar.Text = "Fechar"
    $BtnFechar.Location = New-Object System.Drawing.Point(775, 725)
    $BtnFechar.Size = New-Object System.Drawing.Size(110, 36)
    $BtnFechar.Add_Click({ $Dialog.Close() })

    $BtnCor.Add_Click({
        $ColorDialog = New-Object System.Windows.Forms.ColorDialog
        $ColorDialog.FullOpen = $true
        $ColorDialog.Color = $PanelCor.BackColor
        if ($ColorDialog.ShowDialog($Dialog) -eq [System.Windows.Forms.DialogResult]::OK) {
            $PanelCor.BackColor = $ColorDialog.Color
            & $UpdatePreview
            $PreviewSubtitle.Invalidate()
        }
    })

    $BtnSombra.Add_Click({
        $ColorDialog = New-Object System.Windows.Forms.ColorDialog
        $ColorDialog.FullOpen = $true
        $ColorDialog.Color = $PanelSombra.BackColor
        if ($ColorDialog.ShowDialog($Dialog) -eq [System.Windows.Forms.DialogResult]::OK) {
            $PanelSombra.BackColor = $ColorDialog.Color
            & $UpdatePreview
            $PreviewSubtitle.Invalidate()
        }
    })


    $BtnMultiplasLegendas.Add_Click({
        $SubDlg=New-Object System.Windows.Forms.Form; $SubDlg.Text="Legendas do vídeo"; $SubDlg.StartPosition='CenterParent'; $SubDlg.Size=New-Object System.Drawing.Size(910,335); $SubDlg.FormBorderStyle='FixedDialog'; $SubDlg.MaximizeBox=$false; $SubDlg.MinimizeBox=$false
        $Info=New-Object System.Windows.Forms.Label; $Info.Text="Escolha até 3 legendas, a posição e o intervalo em que cada uma permanecerá visível."; $Info.Location=New-Object System.Drawing.Point(15,15); $Info.Size=New-Object System.Drawing.Size(850,24); $SubDlg.Controls.Add($Info)
        foreach($Hdr in @(@{T='Legenda';X=95;W=390},@{T='Posição';X=500;W=105},@{T='Início';X=620;W=80},@{T='Fim';X=715;W=80})){ $H=New-Object System.Windows.Forms.Label; $H.Text=$Hdr.T; $H.Location=New-Object System.Drawing.Point($Hdr.X,48); $H.Size=New-Object System.Drawing.Size($Hdr.W,20); $H.Font=New-Object System.Drawing.Font($SubDlg.Font,[System.Drawing.FontStyle]::Bold); $SubDlg.Controls.Add($H) }
        $Files=@(Get-SubtitleFilesForItem -Item $Item | ForEach-Object {$_.FullName}); $Sources=@('(Legenda atual da grade)')+$Files; $Combos=@(); $Poss=@(); $Starts=@(); $Ends=@()
        for($i=0;$i -lt 3;$i++){
            $Y=75+($i*52); $L=New-Object System.Windows.Forms.Label; $L.Text=("Legenda {0}:" -f ($i+1)); $L.Location=New-Object System.Drawing.Point(15,$Y+3); $L.Size=New-Object System.Drawing.Size(75,22); $SubDlg.Controls.Add($L)
            $C=New-Object System.Windows.Forms.ComboBox; $C.Location=New-Object System.Drawing.Point(95,$Y); $C.Size=New-Object System.Drawing.Size(390,24); $C.DropDownStyle='DropDownList'; [void]$C.Items.Add('(Nenhuma)'); foreach($X in $Sources){[void]$C.Items.Add($X)}
            $P=New-Object System.Windows.Forms.ComboBox; $P.Location=New-Object System.Drawing.Point(500,$Y); $P.Size=New-Object System.Drawing.Size(105,24); $P.DropDownStyle='DropDownList'; @('Superior','Centro','Inferior')|ForEach-Object{[void]$P.Items.Add($_)}
            $TS=New-Object System.Windows.Forms.TextBox; $TS.Location=New-Object System.Drawing.Point(620,$Y); $TS.Size=New-Object System.Drawing.Size(80,24); $TS.Text='00m:00s'
            $TE=New-Object System.Windows.Forms.TextBox; $TE.Location=New-Object System.Drawing.Point(715,$Y); $TE.Size=New-Object System.Drawing.Size(80,24); $TE.Text=(Format-MinSecDisplay -Seconds $VideoDurationSeconds)
            if($i -lt $SubtitleLayers.Count){ $Existing=$SubtitleLayers[$i]; $Wanted=if([string]$Existing.Source -eq 'Grade atual'){'(Legenda atual da grade)'}elseif(-not [string]::IsNullOrWhiteSpace([string]$Existing.Path)){[string]$Existing.Path}else{'(Nenhuma)'}; $Idx=$C.Items.IndexOf($Wanted); if($Idx -ge 0){$C.SelectedIndex=$Idx}else{$C.SelectedIndex=0}; $P.SelectedItem=[string]$Existing.Position; if($null -eq $P.SelectedItem){$P.SelectedItem='Inferior'}; try{$TS.Text=Format-MinSecDisplay -Seconds ([double]$Existing.StartAt)}catch{}; try{$TE.Text=Format-MinSecDisplay -Seconds ([double]$Existing.EndAt)}catch{} } else { $C.SelectedIndex=0; $P.SelectedItem=@('Inferior','Centro','Superior')[$i] }
            $SubDlg.Controls.AddRange(@($C,$P,$TS,$TE)); $Combos+=$C; $Poss+=$P; $Starts+=$TS; $Ends+=$TE
        }
        $TimeHelp=New-Object System.Windows.Forms.Label; $TimeHelp.Text="Formato: 00m:00s. Por padrão, cada legenda vai do início ao fim da música."; $TimeHelp.Location=New-Object System.Drawing.Point(95,235); $TimeHelp.Size=New-Object System.Drawing.Size(700,22); $TimeHelp.ForeColor=[System.Drawing.Color]::DimGray; $SubDlg.Controls.Add($TimeHelp)
        $Ok=New-Object System.Windows.Forms.Button; $Ok.Text='OK'; $Ok.Location=New-Object System.Drawing.Point(680,265); $Ok.Size=New-Object System.Drawing.Size(90,30); $Ok.DialogResult=[System.Windows.Forms.DialogResult]::OK; $SubDlg.Controls.Add($Ok); $SubDlg.AcceptButton=$Ok
        $Cancel=New-Object System.Windows.Forms.Button; $Cancel.Text='Cancelar'; $Cancel.Location=New-Object System.Drawing.Point(780,265); $Cancel.Size=New-Object System.Drawing.Size(90,30); $Cancel.DialogResult=[System.Windows.Forms.DialogResult]::Cancel; $SubDlg.Controls.Add($Cancel); $SubDlg.CancelButton=$Cancel
        if($SubDlg.ShowDialog($Dialog) -eq [System.Windows.Forms.DialogResult]::OK){
            $NewLayers=New-Object System.Collections.ArrayList; $Invalid=$false
            for($i=0;$i -lt 3;$i++){ $Sel=[string]$Combos[$i].SelectedItem; if([string]::IsNullOrWhiteSpace($Sel) -or $Sel -eq '(Nenhuma)'){continue}; $StartAt=Parse-MinSecDisplay -Text ([string]$Starts[$i].Text); $EndAt=Parse-MinSecDisplay -Text ([string]$Ends[$i].Text); if($null -eq $StartAt -or $null -eq $EndAt -or [double]$EndAt -le [double]$StartAt -or [double]$EndAt -gt ([double]$VideoDurationSeconds + 1.0)){ [System.Windows.Forms.MessageBox]::Show(("Verifique o tempo da Legenda {0}. Use 00m:00s, com o fim maior que o início e dentro da duração da música." -f ($i+1)),"Tempo da legenda",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null; $Invalid=$true; break }; if($Sel -eq '(Legenda atual da grade)'){ $RL=@(Get-SubtitleRowsFromGrid); [void]$NewLayers.Add([PSCustomObject]@{Source='Grade atual';Path='';Position=[string]$Poss[$i].SelectedItem;Rows=$RL;StartAt=[double]$StartAt;EndAt=[double]$EndAt}) } elseif(Test-SafePath -Path $Sel){ $RL=@(Read-SrtFileRows -Path $Sel); [void]$NewLayers.Add([PSCustomObject]@{Source=(Split-SafeLeaf -Path $Sel);Path=$Sel;Position=[string]$Poss[$i].SelectedItem;Rows=$RL;StartAt=[double]$StartAt;EndAt=[double]$EndAt}) } }
            if(-not $Invalid){ $SubtitleLayers.Clear(); foreach($NL in $NewLayers){[void]$SubtitleLayers.Add($NL)}; if($SubtitleLayers.Count -eq 0){[void]$SubtitleLayers.Add([PSCustomObject]@{Source='Grade atual';Path='';Position='Inferior';Rows=@(Get-SubtitleRowsFromGrid);StartAt=0.0;EndAt=[double]$VideoDurationSeconds})}; $QtdLegendasAtivas=if($SubtitleLayers.Count -gt 0){[int]$SubtitleLayers.Count}else{1}; $LblMultiplasLegendasStatus.Text=if($QtdLegendasAtivas -eq 1){"1 legenda ativa"}else{"{0} legendas ativas" -f $QtdLegendasAtivas} }
        }
        $SubDlg.Dispose()
    })

    $ComboModoExibicao.Add_SelectedIndexChanged({
        $ModoSelecionado = [string]$ComboModoExibicao.SelectedItem
        if ($ModoSelecionado -eq "Lyric video") {
            $NumTamanho.Value = 140
            $ComboPosicao.SelectedItem = "Centro"
            $NumMargem.Value = 0
            $NumSombraIntensidade.Value = 100
            $NumSombraExpansao.Value = 6
            $BtnGerar.Text = "Gerar lyric video"
            $LblPreview.Text = "Prévia do lyric video:"
            $LblModoAjuda.Text = "Texto grande e centralizado, próprio para acompanhar a letra da música. Você ainda pode personalizar tudo abaixo."
            try {
                $SaidaAtual = [string]$TxtSaida.Text
                if (-not [string]::IsNullOrWhiteSpace($SaidaAtual)) {
                    $SaidaAtual = $SaidaAtual -replace ' - legendado\.mp4$', ' - lyric video.mp4'
                    $TxtSaida.Text = $SaidaAtual
                }
            } catch { }
        }
        else {
            $NumTamanho.Value = 90
            $ComboPosicao.SelectedItem = "Inferior"
            $NumMargem.Value = 0
            $NumSombraIntensidade.Value = 100
            $NumSombraExpansao.Value = 4
            $BtnGerar.Text = "Gerar vídeo legendado"
            $LblPreview.Text = "Prévia da posição:"
            $LblModoAjuda.Text = "O preset altera apenas a apresentação. Os tempos e o texto da legenda continuam os mesmos."
            try {
                $SaidaAtual = [string]$TxtSaida.Text
                if (-not [string]::IsNullOrWhiteSpace($SaidaAtual)) {
                    $SaidaAtual = $SaidaAtual -replace ' - lyric video\.mp4$', ' - legendado.mp4'
                    $TxtSaida.Text = $SaidaAtual
                }
            } catch { }
        }
        & $UpdatePreview
    })

    $ComboPosicao.Add_SelectedIndexChanged({ & $UpdatePreview })
    $NumMargem.Add_ValueChanged({ if (-not $PreviewState.SuppressMarginEvent) { & $UpdatePreview } })
    $NumTamanho.Add_ValueChanged({ & $UpdatePreview })
    $ComboFonte.Add_TextChanged({ & $UpdatePreview })
    $ComboFonte.Add_SelectedIndexChanged({ & $UpdatePreview })
    $NumSombraIntensidade.Add_ValueChanged({ & $UpdatePreview; $PreviewSubtitle.Invalidate() })
    $NumSombraExpansao.Add_ValueChanged({ & $UpdatePreview; $PreviewSubtitle.Invalidate() })

    $PreviewSubtitle.Add_MouseDown({
        param($Sender, $E)
        if ($E.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            $PreviewState.Dragging = $true
            $PreviewState.OffsetX = $E.X
            $PreviewState.OffsetY = $E.Y
            if ([string]$ComboPosicao.SelectedItem -ne "Personalizada") {
                $ComboPosicao.SelectedItem = "Personalizada"
            }
        }
    })

    $PreviewSubtitle.Add_MouseMove({
        param($Sender, $E)
        if (-not $PreviewState.Dragging) { return }

        # O arraste é somente vertical. O X permanece centralizado.
        $NewLeft = [int](($PreviewSurface.ClientSize.Width - $PreviewSubtitle.Width) / 2)
        $NewTop  = $PreviewSubtitle.Top + $E.Y - [int]$PreviewState.OffsetY

        if ($NewTop -lt 0) { $NewTop = 0 }
        if ($NewTop -gt ($PreviewSurface.ClientSize.Height - $PreviewSubtitle.Height)) { $NewTop = $PreviewSurface.ClientSize.Height - $PreviewSubtitle.Height }

        $PreviewSubtitle.Location = New-Object System.Drawing.Point([int]$NewLeft, [int]$NewTop)
        $PreviewState.CustomX = [int]($PreviewSurface.ClientSize.Width / 2)
        $PreviewState.CustomY = [int]($PreviewSubtitle.Top + ($PreviewSubtitle.Height / 2))
        & $SetMarginFromPreviewPosition
    })

    $PreviewSubtitle.Add_MouseUp({
        param($Sender, $E)
        if ($PreviewState.Dragging) {
            $PreviewState.Dragging = $false
            $PreviewState.CustomX = [int]($PreviewSurface.ClientSize.Width / 2)
            $PreviewState.CustomY = [int]($PreviewSubtitle.Top + ($PreviewSubtitle.Height / 2))
            & $SetMarginFromPreviewPosition
        }
    })

    try {
        if (-not [string]::IsNullOrWhiteSpace([string]$TxtVideo.Text) -and (Test-SafePath -Path ([string]$TxtVideo.Text))) {
            $FfprobePreviewInicial = Resolve-Executable "ffprobe.exe"
            if (-not $FfprobePreviewInicial) { $FfprobePreviewInicial = Resolve-Executable "ffprobe" }
            $DimInicial = Get-VideoDimensions -Arquivo ([string]$TxtVideo.Text) -FfprobePath $FfprobePreviewInicial
            $PreviewState.VideoW = [int]$DimInicial.Width
            $PreviewState.VideoH = [int]$DimInicial.Height
        }
    } catch { }
    & $UpdatePreview

    $CheckMostrarFaixaTitulo.Add_CheckedChanged({
        $PreviewState.ShowTrackTitle = [bool]$CheckMostrarFaixaTitulo.Checked
        $HabilitarTempoTitulo = [bool]$CheckMostrarFaixaTitulo.Checked
        $LblTituloInicio.Enabled = $HabilitarTempoTitulo
        $TxtTituloInicio.Enabled = $HabilitarTempoTitulo
        $LblTituloFim.Enabled = $HabilitarTempoTitulo
        $TxtTituloFim.Enabled = $HabilitarTempoTitulo
        $LblTituloTempoInfo.Enabled = $HabilitarTempoTitulo
        $PreviewTitle.Visible = $false
        $PreviewSurface.Invalidate()
        $PreviewSurface.Refresh()
    })

    $BtnVideo.Add_Click({
        $Open = New-Object System.Windows.Forms.OpenFileDialog
        $Open.Title = "Selecionar vídeo"
        $Open.Filter = "Vídeos MP4|*.mp4|Vídeos|*.mp4;*.mkv;*.mov;*.avi|Todos os arquivos|*.*"
        $Open.Multiselect = $false
        if ($Open.ShowDialog($Dialog) -eq [System.Windows.Forms.DialogResult]::OK) {
            $TxtVideo.Text = $Open.FileName
            $TxtSaida.Text = Get-DefaultBurnedSubtitleVideoPath -Item $Item -VideoPath $Open.FileName
            try {
                $FfprobePreview = Resolve-Executable "ffprobe.exe"
                if (-not $FfprobePreview) { $FfprobePreview = Resolve-Executable "ffprobe" }
                $DimSel = Get-VideoDimensions -Arquivo $Open.FileName -FfprobePath $FfprobePreview
                $PreviewState.VideoW = [int]$DimSel.Width
                $PreviewState.VideoH = [int]$DimSel.Height
                $OldDuration=[double]$VideoDurationSeconds; $NewDuration=Get-MediaDuration -Arquivo $Open.FileName -FfprobePath $FfprobePreview
                if($null -ne $NewDuration -and [double]$NewDuration -gt 0){ $VideoDurationSeconds=[double]$NewDuration; $TxtTituloFim.Text=Format-MinSecDisplay -Seconds $VideoDurationSeconds; foreach($Layer in @($SubtitleLayers)){ try{ if([Math]::Abs(([double]$Layer.EndAt)-$OldDuration) -lt 1.1){$Layer.EndAt=[double]$VideoDurationSeconds} }catch{} } }
                & $UpdatePreview
            } catch { }
        }
    })

    $BtnSaida.Add_Click({
        $Save = New-Object System.Windows.Forms.SaveFileDialog
        $Save.Title = "Salvar vídeo legendado"
        $Save.Filter = "Vídeo MP4|*.mp4"
        $Save.FileName = [System.IO.Path]::GetFileName($TxtSaida.Text)
        $InitialDir = Split-SafeParent -Path $TxtSaida.Text
        if (-not [string]::IsNullOrWhiteSpace($InitialDir) -and (Test-SafePath -Path $InitialDir)) {
            $Save.InitialDirectory = $InitialDir
        }
        if ($Save.ShowDialog($Dialog) -eq [System.Windows.Forms.DialogResult]::OK) {
            $TxtSaida.Text = $Save.FileName
        }
    })

    $BtnGerar.Add_Click({
        try {
            $VideoPath = [string]$TxtVideo.Text
            $OutputPath = [string]$TxtSaida.Text

            if ([string]::IsNullOrWhiteSpace($VideoPath) -or -not (Test-SafePath -Path $VideoPath)) {
                [System.Windows.Forms.MessageBox]::Show("Selecione um vídeo MP4 existente.", "Vídeo legendado", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
                return
            }

            if (Test-SafePath -Path $OutputPath) {
                $Resp = [System.Windows.Forms.MessageBox]::Show("O arquivo de saída já existe. Deseja sobrescrever?`n$OutputPath", "Vídeo legendado", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
                if ($Resp -ne [System.Windows.Forms.DialogResult]::Yes) { return }
            }

            $TrackTitleStart=Parse-MinSecDisplay -Text ([string]$TxtTituloInicio.Text); $TrackTitleEnd=Parse-MinSecDisplay -Text ([string]$TxtTituloFim.Text)
            if([bool]$CheckMostrarFaixaTitulo.Checked){ if($null -eq $TrackTitleStart -or $null -eq $TrackTitleEnd -or [double]$TrackTitleEnd -le [double]$TrackTitleStart -or [double]$TrackTitleEnd -gt ([double]$VideoDurationSeconds + 1.0)){ [System.Windows.Forms.MessageBox]::Show("Verifique os tempos da faixa com o nome da música. Use 00m:00s, com o fim maior que o início e dentro da duração da música.","Tempo da faixa",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)|Out-Null; return } } else { $TrackTitleStart=0.0; $TrackTitleEnd=[double]$VideoDurationSeconds }

            $BtnGerar.Enabled = $false
            $BtnFechar.Enabled = $false
            $LblStatus.Text = if ([string]$ComboModoExibicao.SelectedItem -eq "Lyric video") { "Gerando lyric video..." } else { "Gerando vídeo legendado..." }
            $LblStatus.Refresh()

            $CustomVideoX = $null
            $CustomVideoY = $null
            if ([string]$ComboPosicao.SelectedItem -eq "Personalizada" -and $null -ne $PreviewState.CustomX -and $null -ne $PreviewState.CustomY) {
                $FfprobeParaPreview = Resolve-Executable "ffprobe.exe"
                if (-not $FfprobeParaPreview) { $FfprobeParaPreview = Resolve-Executable "ffprobe" }
                $DimPreview = Get-VideoDimensions -Arquivo $VideoPath -FfprobePath $FfprobeParaPreview
                # A posição personalizada permite apenas deslocamento vertical; o X final permanece centralizado no vídeo.
                $CustomVideoX = [int]([double]$DimPreview.Width / 2.0)
                $CustomVideoY = [int]([double]$PreviewState.CustomY * [double]$DimPreview.Height / [double]$PreviewSurface.ClientSize.Height)
            }

            $script:BurnedSubtitleStyle = [PSCustomObject]@{
                DisplayMode = [string]$ComboModoExibicao.SelectedItem
                FontName = [string]$ComboFonte.Text
                FontSize = [int]$NumTamanho.Value
                Position = [string]$ComboPosicao.SelectedItem
                MarginV = [int]$NumMargem.Value
                FontColor = $PanelCor.BackColor
                ShadowColor = $PanelSombra.BackColor
                ShadowIntensity = [int]$NumSombraIntensidade.Value
                ShadowSpread = [int]$NumSombraExpansao.Value
                ShowTrackTitle = [bool]$CheckMostrarFaixaTitulo.Checked
                TrackTitle = [string]$PreviewTitle.Text
                TrackTitleStart = [double]$TrackTitleStart
                TrackTitleEnd = [double]$TrackTitleEnd
                CustomX = $CustomVideoX
                CustomY = $CustomVideoY
            }

            if ($SubtitleLayers.Count -gt 1) {
                $Ok = Invoke-BurnMultipleSubtitlesIntoVideo `
                    -VideoPath $VideoPath -Layers @($SubtitleLayers) -OutputPath $OutputPath `
                    -FontName ([string]$ComboFonte.Text) -FontSize ([int]$NumTamanho.Value) -MarginV ([int]$NumMargem.Value) `
                    -FontColor $PanelCor.BackColor -ShadowColor $PanelSombra.BackColor `
                    -ShadowIntensity ([int]$NumSombraIntensidade.Value) -ShadowSpread ([int]$NumSombraExpansao.Value) `
                    -ShowTrackTitle ([bool]$CheckMostrarFaixaTitulo.Checked) -TrackTitle ([string]$PreviewTitle.Text) `
                    -TrackTitleStartSeconds ([double]$TrackTitleStart) -TrackTitleEndSeconds ([double]$TrackTitleEnd) `
                    -StatusLabel $LblStatus -LogBox $LogBox
            }
            else {
                $RowsAtuais = if ($SubtitleLayers.Count -eq 1) { @($SubtitleLayers[0].Rows) } else { @($Rows) }
                $PosAtual = if ($SubtitleLayers.Count -eq 1) { [string]$SubtitleLayers[0].Position } else { [string]$ComboPosicao.SelectedItem }
                $SubStartAt=0.0; $SubEndAt=[double]$VideoDurationSeconds; if($SubtitleLayers.Count -eq 1){try{$SubStartAt=[double]$SubtitleLayers[0].StartAt; $SubEndAt=[double]$SubtitleLayers[0].EndAt}catch{}}
                $Ok = Invoke-BurnSubtitlesIntoVideo `
                    -VideoPath $VideoPath -Rows $RowsAtuais -OutputPath $OutputPath `
                    -FontName ([string]$ComboFonte.Text) -FontSize ([int]$NumTamanho.Value) `
                    -Position $PosAtual -MarginV ([int]$NumMargem.Value) `
                    -FontColor $PanelCor.BackColor -ShadowColor $PanelSombra.BackColor `
                    -ShadowIntensity ([int]$NumSombraIntensidade.Value) -ShadowSpread ([int]$NumSombraExpansao.Value) `
                    -SubtitleStartSeconds ([double]$SubStartAt) -SubtitleEndSeconds ([double]$SubEndAt) `
                    -ShowTrackTitle ([bool]$CheckMostrarFaixaTitulo.Checked) -TrackTitle ([string]$PreviewTitle.Text) `
                    -TrackTitleStartSeconds ([double]$TrackTitleStart) -TrackTitleEndSeconds ([double]$TrackTitleEnd) `
                    -CustomX $CustomVideoX -CustomY $CustomVideoY -StatusLabel $LblStatus -LogBox $LogBox
            }

            if ($Ok) {
                $MensagemConcluida = if ([string]$ComboModoExibicao.SelectedItem -eq "Lyric video") { "Lyric video gerado em:`n$OutputPath" } else { "Vídeo legendado gerado em:`n$OutputPath" }
                [System.Windows.Forms.MessageBox]::Show($MensagemConcluida, "Vídeo legendado", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            }
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Erro ao gerar vídeo legendado", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            Add-Log -LogBox $LogBox -Mensagem "ERRO no vídeo legendado: $($_.Exception.Message)"
        }
        finally {
            $BtnGerar.Enabled = $true
            $BtnFechar.Enabled = $true
            if ($LblStatus.Text -ne "Interrompido.") { $LblStatus.Text = "Pronto." }
        }
    })

    $Dialog.Controls.AddRange(@(
        $LblInfo,
        $LblVideo, $TxtVideo, $BtnVideo,
        $LblSaida, $TxtSaida, $BtnSaida,
        $LblFonte, $ComboFonte,
        $LblTamanho, $NumTamanho,
        $LblCor, $PanelCor, $BtnCor,
        $LblSombra, $PanelSombra, $BtnSombra, $LblSombraIntensidade, $NumSombraIntensidade, $LblSombraExpansao, $NumSombraExpansao,
        $LblPosicao, $ComboPosicao,
        $LblMargem, $NumMargem,
        $LblModoExibicao, $ComboModoExibicao, $BtnMultiplasLegendas, $LblMultiplasLegendasStatus, $LblModoAjuda,
        $LblPreview, $CheckMostrarFaixaTitulo, $LblTituloInicio, $TxtTituloInicio, $LblTituloFim, $TxtTituloFim, $LblTituloTempoInfo, $PreviewPanel,
        $LblStatus,
        $BtnGerar, $BtnFechar
    ))

    $Dialog.ShowDialog($Form) | Out-Null
}



function Get-SelectedSeparateAudioItem {
    if ($null -ne $ComboSepMusica -and $null -ne $ComboSepMusica.SelectedItem) {
        return $ComboSepMusica.SelectedItem
    }
    return Get-SelectedSubtitleItem
}

function Start-SeparateAudioForSelected {
    param([object]$Item)

    if ($null -eq $Item) {
        $Item = Get-SelectedSeparateAudioItem
    }

    if ($null -eq $Item) {
        [System.Windows.Forms.MessageBox]::Show("Selecione uma música antes de separar vocal/instrumental.", "Separar Áudio", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }

    if (-not (Test-SafePath -Path ([string]$Item.FilePath))) {
        [System.Windows.Forms.MessageBox]::Show("Arquivo MP3 não encontrado:`n$($Item.FilePath)", "Separar Áudio", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    if ([string]::IsNullOrWhiteSpace($TextLegPastaLegendas.Text)) {
        $TextLegPastaLegendas.Text = Get-AutoSubtitlePath -PastaMP3 $TextPastaMP3.Text
        $TextPastaLegendas.Text = $TextLegPastaLegendas.Text
    }

    $DemucsPath = Resolve-DemucsExecutable
    if ([string]::IsNullOrWhiteSpace($DemucsPath)) {
        [System.Windows.Forms.MessageBox]::Show("Demucs não encontrado. Instale no mesmo ambiente whisper_env ou coloque demucs.exe/demucs.bat na pasta APP.", "Demucs não encontrado", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    $OutputDir = Get-SeparatedAudioOutputDirectory -Item $Item -BaseDirectory $TextLegPastaLegendas.Text
    $Overwrite = $false
    $NomeBase = [string]$Item.BaseName
    $VocalsPath = Join-SafePath $OutputDir ($NomeBase + "_vocals.wav")
    $InstrumentalPath = Join-SafePath $OutputDir ($NomeBase + "_instrumental.wav")

    if ((Test-SafePath -Path $VocalsPath) -or (Test-SafePath -Path $InstrumentalPath)) {
        $Resp = [System.Windows.Forms.MessageBox]::Show(
            "Já existe áudio separado para esta música.`n`nSim = reutilizar arquivos existentes`nNão = substituir e separar novamente`nCancelar = não fazer nada",
            "Áudio separado existente",
            [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )

        if ($Resp -eq [System.Windows.Forms.DialogResult]::Yes) {
            [System.Windows.Forms.MessageBox]::Show("Arquivos existentes:`n`nVocal:`n$VocalsPath`n`nInstrumental:`n$InstrumentalPath", "Áudio separado", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            return
        }
        elseif ($Resp -eq [System.Windows.Forms.DialogResult]::No) {
            $Overwrite = $true
        }
        else {
            return
        }
    }

    $script:CancelarGeracao = $false
    $Processing = Show-ProcessingForm -MainForm $Form
    $Resultado = $null

    try {
        Add-Log -LogBox $Processing.LogBox -Mensagem "Separação de vocal e instrumental da música selecionada."
        $Resultado = Invoke-DemucsSeparation `
            -ArquivoMP3 ([string]$Item.FilePath) `
            -OutputDirectory $OutputDir `
            -DemucsPath $DemucsPath `
            -Detalhado ([bool]$CheckDetalhado.Checked) `
            -StatusLabel $Processing.StatusLabel `
            -LogBox $Processing.LogBox `
            -Overwrite $Overwrite
    }
    catch {
        if ($script:CancelarGeracao) {
            Add-Log -LogBox $Processing.LogBox -Mensagem "Separação interrompida pelo usuário."
            $Processing.StatusLabel.Text = "Interrompido."
            $Resultado = [PSCustomObject]@{ Status = "Interrompido"; VocalsPath = $VocalsPath; InstrumentalPath = $InstrumentalPath; Tempo = "INTERROMPIDO" }
        }
        else {
            Add-Log -LogBox $Processing.LogBox -Mensagem "ERRO INESPERADO: $($_.Exception.Message)"
            $Processing.StatusLabel.Text = "Erro inesperado."
        }
    }
    finally {
        $Processing.ButtonInterromper.Enabled = $false
        $script:ProcessoAtual = $null
        $Form.Show()
        $Form.Refresh()
    }

    if ($null -eq $Resultado) { return }

    if ($Resultado.Status -eq "Gerado" -or $Resultado.Status -eq "Existente") {
        [System.Windows.Forms.MessageBox]::Show("Separação concluída:`n`nVocal:`n$($Resultado.VocalsPath)`n`nInstrumental:`n$($Resultado.InstrumentalPath)", "Separar Áudio", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    }
    elseif ($Resultado.Status -eq "Interrompido") {
        [System.Windows.Forms.MessageBox]::Show("Separação interrompida.", "Separar Áudio", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    }
    else {
        [System.Windows.Forms.MessageBox]::Show("Não foi possível separar vocal/instrumental. Abra o log da janela de processamento para ver o erro.", "Separar Áudio", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    }
}


function Start-SeparateAudioForSelectedAlbum {
    $Album = $null
    if ($null -ne $ComboSepMusica -and $null -ne $ComboSepMusica.SelectedItem) {
        $Album = [string]$ComboSepMusica.SelectedItem.Album
    }

    if ([string]::IsNullOrWhiteSpace($Album)) {
        [System.Windows.Forms.MessageBox]::Show("Selecione uma música do álbum que deseja processar.", "Separar Áudio", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }

    $Items = @($script:ItensLegenda | Where-Object { $_.Album -eq $Album } | Sort-Object BaseName)
    if ($Items.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Nenhuma música encontrada para o álbum selecionado.", "Separar Áudio", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    $Resp = [System.Windows.Forms.MessageBox]::Show("Separar vocal/instrumental de todas as músicas do álbum:`n`n$Album`n`nTotal: $($Items.Count) música(s).", "Separar álbum", [System.Windows.Forms.MessageBoxButtons]::OKCancel, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($Resp -ne [System.Windows.Forms.DialogResult]::OK) { return }

    foreach ($Item in $Items) {
        if ($script:CancelarGeracao) { break }
        Start-SeparateAudioForSelected -Item $Item
    }
}

function Load-SelectedSeparateAudioInfo {
    $Item = Get-SelectedSeparateAudioItem
    if ($null -eq $Item) { return }

    if ($null -ne $TextSepArquivoMP3) { $TextSepArquivoMP3.Text = [string]$Item.FilePath }
    if ($null -ne $LabelSepDuracao) { $LabelSepDuracao.Text = "Duração: " + (Format-Duration ([double]$Item.Duration)) }
    if ($null -ne $TextSepDestino) {
        $Base = $TextLegPastaLegendas.Text
        if ([string]::IsNullOrWhiteSpace($Base)) { $Base = Get-AutoSubtitlePath -PastaMP3 $TextPastaMP3.Text }
        $TextSepDestino.Text = Get-SeparatedAudioOutputDirectory -Item $Item -BaseDirectory $Base
    }
}

function Merge-AlbumSrtFromTrackFilesManual {
    param(
        [string]$Album,
        [double]$SilencioEntreFaixas
    )

    if ([string]::IsNullOrWhiteSpace($Album)) {
        [System.Windows.Forms.MessageBox]::Show("Selecione um álbum.", "Legendas", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }

    $FfprobePath = Resolve-Executable "ffprobe.exe"
    if (-not $FfprobePath) { $FfprobePath = Resolve-Executable "ffprobe" }

    $Items = @($script:ItensLegenda | Where-Object { $_.Album -eq $Album } | Sort-Object BaseName)

    if ($Items.Count -eq 0) {
        Refresh-SubtitleMusicList
        $Items = @($script:ItensLegenda | Where-Object { $_.Album -eq $Album } | Sort-Object BaseName)
    }

    if ($Items.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Nenhuma música encontrada para o álbum selecionado.", "Legendas", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    $OutputDir = Join-SafePath $TextLegPastaLegendas.Text $Album
    New-SafeDirectory -Path $OutputDir | Out-Null

    $AlbumNameClean = Get-CleanAlbumName -NomeAlbum $Album
    $OutputPath = Join-SafePath $OutputDir ("Álbum Completo - " + $AlbumNameClean + ".srt")

    $MergedRows = @()
    $CurrentTime = 0.0
    $Missing = @()

    foreach ($Item in $Items) {
        $SrtPath = Get-SubtitleSrtPathForItem -Item $Item
        if (-not (Test-SafePath -Path $SrtPath)) {
            $Missing += [string]$Item.BaseName
        }
        else {
            $Rows = @(Read-SrtFileRows -Path $SrtPath)
            foreach ($Row in $Rows) {
                $Start = Parse-SrtTime -Text ([string]$Row.Start)
                $End = Parse-SrtTime -Text ([string]$Row.End)

                $MergedRows += [PSCustomObject]@{
                    Index = ($MergedRows.Count + 1)
                    Start = (Format-SrtTime -Seconds ($Start + $CurrentTime))
                    End   = (Format-SrtTime -Seconds ($End + $CurrentTime))
                    Text  = [string]$Row.Text
                }
            }
        }

        $Duration = [double]$Item.Duration
        if ($Duration -le 0 -and -not [string]::IsNullOrWhiteSpace($FfprobePath)) {
            $D = Get-MediaDuration -Arquivo ([string]$Item.FilePath) -FfprobePath $FfprobePath
            if ($null -ne $D) { $Duration = [double]$D }
        }

        $CurrentTime += $Duration + [double]$SilencioEntreFaixas
    }

    if ($Missing.Count -gt 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "Algumas faixas não possuem SRT e foram ignoradas:`n`n" + ($Missing -join [Environment]::NewLine),
            "Legendas ausentes",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }

    if ($MergedRows.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Nenhuma legenda encontrada para montar o SRT do álbum.", "Legendas", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    $SrtText = Convert-SubtitleRowsToSrtText -Rows $MergedRows
    [System.IO.File]::WriteAllText($OutputPath, $SrtText, [System.Text.Encoding]::UTF8)

    [System.Windows.Forms.MessageBox]::Show("Legenda do álbum salva em:`n$OutputPath", "Legendas", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
}

# ============================================================
# TELA PRINCIPAL
# ============================================================

$Form = New-Object System.Windows.Forms.Form
$Form.Text = "Gerador e Publicador de Vídeos FREZZA"
$Form.Size = New-Object System.Drawing.Size(1180, 850)
Set-FormIcon -TargetForm $Form
$Form.StartPosition = "CenterScreen"
$Form.Font = New-Object System.Drawing.Font("Century Gothic", 9)
$Form.MinimumSize = New-Object System.Drawing.Size(1100, 760)
$Form.KeyPreview = $true

$TabControl = New-Object System.Windows.Forms.TabControl
$TabControl.Location = New-Object System.Drawing.Point(10, 12)
$TabControl.Size = New-Object System.Drawing.Size(($Form.ClientSize.Width - 20), ($Form.ClientSize.Height - 22))
$TabControl.Anchor = "Top,Bottom,Left,Right"
$TabControl.DrawMode = [System.Windows.Forms.TabDrawMode]::OwnerDrawFixed
$TabControl.SizeMode = [System.Windows.Forms.TabSizeMode]::Normal

$TabControl.Add_DrawItem({
    param($sender, $e)

    try {
        $TabControlSender = [System.Windows.Forms.TabControl]$sender
        $Args = [System.Windows.Forms.DrawItemEventArgs]$e

        $Tab = $TabControlSender.TabPages[$Args.Index]
        $Rect = [System.Drawing.Rectangle]$Args.Bounds
        $IsSelected = ($TabControlSender.SelectedIndex -eq $Args.Index)

        if ($script:TemaEscuro) {
            if ($IsSelected) {
                $BackColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
                $ForeColor = [System.Drawing.Color]::White
            }
            else {
                $BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
                $ForeColor = [System.Drawing.Color]::Gainsboro
            }
        }
        else {
            if ($IsSelected) {
                $BackColor = [System.Drawing.SystemColors]::Window
            }
            else {
                $BackColor = [System.Drawing.SystemColors]::Control
            }

            $ForeColor = [System.Drawing.SystemColors]::ControlText
        }

        $BrushBack = New-Object System.Drawing.SolidBrush($BackColor)
        $BrushText = New-Object System.Drawing.SolidBrush($ForeColor)
        $Format = New-Object System.Drawing.StringFormat

        try {
            $Args.Graphics.FillRectangle($BrushBack, $Rect)

            $TextRect = [System.Drawing.RectangleF]::new(
                [single]$Rect.X,
                [single]($Rect.Y + 2),
                [single]$Rect.Width,
                [single]($Rect.Height - 2)
            )

            $Format.Alignment = [System.Drawing.StringAlignment]::Center
            $Format.LineAlignment = [System.Drawing.StringAlignment]::Center

            $Args.Graphics.DrawString(
                [string]$Tab.Text,
                $TabControlSender.Font,
                $BrushText,
                $TextRect,
                $Format
            )
        }
        finally {
            if ($BrushBack) { $BrushBack.Dispose() }
            if ($BrushText) { $BrushText.Dispose() }
            if ($Format) { $Format.Dispose() }
        }
    }
    catch {
        # Evita que erro de desenho trave a interface.
    }
})

$ButtonAlternarTema = New-Object System.Windows.Forms.Button
$ButtonAlternarTema.Text = "Tema escuro"
$ButtonAlternarTema.Location = New-Object System.Drawing.Point(($Form.ClientSize.Width - 150), 14)
$ButtonAlternarTema.Size = New-Object System.Drawing.Size(130, 28)
$ButtonAlternarTema.Anchor = "Top,Right"
$ButtonAlternarTema.BringToFront()

$Form.Controls.Add($ButtonAlternarTema)

$ButtonSalvarProjeto = New-Object System.Windows.Forms.Button
$ButtonSalvarProjeto.Text = "Salvar projeto"
$ButtonSalvarProjeto.Size = New-Object System.Drawing.Size(125, 28)
$ButtonSalvarProjeto.Location = New-Object System.Drawing.Point(($Form.ClientSize.Width - 420), 14)
$ButtonSalvarProjeto.Anchor = "Top,Right"
$Form.Controls.Add($ButtonSalvarProjeto)

$ButtonAbrirProjeto = New-Object System.Windows.Forms.Button
$ButtonAbrirProjeto.Text = "Abrir projeto"
$ButtonAbrirProjeto.Size = New-Object System.Drawing.Size(125, 28)
$ButtonAbrirProjeto.Location = New-Object System.Drawing.Point(($Form.ClientSize.Width - 285), 14)
$ButtonAbrirProjeto.Anchor = "Top,Right"
$Form.Controls.Add($ButtonAbrirProjeto)

$TabPrincipal = New-Object System.Windows.Forms.TabPage
$TabPrincipal.Text = "Escanear"

$TabMusicas = New-Object System.Windows.Forms.TabPage
$TabMusicas.Text = "Músicas"

$TabAlbuns = New-Object System.Windows.Forms.TabPage
$TabAlbuns.Text = "Álbuns"

$TabLegendas = New-Object System.Windows.Forms.TabPage
$TabLegendas.Text = "Legendas"

$TabSepararAudio = New-Object System.Windows.Forms.TabPage
$TabSepararAudio.Text = "Separar Áudio"

$TabPublicacao = New-Object System.Windows.Forms.TabPage
$TabPublicacao.Text = "Publicação"

$TabAjuda = New-Object System.Windows.Forms.TabPage
$TabAjuda.Text = "Ajuda"

$TabControl.TabPages.Add($TabPrincipal) | Out-Null
$TabControl.TabPages.Add($TabMusicas) | Out-Null
$TabControl.TabPages.Add($TabAlbuns) | Out-Null
$TabControl.TabPages.Add($TabLegendas) | Out-Null
$TabControl.TabPages.Add($TabSepararAudio) | Out-Null
$TabControl.TabPages.Add($TabPublicacao) | Out-Null
$TabControl.TabPages.Add($TabAjuda) | Out-Null

$Form.Controls.Add($TabControl)

$TabHeaderFillPanel = New-Object System.Windows.Forms.Panel
$TabHeaderFillPanel.Location = New-Object System.Drawing.Point(340, 10)
$TabHeaderFillPanel.Size = New-Object System.Drawing.Size(805, 30)
$TabHeaderFillPanel.Anchor = "Top,Left,Right"
$TabHeaderFillPanel.BackColor = [System.Drawing.SystemColors]::Control
$TabHeaderFillPanel.Visible = $false

$Form.Controls.Add($TabHeaderFillPanel)
$TabHeaderFillPanel.BringToFront()
$ButtonAlternarTema.BringToFront()
Update-TabHeaderFillPanel

$GroupEntrada = New-Object System.Windows.Forms.GroupBox
$GroupEntrada.Text = "1. Entrada"
$GroupEntrada.Location = New-Object System.Drawing.Point(15, 15)
$GroupEntrada.Size = New-Object System.Drawing.Size(1095, 140)

$GroupOpcoes = New-Object System.Windows.Forms.GroupBox
$GroupOpcoes.Text = "2. Gerar vídeo e/ou legendas"
$GroupOpcoes.Location = New-Object System.Drawing.Point(15, 165)
$GroupOpcoes.Size = New-Object System.Drawing.Size(1095, 140)

$GroupAcoes = New-Object System.Windows.Forms.GroupBox
$GroupAcoes.Text = "3. Escaneamento e processamento"
$GroupAcoes.Location = New-Object System.Drawing.Point(15, 315)
$GroupAcoes.Size = New-Object System.Drawing.Size(1095, 80)

$LabelGrupoGeracao = New-Object System.Windows.Forms.Label
$LabelGrupoGeracao.Text = "Escaneamento"
$LabelGrupoGeracao.Location = New-Object System.Drawing.Point(15, 18)
$LabelGrupoGeracao.Size = New-Object System.Drawing.Size(140, 18)

$LabelGrupoSelecao = New-Object System.Windows.Forms.Label
$LabelGrupoSelecao.Text = "Seleção"
$LabelGrupoSelecao.Location = New-Object System.Drawing.Point(470, 18)
$LabelGrupoSelecao.Size = New-Object System.Drawing.Size(140, 18)

$LabelGrupoImagem = New-Object System.Windows.Forms.Label
$LabelGrupoImagem.Text = "Imagem"
$LabelGrupoImagem.Location = New-Object System.Drawing.Point(900, 18)
$LabelGrupoImagem.Size = New-Object System.Drawing.Size(140, 18)


$LabelPastaMP3 = New-Label -Text "Pasta de MP3:" -X 20 -Y 25
$TextPastaMP3 = New-TextBox -Text "" -X 170 -Y 25 -Width 720

$ButtonPastaMP3 = New-Object System.Windows.Forms.Button
$ButtonPastaMP3.Text = "Escolher..."
$ButtonPastaMP3.Location = New-Object System.Drawing.Point(905, 23)
$ButtonPastaMP3.Size = New-Object System.Drawing.Size(110, 28)

$LabelPastaVideo = New-Label -Text "Pasta de VÍDEOS:" -X 20 -Y 65
$TextPastaVideo = New-TextBox -Text "" -X 170 -Y 65 -Width 720

$ButtonPastaVideo = New-Object System.Windows.Forms.Button
$ButtonPastaVideo.Text = "Escolher..."
$ButtonPastaVideo.Location = New-Object System.Drawing.Point(905, 63)
$ButtonPastaVideo.Size = New-Object System.Drawing.Size(110, 28)

$LabelPastaLegendas = New-Label -Text "Pasta de LEGENDAS:" -X 20 -Y 105 -Width 145
$TextPastaLegendas = New-TextBox -Text "" -X 170 -Y 105 -Width 720

$ButtonPastaLegendas = New-Object System.Windows.Forms.Button
$ButtonPastaLegendas.Text = "Escolher..."
$ButtonPastaLegendas.Location = New-Object System.Drawing.Point(905, 103)
$ButtonPastaLegendas.Size = New-Object System.Drawing.Size(110, 28)

$LabelPastaVideo.Visible = $false
$TextPastaVideo.Visible = $false
$ButtonPastaVideo.Visible = $false

$LabelCapa = New-Label -Text "Nome da capa preferida:" -X 20 -Y 105 -Width 145
$TextCapa = New-TextBox -Text "" -X 170 -Y 105 -Width 300
$LabelCapa.Visible = $false
$TextCapa.Visible = $false

$CheckSaidaAutomatica = New-Object System.Windows.Forms.CheckBox
$CheckSaidaAutomatica.Text = "Criar pasta VÍDEOS ao lado da pasta MP3"
$CheckSaidaAutomatica.Location = New-Object System.Drawing.Point(500, 65)
$CheckSaidaAutomatica.Size = New-Object System.Drawing.Size(360, 24)
$CheckSaidaAutomatica.Checked = $true
$CheckSaidaAutomatica.Visible = $false

$LabelModoLeitura = New-Label -Text "Modo de leitura:" -X 20 -Y 65 -Width 145
$ComboModoLeitura = New-Object System.Windows.Forms.ComboBox
$ComboModoLeitura.Location = New-Object System.Drawing.Point(170, 65)
$ComboModoLeitura.Size = New-Object System.Drawing.Size(360, 24)
$ComboModoLeitura.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$ComboModoLeitura.Items.Add("Detectar automaticamente")
[void]$ComboModoLeitura.Items.Add("Cada subpasta é um álbum")
[void]$ComboModoLeitura.Items.Add("Pasta selecionada é um álbum único")
$ComboModoLeitura.SelectedIndex = 0

$CheckGerarMusicas = New-Object System.Windows.Forms.CheckBox
$CheckGerarMusicas.Text = "Gerar vídeo para cada música"
$CheckGerarMusicas.Location = New-Object System.Drawing.Point(20, 110)
$CheckGerarMusicas.Size = New-Object System.Drawing.Size(230, 24)
$CheckGerarMusicas.Checked = $true

$LabelExtra = New-Label -Text "Silêncio final (segundos):" -X 280 -Y 145 -Width 170
$NumericExtra = New-Object System.Windows.Forms.NumericUpDown
$NumericExtra.Location = New-Object System.Drawing.Point(455, 110)
$NumericExtra.Size = New-Object System.Drawing.Size(80, 24)
$NumericExtra.DecimalPlaces = 1
$NumericExtra.Minimum = 0
$NumericExtra.Maximum = 60
$NumericExtra.Value = 1

$CheckGerarAlbum = New-Object System.Windows.Forms.CheckBox
$CheckGerarAlbum.Text = "Gerar vídeo do álbum inteiro"
$CheckGerarAlbum.Location = New-Object System.Drawing.Point(20, 145)
$CheckGerarAlbum.Size = New-Object System.Drawing.Size(230, 24)
$CheckGerarAlbum.Checked = $false

$LabelSilencioEntreFaixas = New-Label -Text "Silêncio entre faixas (segundos):" -X 280 -Y 180 -Width 170
$NumericSilencioEntreFaixas = New-Object System.Windows.Forms.NumericUpDown
$NumericSilencioEntreFaixas.Location = New-Object System.Drawing.Point(455, 145)
$NumericSilencioEntreFaixas.Size = New-Object System.Drawing.Size(80, 24)
$NumericSilencioEntreFaixas.DecimalPlaces = 1
$NumericSilencioEntreFaixas.Minimum = 0
$NumericSilencioEntreFaixas.Maximum = 60
$NumericSilencioEntreFaixas.Value = 1

$CheckDetalhado = New-Object System.Windows.Forms.CheckBox
$CheckDetalhado.Text = "Modo detalhado de log"
$CheckDetalhado.Location = New-Object System.Drawing.Point(575, 110)
$CheckDetalhado.Size = New-Object System.Drawing.Size(150, 24)
$CheckDetalhado.Checked = $false

$CheckValidarDuracao = New-Object System.Windows.Forms.CheckBox
$CheckValidarDuracao.Text = "Validar duração dos vídeos existentes"
$CheckValidarDuracao.Location = New-Object System.Drawing.Point(575, 145)
$CheckValidarDuracao.Size = New-Object System.Drawing.Size(300, 24)
$CheckValidarDuracao.Checked = $false

$ButtonEscanear = New-Object System.Windows.Forms.Button
$ButtonEscanear.Text = "Escanear músicas e álbuns"
$ButtonEscanear.Location = New-Object System.Drawing.Point(20, 190)
$ButtonEscanear.Size = New-Object System.Drawing.Size(140, 34)

$ProgressEscanear = New-Object System.Windows.Forms.ProgressBar
$ProgressEscanear.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
$ProgressEscanear.MarqueeAnimationSpeed = 28
$ProgressEscanear.Location = New-Object System.Drawing.Point(405, 43)
$ProgressEscanear.Size = New-Object System.Drawing.Size(430, 22)
$ProgressEscanear.Visible = $false
$LabelProgressoEscanear = New-Object System.Windows.Forms.Label
$LabelProgressoEscanear.Text = "Escaneando e lendo capas dos MP3..."
$LabelProgressoEscanear.Location = New-Object System.Drawing.Point(845, 43)
$LabelProgressoEscanear.Size = New-Object System.Drawing.Size(230, 22)
$LabelProgressoEscanear.Visible = $false

$ButtonGerarTodos = New-Object System.Windows.Forms.Button
$ButtonGerarTodos.Text = "Gerar todos os itens marcados"
$ButtonGerarTodos.Location = New-Object System.Drawing.Point(180, 38)
$ButtonGerarTodos.Size = New-Object System.Drawing.Size(210, 34)

$GridMusicas = New-MediaGrid
$GridMusicas.Location = New-Object System.Drawing.Point(15, 60)
$GridMusicas.Size = New-Object System.Drawing.Size(1095, 665)

$GridAlbuns = New-MediaGrid
$GridAlbuns.Location = New-Object System.Drawing.Point(15, 60)
$GridAlbuns.Size = New-Object System.Drawing.Size(1095, 665)

$ButtonMarcarTodosMusicas = New-Object System.Windows.Forms.Button
$ButtonMarcarTodosMusicas.Text = "Marcar todos"
$ButtonMarcarTodosMusicas.Location = New-Object System.Drawing.Point(15, 15)
$ButtonMarcarTodosMusicas.Size = New-Object System.Drawing.Size(115, 34)

$ButtonDesmarcarTodosMusicas = New-Object System.Windows.Forms.Button
$ButtonDesmarcarTodosMusicas.Text = "Desmarcar todos"
$ButtonDesmarcarTodosMusicas.Location = New-Object System.Drawing.Point(140, 15)
$ButtonDesmarcarTodosMusicas.Size = New-Object System.Drawing.Size(135, 34)

$ButtonMarcarPendentesMusicas = New-Object System.Windows.Forms.Button
$ButtonMarcarPendentesMusicas.Text = "Marcar pendentes"
$ButtonMarcarPendentesMusicas.Location = New-Object System.Drawing.Point(285, 15)
$ButtonMarcarPendentesMusicas.Size = New-Object System.Drawing.Size(145, 34)

$ButtonReplicarImagemAlbum = New-Object System.Windows.Forms.Button
$ButtonReplicarImagemAlbum.Text = "Replicar imagem no álbum"
$ButtonReplicarImagemAlbum.Location = New-Object System.Drawing.Point(440, 15)
$ButtonReplicarImagemAlbum.Size = New-Object System.Drawing.Size(190, 34)
$ButtonReplicarImagemAlbum.Enabled = $false

$ButtonGerarSelecionadosMusicas = New-Object System.Windows.Forms.Button
$ButtonGerarSelecionadosMusicas.Text = "Processar músicas selecionadas"
$ButtonGerarSelecionadosMusicas.Location = New-Object System.Drawing.Point(880, 15)
$ButtonGerarSelecionadosMusicas.Size = New-Object System.Drawing.Size(230, 34)

$ButtonMarcarTodosAlbuns = New-Object System.Windows.Forms.Button
$ButtonMarcarTodosAlbuns.Text = "Marcar todos"
$ButtonMarcarTodosAlbuns.Location = New-Object System.Drawing.Point(15, 15)
$ButtonMarcarTodosAlbuns.Size = New-Object System.Drawing.Size(115, 34)

$ButtonDesmarcarTodosAlbuns = New-Object System.Windows.Forms.Button
$ButtonDesmarcarTodosAlbuns.Text = "Desmarcar todos"
$ButtonDesmarcarTodosAlbuns.Location = New-Object System.Drawing.Point(140, 15)
$ButtonDesmarcarTodosAlbuns.Size = New-Object System.Drawing.Size(135, 34)

$ButtonMarcarPendentesAlbuns = New-Object System.Windows.Forms.Button
$ButtonMarcarPendentesAlbuns.Text = "Marcar pendentes"
$ButtonMarcarPendentesAlbuns.Location = New-Object System.Drawing.Point(285, 15)
$ButtonMarcarPendentesAlbuns.Size = New-Object System.Drawing.Size(145, 34)

$ButtonGerarSelecionadosAlbuns = New-Object System.Windows.Forms.Button
$ButtonGerarSelecionadosAlbuns.Text = "Processar álbuns selecionados"
$ButtonGerarSelecionadosAlbuns.Location = New-Object System.Drawing.Point(880, 15)
$ButtonGerarSelecionadosAlbuns.Size = New-Object System.Drawing.Size(230, 34)

# Reposicionamento dentro dos grupos para evitar rótulos deslocados.
$LabelPastaMP3.Location = New-Object System.Drawing.Point(15, 30)
$LabelPastaMP3.Size = New-Object System.Drawing.Size(130, 24)
$TextPastaMP3.Location = New-Object System.Drawing.Point(150, 30)
$TextPastaMP3.Size = New-Object System.Drawing.Size(760, 24)
$ButtonPastaMP3.Location = New-Object System.Drawing.Point(925, 27)
$ButtonPastaMP3.Size = New-Object System.Drawing.Size(130, 30)

$LabelPastaLegendas.Location = New-Object System.Drawing.Point(15, 65)
$LabelPastaLegendas.Size = New-Object System.Drawing.Size(130, 24)
$TextPastaLegendas.Location = New-Object System.Drawing.Point(150, 65)
$TextPastaLegendas.Size = New-Object System.Drawing.Size(760, 24)
$ButtonPastaLegendas.Location = New-Object System.Drawing.Point(925, 62)
$ButtonPastaLegendas.Size = New-Object System.Drawing.Size(130, 30)

$LabelModoLeitura.Location = New-Object System.Drawing.Point(15, 100)
$LabelModoLeitura.Size = New-Object System.Drawing.Size(130, 24)
$ComboModoLeitura.Location = New-Object System.Drawing.Point(150, 100)
$ComboModoLeitura.Size = New-Object System.Drawing.Size(360, 24)

# Campos internos/ocultos mantidos para compatibilidade.
$LabelPastaVideo.Visible = $false
$TextPastaVideo.Visible = $false
$ButtonPastaVideo.Visible = $false
$LabelCapa.Visible = $false
$TextCapa.Visible = $false
$CheckSaidaAutomatica.Visible = $false

$CheckGerarMusicas.Location = New-Object System.Drawing.Point(15, 30)
$CheckGerarMusicas.Size = New-Object System.Drawing.Size(260, 24)
$LabelExtra.Location = New-Object System.Drawing.Point(315, 30)
$LabelExtra.Size = New-Object System.Drawing.Size(220, 24)
$NumericExtra.Location = New-Object System.Drawing.Point(540, 30)
$NumericExtra.Size = New-Object System.Drawing.Size(90, 24)
$CheckDetalhado.Location = New-Object System.Drawing.Point(690, 30)
$CheckDetalhado.Size = New-Object System.Drawing.Size(190, 24)

$CheckGerarAlbum.Location = New-Object System.Drawing.Point(15, 65)
$CheckGerarAlbum.Size = New-Object System.Drawing.Size(260, 24)
$LabelSilencioEntreFaixas.Location = New-Object System.Drawing.Point(315, 65)
$LabelSilencioEntreFaixas.Size = New-Object System.Drawing.Size(230, 24)
$NumericSilencioEntreFaixas.Location = New-Object System.Drawing.Point(540, 65)
$NumericSilencioEntreFaixas.Size = New-Object System.Drawing.Size(90, 24)
$CheckValidarDuracao.Location = New-Object System.Drawing.Point(690, 65)
$CheckValidarDuracao.Size = New-Object System.Drawing.Size(340, 24)


$ButtonEscanear.Location = New-Object System.Drawing.Point(15, 38)
$ButtonEscanear.Size = New-Object System.Drawing.Size(220, 34)

$GroupEntrada.Controls.Clear()
$GroupEntrada.Controls.AddRange(@(
    $LabelPastaMP3,
    $TextPastaMP3,
    $ButtonPastaMP3,
    $LabelPastaLegendas,
    $TextPastaLegendas,
    $ButtonPastaLegendas,
    $LabelModoLeitura,
    $ComboModoLeitura
))

$GroupOpcoes.Controls.Clear()
$GroupOpcoes.Controls.AddRange(@(
    $CheckGerarMusicas,
    $LabelExtra,
    $NumericExtra,
    $CheckDetalhado,
    $CheckGerarAlbum,
    $LabelSilencioEntreFaixas,
    $NumericSilencioEntreFaixas,
    $CheckValidarDuracao
))

$GroupAcoes.Controls.Clear()
$GroupAcoes.Controls.AddRange(@(
    $LabelGrupoGeracao,
    $ButtonEscanear,
    $ButtonGerarTodos,
    $ProgressEscanear,
    $LabelProgressoEscanear
))

$LabelGrupoGeracao.Location = New-Object System.Drawing.Point(15, 18)
$ButtonEscanear.Location = New-Object System.Drawing.Point(15, 38)
$ButtonGerarTodos.Location = New-Object System.Drawing.Point(180, 38)

$TabPrincipal.Controls.Clear()
$TabPrincipal.Controls.AddRange(@(
    $GroupEntrada,
    $GroupOpcoes,
    $GroupAcoes
))

$TabMusicas.Controls.AddRange(@(
    $ButtonMarcarTodosMusicas,
    $ButtonDesmarcarTodosMusicas,
    $ButtonMarcarPendentesMusicas,
    $ButtonGerarSelecionadosMusicas,
    $GridMusicas
))

$TabAlbuns.Controls.AddRange(@(
    $ButtonMarcarTodosAlbuns,
    $ButtonDesmarcarTodosAlbuns,
    $ButtonMarcarPendentesAlbuns,
    $ButtonGerarSelecionadosAlbuns,
    $GridAlbuns
))



# Aba Legendas
$GroupLegOrigem = New-Object System.Windows.Forms.GroupBox
$GroupLegOrigem.Text = "1. Música e pasta de legendas"
$GroupLegOrigem.Location = New-Object System.Drawing.Point(15, 15)
$GroupLegOrigem.Size = New-Object System.Drawing.Size(1095, 120)

$LabelLegPastaInfo = New-Object System.Windows.Forms.Label
$LabelLegPastaInfo.Text = "A aba usa a pasta de MP3 da aba Geração. A pasta LEGENDAS pode ser ajustada abaixo."
$LabelLegPastaInfo.Location = New-Object System.Drawing.Point(15, 24)
$LabelLegPastaInfo.Size = New-Object System.Drawing.Size(760, 22)

$LabelLegPastaLegendas = New-Label -Text "Pasta LEGENDAS:" -X 15 -Y 55 -Width 130
$TextLegPastaLegendas = New-TextBox -Text "" -X 150 -Y 55 -Width 760
$ButtonLegPastaLegendas = New-Object System.Windows.Forms.Button
$ButtonLegPastaLegendas.Text = "Escolher..."
$ButtonLegPastaLegendas.Location = New-Object System.Drawing.Point(925, 52)
$ButtonLegPastaLegendas.Size = New-Object System.Drawing.Size(130, 30)

$ButtonLegAtualizar = New-Object System.Windows.Forms.Button
$ButtonLegAtualizar.Text = "Atualizar músicas"
$ButtonLegAtualizar.Location = New-Object System.Drawing.Point(15, 85)
$ButtonLegAtualizar.Size = New-Object System.Drawing.Size(150, 28)

$LabelLegMusica = New-Label -Text "Música:" -X 180 -Y 87 -Width 65
$ComboLegMusica = New-Object System.Windows.Forms.ComboBox
$ComboLegMusica.Location = New-Object System.Drawing.Point(245, 87)
$ComboLegMusica.Size = New-Object System.Drawing.Size(430, 24)
$ComboLegMusica.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList

$ButtonLegExplorarMusica = New-Object System.Windows.Forms.Button
$ButtonLegExplorarMusica.Text = "Explorar..."
$ButtonLegExplorarMusica.Location = New-Object System.Drawing.Point(685, 84)
$ButtonLegExplorarMusica.Size = New-Object System.Drawing.Size(95, 28)

$LabelLegDuracao = New-Object System.Windows.Forms.Label
$LabelLegDuracao.Text = "Duração: -"
$LabelLegDuracao.Location = New-Object System.Drawing.Point(790, 88)
$LabelLegDuracao.Size = New-Object System.Drawing.Size(160, 22)

$LabelLegStatus = New-Object System.Windows.Forms.Label
$LabelLegStatus.Text = "Músicas encontradas: 0"
$LabelLegStatus.Location = New-Object System.Drawing.Point(910, 88)
$LabelLegStatus.Size = New-Object System.Drawing.Size(160, 22)

$GroupLegOrigem.Controls.AddRange(@(
    $LabelLegPastaInfo,
    $LabelLegPastaLegendas,
    $TextLegPastaLegendas,
    $ButtonLegPastaLegendas,
    $ButtonLegAtualizar,
    $LabelLegMusica,
    $ComboLegMusica,
    $ButtonLegExplorarMusica,
    $LabelLegDuracao,
    $LabelLegStatus
))

$GroupLegLetra = New-Object System.Windows.Forms.GroupBox
$GroupLegLetra.Text = "2. Importar ou digitar letra"
$GroupLegLetra.Location = New-Object System.Drawing.Point(15, 145)
$GroupLegLetra.Size = New-Object System.Drawing.Size(400, 435)

$ButtonLegImportarLetra = New-Object System.Windows.Forms.Button
$ButtonLegImportarLetra.Text = "Importar letra .txt"
$ButtonLegImportarLetra.Location = New-Object System.Drawing.Point(15, 25)
$ButtonLegImportarLetra.Size = New-Object System.Drawing.Size(145, 30)

$ButtonLegAplicarLetra = New-Object System.Windows.Forms.Button
$ButtonLegAplicarLetra.Text = "Distribuir tempos"
$ButtonLegAplicarLetra.Location = New-Object System.Drawing.Point(170, 25)
$ButtonLegAplicarLetra.Size = New-Object System.Drawing.Size(145, 30)

$TextLegLetra = New-Object System.Windows.Forms.TextBox
$TextLegLetra.Location = New-Object System.Drawing.Point(15, 68)
$TextLegLetra.Size = New-Object System.Drawing.Size(365, 305)
$TextLegLetra.Multiline = $true
$TextLegLetra.ScrollBars = "Vertical"
$TextLegLetra.AcceptsReturn = $true
$TextLegLetra.AcceptsTab = $true

$LabelLegLetraInfo = New-Object System.Windows.Forms.Label
$LabelLegLetraInfo.Text = "Importe ou digite a letra e use Distribuir tempos para criar uma base editável.`nVocê também pode abrir um SRT existente diretamente no editor ao lado."
$LabelLegLetraInfo.Location = New-Object System.Drawing.Point(15, 385)
$LabelLegLetraInfo.Size = New-Object System.Drawing.Size(380, 50)

$GroupLegLetra.Controls.AddRange(@(
    $ButtonLegImportarLetra,
    $ButtonLegAplicarLetra,
    $TextLegLetra,
    $LabelLegLetraInfo
))

$GroupLegEditor = New-Object System.Windows.Forms.GroupBox
$GroupLegEditor.Text = "3. Editor direto da legenda"
$GroupLegEditor.Location = New-Object System.Drawing.Point(430, 145)
$GroupLegEditor.Size = New-Object System.Drawing.Size(680, 435)

$TextLegArquivoMP3 = New-Object System.Windows.Forms.TextBox
$TextLegArquivoMP3.Location = New-Object System.Drawing.Point(15, 25)
$TextLegArquivoMP3.Size = New-Object System.Drawing.Size(650, 24)
$TextLegArquivoMP3.ReadOnly = $true

$TextLegArquivoSrt = New-Object System.Windows.Forms.ComboBox
$TextLegArquivoSrt.Location = New-Object System.Drawing.Point(15, 55)
$TextLegArquivoSrt.Size = New-Object System.Drawing.Size(650, 24)
$TextLegArquivoSrt.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList

$ButtonLegPrepararMarcacao = New-Object System.Windows.Forms.Button
$ButtonLegPrepararMarcacao.Text = "["
$ButtonLegPrepararMarcacao.Location = New-Object System.Drawing.Point(15, 85)
$ButtonLegPrepararMarcacao.Size = New-Object System.Drawing.Size(60, 32)
$ButtonLegPrepararMarcacao.Font = New-Object System.Drawing.Font("Segoe UI Symbol", 11, [System.Drawing.FontStyle]::Bold)
$ButtonLegPrepararMarcacao.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$ButtonLegPrepararMarcacao.BackColor = [System.Drawing.Color]::WhiteSmoke

$ButtonLegVoltar = New-Object System.Windows.Forms.Button
$ButtonLegVoltar.Text = "⏪"
$ButtonLegVoltar.Location = New-Object System.Drawing.Point(80, 85)
$ButtonLegVoltar.Size = New-Object System.Drawing.Size(60, 32)
$ButtonLegVoltar.Font = New-Object System.Drawing.Font("Segoe UI Symbol", 11, [System.Drawing.FontStyle]::Bold)
$ButtonLegVoltar.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$ButtonLegVoltar.BackColor = [System.Drawing.Color]::WhiteSmoke

$ButtonLegParar = New-Object System.Windows.Forms.Button
$ButtonLegParar.Text = "⏹"
$ButtonLegParar.Location = New-Object System.Drawing.Point(145, 85)
$ButtonLegParar.Size = New-Object System.Drawing.Size(60, 32)
$ButtonLegParar.Font = New-Object System.Drawing.Font("Segoe UI Symbol", 11, [System.Drawing.FontStyle]::Bold)
$ButtonLegParar.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$ButtonLegParar.BackColor = [System.Drawing.Color]::WhiteSmoke

$ButtonLegTocar = New-Object System.Windows.Forms.Button
$ButtonLegTocar.Text = "▶"
$ButtonLegTocar.Location = New-Object System.Drawing.Point(210, 85)
$ButtonLegTocar.Size = New-Object System.Drawing.Size(60, 32)
$ButtonLegTocar.Font = New-Object System.Drawing.Font("Segoe UI Symbol", 11, [System.Drawing.FontStyle]::Bold)
$ButtonLegTocar.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$ButtonLegTocar.BackColor = [System.Drawing.Color]::WhiteSmoke

$ButtonLegPausar = New-Object System.Windows.Forms.Button
$ButtonLegPausar.Text = "⏸"
$ButtonLegPausar.Location = New-Object System.Drawing.Point(275, 85)
$ButtonLegPausar.Size = New-Object System.Drawing.Size(60, 32)
$ButtonLegPausar.Font = New-Object System.Drawing.Font("Segoe UI Symbol", 11, [System.Drawing.FontStyle]::Bold)
$ButtonLegPausar.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$ButtonLegPausar.BackColor = [System.Drawing.Color]::WhiteSmoke

$ButtonLegAvancar = New-Object System.Windows.Forms.Button
$ButtonLegAvancar.Text = "⏩"
$ButtonLegAvancar.Location = New-Object System.Drawing.Point(340, 85)
$ButtonLegAvancar.Size = New-Object System.Drawing.Size(60, 32)
$ButtonLegAvancar.Font = New-Object System.Drawing.Font("Segoe UI Symbol", 11, [System.Drawing.FontStyle]::Bold)
$ButtonLegAvancar.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$ButtonLegAvancar.BackColor = [System.Drawing.Color]::WhiteSmoke

$ButtonLegMarcarLinha = New-Object System.Windows.Forms.Button
$ButtonLegMarcarLinha.Text = "]"
$ButtonLegMarcarLinha.Location = New-Object System.Drawing.Point(405, 85)
$ButtonLegMarcarLinha.Size = New-Object System.Drawing.Size(60, 32)
$ButtonLegMarcarLinha.Font = New-Object System.Drawing.Font("Segoe UI Symbol", 11, [System.Drawing.FontStyle]::Bold)
$ButtonLegMarcarLinha.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$ButtonLegMarcarLinha.BackColor = [System.Drawing.Color]::WhiteSmoke

$ButtonLegDesfazerMarcacao = New-Object System.Windows.Forms.Button
$ButtonLegDesfazerMarcacao.Text = "Desfazer"
$ButtonLegDesfazerMarcacao.Location = New-Object System.Drawing.Point(570, 85)
$ButtonLegDesfazerMarcacao.Size = New-Object System.Drawing.Size(95, 32)
$ButtonLegDesfazerMarcacao.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$ButtonLegDesfazerMarcacao.BackColor = [System.Drawing.Color]::WhiteSmoke

$LabelLegMarcacaoStatus = New-Object System.Windows.Forms.Label
$LabelLegMarcacaoStatus.Text = "Marcação: selecione uma linha e use Início do Trecho / Fim do Trecho. F9 = início, F10 = fim."
$LabelLegMarcacaoStatus.Location = New-Object System.Drawing.Point(15, 122)
$LabelLegMarcacaoStatus.Size = New-Object System.Drawing.Size(705, 22)

$GridLegendas = New-Object System.Windows.Forms.DataGridView
$GridLegendas.Location = New-Object System.Drawing.Point(15, 160)
$GridLegendas.Size = New-Object System.Drawing.Size(700,200)
$GridLegendas.AllowUserToAddRows = $true
$GridLegendas.AllowUserToDeleteRows = $true
$GridLegendas.RowHeadersVisible = $false
$GridLegendas.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$GridLegendas.MultiSelect = $false
$GridLegendas.ClipboardCopyMode = [System.Windows.Forms.DataGridViewClipboardCopyMode]::Disable

$ColLegNumero = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$ColLegNumero.Name = "Numero"; $ColLegNumero.HeaderText = "#"; $ColLegNumero.Width = 40
[void]$GridLegendas.Columns.Add($ColLegNumero)

$ColLegInicio = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$ColLegInicio.Name = "Inicio"; $ColLegInicio.HeaderText = "Início"; $ColLegInicio.Width = 100
[void]$GridLegendas.Columns.Add($ColLegInicio)

$ColLegFim = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$ColLegFim.Name = "Fim"; $ColLegFim.HeaderText = "Fim"; $ColLegFim.Width = 100
[void]$GridLegendas.Columns.Add($ColLegFim)

$ColLegTexto = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$ColLegTexto.Name = "Texto"; $ColLegTexto.HeaderText = "Texto"; $ColLegTexto.Width = 400
[void]$GridLegendas.Columns.Add($ColLegTexto)

$ButtonLegAdicionarLinha = New-Object System.Windows.Forms.Button
$ButtonLegAdicionarLinha.Text = "(+) Adicionar`nlinha"
$ButtonLegAdicionarLinha.Location = New-Object System.Drawing.Point(15, 323)
$ButtonLegAdicionarLinha.Size = New-Object System.Drawing.Size(120, 42)

$ButtonLegRemoverLinha = New-Object System.Windows.Forms.Button
$ButtonLegRemoverLinha.Text = "(-) Remover`nlinha"
$ButtonLegRemoverLinha.Location = New-Object System.Drawing.Point(145, 323)
$ButtonLegRemoverLinha.Size = New-Object System.Drawing.Size(120, 42)

$ButtonLegLimpar = New-Object System.Windows.Forms.Button
$ButtonLegLimpar.Text = "Limpar"
$ButtonLegLimpar.Location = New-Object System.Drawing.Point(275, 323)
$ButtonLegLimpar.Size = New-Object System.Drawing.Size(80, 42)

$ButtonLegAbrirSrt = New-Object System.Windows.Forms.Button
$ButtonLegAbrirSrt.Text = "Abrir SRT`nexistente"
$ButtonLegAbrirSrt.Location = New-Object System.Drawing.Point(365, 323)
$ButtonLegAbrirSrt.Size = New-Object System.Drawing.Size(120, 42)

$ButtonLegRedistribuir = New-Object System.Windows.Forms.Button
$ButtonLegRedistribuir.Text = "Redistribuir`ntempos"
$ButtonLegRedistribuir.Location = New-Object System.Drawing.Point(495, 323)
$ButtonLegRedistribuir.Size = New-Object System.Drawing.Size(120, 42)

$ButtonLegVideoLegendado = New-Object System.Windows.Forms.Button
$ButtonLegVideoLegendado.Text = "Gerar vídeo`ncom legenda"
$ButtonLegVideoLegendado.Location = New-Object System.Drawing.Point(15, 370)
$ButtonLegVideoLegendado.Size = New-Object System.Drawing.Size(180, 42)

$GroupLegEditor.Controls.AddRange(@(
    $TextLegArquivoMP3,
    $TextLegArquivoSrt,
    $ButtonLegTocar,
    $ButtonLegPausar,
    $ButtonLegParar,
    $ButtonLegVoltar,
    $ButtonLegAvancar,
    $ButtonLegPrepararMarcacao,
    $ButtonLegMarcarLinha,
    $ButtonLegDesfazerMarcacao,
    $LabelLegMarcacaoStatus,
    $GridLegendas,
    $ButtonLegAbrirSrt,
    $ButtonLegRedistribuir,
    $ButtonLegVideoLegendado,
    $ButtonLegLimpar,
    $ButtonLegAdicionarLinha,
    $ButtonLegRemoverLinha
))

$ButtonLegSalvarSrt = New-Object System.Windows.Forms.Button
$ButtonLegSalvarSrt.Text = "Salvar .SRT"
$ButtonLegSalvarSrt.Location = New-Object System.Drawing.Point(515, 373)
$ButtonLegSalvarSrt.Size = New-Object System.Drawing.Size(150, 42)
$GroupLegEditor.Controls.Add($ButtonLegSalvarSrt)

$GroupLegAlbum = New-Object System.Windows.Forms.GroupBox
$GroupLegAlbum.Text = "4. Legenda do vídeo de álbum inteiro"
$GroupLegAlbum.Location = New-Object System.Drawing.Point(15, 590)
$GroupLegAlbum.Size = New-Object System.Drawing.Size(1095, 125)

$LabelLegAlbum = New-Label -Text "Álbum:" -X 15 -Y 30 -Width 65
$ComboLegAlbum = New-Object System.Windows.Forms.ComboBox
$ComboLegAlbum.Location = New-Object System.Drawing.Point(85, 30)
$ComboLegAlbum.Size = New-Object System.Drawing.Size(400, 24)
$ComboLegAlbum.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList

$LabelLegSilencio = New-Label -Text "Silêncio entre músicas:" -X 15 -Y 65 -Width 180
$NumericLegSilencioAlbum = New-Object System.Windows.Forms.NumericUpDown
$NumericLegSilencioAlbum.Location = New-Object System.Drawing.Point(200, 65)
$NumericLegSilencioAlbum.Size = New-Object System.Drawing.Size(80, 24)
$NumericLegSilencioAlbum.DecimalPlaces = 1
$NumericLegSilencioAlbum.Minimum = 0
$NumericLegSilencioAlbum.Maximum = 60
$NumericLegSilencioAlbum.Value = 1

$ButtonLegGerarAlbum = New-Object System.Windows.Forms.Button
$ButtonLegGerarAlbum.Text = "Gerar SRT do álbum"
$ButtonLegGerarAlbum.Location = New-Object System.Drawing.Point(310, 58)
$ButtonLegGerarAlbum.Size = New-Object System.Drawing.Size(180, 34)

$LabelLegAlbumInfo = New-Object System.Windows.Forms.Label
$LabelLegAlbumInfo.Text = "O SRT do álbum é montado a partir dos SRTs das músicas, na ordem dos arquivos MP3."
$LabelLegAlbumInfo.Location = New-Object System.Drawing.Point(15, 96)
$LabelLegAlbumInfo.Size = New-Object System.Drawing.Size(900, 22)

$GroupLegAlbum.Controls.AddRange(@(
    $LabelLegAlbum,
    $ComboLegAlbum,
    $LabelLegSilencio,
    $NumericLegSilencioAlbum,
    $ButtonLegGerarAlbum,
    $LabelLegAlbumInfo
))

$TabLegendas.Controls.AddRange(@(
    $GroupLegOrigem,
    $GroupLegLetra,
    $GroupLegEditor,
    $GroupLegAlbum
))


# Aba Separar Áudio
$GroupSepOrigem = New-Object System.Windows.Forms.GroupBox
$GroupSepOrigem.Text = "1. Música e destino"
$GroupSepOrigem.Location = New-Object System.Drawing.Point(15, 15)
$GroupSepOrigem.Size = New-Object System.Drawing.Size(1095, 170)

$LabelSepInfoOrigem = New-Object System.Windows.Forms.Label
$LabelSepInfoOrigem.Text = "Usa a mesma pasta de MP3 e a mesma pasta LEGENDAS. Os arquivos serão salvos em Audio_Separado dentro da pasta do álbum."
$LabelSepInfoOrigem.Location = New-Object System.Drawing.Point(15, 26)
$LabelSepInfoOrigem.Size = New-Object System.Drawing.Size(980, 24)

$ButtonSepAtualizar = New-Object System.Windows.Forms.Button
$ButtonSepAtualizar.Text = "Atualizar músicas"
$ButtonSepAtualizar.Location = New-Object System.Drawing.Point(15, 62)
$ButtonSepAtualizar.Size = New-Object System.Drawing.Size(150, 32)

$ComboSepMusica = New-Object System.Windows.Forms.ComboBox
$ComboSepMusica.Location = New-Object System.Drawing.Point(185, 66)
$ComboSepMusica.Size = New-Object System.Drawing.Size(600, 24)
$ComboSepMusica.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList

$LabelSepDuracao = New-Object System.Windows.Forms.Label
$LabelSepDuracao.Text = "Duração: -"
$LabelSepDuracao.Location = New-Object System.Drawing.Point(805, 68)
$LabelSepDuracao.Size = New-Object System.Drawing.Size(140, 22)

$LabelSepStatus = New-Object System.Windows.Forms.Label
$LabelSepStatus.Text = "Músicas: 0"
$LabelSepStatus.Location = New-Object System.Drawing.Point(950, 68)
$LabelSepStatus.Size = New-Object System.Drawing.Size(120, 22)

$TextSepArquivoMP3 = New-Object System.Windows.Forms.TextBox
$TextSepArquivoMP3.Location = New-Object System.Drawing.Point(15, 102)
$TextSepArquivoMP3.Size = New-Object System.Drawing.Size(1065, 24)
$TextSepArquivoMP3.ReadOnly = $true

$TextSepDestino = New-Object System.Windows.Forms.TextBox
$TextSepDestino.Location = New-Object System.Drawing.Point(15, 132)
$TextSepDestino.Size = New-Object System.Drawing.Size(930, 24)
$TextSepDestino.ReadOnly = $true

$ButtonSepAbrirPasta = New-Object System.Windows.Forms.Button
$ButtonSepAbrirPasta.Text = "Abrir pasta"
$ButtonSepAbrirPasta.Location = New-Object System.Drawing.Point(960, 129)
$ButtonSepAbrirPasta.Size = New-Object System.Drawing.Size(120, 30)

$GroupSepOrigem.Controls.AddRange(@(
    $LabelSepInfoOrigem,
    $ButtonSepAtualizar,
    $ComboSepMusica,
    $LabelSepDuracao,
    $LabelSepStatus,
    $TextSepArquivoMP3,
    $TextSepDestino,
    $ButtonSepAbrirPasta
))

$GroupSepOpcoes = New-Object System.Windows.Forms.GroupBox
$GroupSepOpcoes.Text = "2. Separação de áudio"
$GroupSepOpcoes.Location = New-Object System.Drawing.Point(15, 200)
$GroupSepOpcoes.Size = New-Object System.Drawing.Size(1095, 165)

$CheckSepGerarVocal = New-Object System.Windows.Forms.CheckBox
$CheckSepGerarVocal.Text = "Salvar vocal isolado"
$CheckSepGerarVocal.Location = New-Object System.Drawing.Point(15, 28)
$CheckSepGerarVocal.Size = New-Object System.Drawing.Size(220, 24)
$CheckSepGerarVocal.Checked = $true

$CheckSepGerarInstrumental = New-Object System.Windows.Forms.CheckBox
$CheckSepGerarInstrumental.Text = "Salvar instrumental"
$CheckSepGerarInstrumental.Location = New-Object System.Drawing.Point(260, 28)
$CheckSepGerarInstrumental.Size = New-Object System.Drawing.Size(220, 24)
$CheckSepGerarInstrumental.Checked = $true

$LabelSepInfo = New-Object System.Windows.Forms.Label
$LabelSepInfo.Text = "O Demucs separa a música e o aplicativo salva como _vocals.wav e _instrumental.wav. Depois, a aba Legendas pode usar o vocal isolado existente para gerar SRT."
$LabelSepInfo.Location = New-Object System.Drawing.Point(15, 62)
$LabelSepInfo.Size = New-Object System.Drawing.Size(1040, 45)

$ButtonSepSelecionada = New-Object System.Windows.Forms.Button
$ButtonSepSelecionada.Text = "Separar música selecionada"
$ButtonSepSelecionada.Location = New-Object System.Drawing.Point(15, 115)
$ButtonSepSelecionada.Size = New-Object System.Drawing.Size(210, 36)

$ButtonSepAlbum = New-Object System.Windows.Forms.Button
$ButtonSepAlbum.Text = "Separar álbum da música"
$ButtonSepAlbum.Location = New-Object System.Drawing.Point(245, 115)
$ButtonSepAlbum.Size = New-Object System.Drawing.Size(210, 36)

$GroupSepOpcoes.Controls.AddRange(@(
    $CheckSepGerarVocal,
    $CheckSepGerarInstrumental,
    $LabelSepInfo,
    $ButtonSepSelecionada,
    $ButtonSepAlbum
))

$TabSepararAudio.Controls.AddRange(@(
    $GroupSepOrigem,
    $GroupSepOpcoes
))

# Aba Publicação
$GroupPubOrigem = New-Object System.Windows.Forms.GroupBox
$GroupPubOrigem.Text = "1. Origem e conta"
$GroupPubOrigem.Location = New-Object System.Drawing.Point(15, 15)
$GroupPubOrigem.Size = New-Object System.Drawing.Size(1095, 80)

$LabelPubPasta = New-Label -Text "Pasta dos vídeos:" -X 15 -Y 32 -Width 120
$TextPubPasta = New-TextBox -Text "" -X 140 -Y 32 -Width 385
$ButtonPubPasta = New-Object System.Windows.Forms.Button
$ButtonPubPasta.Text = "Escolher..."
$ButtonPubPasta.Location = New-Object System.Drawing.Point(535, 29)
$ButtonPubPasta.Size = New-Object System.Drawing.Size(105, 30)

$ButtonPubUsarSaida = New-Object System.Windows.Forms.Button
$ButtonPubUsarSaida.Text = "Usar pasta gerada"
$ButtonPubUsarSaida.Location = New-Object System.Drawing.Point(650, 29)
$ButtonPubUsarSaida.Size = New-Object System.Drawing.Size(135, 30)

$ButtonPubConfig = New-Object System.Windows.Forms.Button
$ButtonPubConfig.Text = "Configurar YouTube"
$ButtonPubConfig.Location = New-Object System.Drawing.Point(795, 29)
$ButtonPubConfig.Size = New-Object System.Drawing.Size(165, 30)

$ButtonPubConectar = New-Object System.Windows.Forms.Button
$ButtonPubConectar.Text = "Conectar"
$ButtonPubConectar.Location = New-Object System.Drawing.Point(970, 29)
$ButtonPubConectar.Size = New-Object System.Drawing.Size(95, 30)

$GroupPubOrigem.Controls.AddRange(@(
    $LabelPubPasta,
    $TextPubPasta,
    $ButtonPubPasta,
    $ButtonPubUsarSaida,
    $ButtonPubConfig,
    $ButtonPubConectar
))

$GroupPubAcoes = New-Object System.Windows.Forms.GroupBox
$GroupPubAcoes.Text = "2. Ações da fila"
$GroupPubAcoes.Location = New-Object System.Drawing.Point(15, 105)
$GroupPubAcoes.Size = New-Object System.Drawing.Size(1095, 85)

$ButtonPubEscanear = New-Object System.Windows.Forms.Button
$ButtonPubEscanear.Text = "Escanear vídeos"
$ButtonPubEscanear.Location = New-Object System.Drawing.Point(15, 30)
$ButtonPubEscanear.Size = New-Object System.Drawing.Size(125, 32)

$ButtonPubMarcarTodos = New-Object System.Windows.Forms.Button
$ButtonPubMarcarTodos.Text = "Marcar todos"
$ButtonPubMarcarTodos.Location = New-Object System.Drawing.Point(150, 30)
$ButtonPubMarcarTodos.Size = New-Object System.Drawing.Size(110, 32)

$ButtonPubDesmarcarTodos = New-Object System.Windows.Forms.Button
$ButtonPubDesmarcarTodos.Text = "Desmarcar todos"
$ButtonPubDesmarcarTodos.Location = New-Object System.Drawing.Point(270, 30)
$ButtonPubDesmarcarTodos.Size = New-Object System.Drawing.Size(135, 32)

$ButtonPubMarcarPendentes = New-Object System.Windows.Forms.Button
$ButtonPubMarcarPendentes.Text = "Marcar pendentes"
$ButtonPubMarcarPendentes.Location = New-Object System.Drawing.Point(415, 30)
$ButtonPubMarcarPendentes.Size = New-Object System.Drawing.Size(140, 32)

$ButtonPubValidar = New-Object System.Windows.Forms.Button
$ButtonPubValidar.Text = "Validar"
$ButtonPubValidar.Location = New-Object System.Drawing.Point(565, 30)
$ButtonPubValidar.Size = New-Object System.Drawing.Size(90, 32)

$ButtonPubExportar = New-Object System.Windows.Forms.Button
$ButtonPubExportar.Text = "Salvar fila JSON"
$ButtonPubExportar.Location = New-Object System.Drawing.Point(665, 30)
$ButtonPubExportar.Size = New-Object System.Drawing.Size(125, 32)

$ButtonPubAplicarUltimos = New-Object System.Windows.Forms.Button
$ButtonPubAplicarUltimos.Text = "Aplicar últimos dados"
$ButtonPubAplicarUltimos.Location = New-Object System.Drawing.Point(800, 30)
$ButtonPubAplicarUltimos.Size = New-Object System.Drawing.Size(155, 32)

$ButtonPubEnviarSelecionados = New-Object System.Windows.Forms.Button
$ButtonPubEnviarSelecionados.Text = "Enviar selecionados"
$ButtonPubEnviarSelecionados.Location = New-Object System.Drawing.Point(965, 30)
$ButtonPubEnviarSelecionados.Size = New-Object System.Drawing.Size(145, 32)

$ButtonPubEnviarPendentes = New-Object System.Windows.Forms.Button
$ButtonPubEnviarPendentes.Text = "Enviar pendentes"
$ButtonPubEnviarPendentes.Location = New-Object System.Drawing.Point(15, 67)
$ButtonPubEnviarPendentes.Size = New-Object System.Drawing.Size(155, 32)

$GroupPubAcoes.Controls.AddRange(@(
    $ButtonPubEscanear,
    $ButtonPubMarcarTodos,
    $ButtonPubDesmarcarTodos,
    $ButtonPubMarcarPendentes,
    $ButtonPubValidar,
    $ButtonPubExportar,
    $ButtonPubAplicarUltimos,
    $ButtonPubEnviarSelecionados,
    $ButtonPubEnviarPendentes
))

$GroupPubLegendas = New-Object System.Windows.Forms.GroupBox
$GroupPubLegendas.Text = "3. Legendas na publicação"
$GroupPubLegendas.Location = New-Object System.Drawing.Point(15, 200)
$GroupPubLegendas.Size = New-Object System.Drawing.Size(1095, 75)

$LabelPubModoLegenda = New-Label -Text "Modo:" -X 15 -Y 30 -Width 55
$ComboPubModoLegenda = New-Object System.Windows.Forms.ComboBox
$ComboPubModoLegenda.Location = New-Object System.Drawing.Point(70, 27)
$ComboPubModoLegenda.Size = New-Object System.Drawing.Size(210, 24)
$ComboPubModoLegenda.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
foreach ($ModoLegPub in @("Nenhuma", "Embutir no vídeo", "Anexar SRT ao YouTube", "Embutir + anexar SRT")) { [void]$ComboPubModoLegenda.Items.Add($ModoLegPub) }
$ComboPubModoLegenda.SelectedItem = "Nenhuma"

$CheckPubAnexarTodosSrt = New-Object System.Windows.Forms.CheckBox
$CheckPubAnexarTodosSrt.Text = "Anexar todos os SRTs encontrados da música"
$CheckPubAnexarTodosSrt.Location = New-Object System.Drawing.Point(300, 29)
$CheckPubAnexarTodosSrt.Size = New-Object System.Drawing.Size(290, 24)
$CheckPubAnexarTodosSrt.Checked = $true

$ButtonPubAplicarLegenda = New-Object System.Windows.Forms.Button
$ButtonPubAplicarLegenda.Text = "Aplicar aos selecionados"
$ButtonPubAplicarLegenda.Location = New-Object System.Drawing.Point(610, 24)
$ButtonPubAplicarLegenda.Size = New-Object System.Drawing.Size(165, 32)

$LabelPubLegInfo = New-Label -Text "SRTs: NomeDaMusica.en.srt / .pt-BR.srt / .es.srt" -X 785 -Y 30 -Width 130

$GroupPubLegendas.Controls.AddRange(@($LabelPubModoLegenda, $ComboPubModoLegenda, $CheckPubAnexarTodosSrt, $ButtonPubAplicarLegenda, $LabelPubLegInfo))

$GridPublicacao = New-PublishGrid
$GridPublicacao.Location = New-Object System.Drawing.Point(15, 285)
$GridPublicacao.Size = New-Object System.Drawing.Size(1095, 175)

$GroupPubMetadados = New-Object System.Windows.Forms.GroupBox
$GroupPubMetadados.Text = "4. Metadados do vídeo selecionado"
$GroupPubMetadados.Location = New-Object System.Drawing.Point(15, 475)
$GroupPubMetadados.Size = New-Object System.Drawing.Size(1095, 205)

$LabelPubTitulo = New-Label -Text "Título:" -X 15 -Y 28 -Width 80
$TextPubTitulo = New-TextBox -Text "" -X 100 -Y 28 -Width 460

$LabelPubVisibilidade = New-Label -Text "Visibilidade:" -X 580 -Y 28 -Width 95
$ComboPubVisibilidade = New-Object System.Windows.Forms.ComboBox
$ComboPubVisibilidade.Location = New-Object System.Drawing.Point(680, 28)
$ComboPubVisibilidade.Size = New-Object System.Drawing.Size(130, 24)
$ComboPubVisibilidade.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$ComboPubVisibilidade.Items.Add("private")
[void]$ComboPubVisibilidade.Items.Add("unlisted")
[void]$ComboPubVisibilidade.Items.Add("public")
$ComboPubVisibilidade.SelectedItem = "private"

$LabelPubCategoria = New-Label -Text "Categoria:" -X 825 -Y 28 -Width 80
$TextPubCategoria = New-TextBox -Text "10" -X 910 -Y 28 -Width 60

$LabelPubDescricao = New-Label -Text "Descrição:" -X 15 -Y 63 -Width 80
$TextPubDescricao = New-Object System.Windows.Forms.TextBox
$TextPubDescricao.Location = New-Object System.Drawing.Point(100, 63)
$TextPubDescricao.Size = New-Object System.Drawing.Size(460, 95)
$TextPubDescricao.Multiline = $true
$TextPubDescricao.ScrollBars = "Vertical"

$LabelPubTags = New-Label -Text "Tags:" -X 580 -Y 63 -Width 80
$TextPubTags = New-TextBox -Text "" -X 680 -Y 63 -Width 390

$LabelPubPlaylist = New-Label -Text "Playlist ID:" -X 580 -Y 98 -Width 90
$TextPubPlaylist = New-TextBox -Text "" -X 680 -Y 98 -Width 390

$LabelPubThumbnail = New-Label -Text "Thumbnail:" -X 580 -Y 133 -Width 90
$TextPubThumbnail = New-TextBox -Text "" -X 680 -Y 133 -Width 275
$ButtonPubThumbnail = New-Object System.Windows.Forms.Button
$ButtonPubThumbnail.Text = "Escolher..."
$ButtonPubThumbnail.Location = New-Object System.Drawing.Point(965, 130)
$ButtonPubThumbnail.Size = New-Object System.Drawing.Size(105, 30)

$ButtonPubAplicarLinha = New-Object System.Windows.Forms.Button
$ButtonPubAplicarLinha.Text = "Aplicar à linha"
$ButtonPubAplicarLinha.Location = New-Object System.Drawing.Point(100, 165)
$ButtonPubAplicarLinha.Size = New-Object System.Drawing.Size(130, 30)

$ButtonPubAplicarSelecionados = New-Object System.Windows.Forms.Button
$ButtonPubAplicarSelecionados.Text = "Aplicar aos selecionados"
$ButtonPubAplicarSelecionados.Location = New-Object System.Drawing.Point(240, 165)
$ButtonPubAplicarSelecionados.Size = New-Object System.Drawing.Size(180, 30)

$GroupPubMetadados.Controls.AddRange(@(
    $LabelPubTitulo, $TextPubTitulo, $LabelPubVisibilidade, $ComboPubVisibilidade, $LabelPubCategoria, $TextPubCategoria,
    $LabelPubDescricao, $TextPubDescricao, $LabelPubTags, $TextPubTags, $LabelPubPlaylist, $TextPubPlaylist,
    $LabelPubThumbnail, $TextPubThumbnail, $ButtonPubThumbnail, $ButtonPubAplicarLinha, $ButtonPubAplicarSelecionados
))

$TextPubLog = New-Object System.Windows.Forms.TextBox
$TextPubLog.Location = New-Object System.Drawing.Point(15, 690)
$TextPubLog.Size = New-Object System.Drawing.Size(1095, 95)
$TextPubLog.Multiline = $true
$TextPubLog.ScrollBars = "Vertical"
$TextPubLog.ReadOnly = $true
$TextPubLog.Anchor = "Left,Right,Bottom"

$TabPublicacao.Controls.AddRange(@(
    $GroupPubOrigem,
    $GroupPubAcoes,
    $GroupPubLegendas,
    $GridPublicacao,
    $GroupPubMetadados,
    $TextPubLog
))

$AjudaIndiceTitulo = New-Object System.Windows.Forms.Label
$AjudaIndiceTitulo.Location = New-Object System.Drawing.Point(20, 20)
$AjudaIndiceTitulo.Size = New-Object System.Drawing.Size(1085, 24)
$AjudaIndiceTitulo.Font = New-Object System.Drawing.Font("Century Gothic", 10, [System.Drawing.FontStyle]::Bold)
$AjudaIndiceTitulo.Text = "ÍNDICE"

$AjudaIndicePanel = New-Object System.Windows.Forms.TableLayoutPanel
$AjudaIndicePanel.Location = New-Object System.Drawing.Point(20, 45)
$AjudaIndicePanel.Size = New-Object System.Drawing.Size(1085, 120)
$AjudaIndicePanel.ColumnCount = 4
$AjudaIndicePanel.RowCount = 3
$AjudaIndicePanel.AutoSize = $false

for ($i = 0; $i -lt 4; $i++) {
    [void]$AjudaIndicePanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 25)))
}

for ($i = 0; $i -lt 3; $i++) {
    [void]$AjudaIndicePanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 33.33)))
}

function Set-HelpText {
    param([string]$Section)

    switch ($Section) {
        "pasta" {
            $AjudaBox.Text = @"
1. Pasta de MP3

Clique em 'Escolher...' e selecione a pasta onde estão as músicas.

O programa aceita dois formatos:

A) Uma pasta com subpastas de álbuns:
MP3
  01 - Álbum
    01 - Música.mp3
    02 - Música.mp3

B) Uma pasta única como álbum:
Meu Álbum
  01 - Música.mp3
  02 - Música.mp3

A pasta de saída é criada automaticamente ao lado da pasta de MP3 com o nome VÍDEOS.

A pasta de legendas também é sugerida automaticamente ao lado da pasta de MP3 com o nome LEGENDAS.

Exemplo:
C:\MÚSICAS AI\FREZZA\MP3
C:\MÚSICAS AI\FREZZA\VÍDEOS
C:\MÚSICAS AI\FREZZA\LEGENDAS
"@
        }

        "modo" {
            $AjudaBox.Text = @"
2. Modo de leitura

Use 'Detectar automaticamente' na maioria dos casos.

Também é possível forçar:

- Cada subpasta é um álbum
- A pasta selecionada é um álbum único

Use 'Cada subpasta é um álbum' quando a pasta principal contém várias pastas internas, cada uma representando um álbum.

Use 'Pasta selecionada é um álbum único' quando os MP3s estão diretamente dentro da pasta escolhida.
"@
        }

        "opcoes" {
            $AjudaBox.Text = @"
3. Opções de geração

Marque:

- Gerar vídeo para cada música
- Gerar vídeo do álbum inteiro
- Gerar legendas .SRT automaticamente

Você pode marcar uma, duas ou as três opções.

Silêncio final:
acrescenta segundos no final de cada vídeo individual.

Silêncio entre faixas:
acrescenta segundos entre as músicas no vídeo do álbum.

Modo detalhado de log:
mostra mais mensagens técnicas do ffmpeg.

Validar duração:
confere se vídeos existentes parecem completos antes de pular.
"@
        }

        "escanear" {
            $AjudaBox.Text = @"
4. Escanear e selecionar

Clique em 'Escanear álbuns' para carregar a lista.

Depois disso, os itens aparecem separados nas abas:

- Músicas
- Álbuns

A primeira coluna permite marcar ou desmarcar os itens.

Você pode usar:

- Marcar todos
- Desmarcar todos
- Marcar pendentes

Os álbuns e músicas aparecem separados para facilitar a organização.
"@
        }

        "imagens" {
            $AjudaBox.Text = @"
5. Escolher e replicar imagens

A imagem é obrigatória para cada item selecionado.

Na coluna 'Imagem', clique em 'Escolher...' para selecionar uma imagem manualmente.

Para usar a mesma imagem no álbum:

1. escolha a imagem em uma linha de música individual;
2. clique em 'Replicar imagem no álbum';
3. a imagem será aplicada aos demais itens do mesmo álbum;
4. a imagem também será sincronizada na aba Álbuns.

Depois de replicar, o botão fica inativo até você escolher outra imagem em outra música.
"@
        }

        "gerar" {
            $AjudaBox.Text = @"
6. Gerar vídeos

Você pode gerar:

- músicas selecionadas;
- álbuns selecionados;
- todos os itens marcados.

A geração abre uma tela separada com:

- log do processo;
- status atual;
- botão Interromper.

Se um arquivo já existir, o programa pode pular ou validar a duração, dependendo da opção marcada.
"@
        }

        "saida" {
            $AjudaBox.Text = @"
7. Saída e relatório

A saída fica em uma pasta VÍDEOS ao lado da pasta de MP3.

Exemplo:
D:\Projeto\MP3
D:\Projeto\VÍDEOS

Ao final, um relatório .txt é salvo na pasta de saída com:

- vídeos gerados;
- vídeos pulados;
- erros;
- tempo gasto;
- caminhos dos arquivos.
"@
        }

        "interromper" {
            $AjudaBox.Text = @"
8. Interromper

Durante a geração, uma tela separada é aberta com o log e o botão 'Interromper'.

A interrupção é programada.

Quando possível, o programa remove arquivos incompletos gerados antes da interrupção.

Use essa opção se perceber que escolheu a pasta errada, imagem errada ou configuração errada.
"@
        }

        "publicacao" {
            $AjudaBox.Text = @"
9. Publicação no YouTube

A aba Publicação permite selecionar vídeos já gerados e enviá-los ao YouTube.

Fluxo recomendado:

1. escolha a pasta dos vídeos;
2. clique em 'Escanear vídeos';
3. configure os dados dos vídeos;
4. clique em 'Configurar YouTube';
5. importe o JSON OAuth Desktop do Google Cloud;
6. clique em 'Conectar';
7. envie os vídeos selecionados ou pendentes.

A configuração do YouTube salva Client ID e Client Secret em youtube_config.json.

A conexão salva o token de acesso em youtube_token.json.
"@
        }

        "editar" {
            $AjudaBox.Text = @"
10. Editar dados dos vídeos

Na lista de vídeos da aba Publicação, dê duplo clique em um vídeo para abrir a tela de edição.

Nessa tela é possível editar:

- título;
- descrição;
- tags;
- visibilidade;
- categoria;
- playlist;
- thumbnail.

O botão 'Remover número da faixa' limpa prefixos como:

01 - Nome da música
02. Nome da música
Faixa 03 - Nome da música
Track 04 - Nome da música

Também é possível salvar os dados de um vídeo e aplicar aos vídeos marcados.
"@
        }

        default {
            $AjudaBox.Text = "Selecione um item do índice acima para ver a ajuda correspondente."
        }
    }

    $AjudaBox.SelectionStart = 0
    $AjudaBox.ScrollToCaret()
}

function New-HelpIndexLink {
    param(
        [string]$Text,
        [string]$Target
    )

    $Link = New-Object System.Windows.Forms.LinkLabel
    $Link.Text = $Text
    $Link.Tag = $Target
    $Link.Dock = [System.Windows.Forms.DockStyle]::Fill
    $Link.Font = New-Object System.Drawing.Font("Century Gothic", 10)
    $Link.LinkBehavior = [System.Windows.Forms.LinkBehavior]::HoverUnderline
    $Link.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft

    $Link.Add_LinkClicked({
        param($sender, $e)

        Set-HelpText -Section ([string]$sender.Tag)
    })

    return $Link
}

[void]$AjudaIndicePanel.Controls.Add((New-HelpIndexLink -Text "1. Pasta de MP3" -Target "pasta"), 0, 0)
[void]$AjudaIndicePanel.Controls.Add((New-HelpIndexLink -Text "2. Modo de leitura" -Target "modo"), 1, 0)
[void]$AjudaIndicePanel.Controls.Add((New-HelpIndexLink -Text "3. Opções de geração" -Target "opcoes"), 2, 0)
[void]$AjudaIndicePanel.Controls.Add((New-HelpIndexLink -Text "4. Escanear e selecionar" -Target "escanear"), 3, 0)
[void]$AjudaIndicePanel.Controls.Add((New-HelpIndexLink -Text "5. Escolher/replicar imagens" -Target "imagens"), 0, 1)
[void]$AjudaIndicePanel.Controls.Add((New-HelpIndexLink -Text "6. Gerar vídeos" -Target "gerar"), 1, 1)
[void]$AjudaIndicePanel.Controls.Add((New-HelpIndexLink -Text "7. Saída e relatório" -Target "saida"), 2, 1)
[void]$AjudaIndicePanel.Controls.Add((New-HelpIndexLink -Text "8. Interromper" -Target "interromper"), 3, 1)
[void]$AjudaIndicePanel.Controls.Add((New-HelpIndexLink -Text "9. Publicação no YouTube" -Target "publicacao"), 0, 2)
[void]$AjudaIndicePanel.Controls.Add((New-HelpIndexLink -Text "10. Editar dados dos vídeos" -Target "editar"), 1, 2)

$AjudaBox = New-Object System.Windows.Forms.RichTextBox
$AjudaBox.ReadOnly = $true
$AjudaBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$AjudaBox.BackColor = [System.Drawing.SystemColors]::Window
$AjudaBox.Font = New-Object System.Drawing.Font("Century Gothic", 10)
$AjudaBox.Location = New-Object System.Drawing.Point(20, 180)
$AjudaBox.Size = New-Object System.Drawing.Size(1085, 555)
$AjudaBox.Anchor = "Top,Bottom,Left,Right"
$AjudaBox.ScrollBars = [System.Windows.Forms.RichTextBoxScrollBars]::Vertical
$AjudaBox.Text = "Selecione um item do índice acima para ver a ajuda correspondente."

$TabAjuda.Controls.Add($AjudaIndiceTitulo)
$TabAjuda.Controls.Add($AjudaIndicePanel)
$TabAjuda.Controls.Add($AjudaBox)

$ButtonPastaMP3.Add_Click({
    $TextPastaMP3.Text = Select-Folder -InitialPath $TextPastaMP3.Text
    Update-AutoOutputFromInput
})

$ButtonPastaVideo.Add_Click({
    $TextPastaVideo.Text = Select-Folder -InitialPath $TextPastaVideo.Text
})

$ButtonPastaLegendas.Add_Click({
    $TextPastaLegendas.Text = Select-Folder -InitialPath $TextPastaLegendas.Text
    if ($null -ne $TextLegPastaLegendas) { $TextLegPastaLegendas.Text = $TextPastaLegendas.Text }
})

$CheckSaidaAutomatica.Add_CheckedChanged({
    $CheckSaidaAutomatica.Checked = $true
if ($CheckSaidaAutomatica.Checked) {
        $AutoPath = Get-AutoOutputPath -PastaMP3 $TextPastaMP3.Text

        if (-not [string]::IsNullOrWhiteSpace($AutoPath)) {
            $TextPastaVideo.Text = $AutoPath
        }

        $TextPastaVideo.Enabled = $false
        $ButtonPastaVideo.Enabled = $false
    }
    else {
        $TextPastaVideo.Enabled = $true
        $ButtonPastaVideo.Enabled = $true
    }
})

$TextPastaMP3.Add_TextChanged({
    Update-AutoOutputFromInput
    if ($null -ne $TextLegPastaLegendas) { $TextLegPastaLegendas.Text = $TextPastaLegendas.Text }
})


$ButtonLegPastaLegendas.Add_Click({
    $TextLegPastaLegendas.Text = Select-Folder -InitialPath $TextLegPastaLegendas.Text
    $TextPastaLegendas.Text = $TextLegPastaLegendas.Text
})

$ButtonLegAtualizar.Add_Click({
    if ([string]::IsNullOrWhiteSpace($TextLegPastaLegendas.Text)) {
        $TextLegPastaLegendas.Text = Get-AutoSubtitlePath -PastaMP3 $TextPastaMP3.Text
    }
    $TextPastaLegendas.Text = $TextLegPastaLegendas.Text
    Refresh-SubtitleMusicList
    Load-SelectedSubtitleInfo
})


$ButtonLegExplorarMusica.Add_Click({
    $Dialog = New-Object System.Windows.Forms.OpenFileDialog
    $Dialog.Title = "Escolher música MP3"
    $Dialog.Filter = "Arquivos MP3|*.mp3|Todos os arquivos|*.*"
    $Dialog.Multiselect = $false

    if (-not [string]::IsNullOrWhiteSpace($TextPastaMP3.Text) -and (Test-SafePath -Path $TextPastaMP3.Text)) {
        $Dialog.InitialDirectory = $TextPastaMP3.Text
    }

    if ($Dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        Add-DirectSubtitleMusicFile -Mp3Path $Dialog.FileName
    }
})

$ComboLegMusica.Add_SelectedIndexChanged({
    Load-SelectedSubtitleInfo
})

$ButtonSepAtualizar.Add_Click({
    if ([string]::IsNullOrWhiteSpace($TextLegPastaLegendas.Text)) {
        $TextLegPastaLegendas.Text = Get-AutoSubtitlePath -PastaMP3 $TextPastaMP3.Text
    }
    $TextPastaLegendas.Text = $TextLegPastaLegendas.Text
    Refresh-SubtitleMusicList
    Load-SelectedSeparateAudioInfo
})

$ComboSepMusica.Add_SelectedIndexChanged({
    Load-SelectedSeparateAudioInfo
})

$ButtonSepSelecionada.Add_Click({
    Start-SeparateAudioForSelected
})

$ButtonSepAlbum.Add_Click({
    Start-SeparateAudioForSelectedAlbum
})

$ButtonSepAbrirPasta.Add_Click({
    Load-SelectedSeparateAudioInfo
    if (-not [string]::IsNullOrWhiteSpace($TextSepDestino.Text)) {
        New-SafeDirectory -Path $TextSepDestino.Text | Out-Null
        Start-Process explorer.exe $TextSepDestino.Text
    }
})

$ButtonLegTocar.Add_Click({
    Play-SelectedSubtitleAudio
})

$ButtonLegPausar.Add_Click({
    Pause-SelectedSubtitleAudio
})

$ButtonLegParar.Add_Click({
    Stop-SelectedSubtitleAudio
})

$ButtonLegVoltar.Add_Click({
    Seek-SelectedSubtitleAudio -OffsetSeconds -5
})

$ButtonLegAvancar.Add_Click({
    Seek-SelectedSubtitleAudio -OffsetSeconds 5
})

$ButtonLegPrepararMarcacao.Add_Click({
    Set-SelectedSubtitleLineStart
})

$ButtonLegMarcarLinha.Add_Click({
    Set-SelectedSubtitleLineEnd
})

$ButtonLegDesfazerMarcacao.Add_Click({
    Undo-LastSubtitleMark
})

$ButtonLegAdicionarLinha.Add_Click({
    Add-SubtitleGridLine
})

$ButtonLegRemoverLinha.Add_Click({
    Remove-SelectedSubtitleGridLine
})

$ButtonLegImportarLetra.Add_Click({
    $Dialog = New-Object System.Windows.Forms.OpenFileDialog
    $Dialog.Title = "Importar letra"
    $Dialog.Filter = "Texto|*.txt;*.lrc|Todos os arquivos|*.*"
    $Dialog.Multiselect = $false

    if ($Dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        try {
            $TextLegLetra.Text = Get-Content -LiteralPath $Dialog.FileName -Raw -Encoding UTF8
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Erro ao importar letra", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
    }
})

$ButtonLegAplicarLetra.Add_Click({
    $Item = Get-SelectedSubtitleItem
    if ($null -eq $Item) {
        [System.Windows.Forms.MessageBox]::Show("Selecione uma música antes de distribuir tempos.", "Legendas", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }

    $Lines = @(Get-LyricsLinesFromText -Text $TextLegLetra.Text)
    if ($Lines.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Digite ou importe a letra primeiro.", "Legendas", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }

    $Rows = @(New-SubtitleRowsFromLyrics -Lines $Lines -DurationSeconds ([double]$Item.Duration))
    Fill-SubtitleGrid -Rows $Rows
})

$ButtonLegAbrirSrt.Add_Click({
    $Item = Get-SelectedSubtitleItem
    if ($null -eq $Item) { return }

    $Path = Get-SubtitleSrtPathForItem -Item $Item

    if (-not (Test-SafePath -Path $Path)) {
        $Dialog = New-Object System.Windows.Forms.OpenFileDialog
        $Dialog.Title = "Abrir SRT"
        $Dialog.Filter = "Legendas SRT|*.srt|Todos os arquivos|*.*"
        $Dialog.Multiselect = $false

        if ($Dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
            return
        }

        $Path = $Dialog.FileName
    }

    $Rows = @(Read-SrtFileRows -Path $Path)
    Fill-SubtitleGrid -Rows $Rows
    $TextLegArquivoSrt.Text = $Path
})

$ButtonLegRedistribuir.Add_Click({
    $Item = Get-SelectedSubtitleItem
    if ($null -eq $Item) { return }

    $RowsAtual = @(Get-SubtitleRowsFromGrid)
    $Lines = @($RowsAtual | ForEach-Object { [string]$_.Text } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    if ($Lines.Count -eq 0) {
        $Lines = @(Get-LyricsLinesFromText -Text $TextLegLetra.Text)
    }

    if ($Lines.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Não há texto para redistribuir.", "Legendas", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }

    $Rows = @(New-SubtitleRowsFromLyrics -Lines $Lines -DurationSeconds ([double]$Item.Duration))
    Fill-SubtitleGrid -Rows $Rows
})

$ButtonLegLimpar.Add_Click({
    $GridLegendas.Rows.Clear()
})

$ButtonLegSalvarSrt.Add_Click({
    Save-SubtitleGridToFile
})

$ButtonLegVideoLegendado.Add_Click({
    Show-BurnSubtitleVideoDialog
})

$ButtonLegGerarAlbum.Add_Click({
    if ($null -eq $ComboLegAlbum.SelectedItem) {
        [System.Windows.Forms.MessageBox]::Show("Selecione um álbum.", "Legendas", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }

    Merge-AlbumSrtFromTrackFilesManual `
        -Album ([string]$ComboLegAlbum.SelectedItem) `
        -SilencioEntreFaixas ([double]$NumericLegSilencioAlbum.Value)
})

$ButtonSalvarProjeto.Add_Click({
    $Path=$script:ProjetoAtualPath
    if([string]::IsNullOrWhiteSpace($Path)){
        $Dlg=New-Object System.Windows.Forms.SaveFileDialog; $Dlg.Title="Salvar projeto Frezza"; $Dlg.Filter="Projeto Frezza|*.frezproj"; $Dlg.DefaultExt="frezproj"; $Dlg.AddExtension=$true
        if($Dlg.ShowDialog($Form) -ne [System.Windows.Forms.DialogResult]::OK){ return }; $Path=$Dlg.FileName
    }
    if(Save-FrezzaProject -Path $Path){ [System.Windows.Forms.MessageBox]::Show("Projeto salvo em:`n$Path","Projeto") | Out-Null }
})
$ButtonAbrirProjeto.Add_Click({
    $Dlg=New-Object System.Windows.Forms.OpenFileDialog; $Dlg.Title="Abrir projeto Frezza"; $Dlg.Filter="Projeto Frezza|*.frezproj|Todos os arquivos|*.*"
    if($Dlg.ShowDialog($Form) -eq [System.Windows.Forms.DialogResult]::OK){ if(Open-FrezzaProject -Path $Dlg.FileName){ [System.Windows.Forms.MessageBox]::Show("Projeto aberto com sucesso.","Projeto") | Out-Null } }
})

$ButtonAlternarTema.Add_Click({
    Apply-AppTheme -Dark (-not $script:TemaEscuro)
})

$Form.Add_Resize({
        Update-MainLayout
})

$CheckGerarMusicas.Add_CheckedChanged({ Update-UiState })
$CheckGerarAlbum.Add_CheckedChanged({ Update-UiState })
Wire-GridBasicEvents -Grid $GridMusicas
Wire-GridBasicEvents -Grid $GridAlbuns

$GridMusicas.Add_CellMouseEnter({ param($sender,$e) if($e.RowIndex -ge 0 -and $e.ColumnIndex -ge 0 -and $GridMusicas.Columns[$e.ColumnIndex].Name -eq "ArquivoImagem"){ $It=$GridMusicas.Rows[$e.RowIndex].Tag; if($It){ Show-CoverHoverPreview -Path ([string]$It.CoverPath) -ScreenPoint ([System.Windows.Forms.Cursor]::Position) } } })
$GridMusicas.Add_CellMouseLeave({ param($sender,$e) if($e.ColumnIndex -ge 0 -and $GridMusicas.Columns[$e.ColumnIndex].Name -eq "ArquivoImagem"){ Hide-CoverHoverPreview } })

$GridMusicas.Add_CellContentClick({
    param($sender, $e)

    if ($e.RowIndex -lt 0) { return }
    if ($GridMusicas.Columns[$e.ColumnIndex].Name -ne "Imagem") { return }

    $Row = $GridMusicas.Rows[$e.RowIndex]
    $Item = $Row.Tag
    if ($null -eq $Item) { return }

    $ImagemEscolhida = Select-ImageFile -InitialPath $Item.CoverPath
    if (-not [string]::IsNullOrWhiteSpace($ImagemEscolhida)) {
        $Item.CoverPath = $ImagemEscolhida
        try {
            if ($null -eq $script:CoverPathByMusicKey) { $script:CoverPathByMusicKey = @{} }
            $MusicPathKey = ""
            try { if ($null -ne $Item.MusicFile) { $MusicPathKey = [string]$Item.MusicFile.FullName } } catch { }
            if (-not [string]::IsNullOrWhiteSpace($MusicPathKey)) { $script:CoverPathByMusicKey["PATH|" + $MusicPathKey.ToLowerInvariant()] = $ImagemEscolhida }
            if (-not [string]::IsNullOrWhiteSpace([string]$Item.Album) -and -not [string]::IsNullOrWhiteSpace([string]$Item.Name)) {
                $script:CoverPathByMusicKey["ALBUMNAME|" + ([string]$Item.Album).ToLowerInvariant() + "|" + ([string]$Item.Name).ToLowerInvariant()] = $ImagemEscolhida
            }
        } catch { }
        Update-ItemImageInGrid -ListView $GridMusicas -Item $Item
        $RespAlbum = [System.Windows.Forms.MessageBox]::Show(
            "Deseja aplicar esta imagem a todas as músicas do álbum '$($Item.Album)'?",
            "Aplicar imagem ao álbum",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($RespAlbum -eq [System.Windows.Forms.DialogResult]::Yes) {
            foreach ($Outro in @($script:ItensEscaneados)) {
                if ($Outro -and [string]$Outro.Album -eq [string]$Item.Album) {
                    $Outro.CoverPath = $ImagemEscolhida
                    if ($Outro.Type -eq "Música") { Update-ItemImageInGrid -ListView $GridMusicas -Item $Outro }
                    elseif ($Outro.Type -eq "Álbum") { Update-ItemImageInGrid -ListView $GridAlbuns -Item $Outro }
                }
            }
        } else { Sync-AlbumImageFromMusicItems -AlbumNome ([string]$Item.Album) }
    }
})

$GridAlbuns.Add_CellContentClick({
    param($sender, $e)

    if ($e.RowIndex -lt 0) { return }
    if ($GridAlbuns.Columns[$e.ColumnIndex].Name -ne "Imagem") { return }

    $Row = $GridAlbuns.Rows[$e.RowIndex]
    $Item = $Row.Tag
    if ($null -eq $Item) { return }

    $ImagemEscolhida = Select-ImageFile -InitialPath $Item.CoverPath
    if (-not [string]::IsNullOrWhiteSpace($ImagemEscolhida)) {
        $Item.CoverPath = $ImagemEscolhida
        Update-ItemImageInGrid -ListView $GridAlbuns -Item $Item
    }
})


$TextLegArquivoSrt.Add_SelectedIndexChanged({
    try {
        $P=[string]$TextLegArquivoSrt.Text
        if(Test-SafePath -Path $P){ $RowsLoad=@(Read-SrtFileRows -Path $P); Fill-SubtitleGrid -Rows $RowsLoad }
    } catch { }
})

# Sincroniza a linha selecionada com o trecho que está sendo reproduzido.
if ($null -eq $script:LegPlaybackSyncTimer) {
    $script:LegPlaybackSyncTimer = New-Object System.Windows.Forms.Timer
    $script:LegPlaybackSyncTimer.Interval = 80
    $script:LegPlaybackSyncTimer.Add_Tick({
        try {
            Sync-LegendClockWithPlayerState
            Update-SubtitleRowFromPlayback
        }
        catch { }
    })
    $script:LegPlaybackSyncTimer.Start()
}

$GridLegendas.Add_SelectionChanged({
    Update-ManualMarkerStatus
})

$GridLegendas.Add_CellMouseDown({
    param($sender, $e)
    if ($e.RowIndex -lt 0 -or $e.ColumnIndex -lt 0) { return }
    try {
        if ($GridLegendas.Columns[$e.ColumnIndex].Name -eq "Texto") {
            $GridLegendas.CurrentCell = $GridLegendas.Rows[$e.RowIndex].Cells[$e.ColumnIndex]
        }
    } catch { }
})

$GridLegendas.Add_RowsRemoved({
    Renumber-SubtitleGridRows
})

$GridLegendas.Add_RowsAdded({
    Renumber-SubtitleGridRows
})

$script:LegTimeEditKeyPressHandler = [System.Windows.Forms.KeyPressEventHandler]{
    param($sender, $e)

    if ([char]::IsControl($e.KeyChar) -or [char]::IsDigit($e.KeyChar) -or $e.KeyChar -eq ':' -or $e.KeyChar -eq ',' -or $e.KeyChar -eq '.') {
        return
    }

    $e.Handled = $true
}

$script:LegTextPasteKeyDownHandler = [System.Windows.Forms.KeyEventHandler]{
    param($sender, $e)

    if ($e.Control -and $e.KeyCode -eq [System.Windows.Forms.Keys]::V) {
        if (Paste-MultilineTextIntoSubtitleGrid) {
            $e.SuppressKeyPress = $true
            $e.Handled = $true
        }
    }
}

$script:LegTextCopyKeyDownHandler = [System.Windows.Forms.KeyEventHandler]{
    param($sender, $e)

    if (-not ($e.Control -and $e.KeyCode -eq [System.Windows.Forms.Keys]::C)) { return }
    if ($sender -isnot [System.Windows.Forms.TextBox]) { return }

    $TextBox = [System.Windows.Forms.TextBox]$sender
    if ($TextBox.SelectionLength -gt 0) {
        [System.Windows.Forms.Clipboard]::SetText($TextBox.SelectedText)
    }
    else {
        [System.Windows.Forms.Clipboard]::SetText([string]$TextBox.Text)
    }

    $e.SuppressKeyPress = $true
    $e.Handled = $true
}


$script:HandlingLegMultilinePaste = $false
$script:LegTextPasteTextChangedHandler = [System.EventHandler]{
    param($sender, $e)

    if ($script:HandlingLegMultilinePaste) { return }
    if ($sender -isnot [System.Windows.Forms.TextBox]) { return }

    $TextBox = [System.Windows.Forms.TextBox]$sender
    $Text = [string]$TextBox.Text

    # Captura colagens pelo menu de contexto / botão direito.
    # Usa BeginInvoke para esperar o TextBox receber o texto completo antes de dividir em linhas.
    if ($Text -match "`r|`n") {
        $TextoColado = $Text
        try {
            $TextBox.BeginInvoke([System.Action]{
                if ($script:HandlingLegMultilinePaste) { return }
                try {
                    $script:HandlingLegMultilinePaste = $true
                    [void](Set-SubtitleGridTextCellFromMultilinePaste -Text $TextoColado)
                }
                finally {
                    $script:HandlingLegMultilinePaste = $false
                }
            }) | Out-Null
        }
        catch {
            # Se o BeginInvoke falhar, deixa o CellEndEdit tentar resolver depois.
        }
    }
}

$GridLegendas.Add_EditingControlShowing({
    param($sender, $e)

    if ($e.Control -isnot [System.Windows.Forms.TextBox]) { return }

    $TextBox = [System.Windows.Forms.TextBox]$e.Control
    $TextBox.remove_KeyPress($script:LegTimeEditKeyPressHandler)
    $TextBox.remove_KeyDown($script:LegTextPasteKeyDownHandler)
    $TextBox.remove_KeyDown($script:LegTextCopyKeyDownHandler)
    $TextBox.remove_TextChanged($script:LegTextPasteTextChangedHandler)
    $TextBox.MaxLength = 32767

    if ($GridLegendas.CurrentCell -and $GridLegendas.Columns[$GridLegendas.CurrentCell.ColumnIndex].Name -in @("Inicio", "Fim")) {
        $TextBox.MaxLength = 12
        $TextBox.add_KeyPress($script:LegTimeEditKeyPressHandler)
    }
    elseif ($GridLegendas.CurrentCell -and $GridLegendas.Columns[$GridLegendas.CurrentCell.ColumnIndex].Name -eq "Texto") {
        $TextBox.add_KeyDown($script:LegTextPasteKeyDownHandler)
        $TextBox.add_KeyDown($script:LegTextCopyKeyDownHandler)
        $TextBox.add_TextChanged($script:LegTextPasteTextChangedHandler)
    }
})


$GridLegendas.Add_CellEndEdit({
    param($sender, $e)

    if ($e.RowIndex -lt 0 -or $e.ColumnIndex -lt 0) { return }
    if ($script:HandlingLegMultilinePaste) { return }

    $ColumnName = $GridLegendas.Columns[$e.ColumnIndex].Name
    if ($ColumnName -ne "Texto") { return }

    $Value = [string]$GridLegendas.Rows[$e.RowIndex].Cells[$e.ColumnIndex].Value
    if ($Value -match "`r|`n") {
        try {
            $script:HandlingLegMultilinePaste = $true
            $GridLegendas.CurrentCell = $GridLegendas.Rows[$e.RowIndex].Cells[$e.ColumnIndex]
            Set-SubtitleGridTextCellFromMultilinePaste -Text $Value | Out-Null
        }
        finally {
            $script:HandlingLegMultilinePaste = $false
        }
    }
})

$GridLegendas.Add_CellDoubleClick({
    param($sender, $e)

    if ($e.RowIndex -lt 0 -or $e.ColumnIndex -lt 0) { return }

    $ColumnName = $GridLegendas.Columns[$e.ColumnIndex].Name
    if ($ColumnName -notin @("Inicio", "Fim")) { return }

    $TimeText = [string]$GridLegendas.Rows[$e.RowIndex].Cells[$e.ColumnIndex].Value
    Seek-SubtitleAudioToGridTime -TimeText $TimeText -RowIndex $e.RowIndex
})

$GridLegendas.Add_CellValidating({
    param($sender, $e)

    if ($e.RowIndex -lt 0 -or $e.ColumnIndex -lt 0) { return }

    $ColumnName = $GridLegendas.Columns[$e.ColumnIndex].Name
    if ($ColumnName -notin @("Inicio", "Fim")) { return }

    $Normalized = Try-Normalize-SrtTimeText -Text ([string]$e.FormattedValue)
    if ($null -eq $Normalized) {
        [System.Windows.Forms.MessageBox]::Show("Digite da esquerda para a direita: HH, HH:MM ou HH:MM:SS,mmm. Exemplos: 01 = 01:00:00,000; 00:01 = 00:01:00,000.", "Tempo inválido", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        $e.Cancel = $true
        return
    }

    $GridLegendas.Rows[$e.RowIndex].Cells[$e.ColumnIndex].Value = $Normalized
})

$GridLegendas.Add_KeyDown({
    param($sender, $e)

    if ($e.Control -and $e.KeyCode -eq [System.Windows.Forms.Keys]::C) {
        # Na coluna Texto, nunca copiar a linha inteira: copia apenas o texto da célula atual.
        # Se a célula estiver em edição, respeita a seleção dentro do TextBox.
        try {
            if ($GridLegendas.EditingControl -is [System.Windows.Forms.TextBox]) {
                $Tb = [System.Windows.Forms.TextBox]$GridLegendas.EditingControl
                if ($Tb.SelectionLength -gt 0) { [System.Windows.Forms.Clipboard]::SetText($Tb.SelectedText) }
                else { [System.Windows.Forms.Clipboard]::SetText([string]$Tb.Text) }
                $e.SuppressKeyPress = $true
                $e.Handled = $true
                return
            }
        } catch { }

        if ($GridLegendas.CurrentCell -and $GridLegendas.Columns[$GridLegendas.CurrentCell.ColumnIndex].Name -eq "Texto") {
            [System.Windows.Forms.Clipboard]::SetText([string]$GridLegendas.CurrentCell.Value)
            $e.SuppressKeyPress = $true
            $e.Handled = $true
            return
        }
    }

    if ($e.Control -and $e.KeyCode -eq [System.Windows.Forms.Keys]::V) {
        if (Paste-MultilineTextIntoSubtitleGrid) {
            $e.SuppressKeyPress = $true
            $e.Handled = $true
            return
        }
    }

    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::F9) {
        Set-SelectedSubtitleLineStart
        $e.Handled = $true
    }
    elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::F10) {
        Set-SelectedSubtitleLineEnd
        $e.Handled = $true
    }
})


$Form.Add_KeyDown({
    param($sender, $e)

    if (-not ($e.Control -and $e.KeyCode -eq [System.Windows.Forms.Keys]::V)) { return }
    if ($TabControl.SelectedTab -ne $TabLegendas) { return }

    $FocusedControl = $Form.ActiveControl
    $IsSubtitleTextPaste = $false

    if ($GridLegendas.Focused -or $GridLegendas.IsCurrentCellInEditMode) {
        $IsSubtitleTextPaste = $true
    }
    elseif ($FocusedControl -is [System.Windows.Forms.TextBox] -and $GridLegendas.CurrentCell -and $GridLegendas.Columns[$GridLegendas.CurrentCell.ColumnIndex].Name -eq "Texto") {
        $IsSubtitleTextPaste = $true
    }

    if ($IsSubtitleTextPaste) {
        if (Paste-MultilineTextIntoSubtitleGrid) {
            $e.SuppressKeyPress = $true
            $e.Handled = $true
        }
    }
})

$GridPublicacao.Add_CurrentCellDirtyStateChanged({
    if ($GridPublicacao.IsCurrentCellDirty) {
        $GridPublicacao.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
    }
})

$GridPublicacao.Add_CellValueChanged({
    foreach ($Row in $GridPublicacao.Rows) {
        if ($Row.Tag) {
            try { $Row.Tag.Selected = [bool]$Row.Cells["Selecionar"].Value } catch { }
        }
    }
})

$GridPublicacao.Add_SelectionChanged({
    if ($GridPublicacao.SelectedRows.Count -gt 0) {
        Set-PublishEditorFromItem -Item $GridPublicacao.SelectedRows[0].Tag
    }
})

$GridPublicacao.Add_CellDoubleClick({
    param($sender, $e)

    if ($e.RowIndex -lt 0) {
        return
    }

    $Row = $GridPublicacao.Rows[$e.RowIndex]
    $Item = $Row.Tag

    if ($null -eq $Item) {
        return
    }

    Show-PublishEditForm -Item $Item
})

$ButtonPubPasta.Add_Click({
    $TextPubPasta.Text = Select-Folder -InitialPath $TextPubPasta.Text
})

$ButtonPubUsarSaida.Add_Click({
    Update-AutoOutputFromInput
    $TextPubPasta.Text = $TextPastaVideo.Text
    Add-Log -LogBox $TextPubLog -Mensagem "Pasta de publicação definida a partir da saída da geração: $($TextPubPasta.Text)"
})

$ButtonPubEscanear.Add_Click({
    try {
        $script:ItensPublicacao = @(Scan-PublishVideos -Folder $TextPubPasta.Text)
        Refresh-PublishGrid
        Add-Log -LogBox $TextPubLog -Mensagem "Vídeos encontrados: $($script:ItensPublicacao.Count)"
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Erro ao escanear vídeos", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
})

$ButtonPubMarcarTodos.Add_Click({ Set-PublishSelectionAll -Value $true })
$ButtonPubDesmarcarTodos.Add_Click({ Set-PublishSelectionAll -Value $false })
$ButtonPubMarcarPendentes.Add_Click({ Set-PublishSelectionPending })

$ButtonPubThumbnail.Add_Click({
    $Imagem = Select-ImageFile -InitialPath $TextPubThumbnail.Text
    if (-not [string]::IsNullOrWhiteSpace($Imagem)) { $TextPubThumbnail.Text = $Imagem }
})

$ButtonPubAplicarLinha.Add_Click({
    if ($GridPublicacao.SelectedRows.Count -eq 0) { return }
    Apply-PublishEditorToItems -Itens @($GridPublicacao.SelectedRows[0].Tag)
    Add-Log -LogBox $TextPubLog -Mensagem "Metadados aplicados à linha selecionada."
})

$ButtonPubAplicarLegenda.Add_Click({
    $Selecionados = @(Get-SelectedPublishItems)
    if ($Selecionados.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Marque os vídeos que devem receber a configuração de legenda.", "Legendas na publicação", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }
    foreach ($Item in $Selecionados) {
        Ensure-PublishSubtitleProperties -Item $Item
        $Item.SubtitleMode = [string]$ComboPubModoLegenda.SelectedItem
        $Item.AttachAllSrt = [bool]$CheckPubAnexarTodosSrt.Checked
        Update-PublishItemSubtitleSummary -Item $Item
    }
    Refresh-PublishGrid
    Export-PublishQueue -Itens $script:ItensPublicacao | Out-Null
    Add-Log -LogBox $TextPubLog -Mensagem "Configuração de legenda aplicada aos selecionados: $($Selecionados.Count)"
})

$ButtonPubAplicarSelecionados.Add_Click({
    $Selecionados = @(Get-SelectedPublishItems)
    if ($Selecionados.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Marque ao menos um vídeo.", "Publicação", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }
    Apply-PublishEditorToItems -Itens $Selecionados
    Add-Log -LogBox $TextPubLog -Mensagem "Metadados aplicados aos selecionados: $($Selecionados.Count)"
})

$ButtonPubValidar.Add_Click({
    $Itens = @(Get-SelectedPublishItems)
    if ($Itens.Count -eq 0) { $Itens = @($script:ItensPublicacao) }
    $Erros = Validate-PublishItems -Itens $Itens
    if ($Erros.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Validação concluída sem erros.", "Publicação", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    }
    else {
        [System.Windows.Forms.MessageBox]::Show(($Erros -join [Environment]::NewLine), "Pendências", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    }
})

$ButtonPubExportar.Add_Click({
    try {
        $Path = Export-PublishQueue -Itens $script:ItensPublicacao
        Add-Log -LogBox $TextPubLog -Mensagem "Fila de publicação salva em: $Path"
        [System.Windows.Forms.MessageBox]::Show("Fila salva em:`n$Path", "Publicação", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Erro ao salvar fila", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
})

$ButtonPubAplicarUltimos.Add_Click({
    if ($null -eq $script:UltimosMetadadosPublicacao) {
        [System.Windows.Forms.MessageBox]::Show(
            "Nenhum dado salvo ainda. Abra um vídeo com duplo clique, edite e salve primeiro.",
            "Aplicar últimos dados",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        return
    }

    $Selecionados = @(Get-SelectedPublishItems)

    if ($Selecionados.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "Marque os vídeos que devem receber os últimos dados salvos.",
            "Aplicar últimos dados",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        return
    }

    foreach ($Item in $Selecionados) {
        Apply-PublishMetadataToItem `
            -Item $Item `
            -Metadata $script:UltimosMetadadosPublicacao `
            -ApplyTitle $false
    }

    Refresh-PublishGrid
    Export-PublishQueue -Itens $script:ItensPublicacao | Out-Null

    Add-Log -LogBox $TextPubLog -Mensagem "Últimos dados salvos aplicados aos selecionados: $($Selecionados.Count)"
})

$ButtonPubConfig.Add_Click({
    try {
        Show-YoutubeConfigForm
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            "Config. YouTube",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})

$ButtonPubConectar.Add_Click({
    try {
        Connect-YoutubeAccount -LogBox $TextPubLog | Out-Null

		try {
			Get-YoutubePlaylists | Out-Null
			Add-Log -LogBox $TextPubLog -Mensagem "Playlists carregadas: $($script:YoutubePlaylists.Count)"
		}
		catch {
			Add-Log -LogBox $TextPubLog -Mensagem "Conta conectada, mas não foi possível carregar playlists: $($_.Exception.Message)"
		}
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Erro ao conectar YouTube", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        Add-Log -LogBox $TextPubLog -Mensagem "ERRO ao conectar: $($_.Exception.Message)"
    }
})

$ButtonPubEnviarSelecionados.Add_Click({
    Publish-SelectedVideosToYoutube -Itens @(Get-SelectedPublishItems)
})

$ButtonPubEnviarPendentes.Add_Click({
    $Pendentes = @($script:ItensPublicacao | Where-Object { $_.Status -ne "Enviado" })
    Publish-SelectedVideosToYoutube -Itens $Pendentes
})

$ButtonEscanear.Add_Click({
    if (-not (Validate-MainPaths)) { return }

    $ButtonEscanear.Enabled = $false
    $ProgressEscanear.Visible = $true
    $LabelProgressoEscanear.Visible = $true
    $ProgressEscanear.BringToFront(); $LabelProgressoEscanear.BringToFront()
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $script:ItensEscaneados = Scan-GenerationItems `
            -PastaMP3 $TextPastaMP3.Text `
            -PastaVideo $TextPastaVideo.Text `
            -NomeCapa "" `
            -IncluirMusicas $true `
            -IncluirAlbuns $true `
            -ModoLeitura ([string]$ComboModoLeitura.SelectedItem)

        Populate-MediaTabs

        if ([string]::IsNullOrWhiteSpace($TextLegPastaLegendas.Text)) {
            $TextLegPastaLegendas.Text = Get-AutoSubtitlePath -PastaMP3 $TextPastaMP3.Text
            $TextPastaLegendas.Text = $TextLegPastaLegendas.Text
        }
        Refresh-SubtitleMusicList
        Load-SelectedSubtitleInfo
        if (Get-Command Load-SelectedSeparateAudioInfo -ErrorAction SilentlyContinue) { Load-SelectedSeparateAudioInfo }

        Update-UiState

        [System.Windows.Forms.MessageBox]::Show(
            "Escaneamento concluído. Itens encontrados: $($script:ItensEscaneados.Count)",
            "Escanear músicas e álbuns",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            "Erro ao escanear",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
    finally {
        $ProgressEscanear.Visible = $false
        $LabelProgressoEscanear.Visible = $false
        $ButtonEscanear.Enabled = $true
    }
})

$ButtonMarcarTodosMusicas.Add_Click({ Set-GridSelectionAll -Grid $GridMusicas -Value $true; Update-UiState })
$ButtonDesmarcarTodosMusicas.Add_Click({ Set-GridSelectionAll -Grid $GridMusicas -Value $false; Update-UiState })
$ButtonMarcarPendentesMusicas.Add_Click({ Set-GridSelectionPendentes -Grid $GridMusicas; Update-UiState })

$ButtonMarcarTodosAlbuns.Add_Click({ Set-GridSelectionAll -Grid $GridAlbuns -Value $true; Update-UiState })
$ButtonDesmarcarTodosAlbuns.Add_Click({ Set-GridSelectionAll -Grid $GridAlbuns -Value $false; Update-UiState })
$ButtonMarcarPendentesAlbuns.Add_Click({ Set-GridSelectionPendentes -Grid $GridAlbuns; Update-UiState })

$ButtonReplicarImagemAlbum.Add_Click({
    $ItemOrigem = $script:ItemImagemParaReplicar

    if ($null -eq $ItemOrigem -or $ItemOrigem.Type -ne "Música") {
        [System.Windows.Forms.MessageBox]::Show(
            "Escolha primeiro uma imagem em uma linha de música individual.",
            "Replicar imagem",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null

        $ButtonReplicarImagemAlbum.Enabled = $false
        return
    }

    if ([string]::IsNullOrWhiteSpace([string]$ItemOrigem.CoverPath) -or -not (Test-SafePath -Path $ItemOrigem.CoverPath)) {
        [System.Windows.Forms.MessageBox]::Show(
            "A música escolhida não possui uma imagem válida para replicar.",
            "Replicar imagem",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null

        $ButtonReplicarImagemAlbum.Enabled = $false
        $script:ItemImagemParaReplicar = $null
        return
    }

    foreach ($Item in $script:ItensEscaneados) {
        if ($Item -and $Item.Album -eq $ItemOrigem.Album) {
            $Item.CoverPath = $ItemOrigem.CoverPath

            if ($Item.Type -eq "Música") {
                Update-ItemImageInGrid -ListView $GridMusicas -Item $Item
            }
            elseif ($Item.Type -eq "Álbum") {
                Update-ItemImageInGrid -ListView $GridAlbuns -Item $Item
            }
        }
    }

    [System.Windows.Forms.MessageBox]::Show(
        "Imagem replicada para todas as músicas do álbum e sincronizada com a aba Álbuns: $($ItemOrigem.Album)",
        "Replicar imagem",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null

    $script:ItemImagemParaReplicar = $null
    $ButtonReplicarImagemAlbum.Enabled = $false
})
function Start-Processing {
    param(
        [object[]]$Itens
    )

    if ($Itens.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "Nenhum item selecionado para processamento.",
            "Gerar",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null

        return
    }

    if (($CheckGerarMusicas.Checked -or $CheckGerarAlbum.Checked) -and -not (Validate-SelectedImages -Itens $Itens)) {
        return
    }

    Save-AppConfig `
        -PastaMP3 $TextPastaMP3.Text `
        -PastaVideo $TextPastaVideo.Text `
        -PastaLegendas $TextPastaLegendas.Text `
        -NomeCapa "" `
        -GerarMusicas ([bool]$CheckGerarMusicas.Checked) `
        -GerarAlbum ([bool]$CheckGerarAlbum.Checked) `
        -SegundosExtras ([double]$NumericExtra.Value) `
        -SilencioEntreFaixas ([double]$NumericSilencioEntreFaixas.Value) `
        -Detalhado ([bool]$CheckDetalhado.Checked) `
        -ValidarDuracao ([bool]$CheckValidarDuracao.Checked) `
        -ModoLeitura ([string]$ComboModoLeitura.SelectedItem) `
        -SaidaAutomatica $true

    $script:CancelarGeracao = $false
    $Processing = Show-ProcessingForm -MainForm $Form

    try {
        Process-GenerationItems `
            -Itens $Itens `
            -GerarVideosMusicas ([bool]$CheckGerarMusicas.Checked) `
            -GerarVideoAlbum ([bool]$CheckGerarAlbum.Checked) `
            -SegundosExtras ([double]$NumericExtra.Value) `
            -SilencioEntreFaixas ([double]$NumericSilencioEntreFaixas.Value) `
            -Detalhado ([bool]$CheckDetalhado.Checked) `
            -ValidarDuracaoExistentes ([bool]$CheckValidarDuracao.Checked) `
            -OutputRoot $TextPastaVideo.Text `
            -LogBox $Processing.LogBox `
            -StatusLabel $Processing.StatusLabel
    }
    catch {
        Add-Log -LogBox $Processing.LogBox -Mensagem "ERRO INESPERADO: $($_.Exception.Message)"
        $Processing.StatusLabel.Text = "Erro inesperado."
    }
    finally {
        $Processing.ButtonInterromper.Enabled = $false
        $script:ProcessoAtual = $null
        $Form.Show()
        $Form.Refresh()
    }
}

$ButtonGerarSelecionadosMusicas.Add_Click({
    $Selecionados = Get-SelectedGenerationItems -ListView $GridMusicas
    Start-Processing -Itens $Selecionados
})

$ButtonGerarSelecionadosAlbuns.Add_Click({
    $Selecionados = Get-SelectedGenerationItems -ListView $GridAlbuns
    Start-Processing -Itens $Selecionados
})

$ButtonGerarTodos.Add_Click({
    if (-not (Validate-MainPaths)) { return }

    try {
        if ($script:ItensEscaneados.Count -eq 0) {
            $script:ItensEscaneados = Scan-GenerationItems `
                -PastaMP3 $TextPastaMP3.Text `
                -PastaVideo $TextPastaVideo.Text `
                -NomeCapa "" `
                -IncluirMusicas ([bool]$CheckGerarMusicas.Checked) `
                -IncluirAlbuns ([bool]$CheckGerarAlbum.Checked) `
                -ModoLeitura ([string]$ComboModoLeitura.SelectedItem)

            Populate-MediaTabs
        }

        $Itens = Get-AllSelectedItems
        Start-Processing -Itens $Itens
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            "Erro ao gerar todos",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})

$Form.Add_FormClosing({
    $script:CancelarGeracao = $true

    if ($script:ProcessoAtual -and -not $script:ProcessoAtual.HasExited) {
        try {
            $script:ProcessoAtual.Kill()
        }
        catch {
            # O processo pode já ter terminado.
        }
    }
})

$Config = Load-AppConfig

if ($Config) {
    if (-not [string]::IsNullOrWhiteSpace([string]$Config.PastaMP3)) { $TextPastaMP3.Text = [string]$Config.PastaMP3 }
    if (-not [string]::IsNullOrWhiteSpace([string]$Config.PastaVideo)) { $TextPastaVideo.Text = [string]$Config.PastaVideo }
    if (-not [string]::IsNullOrWhiteSpace([string]$Config.PastaLegendas)) { $TextPastaLegendas.Text = [string]$Config.PastaLegendas }

    if ($null -ne $Config.GerarMusicas) { $CheckGerarMusicas.Checked = [bool]$Config.GerarMusicas }
    if ($null -ne $Config.GerarAlbum) { $CheckGerarAlbum.Checked = [bool]$Config.GerarAlbum }
    if ($null -ne $Config.Detalhado) { $CheckDetalhado.Checked = [bool]$Config.Detalhado }
    if ($null -ne $Config.ValidarDuracao) { $CheckValidarDuracao.Checked = [bool]$Config.ValidarDuracao }
    if ($null -ne $Config.SaidaAutomatica) { $CheckSaidaAutomatica.Checked = [bool]$Config.SaidaAutomatica }

    if ($null -ne $Config.SegundosExtras) { $NumericExtra.Value = [decimal]$Config.SegundosExtras }
    if ($null -ne $Config.SilencioEntreFaixas) { $NumericSilencioEntreFaixas.Value = [decimal]$Config.SilencioEntreFaixas }

    if ($Config.ModoLeitura -and $ComboModoLeitura.Items.Contains([string]$Config.ModoLeitura)) {
        $ComboModoLeitura.SelectedItem = [string]$Config.ModoLeitura
    }
}

if ($CheckSaidaAutomatica.Checked) {
    $AutoPathInicial = Get-AutoOutputPath -PastaMP3 $TextPastaMP3.Text

    if (-not [string]::IsNullOrWhiteSpace($AutoPathInicial)) {
        $TextPastaVideo.Text = $AutoPathInicial
    }

    $TextPastaVideo.Enabled = $false
    $ButtonPastaVideo.Enabled = $false

    $AutoLegendaInicial = Get-AutoSubtitlePath -PastaMP3 $TextPastaMP3.Text

    if ([string]::IsNullOrWhiteSpace($TextPastaLegendas.Text) -and -not [string]::IsNullOrWhiteSpace($AutoLegendaInicial)) {
        $TextPastaLegendas.Text = $AutoLegendaInicial
    }
}

if ($null -ne $TextLegPastaLegendas) {
    $TextLegPastaLegendas.Text = $TextPastaLegendas.Text
}

if ([string]::IsNullOrWhiteSpace($TextPubPasta.Text)) {
    $TextPubPasta.Text = $TextPastaVideo.Text
}

$FilaSalva = @(Import-PublishQueue)
if ($FilaSalva.Count -gt 0) {
    $script:ItensPublicacao = $FilaSalva
    foreach ($Item in $script:ItensPublicacao) { Ensure-PublishSubtitleProperties -Item $Item }
    Refresh-PublishGrid
    Add-Log -LogBox $TextPubLog -Mensagem "Fila de publicação carregada: $($FilaSalva.Count) item(ns)."
}

Update-UiState
Update-MainLayout
Apply-AppTheme -Dark $script:TemaEscuro
Update-MainLayout

[void]$Form.ShowDialog()
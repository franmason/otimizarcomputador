#requires -Version 5.1
<#
    Otimizador de PC - MVP
    ----------------------
    Faz SOMENTE ações seguras, sem exigir administrador:
      1. Limpa %TEMP% (arquivos com mais de 1 dia)
      2. Limpa C:\Windows\Temp (mesma regra; o que não tiver permissão é pulado)
      3. Limpa o cache do Chrome e do Edge (Cache, Code Cache e GPUCache dos perfis
         Default e "Profile *"), pulando o navegador se ele estiver aberto
      4. ipconfig /flushdns
      5. Diagnóstico somente leitura
      6. Abre o Gerenciador de Tarefas na aba Inicialização (não desativa nada sozinho)

    Não mexe em registro, serviços, plano de energia, efeitos visuais ou políticas.
    Não toca em Lixeira, Downloads, Documentos, histórico, senhas, cookies ou favoritos.
    Nunca segue junctions/symlinks: qualquer ponto de reanálise é ignorado.

    Para poder DESFAZER, os arquivos não são apagados na hora: são movidos para
    %LOCALAPPDATA%\OtimizadorPC\Backup. O backup guarda só a última limpeza e é
    apagado definitivamente na próxima otimização, ao clicar em "Esvaziar backup"
    ou automaticamente depois de 7 dias.

    Instalação: o mesmo .exe é instalador, app e desinstalador (ver seção
    "Instalação"). Instala só para o usuário atual, sem administrador. A única
    escrita no registro é a entrada do próprio app em "Programas e Recursos"
    (HKCU), removida ao desinstalar.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ------------------------------------------------------------------ Configuração

$script:NomeApp          = 'Otimizador de PC'
$script:Versao           = '1.0.0'
$script:PastaInstalacao  = Join-Path $env:LOCALAPPDATA 'Programs\OtimizadorPC'
$script:ExeInstalado     = Join-Path $script:PastaInstalacao 'Otimizador.exe'
$script:ChaveDesinstalar = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\OtimizadorPC'

# Atualização automática: cada Release no GitHub tem o Instalar-Otimizador.exe e um versao.json
# (gerados pelo Gerar-EXE.ps1). O app lê o versao.json da Release mais recente.
$script:RepoGitHub       = 'franmason/otimizarcomputador'
$script:UrlReleases      = "https://github.com/$($script:RepoGitHub)/releases"

$script:PastaApp      = Join-Path $env:LOCALAPPDATA 'OtimizadorPC'
$script:PastaBackup   = Join-Path $script:PastaApp 'Backup'
$script:DiasBackup    = 7
$script:PastasCache   = @('Cache', 'Code Cache', 'GPUCache')
$script:FolhasAceitas = @('Temp', 'Tmp', 'Cache', 'Code Cache', 'GPUCache')
$script:txtLog        = $null

# ------------------------------------------------------------------ Utilitários

function Formatar-Tamanho {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N1} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    return '{0:N0} KB' -f ($Bytes / 1KB)
}

function Manter-Responsivo {
    # Deixa a janela redesenhar durante operações longas.
    if ($script:txtLog) { [System.Windows.Forms.Application]::DoEvents() }
}

function Escrever-Log {
    param([string]$Texto)
    if ($script:txtLog) {
        $script:txtLog.AppendText(('[{0:HH:mm:ss}] {1}' -f (Get-Date), $Texto) + "`r`n")
        Manter-Responsivo
    }
}

function Test-PontoDeReanalise {
    param([System.IO.FileSystemInfo]$Item)
    return [bool]($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
}

function Test-ProcessoAberto {
    param([string]$Nome)
    return [bool](Get-Process -Name $Nome -ErrorAction SilentlyContinue)
}

function Test-PastaPermitida {
    # Trava de segurança: só aceita pastas cujo nome final é Temp ou de cache,
    # e nunca a raiz de uma unidade.
    param([string]$Caminho)
    if ([string]::IsNullOrWhiteSpace($Caminho)) { return $false }
    try { $completo = [System.IO.Path]::GetFullPath($Caminho).TrimEnd('\') } catch { return $false }
    if ($completo.Length -le 3) { return $false }
    return ($script:FolhasAceitas -contains [System.IO.Path]::GetFileName($completo))
}

# ------------------------------------------------------------------ Limpeza

function Obter-ArquivosElegiveis {
    # Lista os arquivos da pasta (e subpastas) mais antigos que $DiasMinimos.
    # Junctions, symlinks e arquivos de nuvem (pontos de reanálise) são ignorados,
    # então a busca nunca sai da pasta alvo.
    param([string]$Caminho, [double]$DiasMinimos)

    $resultado = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
    if ([string]::IsNullOrWhiteSpace($Caminho) -or -not [System.IO.Directory]::Exists($Caminho)) { return ,$resultado }

    $raiz = New-Object System.IO.DirectoryInfo($Caminho)
    if (Test-PontoDeReanalise $raiz) { return ,$resultado }

    $limite = (Get-Date).AddDays(-$DiasMinimos)
    $pilha = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $pilha.Push($raiz)

    while ($pilha.Count -gt 0) {
        $pasta = $pilha.Pop()
        try { $itens = $pasta.GetFileSystemInfos() } catch { continue }
        foreach ($item in $itens) {
            if (Test-PontoDeReanalise $item) { continue }
            if ($item -is [System.IO.DirectoryInfo]) { $pilha.Push($item) }
            elseif ($item.LastWriteTime -lt $limite) { $resultado.Add($item) }
        }
        Manter-Responsivo
    }
    return ,$resultado
}

function Limpar-Pasta {
    # Move os arquivos elegíveis para o backup e registra a origem no manifesto,
    # para que possam ser restaurados. Arquivos em uso ou sem permissão são pulados.
    param(
        [string]$Caminho,
        [double]$DiasMinimos = 1,
        [string]$PastaBackup = $script:PastaBackup
    )

    $r = [pscustomobject]@{ Movidos = 0; Bytes = [long]0; Pulados = 0 }
    $arquivos = Obter-ArquivosElegiveis $Caminho $DiasMinimos
    if ($arquivos.Count -eq 0) { return $r }

    $pastaArquivos = Join-Path $PastaBackup 'arquivos'
    [void][System.IO.Directory]::CreateDirectory($pastaArquivos)
    $criado = Join-Path $PastaBackup 'criado.txt'
    if (-not [System.IO.File]::Exists($criado)) {
        [System.IO.File]::WriteAllText($criado, (Get-Date).ToString('o'))
    }

    $manifesto = Join-Path $PastaBackup 'manifesto.txt'
    $escritor = New-Object System.IO.StreamWriter($manifesto, $true, (New-Object System.Text.UTF8Encoding($false)))
    $escritor.AutoFlush = $true
    try {
        $i = 0
        foreach ($arquivo in $arquivos) {
            try {
                $tamanho = $arquivo.Length
                $guardado = Join-Path $pastaArquivos ([guid]::NewGuid().ToString('N'))
                [System.IO.File]::Move($arquivo.FullName, $guardado)
                $escritor.WriteLine($guardado + "`t" + $arquivo.FullName)
                $r.Movidos++
                $r.Bytes += $tamanho
            } catch {
                $r.Pulados++
            }
            if ((++$i % 200) -eq 0) { Manter-Responsivo }
        }
    } finally {
        $escritor.Dispose()
    }
    return $r
}

function Remover-PastaSegura {
    # Apaga uma pasta definitivamente sem seguir junctions/symlinks:
    # um link encontrado é removido como link, o destino dele não é tocado.
    param([string]$Caminho)
    if (-not [System.IO.Directory]::Exists($Caminho)) { return }

    $raiz = New-Object System.IO.DirectoryInfo($Caminho)
    if (Test-PontoDeReanalise $raiz) {
        try { $raiz.Delete() } catch { }
        return
    }
    try { $itens = $raiz.GetFileSystemInfos() } catch { $itens = @() }
    foreach ($item in $itens) {
        try {
            if (Test-PontoDeReanalise $item) { $item.Delete() }
            elseif ($item -is [System.IO.DirectoryInfo]) { Remover-PastaSegura $item.FullName }
            else {
                $item.Attributes = [System.IO.FileAttributes]::Normal
                $item.Delete()
            }
        } catch { }
    }
    try { $raiz.Delete() } catch { }
}

function Restaurar-Backup {
    # Devolve os arquivos do backup para os locais originais.
    # Não sobrescreve nada: se já existir um arquivo com o mesmo nome, o backup é mantido.
    param(
        [string]$PastaBackup = $script:PastaBackup,
        [string[]]$PularPrefixos = @()
    )

    $r = [pscustomobject]@{ Restaurados = 0; JaExistiam = 0; Falhas = 0; Mantidos = 0 }
    $manifesto = Join-Path $PastaBackup 'manifesto.txt'
    if (-not [System.IO.File]::Exists($manifesto)) { return $r }

    $restantes = New-Object 'System.Collections.Generic.List[string]'
    $i = 0
    foreach ($linha in [System.IO.File]::ReadAllLines($manifesto, [System.Text.Encoding]::UTF8)) {
        $partes = $linha -split "`t", 2
        if ($partes.Count -ne 2) { continue }
        $guardado = $partes[0]
        $original = $partes[1]
        if (-not [System.IO.File]::Exists($guardado)) { continue }

        $pular = $false
        foreach ($prefixo in $PularPrefixos) {
            if ($original.StartsWith($prefixo, [System.StringComparison]::OrdinalIgnoreCase)) { $pular = $true; break }
        }
        if ($pular) { $restantes.Add($linha); $r.Mantidos++; continue }

        if ([System.IO.File]::Exists($original) -or [System.IO.Directory]::Exists($original)) {
            $restantes.Add($linha); $r.JaExistiam++; continue
        }
        try {
            [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($original))
            [System.IO.File]::Move($guardado, $original)
            $r.Restaurados++
        } catch {
            $restantes.Add($linha); $r.Falhas++
        }
        if ((++$i % 200) -eq 0) { Manter-Responsivo }
    }

    if ($restantes.Count -eq 0) {
        Remover-PastaSegura $PastaBackup
    } else {
        [System.IO.File]::WriteAllLines($manifesto, $restantes, (New-Object System.Text.UTF8Encoding($false)))
    }
    return $r
}

function Obter-InfoBackup {
    param([string]$PastaBackup = $script:PastaBackup)
    $pastaArquivos = Join-Path $PastaBackup 'arquivos'
    if (-not [System.IO.Directory]::Exists($pastaArquivos)) { return $null }

    $n = 0; $bytes = [long]0
    foreach ($f in (New-Object System.IO.DirectoryInfo($pastaArquivos)).EnumerateFiles()) { $n++; $bytes += $f.Length }
    if ($n -eq 0) { return $null }

    $data = (New-Object System.IO.DirectoryInfo($PastaBackup)).CreationTime
    $criado = Join-Path $PastaBackup 'criado.txt'
    if ([System.IO.File]::Exists($criado)) {
        try { $data = [datetime]::Parse([System.IO.File]::ReadAllText($criado), $null, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch { }
    }
    return [pscustomobject]@{ Arquivos = $n; Bytes = $bytes; Data = $data }
}

function Obter-PastasCache {
    param([string]$DadosUsuario)
    $lista = @()
    if (-not [System.IO.Directory]::Exists($DadosUsuario)) { return $lista }
    $perfis = Get-ChildItem -LiteralPath $DadosUsuario -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { ($_.Name -eq 'Default' -or $_.Name -like 'Profile *') -and -not (Test-PontoDeReanalise $_) }
    foreach ($perfil in $perfis) {
        foreach ($nome in $script:PastasCache) {
            $c = Join-Path $perfil.FullName $nome
            if ([System.IO.Directory]::Exists($c)) { $lista += $c }
        }
    }
    return $lista
}

function Limpar-DNS {
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo('ipconfig.exe', '/flushdns')
        $psi.CreateNoWindow = $true
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        [void]$p.StandardOutput.ReadToEnd()
        $p.WaitForExit()
        return ($p.ExitCode -eq 0)
    } catch {
        return $false
    }
}

# ------------------------------------------------------------------ Ações

$script:Acoes = @(
    [pscustomobject]@{
        Id = 'TempUsuario'; Tipo = 'Pasta'; Nome = 'Temporários do usuário'
        Titulo = 'Limpar arquivos temporários do usuário (%TEMP%)'
        Descricao = 'Só arquivos com mais de 1 dia. Arquivos em uso são pulados.'
        Dias = 1; Processo = $null; Pastas = { , @($env:TEMP) }
    }
    [pscustomobject]@{
        Id = 'TempWindows'; Tipo = 'Pasta'; Nome = 'Temporários do Windows'
        Titulo = 'Limpar temporários do Windows (C:\Windows\Temp)'
        Descricao = 'Só arquivos com mais de 1 dia. O que não tiver permissão é pulado.'
        Dias = 1; Processo = $null; Pastas = { , @(Join-Path $env:windir 'Temp') }
    }
    [pscustomobject]@{
        Id = 'Chrome'; Tipo = 'Pasta'; Nome = 'Google Chrome'
        Titulo = 'Limpar cache do Google Chrome'
        Descricao = 'Só arquivos guardados de sites. Histórico, senhas, cookies e favoritos não são tocados. Pulado se estiver aberto.'
        Dias = 0; Processo = 'chrome'; Pastas = { Obter-PastasCache (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data') }
    }
    [pscustomobject]@{
        Id = 'Edge'; Tipo = 'Pasta'; Nome = 'Microsoft Edge'
        Titulo = 'Limpar cache do Microsoft Edge'
        Descricao = 'Mesma regra do Chrome. Pulado se o Edge estiver aberto.'
        Dias = 0; Processo = 'msedge'; Pastas = { Obter-PastasCache (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data') }
    }
    [pscustomobject]@{
        Id = 'DNS'; Tipo = 'DNS'; Nome = 'Cache de DNS'
        Titulo = 'Limpar cache de DNS (ipconfig /flushdns)'
        Descricao = 'Ajuda quando um site não abre. O Windows recria o cache sozinho, não precisa desfazer.'
        Dias = 0; Processo = $null; Pastas = { , @() }
    }
)

function Obter-PastasDaAcao {
    param($Acao)
    return @(& $Acao.Pastas | Where-Object { Test-PastaPermitida $_ })
}

function Analisar-Acao {
    # Somente leitura: conta o que seria feito, sem alterar nada.
    param($Acao)
    $res = [pscustomobject]@{ Acao = $Acao; Status = 'ok'; Mensagem = ''; Arquivos = 0; Bytes = [long]0 }

    if ($Acao.Tipo -eq 'DNS') {
        $res.Mensagem = 'o cache de DNS será limpo.'
        return $res
    }
    if ($Acao.Processo -and (Test-ProcessoAberto $Acao.Processo)) {
        $res.Status = 'pulado'
        $res.Mensagem = "será PULADO: o $($Acao.Nome) está aberto (ou rodando em segundo plano). Feche-o para limpar."
        return $res
    }
    $pastas = Obter-PastasDaAcao $Acao
    if ($pastas.Count -eq 0) {
        $res.Status = 'vazio'
        $res.Mensagem = 'pasta não encontrada, nada a fazer.'
        return $res
    }
    foreach ($p in $pastas) {
        foreach ($a in (Obter-ArquivosElegiveis $p $Acao.Dias)) { $res.Arquivos++; $res.Bytes += $a.Length }
    }
    $res.Mensagem = '{0:N0} arquivo(s), {1}.' -f $res.Arquivos, (Formatar-Tamanho $res.Bytes)
    return $res
}

function Executar-Acao {
    param($Acao)
    if ($Acao.Tipo -eq 'DNS') {
        if (Limpar-DNS) { return 'cache de DNS limpo.' }
        return 'não foi possível limpar o cache de DNS.'
    }
    if ($Acao.Processo -and (Test-ProcessoAberto $Acao.Processo)) {
        return "pulado: o $($Acao.Nome) está aberto."
    }
    $movidos = 0; $bytes = [long]0; $pulados = 0
    foreach ($p in (Obter-PastasDaAcao $Acao)) {
        $r = Limpar-Pasta -Caminho $p -DiasMinimos $Acao.Dias -PastaBackup $script:PastaBackup
        $movidos += $r.Movidos; $bytes += $r.Bytes; $pulados += $r.Pulados
    }
    $texto = '{0:N0} arquivo(s) limpos ({1})' -f $movidos, (Formatar-Tamanho $bytes)
    if ($pulados -gt 0) { $texto += ', {0:N0} pulados (em uso ou sem permissão)' -f $pulados }
    return $texto + '.'
}

function Obter-PrefixosNavegadoresAbertos {
    $prefixos = @()
    foreach ($acao in $script:Acoes) {
        if ($acao.Processo -and (Test-ProcessoAberto $acao.Processo)) {
            $prefixos += (Obter-PastasDaAcao $acao)
        }
    }
    return $prefixos
}

# ------------------------------------------------------------------ Diagnóstico

function Obter-Diagnostico {
    # Somente leitura.
    $l = New-Object 'System.Collections.Generic.List[string]'
    $rec = New-Object 'System.Collections.Generic.List[string]'

    $cs = $null; $csp = $null; $os = $null; $cpu = $null
    try { $cs  = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop } catch { }
    try { $csp = Get-CimInstance Win32_ComputerSystemProduct -ErrorAction Stop } catch { }
    try { $os  = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } catch { }
    try { $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1 } catch { }

    $l.Add('===== DIAGNÓSTICO (somente leitura) =====')
    if ($cs) {
        $modelo = "$($cs.Manufacturer) $($cs.Model)"
        if ($csp -and $csp.Version -and $cs.Manufacturer -match 'Lenovo') { $modelo = "$($cs.Manufacturer) $($csp.Version) ($($cs.Model))" }
        $l.Add("Modelo: $modelo")
    }
    if ($cpu) { $l.Add("Processador: $($cpu.Name.Trim())") }

    $totalGB = 0
    if ($os) {
        $totalGB = $os.TotalVisibleMemorySize / 1MB
        $usoPct = [math]::Round(100 * (1 - $os.FreePhysicalMemory / $os.TotalVisibleMemorySize))
        $l.Add(('Memória RAM: {0:N1} GB, em uso: {1}%' -f $totalGB, $usoPct))
        if ($usoPct -ge 80) { $rec.Add("Uso de memória alto ($usoPct%). Feche abas e programas que não estiver usando.") }
    }

    try {
        $pentes = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop)
        $slots = (@(Get-CimInstance Win32_PhysicalMemoryArray -ErrorAction Stop) | Measure-Object -Property MemoryDevices -Sum).Sum
        foreach ($p in $pentes) {
            $vel = if ($p.ConfiguredClockSpeed) { $p.ConfiguredClockSpeed } else { $p.Speed }
            $l.Add(('  Pente {0}: {1:N0} GB, {2} MHz' -f $p.DeviceLocator, ($p.Capacity / 1GB), $vel))
        }
        if ($slots) {
            $livres = [math]::Max(0, $slots - $pentes.Count)
            $l.Add("  Slots: $slots no total, $livres livre(s)")
            if ($totalGB -gt 0 -and $totalGB -le 8.5) {
                if ($livres -gt 0) { $rec.Add("Há $livres slot(s) de memória livre(s): adicionar um pente (ex.: +8 GB) deixaria o PC bem mais folgado.") }
                else { $rec.Add('Não há slot de memória livre: para ter mais RAM seria preciso trocar um pente por outro maior.') }
            }
        }
    } catch { $l.Add('  Pentes de memória: não foi possível ler.') }

    try {
        $discos = @(Get-PhysicalDisk -ErrorAction Stop)
        foreach ($d in $discos) {
            $tipo = [string]$d.MediaType
            if ($tipo -notin @('SSD', 'HDD')) { $tipo = if ($d.SpindleSpeed -eq 0) { 'SSD (provável)' } else { 'desconhecido' } }
            $l.Add(('Disco: {0} - {1}, {2}' -f $d.FriendlyName, $tipo, (Formatar-Tamanho $d.Size)))
            if ($tipo -eq 'HDD') { $rec.Add("O disco '$($d.FriendlyName)' é HDD. Trocar por SSD é a melhoria que mais acelera o PC.") }
        }
    } catch { $l.Add('Disco: não foi possível identificar o tipo.') }

    try {
        $c = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
        $pct = [math]::Round(100 * $c.FreeSpace / $c.Size)
        $l.Add(('Espaço livre no C: {0} de {1} ({2}%)' -f (Formatar-Tamanho $c.FreeSpace), (Formatar-Tamanho $c.Size), $pct))
        if ($pct -lt 15 -or $c.FreeSpace -lt 20GB) { $rec.Add('Pouco espaço livre no C:. Remova programas e arquivos grandes que não usa (o Otimizador não apaga arquivos pessoais).') }
    } catch { }

    $l.Add('')
    $l.Add('Programas que mais usam memória:')
    $grupos = Get-Process -ErrorAction SilentlyContinue | Group-Object -Property ProcessName | ForEach-Object {
        [pscustomobject]@{ Nome = $_.Name; Qtd = $_.Count; Bytes = ($_.Group | Measure-Object -Property WorkingSet64 -Sum).Sum }
    } | Sort-Object -Property Bytes -Descending | Select-Object -First 8
    foreach ($g in $grupos) {
        $qtd = if ($g.Qtd -gt 1) { " ($($g.Qtd) processos)" } else { '' }
        $l.Add(('  {0}{1}: {2}' -f $g.Nome, $qtd, (Formatar-Tamanho $g.Bytes)))
    }
    $chrome = $grupos | Where-Object { $_.Nome -eq 'chrome' }
    if ($chrome -and $chrome.Bytes -gt 1.5GB) { $rec.Add('O Chrome está usando muita memória. Feche abas que não estiver usando.') }

    $l.Add('')
    $l.Add('Recomendações:')
    if ($rec.Count -eq 0) { $rec.Add('Nenhum problema evidente encontrado.') }
    foreach ($r in $rec) { $l.Add("  - $r") }
    return $l
}

# ------------------------------------------------------------------ Interface
# Os controles ficam em $script:UI para que os eventos (que rodam depois que
# Criar-Interface termina) consigam acessá-los.

$script:UI = @{}

function Mostrar-Mensagem {
    param([string]$Texto, [string]$Titulo = 'Otimizador de PC', [string]$Botoes = 'OK', [string]$Icone = 'Information')
    if ($script:UI.Form) {
        return [System.Windows.Forms.MessageBox]::Show($script:UI.Form, $Texto, $Titulo, $Botoes, $Icone)
    }
    return [System.Windows.Forms.MessageBox]::Show($Texto, $Titulo, $Botoes, $Icone)
}

function Atualizar-StatusBackup {
    $info = Obter-InfoBackup
    if ($info) {
        $script:UI.LblBackup.Text = 'Backup da última limpeza: {0:N0} arquivo(s), {1}, de {2:dd/MM/yyyy HH:mm}. Pode ser desfeito.' -f $info.Arquivos, (Formatar-Tamanho $info.Bytes), $info.Data
    } else {
        $script:UI.LblBackup.Text = 'Nenhum backup guardado (não há limpeza para desfazer).'
    }
    $script:UI.BtnDesfazer.Enabled = [bool]$info
    $script:UI.BtnEsvaziar.Enabled = [bool]$info
}

function Definir-Ocupado {
    param([bool]$Sim)
    foreach ($b in $script:UI.Botoes) { $b.Enabled = -not $Sim }
    foreach ($c in $script:UI.Caixas.Values) { $c.Enabled = -not $Sim }
    $script:UI.Form.UseWaitCursor = $Sim
    if (-not $Sim) { Atualizar-StatusBackup }
    [System.Windows.Forms.Application]::DoEvents()
}

function Obter-Selecionadas {
    return @($script:Acoes | Where-Object { $script:UI.Caixas[$_.Id].Checked })
}

function Obter-LinhasAnalise {
    param($Acoes)
    $linhas = @()
    foreach ($acao in $Acoes) {
        Escrever-Log "Analisando: $($acao.Nome)..."
        $res = Analisar-Acao $acao
        $linhas += "- $($acao.Nome): $($res.Mensagem)"
    }
    return $linhas
}

function Ao-Analisar {
    $acoes = Obter-Selecionadas
    if ($acoes.Count -eq 0) { [void](Mostrar-Mensagem 'Marque pelo menos uma ação.'); return }
    Definir-Ocupado $true
    try {
        Escrever-Log '----- ANÁLISE (nada foi alterado) -----'
        foreach ($linha in (Obter-LinhasAnalise $acoes)) { Escrever-Log $linha }
    } finally { Definir-Ocupado $false }
}

function Ao-Otimizar {
    $acoes = Obter-Selecionadas
    if ($acoes.Count -eq 0) { [void](Mostrar-Mensagem 'Marque pelo menos uma ação.'); return }
    Definir-Ocupado $true
    try {
        Escrever-Log '----- Preparando a otimização -----'
        $linhas = Obter-LinhasAnalise $acoes
        $msg = "Será feito:`r`n`r`n" + ($linhas -join "`r`n")
        $msg += "`r`n`r`nOs arquivos ficam guardados em backup por até $($script:DiasBackup) dias. Para devolvê-los, use 'Desfazer última limpeza'."
        if (Obter-InfoBackup) { $msg += "`r`n`r`nAtenção: o backup da limpeza anterior será apagado de vez." }
        $msg += "`r`n`r`nDeseja continuar?"

        if ((Mostrar-Mensagem $msg 'Confirmar otimização' 'YesNo' 'Question') -ne 'Yes') {
            Escrever-Log 'Otimização cancelada. Nada foi alterado.'
            return
        }
        if (Obter-InfoBackup) {
            Escrever-Log 'Apagando o backup da limpeza anterior...'
            Remover-PastaSegura $script:PastaBackup
        }
        Escrever-Log '----- OTIMIZANDO -----'
        foreach ($acao in $acoes) {
            Escrever-Log "$($acao.Nome)..."
            Escrever-Log "  -> $(Executar-Acao $acao)"
        }
        Escrever-Log 'Otimização concluída.'
        [void](Mostrar-Mensagem 'Otimização concluída. Veja os detalhes na janela.')
    } finally { Definir-Ocupado $false }
}

function Ao-Desfazer {
    $info = Obter-InfoBackup
    if (-not $info) { [void](Mostrar-Mensagem 'Não há limpeza para desfazer.'); return }
    $msg = 'Devolver {0:N0} arquivo(s) ({1}) para os locais de onde foram removidos?' -f $info.Arquivos, (Formatar-Tamanho $info.Bytes)
    $prefixos = @(Obter-PrefixosNavegadoresAbertos)
    if ($prefixos.Count -gt 0) { $msg += "`r`n`r`nO Chrome ou o Edge está aberto: o cache dele só será devolvido depois que o navegador for fechado." }
    if ((Mostrar-Mensagem $msg 'Desfazer última limpeza' 'YesNo' 'Question') -ne 'Yes') { return }

    Definir-Ocupado $true
    try {
        Escrever-Log '----- DESFAZENDO a última limpeza -----'
        $r = Restaurar-Backup -PastaBackup $script:PastaBackup -PularPrefixos $prefixos
        Escrever-Log ('{0:N0} arquivo(s) devolvidos.' -f $r.Restaurados)
        if ($r.Mantidos)   { Escrever-Log ('{0:N0} mantidos no backup porque o navegador está aberto. Feche-o e clique em Desfazer de novo.' -f $r.Mantidos) }
        if ($r.JaExistiam) { Escrever-Log ('{0:N0} mantidos no backup porque já existe um arquivo novo com o mesmo nome.' -f $r.JaExistiam) }
        if ($r.Falhas)     { Escrever-Log ('{0:N0} não puderam ser devolvidos (sem permissão).' -f $r.Falhas) }
    } finally { Definir-Ocupado $false }
}

function Ao-Esvaziar {
    $info = Obter-InfoBackup
    if (-not $info) { return }
    $msg = 'Apagar de vez o backup ({0:N0} arquivo(s), {1})?{2}{2}Isso libera o espaço, mas depois não dá mais para desfazer a última limpeza.' -f $info.Arquivos, (Formatar-Tamanho $info.Bytes), "`r`n"
    if ((Mostrar-Mensagem $msg 'Esvaziar backup' 'YesNo' 'Warning') -ne 'Yes') { return }
    Definir-Ocupado $true
    try {
        Remover-PastaSegura $script:PastaBackup
        Escrever-Log ('Backup apagado: {0} liberados.' -f (Formatar-Tamanho $info.Bytes))
    } finally { Definir-Ocupado $false }
}

function Ao-Diagnostico {
    Definir-Ocupado $true
    try {
        Escrever-Log 'Coletando diagnóstico...'
        foreach ($linha in (Obter-Diagnostico)) { $script:txtLog.AppendText($linha + "`r`n") }
    } finally { Definir-Ocupado $false }
}

function Ao-Inicializacao {
    try {
        Start-Process -FilePath 'taskmgr.exe' -ArgumentList '/0', '/startup'
        Escrever-Log 'Gerenciador de Tarefas aberto na aba Inicialização. Para desativar um programa: clique nele e em "Desabilitar". Para voltar atrás: "Habilitar".'
    } catch {
        Escrever-Log 'Não foi possível abrir o Gerenciador de Tarefas.'
    }
}

function Ao-Abrir {
    $info = Obter-InfoBackup
    if ($info -and $info.Data -lt (Get-Date).AddDays(-$script:DiasBackup)) {
        Remover-PastaSegura $script:PastaBackup
        Escrever-Log ("Backup com mais de $($script:DiasBackup) dias apagado automaticamente ({0} liberados)." -f (Formatar-Tamanho $info.Bytes))
    }
    Atualizar-StatusBackup
    if ($script:ArgsInicio -contains '/atualizado') { Escrever-Log "Atualizado para a versão $($script:Versao)." }
    Escrever-Log 'Pronto. Clique em "Analisar" para ver o que será feito ou em "Otimizar" para limpar.'
    Remover-PastaSegura $script:PastaDownload   # instalador baixado numa atualização anterior
    Iniciar-VerificacaoAtualizacao
}

function Novo-Botao {
    param([string]$Texto, [int]$X, [int]$Y, [int]$Largura, [string]$Ajuda)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Texto
    $b.Location = New-Object System.Drawing.Point($X, $Y)
    $b.Size = New-Object System.Drawing.Size($Largura, 34)
    $script:UI.Dica.SetToolTip($b, $Ajuda)
    $script:UI.Form.Controls.Add($b)
    $script:UI.Botoes += $b
    return $b
}

function Criar-Interface {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "$($script:NomeApp) $($script:Versao)"
    $form.ClientSize = New-Object System.Drawing.Size(740, 640)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedSingle'
    $form.MaximizeBox = $false
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $form.KeyPreview = $true
    $script:UI.Form = $form
    $script:UI.Dica = New-Object System.Windows.Forms.ToolTip
    $script:UI.Botoes = @()
    $script:UI.Caixas = @{}

    $titulo = New-Object System.Windows.Forms.Label
    $titulo.Text = 'Otimizador de PC'
    $titulo.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
    $titulo.Location = New-Object System.Drawing.Point(16, 10)
    $titulo.AutoSize = $true
    $form.Controls.Add($titulo)

    # Só aparece quando há uma versão nova no GitHub
    $btnAtualizar = New-Object System.Windows.Forms.Button
    $btnAtualizar.Location = New-Object System.Drawing.Point(474, 10)
    $btnAtualizar.Size = New-Object System.Drawing.Size(250, 34)
    $btnAtualizar.BackColor = [System.Drawing.Color]::FromArgb(46, 125, 50)
    $btnAtualizar.ForeColor = [System.Drawing.Color]::White
    $btnAtualizar.FlatStyle = 'Flat'
    $btnAtualizar.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $btnAtualizar.Visible = $false
    $btnAtualizar.Add_Click({ Ao-Atualizar })
    $form.Controls.Add($btnAtualizar)
    $script:UI.BtnAtualizar = $btnAtualizar

    $sub = New-Object System.Windows.Forms.Label
    $sub.Text = 'Marque o que deseja fazer. "Analisar" mostra antes o que será feito, sem alterar nada.'
    $sub.Location = New-Object System.Drawing.Point(18, 42)
    $sub.AutoSize = $true
    $form.Controls.Add($sub)

    $grupo = New-Object System.Windows.Forms.GroupBox
    $grupo.Text = 'Ações de limpeza'
    $grupo.Location = New-Object System.Drawing.Point(16, 66)
    $grupo.Size = New-Object System.Drawing.Size(708, 262)
    $form.Controls.Add($grupo)

    $y = 22
    foreach ($acao in $script:Acoes) {
        $cb = New-Object System.Windows.Forms.CheckBox
        $cb.Text = $acao.Titulo
        $cb.Checked = $true
        $cb.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
        $cb.Location = New-Object System.Drawing.Point(14, $y)
        $cb.AutoSize = $true
        $grupo.Controls.Add($cb)
        $script:UI.Caixas[$acao.Id] = $cb

        $desc = New-Object System.Windows.Forms.Label
        $desc.Text = $acao.Descricao
        $desc.ForeColor = [System.Drawing.Color]::DimGray
        $desc.Location = New-Object System.Drawing.Point(32, ($y + 21))
        $desc.AutoSize = $true
        $grupo.Controls.Add($desc)
        $y += 47
    }

    $btnAnalisar = Novo-Botao '&Analisar' 16 340 170 'Mostra o que será feito, sem alterar nada.'
    $btnOtimizar = Novo-Botao '&Otimizar' 194 340 170 'Mostra o resumo, pede confirmação e faz a limpeza.'
    $btnOtimizar.BackColor = [System.Drawing.Color]::FromArgb(220, 240, 220)
    $btnOtimizar.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $btnDiag     = Novo-Botao 'Dia&gnóstico' 372 340 170 'Mostra informações do PC e recomendações (somente leitura).'
    $btnInic     = Novo-Botao 'Programas de &inicialização' 550 340 174 'Abre o Gerenciador de Tarefas na aba Inicialização. Nada é desativado sozinho.'
    $script:UI.BtnDesfazer = Novo-Botao '&Desfazer última limpeza (Ctrl+Z)' 16 382 348 'Devolve os arquivos da última limpeza para onde estavam.'
    $script:UI.BtnEsvaziar = Novo-Botao '&Esvaziar backup' 372 382 352 'Apaga de vez o backup da última limpeza para liberar o espaço. Depois disso não dá para desfazer.'

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Location = New-Object System.Drawing.Point(18, 424)
    $lbl.Size = New-Object System.Drawing.Size(706, 20)
    $lbl.ForeColor = [System.Drawing.Color]::DarkSlateBlue
    $form.Controls.Add($lbl)
    $script:UI.LblBackup = $lbl

    $log = New-Object System.Windows.Forms.TextBox
    $log.Multiline = $true
    $log.ReadOnly = $true
    $log.ScrollBars = 'Vertical'
    $log.BackColor = [System.Drawing.Color]::White
    $log.Font = New-Object System.Drawing.Font('Consolas', 9)
    $log.Location = New-Object System.Drawing.Point(16, 448)
    $log.Size = New-Object System.Drawing.Size(708, 176)
    $form.Controls.Add($log)
    $script:txtLog = $log

    $btnAnalisar.Add_Click({ Ao-Analisar })
    $btnOtimizar.Add_Click({ Ao-Otimizar })
    $btnDiag.Add_Click({ Ao-Diagnostico })
    $btnInic.Add_Click({ Ao-Inicializacao })
    $script:UI.BtnDesfazer.Add_Click({ Ao-Desfazer })
    $script:UI.BtnEsvaziar.Add_Click({ Ao-Esvaziar })
    $form.Add_Shown({ Ao-Abrir })
    $form.Add_KeyDown({
        param($origem, $e)
        if ($e.Control -and $e.KeyCode -eq [System.Windows.Forms.Keys]::Z -and $script:UI.BtnDesfazer.Enabled) {
            $e.Handled = $true
            Ao-Desfazer
        }
    })

    return $form
}

# ------------------------------------------------------------------ Instalação
# O mesmo .exe faz três papéis:
#   - executado fora da pasta de instalação: mostra a tela de instalação
#   - executado da pasta de instalação (atalho do Menu Iniciar): abre o app
#   - com /desinstalar (chamado pelo Painel de Controle): desinstala

function Obter-ExeAtual {
    return [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
}

function Test-MesmoCaminho {
    param([string]$A, [string]$B)
    try {
        return [string]::Equals([System.IO.Path]::GetFullPath($A), [System.IO.Path]::GetFullPath($B), [System.StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}

function Obter-VersaoInstalada {
    $chave = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($script:ChaveDesinstalar)
    if (-not $chave) { return $null }
    try { return $chave.GetValue('DisplayVersion') } finally { $chave.Dispose() }
}

function Obter-AtalhoMenu    { return Join-Path ([Environment]::GetFolderPath('Programs')) "$($script:NomeApp).lnk" }
function Obter-AtalhoDesktop { return Join-Path ([Environment]::GetFolderPath('Desktop')) "$($script:NomeApp).lnk" }

function Criar-Atalho {
    param([string]$Caminho, [string]$Alvo)
    $shell = New-Object -ComObject WScript.Shell
    try {
        $lnk = $shell.CreateShortcut($Caminho)
        $lnk.TargetPath = $Alvo
        $lnk.WorkingDirectory = Split-Path -Parent $Alvo
        $lnk.IconLocation = "$Alvo,0"
        $lnk.Description = 'Limpeza segura de arquivos temporários e cache'
        $lnk.Save()
    } finally { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
}

function Remover-Atalho {
    # Só apaga o atalho se ele apontar para o app instalado.
    param([string]$Caminho)
    if (-not [System.IO.File]::Exists($Caminho)) { return }
    $shell = New-Object -ComObject WScript.Shell
    try {
        if (Test-MesmoCaminho $shell.CreateShortcut($Caminho).TargetPath $script:ExeInstalado) { [System.IO.File]::Delete($Caminho) }
    } finally { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
}

function Obter-InstanciasAbertas {
    # Outras janelas do app instalado abertas (impedem atualizar ou desinstalar).
    return @(Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Id -ne $PID -and $_.Path -and (Test-MesmoCaminho $_.Path $script:ExeInstalado) })
}

function Test-VersaoMaisNova {
    # $true se $Nova for maior que $Atual (ex.: 1.0.1 > 1.0.0).
    param([string]$Nova, [string]$Atual)
    try { return ([version]$Nova -gt [version]$Atual) } catch { return $true }
}

function Instalar-App {
    param([string]$Origem)

    [void][System.IO.Directory]::CreateDirectory($script:PastaInstalacao)
    [System.IO.File]::Copy($Origem, $script:ExeInstalado, $true)

    Criar-Atalho (Obter-AtalhoMenu) $script:ExeInstalado
    Criar-Atalho (Obter-AtalhoDesktop) $script:ExeInstalado

    # Entrada em "Programas e Recursos" (só do usuário atual)
    $dword = [Microsoft.Win32.RegistryValueKind]::DWord
    $chave = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($script:ChaveDesinstalar)
    try {
        $chave.SetValue('DisplayName', $script:NomeApp)
        $chave.SetValue('DisplayVersion', $script:Versao)
        $chave.SetValue('Publisher', $script:NomeApp)
        $chave.SetValue('DisplayIcon', "$($script:ExeInstalado),0")
        $chave.SetValue('InstallLocation', $script:PastaInstalacao)
        $chave.SetValue('InstallDate', (Get-Date).ToString('yyyyMMdd'))
        $chave.SetValue('UninstallString', "`"$($script:ExeInstalado)`" /desinstalar")
        $chave.SetValue('NoModify', 1, $dword)
        $chave.SetValue('NoRepair', 1, $dword)
        $chave.SetValue('EstimatedSize', [int][math]::Ceiling((Get-Item -LiteralPath $script:ExeInstalado).Length / 1KB), $dword)
    } finally { $chave.Dispose() }
}

function Agendar-RemocaoDoPrograma {
    # Um .exe em uso não consegue apagar a si mesmo: um PowerShell oculto espera
    # este processo fechar e então apaga o exe e a pasta (só se estiver vazia).
    $aspas = { param([string]$s) "'" + $s.Replace("'", "''") + "'" }
    $comando = "Wait-Process -Id $PID -ErrorAction SilentlyContinue; Start-Sleep -Seconds 1; " +
               "Remove-Item -LiteralPath $(& $aspas $script:ExeInstalado) -Force -ErrorAction SilentlyContinue; " +
               "try { [System.IO.Directory]::Delete($(& $aspas $script:PastaInstalacao), `$false) } catch { }"
    $psi = New-Object System.Diagnostics.ProcessStartInfo((Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'))
    $psi.Arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand ' + [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($comando))
    $psi.CreateNoWindow = $true
    $psi.UseShellExecute = $false
    [void][System.Diagnostics.Process]::Start($psi)
}

function Desinstalar-App {
    # Remove atalhos, a entrada do Painel de Controle, os dados (backup) e o programa.
    Remover-Atalho (Obter-AtalhoMenu)
    Remover-Atalho (Obter-AtalhoDesktop)
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($script:ChaveDesinstalar, $false)
    Remover-PastaSegura $script:PastaApp

    if (Test-MesmoCaminho (Obter-ExeAtual) $script:ExeInstalado) {
        Agendar-RemocaoDoPrograma
    } else {
        if ([System.IO.File]::Exists($script:ExeInstalado)) { [System.IO.File]::Delete($script:ExeInstalado) }
        try { [System.IO.Directory]::Delete($script:PastaInstalacao, $false) } catch { }
    }
}

function Ao-Desinstalar {
    if (-not (Obter-VersaoInstalada) -and -not [System.IO.File]::Exists($script:ExeInstalado)) {
        [void](Mostrar-Mensagem 'O Otimizador de PC não está instalado.')
        return
    }
    if ((Obter-InstanciasAbertas).Count -gt 0) {
        [void](Mostrar-Mensagem 'Feche o Otimizador de PC antes de desinstalar.' 'Desinstalar' 'OK' 'Warning')
        return
    }
    $msg = 'Desinstalar o Otimizador de PC deste computador?'
    $info = Obter-InfoBackup
    if ($info) {
        $msg += "`r`n`r`nO backup da última limpeza ({0}) também será apagado e ela não poderá mais ser desfeita. Se quiser recuperar algo, clique em Não, abra o Otimizador e use 'Desfazer' antes." -f (Formatar-Tamanho $info.Bytes)
    }
    if ((Mostrar-Mensagem $msg 'Desinstalar' 'YesNo' 'Question') -ne 'Yes') { return }
    try {
        Desinstalar-App
        [void](Mostrar-Mensagem 'Otimizador de PC desinstalado.' 'Desinstalar')
    } catch {
        [void](Mostrar-Mensagem "Não foi possível concluir a desinstalação: $($_.Exception.Message)" 'Desinstalar' 'OK' 'Error')
    }
}

function Ao-Instalar {
    if ((Obter-InstanciasAbertas).Count -gt 0) {
        [void](Mostrar-Mensagem 'Feche o Otimizador de PC que está aberto e tente de novo.' 'Instalar' 'OK' 'Warning')
        return
    }
    $feito = if (Obter-VersaoInstalada) { 'Atualizado' } else { 'Instalado' }
    try {
        Instalar-App -Origem (Obter-ExeAtual)
    } catch {
        [void](Mostrar-Mensagem "Não foi possível instalar: $($_.Exception.Message)" 'Instalar' 'OK' 'Error')
        return
    }
    $msg = "$feito com sucesso!`r`n`r`nAbra pelo ícone ""$($script:NomeApp)"" na Área de Trabalho ou no Menu Iniciar.`r`n`r`nAbrir agora?"
    if ((Mostrar-Mensagem $msg 'Instalar' 'YesNo' 'Information') -eq 'Yes') { Start-Process -FilePath $script:ExeInstalado }
    $script:UI.Form.Close()
}

function Mostrar-Instalador {
    # Retorna $true se a pessoa escolheu "Abrir sem instalar".
    $instalada = Obter-VersaoInstalada
    if (-not [System.IO.File]::Exists($script:ExeInstalado)) { $instalada = $null }   # instalação quebrada: deixa reinstalar
    $script:UI.AbrirSemInstalar = $false

    # Mesma versão (ou mais nova) já instalada: só avisa.
    if ($instalada -and -not (Test-VersaoMaisNova $script:Versao $instalada)) {
        $msg = "O $($script:NomeApp) já está instalado neste computador (versão $instalada).`r`n`r`n" +
               "Para abrir, use o ícone na Área de Trabalho ou no Menu Iniciar.`r`n`r`n" +
               "Para reinstalar, desinstale antes em Painel de Controle > Programas e Recursos."
        [void](Mostrar-Mensagem $msg 'Já instalado' 'OK' 'Error')
        return $false
    }
    $acao = if ($instalada) { 'Atualizar' } else { 'Instalar' }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "$acao $($script:NomeApp)"
    $form.ClientSize = New-Object System.Drawing.Size(520, 300)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $script:UI.Form = $form

    $titulo = New-Object System.Windows.Forms.Label
    $titulo.Text = "$acao $($script:NomeApp)"
    $titulo.Font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
    $titulo.Location = New-Object System.Drawing.Point(16, 12)
    $titulo.AutoSize = $true
    $form.Controls.Add($titulo)

    if ($instalada) {
        $texto = "Versão instalada: $instalada`r`nNova versão: $($script:Versao)`r`n`r`n" +
                 "O backup da última limpeza e os atalhos são mantidos."
    } else {
        $texto = "Versão $($script:Versao)`r`n`r`nSerá instalado em:`r`n$($script:PastaInstalacao)`r`n`r`n" +
                 "- Só para este usuário, não precisa de administrador.`r`n" +
                 "- Cria um ícone na Área de Trabalho e no Menu Iniciar.`r`n" +
                 "- Para remover: Painel de Controle > Programas e Recursos > $($script:NomeApp) > Desinstalar."
    }
    $info = New-Object System.Windows.Forms.Label
    $info.Text = $texto
    $info.Location = New-Object System.Drawing.Point(18, 48)
    $info.Size = New-Object System.Drawing.Size(486, 180)
    $form.Controls.Add($info)

    $botoes = @(
        @{ Texto = "&$acao"; X = 16; L = 120; Acao = { Ao-Instalar } }
        @{ Texto = 'Abrir &sem instalar'; X = 144; L = 140; Acao = { $script:UI.AbrirSemInstalar = $true; $script:UI.Form.Close() } }
        @{ Texto = '&Fechar'; X = 410; L = 94; Acao = { $script:UI.Form.Close() } }
    )
    foreach ($def in $botoes) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $def.Texto
        $b.Location = New-Object System.Drawing.Point($def.X, 250)
        $b.Size = New-Object System.Drawing.Size($def.L, 34)
        $b.Add_Click($def.Acao)
        $form.Controls.Add($b)
    }
    $form.AcceptButton = $form.Controls | Where-Object { $_ -is [System.Windows.Forms.Button] } | Select-Object -First 1

    [void]$form.ShowDialog()
    $form.Dispose()
    $script:UI.Form = $null
    return $script:UI.AbrirSemInstalar
}

# ------------------------------------------------------------------ Atualização
# 1. Ao abrir, o app baixa em segundo plano o versao.json da Release mais recente.
# 2. Se a versão for maior, aparece o botão "Atualizar para a versão X".
# 3. No clique: baixa o instalador da Release, confere o SHA-256 e roda com /atualizar.
# 4. O instalador espera o app fechar, instala por cima e abre o app de novo.
# Sem internet ou com o GitHub bloqueado, nada aparece e o app funciona normalmente.

$script:PastaDownload = Join-Path $script:PastaApp 'Atualizacao'

# Roda em outra thread, então não pode usar as funções do script.
$script:ScriptVerificacao = {
    param([string]$Url)
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $wc = New-Object System.Net.WebClient
        $wc.Headers['User-Agent'] = 'OtimizadorPC'
        $wc.Encoding = [System.Text.Encoding]::UTF8
        if ($wc.Proxy) { $wc.Proxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials }
        return ($wc.DownloadString($Url) | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Novo-ClienteWeb {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $wc = New-Object System.Net.WebClient
    $wc.Headers['User-Agent'] = 'OtimizadorPC'
    if ($wc.Proxy) { $wc.Proxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials }
    return $wc
}

function Iniciar-VerificacaoAtualizacao {
    # Só o app instalado se atualiza ("Abrir sem instalar" não).
    if (-not (Test-MesmoCaminho (Obter-ExeAtual) $script:ExeInstalado)) { return }

    $ps = [powershell]::Create()
    [void]$ps.AddScript($script:ScriptVerificacao).AddArgument("$($script:UrlReleases)/latest/download/versao.json")
    $script:Verificacao = @{ PS = $ps; Handle = $ps.BeginInvoke() }

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 500
    $timer.Add_Tick({ Ao-VerificacaoConcluida })
    $script:UI.TimerAtualizacao = $timer
    $timer.Start()
}

function Ao-VerificacaoConcluida {
    $v = $script:Verificacao
    if (-not $v.Handle.IsCompleted) { return }
    $script:UI.TimerAtualizacao.Stop()
    try { $info = $v.PS.EndInvoke($v.Handle) | Select-Object -First 1 } catch { $info = $null } finally { $v.PS.Dispose() }

    if (-not $info) { return }
    $versao = [string]$info.versao
    if ($versao -notmatch '^\d+(\.\d+){1,3}$' -or [string]$info.sha256 -notmatch '^[0-9a-fA-F]{64}$') { return }
    if (-not (Test-VersaoMaisNova $versao $script:Versao)) { return }

    $script:Atualizacao = $info
    $script:UI.BtnAtualizar.Text = "Atualizar para a versão $versao"
    $script:UI.BtnAtualizar.Visible = $true
    Escrever-Log "Nova versão disponível: $versao. Clique no botão verde ""Atualizar"" no alto da janela."
}

function Ao-Atualizar {
    $info = $script:Atualizacao
    if (-not $info) { return }
    $msg = "Há uma versão nova do $($script:NomeApp): $($info.versao) (você está na $($script:Versao))."
    if ($info.notas) { $msg += "`r`n`r`nNovidades:`r`n$($info.notas)" }
    $msg += "`r`n`r`nBaixar e atualizar agora? O Otimizador vai fechar e abrir de novo sozinho."
    if ((Mostrar-Mensagem $msg 'Atualizar' 'YesNo' 'Question') -ne 'Yes') { return }

    Definir-Ocupado $true
    try {
        Escrever-Log "Baixando a versão $($info.versao)..."
        [void][System.IO.Directory]::CreateDirectory($script:PastaDownload)
        $arquivo = Join-Path $script:PastaDownload "Instalar-Otimizador-$($info.versao).exe"
        (Novo-ClienteWeb).DownloadFile("$($script:UrlReleases)/download/v$($info.versao)/Instalar-Otimizador.exe", $arquivo)

        # Confere se o arquivo baixado é exatamente o publicado
        $hash = (Get-FileHash -LiteralPath $arquivo -Algorithm SHA256).Hash
        if ($hash -ne ([string]$info.sha256).ToUpperInvariant()) {
            Remover-PastaSegura $script:PastaDownload
            throw 'o arquivo baixado não confere com o publicado (SHA-256 diferente). Por segurança, nada foi instalado.'
        }

        Escrever-Log 'Download conferido. Atualizando...'
        Start-Process -FilePath $arquivo -ArgumentList '/atualizar'
        $script:UI.Form.Close()
    } catch {
        Escrever-Log "Não foi possível atualizar: $($_.Exception.Message)"
        [void](Mostrar-Mensagem "Não foi possível atualizar agora:`r`n$($_.Exception.Message)`r`n`r`nO app continua funcionando na versão $($script:Versao)." 'Atualizar' 'OK' 'Warning')
        Definir-Ocupado $false
    }
}

function Executar-AtualizacaoSilenciosa {
    # Chamado com /atualizar pelo app, que acabou de baixar este instalador.
    $limite = (Get-Date).AddSeconds(30)
    while ((Obter-InstanciasAbertas).Count -gt 0 -and (Get-Date) -lt $limite) { Start-Sleep -Milliseconds 300 }

    $instalada = Obter-VersaoInstalada
    if (-not $instalada -or (Test-VersaoMaisNova $script:Versao $instalada)) {
        try {
            Instalar-App -Origem (Obter-ExeAtual)
        } catch {
            [void](Mostrar-Mensagem "Não foi possível atualizar: $($_.Exception.Message)" 'Atualizar' 'OK' 'Error')
            return
        }
    }
    Start-Process -FilePath $script:ExeInstalado -ArgumentList '/atualizado'
}

# ------------------------------------------------------------------ Início

[System.Windows.Forms.Application]::EnableVisualStyles()
$script:ArgsInicio = $args

if ($args -contains '/desinstalar') {
    Ao-Desinstalar
    return
}
if ($args -contains '/atualizar') {
    Executar-AtualizacaoSilenciosa
    return
}

# Rodando como .ps1 (powershell.exe) ou da pasta de instalação: abre o app direto.
$exeAtual = Obter-ExeAtual
$abrirApp = ([System.IO.Path]::GetFileName($exeAtual) -match '^(powershell|powershell_ise|pwsh)\.exe$') -or
            (Test-MesmoCaminho $exeAtual $script:ExeInstalado)
if (-not $abrirApp) { $abrirApp = Mostrar-Instalador }

if ($abrirApp) {
    $janela = Criar-Interface
    [void]$janela.ShowDialog()
    $janela.Dispose()
}

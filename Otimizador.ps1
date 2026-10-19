#requires -Version 5.1
<#
    Otimizador de PC
    ----------------
    Faz SOMENTE ações seguras, sem exigir administrador:
      1. Limpa %TEMP% (arquivos com mais de 1 dia)
      2. Limpa C:\Windows\Temp (mesma regra; o que não tiver permissão é pulado)
      3. Limpa o cache do Chrome e do Edge (Cache, Code Cache e GPUCache dos perfis
         Default e "Profile *"), pulando o navegador se ele estiver aberto
      4. ipconfig /flushdns
      5. Diagnóstico, nota de saúde e status do sistema (somente leitura)
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

    Interface: WPF (o layout está em XAML na seção "Interface"). Tarefas demoradas
    rodam em segundo plano (Iniciar-EmSegundoPlano) para a janela não travar.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# ------------------------------------------------------------------ Configuração

$script:NomeApp          = 'Otimizador de PC'
$script:Versao           = '1.1.0'
$script:NotasVersao     = ''   # preenchido pelo Gerar-EXE.ps1 com a seção desta versão do NOVIDADES.md
$script:PastaInstalacao  = Join-Path $env:LOCALAPPDATA 'Programs\OtimizadorPC'
$script:ExeInstalado     = Join-Path $script:PastaInstalacao 'Otimizador.exe'
$script:ChaveDesinstalar = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\OtimizadorPC'

# Atualização automática: cada Release no GitHub tem o Instalar-Otimizador.exe e um versao.json
# (gerados pelo Gerar-EXE.ps1). O app lê o versao.json da Release mais recente.
$script:RepoGitHub       = 'franmason/otimizarcomputador'
$script:UrlReleases      = "https://github.com/$($script:RepoGitHub)/releases"

$script:PastaApp      = Join-Path $env:LOCALAPPDATA 'OtimizadorPC'
$script:PastaBackup   = Join-Path $script:PastaApp 'Backup'
$script:PastaDownload = Join-Path $script:PastaApp 'Atualizacao'
$script:ArquivoHistorico = Join-Path $script:PastaApp 'historico.json'
$script:ArquivoConfig    = Join-Path $script:PastaApp 'config.json'
$script:DiasBackup    = 7
$script:PastasCache   = @('Cache', 'Code Cache', 'GPUCache')
$script:FolhasAceitas = @('Temp', 'Tmp', 'Cache', 'Code Cache', 'GPUCache')

# Fila de mensagens do registro: pode receber linhas de qualquer thread;
# a janela mostra o que chegar (ver Processar-Tarefas).
$script:FilaLog = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))

# ------------------------------------------------------------------ Utilitários

function Formatar-Tamanho {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N1} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    return '{0:N0} KB' -f ($Bytes / 1KB)
}

function Escrever-Log {
    param([string]$Texto)
    if ($script:FilaLog) { [void]$script:FilaLog.Add(('[{0:HH:mm:ss}] {1}' -f (Get-Date), $Texto)) }
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

function Formatar-Quando {
    param([datetime]$Data)
    if ($Data.Date -eq (Get-Date).Date) { return 'Hoje, {0:HH:mm}' -f $Data }
    if ($Data.Date -eq (Get-Date).Date.AddDays(-1)) { return 'Ontem, {0:HH:mm}' -f $Data }
    return '{0:dd/MM/yyyy HH:mm}' -f $Data
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
# Só dados (nada de scriptblocks), para poderem ser usados nas tarefas em segundo plano.

$script:Acoes = @(
    [pscustomobject]@{
        Id = 'TempUsuario'; Tipo = 'Pasta'; Nome = 'Temporários do usuário'; Icone = [char]0xE74D; Cor = '#2563EB'
        Titulo = 'Limpar arquivos temporários do usuário (%TEMP%)'
        Descricao = 'Só arquivos com mais de 1 dia. Arquivos em uso são pulados.'
        Dias = 1; Processo = $null; Caminho = $env:TEMP; DadosUsuario = $null
    }
    [pscustomobject]@{
        Id = 'TempWindows'; Tipo = 'Pasta'; Nome = 'Temporários do Windows'; Icone = [char]0xE8B7; Cor = '#7C3AED'
        Titulo = 'Limpar temporários do Windows (C:\Windows\Temp)'
        Descricao = 'Só arquivos com mais de 1 dia. O que não tiver permissão é pulado.'
        Dias = 1; Processo = $null; Caminho = (Join-Path $env:windir 'Temp'); DadosUsuario = $null
    }
    [pscustomobject]@{
        Id = 'Chrome'; Tipo = 'Pasta'; Nome = 'Google Chrome'; Icone = [char]0xE774; Cor = '#EA4335'
        Titulo = 'Limpar cache do Google Chrome'
        Descricao = 'Só arquivos guardados de sites. Histórico, senhas, cookies e favoritos não são tocados. Pulado se estiver aberto.'
        Dias = 0; Processo = 'chrome'; Caminho = $null; DadosUsuario = (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data')
    }
    [pscustomobject]@{
        Id = 'Edge'; Tipo = 'Pasta'; Nome = 'Microsoft Edge'; Icone = [char]0xE909; Cor = '#0EA5E9'
        Titulo = 'Limpar cache do Microsoft Edge'
        Descricao = 'Mesma regra do Chrome. Pulado se o Edge estiver aberto.'
        Dias = 0; Processo = 'msedge'; Caminho = $null; DadosUsuario = (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data')
    }
    [pscustomobject]@{
        Id = 'DNS'; Tipo = 'DNS'; Nome = 'Cache de DNS'; Icone = [char]0xE839; Cor = '#0F766E'
        Titulo = 'Limpar cache de DNS (ipconfig /flushdns)'
        Descricao = 'Ajuda quando um site não abre. O Windows recria o cache sozinho, não precisa desfazer.'
        Dias = 0; Processo = $null; Caminho = $null; DadosUsuario = $null
    }
)

function Obter-PastasDaAcao {
    param($Acao)
    $pastas = @()
    if ($Acao.Caminho) { $pastas += $Acao.Caminho }
    if ($Acao.DadosUsuario) { $pastas += Obter-PastasCache $Acao.DadosUsuario }
    return @($pastas | Where-Object { Test-PastaPermitida $_ })
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
    $res = [pscustomobject]@{ Acao = $Acao; Texto = ''; Arquivos = 0; Bytes = [long]0; Pulados = 0 }
    if ($Acao.Tipo -eq 'DNS') {
        $res.Texto = if (Limpar-DNS) { 'cache de DNS limpo.' } else { 'não foi possível limpar o cache de DNS.' }
        return $res
    }
    if ($Acao.Processo -and (Test-ProcessoAberto $Acao.Processo)) {
        $res.Texto = "pulado: o $($Acao.Nome) está aberto."
        return $res
    }
    foreach ($p in (Obter-PastasDaAcao $Acao)) {
        $r = Limpar-Pasta -Caminho $p -DiasMinimos $Acao.Dias -PastaBackup $script:PastaBackup
        $res.Arquivos += $r.Movidos; $res.Bytes += $r.Bytes; $res.Pulados += $r.Pulados
    }
    $res.Texto = '{0:N0} arquivo(s) limpos ({1})' -f $res.Arquivos, (Formatar-Tamanho $res.Bytes)
    if ($res.Pulados -gt 0) { $res.Texto += ', {0:N0} pulados (em uso ou sem permissão)' -f $res.Pulados }
    $res.Texto += '.'
    return $res
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

# ------------------------------------------------------------------ Diagnóstico e status (somente leitura)

function Calcular-NotaSaude {
    # Nota de 0 a 100: começa em 100 e perde pontos por cada problema encontrado.
    param($Diag)
    $nota = 100
    if ($Diag.RamUsoPct -ge 90) { $nota -= 25 } elseif ($Diag.RamUsoPct -ge 80) { $nota -= 15 } elseif ($Diag.RamUsoPct -ge 70) { $nota -= 5 }
    if ($Diag.RamTotalGB -gt 0 -and $Diag.RamTotalGB -le 4.5) { $nota -= 20 } elseif ($Diag.RamTotalGB -gt 0 -and $Diag.RamTotalGB -le 8.5) { $nota -= 10 }
    if ($Diag.TemHDD) { $nota -= 20 }
    if ($Diag.CLivrePct -ge 0) {
        if ($Diag.CLivrePct -lt 8) { $nota -= 25 } elseif ($Diag.CLivrePct -lt 15) { $nota -= 15 } elseif ($Diag.CLivrePct -lt 25) { $nota -= 5 }
    }
    return [math]::Max(0, [math]::Min(100, $nota))
}

function Obter-Diagnostico {
    $d = [pscustomobject]@{
        Modelo = ''; Processador = ''; RamTotalGB = 0; RamUsoPct = 0; TemHDD = $false; CLivrePct = -1
        Linhas = (New-Object 'System.Collections.Generic.List[string]')
        Dicas  = (New-Object 'System.Collections.Generic.List[string]')
        Nota = 0
    }
    $l = $d.Linhas
    $cs = $null; $csp = $null; $os = $null; $cpu = $null
    try { $cs  = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop } catch { }
    try { $csp = Get-CimInstance Win32_ComputerSystemProduct -ErrorAction Stop } catch { }
    try { $os  = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } catch { }
    try { $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1 } catch { }

    if ($cs) {
        $d.Modelo = "$($cs.Manufacturer) $($cs.Model)"
        if ($csp -and $csp.Version -and $cs.Manufacturer -match 'Lenovo') { $d.Modelo = "$($cs.Manufacturer) $($csp.Version) ($($cs.Model))" }
        $l.Add("Modelo:       $($d.Modelo)")
    }
    if ($cpu) { $d.Processador = $cpu.Name.Trim(); $l.Add("Processador:  $($d.Processador)") }

    if ($os) {
        $d.RamTotalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
        $d.RamUsoPct = [math]::Round(100 * (1 - $os.FreePhysicalMemory / $os.TotalVisibleMemorySize))
        $l.Add(('Memória RAM:  {0:N1} GB, em uso: {1}%' -f $d.RamTotalGB, $d.RamUsoPct))
        if ($d.RamUsoPct -ge 80) { $d.Dicas.Add("Uso de memória alto ($($d.RamUsoPct)%). Feche abas e programas que não estiver usando.") }
    }

    try {
        $pentes = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop)
        $slots = (@(Get-CimInstance Win32_PhysicalMemoryArray -ErrorAction Stop) | Measure-Object -Property MemoryDevices -Sum).Sum
        foreach ($p in $pentes) {
            $vel = if ($p.ConfiguredClockSpeed) { $p.ConfiguredClockSpeed } else { $p.Speed }
            $linhaPente = '  Pente {0}: {1:N0} GB' -f $p.DeviceLocator, ($p.Capacity / 1GB)
            if ($vel) { $linhaPente += ", $vel MHz" }
            $l.Add($linhaPente)
        }
        if ($slots) {
            $livres = [math]::Max(0, $slots - $pentes.Count)
            $l.Add("  Slots: $slots no total, $livres livre(s)")
            if ($d.RamTotalGB -gt 0 -and $d.RamTotalGB -le 8.5) {
                if ($livres -gt 0) { $d.Dicas.Add("Há $livres slot(s) de memória livre(s): adicionar um pente (ex.: +8 GB) deixaria o PC bem mais folgado.") }
                else { $d.Dicas.Add('Não há slot de memória livre: para ter mais RAM seria preciso trocar um pente por outro maior.') }
            }
        }
    } catch { $l.Add('  Pentes de memória: não foi possível ler.') }

    try {
        foreach ($disco in @(Get-PhysicalDisk -ErrorAction Stop)) {
            $tipo = [string]$disco.MediaType
            if ($tipo -notin @('SSD', 'HDD')) { $tipo = if ($disco.SpindleSpeed -eq 0) { 'SSD (provável)' } else { 'desconhecido' } }
            $l.Add(('Disco:        {0} - {1}, {2}' -f $disco.FriendlyName, $tipo, (Formatar-Tamanho $disco.Size)))
            if ($tipo -eq 'HDD') {
                $d.TemHDD = $true
                $d.Dicas.Add("O disco '$($disco.FriendlyName)' é HDD. Trocar por SSD é a melhoria que mais acelera o PC.")
            }
        }
    } catch { $l.Add('Disco:        não foi possível identificar o tipo.') }

    try {
        $c = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
        $d.CLivrePct = [math]::Round(100 * $c.FreeSpace / $c.Size)
        $l.Add(('Espaço no C:  {0} livres de {1} ({2}%)' -f (Formatar-Tamanho $c.FreeSpace), (Formatar-Tamanho $c.Size), $d.CLivrePct))
        if ($d.CLivrePct -lt 15 -or $c.FreeSpace -lt 20GB) { $d.Dicas.Add('Pouco espaço livre no C:. Remova programas e arquivos grandes que não usa (o Otimizador não apaga arquivos pessoais).') }
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
    if ($chrome -and $chrome.Bytes -gt 1.5GB) { $d.Dicas.Add('O Chrome está usando muita memória. Feche abas que não estiver usando.') }

    $d.Nota = Calcular-NotaSaude $d
    if ($d.Dicas.Count -eq 0) { $d.Dicas.Add('Nenhum problema encontrado. Continue fazendo a limpeza de vez em quando.') }
    return $d
}

function Obter-StatusSistema {
    $s = [pscustomobject]@{ Cpu = -1; Memoria = -1; DiscoLivre = -1; Rede = $false }
    try { $s.Cpu = [int](Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop).PercentProcessorTime } catch { }
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $s.Memoria = [int][math]::Round(100 * (1 - $os.FreePhysicalMemory / $os.TotalVisibleMemorySize))
    } catch { }
    try {
        $c = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
        $s.DiscoLivre = [int][math]::Round(100 * $c.FreeSpace / $c.Size)
    } catch { }
    try { $s.Rede = [System.Net.NetworkInformation.NetworkInterface]::GetIsNetworkAvailable() } catch { }
    return $s
}

# ------------------------------------------------------------------ Histórico e configurações

function Ler-Json {
    param([string]$Caminho)
    if (-not [System.IO.File]::Exists($Caminho)) { return $null }
    try { return ([System.IO.File]::ReadAllText($Caminho, [System.Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { return $null }
}

function Salvar-Json {
    param([string]$Caminho, $Objeto)
    [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($Caminho))
    [System.IO.File]::WriteAllText($Caminho, (ConvertTo-Json -InputObject $Objeto -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
}

function Ler-Historico {
    $h = Ler-Json $script:ArquivoHistorico
    if (-not $h) { return @() }
    return @($h)
}

function Adicionar-Historico {
    param([string]$Tipo, [string]$Descricao, [int]$Arquivos = 0, [long]$Bytes = 0)
    $lista = New-Object System.Collections.ArrayList
    foreach ($item in (Ler-Historico)) { [void]$lista.Add($item) }
    [void]$lista.Insert(0, [pscustomobject]@{ Data = (Get-Date).ToString('o'); Tipo = $Tipo; Descricao = $Descricao; Arquivos = $Arquivos; Bytes = $Bytes })
    while ($lista.Count -gt 100) { $lista.RemoveAt($lista.Count - 1) }
    Salvar-Json $script:ArquivoHistorico @($lista)
}

function Ler-Config {
    $c = Ler-Json $script:ArquivoConfig
    $config = [pscustomobject]@{ AcoesPadrao = @($script:Acoes | ForEach-Object { $_.Id }); VerificarAtualizacoes = $true }
    if ($c) {
        if ($null -ne $c.AcoesPadrao) { $config.AcoesPadrao = @($c.AcoesPadrao) }
        if ($null -ne $c.VerificarAtualizacoes) { $config.VerificarAtualizacoes = [bool]$c.VerificarAtualizacoes }
    }
    return $config
}

function Salvar-Config {
    param($Config)
    Salvar-Json $script:ArquivoConfig $Config
}

# ------------------------------------------------------------------ Tarefas em segundo plano
# Cada tarefa roda num runspace separado, com cópias das funções e variáveis de que
# precisa. Um timer da janela confere as tarefas prontas e chama o AoConcluir na
# thread da janela, que é a única que pode mexer na interface.

$script:Tarefas = New-Object System.Collections.ArrayList
$script:FuncoesSegundoPlano = @(
    'Formatar-Tamanho', 'Escrever-Log', 'Test-PontoDeReanalise', 'Test-ProcessoAberto', 'Test-PastaPermitida',
    'Obter-ArquivosElegiveis', 'Limpar-Pasta', 'Remover-PastaSegura', 'Restaurar-Backup', 'Obter-InfoBackup',
    'Obter-PastasCache', 'Limpar-DNS', 'Obter-PastasDaAcao', 'Analisar-Acao', 'Executar-Acao',
    'Calcular-NotaSaude', 'Obter-Diagnostico', 'Obter-StatusSistema'
)
$script:VariaveisSegundoPlano = @('Acoes', 'PastaApp', 'PastaBackup', 'PastasCache', 'FolhasAceitas', 'FilaLog')

function Obter-PoolSegundoPlano {
    # Um pool de runspaces criado uma vez e reaproveitado (o status roda a cada 3 s).
    if ($script:Pool) { return $script:Pool }
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    foreach ($nome in $script:FuncoesSegundoPlano) {
        $definicao = (Get-Item "function:$nome").ScriptBlock.ToString()
        $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry($nome, $definicao)))
    }
    foreach ($nome in $script:VariaveisSegundoPlano) {
        $valor = (Get-Variable -Scope Script -Name $nome).Value
        $iss.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry($nome, $valor, '')))
    }
    $script:Pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, 3, $iss, $Host)
    $script:Pool.Open()
    return $script:Pool
}

function Iniciar-EmSegundoPlano {
    param([scriptblock]$Trabalho, [hashtable]$Parametros = @{}, [scriptblock]$AoConcluir)
    $ps = [powershell]::Create()
    $ps.RunspacePool = Obter-PoolSegundoPlano
    [void]$ps.AddScript($Trabalho.ToString())
    foreach ($chave in $Parametros.Keys) { [void]$ps.AddParameter($chave, $Parametros[$chave]) }
    [void]$script:Tarefas.Add(@{ PS = $ps; Handle = $ps.BeginInvoke(); AoConcluir = $AoConcluir })
}

function Processar-Tarefas {
    for ($i = $script:Tarefas.Count - 1; $i -ge 0; $i--) {
        $t = $script:Tarefas[$i]
        if (-not $t.Handle.IsCompleted) { continue }
        $script:Tarefas.RemoveAt($i)
        $resultado = $null; $erro = $null
        try { $resultado = $t.PS.EndInvoke($t.Handle) } catch { $erro = $_.Exception.Message }
        # Erro do fluxo só conta quando a tarefa não devolveu nada (avisos isolados não descartam o resultado)
        if (-not $erro -and -not $resultado -and $t.PS.Streams.Error.Count -gt 0) { $erro = [string]$t.PS.Streams.Error[0] }
        $t.PS.Dispose()
        if ($t.AoConcluir) {
            try { & $t.AoConcluir $resultado $erro } catch { Escrever-Log "Erro interno: $($_.Exception.Message)" }
        }
    }

    if ($script:FilaLog.Count -gt 0 -and $script:UI.TxtLog) {
        [System.Threading.Monitor]::Enter($script:FilaLog.SyncRoot)
        try { $linhas = $script:FilaLog.ToArray(); $script:FilaLog.Clear() } finally { [System.Threading.Monitor]::Exit($script:FilaLog.SyncRoot) }
        $script:UI.TxtLog.AppendText(($linhas -join "`r`n") + "`r`n")
        $script:UI.TxtLog.ScrollToEnd()
    }
}

# ------------------------------------------------------------------ Interface (WPF)

$script:UI = @{}

$script:Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Otimizador de PC" Width="1060" Height="700" WindowStartupLocation="CenterScreen"
        WindowStyle="None" ResizeMode="CanMinimize" Background="#0A101C" Foreground="#E6EDF7"
        FontFamily="Segoe UI" FontSize="13" UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <SolidColorBrush x:Key="Cartao" Color="#111A2B"/>
    <SolidColorBrush x:Key="Borda" Color="#1C2840"/>
    <SolidColorBrush x:Key="Suave" Color="#8A97AD"/>

    <Style x:Key="EstiloCartao" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource Cartao}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Borda}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="16"/>
    </Style>

    <Style x:Key="Icone" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>

    <Style x:Key="Titulo" TargetType="TextBlock">
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>

    <Style x:Key="TextoSuave" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Suave}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>

    <Style x:Key="Botao" TargetType="Button">
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Background" Value="#1B2740"/>
      <Setter Property="BorderBrush" Value="#2A3A5C"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="14,8"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Fundo" CornerRadius="10" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Fundo" Property="Opacity" Value="0.88"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="Fundo" Property="Opacity" Value="0.75"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Fundo" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="BotaoPrincipal" TargetType="Button" BasedOn="{StaticResource Botao}">
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Height" Value="48"/>
      <Setter Property="Background">
        <Setter.Value>
          <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
            <GradientStop Color="#22C55E" Offset="0"/>
            <GradientStop Color="#16A34A" Offset="1"/>
          </LinearGradientBrush>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="BotaoContorno" TargetType="Button" BasedOn="{StaticResource Botao}">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="#2F4166"/>
      <Setter Property="Height" Value="42"/>
    </Style>

    <Style x:Key="BotaoJanela" TargetType="Button" BasedOn="{StaticResource Botao}">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Width" Value="40"/>
      <Setter Property="Height" Value="32"/>
      <Setter Property="Padding" Value="0"/>
      <Setter Property="Foreground" Value="#A9B4C7"/>
    </Style>

    <Style x:Key="Menu" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#A9B4C7"/>
      <Setter Property="Margin" Value="0,2"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="GroupName" Value="Menu"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="Fundo" CornerRadius="8" Background="Transparent" Padding="12,10">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="{TemplateBinding Tag}" FontFamily="Segoe MDL2 Assets" FontSize="16" Width="30" VerticalAlignment="Center"/>
                <ContentPresenter VerticalAlignment="Center"/>
              </StackPanel>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Fundo" Property="Background" Value="#141F35"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Fundo" Property="Background" Value="#1B2C4D"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Interruptor" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Border x:Name="Trilho" Width="44" Height="24" CornerRadius="12" Background="#2A3650">
              <Ellipse x:Name="Bola" Width="18" Height="18" Fill="White" HorizontalAlignment="Left" Margin="3,0"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Trilho" Property="Background" Value="#22C55E"/>
                <Setter TargetName="Bola" Property="HorizontalAlignment" Value="Right"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Trilho" Property="Opacity" Value="0.5"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Barras de rolagem finas e escuras (as padrão do Windows ficam brancas) -->
    <ControlTemplate x:Key="PolegarRolagem" TargetType="Thumb">
      <Border CornerRadius="4" Background="#2A3A5C"/>
    </ControlTemplate>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/>
      <Setter Property="MinWidth" Value="8"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" Orientation="Vertical" IsDirectionReversed="True">
              <Track.Thumb><Thumb Template="{StaticResource PolegarRolagem}"/></Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/>
          <Setter Property="MinWidth" Value="0"/>
          <Setter Property="Height" Value="8"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="ScrollBar">
                <Track x:Name="PART_Track" Orientation="Horizontal">
                  <Track.Thumb><Thumb Template="{StaticResource PolegarRolagem}"/></Track.Thumb>
                </Track>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style x:Key="Registro" TargetType="TextBox">
      <Setter Property="Background" Value="#0B1322"/>
      <Setter Property="Foreground" Value="#C9D4E5"/>
      <Setter Property="BorderBrush" Value="{StaticResource Borda}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="FontFamily" Value="Consolas"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Padding" Value="8"/>
      <Setter Property="IsReadOnly" Value="True"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="VerticalScrollBarVisibility" Value="Auto"/>
    </Style>
  </Window.Resources>

  <Border BorderBrush="#1C2840" BorderThickness="1">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="48"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>

      <!-- Barra de título -->
      <Grid x:Name="BarraTitulo" Grid.Row="0" Background="#0A101C">
        <StackPanel Orientation="Horizontal" Margin="18,0,0,0" VerticalAlignment="Center">
          <Border Width="28" Height="28" CornerRadius="8">
            <Border.Background>
              <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                <GradientStop Color="#3B82F6" Offset="0"/>
                <GradientStop Color="#22C55E" Offset="1"/>
              </LinearGradientBrush>
            </Border.Background>
            <TextBlock Text="&#xEC4A;" Style="{StaticResource Icone}" FontSize="15" Foreground="White" HorizontalAlignment="Center"/>
          </Border>
          <TextBlock Text="Otimizador de PC" FontSize="15" FontWeight="SemiBold" Margin="10,0,8,0" VerticalAlignment="Center"/>
          <TextBlock x:Name="TxtVersao" Foreground="{StaticResource Suave}" FontSize="11" VerticalAlignment="Center"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,8,0">
          <Button x:Name="BtnAtualizar" Style="{StaticResource BotaoPrincipal}" Height="32" FontSize="12" Padding="14,0"
                  Margin="0,0,12,0" Visibility="Collapsed">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="&#xE896;" Style="{StaticResource Icone}" Margin="0,0,8,0"/>
              <TextBlock x:Name="TxtBtnAtualizar" Text="Atualizar"/>
            </StackPanel>
          </Button>
          <Button x:Name="BtnMinimizar" Style="{StaticResource BotaoJanela}"><TextBlock Text="&#xE921;" Style="{StaticResource Icone}" FontSize="10"/></Button>
          <Button x:Name="BtnFechar" Style="{StaticResource BotaoJanela}"><TextBlock Text="&#xE8BB;" Style="{StaticResource Icone}" FontSize="10"/></Button>
        </StackPanel>
      </Grid>

      <Grid Grid.Row="1">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="214"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <!-- Menu lateral -->
        <Border Grid.Column="0" Background="#0D1524" BorderBrush="#1C2840" BorderThickness="0,1,1,0">
          <DockPanel Margin="12,14,12,14">
            <Border DockPanel.Dock="Bottom" Style="{StaticResource EstiloCartao}" Padding="14">
              <StackPanel>
                <StackPanel Orientation="Horizontal">
                  <Ellipse x:Name="PontoSaude" Width="9" Height="9" Fill="#22C55E" VerticalAlignment="Center"/>
                  <TextBlock x:Name="TxtSaudeLateral" Text="Analisando o PC..." FontSize="12" FontWeight="SemiBold" Margin="8,0,0,0"/>
                </StackPanel>
                <TextBlock Style="{StaticResource TextoSuave}" FontSize="11" Margin="0,6,0,0"
                           Text="Faça a limpeza de vez em quando para manter o PC leve."/>
              </StackPanel>
            </Border>
            <StackPanel>
              <RadioButton x:Name="NavInicio" Style="{StaticResource Menu}" Tag="&#xE80F;" Content="Início" IsChecked="True"/>
              <RadioButton x:Name="NavDiagnostico" Style="{StaticResource Menu}" Tag="&#xE9D9;" Content="Diagnóstico"/>
              <RadioButton x:Name="NavHistorico" Style="{StaticResource Menu}" Tag="&#xE81C;" Content="Histórico"/>
              <RadioButton x:Name="NavInicializacao" Style="{StaticResource Menu}" Tag="&#xE7E8;" Content="Inicialização"/>
              <RadioButton x:Name="NavConfig" Style="{StaticResource Menu}" Tag="&#xE713;" Content="Configurações"/>
            </StackPanel>
          </DockPanel>
        </Border>

        <Grid Grid.Column="1" Margin="22,16,22,18">

          <!-- Página: Início -->
          <Grid x:Name="PaginaInicio">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="272"/>
            </Grid.ColumnDefinitions>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
              <RowDefinition Height="138"/>
            </Grid.RowDefinitions>

            <StackPanel Grid.Row="0" Grid.Column="0" Margin="0,0,0,12">
              <TextBlock FontSize="23" FontWeight="Bold" TextWrapping="Wrap">
                <Run Text="Vamos deixar seu PC"/> <Run Text="mais rápido e leve" Foreground="#4F9BFF"/>
              </TextBlock>
              <TextBlock Style="{StaticResource TextoSuave}" FontSize="13" Margin="0,4,0,0"
                         Text="Escolha o que limpar e clique em Otimizar. Tudo pode ser desfeito."/>
            </StackPanel>

            <Border Grid.Row="1" Grid.Column="0" Style="{StaticResource EstiloCartao}" Padding="14,12,8,4">
              <DockPanel>
                <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="2,0,0,10">
                  <TextBlock Text="&#xE945;" Style="{StaticResource Icone}" Foreground="#4F9BFF" FontSize="16" Margin="0,0,10,0"/>
                  <StackPanel>
                    <TextBlock Text="Ações de limpeza" Style="{StaticResource Titulo}"/>
                    <TextBlock Text="Escolha o que deseja fazer e clique em &quot;Otimizar&quot;." Style="{StaticResource TextoSuave}"/>
                  </StackPanel>
                </StackPanel>
                <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="0,0,6,0">
                  <StackPanel x:Name="ListaAcoes"/>
                </ScrollViewer>
              </DockPanel>
            </Border>

            <Border Grid.Row="2" Grid.Column="0" Style="{StaticResource EstiloCartao}" Margin="0,12,0,0" Padding="14,10,14,14">
              <DockPanel>
                <DockPanel DockPanel.Dock="Top" Margin="0,0,0,8">
                  <Button x:Name="BtnLimparLog" DockPanel.Dock="Right" Style="{StaticResource Botao}" Padding="10,4" FontSize="11" Content="Limpar registro"/>
                  <TextBlock Text="Registro" Style="{StaticResource Titulo}" FontSize="13" VerticalAlignment="Center"/>
                </DockPanel>
                <TextBox x:Name="TxtLog" Style="{StaticResource Registro}"/>
              </DockPanel>
            </Border>

            <StackPanel Grid.Row="0" Grid.RowSpan="3" Grid.Column="1" Margin="16,0,0,0">
              <Border Style="{StaticResource EstiloCartao}">
                <StackPanel>
                  <Grid>
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="84"/>
                      <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <Grid Width="84" Height="84">
                      <Ellipse Stroke="#1F2C45" StrokeThickness="8" Margin="4"/>
                      <Path x:Name="AnelInicio" Stroke="#22C55E" StrokeThickness="8" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                      <TextBlock x:Name="TxtNotaInicio" Text="--" FontSize="22" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Grid>
                    <StackPanel Grid.Column="1" Margin="12,0,0,0" VerticalAlignment="Center">
                      <TextBlock Text="Saúde do PC" Style="{StaticResource TextoSuave}"/>
                      <TextBlock x:Name="TxtEstado" Text="Pronto para otimizar" FontWeight="SemiBold" FontSize="14" TextWrapping="Wrap" Margin="0,2,0,0"/>
                      <TextBlock x:Name="TxtSelecionadas" Style="{StaticResource TextoSuave}" Margin="0,2,0,0"/>
                    </StackPanel>
                  </Grid>
                  <ProgressBar x:Name="BarraProgresso" Height="4" Margin="0,12,0,0" IsIndeterminate="True"
                               Foreground="#22C55E" Background="#1F2C45" BorderThickness="0" Visibility="Collapsed"/>
                  <Button x:Name="BtnOtimizar" Style="{StaticResource BotaoPrincipal}" Margin="0,14,0,0">
                    <StackPanel Orientation="Horizontal">
                      <TextBlock Text="&#xE768;" Style="{StaticResource Icone}" Margin="0,0,10,0"/>
                      <TextBlock Text="Otimizar"/>
                    </StackPanel>
                  </Button>
                  <Button x:Name="BtnAnalisar" Style="{StaticResource BotaoContorno}" Margin="0,10,0,0">
                    <StackPanel Orientation="Horizontal">
                      <TextBlock Text="&#xE721;" Style="{StaticResource Icone}" Margin="0,0,10,0"/>
                      <TextBlock Text="Analisar (sem alterar nada)"/>
                    </StackPanel>
                  </Button>
                </StackPanel>
              </Border>

              <Border Style="{StaticResource EstiloCartao}" Margin="0,12,0,0">
                <StackPanel>
                  <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
                    <TextBlock Text="&#xE9D9;" Style="{StaticResource Icone}" Foreground="#4F9BFF" FontSize="15" Margin="0,0,10,0"/>
                    <TextBlock Text="Status do sistema" Style="{StaticResource Titulo}" FontSize="14"/>
                  </StackPanel>
                  <StackPanel x:Name="ListaStatus"/>
                </StackPanel>
              </Border>

              <Border Style="{StaticResource EstiloCartao}" Margin="0,12,0,0">
                <StackPanel>
                  <Button x:Name="BtnVerHistorico" Background="Transparent" BorderThickness="0" Padding="0" Cursor="Hand"
                          HorizontalContentAlignment="Stretch">
                    <Button.Template>
                      <ControlTemplate TargetType="Button"><ContentPresenter/></ControlTemplate>
                    </Button.Template>
                    <DockPanel>
                      <TextBlock DockPanel.Dock="Right" Text="&#xE76C;" Style="{StaticResource Icone}" Foreground="{StaticResource Suave}" FontSize="11"/>
                      <TextBlock Text="&#xE945;" Style="{StaticResource Icone}" Foreground="#FACC15" FontSize="16" Margin="0,0,10,0"/>
                      <StackPanel>
                        <TextBlock Text="Última limpeza" FontWeight="SemiBold"/>
                        <TextBlock x:Name="TxtUltimaLimpeza" Text="Nenhuma ainda" Style="{StaticResource TextoSuave}"/>
                      </StackPanel>
                    </DockPanel>
                  </Button>
                  <TextBlock x:Name="TxtBackup" Style="{StaticResource TextoSuave}" FontSize="11" Margin="0,10,0,0"/>
                  <Grid Margin="0,8,0,0">
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="*"/>
                      <ColumnDefinition Width="8"/>
                      <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <Button x:Name="BtnDesfazer" Grid.Column="0" Style="{StaticResource Botao}" Padding="6,7" FontSize="12"
                            ToolTip="Devolve os arquivos da última limpeza (Ctrl+Z)">
                      <StackPanel Orientation="Horizontal">
                        <TextBlock Text="&#xE7A7;" Style="{StaticResource Icone}" Margin="0,0,6,0"/>
                        <TextBlock Text="Desfazer"/>
                      </StackPanel>
                    </Button>
                    <Button x:Name="BtnEsvaziar" Grid.Column="2" Style="{StaticResource Botao}" Padding="6,7" FontSize="12"
                            ToolTip="Apaga de vez o backup para liberar o espaço">
                      <StackPanel Orientation="Horizontal">
                        <TextBlock Text="&#xE74D;" Style="{StaticResource Icone}" Margin="0,0,6,0"/>
                        <TextBlock Text="Esvaziar"/>
                      </StackPanel>
                    </Button>
                  </Grid>
                </StackPanel>
              </Border>
            </StackPanel>
          </Grid>

          <!-- Página: Diagnóstico -->
          <Grid x:Name="PaginaDiagnostico" Visibility="Collapsed">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <DockPanel Margin="0,0,0,14">
              <Button x:Name="BtnAtualizarDiag" DockPanel.Dock="Right" Style="{StaticResource BotaoContorno}" Height="38" VerticalAlignment="Center">
                <StackPanel Orientation="Horizontal">
                  <TextBlock Text="&#xE72C;" Style="{StaticResource Icone}" Margin="0,0,8,0"/>
                  <TextBlock Text="Analisar de novo"/>
                </StackPanel>
              </Button>
              <StackPanel>
                <TextBlock Text="Diagnóstico do PC" FontSize="24" FontWeight="Bold"/>
                <TextBlock Style="{StaticResource TextoSuave}" FontSize="13" Text="Só leitura: nada é alterado."/>
              </StackPanel>
            </DockPanel>
            <Grid Grid.Row="1">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="310"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Border Style="{StaticResource EstiloCartao}" Padding="20">
                <StackPanel>
                  <Grid Width="150" Height="150" HorizontalAlignment="Center">
                    <Ellipse Stroke="#1F2C45" StrokeThickness="12" Margin="6"/>
                    <Path x:Name="AnelDiag" Stroke="#22C55E" StrokeThickness="12" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                    <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
                      <TextBlock x:Name="TxtNotaDiag" Text="--" FontSize="40" FontWeight="Bold" HorizontalAlignment="Center"/>
                      <TextBlock Text="de 100" Style="{StaticResource TextoSuave}" HorizontalAlignment="Center"/>
                    </StackPanel>
                  </Grid>
                  <TextBlock x:Name="TxtRotuloDiag" Text="Analisando..." FontSize="17" FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,12,0,0"/>
                  <TextBlock Text="Dicas" Style="{StaticResource Titulo}" FontSize="14" Margin="0,18,0,8"/>
                  <StackPanel x:Name="ListaDicas"/>
                </StackPanel>
              </Border>
              <Border Grid.Column="1" Style="{StaticResource EstiloCartao}" Margin="16,0,0,0">
                <DockPanel>
                  <TextBlock DockPanel.Dock="Top" Text="Detalhes" Style="{StaticResource Titulo}" FontSize="14" Margin="0,0,0,10"/>
                  <TextBox x:Name="TxtDiagnostico" Style="{StaticResource Registro}" Text="Coletando informações..."/>
                </DockPanel>
              </Border>
            </Grid>
          </Grid>

          <!-- Página: Histórico -->
          <Grid x:Name="PaginaHistorico" Visibility="Collapsed">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <StackPanel Margin="0,0,0,14">
              <TextBlock Text="Histórico" FontSize="24" FontWeight="Bold"/>
              <TextBlock Style="{StaticResource TextoSuave}" FontSize="13" Text="As últimas limpezas feitas neste PC."/>
            </StackPanel>
            <Border Grid.Row="1" Style="{StaticResource EstiloCartao}">
              <Grid>
                <TextBlock x:Name="TxtHistoricoVazio" Text="Nenhuma limpeza feita ainda." Style="{StaticResource TextoSuave}"
                           FontSize="13" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                  <StackPanel x:Name="ListaHistorico"/>
                </ScrollViewer>
              </Grid>
            </Border>
          </Grid>

          <!-- Página: Programas de inicialização -->
          <StackPanel x:Name="PaginaInicializacao" Visibility="Collapsed">
            <TextBlock Text="Programas de inicialização" FontSize="24" FontWeight="Bold"/>
            <TextBlock Style="{StaticResource TextoSuave}" FontSize="13" Margin="0,0,0,14"
                       Text="Programas que abrem sozinhos junto com o Windows deixam o PC lento para ligar."/>
            <Border Style="{StaticResource EstiloCartao}" Padding="20">
              <StackPanel>
                <TextBlock TextWrapping="Wrap" FontSize="13" LineHeight="21">
                  O Otimizador não desativa nada sozinho. Ele abre o Gerenciador de Tarefas do Windows
                  na aba de inicialização, onde você escolhe:
                </TextBlock>
                <TextBlock TextWrapping="Wrap" FontSize="13" LineHeight="21" Margin="0,10,0,0" Foreground="#C9D4E5">
                  1. Clique no programa que não precisa abrir com o Windows.<LineBreak/>
                  2. Clique em "Desabilitar". O programa continua instalado e abre normalmente quando você quiser.<LineBreak/>
                  3. Para voltar atrás, clique nele de novo e em "Habilitar".
                </TextBlock>
                <TextBlock TextWrapping="Wrap" Style="{StaticResource TextoSuave}" FontSize="12" Margin="0,10,0,0"
                           Text="Dica: na dúvida, não desative antivírus, drivers (áudio, vídeo, touchpad) nem programas da empresa."/>
                <Button x:Name="BtnAbrirInicializacao" Style="{StaticResource BotaoPrincipal}" HorizontalAlignment="Left" Padding="22,0" Margin="0,18,0,0">
                  <StackPanel Orientation="Horizontal">
                    <TextBlock Text="&#xE7E8;" Style="{StaticResource Icone}" Margin="0,0,10,0"/>
                    <TextBlock Text="Abrir programas de inicialização"/>
                  </StackPanel>
                </Button>
              </StackPanel>
            </Border>
          </StackPanel>

          <!-- Página: Configurações -->
          <Grid x:Name="PaginaConfig" Visibility="Collapsed">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <StackPanel Grid.ColumnSpan="2" Margin="0,0,0,14">
              <TextBlock Text="Configurações" FontSize="24" FontWeight="Bold"/>
              <TextBlock Style="{StaticResource TextoSuave}" FontSize="13"
                         Text="Preferências do Otimizador. Nada aqui muda configurações do Windows."/>
            </StackPanel>
            <Border Grid.Row="1" Style="{StaticResource EstiloCartao}" VerticalAlignment="Top">
              <StackPanel>
                <TextBlock Text="Ações marcadas ao abrir o app" Style="{StaticResource Titulo}" FontSize="14"/>
                <TextBlock Style="{StaticResource TextoSuave}" Margin="0,2,0,10" Text="As que ficarem ligadas aqui já vêm marcadas na tela inicial."/>
                <StackPanel x:Name="ListaConfigAcoes"/>
              </StackPanel>
            </Border>
            <StackPanel Grid.Row="1" Grid.Column="1" Margin="16,0,0,0">
              <Border Style="{StaticResource EstiloCartao}">
                <StackPanel>
                  <TextBlock Text="Atualizações" Style="{StaticResource Titulo}" FontSize="14"/>
                  <DockPanel Margin="0,10,0,0">
                    <CheckBox x:Name="ChkVerificarAtualizacoes" DockPanel.Dock="Right" Style="{StaticResource Interruptor}"/>
                    <StackPanel>
                      <TextBlock Text="Procurar atualizações ao abrir" FontWeight="SemiBold"/>
                      <TextBlock Style="{StaticResource TextoSuave}" Text="Quando houver versão nova, aparece o botão verde &quot;Atualizar&quot; no alto da janela."/>
                    </StackPanel>
                  </DockPanel>
                  <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
                    <Button x:Name="BtnProcurarAtualizacao" Style="{StaticResource BotaoContorno}" Height="38">
                      <StackPanel Orientation="Horizontal">
                        <TextBlock Text="&#xE895;" Style="{StaticResource Icone}" Margin="0,0,8,0"/>
                        <TextBlock Text="Procurar agora"/>
                      </StackPanel>
                    </Button>
                    <TextBlock x:Name="TxtStatusAtualizacao" Style="{StaticResource TextoSuave}" VerticalAlignment="Center" Margin="12,0,0,0"/>
                  </StackPanel>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource EstiloCartao}" Margin="0,12,0,0">
                <StackPanel>
                  <TextBlock Text="Sobre" Style="{StaticResource Titulo}" FontSize="14"/>
                  <TextBlock x:Name="TxtSobre" Style="{StaticResource TextoSuave}" FontSize="12" Margin="0,4,0,10"/>
                  <Button x:Name="BtnNovidades" Style="{StaticResource BotaoContorno}" Height="38" HorizontalAlignment="Left">
                    <StackPanel Orientation="Horizontal">
                      <TextBlock Text="&#xE8A7;" Style="{StaticResource Icone}" Margin="0,0,8,0"/>
                      <TextBlock Text="Ver novidades de todas as versões"/>
                    </StackPanel>
                  </Button>
                </StackPanel>
              </Border>
            </StackPanel>
          </Grid>
        </Grid>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

function Pincel {
    param([string]$Cor)
    return [System.Windows.Media.BrushConverter]::new().ConvertFromString($Cor)
}

function Espaco {
    param([double]$Esquerda, [double]$Cima = $Esquerda, [double]$Direita = $Esquerda, [double]$Baixo = $Cima)
    return New-Object System.Windows.Thickness($Esquerda, $Cima, $Direita, $Baixo)
}

function Novo-Texto {
    param([string]$Texto, [double]$Tamanho = 13, [string]$Cor = $null, [string]$Peso = 'Normal', [string]$Fonte = $null)
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Texto
    $t.FontSize = $Tamanho
    $t.FontWeight = [System.Windows.FontWeights]::$Peso
    $t.TextWrapping = 'Wrap'
    $t.VerticalAlignment = 'Center'
    if ($Cor) { $t.Foreground = Pincel $Cor }
    if ($Fonte) { $t.FontFamily = New-Object System.Windows.Media.FontFamily($Fonte) }
    return $t
}

function Nova-LinhaInterruptor {
    # Linha com ícone colorido, título, descrição e um interruptor (usada nas ações e nas configurações).
    param($Acao, [bool]$Ligado, [bool]$Compacta = $false)
    $borda = New-Object System.Windows.Controls.Border
    $borda.Background = Pincel '#0F1828'
    $borda.BorderBrush = Pincel '#1C2840'
    $borda.BorderThickness = Espaco 1
    $borda.CornerRadius = New-Object System.Windows.CornerRadius(10)
    $borda.Padding = if ($Compacta) { Espaco 10 6 } else { Espaco 12 8 }
    $borda.Margin = Espaco 0 0 0 6

    $grade = New-Object System.Windows.Controls.Grid
    foreach ($largura in '46', '*', 'Auto') {
        $col = New-Object System.Windows.Controls.ColumnDefinition
        $col.Width = [System.Windows.GridLengthConverter]::new().ConvertFromString($largura)
        $grade.ColumnDefinitions.Add($col)
    }

    $circulo = New-Object System.Windows.Controls.Border
    $circulo.Width = 34; $circulo.Height = 34; $circulo.CornerRadius = New-Object System.Windows.CornerRadius(17)
    $circulo.Background = Pincel $Acao.Cor
    $circulo.HorizontalAlignment = 'Left'
    $icone = Novo-Texto ([string]$Acao.Icone) 15 '#FFFFFF' 'Normal' 'Segoe MDL2 Assets'
    $icone.HorizontalAlignment = 'Center'
    $circulo.Child = $icone
    $grade.Children.Add($circulo) | Out-Null

    $textos = New-Object System.Windows.Controls.StackPanel
    $textos.VerticalAlignment = 'Center'
    $textos.Children.Add((Novo-Texto $Acao.Titulo 13 $null 'SemiBold')) | Out-Null
    if (-not $Compacta) {
        $desc = Novo-Texto $Acao.Descricao 11.5 '#8A97AD'
        $desc.Margin = Espaco 0 2 0 0
        $textos.Children.Add($desc) | Out-Null
    }
    [System.Windows.Controls.Grid]::SetColumn($textos, 1)
    $grade.Children.Add($textos) | Out-Null

    $chave = New-Object System.Windows.Controls.CheckBox
    $chave.Style = $script:UI.Janela.FindResource('Interruptor')
    $chave.IsChecked = $Ligado
    $chave.Margin = Espaco 12 0 0 0
    [System.Windows.Automation.AutomationProperties]::SetName($chave, $Acao.Titulo)
    [System.Windows.Controls.Grid]::SetColumn($chave, 2)
    $grade.Children.Add($chave) | Out-Null

    $borda.Child = $grade
    return @{ Linha = $borda; Chave = $chave }
}

function Definir-Anel {
    # Desenha o arco do anel de saúde (0 a 100) dentro de uma área quadrada de $Tamanho.
    param($Caminho, [double]$Valor, [double]$Tamanho, [double]$Espessura)
    # Mesmo raio do traço do círculo de fundo (Ellipse com margem de meia espessura)
    $raio = $Tamanho / 2 - $Espessura
    $centro = $Tamanho / 2
    $v = [math]::Max(0.5, [math]::Min(99.9, $Valor))
    $angulo = $v / 100 * 2 * [math]::PI
    $figura = New-Object System.Windows.Media.PathFigure
    $figura.StartPoint = New-Object System.Windows.Point($centro, ($centro - $raio))
    $fim = New-Object System.Windows.Point(($centro + $raio * [math]::Sin($angulo)), ($centro - $raio * [math]::Cos($angulo)))
    $arco = New-Object System.Windows.Media.ArcSegment($fim, (New-Object System.Windows.Size($raio, $raio)), 0, ($v -gt 50),
        [System.Windows.Media.SweepDirection]::Clockwise, $true)
    $figura.Segments.Add($arco)
    $geometria = New-Object System.Windows.Media.PathGeometry
    $geometria.Figures.Add($figura)
    $Caminho.Data = $geometria
}

function Obter-CorNota {
    param([int]$Nota)
    if ($Nota -ge 80) { return @{ Cor = '#22C55E'; Rotulo = 'Bom' } }
    if ($Nota -ge 60) { return @{ Cor = '#FACC15'; Rotulo = 'Regular' } }
    return @{ Cor = '#EF4444'; Rotulo = 'Precisa de atenção' }
}

function Mostrar-Mensagem {
    param([string]$Texto, [string]$Titulo = 'Otimizador de PC', [string]$Botoes = 'OK', [string]$Icone = 'Information')
    if ($script:UI.Janela -and $script:UI.Janela.IsVisible) {
        return [string][System.Windows.MessageBox]::Show($script:UI.Janela, $Texto, $Titulo, $Botoes, $Icone)
    }
    if ($script:UI.Form) {
        return [string][System.Windows.Forms.MessageBox]::Show($script:UI.Form, $Texto, $Titulo, $Botoes, $Icone)
    }
    return [string][System.Windows.Forms.MessageBox]::Show($Texto, $Titulo, $Botoes, $Icone)
}

function Mostrar-Pagina {
    param([string]$Nome)
    foreach ($p in 'PaginaInicio', 'PaginaDiagnostico', 'PaginaHistorico', 'PaginaInicializacao', 'PaginaConfig') {
        $script:UI[$p].Visibility = if ($p -eq $Nome) { 'Visible' } else { 'Collapsed' }
    }
    if ($Nome -eq 'PaginaHistorico') { Atualizar-Historico }
}

function Obter-Selecionadas {
    return @($script:Acoes | Where-Object { $script:UI.Chaves[$_.Id].IsChecked })
}

function Atualizar-Selecionadas {
    $n = (Obter-Selecionadas).Count
    $script:UI.TxtSelecionadas.Text = if ($n -eq 1) { '1 ação selecionada' } else { "$n ações selecionadas" }
}

function Definir-Ocupado {
    param([bool]$Sim, [string]$Texto = '')
    $script:Ocupado = $Sim
    foreach ($nome in 'BtnOtimizar', 'BtnAnalisar', 'BtnDesfazer', 'BtnEsvaziar', 'BtnAtualizar') { $script:UI[$nome].IsEnabled = -not $Sim }
    foreach ($c in $script:UI.Chaves.Values) { $c.IsEnabled = -not $Sim }
    $script:UI.BarraProgresso.Visibility = if ($Sim) { 'Visible' } else { 'Collapsed' }
    $script:UI.TxtEstado.Text = if ($Sim) { $Texto } else { 'Pronto para otimizar' }
    if (-not $Sim) { Atualizar-StatusBackup }
}

function Atualizar-StatusBackup {
    $info = Obter-InfoBackup
    if ($info) {
        $script:UI.TxtBackup.Text = 'Backup: {0:N0} arquivo(s), {1}. Pode ser desfeito até {2:dd/MM}.' -f $info.Arquivos, (Formatar-Tamanho $info.Bytes), $info.Data.AddDays($script:DiasBackup)
    } else {
        $script:UI.TxtBackup.Text = 'Nenhum backup guardado.'
    }
    if (-not $script:Ocupado) {
        $script:UI.BtnDesfazer.IsEnabled = [bool]$info
        $script:UI.BtnEsvaziar.IsEnabled = [bool]$info
    }
    $ultima = Ler-Historico | Where-Object { $_.Tipo -eq 'Otimizacao' } | Select-Object -First 1
    if ($ultima) {
        $script:UI.TxtUltimaLimpeza.Text = '{0} · {1} limpos' -f (Formatar-Quando ([datetime]$ultima.Data)), (Formatar-Tamanho $ultima.Bytes)
    } else {
        $script:UI.TxtUltimaLimpeza.Text = 'Nenhuma ainda'
    }
}

function Atualizar-Historico {
    $lista = $script:UI.ListaHistorico
    $lista.Children.Clear()
    $itens = Ler-Historico
    $script:UI.TxtHistoricoVazio.Visibility = if ($itens.Count -eq 0) { 'Visible' } else { 'Collapsed' }
    foreach ($item in $itens) {
        $linha = New-Object System.Windows.Controls.DockPanel
        $borda = New-Object System.Windows.Controls.Border
        $borda.Background = Pincel '#0F1828'; $borda.BorderBrush = Pincel '#1C2840'; $borda.BorderThickness = Espaco 1
        $borda.CornerRadius = New-Object System.Windows.CornerRadius(10); $borda.Padding = Espaco 12 10; $borda.Margin = Espaco 0 0 0 8

        $icone = switch ($item.Tipo) { 'Otimizacao' { [char]0xE74D } 'Desfazer' { [char]0xE7A7 } default { [char]0xE74D } }
        $cor   = switch ($item.Tipo) { 'Otimizacao' { '#22C55E' } 'Desfazer' { '#FACC15' } default { '#4F9BFF' } }
        $ic = Novo-Texto ([string]$icone) 16 $cor 'Normal' 'Segoe MDL2 Assets'
        $ic.Width = 32
        [System.Windows.Controls.DockPanel]::SetDock($ic, 'Left')
        $linha.Children.Add($ic) | Out-Null

        if ($item.Bytes -gt 0) {
            $tam = Novo-Texto (Formatar-Tamanho $item.Bytes) 13 $cor 'SemiBold'
            [System.Windows.Controls.DockPanel]::SetDock($tam, 'Right')
            $linha.Children.Add($tam) | Out-Null
        }
        $textos = New-Object System.Windows.Controls.StackPanel
        $textos.Children.Add((Novo-Texto $item.Descricao 13 $null 'SemiBold')) | Out-Null
        $textos.Children.Add((Novo-Texto (Formatar-Quando ([datetime]$item.Data)) 11.5 '#8A97AD')) | Out-Null
        $linha.Children.Add($textos) | Out-Null

        $borda.Child = $linha
        $lista.Children.Add($borda) | Out-Null
    }
}

function Atualizar-Saude {
    param($Diag)
    $cor = Obter-CorNota $Diag.Nota
    foreach ($par in @(@('AnelInicio', 84, 8), @('AnelDiag', 150, 12))) {
        Definir-Anel $script:UI[$par[0]] $Diag.Nota $par[1] $par[2]
        $script:UI[$par[0]].Stroke = Pincel $cor.Cor
    }
    $script:UI.TxtNotaInicio.Text = [string]$Diag.Nota
    $script:UI.TxtNotaDiag.Text = [string]$Diag.Nota
    $script:UI.TxtRotuloDiag.Text = $cor.Rotulo
    $script:UI.TxtRotuloDiag.Foreground = Pincel $cor.Cor
    $script:UI.TxtSaudeLateral.Text = "Saúde do PC: $($Diag.Nota) · $($cor.Rotulo)"
    $script:UI.PontoSaude.Fill = Pincel $cor.Cor
    $script:UI.TxtDiagnostico.Text = ($Diag.Linhas -join "`r`n")

    $script:UI.ListaDicas.Children.Clear()
    foreach ($dica in $Diag.Dicas) {
        $linha = New-Object System.Windows.Controls.DockPanel
        $linha.Margin = Espaco 0 0 0 8
        $marca = Novo-Texto ([string][char]0xE73E) 11 $cor.Cor 'Normal' 'Segoe MDL2 Assets'
        $marca.Width = 20; $marca.VerticalAlignment = 'Top'; $marca.Margin = Espaco 0 3 0 0
        [System.Windows.Controls.DockPanel]::SetDock($marca, 'Left')
        $linha.Children.Add($marca) | Out-Null
        $linha.Children.Add((Novo-Texto $dica 12.5 '#C9D4E5')) | Out-Null
        $script:UI.ListaDicas.Children.Add($linha) | Out-Null
    }
}

function Iniciar-Diagnostico {
    if ($script:DiagnosticoRodando) { return }
    $script:DiagnosticoRodando = $true
    $script:UI.TxtRotuloDiag.Text = 'Analisando...'
    Iniciar-EmSegundoPlano -Trabalho { Obter-Diagnostico } -AoConcluir {
        param($resultado, $erro)
        $script:DiagnosticoRodando = $false
        $diag = $resultado | Select-Object -First 1
        if ($diag) { Atualizar-Saude $diag } else { $script:UI.TxtRotuloDiag.Text = 'Não foi possível analisar' }
    }
}

# ---- Status do sistema

$script:ItensStatus = @(
    @{ Id = 'Cpu';     Nome = 'Processador'; Icone = [char]0xE7F4 }
    @{ Id = 'Memoria'; Nome = 'Memória';     Icone = [char]0xE964 }
    @{ Id = 'Disco';   Nome = 'Disco (C:)';  Icone = [char]0xEDA2 }
    @{ Id = 'Rede';    Nome = 'Internet';    Icone = [char]0xE701 }
)

function Criar-ListaStatus {
    $script:UI.Status = @{}
    foreach ($item in $script:ItensStatus) {
        $linha = New-Object System.Windows.Controls.DockPanel
        $linha.Margin = Espaco 0 4
        $ic = Novo-Texto ([string]$item.Icone) 14 '#8A97AD' 'Normal' 'Segoe MDL2 Assets'
        $ic.Width = 28
        [System.Windows.Controls.DockPanel]::SetDock($ic, 'Left')
        $valor = Novo-Texto '...' 12 '#8A97AD' 'SemiBold'
        [System.Windows.Controls.DockPanel]::SetDock($valor, 'Right')
        $linha.Children.Add($ic) | Out-Null
        $linha.Children.Add($valor) | Out-Null
        $linha.Children.Add((Novo-Texto $item.Nome 13)) | Out-Null
        $script:UI.ListaStatus.Children.Add($linha) | Out-Null
        $script:UI.Status[$item.Id] = $valor
    }
}

function Definir-Status {
    param([string]$Id, [string]$Texto, [string]$Nivel)
    $cores = @{ Normal = '#22C55E'; Atencao = '#FACC15'; Alto = '#EF4444'; Neutro = '#8A97AD' }
    $script:UI.Status[$Id].Text = $Texto
    $script:UI.Status[$Id].Foreground = Pincel $cores[$Nivel]
}

function Classificar {
    param([int]$Valor, [int]$Atencao, [int]$Alto)
    if ($Valor -lt 0) { return 'Neutro' }
    if ($Valor -ge $Alto) { return 'Alto' }
    if ($Valor -ge $Atencao) { return 'Atencao' }
    return 'Normal'
}

function Iniciar-Status {
    if ($script:StatusRodando) { return }
    $script:StatusRodando = $true
    Iniciar-EmSegundoPlano -Trabalho { Obter-StatusSistema } -AoConcluir {
        param($resultado, $erro)
        $script:StatusRodando = $false
        $s = $resultado | Select-Object -First 1
        if (-not $s) { return }
        $rotulos = @{ Normal = 'Normal'; Atencao = 'Atenção'; Alto = 'Alto'; Neutro = '--' }
        $n = Classificar $s.Cpu 70 90;      Definir-Status 'Cpu' ('{0} · {1}%' -f $rotulos[$n], $s.Cpu) $n
        $n = Classificar $s.Memoria 80 90;  Definir-Status 'Memoria' ('{0} · {1}%' -f $rotulos[$n], $s.Memoria) $n
        if ($s.DiscoLivre -lt 0) { $n = 'Neutro' } elseif ($s.DiscoLivre -lt 8) { $n = 'Alto' } elseif ($s.DiscoLivre -lt 15) { $n = 'Atencao' } else { $n = 'Normal' }
        $txtDisco = if ($n -eq 'Normal') { 'Normal' } elseif ($n -eq 'Neutro') { '--' } else { 'Pouco espaço' }
        Definir-Status 'Disco' ('{0} · {1}% livre' -f $txtDisco, $s.DiscoLivre) $n
        if ($s.Rede) { Definir-Status 'Rede' 'Conectado' 'Normal' } else { Definir-Status 'Rede' 'Sem conexão' 'Alto' }
    }
}

# ---- Ações dos botões

function Ao-Analisar {
    $acoes = Obter-Selecionadas
    if ($acoes.Count -eq 0) { [void](Mostrar-Mensagem 'Marque pelo menos uma ação.'); return }
    Definir-Ocupado $true 'Analisando...'
    Escrever-Log '----- ANÁLISE (nada foi alterado) -----'
    Iniciar-EmSegundoPlano -Trabalho { param($Acoes) foreach ($a in $Acoes) { Analisar-Acao $a } } -Parametros @{ Acoes = $acoes } -AoConcluir {
        param($resultado, $erro)
        Definir-Ocupado $false
        if ($erro) { Escrever-Log "Erro na análise: $erro"; return }
        $arquivos = 0; $bytes = [long]0
        foreach ($r in $resultado) { Escrever-Log "- $($r.Acao.Nome): $($r.Mensagem)"; $arquivos += $r.Arquivos; $bytes += $r.Bytes }
        Escrever-Log ('Total: {0:N0} arquivo(s), {1} podem ser limpos.' -f $arquivos, (Formatar-Tamanho $bytes))
        $script:UI.TxtEstado.Text = '{0} podem ser limpos' -f (Formatar-Tamanho $bytes)
    }
}

function Ao-Otimizar {
    $acoes = Obter-Selecionadas
    if ($acoes.Count -eq 0) { [void](Mostrar-Mensagem 'Marque pelo menos uma ação.'); return }
    Definir-Ocupado $true 'Preparando...'
    Escrever-Log '----- Preparando a otimização -----'
    Iniciar-EmSegundoPlano -Trabalho { param($Acoes) foreach ($a in $Acoes) { Analisar-Acao $a } } -Parametros @{ Acoes = $acoes } -AoConcluir {
        param($resultado, $erro)
        if ($erro) { Definir-Ocupado $false; Escrever-Log "Erro na análise: $erro"; return }
        $linhas = foreach ($r in $resultado) { "- $($r.Acao.Nome): $($r.Mensagem)" }
        $msg = "Será feito:`r`n`r`n" + ($linhas -join "`r`n")
        $msg += "`r`n`r`nOs arquivos ficam guardados em backup por até $($script:DiasBackup) dias. Para devolvê-los, use 'Desfazer'."
        $temBackup = [bool](Obter-InfoBackup)
        if ($temBackup) { $msg += "`r`n`r`nAtenção: o backup da limpeza anterior será apagado de vez." }
        $msg += "`r`n`r`nDeseja continuar?"
        if ((Mostrar-Mensagem $msg 'Confirmar otimização' 'YesNo' 'Question') -ne 'Yes') {
            Definir-Ocupado $false
            Escrever-Log 'Otimização cancelada. Nada foi alterado.'
            return
        }
        Definir-Ocupado $true 'Otimizando...'
        $acoesEscolhidas = @($resultado | ForEach-Object { $_.Acao })
        Iniciar-EmSegundoPlano -Parametros @{ Acoes = $acoesEscolhidas; ApagarBackup = $temBackup } -Trabalho {
            param($Acoes, $ApagarBackup)
            if ($ApagarBackup) { Escrever-Log 'Apagando o backup da limpeza anterior...'; Remover-PastaSegura $PastaBackup }
            Escrever-Log '----- OTIMIZANDO -----'
            foreach ($a in $Acoes) {
                Escrever-Log "$($a.Nome)..."
                $r = Executar-Acao $a
                Escrever-Log "  -> $($r.Texto)"
                $r
            }
        } -AoConcluir {
            param($resultado, $erro)
            Definir-Ocupado $false
            if ($erro) { Escrever-Log "Erro na otimização: $erro" }
            $arquivos = 0; $bytes = [long]0
            foreach ($r in $resultado) { $arquivos += $r.Arquivos; $bytes += $r.Bytes }
            Adicionar-Historico 'Otimizacao' ('Otimização: {0:N0} arquivo(s) limpos' -f $arquivos) $arquivos $bytes
            Atualizar-StatusBackup
            Escrever-Log ('Otimização concluída: {0} limpos.' -f (Formatar-Tamanho $bytes))
            $script:UI.TxtEstado.Text = '{0} limpos!' -f (Formatar-Tamanho $bytes)
            [void](Mostrar-Mensagem ('Otimização concluída! {0} limpos.' -f (Formatar-Tamanho $bytes)))
            Iniciar-Diagnostico
        }
    }
}

function Ao-Desfazer {
    if ($script:Ocupado) { return }
    $info = Obter-InfoBackup
    if (-not $info) { [void](Mostrar-Mensagem 'Não há limpeza para desfazer.'); return }
    $msg = 'Devolver {0:N0} arquivo(s) ({1}) para os locais de onde foram removidos?' -f $info.Arquivos, (Formatar-Tamanho $info.Bytes)
    $prefixos = @(Obter-PrefixosNavegadoresAbertos)
    if ($prefixos.Count -gt 0) { $msg += "`r`n`r`nO Chrome ou o Edge está aberto: o cache dele só será devolvido depois que o navegador for fechado." }
    if ((Mostrar-Mensagem $msg 'Desfazer última limpeza' 'YesNo' 'Question') -ne 'Yes') { return }

    Definir-Ocupado $true 'Desfazendo...'
    Escrever-Log '----- DESFAZENDO a última limpeza -----'
    Iniciar-EmSegundoPlano -Parametros @{ Prefixos = $prefixos } -Trabalho {
        param($Prefixos)
        Restaurar-Backup -PastaBackup $PastaBackup -PularPrefixos $Prefixos
    } -AoConcluir {
        param($resultado, $erro)
        Definir-Ocupado $false
        $r = $resultado | Select-Object -First 1
        if (-not $r) { Escrever-Log "Não foi possível desfazer: $erro"; return }
        Escrever-Log ('{0:N0} arquivo(s) devolvidos.' -f $r.Restaurados)
        if ($r.Mantidos)   { Escrever-Log ('{0:N0} mantidos no backup porque o navegador está aberto. Feche-o e clique em Desfazer de novo.' -f $r.Mantidos) }
        if ($r.JaExistiam) { Escrever-Log ('{0:N0} mantidos no backup porque já existe um arquivo novo com o mesmo nome.' -f $r.JaExistiam) }
        if ($r.Falhas)     { Escrever-Log ('{0:N0} não puderam ser devolvidos (sem permissão).' -f $r.Falhas) }
        Adicionar-Historico 'Desfazer' ('Limpeza desfeita: {0:N0} arquivo(s) devolvidos' -f $r.Restaurados) $r.Restaurados 0
        Atualizar-StatusBackup
    }
}

function Ao-Esvaziar {
    $info = Obter-InfoBackup
    if (-not $info) { return }
    $msg = 'Apagar de vez o backup ({0:N0} arquivo(s), {1})?{2}{2}Isso libera o espaço, mas depois não dá mais para desfazer a última limpeza.' -f $info.Arquivos, (Formatar-Tamanho $info.Bytes), "`r`n"
    if ((Mostrar-Mensagem $msg 'Esvaziar backup' 'YesNo' 'Warning') -ne 'Yes') { return }
    Definir-Ocupado $true 'Liberando espaço...'
    Iniciar-EmSegundoPlano -Parametros @{ Bytes = $info.Bytes } -Trabalho {
        param($Bytes)
        Remover-PastaSegura $PastaBackup
        $Bytes
    } -AoConcluir {
        param($resultado, $erro)
        Definir-Ocupado $false
        Escrever-Log ('Backup apagado: {0} liberados.' -f (Formatar-Tamanho ($resultado | Select-Object -First 1)))
    }
}

function Ao-Inicializacao {
    try {
        Start-Process -FilePath 'taskmgr.exe' -ArgumentList '/0', '/startup'
        Escrever-Log 'Gerenciador de Tarefas aberto na aba Inicialização.'
    } catch {
        [void](Mostrar-Mensagem 'Não foi possível abrir o Gerenciador de Tarefas.' 'Programas de inicialização' 'OK' 'Warning')
    }
}

function Ao-VerNovidades {
    try { Start-Process -FilePath $script:UrlReleases } catch { Escrever-Log "As novidades estão em: $($script:UrlReleases)" }
}

function Salvar-Preferencias {
    $config = [pscustomobject]@{
        AcoesPadrao = @($script:Acoes | Where-Object { $script:UI.ChavesConfig[$_.Id].IsChecked } | ForEach-Object { $_.Id })
        VerificarAtualizacoes = [bool]$script:UI.ChkVerificarAtualizacoes.IsChecked
    }
    Salvar-Config $config
}

function Ao-Abrir {
    $info = Obter-InfoBackup
    if ($info -and $info.Data -lt (Get-Date).AddDays(-$script:DiasBackup)) {
        Remover-PastaSegura $script:PastaBackup
        Escrever-Log ("Backup com mais de $($script:DiasBackup) dias apagado automaticamente ({0} liberados)." -f (Formatar-Tamanho $info.Bytes))
    }
    Atualizar-StatusBackup
    Escrever-Log 'Pronto. Clique em "Analisar" para ver o que será feito ou em "Otimizar" para limpar.'
    Remover-PastaSegura $script:PastaDownload   # instalador baixado numa atualização anterior
    Iniciar-Diagnostico
    Iniciar-Status
    if ((Ler-Config).VerificarAtualizacoes) { Iniciar-VerificacaoAtualizacao }
    if ($script:ArgsInicio -contains '/atualizado') {
        Escrever-Log "Atualizado para a versão $($script:Versao)."
        if ($script:NotasVersao) {
            [void](Mostrar-Mensagem "O $($script:NomeApp) foi atualizado para a versão $($script:Versao).`r`n`r`nO que mudou:`r`n$($script:NotasVersao)" "Novidades da versão $($script:Versao)")
        }
    }
}

function Criar-Janela {
    $janela = [System.Windows.Markup.XamlReader]::Parse($script:Xaml)
    $script:UI.Janela = $janela
    $nomes = 'BarraTitulo', 'TxtVersao', 'BtnAtualizar', 'TxtBtnAtualizar', 'BtnMinimizar', 'BtnFechar',
             'PontoSaude', 'TxtSaudeLateral', 'NavInicio', 'NavDiagnostico', 'NavHistorico', 'NavInicializacao', 'NavConfig',
             'PaginaInicio', 'PaginaDiagnostico', 'PaginaHistorico', 'PaginaInicializacao', 'PaginaConfig',
             'ListaAcoes', 'BtnLimparLog', 'TxtLog', 'AnelInicio', 'TxtNotaInicio', 'TxtEstado', 'TxtSelecionadas',
             'BarraProgresso', 'BtnOtimizar', 'BtnAnalisar', 'ListaStatus', 'BtnVerHistorico', 'TxtUltimaLimpeza',
             'TxtBackup', 'BtnDesfazer', 'BtnEsvaziar', 'BtnAtualizarDiag', 'AnelDiag', 'TxtNotaDiag', 'TxtRotuloDiag',
             'ListaDicas', 'TxtDiagnostico', 'TxtHistoricoVazio', 'ListaHistorico', 'BtnAbrirInicializacao',
             'ListaConfigAcoes', 'ChkVerificarAtualizacoes', 'BtnProcurarAtualizacao', 'TxtStatusAtualizacao',
             'TxtSobre', 'BtnNovidades'
    foreach ($nome in $nomes) { $script:UI[$nome] = $janela.FindName($nome) }

    $script:UI.TxtVersao.Text = "v$($script:Versao)"
    $script:UI.TxtSobre.Text = "$($script:NomeApp) versão $($script:Versao)`r`nCódigo e novidades: github.com/$($script:RepoGitHub)"

    # Ações (tela inicial) e preferências (configurações)
    $config = Ler-Config
    $script:UI.Chaves = @{}
    $script:UI.ChavesConfig = @{}
    foreach ($acao in $script:Acoes) {
        $marcada = $config.AcoesPadrao -contains $acao.Id
        $item = Nova-LinhaInterruptor $acao $marcada
        $script:UI.ListaAcoes.Children.Add($item.Linha) | Out-Null
        $script:UI.Chaves[$acao.Id] = $item.Chave
        $item.Chave.Add_Click({ Atualizar-Selecionadas })

        $itemConfig = Nova-LinhaInterruptor $acao $marcada $true
        $script:UI.ListaConfigAcoes.Children.Add($itemConfig.Linha) | Out-Null
        $script:UI.ChavesConfig[$acao.Id] = $itemConfig.Chave
        $itemConfig.Chave.Add_Click({ Salvar-Preferencias })
    }
    $script:UI.ChkVerificarAtualizacoes.IsChecked = $config.VerificarAtualizacoes
    $script:UI.ChkVerificarAtualizacoes.Add_Click({ Salvar-Preferencias })
    Atualizar-Selecionadas
    Criar-ListaStatus
    Definir-Anel $script:UI.AnelInicio 0.5 84 8
    Definir-Anel $script:UI.AnelDiag 0.5 150 12

    # Janela
    $script:UI.BarraTitulo.Add_MouseLeftButtonDown({ $script:UI.Janela.DragMove() })
    $script:UI.BtnMinimizar.Add_Click({ $script:UI.Janela.WindowState = 'Minimized' })
    $script:UI.BtnFechar.Add_Click({ $script:UI.Janela.Close() })
    $janela.Add_KeyDown({
        param($origem, $e)
        if ($e.Key -eq 'Z' -and ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -and $script:UI.BtnDesfazer.IsEnabled) {
            $e.Handled = $true
            Ao-Desfazer
        }
    })

    # Menu
    $script:UI.NavInicio.Add_Checked({ Mostrar-Pagina 'PaginaInicio' })
    $script:UI.NavDiagnostico.Add_Checked({ Mostrar-Pagina 'PaginaDiagnostico' })
    $script:UI.NavHistorico.Add_Checked({ Mostrar-Pagina 'PaginaHistorico' })
    $script:UI.NavInicializacao.Add_Checked({ Mostrar-Pagina 'PaginaInicializacao' })
    $script:UI.NavConfig.Add_Checked({ Mostrar-Pagina 'PaginaConfig' })

    # Botões
    $script:UI.BtnOtimizar.Add_Click({ Ao-Otimizar })
    $script:UI.BtnAnalisar.Add_Click({ Ao-Analisar })
    $script:UI.BtnDesfazer.Add_Click({ Ao-Desfazer })
    $script:UI.BtnEsvaziar.Add_Click({ Ao-Esvaziar })
    $script:UI.BtnLimparLog.Add_Click({ $script:UI.TxtLog.Clear() })
    $script:UI.BtnVerHistorico.Add_Click({ $script:UI.NavHistorico.IsChecked = $true })
    $script:UI.BtnAtualizarDiag.Add_Click({ Iniciar-Diagnostico })
    $script:UI.BtnAbrirInicializacao.Add_Click({ Ao-Inicializacao })
    $script:UI.BtnAtualizar.Add_Click({ Ao-Atualizar })
    $script:UI.BtnProcurarAtualizacao.Add_Click({ Iniciar-VerificacaoAtualizacao -Manual })
    $script:UI.BtnNovidades.Add_Click({ Ao-VerNovidades })

    # Timers: tarefas/registro (rápido) e status do sistema (a cada 3 s)
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(150)
    $timer.Add_Tick({ Processar-Tarefas })
    $timer.Start()
    $timerStatus = New-Object System.Windows.Threading.DispatcherTimer
    $timerStatus.Interval = [TimeSpan]::FromSeconds(3)
    $timerStatus.Add_Tick({ Iniciar-Status })
    $timerStatus.Start()
    $script:UI.Timers = @($timer, $timerStatus)

    $janela.Add_ContentRendered({ Ao-Abrir })
    $janela.Add_Closed({
        foreach ($t in $script:UI.Timers) { $t.Stop() }
        if ($script:Pool) { $script:Pool.Close() }
    })
    return $janela
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
    # Remove atalhos, a entrada do Painel de Controle, os dados (backup, histórico) e o programa.
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
                 "O backup da última limpeza, o histórico e os atalhos são mantidos."
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

function Novo-ClienteWeb {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $wc = New-Object System.Net.WebClient
    $wc.Headers['User-Agent'] = 'OtimizadorPC'
    $wc.Encoding = [System.Text.Encoding]::UTF8
    if ($wc.Proxy) { $wc.Proxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials }
    return $wc
}

function Iniciar-VerificacaoAtualizacao {
    param([switch]$Manual)
    # Só o app instalado se atualiza ("Abrir sem instalar" não).
    if (-not (Test-MesmoCaminho (Obter-ExeAtual) $script:ExeInstalado)) {
        if ($Manual) { $script:UI.TxtStatusAtualizacao.Text = 'Só o app instalado pode se atualizar.' }
        return
    }
    if ($Manual) { $script:UI.TxtStatusAtualizacao.Text = 'Procurando...' }
    $script:VerificacaoManual = [bool]$Manual
    Iniciar-EmSegundoPlano -Parametros @{ Url = "$($script:UrlReleases)/latest/download/versao.json" } -Trabalho {
        param($Url)
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $wc = New-Object System.Net.WebClient
            $wc.Headers['User-Agent'] = 'OtimizadorPC'
            $wc.Encoding = [System.Text.Encoding]::UTF8
            if ($wc.Proxy) { $wc.Proxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials }
            $wc.DownloadString($Url) | ConvertFrom-Json
        } catch { }
    } -AoConcluir {
        param($resultado, $erro)
        $info = $resultado | Select-Object -First 1
        $versao = if ($info) { [string]$info.versao } else { '' }
        $valido = $info -and $versao -match '^\d+(\.\d+){1,3}$' -and [string]$info.sha256 -match '^[0-9a-fA-F]{64}$'
        if ($valido -and (Test-VersaoMaisNova $versao $script:Versao)) {
            $script:Atualizacao = $info
            $script:UI.TxtBtnAtualizar.Text = "Atualizar para a versão $versao"
            $script:UI.BtnAtualizar.Visibility = 'Visible'
            $script:UI.TxtStatusAtualizacao.Text = "Versão $versao disponível."
            Escrever-Log "Nova versão disponível: $versao. Clique no botão verde ""Atualizar"" no alto da janela."
        } elseif ($script:VerificacaoManual) {
            $script:UI.TxtStatusAtualizacao.Text = if ($valido) { 'Você já está na versão mais recente.' } else { 'Não foi possível verificar agora (sem internet?).' }
        }
    }
}

function Ao-Atualizar {
    $info = $script:Atualizacao
    if (-not $info) { return }
    $msg = "Há uma versão nova do $($script:NomeApp): $($info.versao) (você está na $($script:Versao))."
    if ($info.notas) { $msg += "`r`n`r`nNovidades:`r`n$($info.notas)" }
    $msg += "`r`n`r`nBaixar e atualizar agora? O Otimizador vai fechar e abrir de novo sozinho."
    if ((Mostrar-Mensagem $msg 'Atualizar' 'YesNo' 'Question') -ne 'Yes') { return }

    Definir-Ocupado $true 'Baixando atualização...'
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
        $script:UI.Janela.Close()
    } catch {
        Definir-Ocupado $false
        Escrever-Log "Não foi possível atualizar: $($_.Exception.Message)"
        [void](Mostrar-Mensagem "Não foi possível atualizar agora:`r`n$($_.Exception.Message)`r`n`r`nO app continua funcionando na versão $($script:Versao)." 'Atualizar' 'OK' 'Warning')
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
    $janela = Criar-Janela
    [void]$janela.ShowDialog()
}

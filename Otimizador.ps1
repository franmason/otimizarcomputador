#requires -Version 5.1
<#
    Otimizador de PC
    ----------------
    Faz SOMENTE ações seguras, sem exigir administrador:
      1. Limpa %TEMP% (arquivos com mais de 1 dia)
      2. Limpa C:\Windows\Temp (mesma regra; o que não tiver permissão é pulado)
      3. Limpa o cache do Chrome e do Edge (Cache, Code Cache e GPUCache dos perfis
         Default e "Profile *", e os caches de gráficos do navegador), pulando o
         navegador se ele estiver aberto
      4. Limpa relatórios de erro antigos (WER, CrashDumps) e o cache DirectX (D3DSCache)
      5. ipconfig /flushdns
      6. Diagnóstico, nota de saúde e status do sistema (somente leitura)
      7. Abre o Gerenciador de Tarefas na aba Inicialização (não desativa nada sozinho)

    Não mexe em registro, serviços, plano de energia, efeitos visuais ou políticas.
    Não toca em Lixeira, Downloads, Documentos, histórico, senhas, cookies ou favoritos.
    Não toca em áudio/microfone (drivers e dispositivos) nem nos dados do WhatsApp.
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
$script:Versao           = '1.2.0'
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
# Caches de gráficos na raiz do "User Data" do Chrome/Edge (o navegador recria sozinho)
$script:PastasCacheRaiz = @('GrShaderCache', 'ShaderCache', 'GraphiteDawnCache')
# Trava de segurança: só estas pastas (pelo nome final) podem ser limpas
$script:FolhasAceitas = @('Temp', 'Tmp', 'Cache', 'Code Cache', 'GPUCache', 'GrShaderCache', 'ShaderCache', 'GraphiteDawnCache',
                          'ReportArchive', 'ReportQueue', 'CrashDumps', 'D3DSCache')

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
    # $null -ne: uma lista vazia conta como "falso" no PowerShell
    if ($null -ne $script:FilaLog) { [void]$script:FilaLog.Add(('[{0:HH:mm:ss}] {1}' -f (Get-Date), $Texto)) }
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
    foreach ($nome in $script:PastasCacheRaiz) {
        $c = Join-Path $DadosUsuario $nome
        if ([System.IO.Directory]::Exists($c)) { $lista += $c }
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

# "Explicacao" é o texto em linguagem simples mostrado em "O que será feito?" e ao passar o mouse.
$script:Acoes = @(
    [pscustomobject]@{
        Id = 'TempUsuario'; Tipo = 'Pasta'; Nome = 'Temporários do usuário'; Icone = [char]0xE74D; Cor = '#2563EB'
        Titulo = 'Limpar arquivos temporários do usuário (%TEMP%)'
        Descricao = 'Só arquivos com mais de 1 dia. Arquivos em uso são pulados.'
        Explicacao = 'Os programas criam arquivos temporários enquanto funcionam e muitas vezes esquecem de apagar. Com o tempo eles só ocupam espaço. Só saem os que têm mais de 1 dia e não estão em uso.'
        Dias = 1; Processo = $null; Caminhos = @($env:TEMP); DadosUsuario = $null
    }
    [pscustomobject]@{
        Id = 'TempWindows'; Tipo = 'Pasta'; Nome = 'Temporários do Windows'; Icone = [char]0xE8B7; Cor = '#7C3AED'
        Titulo = 'Limpar temporários do Windows (C:\Windows\Temp)'
        Descricao = 'Só arquivos com mais de 1 dia. O que não tiver permissão é pulado.'
        Explicacao = 'A mesma ideia, mas para os temporários do próprio Windows e de instaladores. Sobras de instalações e atualizações que já terminaram.'
        Dias = 1; Processo = $null; Caminhos = @(Join-Path $env:windir 'Temp'); DadosUsuario = $null
    }
    [pscustomobject]@{
        Id = 'Chrome'; Tipo = 'Pasta'; Nome = 'Google Chrome'; Icone = [char]0xE774; Cor = '#EA4335'
        Titulo = 'Limpar cache do Google Chrome'
        Descricao = 'Só arquivos guardados de sites. Histórico, senhas, cookies e favoritos não são tocados. Pulado se estiver aberto.'
        Explicacao = 'O Chrome guarda cópias de imagens e partes dos sites para abrir mais rápido. Esse cache cresce e pode deixar o navegador pesado. Você continua logado em tudo (CRM, e-mail, WhatsApp Web): senhas, cookies, histórico e favoritos ficam. Na primeira vez, o site pode demorar um pouco mais para abrir.'
        Dias = 0; Processo = 'chrome'; Caminhos = @(); DadosUsuario = (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data')
    }
    [pscustomobject]@{
        Id = 'Edge'; Tipo = 'Pasta'; Nome = 'Microsoft Edge'; Icone = [char]0xE909; Cor = '#0EA5E9'
        Titulo = 'Limpar cache do Microsoft Edge'
        Descricao = 'Mesma regra do Chrome. Pulado se o Edge estiver aberto.'
        Explicacao = 'O mesmo que no Chrome, para o Edge: só as cópias de imagens e partes de sites. Logins, senhas, histórico e favoritos ficam.'
        Dias = 0; Processo = 'msedge'; Caminhos = @(); DadosUsuario = (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data')
    }
    [pscustomobject]@{
        Id = 'Erros'; Tipo = 'Pasta'; Nome = 'Relatórios de erro'; Icone = [char]0xE7BA; Cor = '#D97706'
        Titulo = 'Limpar relatórios de erro do Windows'
        Descricao = 'Relatórios de travamentos antigos (mais de 1 dia). O Windows não precisa mais deles.'
        Explicacao = 'Quando um programa trava, o Windows guarda um relatório e às vezes uma cópia da memória. Depois de enviados à Microsoft, eles só ocupam espaço, às vezes bastante.'
        Dias = 1; Processo = $null; DadosUsuario = $null
        Caminhos = @((Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WER\ReportArchive'), (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\WER\ReportQueue'), (Join-Path $env:LOCALAPPDATA 'CrashDumps'))
    }
    [pscustomobject]@{
        Id = 'Graficos'; Tipo = 'Pasta'; Nome = 'Cache de gráficos'; Icone = [char]0xE7F4; Cor = '#DB2777'
        Titulo = 'Limpar cache de gráficos (DirectX)'
        Descricao = 'Arquivos que o Windows recria sozinho. Arquivos em uso são pulados.'
        Explicacao = 'Pequenos arquivos que o Windows usa para desenhar janelas e vídeos mais rápido. Com o tempo acumulam versões antigas. O Windows recria o que precisar na próxima vez.'
        Dias = 1; Processo = $null; Caminhos = @(Join-Path $env:LOCALAPPDATA 'D3DSCache'); DadosUsuario = $null
    }
    [pscustomobject]@{
        Id = 'DNS'; Tipo = 'DNS'; Nome = 'Cache de DNS'; Icone = [char]0xE839; Cor = '#0F766E'
        Titulo = 'Limpar cache de DNS (ipconfig /flushdns)'
        Descricao = 'Ajuda quando um site não abre. O Windows recria o cache sozinho, não precisa desfazer.'
        Explicacao = 'O DNS é a "agenda" que o PC usa para achar os sites. Às vezes ela guarda um endereço velho e o site não abre. Limpar faz o PC procurar o endereço certo de novo. Não muda nenhuma configuração.'
        Dias = 0; Processo = $null; Caminhos = @(); DadosUsuario = $null
    }
)

$script:AvisoSeguranca = 'Nenhuma ação mexe em áudio, microfone, WhatsApp, programas da empresa, senhas ou arquivos pessoais. E tudo pode ser desfeito.'

function Obter-PastasDaAcao {
    param($Acao)
    $pastas = @()
    foreach ($c in $Acao.Caminhos) { if ($c) { $pastas += $c } }
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
    # Devolve a nota e a lista de descontos (para explicar "por que essa nota").
    param($Diag)
    $descontos = New-Object 'System.Collections.Generic.List[object]'
    function Descontar([int]$Pontos, [string]$Motivo) { $descontos.Add([pscustomobject]@{ Pontos = $Pontos; Motivo = $Motivo }) }

    if ($Diag.RamUsoPct -ge 90) { Descontar 25 "Memória em uso muito alta ($($Diag.RamUsoPct)%)" }
    elseif ($Diag.RamUsoPct -ge 80) { Descontar 15 "Memória em uso alta ($($Diag.RamUsoPct)%)" }
    elseif ($Diag.RamUsoPct -ge 70) { Descontar 5 "Memória em uso um pouco alta ($($Diag.RamUsoPct)%)" }
    if ($Diag.RamTotalGB -gt 0 -and $Diag.RamTotalGB -le 4.5) { Descontar 20 "Pouca memória instalada ($($Diag.RamTotalGB) GB)" }
    elseif ($Diag.RamTotalGB -gt 0 -and $Diag.RamTotalGB -le 8.5) { Descontar 10 "Memória instalada justa ($($Diag.RamTotalGB) GB)" }
    if ($Diag.TemHDD) { Descontar 20 'Disco HDD (mais lento que SSD)' }
    if ($Diag.CLivrePct -ge 0) {
        if ($Diag.CLivrePct -lt 8) { Descontar 25 "Disco C: quase cheio ($($Diag.CLivrePct)% livre)" }
        elseif ($Diag.CLivrePct -lt 15) { Descontar 15 "Pouco espaço no C: ($($Diag.CLivrePct)% livre)" }
        elseif ($Diag.CLivrePct -lt 25) { Descontar 5 "Espaço no C: ficando curto ($($Diag.CLivrePct)% livre)" }
    }
    if ($Diag.DiasLigado -ge 7) { Descontar 5 "PC ligado há $($Diag.DiasLigado) dias sem reiniciar" }
    # O que a limpeza resolve: lixo acumulado e tempo sem limpar
    if ($Diag.LixoBytes -ge 2GB) { Descontar 15 "Muito lixo acumulado ($(Formatar-Tamanho $Diag.LixoBytes) para limpar)" }
    elseif ($Diag.LixoBytes -ge 1GB) { Descontar 10 "Lixo acumulado ($(Formatar-Tamanho $Diag.LixoBytes) para limpar)" }
    elseif ($Diag.LixoBytes -ge 300MB) { Descontar 5 "Um pouco de lixo acumulado ($(Formatar-Tamanho $Diag.LixoBytes) para limpar)" }
    if ($Diag.DiasDesdeLimpeza -lt 0) { Descontar 5 'Nenhuma limpeza feita ainda neste PC' }
    elseif ($Diag.DiasDesdeLimpeza -gt 14) { Descontar 5 "Última limpeza há $($Diag.DiasDesdeLimpeza) dias" }

    $total = ($descontos | Measure-Object -Property Pontos -Sum).Sum
    return [pscustomobject]@{ Nota = [int][math]::Max(0, [math]::Min(100, 100 - $total)); Descontos = $descontos }
}

function Obter-Diagnostico {
    # $DiasDesdeLimpeza: -1 = nunca limpou (vem do histórico, que fica na thread da janela)
    param([int]$DiasDesdeLimpeza = -1)
    $d = [pscustomobject]@{
        Modelo = ''; Processador = ''; RamTotalGB = 0; RamUsoPct = 0; TemHDD = $false; CLivrePct = -1
        LixoBytes = [long]0; DiasDesdeLimpeza = $DiasDesdeLimpeza; DiasLigado = 0; Descontos = @()
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
        try {
            $d.DiasLigado = [int][math]::Floor(((Get-Date) - $os.LastBootUpTime).TotalDays)
            $l.Add("Ligado há:    $($d.DiasLigado) dia(s) sem reiniciar")
            if ($d.DiasLigado -ge 7) { $d.Dicas.Add("O PC está há $($d.DiasLigado) dias sem reiniciar. Reiniciar (não só desligar) libera a memória. Veja em Ferramentas.") }
        } catch { }
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

    # Quanto dá para limpar agora (só contagem, nada é alterado)
    foreach ($acao in $script:Acoes) {
        if ($acao.Tipo -eq 'Pasta') { $d.LixoBytes += (Analisar-Acao $acao).Bytes }
    }
    $l.Add('')
    $l.Add(('Para limpar:  {0} em arquivos temporários e cache' -f (Formatar-Tamanho $d.LixoBytes)))
    if ($d.LixoBytes -ge 300MB) { $d.Dicas.Insert(0, ('Há {0} de arquivos temporários e cache para limpar. Clique em Otimizar.' -f (Formatar-Tamanho $d.LixoBytes))) }

    $resultadoNota = Calcular-NotaSaude $d
    $d.Nota = $resultadoNota.Nota
    $d.Descontos = @($resultadoNota.Descontos)
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

function Obter-Monitor {
    # Leitura detalhada para o Monitor (contadores de desempenho do Windows, sem administrador).
    # Cada consulta leva ~300 ms, então a leitura é dividida em 4 partes que rodam ao mesmo tempo
    # ($Parte 1 a 4; 0 = tudo de uma vez).
    param([int]$Parte = 0)
    $m = [ordered]@{
        Cpu = -1; Nucleos = @(); ClockAtual = 0; ClockMax = 0; NucleosFisicos = 0; Processos = 0; Threads = 0
        Memoria = -1; MemTotal = 0; MemLivre = 0; Cache = 0; Comprometida = 0; LimiteComprometida = 0
        DiscoAtivo = -1; Leitura = 0; Gravacao = 0; CLivrePct = -1
        RedeDown = 0; RedeUp = 0; Adaptador = ''; Link = 0; IP = ''; Wifi = ''; Sinal = -1
        Temperatura = -1; Gpu = -1
    }
    if ($Parte -in 0, 1) { try {
        $cpus = @(Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -ErrorAction Stop)
        $m.Cpu = [int]($cpus | Where-Object { $_.Name -eq '_Total' }).PercentProcessorTime
        $m.Nucleos = @($cpus | Where-Object { $_.Name -ne '_Total' } | Sort-Object { [int]$_.Name } | ForEach-Object { [int]$_.PercentProcessorTime })
    } catch { } }
    if ($Parte -in 0, 4) { try {
        # Dados fixos do processador: lidos uma vez e guardados (o runspace do pool é reaproveitado)
        if (-not $global:ProcessadorFixo) {
            $proc = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
            $global:ProcessadorFixo = @{ Base = [int]$proc.MaxClockSpeed; Nucleos = [int]$proc.NumberOfCores }
        }
        $m.ClockMax = $global:ProcessadorFixo.Base; $m.NucleosFisicos = $global:ProcessadorFixo.Nucleos
        $info = Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'" -ErrorAction Stop
        $m.ClockAtual = [int]($m.ClockMax * [double]$info.PercentProcessorPerformance / 100)
    } catch { } }
    if ($Parte -in 0, 2) { try {
        $sis = Get-CimInstance Win32_PerfFormattedData_PerfOS_System -ErrorAction Stop
        $m.Processos = [int]$sis.Processes; $m.Threads = [int]$sis.Threads
    } catch { } }
    if ($Parte -in 0, 2) { try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $m.MemTotal = [long]$os.TotalVisibleMemorySize * 1KB; $m.MemLivre = [long]$os.FreePhysicalMemory * 1KB
        $m.Memoria = [int][math]::Round(100 * (1 - $m.MemLivre / $m.MemTotal))
        $mem = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -ErrorAction Stop
        $m.Cache = [long]$mem.CacheBytes; $m.Comprometida = [long]$mem.CommittedBytes; $m.LimiteComprometida = [long]$mem.CommitLimit
    } catch { } }
    if ($Parte -in 0, 3) { try {
        $disco = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'" -ErrorAction Stop
        $m.DiscoAtivo = [int][math]::Min(100, [double]$disco.PercentDiskTime)
        $m.Leitura = [long]$disco.DiskReadBytesPersec; $m.Gravacao = [long]$disco.DiskWriteBytesPersec
        $c = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
        $m.CLivrePct = [int][math]::Round(100 * $c.FreeSpace / $c.Size)
    } catch { } }
    if ($Parte -in 0, 3) { try {
        foreach ($rede in @(Get-CimInstance Win32_PerfFormattedData_Tcpip_NetworkInterface -ErrorAction Stop)) {
            $m.RedeDown += [double]$rede.BytesReceivedPersec * 8 / 1e6
            $m.RedeUp += [double]$rede.BytesSentPersec * 8 / 1e6
        }
        $ativa = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | Where-Object {
            $_.OperationalStatus -eq 'Up' -and $_.NetworkInterfaceType -ne 'Loopback' -and @($_.GetIPProperties().GatewayAddresses).Count -gt 0
        } | Select-Object -First 1
        if ($ativa) {
            $m.Adaptador = if ($ativa.NetworkInterfaceType -eq 'Wireless80211') { 'Wi-Fi' } else { 'Cabo de rede' }
            $m.Link = [int]($ativa.Speed / 1e6)
            $ip = $ativa.GetIPProperties().UnicastAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
            if ($ip) { $m.IP = $ip.Address.ToString() }
            if ($ativa.NetworkInterfaceType -eq 'Wireless80211') {
                # netsh só lê (nome da rede e sinal); sem janela de console
                $psi = New-Object System.Diagnostics.ProcessStartInfo('netsh.exe', 'wlan show interfaces')
                $psi.CreateNoWindow = $true; $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true
                $p = [System.Diagnostics.Process]::Start($psi)
                $saida = $p.StandardOutput.ReadToEnd(); $p.WaitForExit()
                if ($saida -match '(?m)^\s*SSID\s*:\s*(.+?)\s*$') { $m.Wifi = $Matches[1] }
                if ($saida -match '(?m)^\s*(Sinal|Signal)\s*:\s*(\d+)\s*%') { $m.Sinal = [int]$Matches[2] }
            }
        }
    } catch { } }
    if ($Parte -in 0, 4) { try {
        # Zonas térmicas do Windows (em Kelvin); fica a maior. Nem todo PC tem.
        $zonas = @(Get-CimInstance Win32_PerfFormattedData_Counters_ThermalZoneInformation -ErrorAction Stop | Where-Object { $_.Temperature -gt 0 })
        if ($zonas.Count) { $m.Temperatura = [int][math]::Round((($zonas | Measure-Object -Property Temperature -Maximum).Maximum) - 273.15) }
    } catch { } }
    if ($Parte -in 0, 4) { try {
        $motores = @(Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -ErrorAction Stop | Where-Object { $_.Name -like '*engtype_3D' })
        if ($motores.Count) { $m.Gpu = [int][math]::Min(100, ($motores | Measure-Object -Property UtilizationPercentage -Sum).Sum) }
    } catch { } }
    $m.Parte = $Parte
    return [pscustomobject]$m
}

function Obter-InfoSistema {
    # Tempo ligado desde o último reinício e bateria (só leitura)
    $i = [pscustomobject]@{ Ligado = [timespan]::Zero; TemBateria = $false; Carga = -1; Carregando = $false; SaudePct = -1 }
    try { $i.Ligado = (Get-Date) - (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime } catch { }
    try {
        $b = Get-CimInstance Win32_Battery -ErrorAction Stop | Select-Object -First 1
        if ($b) {
            $i.TemBateria = $true; $i.Carga = [int]$b.EstimatedChargeRemaining
            $i.Carregando = $b.BatteryStatus -in 2, 6, 7, 8, 9
            try {
                $cheia = (Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop | Select-Object -First 1).FullChargedCapacity
                $projeto = (Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction Stop | Select-Object -First 1).DesignedCapacity
                if ($cheia -gt 0 -and $projeto -gt 0) { $i.SaudePct = [int][math]::Min(100, [math]::Round(100 * $cheia / $projeto)) }
            } catch { }
        }
    } catch { }
    return $i
}

function Obter-ProgramasPesados {
    # Programas (agrupados pelo nome) que mais usam memória; "TemJanela" = dá para fechar pelo X
    $ignorar = @('Idle', 'System', 'Registry', 'Memory Compression', 'svchost', 'csrss', 'wininit', 'winlogon', 'services', 'lsass',
                 'smss', 'dwm', 'explorer', 'MsMpEng', 'fontdrvhost', 'Otimizador', 'powershell', 'SearchHost', 'StartMenuExperienceHost')
    Get-Process -ErrorAction SilentlyContinue | Where-Object { $ignorar -notcontains $_.ProcessName } |
        Group-Object -Property ProcessName | ForEach-Object {
            [pscustomobject]@{
                Nome = $_.Name
                Titulo = ($_.Group | Where-Object { $_.MainWindowTitle } | Select-Object -First 1).MainWindowTitle
                Qtd = $_.Count
                Bytes = [long]($_.Group | Measure-Object -Property WorkingSet64 -Sum).Sum
                TemJanela = [bool]($_.Group | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero })
            }
        } | Sort-Object -Property Bytes -Descending | Select-Object -First 8
}

function Obter-ArquivosGrandes {
    # Maiores arquivos (>= 100 MB) nas pastas pessoais. Só lista; nunca segue junctions nem baixa arquivos da nuvem.
    $pastas = @(
        (Join-Path $env:USERPROFILE 'Downloads'),
        [Environment]::GetFolderPath('Desktop'),
        [Environment]::GetFolderPath('MyDocuments'),
        [Environment]::GetFolderPath('MyVideos')
    ) | Select-Object -Unique
    # Pula pastas ocultas/de sistema (dados internos de programas) e pastas de desenvolvimento; no máximo 25 s
    $ocultaOuSistema = [System.IO.FileAttributes]::Hidden -bor [System.IO.FileAttributes]::System
    $pularNomes = @('node_modules', 'AppData')   # e toda pasta que começa com "." (.git, .next, .cache...)
    $relogio = [System.Diagnostics.Stopwatch]::StartNew()
    $achados = New-Object System.Collections.Generic.List[object]
    foreach ($pasta in $pastas) {
        if (-not $pasta -or -not [System.IO.Directory]::Exists($pasta)) { continue }
        $pilha = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
        $pilha.Push((New-Object System.IO.DirectoryInfo($pasta)))
        while ($pilha.Count -gt 0 -and $relogio.Elapsed.TotalSeconds -lt 25) {
            $atual = $pilha.Pop()
            try { $itens = $atual.GetFileSystemInfos() } catch { continue }
            foreach ($item in $itens) {
                if (Test-PontoDeReanalise $item) { continue }
                if ($item.Attributes -band $ocultaOuSistema) { continue }
                if ($item -is [System.IO.DirectoryInfo]) {
                    if ($pularNomes -notcontains $item.Name -and -not $item.Name.StartsWith('.')) { $pilha.Push($item) }
                }
                elseif ($item.Length -ge 100MB) { $achados.Add([pscustomobject]@{ Caminho = $item.FullName; Nome = $item.Name; Bytes = $item.Length; Data = $item.LastWriteTime }) }
            }
        }
    }
    $achados | Sort-Object -Property Bytes -Descending | Select-Object -First 15
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
    # Guarda as ações DESLIGADAS: ações novas de versões futuras já vêm ligadas.
    $config = [pscustomobject]@{ AcoesDesligadas = @(); VerificarAtualizacoes = $true }
    if ($c) {
        if ($null -ne $c.AcoesDesligadas) { $config.AcoesDesligadas = @($c.AcoesDesligadas) }
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
    'Calcular-NotaSaude', 'Obter-Diagnostico', 'Obter-StatusSistema', 'Obter-Monitor', 'Obter-InfoSistema',
    'Obter-ProgramasPesados', 'Obter-ArquivosGrandes'
)
$script:VariaveisSegundoPlano = @('Acoes', 'PastaApp', 'PastaBackup', 'PastasCache', 'PastasCacheRaiz', 'FolhasAceitas', 'FilaLog')

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
    $script:Pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, 6, $iss, $Host)
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
        # Durante a animação, mostra o que está sendo limpo agora (linhas "Nome...")
        if ($script:UI.Overlay.Visibility -eq 'Visible') {
            foreach ($linha in $linhas) {
                foreach ($acao in $script:Acoes) {
                    if ($linha -like "*] $($acao.Nome)...") { $script:UI.TxtAnimDetalhe.Text = "Limpando: $($acao.Nome)" }
                }
            }
        }
    }

    if ($script:TesteInternet) { Atualizar-TesteInternet $script:TesteInternet }
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
              <RadioButton x:Name="NavMonitor" Style="{StaticResource Menu}" Tag="&#xE9D2;" Content="Monitor"/>
              <RadioButton x:Name="NavFerramentas" Style="{StaticResource Menu}" Tag="&#xE90F;" Content="Ferramentas"/>
              <RadioButton x:Name="NavInternet" Style="{StaticResource Menu}" Tag="&#xE701;" Content="Teste de internet"/>
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
                         Text="Escolha o que limpar e clique em Otimizar. Nada mexe em áudio, microfone ou WhatsApp, e tudo pode ser desfeito."/>
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
                      <Button x:Name="BtnExplicar" Cursor="Hand" HorizontalAlignment="Left" Margin="0,3,0,0"
                              ToolTip="Explica em palavras simples cada ação marcada">
                        <Button.Template>
                          <ControlTemplate TargetType="Button"><ContentPresenter/></ControlTemplate>
                        </Button.Template>
                        <TextBlock Text="O que será feito?" Foreground="#4F9BFF" FontSize="12" TextDecorations="Underline"/>
                      </Button>
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

              <Border x:Name="CartaoStatus" Style="{StaticResource EstiloCartao}" Margin="0,12,0,0" Cursor="Hand"
                      ToolTip="Clique para ver o monitor completo: temperatura, núcleos, rede ao vivo e gráficos">
                <StackPanel>
                  <DockPanel Margin="0,0,0,10">
                    <TextBlock DockPanel.Dock="Right" Text="Detalhes &#xE76C;" Foreground="#4F9BFF" FontSize="11" VerticalAlignment="Center"
                               FontFamily="Segoe UI, Segoe MDL2 Assets"/>
                    <TextBlock Text="&#xE9D9;" Style="{StaticResource Icone}" Foreground="#4F9BFF" FontSize="15" Margin="0,0,10,0"/>
                    <TextBlock Text="Status do sistema" Style="{StaticResource Titulo}" FontSize="14"/>
                  </DockPanel>
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
                  <TextBlock Text="Por que essa nota" Style="{StaticResource Titulo}" FontSize="14" Margin="0,16,0,8"/>
                  <StackPanel x:Name="ListaDescontos"/>
                  <TextBlock Text="Dicas" Style="{StaticResource Titulo}" FontSize="14" Margin="0,14,0,8"/>
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

          <!-- Página: Monitor do sistema (cartões criados em Criar-Monitor) -->
          <Grid x:Name="PaginaMonitor" Visibility="Collapsed">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <DockPanel Margin="0,0,0,12">
              <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
                <Ellipse x:Name="PontoAoVivo" Width="8" Height="8" Fill="#EF4444" Margin="0,0,6,0"/>
                <TextBlock Text="AO VIVO · últimos 60 s" Style="{StaticResource TextoSuave}" FontSize="11"/>
              </StackPanel>
              <StackPanel>
                <TextBlock Text="Monitor do sistema" FontSize="24" FontWeight="Bold"/>
                <TextBlock Style="{StaticResource TextoSuave}" FontSize="13" Text="Tudo em tempo real, atualizado a cada segundo. Só leitura."/>
              </StackPanel>
            </DockPanel>
            <UniformGrid x:Name="GradeMonitor" Grid.Row="1" Columns="2" Rows="3"/>
          </Grid>

          <!-- Página: Ferramentas -->
          <ScrollViewer x:Name="PaginaFerramentas" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" Padding="0,0,8,0">
            <StackPanel>
              <TextBlock Text="Ferramentas" FontSize="24" FontWeight="Bold"/>
              <TextBlock Style="{StaticResource TextoSuave}" FontSize="13" Margin="0,0,0,14"
                         Text="Atalhos que ajudam no dia a dia. Nada é apagado ou desligado sem você decidir."/>
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0" Margin="0,0,8,0">
                  <Border Style="{StaticResource EstiloCartao}">
                    <StackPanel>
                      <TextBlock Text="Memória do navegador" Style="{StaticResource Titulo}" FontSize="14"/>
                      <TextBlock Style="{StaticResource TextoSuave}" Margin="0,4,0,10"
                                 Text="Ligue a economia de memória: as abas paradas deixam de ocupar memória, e você continua logado em tudo. O botão só abre a configuração; quem liga é você."/>
                      <StackPanel Orientation="Horizontal">
                        <Button x:Name="BtnMemoriaChrome" Style="{StaticResource BotaoContorno}" Height="36" Margin="0,0,8,0" Content="Abrir no Chrome"/>
                        <Button x:Name="BtnMemoriaEdge" Style="{StaticResource BotaoContorno}" Height="36" Content="Abrir no Edge"/>
                      </StackPanel>
                    </StackPanel>
                  </Border>
                  <Border Style="{StaticResource EstiloCartao}" Margin="0,12,0,0">
                    <StackPanel>
                      <DockPanel>
                        <Button x:Name="BtnAtualizarProgramas" DockPanel.Dock="Right" Style="{StaticResource Botao}" Padding="10,4" FontSize="11" Content="Atualizar"/>
                        <TextBlock Text="Programas usando mais memória" Style="{StaticResource Titulo}" FontSize="14" VerticalAlignment="Center"/>
                      </DockPanel>
                      <TextBlock Style="{StaticResource TextoSuave}" Margin="0,4,0,10"
                                 Text="&quot;Fechar&quot; é o mesmo que clicar no X do programa: ele pergunta se quer salvar."/>
                      <StackPanel x:Name="ListaProgramas"/>
                    </StackPanel>
                  </Border>
                  <Border Style="{StaticResource EstiloCartao}" Margin="0,12,0,0">
                    <StackPanel>
                      <TextBlock Text="Áudio e microfone" Style="{StaticResource Titulo}" FontSize="14"/>
                      <TextBlock Style="{StaticResource TextoSuave}" Margin="0,4,0,10"
                                 Text="Ninguém te ouve? Confira se o microfone certo está escolhido e se os apps têm permissão para usá-lo."/>
                      <WrapPanel>
                        <Button x:Name="BtnTestarMicrofone" Style="{StaticResource BotaoContorno}" Height="36" Margin="0,0,8,8" Content="Testar microfone"/>
                        <Button x:Name="BtnPermissaoMicrofone" Style="{StaticResource BotaoContorno}" Height="36" Margin="0,0,8,8" Content="Permissão do microfone"/>
                        <Button x:Name="BtnPainelSom" Style="{StaticResource BotaoContorno}" Height="36" Margin="0,0,8,8" Content="Painel de som"/>
                      </WrapPanel>
                    </StackPanel>
                  </Border>
                </StackPanel>
                <StackPanel Grid.Column="1" Margin="8,0,0,0">
                  <Border Style="{StaticResource EstiloCartao}">
                    <StackPanel>
                      <TextBlock Text="Reinício e bateria" Style="{StaticResource Titulo}" FontSize="14"/>
                      <TextBlock x:Name="TxtTempoLigado" FontSize="13" FontWeight="SemiBold" Margin="0,6,0,0" TextWrapping="Wrap"/>
                      <TextBlock Style="{StaticResource TextoSuave}" Margin="0,4,0,10"
                                 Text="Reiniciar libera a memória de verdade. &quot;Desligar&quot; não basta: com a inicialização rápida do Windows, a memória não é zerada."/>
                      <Button x:Name="BtnReiniciar" Style="{StaticResource BotaoContorno}" Height="36" HorizontalAlignment="Left" Content="Reiniciar agora"/>
                      <TextBlock x:Name="TxtBateria" Style="{StaticResource TextoSuave}" FontSize="12.5" Margin="0,12,0,0"/>
                    </StackPanel>
                  </Border>
                  <Border Style="{StaticResource EstiloCartao}" Margin="0,12,0,0">
                    <StackPanel>
                      <TextBlock Text="Arquivos grandes" Style="{StaticResource Titulo}" FontSize="14"/>
                      <TextBlock Style="{StaticResource TextoSuave}" Margin="0,4,0,10"
                                 Text="Os maiores arquivos em Downloads, Área de Trabalho, Documentos e Vídeos. O app não apaga nada: você vê e decide."/>
                      <Button x:Name="BtnArquivosGrandes" Style="{StaticResource BotaoContorno}" Height="36" HorizontalAlignment="Left" Content="Procurar arquivos grandes"/>
                      <StackPanel x:Name="ListaArquivosGrandes" Margin="0,10,0,0"/>
                    </StackPanel>
                  </Border>
                </StackPanel>
              </Grid>
            </StackPanel>
          </ScrollViewer>

          <!-- Página: Teste de internet -->
          <Grid x:Name="PaginaInternet" Visibility="Collapsed">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <StackPanel Margin="0,0,0,14">
              <TextBlock Text="Teste de internet" FontSize="24" FontWeight="Bold"/>
              <TextBlock Style="{StaticResource TextoSuave}" FontSize="13"
                         Text="Mede a velocidade da sua conexão. Cada teste usa até cerca de 130 MB de internet."/>
            </StackPanel>
            <Grid Grid.Row="1">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="330"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <Border Style="{StaticResource EstiloCartao}" Padding="20" VerticalAlignment="Top">
                <StackPanel>
                  <!-- Velocímetro: arco de 240°, marcas, ponteiro e valor no centro (desenhado em Montar-Velocimetro) -->
                  <Canvas Width="290" Height="238" HorizontalAlignment="Center">
                    <Path x:Name="ArcoFundoInternet" Stroke="#1F2C45" StrokeThickness="14" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                    <Path x:Name="ArcoInternet" StrokeThickness="14" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                    <Canvas x:Name="MarcasVelocimetro"/>
                    <Path x:Name="Ponteiro" Data="M140,135 L145,42 L150,135 Z">
                      <Path.Fill>
                        <LinearGradientBrush StartPoint="0,1" EndPoint="0,0">
                          <GradientStop Color="#8A97AD" Offset="0"/>
                          <GradientStop Color="#FFFFFF" Offset="1"/>
                        </LinearGradientBrush>
                      </Path.Fill>
                      <Path.RenderTransform><RotateTransform CenterX="145" CenterY="135" Angle="-120"/></Path.RenderTransform>
                    </Path>
                    <Ellipse Canvas.Left="133" Canvas.Top="123" Width="24" Height="24" Fill="#111A2B" Stroke="#FFFFFF" StrokeThickness="3"/>
                    <StackPanel Canvas.Left="70" Canvas.Top="184" Width="150">
                      <TextBlock x:Name="TxtVelocidade" Text="0" FontSize="34" FontWeight="Bold" HorizontalAlignment="Center"/>
                      <TextBlock x:Name="TxtUnidadeFase" Text="Mbps" Style="{StaticResource TextoSuave}" FontSize="12" HorizontalAlignment="Center"/>
                    </StackPanel>
                  </Canvas>
                  <TextBlock x:Name="TxtFaseTeste" Text="Pronto para testar" FontSize="15" FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,14,0,0"/>
                  <Button x:Name="BtnTestarInternet" Style="{StaticResource BotaoPrincipal}" Margin="0,16,0,0">
                    <StackPanel Orientation="Horizontal">
                      <TextBlock Text="&#xE768;" Style="{StaticResource Icone}" Margin="0,0,10,0"/>
                      <TextBlock x:Name="TxtBtnTestar" Text="Iniciar teste"/>
                    </StackPanel>
                  </Button>
                  <TextBlock x:Name="TxtServidorTeste" Style="{StaticResource TextoSuave}" FontSize="11" HorizontalAlignment="Center" TextAlignment="Center" Margin="0,10,0,0"
                             Text="Servidor de teste: Cloudflare"/>
                </StackPanel>
              </Border>
              <StackPanel Grid.Column="1" Margin="16,0,0,0">
                <UniformGrid Columns="2">
                  <Border Style="{StaticResource EstiloCartao}" Margin="0,0,6,12">
                    <StackPanel>
                      <StackPanel Orientation="Horizontal">
                        <TextBlock Text="&#xE896;" Style="{StaticResource Icone}" Foreground="#22C55E" FontSize="15" Margin="0,0,8,0"/>
                        <TextBlock Text="Download" Style="{StaticResource TextoSuave}" FontSize="13"/>
                      </StackPanel>
                      <TextBlock x:Name="TxtDownload" Text="--" FontSize="26" FontWeight="Bold" Margin="0,6,0,0"/>
                      <TextBlock Text="Mbps · receber (sites, vídeos)" Style="{StaticResource TextoSuave}" FontSize="11"/>
                    </StackPanel>
                  </Border>
                  <Border Style="{StaticResource EstiloCartao}" Margin="6,0,0,12">
                    <StackPanel>
                      <StackPanel Orientation="Horizontal">
                        <TextBlock Text="&#xE898;" Style="{StaticResource Icone}" Foreground="#4F9BFF" FontSize="15" Margin="0,0,8,0"/>
                        <TextBlock Text="Upload" Style="{StaticResource TextoSuave}" FontSize="13"/>
                      </StackPanel>
                      <TextBlock x:Name="TxtUpload" Text="--" FontSize="26" FontWeight="Bold" Margin="0,6,0,0"/>
                      <TextBlock Text="Mbps · enviar (sua voz, arquivos)" Style="{StaticResource TextoSuave}" FontSize="11"/>
                    </StackPanel>
                  </Border>
                  <Border Style="{StaticResource EstiloCartao}" Margin="0,0,6,12">
                    <StackPanel>
                      <StackPanel Orientation="Horizontal">
                        <TextBlock Text="&#xE916;" Style="{StaticResource Icone}" Foreground="#FACC15" FontSize="15" Margin="0,0,8,0"/>
                        <TextBlock Text="Ping" Style="{StaticResource TextoSuave}" FontSize="13"/>
                      </StackPanel>
                      <TextBlock x:Name="TxtPing" Text="--" FontSize="26" FontWeight="Bold" Margin="0,6,0,0"/>
                      <TextBlock Text="ms · tempo de resposta" Style="{StaticResource TextoSuave}" FontSize="11"/>
                    </StackPanel>
                  </Border>
                  <Border Style="{StaticResource EstiloCartao}" Margin="6,0,0,12">
                    <StackPanel>
                      <StackPanel Orientation="Horizontal">
                        <TextBlock Text="&#xE9D9;" Style="{StaticResource Icone}" Foreground="#DB2777" FontSize="15" Margin="0,0,8,0"/>
                        <TextBlock Text="Oscilação" Style="{StaticResource TextoSuave}" FontSize="13"/>
                      </StackPanel>
                      <TextBlock x:Name="TxtJitter" Text="--" FontSize="26" FontWeight="Bold" Margin="0,6,0,0"/>
                      <TextBlock Text="ms · estabilidade (jitter)" Style="{StaticResource TextoSuave}" FontSize="11"/>
                    </StackPanel>
                  </Border>
                </UniformGrid>
                <Border Style="{StaticResource EstiloCartao}">
                  <StackPanel>
                    <TextBlock Text="O que isso significa" Style="{StaticResource Titulo}" FontSize="14" Margin="0,0,0,8"/>
                    <StackPanel x:Name="ListaAvaliacao">
                      <TextBlock Style="{StaticResource TextoSuave}" FontSize="12.5"
                                 Text="Clique em &quot;Iniciar teste&quot;. Leva uns 20 segundos. Evite baixar arquivos ou assistir vídeos durante o teste."/>
                    </StackPanel>
                  </StackPanel>
                </Border>
              </StackPanel>
            </Grid>
          </Grid>

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

          <!-- Animação da otimização: lixeira recebendo arquivos (cobre a área de conteúdo) -->
          <Grid x:Name="Overlay" Visibility="Collapsed" Margin="-22,-16,-22,-18" Background="#F20A101C">
            <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
              <Canvas x:Name="CanvasLixo" Width="360" Height="250">
                <Ellipse Canvas.Left="122" Canvas.Top="236" Width="116" Height="12" Fill="#40000000"/>
                <Grid x:Name="CorpoLixeira" Canvas.Left="130" Canvas.Top="118" Width="100" Height="122" RenderTransformOrigin="0.5,1">
                  <Grid.RenderTransform><RotateTransform/></Grid.RenderTransform>
                  <Path Data="M0,0 L100,0 L90,122 L10,122 Z">
                    <Path.Fill>
                      <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                        <GradientStop Color="#22C55E" Offset="0"/>
                        <GradientStop Color="#15803D" Offset="1"/>
                      </LinearGradientBrush>
                    </Path.Fill>
                  </Path>
                  <Path Data="M30,20 L33,104 M50,20 L50,104 M70,20 L67,104" Stroke="#052E16" StrokeThickness="5"
                        StrokeStartLineCap="Round" StrokeEndLineCap="Round" Opacity="0.35"/>
                </Grid>
                <Canvas x:Name="TampaLixeira" Canvas.Left="122" Canvas.Top="100">
                  <Canvas.RenderTransform><RotateTransform CenterX="0" CenterY="18"/></Canvas.RenderTransform>
                  <Border Canvas.Left="40" Canvas.Top="0" Width="36" Height="10" CornerRadius="5,5,0,0" Background="#16A34A"/>
                  <Border Canvas.Left="0" Canvas.Top="8" Width="116" Height="12" CornerRadius="6" Background="#22C55E"/>
                </Canvas>
                <Grid x:Name="SeloConcluido" Canvas.Left="140" Canvas.Top="8" Width="80" Height="80" Opacity="0" RenderTransformOrigin="0.5,0.5">
                  <Grid.RenderTransform><ScaleTransform ScaleX="0" ScaleY="0"/></Grid.RenderTransform>
                  <Ellipse Fill="#22C55E"/>
                  <TextBlock Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" FontSize="38" Foreground="White"
                             HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Grid>
              </Canvas>
              <TextBlock x:Name="TxtAnimTitulo" Text="Otimizando..." FontSize="26" FontWeight="Bold" HorizontalAlignment="Center" Margin="0,8,0,0"/>
              <TextBlock x:Name="TxtAnimDetalhe" Text="Jogando fora o que não serve mais" Style="{StaticResource TextoSuave}"
                         FontSize="13" HorizontalAlignment="Center" TextAlignment="Center" Margin="0,6,0,0"/>
              <Button x:Name="BtnFecharAnim" Style="{StaticResource BotaoPrincipal}" Width="200" Margin="0,22,0,0"
                      Content="Concluir" Visibility="Hidden"/>
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
    $borda.ToolTip = $Acao.Explicacao
    [System.Windows.Controls.ToolTipService]::SetShowDuration($borda, 30000)
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
    foreach ($p in 'PaginaInicio', 'PaginaDiagnostico', 'PaginaMonitor', 'PaginaFerramentas', 'PaginaInternet', 'PaginaHistorico', 'PaginaInicializacao', 'PaginaConfig') {
        $script:UI[$p].Visibility = if ($p -eq $Nome) { 'Visible' } else { 'Collapsed' }
    }
    if ($Nome -eq 'PaginaHistorico') { Atualizar-Historico }
    if ($Nome -eq 'PaginaMonitor') { Iniciar-LeituraMonitor }
    if ($Nome -eq 'PaginaFerramentas') { Atualizar-Programas; Atualizar-InfoSistema }
}

function Obter-Selecionadas {
    return @($script:Acoes | Where-Object { $script:UI.Chaves[$_.Id].IsChecked })
}

function Ao-Explicar {
    $acoes = Obter-Selecionadas
    if ($acoes.Count -eq 0) { [void](Mostrar-Mensagem 'Nenhuma ação marcada. Ligue as que quiser na lista "Ações de limpeza".' 'O que será feito'); return }
    $partes = foreach ($a in $acoes) { "■ $($a.Nome)`r`n$($a.Explicacao)" }
    $msg = "Ao clicar em Otimizar, o app vai:`r`n`r`n" + ($partes -join "`r`n`r`n") + "`r`n`r`n$($script:AvisoSeguranca)"
    [void](Mostrar-Mensagem $msg 'O que será feito')
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

        $icone = switch ($item.Tipo) { 'Otimizacao' { [char]0xE74D } 'Desfazer' { [char]0xE7A7 } 'Internet' { [char]0xE701 } default { [char]0xE74D } }
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

    # Por que essa nota: cada ponto perdido e o motivo
    $script:UI.ListaDescontos.Children.Clear()
    if (@($Diag.Descontos).Count -eq 0) {
        $script:UI.ListaDescontos.Children.Add((Novo-Texto 'Nenhum ponto perdido. Tudo certo!' 12.5 '#22C55E')) | Out-Null
    }
    foreach ($desc in $Diag.Descontos) {
        $linha = New-Object System.Windows.Controls.DockPanel
        $linha.Margin = Espaco 0 0 0 5
        $pontos = Novo-Texto ("−$($desc.Pontos)") 12.5 '#EF4444' 'SemiBold'
        $pontos.Width = 34; $pontos.VerticalAlignment = 'Top'
        [System.Windows.Controls.DockPanel]::SetDock($pontos, 'Left')
        $linha.Children.Add($pontos) | Out-Null
        $linha.Children.Add((Novo-Texto $desc.Motivo 12.5 '#C9D4E5')) | Out-Null
        $script:UI.ListaDescontos.Children.Add($linha) | Out-Null
    }
    $explicacao = if (@($Diag.Descontos).Count) { (@($Diag.Descontos) | ForEach-Object { "−$($_.Pontos)  $($_.Motivo)" }) -join "`r`n" } else { 'Nenhum ponto perdido.' }
    $script:UI.AnelInicio.Parent.ToolTip = "Saúde do PC: $($Diag.Nota) de 100`r`n`r`n$explicacao`r`n`r`nDetalhes na aba Diagnóstico."

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
    $ultima = Ler-Historico | Where-Object { $_.Tipo -eq 'Otimizacao' } | Select-Object -First 1
    $dias = if ($ultima) { [int][math]::Floor(((Get-Date) - [datetime]$ultima.Data).TotalDays) } else { -1 }
    Iniciar-EmSegundoPlano -Parametros @{ Dias = $dias } -Trabalho { param($Dias) Obter-Diagnostico -DiasDesdeLimpeza $Dias } -AoConcluir {
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
        $msg += "`r`n$($script:AvisoSeguranca)"
        $temBackup = [bool](Obter-InfoBackup)
        if ($temBackup) { $msg += "`r`n`r`nAtenção: o backup da limpeza anterior será apagado de vez." }
        $msg += "`r`n`r`nDeseja continuar?"
        if ((Mostrar-Mensagem $msg 'Confirmar otimização' 'YesNo' 'Question') -ne 'Yes') {
            Definir-Ocupado $false
            Escrever-Log 'Otimização cancelada. Nada foi alterado.'
            return
        }
        Definir-Ocupado $true 'Otimizando...'
        Iniciar-AnimacaoOtimizacao
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
            Concluir-AnimacaoOtimizacao $bytes $erro
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
        AcoesDesligadas = @($script:Acoes | Where-Object { -not $script:UI.ChavesConfig[$_.Id].IsChecked } | ForEach-Object { $_.Id })
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
    # Lembrete: muito tempo sem limpar
    $ultima = Ler-Historico | Where-Object { $_.Tipo -eq 'Otimizacao' } | Select-Object -First 1
    if ($ultima) {
        $dias = [int][math]::Floor(((Get-Date) - [datetime]$ultima.Data).TotalDays)
        if ($dias -gt 15) {
            $script:UI.TxtEstado.Text = "Última limpeza há $dias dias"
            Escrever-Log "Faz $dias dias da última limpeza. Que tal otimizar agora?"
        }
    }
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

# ---- Monitor do sistema (ao vivo, 1 leitura por segundo, gráfico dos últimos 60 s)

$script:CartoesMonitor = @(
    @{ Id = 'Cpu';         Titulo = 'Processador';    Icone = [char]0xE9D9; Cor = '#4F9BFF' }
    @{ Id = 'Memoria';     Titulo = 'Memória';        Icone = [char]0xE964; Cor = '#A78BFA' }
    @{ Id = 'Disco';       Titulo = 'Disco';          Icone = [char]0xEDA2; Cor = '#22C55E' }
    @{ Id = 'Rede';        Titulo = 'Rede';           Icone = [char]0xE701; Cor = '#06B6D4' }
    @{ Id = 'Temperatura'; Titulo = 'Temperatura';    Icone = [char]0xE706; Cor = '#F97316' }
    @{ Id = 'Gpu';         Titulo = 'Placa de vídeo'; Icone = [char]0xE7F4; Cor = '#EC4899' }
)
$script:HistMonitor = @{}

function Criar-Monitor {
    $script:UI.Monitor = @{}
    foreach ($c in $script:CartoesMonitor) {
        $script:HistMonitor[$c.Id] = New-Object System.Collections.Generic.List[double]
        $borda = New-Object System.Windows.Controls.Border
        $borda.Style = $script:UI.Janela.FindResource('EstiloCartao')
        $borda.Margin = Espaco 0 0 12 12
        $borda.Padding = Espaco 14 12

        $painel = New-Object System.Windows.Controls.DockPanel
        $cabecalho = New-Object System.Windows.Controls.DockPanel
        $status = Novo-Texto '...' 11.5 '#8A97AD' 'SemiBold'
        [System.Windows.Controls.DockPanel]::SetDock($status, 'Right')
        $cabecalho.Children.Add($status) | Out-Null
        $icone = Novo-Texto ([string]$c.Icone) 14 $c.Cor 'Normal' 'Segoe MDL2 Assets'
        $icone.Margin = Espaco 0 0 8 0
        $cabecalho.Children.Add($icone) | Out-Null
        $cabecalho.Children.Add((Novo-Texto $c.Titulo 13 '#8A97AD' 'SemiBold')) | Out-Null
        [System.Windows.Controls.DockPanel]::SetDock($cabecalho, 'Top')
        $painel.Children.Add($cabecalho) | Out-Null

        $linhaValor = New-Object System.Windows.Controls.DockPanel
        $linhaValor.Margin = Espaco 0 2 0 0
        $barras = New-Object System.Windows.Controls.StackPanel
        $barras.Orientation = 'Horizontal'; $barras.VerticalAlignment = 'Bottom'; $barras.Height = 26
        [System.Windows.Controls.DockPanel]::SetDock($barras, 'Right')
        $linhaValor.Children.Add($barras) | Out-Null
        $valor = Novo-Texto '--' 26 $null 'Bold'
        $linhaValor.Children.Add($valor) | Out-Null
        [System.Windows.Controls.DockPanel]::SetDock($linhaValor, 'Top')
        $painel.Children.Add($linhaValor) | Out-Null

        $detalhe = Novo-Texto '' 11.5 '#8A97AD'
        $detalhe.Margin = Espaco 0 6 0 0
        [System.Windows.Controls.DockPanel]::SetDock($detalhe, 'Bottom')
        $painel.Children.Add($detalhe) | Out-Null

        # Gráfico: área preenchida + linha
        $tela = New-Object System.Windows.Controls.Canvas
        $tela.Margin = Espaco 0 6 0 0
        $tela.ClipToBounds = $true
        $cor = [System.Windows.Media.ColorConverter]::ConvertFromString($c.Cor)
        $area = New-Object System.Windows.Shapes.Polygon
        $area.Fill = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(50, $cor.R, $cor.G, $cor.B))
        $linha = New-Object System.Windows.Shapes.Polyline
        $linha.Stroke = Pincel $c.Cor; $linha.StrokeThickness = 2; $linha.StrokeLineJoin = 'Round'
        $tela.Children.Add($area) | Out-Null
        $tela.Children.Add($linha) | Out-Null
        $painel.Children.Add($tela) | Out-Null

        $borda.Child = $painel
        $script:UI.GradeMonitor.Children.Add($borda) | Out-Null
        $script:UI.Monitor[$c.Id] = @{ Valor = $valor; Status = $status; Detalhe = $detalhe; Tela = $tela; Area = $area; Linha = $linha; Barras = $barras; Cor = $c.Cor }
    }
}

function Desenhar-Grafico {
    # $Escala: valor que encosta no topo (100 para %, ou o maior valor recente para a rede)
    param([string]$Id, [double]$Escala = 100)
    $cartao = $script:UI.Monitor[$Id]
    $dados = $script:HistMonitor[$Id]
    $largura = if ($cartao.Tela.ActualWidth -gt 0) { $cartao.Tela.ActualWidth } else { 330 }
    $altura = if ($cartao.Tela.ActualHeight -gt 10) { $cartao.Tela.ActualHeight } else { 44 }
    $passo = $largura / 59
    $pontos = New-Object System.Windows.Media.PointCollection
    $inicio = 60 - $dados.Count
    for ($i = 0; $i -lt $dados.Count; $i++) {
        $y = $altura - 2 - ([math]::Min(1, $dados[$i] / [math]::Max(0.001, $Escala)) * ($altura - 4))
        $pontos.Add((New-Object System.Windows.Point((($inicio + $i) * $passo), $y)))
    }
    $cartao.Linha.Points = $pontos
    $poligono = New-Object System.Windows.Media.PointCollection
    if ($pontos.Count -gt 1) {
        $poligono.Add((New-Object System.Windows.Point($pontos[0].X, $altura)))
        foreach ($p in $pontos) { $poligono.Add($p) }
        $poligono.Add((New-Object System.Windows.Point($pontos[$pontos.Count - 1].X, $altura)))
    }
    $cartao.Area.Points = $poligono
}

function Registrar-Ponto {
    param([string]$Id, [double]$Valor)
    $lista = $script:HistMonitor[$Id]
    $lista.Add([math]::Max(0, $Valor))
    while ($lista.Count -gt 60) { $lista.RemoveAt(0) }
}

function Definir-StatusMonitor {
    param([string]$Id, [string]$Texto, [string]$Nivel)
    $cores = @{ Normal = '#22C55E'; Atencao = '#FACC15'; Alto = '#EF4444'; Neutro = '#8A97AD' }
    $script:UI.Monitor[$Id].Status.Text = $Texto
    $script:UI.Monitor[$Id].Status.Foreground = Pincel $cores[$Nivel]
}

function Atualizar-Monitor {
    param($M)
    $ui = $script:UI.Monitor
    $rotulos = @{ Normal = 'Normal'; Atencao = 'Atenção'; Alto = 'Alto'; Neutro = '--' }

    # Processador + barrinha por núcleo
    if ($M.Cpu -ge 0) {
        $ui.Cpu.Valor.Text = "$($M.Cpu)%"
        $n = Classificar $M.Cpu 70 90; Definir-StatusMonitor 'Cpu' $rotulos[$n] $n
        Registrar-Ponto 'Cpu' $M.Cpu; Desenhar-Grafico 'Cpu'
        $partes = @()
        if ($M.NucleosFisicos) { $partes += "$($M.NucleosFisicos) núcleos ($(@($M.Nucleos).Count) threads)" }
        if ($M.ClockAtual) { $partes += ('{0:N1} GHz agora (base {1:N1} GHz)' -f ($M.ClockAtual / 1000), ($M.ClockMax / 1000)) }
        $partes += "$($M.Processos) processos · $('{0:N0}' -f $M.Threads) threads"
        $ui.Cpu.Detalhe.Text = $partes -join ' · '
        $barras = $ui.Cpu.Barras
        $nucleos = @($M.Nucleos)
        if ($barras.Children.Count -ne $nucleos.Count) {
            $barras.Children.Clear()
            foreach ($x in $nucleos) {
                $r = New-Object System.Windows.Shapes.Rectangle
                $r.Width = [math]::Max(3, [math]::Min(8, 120 / [math]::Max(1, $nucleos.Count)))
                $r.Margin = Espaco 1 0; $r.VerticalAlignment = 'Bottom'; $r.RadiusX = 1.5; $r.RadiusY = 1.5
                $r.Fill = Pincel '#4F9BFF'
                $barras.Children.Add($r) | Out-Null
            }
        }
        for ($k = 0; $k -lt $nucleos.Count; $k++) { $barras.Children[$k].Height = [math]::Max(2, 26 * $nucleos[$k] / 100) }
        $barras.ToolTip = 'Uso de cada núcleo: ' + (($nucleos | ForEach-Object { "$_%" }) -join ' · ')
    }

    # Memória
    if ($M.Memoria -ge 0) {
        $ui.Memoria.Valor.Text = "$($M.Memoria)%"
        $n = Classificar $M.Memoria 80 90; Definir-StatusMonitor 'Memoria' $rotulos[$n] $n
        Registrar-Ponto 'Memoria' $M.Memoria; Desenhar-Grafico 'Memoria'
        $ui.Memoria.Detalhe.Text = '{0} de {1} em uso · {2} livres · cache {3} · comprometida {4} de {5}' -f
            (Formatar-Tamanho ($M.MemTotal - $M.MemLivre)), (Formatar-Tamanho $M.MemTotal), (Formatar-Tamanho $M.MemLivre),
            (Formatar-Tamanho $M.Cache), (Formatar-Tamanho $M.Comprometida), (Formatar-Tamanho $M.LimiteComprometida)
    }

    # Disco
    if ($M.DiscoAtivo -ge 0) {
        $ui.Disco.Valor.Text = "$($M.DiscoAtivo)% ativo"
        $n = Classificar $M.DiscoAtivo 60 90; Definir-StatusMonitor 'Disco' $rotulos[$n] $n
        Registrar-Ponto 'Disco' $M.DiscoAtivo; Desenhar-Grafico 'Disco'
        $ui.Disco.Detalhe.Text = 'Leitura {0}/s · Gravação {1}/s · C: {2}% livre' -f (Formatar-Tamanho $M.Leitura), (Formatar-Tamanho $M.Gravacao), $M.CLivrePct
    }

    # Rede (gráfico se ajusta ao maior valor do último minuto)
    $ui.Rede.Valor.Text = '↓ {0} ↑ {1} Mbps' -f (Formatar-Mbps $M.RedeDown), (Formatar-Mbps $M.RedeUp)
    if ($M.Adaptador) { Definir-StatusMonitor 'Rede' 'Conectado' 'Normal' } else { Definir-StatusMonitor 'Rede' 'Sem conexão' 'Alto' }
    Registrar-Ponto 'Rede' $M.RedeDown
    Desenhar-Grafico 'Rede' ([math]::Max(1, ($script:HistMonitor.Rede | Measure-Object -Maximum).Maximum))
    $partes = @()
    if ($M.Adaptador -eq 'Wi-Fi' -and $M.Wifi) { $partes += "Wi-Fi ""$($M.Wifi)""" } elseif ($M.Adaptador) { $partes += $M.Adaptador }
    if ($M.Sinal -ge 0) { $partes += "sinal $($M.Sinal)%" }
    if ($M.Link) { $partes += "link $($M.Link) Mbps" }
    if ($M.IP) { $partes += "IP $($M.IP)" }
    $ui.Rede.Detalhe.Text = if ($partes) { $partes -join ' · ' } else { 'Sem rede ativa.' }

    # Temperatura (sensor térmico do Windows; nem todo PC informa)
    if ($M.Temperatura -gt 0) {
        $ui.Temperatura.Valor.Text = "$($M.Temperatura) °C"
        if ($M.Temperatura -ge 85) { Definir-StatusMonitor 'Temperatura' 'Muito quente' 'Alto' }
        elseif ($M.Temperatura -ge 70) { Definir-StatusMonitor 'Temperatura' 'Quente' 'Atencao' }
        else { Definir-StatusMonitor 'Temperatura' 'Normal' 'Normal' }
        Registrar-Ponto 'Temperatura' $M.Temperatura; Desenhar-Grafico 'Temperatura' 100
        $ui.Temperatura.Detalhe.Text = 'Sensor térmico do Windows (valor aproximado). Até 70 °C é normal em uso; acima de 85 °C, confira se as saídas de ar estão livres.'
    } else {
        $ui.Temperatura.Valor.Text = '--'
        Definir-StatusMonitor 'Temperatura' 'Indisponível' 'Neutro'
        $ui.Temperatura.Detalhe.Text = 'Este PC não informa a temperatura sem permissão de administrador.'
    }

    # Placa de vídeo
    if ($M.Gpu -ge 0) {
        $ui.Gpu.Valor.Text = "$($M.Gpu)%"
        $n = Classificar $M.Gpu 70 90; Definir-StatusMonitor 'Gpu' $rotulos[$n] $n
        Registrar-Ponto 'Gpu' $M.Gpu; Desenhar-Grafico 'Gpu'
        $ui.Gpu.Detalhe.Text = 'Uso do processador gráfico: vídeos, chamadas com câmera e telas.'
    } else {
        $ui.Gpu.Valor.Text = '--'
        Definir-StatusMonitor 'Gpu' 'Indisponível' 'Neutro'
        $ui.Gpu.Detalhe.Text = 'O Windows não informa o uso da placa de vídeo neste PC.'
    }
}

$script:CamposParteMonitor = @{
    1 = @('Cpu', 'Nucleos')
    2 = @('Processos', 'Threads', 'Memoria', 'MemTotal', 'MemLivre', 'Cache', 'Comprometida', 'LimiteComprometida')
    3 = @('DiscoAtivo', 'Leitura', 'Gravacao', 'CLivrePct', 'RedeDown', 'RedeUp', 'Adaptador', 'Link', 'IP', 'Wifi', 'Sinal')
    4 = @('ClockAtual', 'ClockMax', 'NucleosFisicos', 'Temperatura', 'Gpu')
}

function Iniciar-LeituraMonitor {
    # As 4 partes rodam ao mesmo tempo; quando todas chegam, a tela é atualizada de uma vez
    if ($script:MonitorPendentes -gt 0 -or $script:UI.PaginaMonitor.Visibility -ne 'Visible') { return }
    $script:MonitorPendentes = 4
    $script:MonitorLeitura = [pscustomobject]@{}
    $script:UI.PontoAoVivo.Opacity = if ($script:UI.PontoAoVivo.Opacity -eq 1) { 0.3 } else { 1 }
    foreach ($parte in 1..4) {
        Iniciar-EmSegundoPlano -Parametros @{ Parte = $parte } -Trabalho { param($Parte) Obter-Monitor -Parte $Parte } -AoConcluir {
            param($resultado, $erro)
            $r = $resultado | Select-Object -First 1
            if ($r) {
                foreach ($campo in $script:CamposParteMonitor[[int]$r.Parte]) {
                    $script:MonitorLeitura | Add-Member -NotePropertyName $campo -NotePropertyValue $r.$campo -Force
                }
            }
            $script:MonitorPendentes--
            if ($script:MonitorPendentes -le 0) {
                $m = $script:MonitorLeitura
                foreach ($campo in $script:CamposParteMonitor.Values | ForEach-Object { $_ }) {
                    if ($null -eq $m.$campo) { $m | Add-Member -NotePropertyName $campo -NotePropertyValue $(if ($campo -in 'Adaptador', 'IP', 'Wifi') { '' } elseif ($campo -eq 'Nucleos') { @() } else { -1 }) -Force }
                }
                Atualizar-Monitor $m
            }
        }
    }
}

# ---- Ferramentas

function Abrir-Endereco {
    # Abre configurações do Windows/navegador. Só abre; a pessoa decide o que mudar.
    param([string]$Programa, [string]$Argumento, [string]$Nome)
    try {
        if ($Argumento) { Start-Process -FilePath $Programa -ArgumentList $Argumento } else { Start-Process -FilePath $Programa }
    } catch {
        [void](Mostrar-Mensagem "Não foi possível abrir: $Nome." 'Ferramentas' 'OK' 'Warning')
    }
}

function Atualizar-Programas {
    $script:UI.ListaProgramas.Children.Clear()
    $script:UI.ListaProgramas.Children.Add((Novo-Texto 'Carregando...' 12 '#8A97AD')) | Out-Null
    Iniciar-EmSegundoPlano -Trabalho { Obter-ProgramasPesados } -AoConcluir {
        param($resultado, $erro)
        $lista = $script:UI.ListaProgramas
        $lista.Children.Clear()
        foreach ($p in $resultado) {
            $linha = New-Object System.Windows.Controls.DockPanel
            $linha.Margin = Espaco 0 0 0 6
            if ($p.TemJanela) {
                $btn = New-Object System.Windows.Controls.Button
                $btn.Style = $script:UI.Janela.FindResource('Botao')
                $btn.Padding = Espaco 10 3; $btn.FontSize = 11; $btn.Content = 'Fechar'; $btn.Tag = $p.Nome
                $btn.Margin = Espaco 8 0 0 0
                [System.Windows.Automation.AutomationProperties]::SetName($btn, "Fechar $($p.Nome)")
                $btn.Add_Click({ param($origem) Ao-FecharPrograma $origem.Tag })
                [System.Windows.Controls.DockPanel]::SetDock($btn, 'Right')
                $linha.Children.Add($btn) | Out-Null
            }
            $tam = Novo-Texto (Formatar-Tamanho $p.Bytes) 12.5 '#C9D4E5' 'SemiBold'
            $tam.Margin = Espaco 8 0 0 0
            [System.Windows.Controls.DockPanel]::SetDock($tam, 'Right')
            $linha.Children.Add($tam) | Out-Null
            $nome = if ($p.Qtd -gt 1) { "$($p.Nome) ($($p.Qtd) processos)" } else { $p.Nome }
            $texto = Novo-Texto $nome 12.5
            $texto.TextTrimming = 'CharacterEllipsis'; $texto.TextWrapping = 'NoWrap'
            if ($p.Titulo) { $texto.ToolTip = $p.Titulo }
            $linha.Children.Add($texto) | Out-Null
            $lista.Children.Add($linha) | Out-Null
        }
    }
}

function Ao-FecharPrograma {
    param([string]$Nome)
    $msg = "Fechar o $Nome?`r`n`r`nÉ o mesmo que clicar no X: se tiver algo sem salvar, o programa vai perguntar antes de fechar."
    if ((Mostrar-Mensagem $msg 'Fechar programa' 'YesNo' 'Question') -ne 'Yes') { return }
    foreach ($p in @(Get-Process -Name $Nome -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero })) {
        try { [void]$p.CloseMainWindow() } catch { }
    }
    Escrever-Log "Pedido para fechar: $Nome."
    # Dá um tempo para o programa fechar e atualiza a lista
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromSeconds(2)
    $t.Add_Tick({ param($s) $s.Stop(); Atualizar-Programas })
    $t.Start()
}

function Atualizar-InfoSistema {
    Iniciar-EmSegundoPlano -Trabalho { Obter-InfoSistema } -AoConcluir {
        param($resultado, $erro)
        $i = $resultado | Select-Object -First 1
        if (-not $i) { return }
        $dias = [int][math]::Floor($i.Ligado.TotalDays)
        $tempo = if ($dias -ge 1) { "$dias dia(s) e $($i.Ligado.Hours) hora(s)" } else { "$($i.Ligado.Hours) hora(s) e $($i.Ligado.Minutes) minuto(s)" }
        $script:UI.TxtTempoLigado.Text = "Ligado há $tempo sem reiniciar."
        $script:UI.TxtTempoLigado.Foreground = Pincel $(if ($dias -ge 7) { '#FACC15' } else { '#E6EDF7' })
        if ($dias -ge 7) { $script:UI.TxtTempoLigado.Text += ' Recomendamos reiniciar.' }
        if ($i.TemBateria) {
            $txt = "Bateria: $($i.Carga)%" + $(if ($i.Carregando) { ' (carregando)' } else { '' })
            if ($i.SaudePct -gt 0) {
                $txt += " · saúde: $($i.SaudePct)% da capacidade original"
                if ($i.SaudePct -lt 60) { $txt += '. A bateria já está bem gasta; vale pensar em trocar.' }
            }
            $script:UI.TxtBateria.Text = $txt
        } else {
            $script:UI.TxtBateria.Text = 'Sem bateria (computador de mesa).'
        }
    }
}

function Ao-Reiniciar {
    $msg = "Reiniciar o computador agora?`r`n`r`nSalve seus trabalhos e feche os programas antes. O PC reinicia em 10 segundos."
    if ((Mostrar-Mensagem $msg 'Reiniciar' 'YesNo' 'Warning') -ne 'Yes') { return }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo('shutdown.exe', '/r /t 10 /c "Reiniciando pelo Otimizador de PC"')
        $psi.CreateNoWindow = $true; $psi.UseShellExecute = $false
        [void][System.Diagnostics.Process]::Start($psi)
    } catch {
        [void](Mostrar-Mensagem 'Não foi possível reiniciar pelo app. Use Iniciar > Energia > Reiniciar.' 'Reiniciar' 'OK' 'Warning')
    }
}

function Ao-ProcurarArquivosGrandes {
    $script:UI.BtnArquivosGrandes.IsEnabled = $false
    $script:UI.ListaArquivosGrandes.Children.Clear()
    $script:UI.ListaArquivosGrandes.Children.Add((Novo-Texto 'Procurando... pode levar alguns segundos.' 12 '#8A97AD')) | Out-Null
    Iniciar-EmSegundoPlano -Trabalho { Obter-ArquivosGrandes } -AoConcluir {
        param($resultado, $erro)
        $script:UI.BtnArquivosGrandes.IsEnabled = $true
        $lista = $script:UI.ListaArquivosGrandes
        $lista.Children.Clear()
        $itens = @($resultado)
        if ($itens.Count -eq 0) { $lista.Children.Add((Novo-Texto 'Nenhum arquivo acima de 100 MB. Tudo certo!' 12.5 '#22C55E')) | Out-Null; return }
        $total = ($itens | Measure-Object -Property Bytes -Sum).Sum
        $lista.Children.Add((Novo-Texto ('{0} arquivo(s) somando {1}:' -f $itens.Count, (Formatar-Tamanho $total)) 12 '#8A97AD')) | Out-Null
        foreach ($a in $itens) {
            $linha = New-Object System.Windows.Controls.DockPanel
            $linha.Margin = Espaco 0 6 0 0
            $btn = New-Object System.Windows.Controls.Button
            $btn.Style = $script:UI.Janela.FindResource('Botao')
            $btn.Padding = Espaco 10 3; $btn.FontSize = 11; $btn.Content = 'Mostrar'; $btn.Tag = $a.Caminho
            $btn.Margin = Espaco 8 0 0 0
            $btn.ToolTip = 'Abre a pasta com o arquivo selecionado'
            $btn.Add_Click({ param($origem) Abrir-Endereco 'explorer.exe' ("/select,""$($origem.Tag)""") 'a pasta do arquivo' })
            [System.Windows.Controls.DockPanel]::SetDock($btn, 'Right')
            $linha.Children.Add($btn) | Out-Null
            $tam = Novo-Texto (Formatar-Tamanho $a.Bytes) 12.5 '#C9D4E5' 'SemiBold'
            $tam.Margin = Espaco 8 0 0 0
            [System.Windows.Controls.DockPanel]::SetDock($tam, 'Right')
            $linha.Children.Add($tam) | Out-Null
            $nome = Novo-Texto $a.Nome 12.5
            $nome.TextTrimming = 'CharacterEllipsis'; $nome.TextWrapping = 'NoWrap'
            $nome.ToolTip = $a.Caminho
            $linha.Children.Add($nome) | Out-Null
            $lista.Children.Add($linha) | Out-Null
        }
    }
}

# ---- Teste de internet
# Usa os servidores públicos de teste da Cloudflare (os mesmos de speed.cloudflare.com).
# Roda em segundo plano e vai escrevendo o progresso numa tabela compartilhada.

$script:ScriptTesteInternet = {
    param($P)
    $base = 'https://speed.cloudflare.com'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    function Pedido([string]$Url, [string]$Metodo = 'GET') {
        $r = [System.Net.HttpWebRequest]::Create($Url)
        $r.Method = $Metodo; $r.UserAgent = 'OtimizadorPC'; $r.Timeout = 15000; $r.ReadWriteTimeout = 15000
        if ($r.Proxy) { $r.Proxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials }
        return $r
    }
    try {
        try {
            $wc = New-Object System.Net.WebClient
            $wc.Headers['User-Agent'] = 'OtimizadorPC'
            $wc.Encoding = [System.Text.Encoding]::UTF8
            $meta = $wc.DownloadString("$base/meta") | ConvertFrom-Json
            $P.Servidor = [string]$meta.city
            $P.Provedor = [string]$meta.asOrganization
        } catch { }

        # Ping e oscilação: 11 pedidos vazios (o primeiro abre a conexão e é descartado)
        $P.Fase = 'ping'
        $tempos = @()
        for ($i = 0; $i -lt 11; $i++) {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            (Pedido "$base/__down?bytes=0").GetResponse().Close()
            $sw.Stop()
            if ($i -gt 0) { $tempos += $sw.Elapsed.TotalMilliseconds }
        }
        $ordenados = @($tempos | Sort-Object)
        $P.Ping = [math]::Round($ordenados[[int][math]::Floor($ordenados.Count / 2)])
        # Oscilação = mediana das diferenças entre pings seguidos (um pico isolado não distorce o resultado)
        $diferencas = @(for ($i = 1; $i -lt $tempos.Count; $i++) { [math]::Abs($tempos[$i] - $tempos[$i - 1]) }) | Sort-Object
        $P.Jitter = [math]::Round(@($diferencas)[[int][math]::Floor(@($diferencas).Count / 2)])

        # Download: até 8 s ou 100 MB; o primeiro segundo (aceleração da conexão) não entra na conta
        $P.Fase = 'download'; $P.Mbps = 0
        $buffer = New-Object byte[] 65536
        $total = [long]0; $base1s = [long]-1
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt 8 -and $total -lt 100MB) {
            $resp = (Pedido "$base/__down?bytes=25000000").GetResponse()
            $fluxo = $resp.GetResponseStream()
            try {
                while (($n = $fluxo.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $total += $n
                    $t = $sw.Elapsed.TotalSeconds
                    if ($base1s -lt 0 -and $t -ge 1) { $base1s = $total }
                    if ($base1s -ge 0 -and $t -gt 1.2) { $P.Mbps = [math]::Round(($total - $base1s) * 8 / 1e6 / ($t - 1), 1) }
                    elseif ($t -gt 0.2) { $P.Mbps = [math]::Round($total * 8 / 1e6 / $t, 1) }
                    if ($t -ge 8 -or $total -ge 100MB) { break }
                }
            } finally { $fluxo.Close(); $resp.Close() }
        }
        $P.Download = $P.Mbps

        # Upload: até 8 s ou 30 MB, em envios de 4 MB
        $P.Fase = 'upload'; $P.Mbps = 0
        $dados = New-Object byte[] 65536
        (New-Object System.Random).NextBytes($dados)
        $total = [long]0
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt 8 -and $total -lt 30MB) {
            $r = Pedido "$base/__up" 'POST'
            $r.ContentType = 'application/octet-stream'
            $r.ContentLength = 4MB
            $r.AllowWriteStreamBuffering = $false
            $fluxo = $r.GetRequestStream()
            try {
                for ($k = 0; $k -lt 64; $k++) {
                    $fluxo.Write($dados, 0, $dados.Length)
                    $total += $dados.Length
                    $t = $sw.Elapsed.TotalSeconds
                    if ($t -gt 0.2) { $P.Mbps = [math]::Round($total * 8 / 1e6 / $t, 1) }
                }
            } finally { $fluxo.Close() }
            $r.GetResponse().Close()
        }
        $P.Upload = [math]::Round($total * 8 / 1e6 / $sw.Elapsed.TotalSeconds, 1)
        $P.Fase = 'fim'
    } catch {
        $P.Erro = $_.Exception.Message
        $P.Fase = 'erro'
    }
}

# Velocímetro estilo speedtest: arco de 240° (de -120° a +120°, 0° = para cima),
# marcas com espaçamento igual e um ponteiro que corre suavemente até o valor medido.
$script:MarcasVelocidade = @(0, 5, 10, 50, 100, 250, 500, 750, 1000)
$script:Velo = @{ Atual = 0.0; Alvo = 0.0 }
$script:CentroVelo = @{ X = 145; Y = 135; Raio = 110 }

function Obter-PontoVelocimetro {
    param([double]$Graus, [double]$Raio)
    $rad = $Graus * [math]::PI / 180
    return New-Object System.Windows.Point(($script:CentroVelo.X + $Raio * [math]::Sin($rad)), ($script:CentroVelo.Y - $Raio * [math]::Cos($rad)))
}

function Obter-AnguloVelocidade {
    # Cada intervalo entre marcas ocupa a mesma fatia do arco (30°)
    param([double]$Mbps)
    $m = $script:MarcasVelocidade
    if ($Mbps -le 0) { return -120 }
    for ($i = 1; $i -lt $m.Count; $i++) {
        if ($Mbps -le $m[$i]) { return -120 + ($i - 1 + ($Mbps - $m[$i - 1]) / ($m[$i] - $m[$i - 1])) * 30 }
    }
    return 120
}

function Definir-ArcoGraus {
    param($Caminho, [double]$De, [double]$Ate)
    if ($Ate - $De -lt 0.5) { $Caminho.Data = $null; return }
    $r = $script:CentroVelo.Raio
    $figura = New-Object System.Windows.Media.PathFigure
    $figura.StartPoint = Obter-PontoVelocimetro $De $r
    $arco = New-Object System.Windows.Media.ArcSegment((Obter-PontoVelocimetro $Ate $r), (New-Object System.Windows.Size($r, $r)), 0,
        (($Ate - $De) -gt 180), [System.Windows.Media.SweepDirection]::Clockwise, $true)
    $figura.Segments.Add($arco)
    $geometria = New-Object System.Windows.Media.PathGeometry
    $geometria.Figures.Add($figura)
    $Caminho.Data = $geometria
}

function Montar-Velocimetro {
    Definir-ArcoGraus $script:UI.ArcoFundoInternet -120 120
    $marcas = $script:UI.MarcasVelocimetro
    $marcas.Children.Clear()
    for ($i = 0; $i -lt $script:MarcasVelocidade.Count; $i++) {
        $graus = -120 + $i * 30
        $a = Obter-PontoVelocimetro $graus 92
        $b = Obter-PontoVelocimetro $graus 98
        $risco = New-Object System.Windows.Shapes.Line
        $risco.X1 = $a.X; $risco.Y1 = $a.Y; $risco.X2 = $b.X; $risco.Y2 = $b.Y
        $risco.Stroke = Pincel '#3A4A6B'; $risco.StrokeThickness = 2
        $marcas.Children.Add($risco) | Out-Null
        $p = Obter-PontoVelocimetro $graus 78
        $rotulo = Novo-Texto ([string]$script:MarcasVelocidade[$i]) 11 '#8A97AD'
        $rotulo.Width = 40; $rotulo.TextAlignment = 'Center'
        [System.Windows.Controls.Canvas]::SetLeft($rotulo, $p.X - 20)
        [System.Windows.Controls.Canvas]::SetTop($rotulo, $p.Y - 8)
        $marcas.Children.Add($rotulo) | Out-Null
    }
    Definir-CorFase 'download'
    Desenhar-Velocimetro 0
}

function Definir-CorFase {
    # Download em azul-verde e upload em roxo-rosa, como nos sites de speedtest
    param([string]$Fase)
    $cores = if ($Fase -eq 'upload') { '#8B5CF6', '#EC4899' } else { '#06B6D4', '#22C55E' }
    $gradiente = New-Object System.Windows.Media.LinearGradientBrush
    $gradiente.StartPoint = New-Object System.Windows.Point(0, 0)
    $gradiente.EndPoint = New-Object System.Windows.Point(1, 0)
    $gradiente.GradientStops.Add((New-Object System.Windows.Media.GradientStop(([System.Windows.Media.ColorConverter]::ConvertFromString($cores[0])), 0)))
    $gradiente.GradientStops.Add((New-Object System.Windows.Media.GradientStop(([System.Windows.Media.ColorConverter]::ConvertFromString($cores[1])), 1)))
    $script:UI.ArcoInternet.Stroke = $gradiente
    $script:UI.TxtUnidadeFase.Text = switch ($Fase) { 'download' { 'Mbps · download' } 'upload' { 'Mbps · upload' } default { 'Mbps' } }
}

function Desenhar-Velocimetro {
    param([double]$Mbps)
    $graus = Obter-AnguloVelocidade $Mbps
    $script:UI.Ponteiro.RenderTransform.Angle = $graus
    Definir-ArcoGraus $script:UI.ArcoInternet -120 $graus
    $script:UI.TxtVelocidade.Text = Formatar-Mbps $Mbps
}

function Definir-Velocimetro {
    # Só muda o alvo; o timer do velocímetro leva o ponteiro até lá suavemente (~60 quadros/s)
    param([double]$Mbps)
    $script:Velo.Alvo = [math]::Max(0, $Mbps)
    if (-not $script:UI.TimerVelocimetro) {
        $t = New-Object System.Windows.Threading.DispatcherTimer
        $t.Interval = [TimeSpan]::FromMilliseconds(16)
        $t.Add_Tick({
            $v = $script:Velo
            $v.Atual += ($v.Alvo - $v.Atual) * 0.12
            if ([math]::Abs($v.Alvo - $v.Atual) -lt 0.05) { $v.Atual = $v.Alvo }
            Desenhar-Velocimetro $v.Atual
            if ($v.Atual -eq $v.Alvo -and -not $script:TesteInternet) { $script:UI.TimerVelocimetro.Stop() }
        })
        $script:UI.TimerVelocimetro = $t
    }
    $script:UI.TimerVelocimetro.Start()
}

function Formatar-Mbps {
    param([double]$Valor)
    if ($Valor -ge 100) { return '{0:N0}' -f $Valor }
    return '{0:N1}' -f $Valor
}

function Avaliar-Internet {
    param($P)
    $linhas = @()
    $d = [double]$P.Download; $u = [double]$P.Upload; $ping = [double]$P.Ping; $jit = [double]$P.Jitter
    $dTxt = Formatar-Mbps $d; $uTxt = Formatar-Mbps $u
    if ($d -lt 5) { $linhas += @('#EF4444', "Download lento ($dTxt Mbps): sites e vídeos podem travar.") }
    elseif ($d -lt 25) { $linhas += @('#FACC15', "Download razoável ($dTxt Mbps): dá para o dia a dia, mas vídeos em alta qualidade podem travar.") }
    else { $linhas += @('#22C55E', "Download bom ($dTxt Mbps): sites, CRM e vídeos devem abrir sem problema.") }

    if ($u -ge 1.5 -and $ping -lt 100 -and $jit -lt 30) {
        $linhas += @('#22C55E', 'Chamadas de áudio e vídeo (WhatsApp, Meet, Teams): boas condições.')
    } else {
        $motivos = @()
        if ($u -lt 1.5) { $motivos += "upload baixo ($uTxt Mbps)" }
        if ($ping -ge 100) { $motivos += "ping alto ($ping ms)" }
        if ($jit -ge 30) { $motivos += "conexão instável ($jit ms de oscilação)" }
        $linhas += @('#FACC15', "Chamadas de áudio e vídeo podem picotar: $($motivos -join ', ').")
        $linhas += @('#8A97AD', 'Dica: se estiver no Wi-Fi, chegue mais perto do roteador ou use cabo de rede.')
    }
    return ,$linhas
}

function Ao-TestarInternet {
    if ($script:TesteInternet) { return }
    $p = [hashtable]::Synchronized(@{ Fase = 'inicio'; Mbps = 0; Download = 0; Upload = 0; Ping = 0; Jitter = 0; Erro = $null; Servidor = ''; Provedor = '' })
    $script:TesteInternet = $p
    foreach ($nome in 'TxtDownload', 'TxtUpload', 'TxtPing', 'TxtJitter') { $script:UI[$nome].Text = '--' }
    $script:UI.BtnTestarInternet.IsEnabled = $false
    $script:UI.TxtBtnTestar.Text = 'Testando...'
    $script:UI.TxtFaseTeste.Text = 'Conectando...'
    $script:UI.ListaAvaliacao.Children.Clear()
    $script:UI.ListaAvaliacao.Children.Add((Novo-Texto 'Aguarde uns 20 segundos...' 12.5 '#8A97AD')) | Out-Null
    $script:UltimaFaseInternet = $null
    Definir-CorFase 'inicio'
    Definir-Velocimetro 0
    Iniciar-EmSegundoPlano -Trabalho $script:ScriptTesteInternet -Parametros @{ P = $p } -AoConcluir {
        param($resultado, $erro)
        $p = $script:TesteInternet
        $script:TesteInternet = $null
        $script:UI.BtnTestarInternet.IsEnabled = $true
        $script:UI.TxtBtnTestar.Text = 'Testar de novo'
        $script:UI.ListaAvaliacao.Children.Clear()
        if ($p.Fase -ne 'fim') {
            $script:UI.TxtFaseTeste.Text = 'Não foi possível testar'
            Definir-Velocimetro 0
            $script:UI.ListaAvaliacao.Children.Add((Novo-Texto 'Sem internet ou o servidor de teste está bloqueado na rede.' 12.5 '#EF4444')) | Out-Null
            return
        }
        Atualizar-TesteInternet $p
        $script:UI.TxtFaseTeste.Text = 'Teste concluído'
        Definir-CorFase 'download'
        Definir-Velocimetro $p.Download
        $avaliacao = Avaliar-Internet $p
        for ($i = 0; $i -lt $avaliacao.Count; $i += 2) {
            $linha = Novo-Texto ("• " + $avaliacao[$i + 1]) 12.5 $avaliacao[$i]
            $linha.Margin = Espaco 0 0 0 6
            $script:UI.ListaAvaliacao.Children.Add($linha) | Out-Null
        }
        $resumo = 'Teste de internet: {0} Mbps download, {1} Mbps upload, ping {2} ms' -f (Formatar-Mbps $p.Download), (Formatar-Mbps $p.Upload), $p.Ping
        Adicionar-Historico 'Internet' $resumo
        Escrever-Log "$resumo."
    }
}

function Atualizar-TesteInternet {
    param($P)
    $fases = @{ inicio = 'Conectando...'; ping = 'Medindo o ping...'; download = 'Testando download...'; upload = 'Testando upload...'; fim = 'Teste concluído' }
    if ($fases.ContainsKey([string]$P.Fase)) { $script:UI.TxtFaseTeste.Text = $fases[[string]$P.Fase] }
    if ($P.Fase -ne $script:UltimaFaseInternet) {
        # Troca de etapa: muda a cor e o ponteiro volta a zero antes de subir de novo
        $script:UltimaFaseInternet = $P.Fase
        if ($P.Fase -in 'download', 'upload') { Definir-CorFase $P.Fase }
    }
    if ($P.Fase -in 'download', 'upload') { Definir-Velocimetro ([double]$P.Mbps) }
    elseif ($P.Fase -in 'inicio', 'ping') { Definir-Velocimetro 0 }
    if ($P.Ping) { $script:UI.TxtPing.Text = [string]$P.Ping; $script:UI.TxtJitter.Text = [string]$P.Jitter }
    if ($P.Download) { $script:UI.TxtDownload.Text = Formatar-Mbps $P.Download }
    if ($P.Upload) { $script:UI.TxtUpload.Text = Formatar-Mbps $P.Upload }
    if ($P.Servidor -or $P.Provedor) {
        $partes = @('Servidor de teste: Cloudflare')
        if ($P.Servidor) { $partes[0] += " ($($P.Servidor))" }
        if ($P.Provedor) { $partes += "Provedor: $($P.Provedor)" }
        $script:UI.TxtServidorTeste.Text = $partes -join "`r`n"
    }
}

# ---- Animação da otimização (lixeira recebendo arquivos)

function Nova-AnimacaoQuadros {
    # Animação por quadros-chave: $Quadros = lista de @(segundos, valor[, suavização])
    param([object[]]$Quadros, [double]$Duracao, [double]$Inicio = 0, [switch]$Repetir)
    $a = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
    $a.Duration = New-Object System.Windows.Duration([TimeSpan]::FromSeconds($Duracao))
    $a.BeginTime = [TimeSpan]::FromSeconds($Inicio)
    if ($Repetir) { $a.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever }
    foreach ($q in $Quadros) {
        $k = New-Object System.Windows.Media.Animation.EasingDoubleKeyFrame([double]$q[1], [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromSeconds($q[0])))
        if ($q.Count -gt 2) { $k.EasingFunction = $q[2] }
        [void]$a.KeyFrames.Add($k)   # Add devolve a posição; sem [void] ela iria junto no retorno
    }
    return $a
}

function Iniciar-AnimacaoOtimizacao {
    $ui = $script:UI
    $script:AnimInicio = Get-Date
    $ui.TxtAnimTitulo.Text = 'Otimizando...'
    $ui.TxtAnimDetalhe.Text = 'Jogando fora o que não serve mais'
    $ui.BtnFecharAnim.Visibility = 'Hidden'
    # Limpa o que sobrou da animação anterior (animações "seguram" o último valor)
    $ui.SeloConcluido.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
    $ui.SeloConcluido.RenderTransform.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $null)
    $ui.SeloConcluido.RenderTransform.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $null)
    $ui.CorpoLixeira.RenderTransform.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $null)
    $ui.SeloConcluido.Opacity = 0
    $ui.SeloConcluido.RenderTransform.ScaleX = 0; $ui.SeloConcluido.RenderTransform.ScaleY = 0
    $ui.Overlay.Opacity = 0
    $ui.Overlay.Visibility = 'Visible'
    $ui.Overlay.BeginAnimation([System.Windows.UIElement]::OpacityProperty,
        (New-Object System.Windows.Media.Animation.DoubleAnimation(0, 1, (New-Object System.Windows.Duration([TimeSpan]::FromSeconds(0.25))))))

    # Tampa aberta, balançando
    $ui.TampaLixeira.RenderTransform.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty,
        (Nova-AnimacaoQuadros @(@(0, 0), @(0.2, -38), @(0.45, -28), @(0.7, -38)) 0.7 0 -Repetir))

    # Arquivos voando para dentro da lixeira, um atrás do outro
    foreach ($a in @($script:ArquivosAnim)) { $ui.CanvasLixo.Children.Remove($a) }
    $script:ArquivosAnim = @()
    $origens = @(@(10, 150, '#4F9BFF', 0xE8A5), @(300, 140, '#FACC15', 0xE7C3), @(40, 20, '#EA4335', 0xE8A5),
                 @(290, 10, '#A78BFA', 0xE7C3), @(150, -10, '#22C55E', 0xE8A5))
    $suave = New-Object System.Windows.Media.Animation.QuadraticEase
    $suave.EasingMode = 'EaseIn'
    $i = 0
    foreach ($o in $origens) {
        $arq = Novo-Texto ([string][char]$o[3]) 30 $o[2] 'Normal' 'Segoe MDL2 Assets'
        [System.Windows.Controls.Canvas]::SetLeft($arq, $o[0]); [System.Windows.Controls.Canvas]::SetTop($arq, $o[1])
        $arq.RenderTransformOrigin = New-Object System.Windows.Point(0.5, 0.5)
        $escala = New-Object System.Windows.Media.ScaleTransform
        $giro = New-Object System.Windows.Media.RotateTransform
        $mov = New-Object System.Windows.Media.TranslateTransform
        $grupo = New-Object System.Windows.Media.TransformGroup
        $grupo.Children.Add($escala); $grupo.Children.Add($giro); $grupo.Children.Add($mov)
        $arq.RenderTransform = $grupo
        $arq.Opacity = 0
        $ui.CanvasLixo.Children.Add($arq) | Out-Null
        $script:ArquivosAnim += $arq

        # Destino: boca da lixeira (165, 100); sobe um pouco antes de cair (arco)
        $dx = 165 - $o[0]; $dy = 100 - $o[1]
        $dur = 1.4; $atraso = $i * 0.28
        $mov.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, (Nova-AnimacaoQuadros @(@(0, 0), @(1.1, $dx), @(1.4, $dx)) $dur $atraso -Repetir))
        $mov.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, (Nova-AnimacaoQuadros @(@(0, 0), @(0.45, ([math]::Min(0, $dy) - 45)), @(1.1, $dy, $suave), @(1.4, ($dy + 30))) $dur $atraso -Repetir))
        $giro.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, (Nova-AnimacaoQuadros @(@(0, 0), @(1.4, 260)) $dur $atraso -Repetir))
        $escala.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, (Nova-AnimacaoQuadros @(@(0, 1), @(1.1, 0.7), @(1.4, 0.3)) $dur $atraso -Repetir))
        $escala.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, (Nova-AnimacaoQuadros @(@(0, 1), @(1.1, 0.7), @(1.4, 0.3)) $dur $atraso -Repetir))
        $arq.BeginAnimation([System.Windows.UIElement]::OpacityProperty, (Nova-AnimacaoQuadros @(@(0, 0), @(0.15, 1), @(1.1, 1), @(1.3, 0), @(1.4, 0)) $dur $atraso -Repetir))
        $i++
    }
}

function Concluir-AnimacaoOtimizacao {
    param([long]$Bytes, [string]$Erro)
    # Garante pelo menos 2,5 s de animação, mesmo se a limpeza for rápida
    $falta = 2.5 - ((Get-Date) - $script:AnimInicio).TotalSeconds
    if ($falta -gt 0) {
        $script:AnimPendente = @{ Bytes = $Bytes; Erro = $Erro }
        $t = New-Object System.Windows.Threading.DispatcherTimer
        $t.Interval = [TimeSpan]::FromSeconds($falta)
        $t.Add_Tick({ param($s) $s.Stop(); Concluir-AnimacaoOtimizacao $script:AnimPendente.Bytes $script:AnimPendente.Erro })
        $t.Start()
        return
    }
    $ui = $script:UI
    foreach ($a in @($script:ArquivosAnim)) {
        $a.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
        $a.Opacity = 0
    }

    # Tampa fecha com um quique e a lixeira balança
    $quique = New-Object System.Windows.Media.Animation.BounceEase
    $quique.Bounces = 2; $quique.Bounciness = 3
    $ui.TampaLixeira.RenderTransform.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty,
        (Nova-AnimacaoQuadros @(@(0, -38), @(0.5, 0, $quique)) 0.5))
    $ui.CorpoLixeira.RenderTransform.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty,
        (Nova-AnimacaoQuadros @(@(0, 0), @(0.1, -5), @(0.2, 5), @(0.3, -3), @(0.4, 3), @(0.5, 0)) 0.5 0.35))

    # Selo de concluído aparece crescendo
    $volta = New-Object System.Windows.Media.Animation.BackEase
    $volta.Amplitude = 0.5; $volta.EasingMode = 'EaseOut'
    $ui.SeloConcluido.BeginAnimation([System.Windows.UIElement]::OpacityProperty, (Nova-AnimacaoQuadros @(@(0, 0), @(0.2, 1)) 0.2 0.5))
    foreach ($prop in [System.Windows.Media.ScaleTransform]::ScaleXProperty, [System.Windows.Media.ScaleTransform]::ScaleYProperty) {
        $ui.SeloConcluido.RenderTransform.BeginAnimation($prop, (Nova-AnimacaoQuadros @(@(0, 0), @(0.45, 1, $volta)) 0.45 0.5))
    }

    if ($Erro) {
        $ui.TxtAnimTitulo.Text = 'Concluído com avisos'
        $ui.TxtAnimDetalhe.Text = 'Veja os detalhes no registro.'
    } else {
        # Contagem subindo até o total limpo
        $script:AnimContagem = @{ Alvo = $Bytes; Passo = 0 }
        $ui.TxtAnimDetalhe.Text = 'Seu PC está mais leve. Tudo pode ser desfeito com "Desfazer".'
        $t = New-Object System.Windows.Threading.DispatcherTimer
        $t.Interval = [TimeSpan]::FromMilliseconds(30)
        $t.Add_Tick({
            param($s)
            $c = $script:AnimContagem
            $c.Passo++
            $fracao = [math]::Min(1, $c.Passo / 30)
            $script:UI.TxtAnimTitulo.Text = '{0} limpos!' -f (Formatar-Tamanho ($c.Alvo * (1 - [math]::Pow(1 - $fracao, 3))))
            if ($fracao -ge 1) { $s.Stop() }
        })
        $t.Start()
    }
    $ui.BtnFecharAnim.Visibility = 'Visible'
}

function Fechar-AnimacaoOtimizacao {
    $ui = $script:UI
    $ui.TampaLixeira.RenderTransform.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $null)
    $sumir = New-Object System.Windows.Media.Animation.DoubleAnimation(1, 0, (New-Object System.Windows.Duration([TimeSpan]::FromSeconds(0.2))))
    $sumir.Add_Completed({ $script:UI.Overlay.Visibility = 'Collapsed' })
    $ui.Overlay.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $sumir)
}

function Criar-Janela {
    $janela = [System.Windows.Markup.XamlReader]::Parse($script:Xaml)
    $script:UI.Janela = $janela
    $nomes = 'BarraTitulo', 'TxtVersao', 'BtnAtualizar', 'TxtBtnAtualizar', 'BtnMinimizar', 'BtnFechar',
             'PontoSaude', 'TxtSaudeLateral', 'NavInicio', 'NavDiagnostico', 'NavInternet', 'NavHistorico', 'NavInicializacao', 'NavConfig',
             'NavMonitor', 'NavFerramentas', 'PaginaMonitor', 'PaginaFerramentas', 'GradeMonitor', 'PontoAoVivo', 'CartaoStatus',
             'BtnMemoriaChrome', 'BtnMemoriaEdge', 'BtnAtualizarProgramas', 'ListaProgramas', 'BtnTestarMicrofone',
             'BtnPermissaoMicrofone', 'BtnPainelSom', 'TxtTempoLigado', 'BtnReiniciar', 'TxtBateria', 'BtnArquivosGrandes',
             'ListaArquivosGrandes',
             'PaginaInternet', 'ArcoFundoInternet', 'ArcoInternet', 'MarcasVelocimetro', 'Ponteiro', 'TxtUnidadeFase', 'TxtVelocidade', 'TxtFaseTeste', 'BtnTestarInternet', 'TxtBtnTestar',
             'TxtServidorTeste', 'TxtDownload', 'TxtUpload', 'TxtPing', 'TxtJitter', 'ListaAvaliacao',
             'Overlay', 'CanvasLixo', 'CorpoLixeira', 'TampaLixeira', 'SeloConcluido', 'TxtAnimTitulo', 'TxtAnimDetalhe', 'BtnFecharAnim',
             'PaginaInicio', 'PaginaDiagnostico', 'PaginaHistorico', 'PaginaInicializacao', 'PaginaConfig',
             'ListaAcoes', 'BtnLimparLog', 'TxtLog', 'AnelInicio', 'TxtNotaInicio', 'TxtEstado', 'TxtSelecionadas', 'BtnExplicar',
             'BarraProgresso', 'BtnOtimizar', 'BtnAnalisar', 'ListaStatus', 'BtnVerHistorico', 'TxtUltimaLimpeza',
             'TxtBackup', 'BtnDesfazer', 'BtnEsvaziar', 'BtnAtualizarDiag', 'AnelDiag', 'TxtNotaDiag', 'TxtRotuloDiag',
             'ListaDicas', 'ListaDescontos', 'TxtDiagnostico', 'TxtHistoricoVazio', 'ListaHistorico', 'BtnAbrirInicializacao',
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
        $marcada = $config.AcoesDesligadas -notcontains $acao.Id
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
    Montar-Velocimetro
    Criar-Monitor

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
    $script:UI.NavMonitor.Add_Checked({ Mostrar-Pagina 'PaginaMonitor' })
    $script:UI.NavFerramentas.Add_Checked({ Mostrar-Pagina 'PaginaFerramentas' })
    $script:UI.NavInternet.Add_Checked({ Mostrar-Pagina 'PaginaInternet' })
    $script:UI.NavHistorico.Add_Checked({ Mostrar-Pagina 'PaginaHistorico' })
    $script:UI.NavInicializacao.Add_Checked({ Mostrar-Pagina 'PaginaInicializacao' })
    $script:UI.NavConfig.Add_Checked({ Mostrar-Pagina 'PaginaConfig' })

    # Botões
    $script:UI.BtnOtimizar.Add_Click({ Ao-Otimizar })
    $script:UI.BtnAnalisar.Add_Click({ Ao-Analisar })
    $script:UI.BtnExplicar.Add_Click({ Ao-Explicar })
    $script:UI.BtnDesfazer.Add_Click({ Ao-Desfazer })
    $script:UI.BtnEsvaziar.Add_Click({ Ao-Esvaziar })
    $script:UI.BtnLimparLog.Add_Click({ $script:UI.TxtLog.Clear() })
    $script:UI.BtnVerHistorico.Add_Click({ $script:UI.NavHistorico.IsChecked = $true })
    $script:UI.BtnAtualizarDiag.Add_Click({ Iniciar-Diagnostico })
    $script:UI.BtnAbrirInicializacao.Add_Click({ Ao-Inicializacao })
    $script:UI.BtnAtualizar.Add_Click({ Ao-Atualizar })
    $script:UI.BtnProcurarAtualizacao.Add_Click({ Iniciar-VerificacaoAtualizacao -Manual })
    $script:UI.BtnNovidades.Add_Click({ Ao-VerNovidades })
    $script:UI.BtnTestarInternet.Add_Click({ Ao-TestarInternet })
    $script:UI.CartaoStatus.Add_MouseLeftButtonUp({ $script:UI.NavMonitor.IsChecked = $true })
    $script:UI.BtnMemoriaChrome.Add_Click({ Abrir-Endereco 'chrome' 'chrome://settings/performance' 'o Chrome' })
    $script:UI.BtnMemoriaEdge.Add_Click({ Abrir-Endereco 'msedge' 'edge://settings/system' 'o Edge' })
    $script:UI.BtnAtualizarProgramas.Add_Click({ Atualizar-Programas })
    $script:UI.BtnTestarMicrofone.Add_Click({ Abrir-Endereco 'ms-settings:sound' $null 'as configurações de som' })
    $script:UI.BtnPermissaoMicrofone.Add_Click({ Abrir-Endereco 'ms-settings:privacy-microphone' $null 'a permissão do microfone' })
    $script:UI.BtnPainelSom.Add_Click({ Abrir-Endereco 'control.exe' 'mmsys.cpl' 'o painel de som' })
    $script:UI.BtnReiniciar.Add_Click({ Ao-Reiniciar })
    $script:UI.BtnArquivosGrandes.Add_Click({ Ao-ProcurarArquivosGrandes })
    $script:UI.BtnFecharAnim.Add_Click({ Fechar-AnimacaoOtimizacao })

    # Timers: tarefas/registro (rápido) e status do sistema (a cada 3 s)
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(150)
    $timer.Add_Tick({ Processar-Tarefas })
    $timer.Start()
    $timerStatus = New-Object System.Windows.Threading.DispatcherTimer
    $timerStatus.Interval = [TimeSpan]::FromSeconds(3)
    $timerStatus.Add_Tick({ Iniciar-Status })
    $timerStatus.Start()
    $timerMonitor = New-Object System.Windows.Threading.DispatcherTimer
    $timerMonitor.Interval = [TimeSpan]::FromSeconds(1)
    $timerMonitor.Add_Tick({ Iniciar-LeituraMonitor })   # só lê quando a página Monitor está aberta
    $timerMonitor.Start()
    $script:UI.Timers = @($timer, $timerStatus, $timerMonitor)

    $janela.Add_ContentRendered({ Ao-Abrir })
    $janela.Add_Closed({
        foreach ($t in $script:UI.Timers) { $t.Stop() }
        if ($script:UI.TimerVelocimetro) { $script:UI.TimerVelocimetro.Stop() }
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

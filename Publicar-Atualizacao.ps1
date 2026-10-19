# Publica a versão atual como uma Release no GitHub. Os apps instalados
# mostram o botão "Atualizar" na próxima vez que forem abertos.
#
# Antes: mude $script:Versao no Otimizador.ps1, escreva as novidades no NOVIDADES.md,
# rode .\Gerar-EXE.ps1 e envie o código (git commit + git push).
# Depois:
#   .\Publicar-Atualizacao.ps1
#
# Usa o mesmo login do git (Git Credential Manager), sem precisar de outra ferramenta.

$ErrorActionPreference = 'Stop'
$pasta    = Split-Path -Parent $MyInvocation.MyCommand.Path
$codigo   = [IO.File]::ReadAllText((Join-Path $pasta 'Otimizador.ps1'))
$repo     = [regex]::Match($codigo, "\`$script:RepoGitHub\s*=\s*'([^']+)'").Groups[1].Value
$exe      = Join-Path $pasta 'Instalar-Otimizador.exe'
$jsonPath = Join-Path $pasta 'versao.json'

# 1. Confere os arquivos gerados
if (-not (Test-Path $exe) -or -not (Test-Path $jsonPath)) {
    Write-Host 'Rode o Gerar-EXE.ps1 antes.' -ForegroundColor Red; exit 1
}
$info = [IO.File]::ReadAllText($jsonPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
if ((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -ne $info.sha256) {
    Write-Host 'O versao.json não corresponde ao exe atual. Rode o Gerar-EXE.ps1 de novo.' -ForegroundColor Red; exit 1
}

# 2. Pega o token do GitHub guardado pelo git
$psi = New-Object System.Diagnostics.ProcessStartInfo('git', 'credential fill')
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
# Sem isto o .NET manda um BOM antes do texto e o git recusa o pedido
$codificacaoAnterior = [Console]::InputEncoding
[Console]::InputEncoding = New-Object Text.UTF8Encoding($false)
try { $proc = [System.Diagnostics.Process]::Start($psi) } finally { [Console]::InputEncoding = $codificacaoAnterior }
$proc.StandardInput.Write("protocol=https`nhost=github.com`n`n")
$proc.StandardInput.Close()
$credencial = $proc.StandardOutput.ReadToEnd() -split "`n"
$proc.WaitForExit()
$token = [string](($credencial | Where-Object { $_ -like 'password=*' } | Select-Object -First 1) -replace '^password=', '')
$token = $token.Trim()
if (-not $token) {
    Write-Host 'Login do GitHub não encontrado. Faça um "git push" uma vez para logar e tente de novo.' -ForegroundColor Red; exit 1
}

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$cabecalhos = @{
    Authorization          = "Bearer $token"
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent'           = 'OtimizadorPC-Publicar'
}

# 3. Cria a Release, ou reaproveita a que já existe (ex.: uma tentativa anterior falhou no meio)
$tag   = "v$($info.versao)"
$notas = if ($info.notas) { $info.notas } else { "Versão $($info.versao)" }
$release = $null
try { $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/tags/$tag" -Headers $cabecalhos } catch { }
if ($release) {
    Write-Host "A Release $tag já existe; completando os arquivos que faltam..."
} else {
    $corpo = @{ tag_name = $tag; name = "Otimizador de PC $($info.versao)"; body = $notas } | ConvertTo-Json
    Write-Host "Criando a Release $tag em $repo..."
    try {
        $release = Invoke-RestMethod -Method Post -Uri "https://api.github.com/repos/$repo/releases" -Headers $cabecalhos `
            -Body ([Text.Encoding]::UTF8.GetBytes($corpo)) -ContentType 'application/json; charset=utf-8'
    } catch {
        Write-Host "Falha ao criar a Release: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host 'Se o GitHub estiver instável, espere um pouco e rode de novo: a Release será completada.' -ForegroundColor Yellow
        exit 1
    }
}

# 4. Anexa o instalador e o versao.json (troca os que já existirem, para ficarem iguais aos daqui)
$baseUpload = $release.upload_url -replace '\{.*\}$', ''
foreach ($arquivo in $exe, $jsonPath) {
    $nome = Split-Path -Leaf $arquivo
    $antigo = $release.assets | Where-Object { $_.name -eq $nome }
    if ($antigo) {
        Write-Host "Substituindo $nome..."
        [void](Invoke-RestMethod -Method Delete -Uri "https://api.github.com/repos/$repo/releases/assets/$($antigo.id)" -Headers $cabecalhos)
    } else {
        Write-Host "Enviando $nome..."
    }
    try {
        [void](Invoke-RestMethod -Method Post -Uri "$($baseUpload)?name=$nome" -Headers $cabecalhos `
            -InFile $arquivo -ContentType 'application/octet-stream')
    } catch {
        Write-Host "Falha ao enviar ${nome}: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host 'Rode o Publicar-Atualizacao.ps1 de novo: ele completa a Release.' -ForegroundColor Yellow
        exit 1
    }
}
Write-Host "Publicado: $($release.html_url)" -ForegroundColor Green

# Gera o Instalar-Otimizador.exe a partir do Otimizador.ps1 usando o PS2EXE.
# O mesmo exe instala, abre o app e desinstala (ver seção "Instalação" no Otimizador.ps1).
# Uso: clique com o botão direito > "Executar com o PowerShell"
#  ou: powershell -ExecutionPolicy Bypass -File .\Gerar-EXE.ps1 -Novidades "O que mudou nesta versão"
#
# Também gera o versao.json (versão + SHA-256 do exe + novidades), que vai junto
# na Release do GitHub e é lido pelo app para saber se há atualização.

param([string]$Novidades = '')

$ErrorActionPreference = 'Stop'
$pasta   = Split-Path -Parent $MyInvocation.MyCommand.Path
$entrada = Join-Path $pasta 'Otimizador.ps1'
$saida   = Join-Path $pasta 'Instalar-Otimizador.exe'

# A versão vem do próprio script ($script:Versao), para ficar igual no exe e no Painel de Controle
$versao = [regex]::Match([IO.File]::ReadAllText($entrada), "\`$script:Versao\s*=\s*'([\d.]+)'").Groups[1].Value
if (-not $versao) { Write-Host 'Não encontrei $script:Versao no Otimizador.ps1.' -ForegroundColor Red; exit 1 }

# 1. Valida a sintaxe antes de compilar
$tokens = $null; $erros = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($entrada, [ref]$tokens, [ref]$erros)
if ($erros) {
    foreach ($e in $erros) { Write-Host ("Erro de sintaxe na linha {0}: {1}" -f $e.Extent.StartLineNumber, $e.Message) -ForegroundColor Red }
    exit 1
}
Write-Host 'Sintaxe OK.' -ForegroundColor Green

# 2. Instala o ps2exe só para o usuário atual (não precisa de administrador)
if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host 'Instalando o módulo ps2exe (somente para o usuário atual)...'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
    }
    Install-Module -Name ps2exe -Scope CurrentUser -Force
}
Import-Module ps2exe

# 3. Compila: sem console e sem pedir administrador
Invoke-ps2exe -inputFile $entrada -outputFile $saida -noConsole -STA `
    -title 'Otimizador de PC' -product 'Otimizador de PC' `
    -description 'Limpeza segura de arquivos temporários e cache' -version "$versao.0"

if (-not (Test-Path $saida)) {
    Write-Host 'Falha ao gerar o exe.' -ForegroundColor Red
    exit 1
}
Write-Host ("Gerado: {0} ({1:N0} KB)" -f $saida, ((Get-Item $saida).Length / 1KB)) -ForegroundColor Green

# 4. versao.json (UTF-8 sem BOM, para o app ler direto do GitHub)
$json = [ordered]@{
    versao = $versao
    sha256 = (Get-FileHash -LiteralPath $saida -Algorithm SHA256).Hash
    notas  = $Novidades
} | ConvertTo-Json
[IO.File]::WriteAllText((Join-Path $pasta 'versao.json'), $json, (New-Object Text.UTF8Encoding($false)))
Write-Host "Gerado: versao.json (versão $versao)" -ForegroundColor Green

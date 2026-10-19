# Testa a lógica de limpeza numa pasta temporária (não abre janelas).
# Cria arquivos novos, antigos, somente leitura, uma subpasta e uma junction, e confere que:
# só os antigos saem, a junction nunca é seguida, o Desfazer devolve tudo e as travas de pasta funcionam.
param(
    [string]$Script = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Otimizador.ps1'),
    [string]$Base = (Join-Path $env:TEMP 'teste-otimizador')
)
$ErrorActionPreference = 'Stop'

# Carrega só as funções e definições (tudo antes do bloco "Início", que abre a janela)
$texto = [IO.File]::ReadAllText($Script)
$fim = $texto.IndexOf('# ------------------------------------------------------------------ Início')
. ([scriptblock]::Create($texto.Substring(0, $fim)))

$falhas = 0
function Confere([string]$Nome, [bool]$Ok) {
    if ($Ok) { Write-Output "  OK    $Nome" } else { Write-Output "  FALHA $Nome"; $script:falhas++ }
}

if (Test-Path $Base) { Remover-PastaSegura $Base }
$alvo    = Join-Path $Base 'alvo'
$externo = Join-Path $Base 'externo'
$backup  = Join-Path $Base 'backup'
$sub     = Join-Path $alvo 'subpasta'
New-Item -ItemType Directory -Path $sub, $externo | Out-Null

$antigo = (Get-Date).AddDays(-3)
function Novo([string]$Caminho, [bool]$Velho) {
    Set-Content -LiteralPath $Caminho -Value "conteudo de $Caminho" -Encoding UTF8
    if ($Velho) { (Get-Item -LiteralPath $Caminho).LastWriteTime = $antigo }
}
Novo "$alvo\novo.txt" $false
Novo "$alvo\antigo.txt" $true
Novo "$alvo\antigo-somente-leitura.txt" $true
(Get-Item "$alvo\antigo-somente-leitura.txt").IsReadOnly = $true
Novo "$sub\novo-sub.txt" $false
Novo "$sub\antigo-sub.txt" $true
Novo "$externo\externo-antigo.txt" $true
Novo "$externo\externo-novo.txt" $false
New-Item -ItemType Junction -Path "$alvo\link-junction" -Target $externo | Out-Null

Write-Output '1) Analisar (somente contagem)'
$lista = Obter-ArquivosElegiveis $alvo 1
Confere 'encontra exatamente 3 arquivos antigos' ($lista.Count -eq 3)
Confere 'nenhum arquivo listado vem pela junction' (-not ($lista | Where-Object { $_.FullName -like '*link-junction*' }))

Write-Output '2) Limpar-Pasta (dias minimos = 1)'
$r = Limpar-Pasta -Caminho $alvo -DiasMinimos 1 -PastaBackup $backup
Confere 'antigo.txt saiu'                 (-not (Test-Path "$alvo\antigo.txt"))
Confere 'antigo-somente-leitura.txt saiu' (-not (Test-Path "$alvo\antigo-somente-leitura.txt"))
Confere 'subpasta\antigo-sub.txt saiu'    (-not (Test-Path "$sub\antigo-sub.txt"))
Confere 'novo.txt ficou'                  (Test-Path "$alvo\novo.txt")
Confere 'subpasta\novo-sub.txt ficou'     (Test-Path "$sub\novo-sub.txt")
Confere 'junction ainda existe'           ([bool]((Get-Item "$alvo\link-junction" -Force).Attributes -band 'ReparsePoint'))
Confere 'alvo da junction intacto'        ((Test-Path "$externo\externo-antigo.txt") -and (Test-Path "$externo\externo-novo.txt"))
Confere '3 arquivos no backup'            ((Obter-InfoBackup $backup).Arquivos -eq 3)

Write-Output '3) Desfazer (Restaurar-Backup)'
Set-Content "$alvo\antigo.txt" 'arquivo recriado depois da limpeza'
$rr = Restaurar-Backup -PastaBackup $backup
Confere 'antigo-sub.txt voltou com o conteúdo original' ((Get-Content "$sub\antigo-sub.txt") -eq "conteudo de $sub\antigo-sub.txt")
Confere 'antigo-somente-leitura.txt voltou'             (Test-Path "$alvo\antigo-somente-leitura.txt")
Confere 'arquivo recriado NÃO foi sobrescrito'          ((Get-Content "$alvo\antigo.txt") -eq 'arquivo recriado depois da limpeza')
Confere 'conflito ficou guardado no backup'             ((Obter-InfoBackup $backup).Arquivos -eq 1)

Write-Output '4) Esvaziar backup com uma junction dentro'
New-Item -ItemType Junction -Path "$backup\junction-armadilha" -Target $externo | Out-Null
Remover-PastaSegura $backup
Confere 'backup apagado'                    (-not (Test-Path $backup))
Confere 'alvo da junction continua intacto' ((Test-Path "$externo\externo-antigo.txt") -and (Test-Path "$externo\externo-novo.txt"))

Write-Output '5) Raiz da limpeza sendo uma junction'
$r2 = Limpar-Pasta -Caminho "$alvo\link-junction" -DiasMinimos 0 -PastaBackup $backup
Confere 'nada movido quando a pasta alvo é uma junction' (($r2.Movidos -eq 0) -and (Test-Path "$externo\externo-antigo.txt"))

Write-Output '6) Trava de pastas permitidas'
Confere 'aceita %TEMP%'            (Test-PastaPermitida $env:TEMP)
Confere 'aceita C:\Windows\Temp'   (Test-PastaPermitida "$env:windir\Temp")
Confere 'recusa C:\'               (-not (Test-PastaPermitida 'C:\'))
Confere 'recusa perfil do usuário' (-not (Test-PastaPermitida $env:USERPROFILE))
Confere 'recusa Downloads'         (-not (Test-PastaPermitida "$env:USERPROFILE\Downloads"))
Confere 'recusa Documentos'        (-not (Test-PastaPermitida ([Environment]::GetFolderPath('MyDocuments'))))
Confere 'recusa vazio'             (-not (Test-PastaPermitida ''))
Confere 'aceita relatórios de erro' (Test-PastaPermitida "$env:LOCALAPPDATA\Microsoft\Windows\WER\ReportArchive")
Confere 'aceita cache DirectX'     (Test-PastaPermitida "$env:LOCALAPPDATA\D3DSCache")
Confere 'recusa pasta de apps (WhatsApp)' (-not (Test-PastaPermitida "$env:LOCALAPPDATA\Packages"))
Confere 'recusa dados do navegador inteiros' (-not (Test-PastaPermitida "$env:LOCALAPPDATA\Google\Chrome\User Data"))

Write-Output '7) Pastas de cada ação'
foreach ($acao in $script:Acoes) {
    foreach ($pasta in (Obter-PastasDaAcao $acao)) {
        Confere "$($acao.Nome): $pasta passa na trava" (Test-PastaPermitida $pasta)
    }
}
$graficos = $script:Acoes | Where-Object { $_.Id -eq 'Graficos' }
Confere 'cache de gráficos aponta para D3DSCache' (@($graficos.Caminhos) -contains (Join-Path $env:LOCALAPPDATA 'D3DSCache'))
Confere 'toda ação tem explicação' (-not ($script:Acoes | Where-Object { -not $_.Explicacao }))

Remover-PastaSegura $Base
Confere 'pasta de teste apagada' (-not (Test-Path $Base))
Write-Output "RESULTADO: $falhas falha(s)"
if ($falhas -gt 0) { exit 1 }

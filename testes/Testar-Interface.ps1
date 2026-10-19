# Teste de ponta a ponta da interface: instala, abre, navega, otimiza, desfaz, atualiza e desinstala.
# ATENÇÃO: instala e desinstala o app e mexe no %TEMP%. Feito para rodar no GitHub Actions
# (máquina descartável), NÃO no seu PC. As capturas de tela vão para testes\saida.
param([string]$Setup = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Instalar-Otimizador.exe'))
$ErrorActionPreference = 'Stop'
if (-not $env:GITHUB_ACTIONS -and -not $env:OTIMIZADOR_PERMITIR_TESTE_LOCAL) {
    Write-Output 'Este teste instala e desinstala o app. Rode só no GitHub Actions.'
    exit 1
}

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms, System.Drawing
Add-Type -Namespace W -Name U -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
[DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint f);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
public struct RECT { public int Left, Top, Right, Bottom; }
'@
$AE = [System.Windows.Automation.AutomationElement]
$raiz = Split-Path -Parent $PSScriptRoot
$saida = Join-Path $PSScriptRoot 'saida'
New-Item -ItemType Directory -Force -Path $saida | Out-Null

$pastaInst = Join-Path $env:LOCALAPPDATA 'Programs\OtimizadorPC'
$exeInst   = Join-Path $pastaInst 'Otimizador.exe'
$pastaApp  = Join-Path $env:LOCALAPPDATA 'OtimizadorPC'
$chave     = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\OtimizadorPC'
$lnkMenu   = Join-Path ([Environment]::GetFolderPath('Programs')) 'Otimizador de PC.lnk'
$lnkDesk   = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Otimizador de PC.lnk'
$shell     = New-Object -ComObject WScript.Shell
$SIM = @('Sim', 'Yes'); $NAO = @('Não', 'No'); $OK = @('OK')

$falhas = 0
function Confere([string]$Nome, [bool]$Ok) {
    if ($Ok) { Write-Output "  OK    $Nome" } else { Write-Output "  FALHA $Nome"; $script:falhas++ }
}
function Versao { (Get-ItemProperty $chave -ErrorAction SilentlyContinue).DisplayVersion }

# ---------- automação

function Cond([System.Windows.Automation.AutomationProperty]$P, $V) { New-Object System.Windows.Automation.PropertyCondition($P, $V) }

function Esperar-Janela([int]$ProcId, [string]$Nome, [int]$Seg = 30, [IntPtr]$Excluir = [IntPtr]::Zero) {
    # Janela (ou caixa de diálogo) do processo com esse título.
    $fim = (Get-Date).AddSeconds($Seg)
    $condJanela = New-Object System.Windows.Automation.AndCondition((Cond $AE::NameProperty $Nome), (Cond $AE::ControlTypeProperty ([System.Windows.Automation.ControlType]::Window)))
    while ((Get-Date) -lt $fim) {
        foreach ($w in $AE::RootElement.FindAll('Children', (Cond $AE::ProcessIdProperty $ProcId))) {
            $candidatos = @($w) + @($w.FindAll('Descendants', $condJanela))
            foreach ($c in $candidatos) {
                if ($c.Current.Name -eq $Nome -and [IntPtr]$c.Current.NativeWindowHandle -ne $Excluir) { return $c }
            }
        }
        Start-Sleep -Milliseconds 300
    }
    throw "Janela '$Nome' não apareceu"
}

function Achar($Janela, [string]$Id) {
    $e = $Janela.FindFirst('Descendants', (Cond $AE::AutomationIdProperty $Id))
    if (-not $e) { $e = $Janela.FindFirst('Descendants', (Cond $AE::NameProperty $Id)) }
    return $e
}

function Esperar-Elemento($Janela, [string]$Id, [int]$Seg = 30) {
    $fim = (Get-Date).AddSeconds($Seg)
    while ((Get-Date) -lt $fim) { $e = Achar $Janela $Id; if ($e -and -not $e.Current.IsOffscreen) { return $e }; Start-Sleep -Milliseconds 300 }
    return $null
}

function Clicar($Janela, [string[]]$Ids) {
    $e = $null
    foreach ($id in $Ids) { $e = Achar $Janela $id; if ($e) { break } }
    if (-not $e) { throw "Elemento '$($Ids -join '/')' não encontrado" }
    $padroes = $e.GetSupportedPatterns()
    if ($padroes -contains [System.Windows.Automation.SelectionItemPattern]::Pattern) {
        $e.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    } elseif ($padroes -contains [System.Windows.Automation.InvokePattern]::Pattern -and $e.Current.FrameworkId -eq 'WPF') {
        # Em outra thread: o clique pode abrir uma caixa modal
        $rs = [powershell]::Create()
        [void]$rs.AddScript({ param($x) $x.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() }).AddArgument($e)
        [void]$rs.BeginInvoke()
    } elseif ($e.Current.NativeWindowHandle -ne 0) {
        [void][W.U]::PostMessage([IntPtr]$e.Current.NativeWindowHandle, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero)   # BM_CLICK
    } else {
        $rs = [powershell]::Create()
        [void]$rs.AddScript({ param($x) $x.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() }).AddArgument($e)
        [void]$rs.BeginInvoke()
    }
    Start-Sleep -Milliseconds 700
}

function Texto($Janela, [string]$Id) {
    # Caixa de texto de várias linhas: TextPattern; uma linha: ValuePattern; TextBlock: Name
    $e = Achar $Janela $Id
    if (-not $e) { return $null }
    $padroes = $e.GetSupportedPatterns()
    if ($padroes -contains [System.Windows.Automation.TextPattern]::Pattern) {
        return $e.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern).DocumentRange.GetText(-1)
    }
    if ($padroes -contains [System.Windows.Automation.ValuePattern]::Pattern) {
        return $e.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
    }
    return $e.Current.Name
}

function Esperar-Texto($Janela, [string]$Id, [scriptblock]$Condicao, [int]$Seg = 60) {
    $fim = (Get-Date).AddSeconds($Seg)
    while ((Get-Date) -lt $fim) { $t = Texto $Janela $Id; if ($t -and (& $Condicao $t)) { return $t }; Start-Sleep -Milliseconds 400 }
    return $null
}

function Capturar($Janela, [string]$Nome) {
    Start-Sleep -Milliseconds 600
    $h = [IntPtr]$Janela.Current.NativeWindowHandle
    $r = New-Object W.U+RECT
    [void][W.U]::GetWindowRect($h, [ref]$r)
    $bmp = New-Object System.Drawing.Bitmap(($r.Right - $r.Left), ($r.Bottom - $r.Top))
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $dc = $g.GetHdc(); [void][W.U]::PrintWindow($h, $dc, 2); $g.ReleaseHdc($dc)
    $bmp.Save((Join-Path $saida "$Nome.png")); $g.Dispose(); $bmp.Dispose()
}

function Esperar-Processo([string]$Caminho, [int]$Seg = 30, [int]$Diferente = 0) {
    $fim = (Get-Date).AddSeconds($Seg)
    while ((Get-Date) -lt $fim) {
        $p = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $Caminho -and $_.Id -ne $Diferente } | Select-Object -First 1
        if ($p) { return $p }
        Start-Sleep -Milliseconds 300
    }
    return $null
}

function Instalar([string]$Exe) {
    $p = Start-Process $Exe -PassThru
    $w = Esperar-Janela $p.Id 'Instalar Otimizador de PC'
    Capturar $w '01-instalador'
    Clicar $w 'Instalar'
    Clicar (Esperar-Janela $p.Id 'Instalar') $NAO
    Confere 'instalador fechou' ($p.WaitForExit(15000))
}

function Desinstalar {
    $p = Start-Process $exeInst -ArgumentList '/desinstalar' -PassThru
    Clicar (Esperar-Janela $p.Id 'Desinstalar') $SIM
    Clicar (Esperar-Janela $p.Id 'Desinstalar') $OK
    [void]$p.WaitForExit(15000); Start-Sleep -Seconds 4
    Confere 'desinstalado: registro, atalhos, programa e dados removidos' (
        -not (Test-Path $chave) -and -not (Test-Path $lnkMenu) -and -not (Test-Path $lnkDesk) -and
        -not (Test-Path $exeInst) -and -not (Test-Path $pastaApp))
}

function Abrir-App([string]$Titulo = 'Otimizador de PC') {
    Start-Process $exeInst | Out-Null
    $p = Esperar-Processo $exeInst
    return @{ Processo = $p; Janela = (Esperar-Janela $p.Id $Titulo) }
}

function Fechar-App($App) {
    try { Clicar $App.Janela 'BtnFechar' } catch { }
    if (-not $App.Processo.WaitForExit(10000)) { $App.Processo.Kill() }
}

# ---------- arquivos de teste no %TEMP% (antigos, para a otimização ter o que limpar)

$lixo = Join-Path $env:TEMP 'otimizador-teste-lixo'
New-Item -ItemType Directory -Force -Path $lixo | Out-Null
1..3 | ForEach-Object {
    $f = Join-Path $lixo "antigo$_.tmp"
    Set-Content -LiteralPath $f -Value ('x' * 50000)
    (Get-Item $f).LastWriteTime = (Get-Date).AddDays(-5)
}

try {
    Write-Output '1) Instalar'
    Instalar $Setup
    Confere 'programa copiado' (Test-Path $exeInst)
    Confere 'ícone na Área de Trabalho' ((Test-Path $lnkDesk) -and $shell.CreateShortcut($lnkDesk).TargetPath -eq $exeInst)
    Confere 'atalho no Menu Iniciar' (Test-Path $lnkMenu)
    Confere 'aparece em Programas e Recursos' ([bool](Versao))

    Write-Output '2) Instalar de novo mostra "Já instalado"'
    $p = Start-Process $Setup -PassThru
    $m = Esperar-Janela $p.Id 'Já instalado'
    Capturar $m '02-ja-instalado'
    Clicar $m $OK
    Confere 'fechou sem reinstalar' ($p.WaitForExit(10000))

    Write-Output '3) Abrir o app e navegar'
    $app = Abrir-App
    $w = $app.Janela
    Confere 'nota de saúde calculada' ([bool](Esperar-Texto $w 'TxtNotaInicio' { param($t) $t -match '^\d+$' }))
    Confere 'status do sistema preenchido' ([bool](Esperar-Texto $w 'TxtSaudeLateral' { param($t) $t -like 'Saúde do PC:*' }))
    Start-Sleep -Seconds 4   # deixa o status do sistema atualizar
    Capturar $w '03-inicio'
    Clicar $w 'NavDiagnostico'
    Confere 'diagnóstico terminou' ([bool](Esperar-Texto $w 'TxtRotuloDiag' { param($t) $t -ne 'Analisando...' }))
    Capturar $w '04-diagnostico'
    Clicar $w 'NavHistorico';     Capturar $w '05-historico-vazio'
    Clicar $w 'NavInicializacao'; Capturar $w '06-inicializacao'
    Clicar $w 'NavConfig';        Capturar $w '07-configuracoes'
    Clicar $w 'NavInicio'

    Write-Output '4) "O que será feito?" e Analisar'
    Clicar $w 'BtnExplicar'
    $m = Esperar-Janela $app.Processo.Id 'O que será feito'
    Capturar $m '08a-o-que-sera-feito'
    Clicar $m $OK
    Confere 'explicação das ações abriu e fechou' ($true)
    Clicar $w 'BtnAnalisar'
    Confere 'análise mostrou o total' ([bool](Esperar-Texto $w 'TxtLog' { param($t) $t -match 'Total:' }))
    Confere 'caixa de registro visível (altura de pelo menos 60 px)' ((Achar $w 'TxtLog').Current.BoundingRectangle.Height -ge 60)
    Capturar $w '08-analise'

    Write-Output '5) Otimizar'
    Clicar $w 'BtnOtimizar'
    $m = Esperar-Janela $app.Processo.Id 'Confirmar otimização'
    Capturar $m '09-confirmar-otimizacao'
    Clicar $m $SIM
    $m = Esperar-Janela $app.Processo.Id 'Otimizador de PC' 120 ([IntPtr]$w.Current.NativeWindowHandle)
    Clicar $m $OK
    Confere 'arquivos antigos de teste saíram do %TEMP%' (-not (Test-Path (Join-Path $lixo 'antigo1.tmp')))
    Confere 'última limpeza preenchida' ((Texto $w 'TxtUltimaLimpeza') -like 'Hoje*')
    Capturar $w '10-pos-otimizacao'
    Clicar $w 'NavHistorico'; Capturar $w '11-historico'
    Clicar $w 'NavInicio'

    Write-Output '6) Desfazer'
    Clicar $w 'BtnDesfazer'
    Clicar (Esperar-Janela $app.Processo.Id 'Desfazer última limpeza') $SIM
    Confere 'registro mostra arquivos devolvidos' ([bool](Esperar-Texto $w 'TxtLog' { param($t) $t -match 'devolvidos' }))
    Confere 'arquivos de teste voltaram para o %TEMP%' (Test-Path (Join-Path $lixo 'antigo1.tmp'))
    Capturar $w '12-desfeito'
    Fechar-App $app

    Write-Output '7) Atualização automática (servidor local imitando o GitHub)'
    $versaoAtual = Versao
    $versaoNova = '9.9.9'
    $trabalho = Join-Path $env:TEMP 'otimizador-teste-atualizacao'
    if (Test-Path $trabalho) { Remove-Item $trabalho -Recurse -Force }
    $codigo = [IO.File]::ReadAllText((Join-Path $raiz 'Otimizador.ps1'))
    $codigo = $codigo.Replace('$script:UrlReleases      = "https://github.com/$($script:RepoGitHub)/releases"', '$script:UrlReleases      = "http://localhost:8765/releases"')
    foreach ($v in $versaoAtual, $versaoNova) {
        $d = Join-Path $trabalho $v
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        [IO.File]::WriteAllText((Join-Path $d 'Otimizador.ps1'), ($codigo -replace "\`$script:Versao(\s*)= '[\d.]+'", "`$script:Versao`$1= '$v'"), (New-Object Text.UTF8Encoding($true)))
        [IO.File]::WriteAllText((Join-Path $d 'NOVIDADES.md'), "## $v`r`n- Novidade de teste da versão $v.`r`n", (New-Object Text.UTF8Encoding($false)))
        Copy-Item (Join-Path $raiz 'Gerar-EXE.ps1') $d
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $d 'Gerar-EXE.ps1') | Out-Null
    }
    $servidor = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'Servidor-Teste.ps1'), '-Pasta', (Join-Path $trabalho $versaoNova))
    Start-Sleep -Seconds 2

    Desinstalar
    Instalar (Join-Path (Join-Path $trabalho $versaoAtual) 'Instalar-Otimizador.exe')
    $app = Abrir-App
    $btn = Esperar-Elemento $app.Janela 'BtnAtualizar' 40
    Confere 'botão "Atualizar" apareceu' ([bool]$btn)
    Capturar $app.Janela '13-atualizacao-disponivel'
    Clicar $app.Janela 'BtnAtualizar'
    $m = Esperar-Janela $app.Processo.Id 'Atualizar'
    Capturar $m '14-confirmar-atualizacao'
    Clicar $m $SIM
    Confere 'app antigo fechou' ($app.Processo.WaitForExit(30000))
    $novo = Esperar-Processo $exeInst 60 $app.Processo.Id
    $n = Esperar-Janela $novo.Id "Novidades da versão $versaoNova" 60
    Capturar $n '15-novidades'
    Clicar $n $OK
    Confere "Programas e Recursos mostra $versaoNova" ((Versao) -eq $versaoNova)
    Fechar-App @{ Processo = $novo; Janela = (Esperar-Janela $novo.Id 'Otimizador de PC') }
    Stop-Process -Id $servidor.Id -Force -ErrorAction SilentlyContinue

    Write-Output '8) Desinstalar pelo Painel de Controle'
    Desinstalar
} catch {
    Write-Output "  FALHA erro inesperado: $($_.Exception.Message)"
    Write-Output $_.ScriptStackTrace
    $falhas++
    try {
        $tela = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $bmp = New-Object System.Drawing.Bitmap($tela.Width, $tela.Height)
        $g = [System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen(0, 0, 0, 0, $bmp.Size)
        $bmp.Save((Join-Path $saida 'erro-tela.png')); $g.Dispose(); $bmp.Dispose()
    } catch { }
}

Write-Output "RESULTADO: $falhas falha(s)"
if ($falhas -gt 0) { exit 1 }

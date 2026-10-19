# Gera o Instalar-Otimizador.exe a partir do Otimizador.ps1 usando o PS2EXE.
# O mesmo exe instala, abre o app e desinstala (ver seção "Instalação" no Otimizador.ps1).
# Uso: clique com o botão direito > "Executar com o PowerShell"
#  ou: powershell -ExecutionPolicy Bypass -File .\Gerar-EXE.ps1
#
# As novidades (patch notes) vêm da seção "## <versão>" do NOVIDADES.md. Elas vão
# embutidas no exe (o app mostra depois de atualizar) e no versao.json, que vai junto
# na Release do GitHub e é lido pelo app para saber se há atualização.

$ErrorActionPreference = 'Stop'
$pasta      = Split-Path -Parent $MyInvocation.MyCommand.Path
$entrada    = Join-Path $pasta 'Otimizador.ps1'
$novidades  = Join-Path $pasta 'NOVIDADES.md'
$saida      = Join-Path $pasta 'Instalar-Otimizador.exe'
$utf8Bom    = New-Object Text.UTF8Encoding($true)
$codigo     = [IO.File]::ReadAllText($entrada)

# A versão vem do próprio script ($script:Versao), para ficar igual no exe e no Painel de Controle
$versao = [regex]::Match($codigo, "\`$script:Versao\s*=\s*'([\d.]+)'").Groups[1].Value
if (-not $versao) { Write-Host 'Não encontrei $script:Versao no Otimizador.ps1.' -ForegroundColor Red; exit 1 }

# 1. Valida a sintaxe antes de compilar
$tokens = $null; $erros = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($entrada, [ref]$tokens, [ref]$erros)
if ($erros) {
    foreach ($e in $erros) { Write-Host ("Erro de sintaxe na linha {0}: {1}" -f $e.Extent.StartLineNumber, $e.Message) -ForegroundColor Red }
    exit 1
}
Write-Host 'Sintaxe OK.' -ForegroundColor Green

# 2. Lê as novidades desta versão no NOVIDADES.md
$md = if (Test-Path $novidades) { [IO.File]::ReadAllText($novidades, [Text.Encoding]::UTF8) } else { '' }
$padrao = '(?ms)^##[ \t]*' + [regex]::Escape($versao) + '[ \t]*\r?$(.*?)(?=^##[ \t]|\z)'
$secao = [regex]::Match($md, $padrao)
$notas = ($secao.Groups[1].Value -replace "`r`n", "`n").Trim()
if (-not $notas) {
    Write-Host "Escreva as novidades da versão $versao no NOVIDADES.md (uma seção '## $versao') e rode de novo." -ForegroundColor Red
    exit 1
}
Write-Host "Novidades da versão ${versao}:" -ForegroundColor Green
Write-Host $notas

# 3. Instala o ps2exe só para o usuário atual (não precisa de administrador)
if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host 'Instalando o módulo ps2exe (somente para o usuário atual)...'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
    }
    Install-Module -Name ps2exe -Scope CurrentUser -Force
}
Import-Module ps2exe

# 4. Ícone a partir da imagem da pasta "logo" (opcional)
Add-Type -AssemblyName System.Drawing

function Converter-ParaPng {
    param([System.Drawing.Image]$Imagem, [int]$Lado)
    $bmp = New-Object System.Drawing.Bitmap($Lado, $Lado, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = 'HighQualityBicubic'; $g.SmoothingMode = 'AntiAlias'; $g.PixelOffsetMode = 'HighQuality'
    $g.DrawImage($Imagem, 0, 0, $Lado, $Lado)
    $g.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    return ,$ms.ToArray()
}

function Preparar-Logo {
    # Recorta a logo num quadrado justo. Se ela for redonda sobre um fundo liso (como cantos pretos),
    # o fundo fora do círculo vira transparente. Devolve uma imagem 512 x 512 com transparência.
    param([string]$Caminho)
    $orig = [System.Drawing.Bitmap]::FromFile($Caminho)
    try {
        $w = $orig.Width; $h = $orig.Height
        $fundo = $orig.GetPixel(2, 2)
        $ehFundo = { param($x, $y) $c = $orig.GetPixel($x, $y); ([math]::Abs($c.R - $fundo.R) + [math]::Abs($c.G - $fundo.G) + [math]::Abs($c.B - $fundo.B)) -lt 60 -and $c.A -gt 200 }
        $meioX = [int]($w / 2); $meioY = [int]($h / 2)
        $esq = 0;       while ($esq -lt $meioX -and (& $ehFundo $esq $meioY)) { $esq++ }
        $dir = $w - 1;  while ($dir -gt $meioX -and (& $ehFundo $dir $meioY)) { $dir-- }
        $topo = 0;      while ($topo -lt $meioY -and (& $ehFundo $meioX $topo)) { $topo++ }
        $base = $h - 1; while ($base -gt $meioY -and (& $ehFundo $meioX $base)) { $base-- }
        $lado = [math]::Max($dir - $esq, $base - $topo) + 1
        $cx = ($esq + $dir) / 2; $cy = ($topo + $base) / 2
        $origem = New-Object System.Drawing.RectangleF(($cx - $lado / 2), ($cy - $lado / 2), $lado, $lado)
        # Redonda = o canto do quadrado justo ainda é fundo
        $redonda = & $ehFundo ([int]($cx - $lado * 0.45)) ([int]($cy - $lado * 0.45))

        $quadro = New-Object System.Drawing.Bitmap(512, 512, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($quadro)
        $g.InterpolationMode = 'HighQualityBicubic'; $g.SmoothingMode = 'AntiAlias'; $g.PixelOffsetMode = 'HighQuality'
        $destino = New-Object System.Drawing.RectangleF(0, 0, 512, 512)
        if ($redonda) {
            $temp = New-Object System.Drawing.Bitmap(512, 512, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $gt = [System.Drawing.Graphics]::FromImage($temp)
            $gt.InterpolationMode = 'HighQualityBicubic'; $gt.PixelOffsetMode = 'HighQuality'
            $gt.DrawImage($orig, $destino, $origem, [System.Drawing.GraphicsUnit]::Pixel)
            $gt.Dispose()
            $pincel = New-Object System.Drawing.TextureBrush($temp)
            $g.FillEllipse($pincel, 0, 0, 511, 511)
            $pincel.Dispose(); $temp.Dispose()
        } else {
            $g.DrawImage($orig, $destino, $origem, [System.Drawing.GraphicsUnit]::Pixel)
        }
        $g.Dispose()
        return $quadro
    } finally { $orig.Dispose() }
}

function Converter-ParaDib {
    # Formato clássico de ícone (bitmap 32 bits com transparência), entendido por qualquer programa
    param([System.Drawing.Image]$Imagem, [int]$Lado)
    $bmp = New-Object System.Drawing.Bitmap($Lado, $Lado, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = 'HighQualityBicubic'; $g.SmoothingMode = 'AntiAlias'; $g.PixelOffsetMode = 'HighQuality'
    $g.DrawImage($Imagem, 0, 0, $Lado, $Lado)
    $g.Dispose()
    $dados = $bmp.LockBits((New-Object System.Drawing.Rectangle(0, 0, $Lado, $Lado)), 'ReadOnly', [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $linha = $Lado * 4
    $pixels = New-Object byte[] ($linha * $Lado)
    for ($y = 0; $y -lt $Lado; $y++) {
        # o .ico guarda as linhas de baixo para cima
        [System.Runtime.InteropServices.Marshal]::Copy([IntPtr]($dados.Scan0.ToInt64() + $y * $dados.Stride), $pixels, ($Lado - 1 - $y) * $linha, $linha)
    }
    $bmp.UnlockBits($dados); $bmp.Dispose()
    $mascara = New-Object byte[] ([int]([math]::Ceiling($Lado / 32)) * 4 * $Lado)   # máscara AND vazia (a transparência vem do alfa)
    $ms = New-Object System.IO.MemoryStream
    $w = New-Object System.IO.BinaryWriter($ms)
    $w.Write([uint32]40); $w.Write([int32]$Lado); $w.Write([int32]($Lado * 2)); $w.Write([uint16]1); $w.Write([uint16]32)
    $w.Write([uint32]0); $w.Write([uint32]($pixels.Length + $mascara.Length)); $w.Write([int32]0); $w.Write([int32]0); $w.Write([uint32]0); $w.Write([uint32]0)
    $w.Write($pixels); $w.Write($mascara); $w.Flush()
    $resultado = $ms.ToArray(); $w.Dispose()
    return ,$resultado
}

function Salvar-Ico {
    # .ico com vários tamanhos: 256 em PNG (padrão do Windows) e os menores no formato clássico
    param([System.Drawing.Image]$Imagem, [string]$Destino)
    $tamanhos = @(256, 128, 64, 48, 32, 24, 16)
    $imagens = foreach ($t in $tamanhos) { if ($t -ge 256) { ,(Converter-ParaPng $Imagem $t) } else { ,(Converter-ParaDib $Imagem $t) } }
    $saidaIco = New-Object System.IO.MemoryStream
    $w = New-Object System.IO.BinaryWriter($saidaIco)
    $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$tamanhos.Count)
    $posicao = 6 + 16 * $tamanhos.Count
    for ($i = 0; $i -lt $tamanhos.Count; $i++) {
        $t = $tamanhos[$i]; $dados = $imagens[$i]
        $w.Write([byte]($t % 256)); $w.Write([byte]($t % 256))   # 256 é gravado como 0
        $w.Write([byte]0); $w.Write([byte]0); $w.Write([uint16]1); $w.Write([uint16]32)
        $w.Write([uint32]$dados.Length); $w.Write([uint32]$posicao)
        $posicao += $dados.Length
    }
    foreach ($dados in $imagens) { $w.Write($dados) }
    $w.Flush()
    [IO.File]::WriteAllBytes($Destino, $saidaIco.ToArray())
    $w.Dispose()
}

$parametrosIcone = @{}
$logoBase64 = ''
$arquivoLogo = Get-ChildItem -Path (Join-Path $pasta 'logo') -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -in '.png', '.jpg', '.jpeg' } | Sort-Object Name | Select-Object -First 1
if ($arquivoLogo) {
    $logo = Preparar-Logo $arquivoLogo.FullName
    $icone = Join-Path $pasta 'logo\icone.ico'
    Salvar-Ico $logo $icone
    $logoBase64 = [Convert]::ToBase64String((Converter-ParaPng $logo 96))   # vai embutido no app (canto da janela)
    $logo.Dispose()
    $parametrosIcone.iconFile = $icone
    Write-Host "Ícone gerado a partir de logo\$($arquivoLogo.Name)." -ForegroundColor Green
} else {
    Write-Host 'Sem imagem na pasta logo: usando o ícone padrão.' -ForegroundColor Yellow
}

# 5. Embute as novidades e a logo numa cópia temporária do script (o Otimizador.ps1 não é alterado)
$marcador = "`$script:NotasVersao     = ''"
$marcadorLogo = "`$script:LogoBase64      = ''"
if (-not $codigo.Contains($marcador) -or -not $codigo.Contains($marcadorLogo)) {
    Write-Host 'Não encontrei $script:NotasVersao ou $script:LogoBase64 no Otimizador.ps1.' -ForegroundColor Red; exit 1
}
$pastaTemp = Join-Path $env:TEMP 'OtimizadorPC-build'
[void][IO.Directory]::CreateDirectory($pastaTemp)
$temporario = Join-Path $pastaTemp 'Otimizador.ps1'
$codigoFinal = $codigo.Replace($marcador, "`$script:NotasVersao     = '" + $notas.Replace("'", "''") + "'").Replace($marcadorLogo, "`$script:LogoBase64      = '$logoBase64'")
[IO.File]::WriteAllText($temporario, $codigoFinal, $utf8Bom)

# 6. Compila: sem console e sem pedir administrador
try {
    Invoke-ps2exe -inputFile $temporario -outputFile $saida -noConsole -STA `
        -title 'Otimizador de PC' -product 'Otimizador de PC' `
        -description 'Limpeza segura de arquivos temporários e cache' -version "$versao.0" @parametrosIcone
} finally {
    Remove-Item -LiteralPath $temporario -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path $saida)) {
    Write-Host 'Falha ao gerar o exe.' -ForegroundColor Red
    exit 1
}
Write-Host ("Gerado: {0} ({1:N0} KB)" -f $saida, ((Get-Item $saida).Length / 1KB)) -ForegroundColor Green

# 7. versao.json (UTF-8 sem BOM, para o app ler direto do GitHub)
$json = [ordered]@{
    versao = $versao
    sha256 = (Get-FileHash -LiteralPath $saida -Algorithm SHA256).Hash
    notas  = $notas
} | ConvertTo-Json
[IO.File]::WriteAllText((Join-Path $pasta 'versao.json'), $json, (New-Object Text.UTF8Encoding($false)))
Write-Host "Gerado: versao.json (versão $versao)" -ForegroundColor Green

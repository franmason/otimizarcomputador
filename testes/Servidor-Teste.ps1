# Servidor local que imita o GitHub Releases: devolve o arquivo da pasta pelo último segmento da URL.
param([string]$Pasta, [string]$Prefixo = 'http://localhost:8765/')
$l = New-Object System.Net.HttpListener
$l.Prefixes.Add($Prefixo)
$l.Start()
while ($l.IsListening) {
    $ctx = $l.GetContext()
    $nome = [IO.Path]::GetFileName($ctx.Request.Url.AbsolutePath)
    $arq = Join-Path $Pasta $nome
    Add-Content -Path (Join-Path $Pasta 'acessos.log') -Value $ctx.Request.Url.AbsolutePath
    if ($nome -and (Test-Path -LiteralPath $arq)) {
        $bytes = [IO.File]::ReadAllBytes($arq)
        $ctx.Response.ContentLength64 = $bytes.Length
        $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    } else {
        $ctx.Response.StatusCode = 404
    }
    $ctx.Response.Close()
}

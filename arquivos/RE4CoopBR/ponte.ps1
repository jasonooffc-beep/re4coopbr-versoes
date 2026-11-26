# RE4 Co-op BR - ponte de rede UDP
# Liga o jogo (scripts Lua do REFramework) ao PC do parceiro.
# O Lua escreve out.json / ctl.json e le in.json / status.json em reframework\data\RE4CoopBR.
# A ponte so repassa bytes: nao interpreta o estado do jogo, entao e leve e rapida.
#
# Pacotes UDP (1o byte = tipo):
#   'S' (83) estado do jogo (conteudo de out.json)
#   'P' (80) ping com timestamp, 'Q' (81) resposta do ping

param([string]$Dados)

$Host.UI.RawUI.WindowTitle = 'RE4 Co-op BR - Ponte de rede'
if (-not $Dados) { $Dados = Join-Path $PSScriptRoot '..\reframework\data\RE4CoopBR' }
$Dados = [IO.Path]::GetFullPath($Dados)
[IO.Directory]::CreateDirectory($Dados) | Out-Null

$arqCtl    = Join-Path $Dados 'ctl.json'
$arqOut    = Join-Path $Dados 'out.json'
$arqIn     = Join-Path $Dados 'in.json'
$arqInTmp  = Join-Path $Dados 'in.json.tmp'
$arqStatus = Join-Path $Dados 'status.json'
$utf8 = New-Object Text.UTF8Encoding($false)

# Timer do Windows em 1 ms: o loop reage mais rapido (menos latencia)
try {
    Add-Type -Namespace RE4CoopBR -Name Win -MemberDefinition '[DllImport("winmm.dll")] public static extern uint timeBeginPeriod(uint p);'
    [RE4CoopBR.Win]::timeBeginPeriod(1) | Out-Null
} catch { }

$relogio = [Diagnostics.Stopwatch]::StartNew()
function Ms { $relogio.Elapsed.TotalMilliseconds }

$s = @{
    udp = $null; remoto = $null; modo = 'parado'; porta = 27420; ip = ''
    ctlTexto = ''; ctlMtime = [DateTime]::MinValue; ultimoOut = ''; proxOut = 0; pendIn = $null
    ultimoRx = -1e9; ping = 0; rx = 0; tx = 0; erro = ''
    proxPing = 0; proxStatus = 0; proxCtl = 0; contador = 0; conectadoAntes = $false
}

function Log($m) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }

function IPsLocais {
    try {
        [Net.Dns]::GetHostAddresses([Net.Dns]::GetHostName()) |
            Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
            ForEach-Object { $_.ToString() } |
            Where-Object { -not $_.StartsWith('127.') -and -not $_.StartsWith('169.254.') }
    } catch { }
}
$ips = @(IPsLocais)

function LerCompartilhado($p) {
    $fs = [IO.File]::Open($p, 'Open', 'Read', 'ReadWrite, Delete')
    try {
        $ms = New-Object IO.MemoryStream
        $fs.CopyTo($ms)
        return , $ms.ToArray()
    } finally { $fs.Dispose() }
}

function Fechar {
    if ($s.udp) { try { $s.udp.Close() } catch { } }
    $s.udp = $null
    $s.remoto = $null
}

function Abrir {
    Fechar
    $s.erro = ''
    $s.ultimoRx = -1e9
    $s.pendIn = $null
    try { [IO.File]::Delete($arqIn) } catch { } # estado do parceiro da sessao anterior
    try {
        if ($s.modo -eq 'host') {
            $u = New-Object Net.Sockets.UdpClient($s.porta)
            Log "Sala aberta na porta UDP $($s.porta)."
            Log "Passe um destes IPs para o parceiro: $($ips -join '  |  ')"
        } elseif ($s.modo -eq 'entrar') {
            $addr = $null
            $alvo = $s.ip.Trim()
            if (-not [Net.IPAddress]::TryParse($alvo, [ref]$addr)) {
                $addr = [Net.Dns]::GetHostAddresses($alvo) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
            }
            if (-not $addr) { throw "IP invalido: '$alvo'" }
            $u = New-Object Net.Sockets.UdpClient(0)
            $s.remoto = New-Object Net.IPEndPoint($addr, $s.porta)
            Log "Conectando em $($s.remoto) ..."
        } else {
            Log 'Desconectado (parado).'
            return
        }
        # Ignora o erro ICMP "porta inalcancavel" do Windows (SIO_UDP_CONNRESET),
        # senao o socket quebra enquanto o anfitriao ainda nao abriu a sala.
        [void]$u.Client.IOControl(-1744830452, [byte[]](0, 0, 0, 0), $null)
        $s.udp = $u
    } catch [Net.Sockets.SocketException] {
        if ($_.Exception.ErrorCode -eq 10048) {
            $s.erro = "Porta $($s.porta) ja esta em uso (outra ponte aberta?)"
        } else { $s.erro = $_.Exception.Message }
        Log "ERRO: $($s.erro)"
    } catch {
        $s.erro = $_.Exception.Message
        Log "ERRO: $($s.erro)"
    }
}

function Enviar([byte]$tipo, [byte[]]$dados) {
    if (-not $s.udp -or -not $s.remoto) { return }
    $pkt = New-Object byte[] ($dados.Length + 1)
    $pkt[0] = $tipo
    [Array]::Copy($dados, 0, $pkt, 1, $dados.Length)
    try { [void]$s.udp.Send($pkt, $pkt.Length, $s.remoto); $s.tx++ } catch { $s.erro = $_.Exception.Message }
}

function Resto([byte[]]$b) {
    $d = New-Object byte[] ($b.Length - 1)
    [Array]::Copy($b, 1, $d, 0, $d.Length)
    return , $d
}

Write-Host ''
Write-Host '  ==========================================' -ForegroundColor Yellow
Write-Host '    RE4 Co-op BR - ponte de rede' -ForegroundColor Yellow
Write-Host '  ==========================================' -ForegroundColor Yellow
Write-Host ''
Log "Pasta de dados: $Dados"
Log "IPs deste PC: $($ips -join '  |  ')"
Log 'Deixe esta janela aberta enquanto joga. Controle tudo pelo painel no jogo (F8).'
Write-Host ''

try {
    while ($true) {
        $t = Ms

        # 1) Comandos do jogo (criar sala / entrar / desconectar)
        if ($t -ge $s.proxCtl) {
            $s.proxCtl = $t + 300
            try {
                if ([IO.File]::Exists($arqCtl)) {
                    $mt = [IO.File]::GetLastWriteTimeUtc($arqCtl)
                    if ($mt -ne $s.ctlMtime) {
                        $txt = $utf8.GetString((LerCompartilhado $arqCtl))
                        $c = $txt | ConvertFrom-Json
                        $s.ctlMtime = $mt
                        if ($txt -ne $s.ctlTexto) {
                            $s.ctlTexto = $txt
                            $s.modo = [string]$c.modo
                            $s.ip = [string]$c.ip
                            if ($c.porta) { $s.porta = [int]$c.porta }
                            Abrir
                        }
                    }
                }
            } catch { } # arquivo no meio de uma escrita: tenta de novo em 300 ms
        }

        if ($s.udp) {
            # 2) Recebe tudo que chegou
            try {
                while ($s.udp -and $s.udp.Available -gt 0) {
                    $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
                    $b = $s.udp.Receive([ref]$ep)
                    if ($b.Length -lt 1) { continue }
                    if ($s.modo -eq 'host') {
                        $mesmo = $s.remoto -and $s.remoto.Equals($ep)
                        if (-not $mesmo) {
                            # Aceita um novo parceiro so se o atual sumiu
                            if ($s.remoto -and ($t - $s.ultimoRx) -lt 3000) { continue }
                            $s.remoto = $ep
                            Log "Parceiro chegou de $ep"
                        }
                    } elseif (-not $ep.Equals($s.remoto)) { continue }

                    $s.ultimoRx = $t
                    $s.rx++
                    switch ($b[0]) {
                        83 { $s.pendIn = Resto $b }
                        80 { Enviar 81 (Resto $b) }
                        81 { if ($b.Length -ge 9) { $s.ping = [int][Math]::Max(0, $t - [BitConverter]::ToDouble($b, 1)) } }
                    }
                }
            } catch { $s.erro = $_.Exception.Message }

            # So o estado mais novo importa; se o jogo estiver lendo o arquivo agora, tenta no proximo giro
            if ($s.pendIn) {
                # Escreve num temporario e troca de uma vez: o jogo nunca ve o arquivo pela metade
                try {
                    [IO.File]::WriteAllBytes($arqInTmp, $s.pendIn)
                    if ([IO.File]::Exists($arqIn)) { [IO.File]::Replace($arqInTmp, $arqIn, [NullString]::Value) }
                    else { [IO.File]::Move($arqInTmp, $arqIn) }
                    $s.pendIn = $null
                } catch { }
            }

            # 3) Repassa o estado local assim que o jogo escreve um novo.
            #    Compara o conteudo (nao a data do arquivo) e so envia JSON completo,
            #    para nunca perder nem mandar uma escrita pela metade.
            if ($s.remoto -and $t -ge $s.proxOut) {
                $s.proxOut = $t + 8
                try {
                    if ([IO.File]::Exists($arqOut)) {
                        $d = LerCompartilhado $arqOut
                        $n = $d.Length
                        while ($n -gt 0 -and $d[$n - 1] -le 32) { $n-- }
                        if ($n -gt 1 -and $n -lt 60000 -and $d[0] -eq 123 -and $d[$n - 1] -eq 125) {
                            $txt = [Convert]::ToBase64String($d, 0, $n)
                            if ($txt -ne $s.ultimoOut) {
                                $s.ultimoOut = $txt
                                Enviar 83 $d
                            }
                        }
                    }
                } catch { }

                # 4) Ping a cada 1 s (tambem serve de "ola" para o anfitriao achar o convidado)
                if ($t -ge $s.proxPing) {
                    $s.proxPing = $t + 1000
                    Enviar 80 ([BitConverter]::GetBytes([double]$t))
                }
            }
        }

        # 5) Status para o painel do jogo
        if ($t -ge $s.proxStatus) {
            $s.proxStatus = $t + 250
            $s.contador++
            $con = ($t - $s.ultimoRx) -lt 3000
            if ($con -ne $s.conectadoAntes) {
                $s.conectadoAntes = $con
                if ($con) { Log "CONECTADO! (ping ~$($s.ping) ms)" }
                elseif ($s.modo -ne 'parado') { Log 'Sem resposta do parceiro... aguardando.' }
            }
            $st = @{
                relogio = $s.contador; modo = $s.modo; conectado = $con; ping = $s.ping
                remoto = $(if ($s.remoto) { $s.remoto.ToString() } else { '' })
                ips = $ips; erro = $s.erro; rx = $s.rx; tx = $s.tx; porta = $s.porta
            }
            try { [IO.File]::WriteAllText($arqStatus, ($st | ConvertTo-Json -Compress), $utf8) } catch { }
        }

        # Espera no proprio socket: acorda na hora em que um pacote chega
        if ($s.udp) {
            try { [void]$s.udp.Client.Poll($(if ($s.pendIn) { 1000 } else { 8000 }), [Net.Sockets.SelectMode]::SelectRead) } catch { Start-Sleep -Milliseconds 8 }
        } else {
            Start-Sleep -Milliseconds 50
        }
    }
} finally {
    Fechar
}

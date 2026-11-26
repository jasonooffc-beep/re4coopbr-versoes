--[[
    RE4 Co-op BR - co-op para 2 jogadores no Resident Evil 4 Remake (REFramework)

    Cada jogador roda o proprio jogo localmente (zero input lag). Este script le o
    estado do seu personagem, troca com o parceiro pelo plugin de rede
    (reframework\plugins
e4coopbr_rede.dll: sala e convite da Steam, ou IP direto) e:
      - mostra o parceiro no seu jogo (Ashley/Luis como avatar + nome flutuante)
      - puxa quem ficou para tras (anti-preso) e marca a porta usada pelo parceiro
      - sincroniza a vida dos inimigos (experimental)
      - chat simples

    Comunicacao com o plugin de rede (pasta reframework/data/RE4CoopBR):
      ctl.json    -> Lua escreve: modo (host/entrar/parado), rede (steam/ip), ip, porta, sala, pronto, inicio
      out.json    -> Lua escreve: estado local (30x por segundo)
      in.json     <- plugin escreve: ultimo estado recebido do parceiro
      status.json <- plugin escreve: conexao, ping, sala Steam (membros, pronto, inicio), convites
    (A ponte antiga RE4CoopBR\Iniciar-Ponte.bat ainda funciona no modo IP, sem o plugin.)
]]

local VERSAO = "0.27.2"
local PASTA = "RE4CoopBR/"
local ARQ = {
    cfg = PASTA .. "config.json",
    ctl = PASTA .. "ctl.json",
    saida = PASTA .. "out.json",
    entrada = PASTA .. "in.json",
    status = PASTA .. "status.json",
}

math.randomseed(os.time())
local SESSAO = math.random(1, 2000000000)

local function agora() return os.clock() end

---------------------------------------------------------------------------
-- Configuracao
---------------------------------------------------------------------------
local cfg = {
    nome = "Jogador",
    modo = "parado",         -- "parado" | "host" | "entrar"
    ip = "",
    porta = 27420,
    avatar = 1,              -- 1 Clone animado, 2 Ashley/Luis, 3 Nenhum
    mostrar_nome = true,
    mostrar_hud = false,     -- v0.23: barra de status desligada por padrao (erros aparecem sempre)
    anti_preso = false,      -- v0.24: teleporte so por tecla (F5/F6); automatico opcional em F8 > Opcoes
    quem_segue = 1,          -- 1 automatico (quem ficou para tras), 2 convidado segue, 3 anfitriao segue, 4 ninguem
    dist_max = 20.0,
    tempo_max = 3.0,
    sync_inimigos = true,
    sync_historia = true,    -- eventos da historia (ex.: torre da vila) acontecem para os dois
    sync_objetos = true,     -- portas, alavancas, escadas... usados por um abrem no outro
    sync_chaves = true,      -- v0.25: item-chave pego por um vai para o inventario dos dois
    inimigos_seguem = true,  -- no jogo do convidado, os inimigos ficam onde estao no do anfitriao
    inimigos_animacao = true, -- v0.18: quem segue toca a mesma animacao que o dono
    atraso_ms = 100,
    painel_aberto = true,
    clarao = 3,              -- intensidade do clarao dos disparos do parceiro (0-100%)
    modo_dev = false,        -- libera o comando "lua" em comando.json (depuracao)
    rede = "steam",          -- v0.20: "steam" (sala + convite da Steam) | "ip" (IP direto, como antes)
    lobby = "",              -- sala Steam em que o convidado entra (texto: o numero nao cabe num double)
    sala = "amigos",         -- quem ve a sala: "amigos" | "privada" (so convite)
    ultimo_convite = "",
    janela_inicio = true,    -- mostra a janela "Jogar junto" na tela inicial
    menu_jogo = true,        -- v0.21: opcao "JOGAR JUNTO" dentro do menu principal do jogo
    idioma = "auto",         -- v0.23: "auto" (segue o idioma do jogo) | "pt" | "en" | outro arquivo em data/RE4CoopBR/lang
    cfg_versao = 7,
}

local function carregar_cfg()
    local ok, t = pcall(json.load_file, ARQ.cfg)
    if ok and type(t) == "table" then
        for k, v in pairs(t) do
            if cfg[k] ~= nil and type(v) == type(cfg[k]) then cfg[k] = v end
        end
        -- Configs da v0.1 usavam outra numeracao de avatar: volta para o clone
        if (t.cfg_versao or 1) < 2 then cfg.avatar = 1 end
        -- v0.10.2: o clarao padrao passou de 30% para 3%
        if (t.cfg_versao or 1) < 3 then cfg.clarao = 3 end
        -- v0.11: nova opcao "automatico" virou a 1 e o padrao
        if (t.cfg_versao or 1) < 4 then cfg.quem_segue = 1 end
        -- v0.20: a conexao passa a ser pela Steam (o IP direto continua como opcao)
        if (t.cfg_versao or 1) < 5 then cfg.rede = "steam" end
        -- v0.23: sem mensagens no topo da tela por padrao
        if (t.cfg_versao or 1) < 6 then cfg.mostrar_hud = false end
        -- v0.24: teleporte automatico desligado (os jogadores preferem F5/F6)
        if (t.cfg_versao or 1) < 7 then cfg.anti_preso = false end
    end
    cfg.cfg_versao = 7
end

local function salvar_cfg() pcall(json.dump_file, ARQ.cfg, cfg) end

carregar_cfg()
if cfg.avatar < 1 or cfg.avatar > 3 then cfg.avatar = 1 end
salvar_cfg()

---------------------------------------------------------------------------
-- Idiomas (v0.23). O texto em portugues e a chave; as traducoes ficam em
-- reframework/data/RE4CoopBR/lang/<idioma>.json:
--   "textos":  { "texto exato ou modelo com %s/%d/%.1f": "traducao" }
--   "trechos": { "pedaco de frase montada": "traducao" }  (troca dentro do texto)
-- Todo texto que vai para a tela passa por I18N.T (imgui/draw abaixo sao envolvidos).
---------------------------------------------------------------------------
local I18N = { lingua = "pt", dic = nil, modelos = {}, trechos = {}, cache = {}, n = 0, prox = 0 }
function I18N.lingua_do_jogo()
    local ok, v = pcall(function()
        return sdk.call_native_func(sdk.get_native_singleton("via.gui.GUISystem"),
            sdk.find_type_definition("via.gui.GUISystem"), "get_MessageLanguage")
    end)
    if not ok or type(v) ~= "number" then return nil end
    if v == 9 or v == 10 then return "pt" end  -- via.Language: 9 Portuguese, 10 PortugueseBr
    local outros = { [1] = "en", [2] = "fr", [3] = "it", [4] = "de", [5] = "es", [6] = "ru", [7] = "pl",
        [11] = "ko", [12] = "zh-TW", [13] = "zh-CN", [22] = "tr", [32] = "es-419" }
    local l = outros[v] or "en"
    -- idioma sem arquivo de traducao: ingles
    if l ~= "en" and not pcall(function() assert(json.load_file(PASTA .. "lang/" .. l .. ".json")) end) then l = "en" end
    return l
end
function I18N.carregar()
    local l = cfg.idioma
    if l == "auto" or l == "" then l = I18N.lingua_do_jogo() or I18N.lingua end
    I18N.lingua, I18N.dic, I18N.modelos, I18N.trechos, I18N.cache, I18N.n = l, nil, {}, {}, {}, 0
    if l == "pt" then return end
    local ok, d = pcall(json.load_file, PASTA .. "lang/" .. l .. ".json")
    if not ok or type(d) ~= "table" then return end
    I18N.dic = d.textos or {}
    for k, v in pairs(I18N.dic) do
        -- modelos com %d/%s/%.Nf viram padroes para reconhecer o texto ja montado
        if k:find("%%[%.%d]*[dsf]") then
            local pat, ordem = "", {}
            local i = 1
            while i <= #k do
                local a, b, spec = k:find("^%%([%.%d]*[dsf%%])", i)
                if a then
                    if spec == "%" then pat = pat .. "%%"
                    elseif spec:sub(-1) == "s" then pat = pat .. "(.-)"
                    else pat = pat .. "([%-%d%.]+)" end
                    ordem[#ordem + 1] = spec
                    i = b + 1
                else
                    local c = k:sub(i, i)
                    pat = pat .. (c:match("[%^%$%(%)%%%.%[%]%*%+%-%?]") and ("%" .. c) or c)
                    i = i + 1
                end
            end
            table.insert(I18N.modelos, { pat = "^" .. pat .. "$", trad = v, n = #k })
        end
    end
    table.sort(I18N.modelos, function(a, b) return a.n > b.n end)
    for k, v in pairs(d.trechos or {}) do table.insert(I18N.trechos, { k, v }) end
    table.sort(I18N.trechos, function(a, b) return #a[1] > #b[1] end)
end
function I18N.T(s)
    if type(s) ~= "string" or not I18N.dic or s == "" then return s end
    local c = I18N.cache[s]
    if c then return c end
    local corpo, id = s:match("^(.-)(##.*)$")
    corpo = corpo or s
    local r = I18N.dic[corpo]
    if not r then
        for _, m in ipairs(I18N.modelos) do
            local caps = { corpo:match(m.pat) }
            if #caps > 0 then
                local j = 0
                r = m.trad:gsub("%%[%.%d]*[dsf]", function() j = j + 1 return caps[j] or "" end):gsub("%%%%", "%%")
                break
            end
        end
    end
    if not r then
        r = corpo
        for _, t in ipairs(I18N.trechos) do
            local a, b = r:find(t[1], 1, true)
            while a do
                r = r:sub(1, a - 1) .. t[2] .. r:sub(b + 1)
                a, b = r:find(t[1], a + #t[2], true)
            end
        end
    end
    r = r .. (id or "")
    if I18N.n > 4000 then I18N.cache, I18N.n = {}, 0 end
    I18N.cache[s] = r
    I18N.n = I18N.n + 1
    return r
end
I18N.carregar()
-- no modo automatico, confere de vez em quando se o idioma do jogo mudou (menu de opcoes)
re.on_frame(function()
    if cfg.idioma ~= "auto" or os.clock() < I18N.prox then return end
    I18N.prox = os.clock() + 5
    local l = I18N.lingua_do_jogo()
    if l and l ~= I18N.lingua then I18N.carregar() end
end)

-- imgui/draw locais que traduzem o texto (1o argumento) antes de desenhar
local imgui = (function(orig)
    local T = I18N.T
    local traduz = { text = true, text_colored = true, button = true, checkbox = true, collapsing_header = true,
        tree_node = true, slider_int = true, slider_float = true, drag_float = true, drag_int = true,
        input_text = true, begin_window = true, begin_tab_item = true, calc_text_size = true,
        selectable = true, small_button = true, combo = true }
    return setmetatable({}, { __index = function(t, k)
        local f = orig[k]
        if traduz[k] and type(f) == "function" then
            local g
            if k == "combo" then
                g = function(a, sel, lista, ...)
                    local l2 = lista
                    if type(lista) == "table" then l2 = {} for i, v in pairs(lista) do l2[i] = T(v) end end
                    return f(T(a), sel, l2, ...)
                end
            else
                g = function(a, ...) return f(T(a), ...) end
            end
            rawset(t, k, g)
            return g
        end
        rawset(t, k, f)
        return f
    end })
end)(imgui)
local draw = (function(orig)
    return setmetatable({ text = function(s, ...) return orig.text(I18N.T(s), ...) end }, { __index = orig })
end)(draw)

-- JSON compacto (indent -1) deixa os pacotes menores; cai para o padrao se a versao do REFramework nao aceitar
local dump_compacto = true
local function gravar_json(caminho, t)
    if dump_compacto then
        if pcall(json.dump_file, caminho, t, -1) then return end
        dump_compacto = false
    end
    pcall(json.dump_file, caminho, t)
end

-- Sala Steam: botoes do painel e da janela "Jogar junto" (uma tabela so: limite de 200 locais)
local Sala = { con = "0", convidar = 0, pronto = false, inicio = "0", inicio_tipo = "novo",
    inicio_visto = nil, iniciada = nil, no_jogo = nil, juntou = false, esconder = false }

-- v0.24: cenas. O jogo "desliga" o jogador quando uma cena comeca e "religa" no fim.
Sala.em_cena, Sala.cena_desde = false, 0
function Sala.em_cena_agora()
    -- v0.26: o componente de cena do jogador diz se a cena esta tocando (_IsPlaying) e qual e (_EventID)
    if Sala.ator_cena then
        local ok, ap = pcall(Sala.ator_cena)
        if ok and ap then
            local okp, tocando = pcall(ap.get_field, ap, "_IsPlaying")
            if okp then
                if tocando then pcall(function() Sala.cena_id = ap:get_field("_EventID") end) end
                return tocando == true
            end
        end
    end
    -- reserva: ganchos. Se o "religar" nao vier (cena pulada, troca de area), solta depois de 5 min
    if Sala.em_cena and os.clock() - Sala.cena_desde > 300 then Sala.em_cena = false end
    return Sala.em_cena
end
pcall(function()
    local td = sdk.find_type_definition("chainsaw.TimelineEventActorPlayer")
    -- (visto com escutas: o jogo chama play() no inicio da cena e enableIngamePlayer() no fim)
    sdk.hook(td:get_method("play"), function() Sala.em_cena, Sala.cena_desde = true, os.clock() end, nil)
    sdk.hook(td:get_method("disableIngamePlayer"), function() Sala.em_cena, Sala.cena_desde = true, os.clock() end, nil)
    sdk.hook(td:get_method("enableIngamePlayer"), function() Sala.em_cena = false end, nil)
end)

local function enviar_ctl()
    pcall(json.dump_file, ARQ.ctl, {
        modo = cfg.modo, rede = cfg.rede, ip = cfg.ip, porta = cfg.porta, lobby = cfg.lobby, sala = cfg.sala,
        versao = VERSAO, nome = cfg.nome, con = Sala.con, convidar = Sala.convidar,
        pronto = Sala.pronto and "1" or "0", inicio = Sala.inicio, inicio_tipo = Sala.inicio_tipo,
        inicio_cap = tostring(Sala.inicio_dif or 20), save = Sala.info_save or "",
        sessao = SESSAO, t = agora(),
    })
end
enviar_ctl()

---------------------------------------------------------------------------
-- Mensagens (chat + avisos do sistema)
---------------------------------------------------------------------------
local mensagens = {}
local aviso_hud = { texto = nil, ate = 0 }

local function registrar(texto, de_quem)
    table.insert(mensagens, { texto = texto, de = de_quem, t = os.date("%H:%M") })
    while #mensagens > 60 do table.remove(mensagens, 1) end
    aviso_hud.texto = (de_quem and (de_quem .. ": ") or "") .. texto
    aviso_hud.ate = agora() + 6
    log.info("[RE4 Co-op BR] " .. aviso_hud.texto)
end

---------------------------------------------------------------------------
-- Acesso ao jogo
---------------------------------------------------------------------------
local scene_mgr = sdk.get_native_singleton("via.SceneManager")
local scene_td = sdk.find_type_definition("via.SceneManager")
local T_TRANSFORM = sdk.typeof("via.Transform")
local T_CC = sdk.typeof("via.physics.CharacterController")

local function tentar(obj, nomes, ...)
    if not obj then return nil end
    for _, n in ipairs(nomes) do
        local ok, r = pcall(obj.call, obj, n, ...)
        if ok and r ~= nil then return r end
    end
    return nil
end

local function cena()
    if not scene_mgr then return nil end
    local ok, s = pcall(sdk.call_native_func, scene_mgr, scene_td, "get_CurrentScene")
    if ok then return s end
end

local function achar_go(nome)
    local s = cena()
    if not s then return nil end
    local ok, go = pcall(s.call, s, "findGameObject(System.String)", nome)
    if ok then return go end
end

local function componente(go, tipo)
    if not go then return nil end
    local ok, c = pcall(go.call, go, "getComponent(System.Type)", tipo)
    if ok then return c end
end

local function personagens()
    return sdk.get_managed_singleton("chainsaw.CharacterManager")
end

local function contexto_jogador()
    local lista = tentar(personagens(), { "get_PlayerContextList" })
    if not lista then return nil end
    local ok, n = pcall(lista.call, lista, "get_Count")
    if not ok or not n or n == 0 then return nil end
    local ok2, p = pcall(lista.call, lista, "get_Item", 0)
    if ok2 then return p end
end

-- Cache de GameObjects (findGameObject e caro, revalida a cada 1s)
local cache_go = {}
local function go_cacheado(nome)
    local c = cache_go[nome]
    if c and agora() - c.t < 1.0 then return c.go end
    local go = achar_go(nome)
    cache_go[nome] = { go = go, t = agora() }
    return go
end

local function go_jogador()
    local ctx = contexto_jogador()
    local go = tentar(ctx, { "get_BodyGameObject" })
    if go then return go end
    return go_cacheado("ch0a0z0_body")
end

-- v0.26: componente de cena (chainsaw.TimelineEventActorPlayer) do corpo do jogador, guardado por corpo
function Sala.ator_cena()
    local go = go_jogador()
    if not go then return nil end
    if Sala._ator_go ~= go then
        Sala._ator_go = go
        Sala._ator = go:call("getComponent(System.Type)", sdk.typeof("chainsaw.TimelineEventActorPlayer"))
    end
    return Sala._ator
end

local function ler_transform(go)
    local tr = componente(go, T_TRANSFORM)
    if not tr then return nil end
    local ok, p = pcall(tr.call, tr, "get_Position")
    local ok2, r = pcall(tr.call, tr, "get_Rotation")
    if not ok or not p then return nil end
    return p, (ok2 and r or nil)
end

local function mover_go(go, x, y, z, rot)
    local tr = componente(go, T_TRANSFORM)
    if not tr then return false end
    local cc = componente(go, T_CC)
    if cc then pcall(cc.call, cc, "warp") end
    pcall(tr.call, tr, "set_Position", Vector3f.new(x, y, z))
    if cc then pcall(cc.call, cc, "warp") end
    if rot then pcall(tr.call, tr, "set_Rotation", Vector4f.new(rot[1], rot[2], rot[3], rot[4])) end
    return true
end

local T_MESH = sdk.typeof("via.render.Mesh")
local GO_TD = sdk.find_type_definition("via.GameObject")
local GO_CREATE = GO_TD and GO_TD:get_method("create(System.String)")

-- Chama o primeiro metodo que existir (setters retornam nil, entao "tentar" nao serve)
local function chamar(obj, nomes, ...)
    if not obj then return false end
    for _, n in ipairs(nomes) do
        if pcall(obj.call, obj, n, ...) then return true end
    end
    return false
end

local function valido(obj)
    if not obj then return false end
    local ok, v = pcall(obj.call, obj, "get_Valid")
    return ok and v == true
end

local function endereco(obj)
    if not obj then return nil end
    local ok, a = pcall(obj.get_address, obj)
    return ok and a or nil
end

local function juntas_de(tr)
    local arr = tentar(tr, { "get_Joints" })
    if not arr then return nil end
    local ok, el = pcall(arr.get_elements, arr)
    if ok then return el end
end

local function hp_de(ctx)
    local hp = tentar(ctx, { "get_HitPoint" })
    if not hp then
        local ok, f = pcall(ctx.get_field, ctx, "<HitPoint>k__BackingField")
        if ok then hp = f end
    end
    return hp
end

local function valor_hp(hp)
    if not hp then return nil, nil end
    local cur = tentar(hp, { "get_CurrentHitPoint" })
    local max = tentar(hp, { "get_DefaultHitPoint" })
    return cur, max
end

---------------------------------------------------------------------------
-- Capitulo / estagio (descobertos por reflexao, os nomes dos getters mudam entre versoes)
---------------------------------------------------------------------------
local SINGLETONS_ESTAGIO = {
    "chainsaw.CampaignManager", "chainsaw.MapManager", "chainsaw.GameStageManager",
    "chainsaw.StageManager", "chainsaw.LevelManager",
}

local function nomes_enum(tipo)
    local m = {}
    pcall(function()
        local td = sdk.find_type_definition(tipo)
        for _, f in ipairs(td:get_fields()) do
            if f:is_static() then
                local ok, v = pcall(f.get_data, f, nil)
                if ok and type(v) == "number" then m[v] = f:get_name() end
            end
        end
    end)
    return m
end

local NOME_ESTAGIO = nomes_enum("chainsaw.StageID")
local NOME_CAPITULO = nomes_enum("chainsaw.ChapterID")

local function achar_leitor(tipo_ret)
    for _, sn in ipairs(SINGLETONS_ESTAGIO) do
        local inst = sdk.get_managed_singleton(sn)
        if inst then
            local ok, td = pcall(inst.get_type_definition, inst)
            if ok and td then
                local melhor
                for _, m in ipairs(td:get_methods()) do
                    local ok2, info = pcall(function()
                        return { n = m:get_name(), r = m:get_return_type():get_full_name(), p = m:get_num_params() }
                    end)
                    if ok2 and info.r == tipo_ret and info.p == 0 and info.n:sub(1, 4) == "get_" then
                        if not melhor or info.n:find("Current") then melhor = info.n end
                    end
                end
                if melhor then return { sing = sn, metodo = melhor } end
            end
        end
    end
end

local leitores = { capitulo = nil, estagio = nil, proxima_busca = 0 }

local function ler_numero(leitor)
    if not leitor then return nil end
    local inst = sdk.get_managed_singleton(leitor.sing)
    if not inst then return nil end
    local ok, v = pcall(inst.call, inst, leitor.metodo)
    if ok and type(v) == "number" then return v end
end

local function ler_local_jogo()
    if (not leitores.capitulo or not leitores.estagio) and agora() > leitores.proxima_busca then
        leitores.proxima_busca = agora() + 5
        leitores.capitulo = leitores.capitulo or achar_leitor("chainsaw.ChapterID")
        leitores.estagio = leitores.estagio or achar_leitor("chainsaw.StageID")
    end
    return ler_numero(leitores.capitulo), ler_numero(leitores.estagio)
end

local function nome_estagio(v) return v and (NOME_ESTAGIO[v] or tostring(v)) or "?" end
local function nome_capitulo(v) return v and (NOME_CAPITULO[v] or tostring(v)) or "?" end

---------------------------------------------------------------------------
-- Estado local / remoto
---------------------------------------------------------------------------
local function arred(v, casas)
    local m = 10 ^ casas
    return math.floor(v * m + 0.5) / m
end

local local_ = { ok = false }        -- meu estado lido do jogo
local parceiro = nil                 -- ultimo estado do parceiro
local parceiro_recebido_em = 0
local parceiro_sessao = nil
local ultimo_seq_parceiro = -1
local ultimo_ev_parceiro = 0
local status_ponte = {}
local ponte_relogio, ponte_relogio_mudou = nil, 0

local seq = 0
local prox_ev = 1
local eventos_pendentes = {}
-- Modulo de inimigos: declarado aqui (escrever_saida usa), preenchido mais abaixo
local Inimigos = { vistos = 0, enviados = 0, recebidos = 0, pendentes = 0, ultimo = "-" }

local function papel()
    if cfg.modo == "host" then return "anfitriao" elseif cfg.modo == "entrar" then return "convidado" end
    return "parado"
end

-- Quanto voce andou nos ultimos 10 s (amostras a cada 0,5 s; saltos > 5 m sao teleportes e nao contam)
local trilha = {}
local function registrar_movimento()
    if not local_.ok then return end
    local t = agora()
    local ult = trilha[#trilha]
    if not ult or t - ult.t >= 0.5 then
        table.insert(trilha, { t = t, x = local_.x, y = local_.y, z = local_.z })
    end
    while trilha[1] and t - trilha[1].t > 10 do table.remove(trilha, 1) end
end

local function andou_recentemente()
    local s = 0
    for i = 2, #trilha do
        local a, b = trilha[i - 1], trilha[i]
        local d = math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2 + (b.z - a.z) ^ 2)
        if d < 5 then s = s + d end
    end
    return s
end

local function eu_sigo()
    if cfg.quem_segue == 1 then
        -- Automatico: e puxado quem andou bem menos (ficou parado/preso enquanto o outro avancou)
        local dele = tonumber(parceiro and parceiro.mv) or 0
        return dele > andou_recentemente() + 4
    end
    if cfg.quem_segue == 2 then return papel() == "convidado" end
    if cfg.quem_segue == 3 then return papel() == "anfitriao" end
    return false
end

local function enviar_evento(tipo, dados)
    table.insert(eventos_pendentes, { id = prox_ev, tipo = tipo, d = dados })
    prox_ev = prox_ev + 1
    while #eventos_pendentes > 30 do table.remove(eventos_pendentes, 1) end
end

local function ler_estado_local()
    local ctx = contexto_jogador()
    local go = ctx and go_jogador()
    local pos, rot = nil, nil
    if go then pos, rot = ler_transform(go) end
    if not pos then local_.ok = false; return end
    local cur, max = valor_hp(hp_de(ctx))
    local cap, est = ler_local_jogo()
    local_.ok = true
    local_.x, local_.y, local_.z = pos.x, pos.y, pos.z
    if rot then local_.rot = { rot.x, rot.y, rot.z, rot.w } end
    local_.hp, local_.hpmax = cur, max
    local_.cap, local_.est = cap, est
    registrar_movimento()
end

---------------------------------------------------------------------------
-- Pose do esqueleto (para o clone animado no PC do parceiro)
-- Cada junta vai como quaternion x,y,z em int16 hex (w e reconstruido), 12 chars por junta.
---------------------------------------------------------------------------
-- Quaternions como {x, y, z, w}
local function qmul(a, b)
    local ax, ay, az, aw = a[1], a[2], a[3], a[4]
    local bx, by, bz, bw = b[1], b[2], b[3], b[4]
    return {
        aw * bx + ax * bw + ay * bz - az * by,
        aw * by - ax * bz + ay * bw + az * bx,
        aw * bz + ax * by - ay * bx + az * bw,
        aw * bw - ax * bx - ay * by - az * bz,
    }
end
local function qconj(a) return { -a[1], -a[2], -a[3], a[4] } end
local function qrot(q, v)
    local r = qmul(qmul(q, { v[1], v[2], v[3], 0 }), qconj(q))
    return { r[1], r[2], r[3] }
end

Sala.MAX_OSSOS = 512
local ossos_locais = { chave = nil, juntas = {}, nomes = {}, assinatura = nil, prox = 0 }

-- O GameObject raiz (chXaXzX_body) tem so um esqueleto simplificado (DummySkeleton, ~61 juntas).
-- As malhas visiveis (body, head, hair) sao filhas dele e cada uma tem o proprio esqueleto
-- (body ~169, head ~231 com o rosto). A pose enviada e a uniao de todas, sem nomes repetidos,
-- com o "body" primeiro para as juntas compartilhadas sairem do corpo.
local function partes_visiveis(go)
    local res = {}
    local c = tentar(componente(go, T_TRANSFORM), { "get_Child" })
    local n = 0
    while c and n < 80 do
        local g = tentar(c, { "get_GameObject" })
        local nome = g and tentar(g, { "get_Name" }) or ""
        if type(nome) == "string" and not nome:find("^wp") and not nome:find("RE4CoopBR") and componente(g, T_MESH) then
            if nome == "body" then table.insert(res, 1, { go = g, tr = c, nome = nome })
            else table.insert(res, { go = g, tr = c, nome = nome }) end
        end
        c = tentar(c, { "get_Next" })
        n = n + 1
    end
    return res
end

-- Caminho do recurso (malha .mesh / material .mdf2) para o parceiro carregar a sua roupa
local function caminho_recurso(holder)
    if not holder then return nil end
    local p = tentar(holder, { "get_ResourcePath" })
    if type(p) == "string" and p ~= "" then return p end
end

-- Armas: filhos "wpXXXX" com malha (na mao, no coldre, granadas no cinto...)
Sala.MAX_ARMAS = 16
local TD_SOM_ARMA = sdk.find_type_definition("chainsaw.SoundGunContainer")
local tiros_locais = {}     -- disparos acumulados por arma (indice da lista de armas)
local function armas_do_personagem(go)
    local res = {}
    local c = tentar(componente(go, T_TRANSFORM), { "get_Child" })
    local n = 0
    while c and n < 80 and #res < Sala.MAX_ARMAS do
        local g = tentar(c, { "get_GameObject" })
        local nome = g and tentar(g, { "get_Name" }) or ""
        if type(nome) == "string" and nome:find("^wp") then
            local m = componente(g, T_MESH)
            if m then table.insert(res, { go = g, tr = c, mesh = m, nome = nome }) end
        end
        c = tentar(c, { "get_Next" })
        n = n + 1
    end
    return res
end

local visual_local = { lista = nil, armas = nil, armas_obj = {}, assinatura = nil, prox = 0 }

local function capturar_visual(go)
    if visual_local.lista and agora() < visual_local.prox then return end
    visual_local.prox = agora() + 3
    local lista, partes_txt = {}, {}
    for _, p in ipairs(partes_visiveis(go)) do
        local m = componente(p.go, T_MESH)
        local malha = caminho_recurso(tentar(m, { "getMesh", "get_Mesh" }))
        local mat = caminho_recurso(tentar(m, { "get_Material", "getMaterial" }))
        if malha then
            table.insert(lista, { n = p.nome, m = malha, t = mat })
            partes_txt[#partes_txt + 1] = p.nome .. "=" .. malha .. "|" .. tostring(mat)
        end
    end
    local armas, armas_obj, idx_por_addr = {}, {}, {}
    for _, a in ipairs(armas_do_personagem(go)) do
        local malha = caminho_recurso(tentar(a.mesh, { "getMesh", "get_Mesh" }))
        local mat = caminho_recurso(tentar(a.mesh, { "get_Material", "getMaterial" }))
        if malha then
            -- Codigo do som do disparo desta arma (o parceiro usa se nao tiver a mesma arma)
            local som = nil
            local sc = TD_SOM_ARMA and tentar(a.go, { "getComponent(System.Type)" }, TD_SOM_ARMA:get_runtime_type())
            if sc then
                local ok, v = pcall(sc.get_field, sc, "_TriggerShot")
                if ok then som = v end
            end
            table.insert(armas, { n = a.nome, m = malha, t = mat, s = som })
            table.insert(armas_obj, a)
            local addr = endereco(a.go)
            if addr then idx_por_addr[addr] = #armas_obj end
            partes_txt[#partes_txt + 1] = "A:" .. a.nome .. "=" .. malha
        end
    end
    local assinatura = table.concat(partes_txt, ";")
    if assinatura ~= visual_local.assinatura then tiros_locais = {} end
    visual_local.lista = lista
    visual_local.armas = armas
    visual_local.armas_obj = armas_obj
    visual_local.idx_por_addr = idx_por_addr
    visual_local.assinatura = assinatura
end

-- Conta os disparos das suas armas: o jogo chama chainsaw.Gun.onFire() a cada tiro
local TD_GUN = sdk.find_type_definition("chainsaw.Gun")
local metodo_disparo = TD_GUN and TD_GUN:get_method("onFire")
if metodo_disparo then
    sdk.hook(metodo_disparo, function(args)
        pcall(function()
            local gun = sdk.to_managed_object(args[2])
            local go = gun and gun:call("get_GameObject")
            local i = visual_local.idx_por_addr and visual_local.idx_por_addr[endereco(go)]
            if i then tiros_locais[i] = (tiros_locais[i] or 0) + 1 end
        end)
    end, function(ret) return ret end)
end

local function contagem_tiros()
    local t = {}
    for i = 1, #(visual_local.armas_obj or {}) do t[i] = tostring(tiros_locais[i] or 0) end
    return table.concat(t, ",")
end

-- Pecas opcionais da malha (pente reserva, acessorios...): 64 bits em 16 hex
Sala.MAX_PECAS = 64
local function mascara_pecas(m)
    local hex = {}
    for nib = 0, Sala.MAX_PECAS // 4 - 1 do
        local v = 0
        for b = 0, 3 do
            local ok, ligado = pcall(m.call, m, "getPartsEnable", nib * 4 + b)
            if not ok or ligado ~= false then v = v | (1 << b) end
        end
        hex[#hex + 1] = string.format("%x", v)
    end
    return table.concat(hex)
end

local function aplicar_mascara(m, mascara)
    for nib = 0, #mascara - 1 do
        local v = tonumber(mascara:sub(nib + 1, nib + 1), 16) or 15
        for b = 0, 3 do
            pcall(m.call, m, "setPartsEnable", nib * 4 + b, (v & (1 << b)) ~= 0)
        end
    end
end

local function arma_visivel(a)
    local ok, d = pcall(a.go.call, a.go, "get_DrawSelf")
    if ok and d == false then return false end
    local ok2, e = pcall(a.mesh.call, a.mesh, "get_Enabled")
    if ok2 and e == false then return false end
    return ok
end
local prox_nomes = 0

local function i16hex(v, escala)
    local n = math.floor(v * escala + 0.5)
    if n > 32767 then n = 32767 elseif n < -32767 then n = -32767 end
    return string.format("%04x", n & 0xFFFF)
end

local function hexi16(s, i)
    local n = tonumber(s:sub(i, i + 3), 16)
    if not n then return 0 end
    if n >= 32768 then n = n - 65536 end
    return n
end

local function capturar_pose()
    local go = go_jogador()
    if not go then return nil end
    pcall(capturar_visual, go)
    if #ossos_locais.juntas == 0 or agora() > ossos_locais.prox then
        local partes = partes_visiveis(go)
        local juntas, nomes, vistos = {}, {}, {}
        -- Juntas sem pai em alguma peca (ex.: o pescoco e a base do esqueleto da cabeca).
        -- Elas precisam da posicao real; as outras se encaixam pela rotacao do pai.
        local raizes = {}
        for _, p in ipairs(partes) do
            for _, j in ipairs(juntas_de(p.tr) or {}) do
                local n = tentar(j, { "get_Name" })
                if n and not tentar(j, { "get_Parent" }) then raizes[n] = true end
                if n and not vistos[n] and #juntas < Sala.MAX_OSSOS then
                    vistos[n] = true
                    juntas[#juntas + 1] = j
                    nomes[#nomes + 1] = n
                end
            end
        end
        if #juntas == 0 then return nil end
        local com_posicao = {}
        for i, n in ipairs(nomes) do
            if i <= 3 or raizes[n] then com_posicao[#com_posicao + 1] = i end
        end
        local junto = table.concat(nomes, "|")
        ossos_locais = { juntas = juntas, nomes = nomes, com_posicao = com_posicao, prox = agora() + 5,
            assinatura = #nomes .. ":" .. #junto .. ":" .. (nomes[#nomes] or "") }
    end
    -- As malhas visiveis tem as rotacoes LOCAIS paradas na pose de fabrica (o motor posiciona
    -- as juntas direto no mundo). Por isso a pose vai em espaco do MUNDO, relativa a raiz do
    -- personagem: o parceiro so precisa multiplicar pela posicao/rotacao do clone.
    local raiz = componente(go, T_TRANSFORM)
    local ok1, rp = pcall(raiz.call, raiz, "get_Position")
    local ok2, rr = pcall(raiz.call, raiz, "get_Rotation")
    if not ok1 or not ok2 or not rp or not rr then return nil end
    local inv = qconj({ rr.x, rr.y, rr.z, rr.w })
    local q, p = {}, {}
    for i, j in ipairs(ossos_locais.juntas) do
        local ok, w = pcall(j.call, j, "get_Rotation")
        if ok and w then
            local rel = qmul(inv, { w.x, w.y, w.z, w.w })
            local x, y, z = rel[1], rel[2], rel[3]
            if rel[4] < 0 then x, y, z = -x, -y, -z end
            q[i] = i16hex(x, 32767) .. i16hex(y, 32767) .. i16hex(z, 32767)
        else
            q[i] = "000000000000"
        end
    end
    -- Posicoes: indice (4 hex) + x,y,z em mm (12 hex) = 16 chars por junta
    for _, i in ipairs(ossos_locais.com_posicao or {}) do
        local j = ossos_locais.juntas[i]
        local ok3, v = pcall(j.call, j, "get_Position")
        if ok3 and v then
            local rel = qrot(inv, { v.x - rp.x, v.y - rp.y, v.z - rp.z })
            p[#p + 1] = string.format("%04x", i) .. i16hex(rel[1], 1000) .. i16hex(rel[2], 1000) .. i16hex(rel[3], 1000)
        end
    end
    -- Pecas ligadas de cada arma (pente reserva etc.), 16 hex por arma, a cada 0,25 s
    if agora() >= (visual_local.prox_mascara or 0) then
        visual_local.prox_mascara = agora() + 0.25
        local ms = {}
        for _, arma in ipairs(visual_local.armas_obj or {}) do
            local ok, mk = pcall(mascara_pecas, arma.mesh)
            ms[#ms + 1] = ok and mk or string.rep("f", Sala.MAX_PECAS // 4)
        end
        visual_local.mascaras = table.concat(ms)
    end
    -- Armas: posicao (12) + rotacao (12) relativas a raiz + visivel (1) = 25 chars cada
    local a = {}
    for _, arma in ipairs(visual_local.armas_obj or {}) do
        local ok4, v = pcall(arma.tr.call, arma.tr, "get_Position")
        local ok5, w = pcall(arma.tr.call, arma.tr, "get_Rotation")
        if ok4 and ok5 and v and w then
            local rel_p = qrot(inv, { v.x - rp.x, v.y - rp.y, v.z - rp.z })
            local rel_q = qmul(inv, { w.x, w.y, w.z, w.w })
            if rel_q[4] < 0 then rel_q = { -rel_q[1], -rel_q[2], -rel_q[3], -rel_q[4] } end
            a[#a + 1] = i16hex(rel_p[1], 1000) .. i16hex(rel_p[2], 1000) .. i16hex(rel_p[3], 1000)
                .. i16hex(rel_q[1], 32767) .. i16hex(rel_q[2], 32767) .. i16hex(rel_q[3], 32767)
                .. (arma_visivel(arma) and "1" or "0")
        else
            a[#a + 1] = string.rep("0", 24) .. "0"
        end
    end
    return table.concat(q), table.concat(p), table.concat(a)
end

local function decodificar_pose(pz, pp, ap)
    if type(pz) ~= "string" or #pz < 12 then return nil end
    local q, p, armas = {}, {}, {}
    if type(ap) == "string" then
        for k = 1, #ap // 25 do
            local b = (k - 1) * 25 + 1
            local x, y, z = hexi16(ap, b + 12) / 32767, hexi16(ap, b + 16) / 32767, hexi16(ap, b + 20) / 32767
            armas[k] = {
                p = { hexi16(ap, b) / 1000, hexi16(ap, b + 4) / 1000, hexi16(ap, b + 8) / 1000 },
                q = { x, y, z, math.sqrt(math.max(0, 1 - x * x - y * y - z * z)) },
                v = ap:sub(b + 24, b + 24) == "1",
            }
        end
    end
    for i = 1, #pz // 12 do
        local b = (i - 1) * 12 + 1
        local x, y, z = hexi16(pz, b) / 32767, hexi16(pz, b + 4) / 32767, hexi16(pz, b + 8) / 32767
        q[i] = { x, y, z, math.sqrt(math.max(0, 1 - x * x - y * y - z * z)) }
    end
    if type(pp) == "string" then
        for k = 1, #pp // 16 do
            local b = (k - 1) * 16 + 1
            local i = tonumber(pp:sub(b, b + 3), 16)
            if i then p[i] = { hexi16(pp, b + 4) / 1000, hexi16(pp, b + 8) / 1000, hexi16(pp, b + 12) / 1000 } end
        end
    end
    return { q = q, p = p, armas = armas }
end

local function escrever_saida()
    seq = seq + 1
    local e = {
        v = VERSAO, s = SESSAO, seq = seq, t = arred(agora(), 3), nome = cfg.nome, papel = papel(),
        ack = ultimo_ev_parceiro, ev = eventos_pendentes, mv = arred(andou_recentemente(), 1),
    }
    -- v0.24: jogo pausado (menu de pausa, inventario...): o parceiro assume os inimigos e mostra "PAUSADO"
    local okp, pausado = pcall(function() return sdk.get_managed_singleton("share.PauseManager"):call("isPaused()") end)
    Sala.pausado = okp and pausado == true
    if Sala.pausado then e.pau = 1 end
    if Sala.em_cena_agora() then e.cena = 1; e.cid = Sala.cena_id end
    if local_.ok then
        e.p = { arred(local_.x, 3), arred(local_.y, 3), arred(local_.z, 3) }
        if local_.rot then
            e.r = { arred(local_.rot[1], 4), arred(local_.rot[2], 4), arred(local_.rot[3], 4), arred(local_.rot[4], 4) }
        end
        e.hp = local_.hp and arred(local_.hp, 1)
        e.hpmax = local_.hpmax
        e.cap, e.est = local_.cap, local_.est
        local oke, en, ec = pcall(Inimigos.capturar_posicoes)
        if oke and en then e.en, e.ec = en, ec end
        if not oke then Inimigos.ultimo = "erro posicoes: " .. tostring(en) end
        local ok, pz, pp, ap = pcall(capturar_pose)
        if ok and pz then
            e.pz, e.pp, e.ap, e.ph = pz, pp, ap, ossos_locais.assinatura
            e.am = visual_local.mascaras
            e.tc = contagem_tiros()
            e.vh = visual_local.assinatura
            -- Listas de juntas/roupa/armas so de vez em quando (o parceiro guarda)
            if agora() >= prox_nomes then
                prox_nomes = agora() + 2
                e.pn = ossos_locais.nomes
                e.vis = visual_local.lista
                e.arm = visual_local.armas
            end
        end
    end
    -- v0.26.4: durante a cena a posicao do jogador e a do "palco" da cena (lugar nao jogavel);
    -- manda tambem onde ele estava ANTES da cena, para o parceiro ir ate um lugar de verdade
    if e.p then
        if e.cena then
            if Sala.pos_pre then e.cp, e.cr = Sala.pos_pre.p, Sala.pos_pre.r end
        else
            Sala.pos_pre = { p = e.p, r = e.r }
        end
    end
    gravar_json(ARQ.saida, e)
end

---------------------------------------------------------------------------
-- Interpolacao do parceiro
---------------------------------------------------------------------------
local amostras = {}
local offset_relogio = nil
local ossos_parceiro = { nomes = nil, assinatura = nil }
local visual_parceiro = { lista = nil, armas = nil, assinatura = nil, mudou = false }
local mascaras_parceiro = nil
local tiros_parceiro_base = {}
local tiros_pendentes = {}

local function adicionar_amostra(st)
    if not st.p then return end
    local recebido = agora()
    local amostra_off = recebido - (st.t or recebido)
    if not offset_relogio or amostra_off < offset_relogio then
        offset_relogio = amostra_off
    else
        offset_relogio = offset_relogio + (amostra_off - offset_relogio) * 0.01
    end
    local t = (st.t or recebido) + offset_relogio
    local ultimo = amostras[#amostras]
    if ultimo and t <= ultimo.t then return end
    if type(st.pn) == "table" and st.ph then
        ossos_parceiro.nomes, ossos_parceiro.assinatura = st.pn, st.ph
    end
    -- Roupa do parceiro mudou (ou chegou pela 1a vez): o clone e refeito com ela
    if type(st.vis) == "table" and st.vh and st.vh ~= visual_parceiro.assinatura then
        visual_parceiro.lista, visual_parceiro.assinatura = st.vis, st.vh
        visual_parceiro.armas = type(st.arm) == "table" and st.arm or {}
        visual_parceiro.mudou = true
    end
    local pose = nil
    if st.pz and st.ph and st.ph == ossos_parceiro.assinatura then pose = decodificar_pose(st.pz, st.pp, st.ap) end
    table.insert(amostras, { t = t, p = st.p, r = st.r, pose = pose })
    while #amostras > 24 do table.remove(amostras, 1) end
end

local function nlerp_quat(a, b, k)
    if not a then return b end
    if not b then return a end
    local d = a[1] * b[1] + a[2] * b[2] + a[3] * b[3] + a[4] * b[4]
    local s = d < 0 and -1 or 1
    local q = {}
    for i = 1, 4 do q[i] = a[i] + (b[i] * s - a[i]) * k end
    local n = math.sqrt(q[1] ^ 2 + q[2] ^ 2 + q[3] ^ 2 + q[4] ^ 2)
    if n < 1e-6 then return b end
    for i = 1, 4 do q[i] = q[i] / n end
    return q
end

local function misturar_pose(a, b, k)
    if not a then return b end
    if not b then return a end
    if #a.q ~= #b.q then return k < 0.5 and a or b end
    local q, p = {}, {}
    for i = 1, #a.q do q[i] = nlerp_quat(a.q[i], b.q[i], k) end
    for i, pa in pairs(a.p) do
        local pb = b.p[i]
        if pb then p[i] = { pa[1] + (pb[1] - pa[1]) * k, pa[2] + (pb[2] - pa[2]) * k, pa[3] + (pb[3] - pa[3]) * k } end
    end
    local armas = {}
    for i, aa in ipairs(a.armas or {}) do
        local ab = b.armas and b.armas[i]
        if ab then
            armas[i] = {
                p = { aa.p[1] + (ab.p[1] - aa.p[1]) * k, aa.p[2] + (ab.p[2] - aa.p[2]) * k, aa.p[3] + (ab.p[3] - aa.p[3]) * k },
                q = nlerp_quat(aa.q, ab.q, k),
                v = (k < 0.5) and aa.v or ab.v,
            }
        else
            armas[i] = aa
        end
    end
    return { q = q, p = p, armas = armas }
end

-- Retorna posicao, rotacao e pose do parceiro no instante "agora - suavizacao"
local function posicao_suave()
    local n = #amostras
    if n == 0 then return nil end
    local tr = agora() - cfg.atraso_ms / 1000
    if tr <= amostras[1].t then return amostras[1].p, amostras[1].r, amostras[1].pose end
    for i = n - 1, 1, -1 do
        local a, b = amostras[i], amostras[i + 1]
        if a.t <= tr and tr <= b.t then
            local k = (tr - a.t) / math.max(b.t - a.t, 1e-4)
            return {
                a.p[1] + (b.p[1] - a.p[1]) * k,
                a.p[2] + (b.p[2] - a.p[2]) * k,
                a.p[3] + (b.p[3] - a.p[3]) * k,
            }, nlerp_quat(a.r, b.r, k), misturar_pose(a.pose, b.pose, k)
        end
    end
    -- Sem pacote novo: extrapola por no maximo 150 ms
    local b = amostras[n]
    if n >= 2 then
        local a = amostras[n - 1]
        local dt = math.min(tr - b.t, 0.15)
        local inv = 1 / math.max(b.t - a.t, 1e-4)
        return {
            b.p[1] + (b.p[1] - a.p[1]) * inv * dt,
            b.p[2] + (b.p[2] - a.p[2]) * inv * dt,
            b.p[3] + (b.p[3] - a.p[3]) * inv * dt,
        }, b.r, b.pose
    end
    return b.p, b.r, b.pose
end

---------------------------------------------------------------------------
-- Leitura da ponte
---------------------------------------------------------------------------
local ultimo_teleporte = 0
local porta_parceiro = nil      -- ultimo ponto do parceiro antes de trocar de area

local function mesma_area()
    if not parceiro or not local_.ok then return false end
    if local_.est and parceiro.est then return local_.est == parceiro.est end
    if local_.cap and parceiro.cap then return local_.cap == parceiro.cap end
    return true
end

local function distancia_parceiro()
    if not parceiro or not parceiro.p or not local_.ok then return nil end
    local dx, dy, dz = parceiro.p[1] - local_.x, parceiro.p[2] - local_.y, parceiro.p[3] - local_.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function teleportar_para(p, r)
    local go = go_jogador()
    if not go or not p then return false end
    -- Fica ~1 m atras do parceiro para nao nascer dentro dele
    local ox, oz = 0, 0
    if r then
        local x, y, z, w = r[1], r[2], r[3], r[4]
        local fx, fz = 2 * (x * z + w * y), 1 - 2 * (x * x + y * y)
        local n = math.sqrt(fx * fx + fz * fz)
        if n > 1e-3 then ox, oz = -fx / n, -fz / n end
    end
    ultimo_teleporte = agora()
    return mover_go(go, p[1] + ox, p[2] + 0.05, p[3] + oz, r)
end

local function ir_ate_parceiro(motivo)
    if not parceiro or not parceiro.p then registrar("Parceiro ainda nao conectado.") return end
    if mesma_area() then
        -- v0.26.4: parceiro em cena -> vai para onde ele estava antes da cena (o palco da cena nao e jogavel)
        local destino, rot = parceiro.p, parceiro.r
        if parceiro.cena and type(parceiro.cp) == "table" then destino, rot = parceiro.cp, parceiro.cr end
        if teleportar_para(destino, rot) then registrar(motivo or "Teleportado ate o parceiro.") end
    elseif porta_parceiro then
        if teleportar_para(porta_parceiro.p, porta_parceiro.r) then
            registrar("Parceiro esta em outra area. Voce foi levado ate a porta que ele usou.")
        end
    else
        registrar("Parceiro esta em outra area (" .. nome_estagio(parceiro.est) .. ").")
    end
end

---------------------------------------------------------------------------
-- Inimigos: cada um tem um ID fixo (Context.get_ID().get_Code(), o mesmo nos dois jogos).
-- O dano que cada jogo causa vai para o outro, que aplica com HitPoint.addDamage
-- (o mesmo metodo do jogo: o inimigo reage e morre com animacao).
---------------------------------------------------------------------------
do
    local conhecido = {}   -- codigo -> ultima vida vista (ja contando o dano vindo do parceiro)
    local pendente = {}    -- codigo -> dano recebido para um inimigo que ainda nao existe no seu jogo
    local mortes = {}      -- v0.19: codigo -> quando o parceiro avisou que morreu (repete ate pegar)
    local prox = 0

    local function codigo_ctx(ctx)
        local id = tentar(ctx, { "get_ID" })
        if not id then return nil end
        local ok, c = pcall(id.call, id, "get_Code")
        if ok and type(c) == "number" and c ~= 0 then return c end
    end

    local function vida(hp)
        local ok, v = pcall(hp.call, hp, "get_CurrentHitPoint")
        if ok and type(v) == "number" then return v end
    end

    local function cada_inimigo(fn)
        local lista = tentar(personagens(), { "get_EnemyContextList" })
        local n = lista and tentar(lista, { "get_Count" }) or 0
        for i = 0, n - 1 do
            local ok, ctx = pcall(lista.call, lista, "get_Item", i)
            if ok and ctx then
                local cod = codigo_ctx(ctx)
                local hp = cod and tentar(ctx, { "get_HitPoint" })
                if hp then fn(cod, hp) end
            end
        end
        return n
    end

    local function aplicar(hp, cod, dano)
        local antes = vida(hp)
        if not antes or antes <= 0 then return end
        -- v0.19: com o "cerebro" de animacao desligado (copiando o dono) o jogo nao processa a
        -- morte e o inimigo fica imortal com vida 0. Religa antes de aplicar o dano.
        if Inimigos.religar_anim then pcall(Inimigos.religar_anim, cod) end
        dano = math.min(math.floor(dano + 0.5), antes)
        if dano <= 0 then return end
        -- Marca como ja visto antes de aplicar, para esse dano nao voltar para o parceiro
        conhecido[cod] = antes - dano
        pcall(hp.call, hp, "addDamage", dano)
        conhecido[cod] = vida(hp) or conhecido[cod]
    end

    function Inimigos.tick()
        if not cfg.sync_inimigos or not parceiro or agora() - parceiro_recebido_em > 3 then return end
        local t = agora()
        if t < prox then return end
        prox = t + 0.1
        local danos = {}
        Inimigos.vistos = cada_inimigo(function(cod, hp)
            -- Dano que chegou antes de este inimigo existir no seu jogo
            if pendente[cod] then
                local d = pendente[cod]
                pendente[cod] = nil
                aplicar(hp, cod, d)
            end
            -- Morreu no parceiro mas aqui recusou o dano (agarrando, jogando molotov...): insiste
            local m = mortes[cod]
            if m then
                local v0 = vida(hp)
                if not v0 or v0 <= 0 or t - m > 15 then
                    mortes[cod] = nil
                else
                    aplicar(hp, cod, 1000000)
                    Inimigos.insistencias = (Inimigos.insistencias or 0) + 1
                end
            end
            local v = vida(hp)
            if not v then return end
            local antes = conhecido[cod]
            -- Morreu aqui: manda dano "infinito" para morrer la tambem, mesmo que a vida nao bata (v0.16)
            if antes and v < antes then danos[#danos + 1] = { c = cod, d = (v <= 0 and antes > 0) and 1000000 or (antes - v) } end
            conhecido[cod] = v
        end)
        local np = 0
        for _ in pairs(pendente) do np = np + 1 end
        Inimigos.pendentes = np
        if #danos > 0 then
            enviar_evento("dano", danos)
            Inimigos.enviados = Inimigos.enviados + #danos
            Inimigos.ultimo = string.format("voce causou %d de dano", danos[1].d)
        end
    end

    function Inimigos.receber(lista)
        if not cfg.sync_inimigos or type(lista) ~= "table" then return end
        local por_cod = {}
        for _, d in ipairs(lista) do
            if type(d) == "table" and type(d.c) == "number" and type(d.d) == "number" then
                por_cod[d.c] = (por_cod[d.c] or 0) + d.d
                if d.d >= 1000000 then mortes[d.c] = agora() end
            end
        end
        local achados = {}
        cada_inimigo(function(cod, hp)
            local d = por_cod[cod]
            if d then
                achados[cod] = true
                aplicar(hp, cod, d)
            end
        end)
        for cod, d in pairs(por_cod) do
            Inimigos.recebidos = Inimigos.recebidos + 1
            if not achados[cod] then pendente[cod] = (pendente[cod] or 0) + d end
        end
        Inimigos.ultimo = "parceiro causou dano"
    end

    -- Posicoes (v0.15): cada inimigo tem um DONO, o jogo de quem esta mais perto dele.
    -- No dono a IA de verdade persegue um jogador de verdade; o dono manda a posicao e o
    -- outro jogo puxa o mesmo inimigo para la. Sem combinacao, o dono e o anfitriao.
    local alvos = {}       -- codigo -> { p = {x,y,z}, r = {x,y,z,w}, t = recebido em }
    local prox_envio = 0
    local dono = {}        -- codigo -> "eu" | "ele" (vazio = padrao, o anfitriao)
    local dono_desde = {}  -- codigo -> quando o dono mudou
    local nao_dar_ate = {} -- codigo -> nao entregar antes disso (evita vai-e-volta)
    local visto_desde = {} -- codigo -> desde quando esta carregado aqui
    local carregados_dele = {}  -- codigo -> true (lista "ec" do parceiro)
    local TROCA_M, SEM_DADOS_S, CARENCIA_S = 3, 3, 1
    Inimigos.meus, Inimigos.seguidos, Inimigos.entregues, Inimigos.ganhos = 0, 0, 0, 0
    Inimigos.trocas_anim, Inimigos.animados = 0, 0

    -- Animacao (v0.18): o dono manda banco/animacao/quadro das camadas 0 e 2; quem segue
    -- desliga o "cerebro" de animacao (via.motion.MotionFsm2) e toca o mesmo com
    -- chainsaw.MotionController.changeMotion + TreeLayer.set_Frame (testado em jogo).
    local SEM_ANIM = 4294967295
    local CAMADAS = { 0, 2 }
    local T_MOT, T_FSM, T_MC = sdk.typeof("via.motion.Motion"), sdk.typeof("via.motion.MotionFsm2"), sdk.typeof("chainsaw.MotionController")
    local comps_anim = {}  -- codigo -> { end = endereco do GameObject, mot, fsm, mc }
    local fsm_off = {}     -- codigo -> MotionFsm2 desligado por nos

    local function anim_de(cod, go)
        local ok, ender = pcall(go.get_address, go)
        local c = comps_anim[cod]
        if c and ok and c.ender == ender then return c end
        c = { ender = ok and ender or nil }
        pcall(function()
            c.mot = go:call("getComponent(System.Type)", T_MOT)
            c.fsm = go:call("getComponent(System.Type)", T_FSM)
            c.mc = go:call("getComponent(System.Type)", T_MC)
        end)
        comps_anim[cod] = c
        return c
    end

    local function religar_fsm(cod)
        local f = fsm_off[cod]
        if f then pcall(f.call, f, "set_Enabled", true) end
        fsm_off[cod] = nil
    end
    Inimigos.religar_anim = religar_fsm

    local function dono_de(cod)
        return dono[cod] or (papel() == "anfitriao" and "eu" or "ele")
    end

    local function mudar_dono(cod, quem)
        dono[cod] = quem
        dono_desde[cod] = agora()
    end

    function Inimigos.reset()
        for cod in pairs(fsm_off) do religar_fsm(cod) end
        comps_anim = {}
        dono, dono_desde, nao_dar_ate, visto_desde, carregados_dele, alvos = {}, {}, {}, {}, {}, {}
    end

    local function dist(a, x, y, z)
        return math.sqrt((a[1] - x) ^ 2 + (a[2] - y) ^ 2 + (a[3] - z) ^ 2)
    end

    -- Lista plana [codigo, x, y, z, qx, qy, qz, qw, ...] dos inimigos vivos que sao MEUS,
    -- mais a lista dos codigos carregados aqui (o parceiro so me entrega o que eu tenho).
    -- Tambem decide as entregas: se o parceiro esta 3 m mais perto, o inimigo passa para ele.
    function Inimigos.capturar_posicoes()
        if not cfg.sync_inimigos or not cfg.inimigos_seguem or not local_.ok then return nil end
        local t = agora()
        if not parceiro or t - parceiro_recebido_em > 3 or not mesma_area() then return nil end
        if t < prox_envio then return nil end
        prox_envio = t + 1 / 15
        -- v0.24: eu pausei -> os meus inimigos passam a ser do parceiro (o jogo dele continua rodando)
        if Sala.pausado then
            for cod in pairs(visto_desde) do
                if dono_de(cod) == "eu" then mudar_dono(cod, "ele") end
            end
            return nil
        end
        local pp = type(parceiro.p) == "table" and parceiro.p or nil
        local plano, ec, entregar, meus = {}, {}, {}, 0
        local agora_visto = {}
        local lista = tentar(personagens(), { "get_EnemyContextList" })
        local n = lista and tentar(lista, { "get_Count" }) or 0
        for i = 0, n - 1 do
            local ok, ctx = pcall(lista.call, lista, "get_Item", i)
            local cod = ok and ctx and codigo_ctx(ctx)
            local hp = cod and tentar(ctx, { "get_HitPoint" })
            local v = hp and vida(hp)
            local go = v and v > 0 and tentar(ctx, { "get_BodyGameObject" })
            local p, r = nil, nil
            if go then p, r = ler_transform(go) end
            if p and r then
                agora_visto[cod] = true
                if not visto_desde[cod] then
                    visto_desde[cod] = t
                    -- Primeiro a ver e o dono (v0.16): se o parceiro ja tem este inimigo carregado
                    -- (ex.: o evento da torre aconteceu antes na tela dele), ele manda; senao, eu.
                    if not dono[cod] then mudar_dono(cod, carregados_dele[cod] and "ele" or "eu") end
                end
                if #ec < 40 then ec[#ec + 1] = cod end
                local d_eu = math.sqrt((p.x - local_.x) ^ 2 + (p.y - local_.y) ^ 2 + (p.z - local_.z) ^ 2)
                local d_ele = pp and dist(pp, p.x, p.y, p.z) or math.huge
                if dono_de(cod) == "ele" and parceiro.pau then
                    -- v0.24: o parceiro pausou -> assumo na hora (e nao devolvo logo que ele voltar)
                    mudar_dono(cod, "eu")
                    nao_dar_ate[cod] = t + 5
                    Inimigos.ganhos = Inimigos.ganhos + 1
                elseif dono_de(cod) == "ele" then
                    -- O dono sumiu (descarregou o inimigo ou parou de mandar): assumo
                    local alvo = alvos[cod]
                    local ultimo = math.max(alvo and alvo.t or 0, visto_desde[cod], dono_desde[cod] or 0)
                    if t - ultimo > SEM_DADOS_S then
                        mudar_dono(cod, "eu")
                        nao_dar_ate[cod] = t + 10
                        Inimigos.ganhos = Inimigos.ganhos + 1
                    end
                elseif d_ele + TROCA_M < d_eu and carregados_dele[cod] and t >= (nao_dar_ate[cod] or 0)
                    and t - (dono_desde[cod] or 0) > CARENCIA_S then
                    mudar_dono(cod, "ele")
                    entregar[#entregar + 1] = cod
                end
                if dono_de(cod) == "eu" and math.min(d_eu, d_ele) < 60 and #plano < 14 * 24 then
                    meus = meus + 1
                    local base = #plano
                    plano[base + 1] = cod
                    plano[base + 2], plano[base + 3], plano[base + 4] = arred(p.x, 3), arred(p.y, 3), arred(p.z, 3)
                    plano[base + 5], plano[base + 6], plano[base + 7], plano[base + 8] = arred(r.x, 3), arred(r.y, 3), arred(r.z, 3), arred(r.w, 3)
                    -- v0.18: camadas 0 e 2 = banco, animacao, quadro
                    local c = anim_de(cod, go)
                    for k, li in ipairs(CAMADAS) do
                        local b, m, f = 0, SEM_ANIM, 0
                        pcall(function()
                            local L = c.mot:call("getLayer", li)
                            b, m, f = L:call("get_MotionBankID"), L:call("get_MotionID"), L:call("get_Frame")
                        end)
                        local o = base + 8 + (k - 1) * 3
                        plano[o + 1], plano[o + 2], plano[o + 3] = b or 0, m or SEM_ANIM, arred(f or 0, 1)
                    end
                end
            end
        end
        for cod in pairs(visto_desde) do
            if not agora_visto[cod] then visto_desde[cod] = nil end
        end
        if #entregar > 0 then
            enviar_evento("dono", entregar)
            Inimigos.entregues = Inimigos.entregues + #entregar
            Inimigos.ultimo = string.format("%d inimigo(s) passaram para o parceiro (ele esta mais perto)", #entregar)
        end
        Inimigos.meus = meus
        return plano, ec
    end

    -- O parceiro me entregou estes inimigos
    function Inimigos.receber_dono(lista)
        if type(lista) ~= "table" then return end
        for _, cod in ipairs(lista) do
            if type(cod) == "number" then mudar_dono(cod, "eu") end
        end
        Inimigos.ganhos = Inimigos.ganhos + #lista
        Inimigos.ultimo = string.format("voce virou dono de %d inimigo(s) (esta mais perto)", #lista)
    end

    -- Guarda o ultimo alvo de cada inimigo que o parceiro manda, e o que ele tem carregado
    function Inimigos.receber_posicoes(plano, ec)
        local t = agora()
        if type(ec) == "table" then
            carregados_dele = {}
            for _, cod in ipairs(ec) do carregados_dele[cod] = true end
        end
        if type(plano) ~= "table" then return end
        for i = 1, #plano - 13, 14 do
            local cod = plano[i]
            -- Os dois acham que sao donos: o anfitriao fica (o convidado cede, passada a carencia)
            if dono_de(cod) == "eu" and papel() == "convidado" and t - (dono_desde[cod] or 0) > CARENCIA_S then
                mudar_dono(cod, "ele")
            end
            alvos[cod] = { p = { plano[i + 1], plano[i + 2], plano[i + 3] },
                r = { plano[i + 4], plano[i + 5], plano[i + 6], plano[i + 7] }, t = t,
                a = { plano[i + 8], plano[i + 9], plano[i + 10], plano[i + 11], plano[i + 12], plano[i + 13] } }
        end
    end

    -- A cada frame, nos inimigos do parceiro: aproxima suavemente; longe demais (> 4 m), teleporta
    local ultimo_frame = 0

    -- Toca no inimigo daqui a mesma animacao/quadro que o dono esta tocando
    local function animar(cod, go, alvo, t)
        local c = anim_de(cod, go)
        if not c.mot or not c.mc or not c.fsm then return false end
        if not fsm_off[cod] then
            c.fsm:call("set_Enabled", false)
            fsm_off[cod] = c.fsm
        end
        local a = alvo.a
        for k, li in ipairs(CAMADAS) do
            local b, m, f = a[(k - 1) * 3 + 1], a[(k - 1) * 3 + 2], a[(k - 1) * 3 + 3]
            if type(b) == "number" and type(m) == "number" and type(f) == "number" and m ~= SEM_ANIM then
                local L = c.mot:call("getLayer", li)
                if L then
                    if L:call("get_MotionBankID") ~= b or L:call("get_MotionID") ~= m then
                        c.mc:call("changeMotion(System.Int32, System.UInt32, System.UInt32, System.Single)", li, b, m, 6.0)
                        Inimigos.trocas_anim = Inimigos.trocas_anim + 1
                    end
                    local q = f + (t - alvo.t) * 60
                    local fim = L:call("get_EndFrame") or 0
                    if fim > 0 and q > fim then q = q % fim end
                    L:call("set_Frame", q)
                end
            end
        end
        return true
    end

    function Inimigos.seguir()
        local t = agora()
        local dt = math.min(0.1, t - ultimo_frame)
        ultimo_frame = t
        local ativo = cfg.sync_inimigos and cfg.inimigos_seguem and parceiro and t - parceiro_recebido_em <= 3
        if not ativo then
            for cod in pairs(fsm_off) do religar_fsm(cod) end
            Inimigos.animados = 0
            return
        end
        local k = 1 - math.exp(-dt * 12)
        local seguidos = 0
        local animados = {}
        local lista = tentar(personagens(), { "get_EnemyContextList" })
        local n = lista and tentar(lista, { "get_Count" }) or 0
        for i = 0, n - 1 do
            local ok, ctx = pcall(lista.call, lista, "get_Item", i)
            local cod = ok and ctx and codigo_ctx(ctx)
            local alvo = cod and dono_de(cod) == "ele" and alvos[cod]
            -- Morto aqui nao se mexe mais (v0.16: corpo andando pelo mapa)
            local hpo = alvo and tentar(ctx, { "get_HitPoint" })
            local vo = hpo and vida(hpo)
            if vo and vo <= 0 then alvo = nil end
            if alvo and t - alvo.t < 0.6 then
                local go = tentar(ctx, { "get_BodyGameObject" })
                local p = go and ler_transform(go)
                if p then
                    local a = alvo.p
                    local d2 = (a[1] - p.x) ^ 2 + (a[2] - p.y) ^ 2 + (a[3] - p.z) ^ 2
                    if d2 > 16 then
                        mover_go(go, a[1], a[2], a[3], alvo.r)
                    elseif d2 > 0.0004 then
                        mover_go(go, p.x + (a[1] - p.x) * k, p.y + (a[2] - p.y) * k, p.z + (a[3] - p.z) * k, alvo.r)
                    end
                    seguidos = seguidos + 1
                    if cfg.inimigos_animacao and alvo.a then
                        local oka, r = pcall(animar, cod, go, alvo, t)
                        if oka and r then animados[cod] = true end
                        if not oka then Inimigos.ultimo = "erro animacao: " .. tostring(r) end
                    end
                end
            end
        end
        -- Quem nao esta mais sendo animado por nos (morreu, trocou de dono, sem dados) volta ao normal
        local na = 0
        for cod in pairs(fsm_off) do
            if animados[cod] then na = na + 1 else religar_fsm(cod) end
        end
        Inimigos.animados = na
        Inimigos.seguidos = seguidos
    end
end

---------------------------------------------------------------------------
-- Historia (v0.17): bandeiras de cenario (chainsaw.ScenarioFlagManager, por Guid).
-- Elas CAUSAM os eventos roteirizados (testado: marcar as bandeiras da torre da vila faz
-- ela explodir sem passar pelo gatilho). Quando uma vira "true" num jogo, o outro marca a
-- mesma. So "true": a historia so anda para frente (save antigo nao desfaz nada no outro).
-- So aplica na mesma area; senao espera o reencontro.
---------------------------------------------------------------------------
local Historia = { enviadas = 0, recebidas = 0, aplicadas = 0, esperando = 0, ultimo = "-" }
do
    local fila = {}       -- guids marcados aqui, a enviar
    local espera = {}     -- guids recebidos, a aplicar quando estiver na mesma area
    local aplicando = false
    local TD_GUID = sdk.find_type_definition("System.Guid")
    local M_PARSE = TD_GUID and TD_GUID:get_method("Parse(System.String)")
    local TD_SF = sdk.find_type_definition("chainsaw.ScenarioFlagManager")
    local M_REQ = TD_SF and TD_SF:get_method("requestSetFlag(System.Guid, System.Boolean)")

    if M_REQ then
        sdk.hook(M_REQ, function(args)
            if aplicando or not cfg.sync_historia then return end
            local ok, v = pcall(sdk.to_int64, args[4])
            if not ok or not v or (v & 1) == 0 then return end
            local okg, s = pcall(function() return sdk.to_valuetype(args[3], "System.Guid"):call("ToString()") end)
            if okg and type(s) == "string" and #s == 36 and #fila < 300 then fila[#fila + 1] = s end
        end, nil)
    end

    local function aplicar_espera()
        local m = sdk.get_managed_singleton("chainsaw.ScenarioFlagManager")
        if not m or not M_PARSE then return end
        local novas = 0
        aplicando = true
        for s in pairs(espera) do
            pcall(function()
                local g = M_PARSE:call(nil, s)
                if not m:call("checkFlag(System.Guid)", g) then
                    m:call("requestSetFlag(System.Guid, System.Boolean)", g, true)
                    novas = novas + 1
                end
            end)
        end
        aplicando = false
        espera = {}
        Historia.aplicadas = Historia.aplicadas + novas
        if novas > 0 then
            Historia.ultimo = string.format("parceiro avancou a historia: %d bandeira(s) aplicada(s)", novas)
            registrar("O parceiro avancou a historia (evento sincronizado).")
        end
    end

    function Historia.tick()
        local online = parceiro and agora() - parceiro_recebido_em <= 3
        if online and #fila > 0 then
            local lote = {}
            while #fila > 0 and #lote < 20 do lote[#lote + 1] = table.remove(fila, 1) end
            enviar_evento("hist", lote)
            Historia.enviadas = Historia.enviadas + #lote
            Historia.ultimo = string.format("voce avancou a historia (%d bandeira(s) enviadas)", #lote)
        end
        local n = 0
        for _ in pairs(espera) do n = n + 1 end
        Historia.esperando = n
        if n > 0 and cfg.sync_historia and online and mesma_area() then aplicar_espera() end
    end

    function Historia.receber(lista)
        if not cfg.sync_historia or type(lista) ~= "table" then return end
        for _, s in ipairs(lista) do
            if type(s) == "string" and #s == 36 then
                espera[s] = true
                Historia.recebidas = Historia.recebidas + 1
            end
        end
    end
end

---------------------------------------------------------------------------
-- Objetos do cenario (portas, alavancas, escadas, bau...): cada um tem um codigo fixo
-- (GimmickCore.ID._Code, vem dos dados do mapa) e uma "bandeira" de usado (getGmFlag).
-- Quando a bandeira muda num jogo, o outro aciona o mesmo objeto.
---------------------------------------------------------------------------
local TD_CORE = sdk.find_type_definition("chainsaw.GimmickCore")
local TD_GMBASE = sdk.find_type_definition("chainsaw.GmBase")
-- Tipos que NAO sincronizam: itens/documentos (pegar no seu jogo nao pode sumir do dela)
-- v0.19: caixas de madeira (WoodBox) sincronizam: setGmFlag(true) quebra a caixa (testado) e o item fica para o outro
local OBJ_IGNORAR = { "Item", "ReadFile", "BlueCoin", "SrRamon", "Treasure", "Merchant", "Typewriter", "SavePoint",
    "Locker", "WeaponUpgrade", "Camera", "MapIcon", "AutoSave", "KeepInCamera", "ViewPoint", "AlwaysRigid" }
local SIG_SET_FLAG = "setGmFlag(System.Boolean, chainsaw.InteractTrigger, chainsaw.InteractActionArgs)"
local objetos = { lista = {}, por_codigo = {}, estado = {}, prox_lista = 0, prox_leitura = 0, ultimo = "-", enviados = 0, recebidos = 0 }

local function codigo_objeto(core)
    local id = tentar(core, { "get_ID" })
    if not id then return nil end
    local ok, c = pcall(id.call, id, "get_Code")
    if ok and type(c) == "number" and c ~= 0 then return c end
end

local function gmbase_de(go)
    local comps = tentar(go, { "get_Components" })
    local ok, el = false, nil
    if comps then ok, el = pcall(comps.get_elements, comps) end
    for _, c in ipairs(ok and el or {}) do
        local okt, td = pcall(c.get_type_definition, c)
        if okt and td and TD_GMBASE and td:is_a(TD_GMBASE) then
            local nome = td:get_name()
            for _, ign in ipairs(OBJ_IGNORAR) do
                if nome:find(ign) then return nil, nome end
            end
            return c, nome
        end
    end
end

local function atualizar_lista_objetos()
    local s = cena()
    if not s or not TD_CORE then return end
    local ok, arr = pcall(s.call, s, "findComponents(System.Type)", TD_CORE:get_runtime_type())
    local ok2, el = false, nil
    if ok and arr then ok2, el = pcall(arr.get_elements, arr) end
    local lista, por_codigo = {}, {}
    for _, core in ipairs(ok2 and el or {}) do
        local cod = codigo_objeto(core)
        local go = cod and tentar(core, { "get_GameObject" })
        local gm, tipo = nil, nil
        if go then gm, tipo = gmbase_de(go) end
        if gm then
            local item = { codigo = cod, core = core, gm = gm, ctx = tentar(core, { "get_GmkContext" }), tipo = tipo,
                tr = componente(go, T_TRANSFORM) }
            lista[#lista + 1] = item
            por_codigo[cod] = item
        end
    end
    objetos.lista, objetos.por_codigo = lista, por_codigo
end

local function bandeira(item)
    local ok, f = pcall(item.gm.call, item.gm, "getGmFlag")
    if ok and type(f) == "boolean" then return f end
    if item.ctx then
        local ok2, f2 = pcall(item.ctx.call, item.ctx, "getGmFlag")
        if ok2 and type(f2) == "boolean" then return f2 end
    end
end

local function vigiar_objetos()
    if not cfg.sync_objetos or not parceiro or agora() - parceiro_recebido_em > 3 then return end
    local t = agora()
    -- Varre a cena (~12 ms) a cada 10 s ou quando voce muda de area
    if t >= objetos.prox_lista or objetos.area ~= local_.est then
        if objetos.area ~= local_.est then
            -- Area nova: o jogo mexe em varias bandeiras enquanto carrega; espera assentar
            objetos.estado = {}
            objetos.vigiar_apos = t + 5
        end
        objetos.prox_lista = t + 10
        objetos.area = local_.est
        pcall(atualizar_lista_objetos)
    end
    if t < objetos.prox_leitura then return end
    objetos.prox_leitura = t + 0.3
    local enviar = t >= (objetos.vigiar_apos or 0) and local_.ok
    for _, item in ipairs(objetos.lista) do
        local f = bandeira(item)
        if f ~= nil then
            local antes = objetos.estado[item.codigo]
            objetos.estado[item.codigo] = f
            -- So mudancas feitas por VOCE: o objeto tem que estar a menos de 4 m do seu personagem.
            -- Mudancas que o jogo faz sozinho (longe de voce) ficam so no seu jogo.
            if enviar and antes ~= nil and antes ~= f then
                local ok, p = pcall(item.tr.call, item.tr, "get_Position")
                -- Caixas quebram com tiro de longe (o jogo nao quebra caixa sozinho): ate 40 m
                local tp = tostring(item.tipo)
                local lim = (tp:find("WoodBox") or tp:find("SensorBomb")) and 1600 or 16
                local perto = ok and p and ((p.x - local_.x) ^ 2 + (p.y - local_.y) ^ 2 + (p.z - local_.z) ^ 2) < lim
                if perto then
                    enviar_evento("obj", { c = item.codigo, f = f, n = item.tipo })
                    objetos.enviados = objetos.enviados + 1
                    objetos.ultimo = "voce usou " .. tostring(item.tipo)
                else
                    objetos.ignorados = (objetos.ignorados or 0) + 1
                end
            end
        end
    end
end

local function aplicar_objeto(d)
    if not cfg.sync_objetos or type(d) ~= "table" or type(d.c) ~= "number" then return end
    local item = objetos.por_codigo[d.c]
    if not item then
        pcall(atualizar_lista_objetos)
        item = objetos.por_codigo[d.c]
    end
    objetos.recebidos = objetos.recebidos + 1
    if not item then
        objetos.ultimo = "objeto " .. tostring(d.n) .. " nao existe na sua area"
        return
    end
    local f = d.f == true
    -- Marca antes de aplicar, para a mudanca nao voltar para o parceiro
    objetos.estado[d.c] = f
    if bandeira(item) == f then return end
    if not pcall(item.gm.call, item.gm, SIG_SET_FLAG, f, nil, nil) and item.ctx then
        pcall(item.ctx.call, item.ctx, "setGmFlag", f)
    end
    objetos.ultimo = "parceiro usou " .. tostring(item.tipo) .. " -> " .. ((bandeira(item) == f) and "aplicado" or "NAO aplicou")
    registrar("Parceiro usou: " .. tostring(item.tipo):gsub("^Gm", ""))
end

-- v0.19: acoes de alcapao/portao grande/alavanca/tranca (executeFSMAction). So mudar a bandeira
-- nao abre esses (o alcapao ficava fechado no outro jogo). Quem usa manda a acao; o outro executa.
objetos.acoes_env, objetos.acoes_rec = 0, 0
do
    local aplicando_acao = false
    local ultima = {}  -- "codigo:acao" -> quando enviou (evita repetir)
    local T_CORE_RT = TD_CORE and TD_CORE:get_runtime_type()
    for _, nome in ipairs({ "GmFloorBoard", "GmBigDoor", "GmLever", "GmBigDoorLock" }) do
        local td = sdk.find_type_definition("chainsaw." .. nome)
        local m = td and td:get_method("executeFSMAction(System.Int32)")
        if m then
            sdk.hook(m, function(args)
                if aplicando_acao or not cfg.sync_objetos or not local_.ok then return end
                if not parceiro or agora() - parceiro_recebido_em > 3 then return end
                if agora() < (objetos.vigiar_apos or 0) then return end
                pcall(function()
                    local acao = sdk.to_int64(args[3]) & 0xFFFFFFFF
                    local gm = sdk.to_managed_object(args[2])
                    local go = gm:call("get_GameObject")
                    local core = go:call("getComponent(System.Type)", T_CORE_RT)
                    local cod = core and codigo_objeto(core)
                    if not cod then return end
                    local p = go:call("get_Transform"):call("get_Position")
                    if ((p.x - local_.x) ^ 2 + (p.y - local_.y) ^ 2 + (p.z - local_.z) ^ 2) > 16 then return end
                    local chave = cod .. ":" .. acao
                    if agora() - (ultima[chave] or -10) < 1 then return end
                    ultima[chave] = agora()
                    enviar_evento("acao", { c = cod, a = acao, n = nome })
                    objetos.acoes_env = objetos.acoes_env + 1
                    objetos.ultimo = string.format("voce usou %s (acao %d)", nome, acao)
                end)
            end, nil)
        end
    end

    function objetos.aplicar_acao(d)
        if not cfg.sync_objetos or type(d) ~= "table" or type(d.c) ~= "number" or type(d.a) ~= "number" then return end
        local item = objetos.por_codigo[d.c]
        if not item then
            pcall(atualizar_lista_objetos)
            item = objetos.por_codigo[d.c]
        end
        objetos.acoes_rec = objetos.acoes_rec + 1
        if not item then
            objetos.ultimo = "acao em " .. tostring(d.n) .. ": objeto nao existe na sua area"
            return
        end
        -- O componente do mesmo tipo que o parceiro usou (portao e tranca podem estar no mesmo objeto)
        local alvo = item.gm
        pcall(function()
            local t = sdk.typeof("chainsaw." .. tostring(d.n))
            local c = t and item.core:call("get_GameObject"):call("getComponent(System.Type)", t)
            if c then alvo = c end
        end)
        aplicando_acao = true
        local ok, e = pcall(alvo.call, alvo, "executeFSMAction(System.Int32)", d.a)
        aplicando_acao = false
        objetos.ultimo = string.format("parceiro usou %s (acao %d) -> %s", tostring(d.n), d.a, ok and "executado" or ("erro " .. tostring(e)))
        if ok then registrar("Parceiro usou: " .. tostring(d.n):gsub("^Gm", "")) end
    end
end

-- v0.25: ITENS-CHAVE COMPARTILHADOS. Quem pega um item-chave (chainsaw.Item ItemType 0 = Key) que esta
-- colocado no mapa (ContextID categoria 2, codigo fixo igual nos dois jogos) avisa o parceiro; o jogo dele
-- acha o mesmo item, poe no inventario de chaves (KeyItemInventoryController.pickupItem) e zera o item do
-- chao (DropItemContext.setCountZero). Se o item ainda nao carregou (outra area), fica pendente (arquivo).
Sala.chaves = { pendentes = nil, aplicando = false, prox = 0, recebidas = 0, enviadas = 0 }
function Sala.chaves.carregar()
    if Sala.chaves.pendentes then return end
    local ok, t = pcall(json.load_file, PASTA .. "chaves_pendentes.json")
    Sala.chaves.pendentes = (ok and type(t) == "table") and t or {}
end
function Sala.chaves.salvar() pcall(json.dump_file, PASTA .. "chaves_pendentes.json", Sala.chaves.pendentes) end
function Sala.chaves.controlador()
    local im = sdk.get_managed_singleton("chainsaw.InventoryManager")
    local tab = im and im:get_field("_ControllerTable")
    if not tab then return nil end
    for _, e in ipairs(tab:get_field("_entries"):get_elements()) do
        local v = e:get_field("value")
        if v and v:get_type_definition():get_full_name() == "chainsaw.KeyItemInventoryController" then return v end
    end
end
function Sala.chaves.receber(d)
    if type(d) ~= "table" or type(d.c) ~= "number" then return end
    Sala.chaves.carregar()
    Sala.chaves.pendentes[tostring(d.c)] = d.i or 0
    Sala.chaves.salvar()
    Sala.chaves.prox = 0
end
-- Chamado a cada quadro: no maximo 1 vez por segundo, e so se houver chave pendente
function Sala.chaves.tick()
    if not cfg.sync_chaves or not local_.ok or agora() < Sala.chaves.prox then return end
    Sala.chaves.prox = agora() + 1
    Sala.chaves.carregar()
    if next(Sala.chaves.pendentes) == nil then return end
    local cena = sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"),
        sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
    local lista = cena and cena:call("findComponents(System.Type)", sdk.typeof("chainsaw.DropItem"))
    if not lista then return end
    local kc = Sala.chaves.controlador()
    local mudou = false
    for _, dr in ipairs(lista:get_elements()) do
        local okc, cod = pcall(function() return dr:get_field("_ID"):get_field("_Code") end)
        local k = okc and tostring(cod)
        if k and Sala.chaves.pendentes[k] then
            local ctx = dr:get_field("<DropItemContext>k__BackingField")
            local item = dr:get_field("_Item")
            local okn, qtd = pcall(ctx.call, ctx, "getCount")
            if okn and qtd and qtd > 0 and kc and item then
                Sala.chaves.aplicando = true
                local ok1 = pcall(kc.call, kc, "pickupItem(chainsaw.Item)", item)
                pcall(ctx.call, ctx, "setCountZero")
                Sala.chaves.aplicando = false
                if ok1 then
                    Sala.chaves.recebidas = Sala.chaves.recebidas + 1
                    registrar("O parceiro pegou um item-chave: ele tambem esta com voce.")
                end
            end
            -- ja pego aqui tambem (quantidade 0) ou entregue agora: sai da lista
            Sala.chaves.pendentes[k] = nil
            mudou = true
        end
    end
    if mudou then Sala.chaves.salvar() end
end
pcall(function()
    sdk.hook(sdk.find_type_definition("chainsaw.DropItem"):get_method("onChangeCountByInventory"), function(args)
        if not cfg.sync_chaves or Sala.chaves.aplicando or cfg.modo == "parado" then return end
        pcall(function()
            local dr = sdk.to_managed_object(args[2])
            local item = dr:get_field("_Item")
            if not item or item:call("get_ItemType") ~= 0 then return end          -- 0 = Key
            local id = dr:get_field("_ID")
            if id:get_field("_Category") ~= 2 then return end                       -- so itens colocados no mapa
            enviar_evento("chave", { c = id:get_field("_Code"), i = item:get_field("_ItemId") })
            Sala.chaves.enviadas = Sala.chaves.enviadas + 1
        end)
    end, nil)
end)

local function processar_evento(ev)
    if ev.tipo == "puxar" then
        ir_ate_parceiro("O parceiro te puxou ate ele.")
    elseif ev.tipo == "msg" and type(ev.d) == "string" then
        registrar(ev.d, parceiro and parceiro.nome or "Parceiro")
    elseif ev.tipo == "obj" then
        aplicar_objeto(ev.d)
    elseif ev.tipo == "dano" then
        Inimigos.receber(ev.d)
    elseif ev.tipo == "dono" then
        Inimigos.receber_dono(ev.d)
    elseif ev.tipo == "hist" then
        Historia.receber(ev.d)
    elseif ev.tipo == "acao" then
        objetos.aplicar_acao(ev.d)
    elseif ev.tipo == "salvar_coop" then
        Sala.salvar_apos = agora() + 0.5
    elseif ev.tipo == "chave" then
        Sala.chaves.receber(ev.d)
    end
end

local function ler_ponte()
    -- Sem conexao ativa, in.json pode ser de uma sessao antiga: ignora
    if not status_ponte.conectado or not ponte_relogio then return end
    local ok, st = pcall(json.load_file, ARQ.entrada)
    if not ok or type(st) ~= "table" or not st.seq then return end
    if st.s ~= parceiro_sessao then
        -- Parceiro reiniciou o jogo/script
        parceiro_sessao = st.s
        ultimo_seq_parceiro = -1
        ultimo_ev_parceiro = 0
        amostras = {}
        offset_relogio = nil
        tiros_parceiro_base = {}
        pcall(Inimigos.reset)
        registrar((st.nome or "Parceiro") .. " entrou na sessao.")
        -- O corpo do parceiro as vezes nasce errado ao entrar: recria sozinho (igual ao botao do F8)
        Sala.recriar_em = agora() + 4
    end
    if st.seq <= ultimo_seq_parceiro then return end
    ultimo_seq_parceiro = st.seq

    -- Guarda onde o parceiro estava antes de sair da minha area (a "porta")
    if parceiro and parceiro.p and parceiro.est and st.est and parceiro.est ~= st.est then
        if local_.est and parceiro.est == local_.est then
            porta_parceiro = { p = parceiro.p, r = parceiro.r, est = parceiro.est }
            registrar("Parceiro passou para outra area. Siga o marcador da porta (ou F5).")
        end
    end
    if porta_parceiro and st.est and local_.est and st.est == local_.est then porta_parceiro = nil end

    parceiro = st
    parceiro_recebido_em = agora()
    adicionar_amostra(st)

    if type(st.ack) == "number" then
        local restantes = {}
        for _, ev in ipairs(eventos_pendentes) do
            if ev.id > st.ack then table.insert(restantes, ev) end
        end
        eventos_pendentes = restantes
    end
    if type(st.ev) == "table" then
        for _, ev in ipairs(st.ev) do
            if type(ev) == "table" and type(ev.id) == "number" and ev.id > ultimo_ev_parceiro then
                ultimo_ev_parceiro = ev.id
                pcall(processar_evento, ev)
            end
        end
    end
    if type(st.am) == "string" then mascaras_parceiro = st.am end
    if st.en or st.ec then pcall(Inimigos.receber_posicoes, st.en, st.ec) end
    -- Disparos: compara a contagem de cada arma com a ultima vista
    if type(st.tc) == "string" then
        local i = 0
        for txt in st.tc:gmatch("[^,]+") do
            i = i + 1
            local n = tonumber(txt) or 0
            local base = tiros_parceiro_base[i]
            if base and n > base then
                -- Tiros seguidos (Chicago) ficam espacados ~60 ms entre si
                local t0 = agora() + cfg.atraso_ms / 1000
                for k = 1, math.min(n - base, 5) do table.insert(tiros_pendentes, { i = i, t = t0 + (k - 1) * 0.06 }) end
            end
            tiros_parceiro_base[i] = n
        end
    end
end

local function ler_status()
    local ok, st = pcall(json.load_file, ARQ.status)
    if ok and type(st) == "table" then
        status_ponte = st
        if st.relogio ~= ponte_relogio then
            ponte_relogio = st.relogio
            ponte_relogio_mudou = agora()
        end
    end
    local s = status_ponte.steam
    if type(s) ~= "table" or not s.ok then return end
    -- Convite aceito / "Entrar no jogo" pela Steam (o plugin ja esta entrando na sala)
    if type(s.convite) == "string" and s.convite ~= "" and s.convite ~= cfg.ultimo_convite then
        cfg.ultimo_convite = s.convite
        cfg.rede, cfg.modo, cfg.lobby = "steam", "entrar", s.convite
        salvar_cfg(); enviar_ctl()
        registrar("Convite da Steam aceito: entrando na sala do amigo...")
        Sala.janela_aberta = true; Sala.esconder = false
        if cfg.menu_jogo and Sala.Aba then Sala.Aba.abrir() end
    end
    -- O plugin achou sozinho a sala nova do anfitriao (reconexao): guarda para a proxima vez
    if cfg.rede == "steam" and cfg.modo == "entrar" and type(s.lobby) == "string" and s.lobby ~= cfg.lobby and not s.sou_dono then
        cfg.lobby = s.lobby; salvar_cfg()
    end
    -- O anfitriao apertou INICIAR PARTIDA
    if s.inicio ~= Sala.inicio_visto then
        local antes = Sala.inicio_visto
        Sala.inicio_visto = s.inicio
        if antes ~= nil and type(s.inicio) == "string" and s.inicio ~= "" and s.inicio ~= "0" then
            Sala.iniciada = { tipo = s.inicio_tipo, ate = agora() + 600 }
            Sala.juntou = false
            Sala.auto = { tipo = s.inicio_tipo, dif = tonumber(s.inicio_cap) or 20, ate = agora() + 120 }
            registrar(s.inicio_tipo == "continuar" and "PARTIDA INICIADA! Carregando o save co-op..."
                or "PARTIDA INICIADA! Comecando um jogo novo...")
        end
    end
end

local function ponte_viva() return ponte_relogio ~= nil and agora() - ponte_relogio_mudou < 2.5 end
local function parceiro_online() return parceiro ~= nil and agora() - parceiro_recebido_em < 3 end

---------------------------------------------------------------------------
-- Avatar do parceiro
---------------------------------------------------------------------------
local AVATARES = { "Clone do personagem (animado)", "Ashley ou Luis (quando estiverem na cena)", "Nenhum (so o nome)" }

local function go_companheiro()
    for _, n in ipairs({ "ch2a1z0_body", "ch2a3z0_body" }) do
        local go = go_cacheado(n)
        if go then return go end
    end
end

-- Clone: GameObjects novos com as mesmas malhas/materiais do seu personagem,
-- posicionados no parceiro e com o esqueleto copiado da pose que ele envia.
local clone = { partes = {}, armas = {}, status = "ainda nao criado", status_armas = "-", prox_tentativa = 0, visivel = nil }

local function destruir_clone()
    for _, lista in ipairs({ clone.partes, clone.armas }) do
        for _, p in pairs(lista) do
            if not chamar(p.go, { "destroy(via.GameObject)" }, p.go) then pcall(p.go.call, p.go, "set_DrawSelf", false) end
        end
    end
    clone.partes = {}
    clone.armas = {}
    clone.visivel = nil
end

local function clone_valido()
    if #clone.partes == 0 then return false end
    for _, p in ipairs(clone.partes) do
        if not valido(p.go) then return false end
    end
    return true
end

local function nome_go(g)
    if not g then return "?" end
    local n = tentar(g, { "get_Name" })
    return type(n) == "string" and n or tostring(n)
end

-- Percorre a hierarquia de Transforms (filhos e netos)
local function descendentes(tr, limite)
    local res = {}
    local function rec(t, prof)
        local c = tentar(t, { "get_Child" })
        local n = 0
        while c and n < 80 and #res < limite do
            table.insert(res, { tr = c, prof = prof })
            if prof < 5 then rec(c, prof + 1) end
            c = tentar(c, { "get_Next" })
            n = n + 1
        end
    end
    if tr then rec(tr, 1) end
    return res
end

-- Sobe ate a raiz do personagem (o corpo costuma ser filho de um objeto "chXaXzX")
local function raiz_personagem(go)
    local tr = componente(go, T_TRANSFORM)
    local raiz = tr
    for _ = 1, 3 do
        local pai = raiz and tentar(raiz, { "get_Parent" })
        if not pai then break end
        local n = nome_go(tentar(pai, { "get_GameObject" }))
        if not n:find("^ch%d") then break end
        raiz = pai
    end
    return raiz
end

-- Partes visiveis do personagem: filhos diretos com malha (body, head, hair...).
-- Armas (wpXXXX) e o que fica pendurado nelas (mira de granada, laser) ficam de fora.
local function partes_personagem(go)
    local res = {}
    if not go then return res end
    if componente(go, T_MESH) then table.insert(res, go) end
    local c = tentar(componente(go, T_TRANSFORM), { "get_Child" })
    local n = 0
    while c and n < 80 do
        local g = tentar(c, { "get_GameObject" })
        local nome = nome_go(g)
        if g and not nome:find("^wp") and not nome:find("RE4CoopBR") and componente(g, T_MESH) then
            table.insert(res, g)
        end
        c = tentar(c, { "get_Next" })
        n = n + 1
    end
    return res
end

local function malhas_do_jogador()
    local go = go_jogador()
    if not go then return nil, "personagem local nao encontrado" end
    local res = {}
    for _, g in ipairs(partes_personagem(go)) do
        table.insert(res, { orig = componente(g, T_MESH), nome = nome_go(g) })
    end
    if #res == 0 then return nil, "nenhuma malha encontrada no personagem " .. nome_go(go) end
    return res
end

local function tipo_de(obj)
    if not obj then return nil end
    local ok, n = pcall(function() return obj:get_type_definition():get_full_name() end)
    return ok and n or nil
end

-- Carrega um recurso do jogo pelo caminho (ex.: a malha da roupa do parceiro)
local function carregar_holder(tipo_holder, caminho)
    if not tipo_holder or not caminho then return nil end
    local tipo_res = tipo_holder:gsub("Holder$", "")
    local ok, res = pcall(sdk.create_resource, tipo_res, caminho)
    if not ok or not res then return nil end
    pcall(res.add_ref, res)
    local ok2, h = pcall(res.create_holder, res, tipo_holder)
    if not ok2 or not h then return nil end
    pcall(h.add_ref, h)
    return h
end

-- Fotografa a estrutura do personagem local para o diag.json
local function sondar_personagem()
    local r = {}
    local ctx = contexto_jogador()
    local go_ctx = tentar(ctx, { "get_BodyGameObject" })
    r.body_go_do_contexto = go_ctx and nome_go(go_ctx) or "nao"
    local go = go_jogador()
    r.go = go and nome_go(go) or "nenhum"
    if not go then return r end
    r.componentes = {}
    local comps = tentar(go, { "get_Components" })
    local ok, el = false, nil
    if comps then ok, el = pcall(comps.get_elements, comps) end
    for _, c in ipairs(ok and el or {}) do
        local ok2, tn = pcall(function() return c:get_type_definition():get_full_name() end)
        table.insert(r.componentes, ok2 and tn or "?")
    end
    local tr = componente(go, T_TRANSFORM)
    local pai = tr and tentar(tr, { "get_Parent" })
    r.pai = pai and nome_go(tentar(pai, { "get_GameObject" })) or "nenhum"
    local raiz = raiz_personagem(go)
    r.raiz = raiz and nome_go(tentar(raiz, { "get_GameObject" })) or "?"
    r.arvore = {}
    for _, d in ipairs(descendentes(raiz, 150)) do
        local g = tentar(d.tr, { "get_GameObject" })
        table.insert(r.arvore, string.rep("  ", d.prof - 1) .. nome_go(g) .. (componente(g, T_MESH) and " [MALHA]" or ""))
    end
    local s = cena()
    local ok3, arr = pcall(s.call, s, "findComponents(System.Type)", T_MESH)
    r.findComponents = ok3 and "ok" or tostring(arr)
    if ok3 and arr then
        local ok4, todas = pcall(arr.get_elements, arr)
        r.malhas_na_cena = ok4 and #todas or -1
        r.malhas_ch = {}
        for _, m in ipairs(ok4 and todas or {}) do
            local n = nome_go(tentar(m, { "get_GameObject" }))
            if n:find("^ch0") and #r.malhas_ch < 40 then table.insert(r.malhas_ch, n) end
        end
    end
    return r
end

local function criar_go(nome)
    if not GO_CREATE then return nil end
    local ok, g = pcall(GO_CREATE.call, GO_CREATE, nil, nome)
    if not ok or not g then return nil end
    pcall(g.add_ref, g)
    return g
end

-- Registro detalhado da ultima tentativa (vai para RE4CoopBR/diag.json)
local diag_clone = {}

local function construir_clone()
    destruir_clone()
    diag_clone = { inicio = os.date("%H:%M:%S"), etapas = {} }
    local function etapa(t)
        table.insert(diag_clone.etapas, t)
        log.info("[RE4 Co-op BR] corpo: " .. t)
    end
    if not GO_CREATE then
        clone.status = "via.GameObject.create indisponivel"
        etapa(clone.status)
        return
    end
    local locais, err = malhas_do_jogador()
    if not locais then
        clone.status = "falhou: " .. err
        etapa(clone.status)
        return
    end
    local local_por_nome = {}
    for _, mo in ipairs(locais) do local_por_nome[mo.nome] = local_por_nome[mo.nome] or mo end
    -- Tipos dos holders (descobertos na sua propria malha) para carregar os recursos do parceiro
    local ref = locais[1].orig
    local tipo_malha = tipo_de(tentar(ref, { "getMesh", "get_Mesh" }))
    local tipo_mat = tipo_de(tentar(ref, { "get_Material", "getMaterial" }))

    -- Usa a lista de partes/roupa do parceiro; sem ela, copia o seu personagem
    local fontes = {}
    if type(visual_parceiro.lista) == "table" and #visual_parceiro.lista > 0 then
        for _, v in ipairs(visual_parceiro.lista) do
            table.insert(fontes, { nome = v.n, caminho_malha = v.m, caminho_mat = v.t, orig = local_por_nome[v.n] and local_por_nome[v.n].orig })
        end
        etapa("usando a roupa do parceiro (" .. #fontes .. " partes)")
    else
        fontes = locais
        etapa("parceiro ainda nao mandou a roupa: usando a sua")
    end
    visual_parceiro.mudou = false

    local nomes = {}
    for _, mo in ipairs(fontes) do nomes[#nomes + 1] = mo.nome end
    etapa("partes: " .. table.concat(nomes, ", "))
    local malhas = fontes
    for i, mo in ipairs(malhas) do
        local g = criar_go("RE4CoopBR_parceiro_" .. i)
        if not g then
            etapa("parte " .. i .. ": GameObject.create retornou nil")
        else
            local okc, m = pcall(g.call, g, "createComponent(System.Type)", T_MESH)
            if not okc or not m then
                etapa("parte " .. i .. ": createComponent falhou: " .. tostring(m))
            else
                pcall(m.add_ref, m)
                local malha = mo.caminho_malha and carregar_holder(tipo_malha, mo.caminho_malha)
                local material = mo.caminho_mat and carregar_holder(tipo_mat, mo.caminho_mat)
                if mo.caminho_malha and not malha then etapa("parte " .. i .. ": nao carregou " .. mo.caminho_malha) end
                -- Reserva: a sua propria malha com o mesmo nome
                if not malha and mo.orig then
                    malha = tentar(mo.orig, { "getMesh", "get_Mesh" })
                    material = tentar(mo.orig, { "get_Material", "getMaterial" })
                end
                material = material or (mo.orig and tentar(mo.orig, { "get_Material", "getMaterial" }))
                local set_m = malha and chamar(m, { "setMesh", "set_Mesh" }, malha)
                local set_mat = material and chamar(m, { "set_Material", "setMaterial" }, material)
                local tr = componente(g, T_TRANSFORM)
                local juntas = tr and juntas_de(tr)
                etapa(string.format("parte %d (%s): malha=%s set=%s material=%s set=%s transform=%s juntas=%d", i, mo.nome,
                    tostring(malha ~= nil), tostring(set_m), tostring(material ~= nil), tostring(set_mat),
                    tostring(tr ~= nil), juntas and #juntas or -1))
                table.insert(clone.partes, { go = g, mesh = m, tr = tr, nome = mo.nome, holder = malha, mat = material })
            end
        end
    end
    clone.status = string.format("%d de %d partes criadas", #clone.partes, #malhas)
    etapa(clone.status)

    -- Armas do parceiro: mesma ordem da lista que ele envia (a posicao de cada uma vem no pacote)
    local armas_ok, armas_falha = 0, {}
    for i, a in ipairs(visual_parceiro.armas or {}) do
        local g = criar_go("RE4CoopBR_arma_" .. i)
        local okc, m = false, nil
        if g then okc, m = pcall(g.call, g, "createComponent(System.Type)", T_MESH) end
        local malha = okc and m and carregar_holder(tipo_malha, a.m)
        if malha then
            pcall(m.add_ref, m)
            chamar(m, { "setMesh", "set_Mesh" }, malha)
            local material = a.t and carregar_holder(tipo_mat, a.t)
            if material then chamar(m, { "set_Material", "setMaterial" }, material) end
            pcall(g.call, g, "set_DrawSelf", false)
            clone.armas[i] = { go = g, mesh = m, tr = componente(g, T_TRANSFORM), nome = a.n, holder = malha, mat = material }
            armas_ok = armas_ok + 1
        else
            armas_falha[#armas_falha + 1] = tostring(a.n)
            if g then chamar(g, { "destroy(via.GameObject)" }, g) end
        end
    end
    clone.status_armas = string.format("%d de %d armas criadas", armas_ok, #(visual_parceiro.armas or {}))
        .. (#armas_falha > 0 and (" (falharam: " .. table.concat(armas_falha, ", ") .. ")") or "")
    etapa(clone.status_armas)
    -- Modelos que o seu jogo nao tinha na memoria carregam em segundo plano; a malha
    -- e reaplicada algumas vezes para o clone pegar o modelo quando ele terminar de carregar.
    local t0 = agora()
    clone.recarregar = { t0 + 1, t0 + 3, t0 + 6, t0 + 12, t0 + 25 }
    registrar("Corpo do parceiro criado (" .. clone.status .. ", " .. clone.status_armas .. ").")
end

local function reaplicar_malha(obj)
    if obj.holder then chamar(obj.mesh, { "setMesh", "set_Mesh" }, obj.holder) end
    if obj.mat then chamar(obj.mesh, { "set_Material", "setMaterial" }, obj.mat) end
    obj.mascara = nil -- reaplicar a malha pode resetar as pecas ligadas
end

local function recarregar_malhas_pendentes()
    local fila = clone.recarregar
    if not fila or not fila[1] or agora() < fila[1] then return end
    table.remove(fila, 1)
    for _, p in ipairs(clone.partes) do pcall(reaplicar_malha, p) end
    for _, a in pairs(clone.armas) do pcall(reaplicar_malha, a) end
end

---------------------------------------------------------------------------
-- Disparos do parceiro: som + clarao na boca do cano do clone
---------------------------------------------------------------------------
local SIG_SOM_POSICIONADO = "trigger(System.UInt32, via.vec3, via.GameObject, System.UInt32, via.simplewwise.CallbackType, "
    .. "System.Action`1<soundlib.SoundManager.RequestInfo>, System.Action`1<soundlib.SoundManager.RequestInfo>, "
    .. "System.Action`1<soundlib.SoundManager.RequestInfo>, System.Action`1<soundlib.SoundManager.RequestInfo>)"
local T_LUZ = sdk.typeof("via.render.PointLight")
local clarao = { go = nil, luz = nil, tr = nil, apaga_em = 0 }
local claroes_tela = {}     -- brilhos desenhados na tela: { p = {x,y,z}, ate = t }

-- O som sai por um SoundGunContainer das SUAS armas, tocado na posicao do clone.
-- Com a mesma arma, usa o som dela; sem, usa o codigo de som que o parceiro mandou.
local function tocar_disparo(nome, id_parceiro, pos)
    if not TD_SOM_ARMA then return end
    local qualquer, mesma = nil, nil
    for _, a in ipairs(armas_do_personagem(go_jogador())) do
        local sc = tentar(a.go, { "getComponent(System.Type)" }, TD_SOM_ARMA:get_runtime_type())
        if sc then
            if a.nome == nome then mesma = sc break end
            qualquer = qualquer or sc
        end
    end
    local sc = mesma or qualquer
    if not sc then return end
    local id = id_parceiro
    if mesma or not id then
        local ok, v = pcall(sc.get_field, sc, "_TriggerShot")
        if ok and v then id = v end
    end
    if id then pcall(sc.call, sc, SIG_SOM_POSICIONADO, id, Vector3f.new(pos[1], pos[2], pos[3]), nil, 0, 0, nil, nil, nil, nil) end
end

local function acender_clarao(pos, arma)
    local f = math.max(0, math.min(100, cfg.clarao)) / 100
    if f <= 0 then return end
    if not (clarao.go and valido(clarao.go)) then
        clarao.go = criar_go("RE4CoopBR_clarao")
        if clarao.go then
            local ok, l = pcall(clarao.go.call, clarao.go, "createComponent(System.Type)", T_LUZ)
            if ok and l then
                pcall(l.add_ref, l)
                clarao.luz = l
                chamar(l, { "set_Color" }, Vector3f.new(1.0, 0.72, 0.38))
                chamar(l, { "set_ShadowEnable" }, false)
            end
            clarao.tr = componente(clarao.go, T_TRANSFORM)
        end
    end
    if clarao.luz and clarao.f ~= f then
        -- 30% (padrao) = ~500 de intensidade e ~2,5 m de alcance: ilumina so em volta da arma
        clarao.f = f
        chamar(clarao.luz, { "set_Radius" }, 1.0 + 5.0 * f)
        chamar(clarao.luz, { "set_Intensity" }, 1700.0 * f)
    end
    if clarao.tr then pcall(clarao.tr.call, clarao.tr, "set_Position", Vector3f.new(pos[1], pos[2], pos[3])) end
    if clarao.luz then chamar(clarao.luz, { "set_Enabled" }, true) end
    clarao.apaga_em = agora() + 0.04
    clarao.arma = arma
    table.insert(claroes_tela, { p = pos, ate = agora() + 0.035, f = f, arma = arma })
end

local boca_do_cano_ref = nil  -- preenchido abaixo (boca_do_cano e definida depois)

local function atualizar_clarao()
    if clarao.luz and clarao.apaga_em > 0 then
        if agora() >= clarao.apaga_em then
            clarao.apaga_em = 0
            chamar(clarao.luz, { "set_Enabled" }, false)
        elseif clarao.arma and clarao.tr and boca_do_cano_ref then
            -- Acompanha a arma enquanto o clarao esta aceso
            local p = boca_do_cano_ref(clarao.arma)
            if p then pcall(clarao.tr.call, clarao.tr, "set_Position", Vector3f.new(p[1], p[2], p[3])) end
        end
    end
end

-- Posicao da boca do cano no mundo: a junta "vfx_muzzle1" que o proprio jogo usa para o clarao
local function boca_do_cano(arma)
    if arma.cano == nil then
        arma.cano = tentar(arma.tr, { "getJointByName" }, "vfx_muzzle1") or false
    end
    local alvo = arma.cano or arma.tr
    local ok, p = pcall(alvo.call, alvo, "get_Position")
    if ok and p then return { p.x, p.y, p.z } end
end
boca_do_cano_ref = boca_do_cano

local function processar_disparos()
    if #tiros_pendentes == 0 then return end
    if not clone.visivel then tiros_pendentes = {} return end
    local resto = {}
    for _, tiro in ipairs(tiros_pendentes) do
        -- Espera a mesma suavizacao do corpo, para o tiro bater com a animacao do clone
        if agora() < tiro.t then
            resto[#resto + 1] = tiro
        else
            local arma = clone.armas[tiro.i]
            local info = visual_parceiro.armas and visual_parceiro.armas[tiro.i]
            local pos = arma and boca_do_cano(arma)
            if pos and info then
                pcall(tocar_disparo, info.n, info.s, pos)
                pcall(acender_clarao, pos, arma)
            end
        end
    end
    tiros_pendentes = resto
end

local function posicionar_armas(pose, cp, cr)
    if not pose or not pose.armas then return end
    cr = cr or { 0, 0, 0, 1 }
    pcall(recarregar_malhas_pendentes)
    pcall(atualizar_clarao)
    local tam = Sala.MAX_PECAS // 4
    for i, arma in pairs(clone.armas) do
        local d = pose.armas[i]
        if d and arma.tr then
            local visivel = d.v and clone.visivel
            if arma.visivel ~= visivel then
                -- Arma que acabou de aparecer: reaplica a malha caso o modelo tenha terminado de carregar agora
                if visivel then pcall(reaplicar_malha, arma) end
                arma.visivel = visivel
                pcall(arma.go.call, arma.go, "set_DrawSelf", visivel and true or false)
            end
            local mk = mascaras_parceiro and mascaras_parceiro:sub((i - 1) * tam + 1, i * tam)
            if visivel and mk and #mk == tam and mk ~= arma.mascara then
                arma.mascara = mk
                pcall(aplicar_mascara, arma.mesh, mk)
            end
            if visivel then
                local w = qrot(cr, d.p)
                pcall(arma.tr.call, arma.tr, "set_Position", Vector3f.new(cp[1] + w[1], cp[2] + w[2], cp[3] + w[3]))
                local q = qmul(cr, d.q)
                pcall(arma.tr.call, arma.tr, "set_Rotation", Vector4f.new(q[1], q[2], q[3], q[4]))
            end
        end
    end
end

local function mapear_juntas(parte)
    local el = juntas_de(parte.tr)
    if not el or #el == 0 or not ossos_parceiro.nomes then return nil end
    local por_nome = {}
    for _, j in ipairs(el) do
        local n = tentar(j, { "get_Name" })
        if n then por_nome[n] = j end
    end
    local mapa = {}
    for i, n in ipairs(ossos_parceiro.nomes) do
        local j = por_nome[n]
        if j then mapa[#mapa + 1] = { i, j } end
    end
    if #mapa == 0 then return nil end
    return mapa
end

local function mostrar_clone(sim)
    if clone.visivel == sim then return end
    clone.visivel = sim
    for _, p in ipairs(clone.partes) do pcall(p.go.call, p.go, "set_DrawSelf", sim) end
    if not sim then
        for _, a in pairs(clone.armas) do
            a.visivel = false
            pcall(a.go.call, a.go, "set_DrawSelf", false)
        end
    end
end

-- Formatos possiveis de quaternion aceitos por via.Joint.set_LocalRotation.
-- O mod testa cada um numa junta e fica com o primeiro que o jogo realmente aceita.
local FORMATOS_QUAT = {
    { "Vector4f(x,y,z,w)", function(q) return Vector4f.new(q[1], q[2], q[3], q[4]) end },
    { "Quaternion(w,x,y,z)", function(q) return Quaternion.new(q[4], q[1], q[2], q[3]) end },
    { "Quaternion(x,y,z,w)", function(q) return Quaternion.new(q[1], q[2], q[3], q[4]) end },
}
local teste_pose = { formato = nil, resultado = "ainda nao testado", persistiu = nil }
local quat_para = FORMATOS_QUAT[1][2]

local function ler_quat(j)
    local ok, r = pcall(j.call, j, "get_LocalRotation")
    if ok and r then return { r.x, r.y, r.z, r.w } end
end

local function parecido(a, b)
    if not a or not b then return false end
    return math.abs(a[1] * b[1] + a[2] * b[2] + a[3] * b[3] + a[4] * b[4]) > 0.995
end

local function testar_formato(mapa, pose)
    -- Junta de teste: a que tem a rotacao mais diferente da identidade
    local melhor, peso = nil, 0
    for _, par in ipairs(mapa) do
        local q = pose.q[par[1]]
        if q and (1 - math.abs(q[4])) > peso then melhor, peso = par, 1 - math.abs(q[4]) end
    end
    if not melhor then return end
    local alvo = pose.q[melhor[1]]
    local antes = ler_quat(melhor[2])
    local log_t = {}
    for _, f in ipairs(FORMATOS_QUAT) do
        local okq, valor = pcall(f[2], alvo)
        if okq and valor then
            pcall(melhor[2].call, melhor[2], "set_LocalRotation", valor)
            local lido = ler_quat(melhor[2])
            log_t[#log_t + 1] = f[1] .. "=" .. (parecido(lido, alvo) and "OK" or "nao")
            if parecido(lido, alvo) then
                quat_para = f[2]
                teste_pose.formato = f[1]
                teste_pose.junta = melhor[2]
                teste_pose.alvo = alvo
                break
            end
        else
            log_t[#log_t + 1] = f[1] .. "=indisponivel"
        end
    end
    teste_pose.resultado = table.concat(log_t, ", ") .. (antes and string.format(" | antes w=%.3f alvo w=%.3f", antes[4], alvo[4]) or "")
    if not teste_pose.formato then teste_pose.formato = "nenhum" end
end

local pose_para_render = nil

-- A pose chega relativa a raiz do parceiro; cp/cr = posicao e rotacao do clone agora
local function aplicar_pose(pose, cp, cr)
    if not pose or not cp then return end
    cr = cr or { 0, 0, 0, 1 }
    for _, parte in ipairs(clone.partes) do
        if parte.mapa then
            if not teste_pose.formato then pcall(testar_formato, parte.mapa, pose) end
            -- Ordem da lista = pais antes dos filhos, entao cada junta ja ve o pai no lugar certo
            for k, par in ipairs(parte.mapa) do
                local i, j = par[1], par[2]
                local q = pose.q[i]
                if q then
                    local alvo = qmul(cr, q)
                    pcall(j.call, j, "set_Rotation", quat_para(alvo))
                    -- Guarda uma junta do meio do corpo para o diagnostico conferir depois do frame
                    if k == 20 and parte == clone.partes[1] then teste_pose.junta_mundo, teste_pose.alvo_mundo = j, alvo end
                end
                local lp = pose.p[i]
                if lp then
                    local w = qrot(cr, lp)
                    pcall(j.call, j, "set_Position", Vector3f.new(cp[1] + w[1], cp[2] + w[2], cp[3] + w[3]))
                end
            end
        end
    end
end

local function posicionar_clone(p, r, pose)
    local pos = Vector3f.new(p[1], p[2], p[3])
    local rot = r and Vector4f.new(r[1], r[2], r[3], r[4])
    for _, parte in ipairs(clone.partes) do
        if parte.tr then
            pcall(parte.tr.call, parte.tr, "set_Position", pos)
            if rot then pcall(parte.tr.call, parte.tr, "set_Rotation", rot) end
            if pose then
                if (not parte.mapa or parte.assinatura ~= ossos_parceiro.assinatura) and agora() > (parte.prox_mapa or 0) then
                    parte.prox_mapa = agora() + 1
                    parte.mapa = mapear_juntas(parte)
                    if parte.mapa then parte.assinatura = ossos_parceiro.assinatura end
                end
            end
        end
    end
    aplicar_pose(pose, p, r)
    pcall(posicionar_armas, pose, p, r)
    pcall(processar_disparos)
    pose_para_render = { pose = pose, p = p, r = r }
end

-- Reaplica a pose logo antes de desenhar, caso o motor tenha resetado as juntas depois do LateUpdate
re.on_pre_application_entry("PrepareRendering", function()
    local pr = pose_para_render
    if pr and clone.visivel then pcall(aplicar_pose, pr.pose, pr.p, pr.r) end
end)

local function juntas_mapeadas()
    local total = 0
    for _, p in ipairs(clone.partes) do total = total + (p.mapa and #p.mapa or 0) end
    return total
end

local pos_render, rot_render = nil, nil

local contador_gancho = 0

re.on_pre_application_entry("LateUpdateBehavior", function()
    contador_gancho = contador_gancho + 1
    local oks, errs = pcall(Inimigos.seguir)
    if not oks then Inimigos.ultimo = "erro seguir: " .. tostring(errs) end
    -- v0.24: durante uma cena (minha ou dele) o boneco e o nome do parceiro somem
    local ativo = parceiro_online() and mesma_area() and not Sala.em_cena_agora() and not parceiro.cena
    if not ativo then
        pos_render = nil
        mostrar_clone(false)
        return
    end
    local p, r, pose = posicao_suave()
    pos_render, rot_render = p, r
    if not p then return end
    if cfg.avatar == 1 then
        if visual_parceiro.mudou and agora() >= clone.prox_tentativa then
            destruir_clone()
        end
        if not clone_valido() then
            -- Troca de area destroi os objetos criados: recria
            if agora() >= clone.prox_tentativa then
                clone.prox_tentativa = agora() + 3
                local ok, err = pcall(construir_clone)
                if not ok then
                    clone.status = "erro: " .. tostring(err)
                    log.error("[RE4 Co-op BR] criar corpo: " .. tostring(err))
                end
            end
            if not clone_valido() then return end
        end
        mostrar_clone(true)
        posicionar_clone(p, r, pose)
    else
        mostrar_clone(false)
        if cfg.avatar == 2 then
            local go = go_companheiro()
            if go then mover_go(go, p[1], p[2], p[3], r) end
        end
    end
end)

---------------------------------------------------------------------------
-- Loop principal
---------------------------------------------------------------------------
local prox_saida, prox_entrada, prox_status = 0, 0, 0
local longe_desde = nil
local teclas_antes = {}

local VK = { F5 = 0x74, F6 = 0x75, F7 = 0x76, F8 = 0x77 }

local function tecla_apertada(vk)
    local ok, down = pcall(reframework.is_key_down, reframework, vk)
    down = ok and down or false
    local antes = teclas_antes[vk]
    teclas_antes[vk] = down
    return down and not antes
end

local function anti_preso()
    if not cfg.anti_preso or not eu_sigo() or not parceiro_online() or not local_.ok then longe_desde = nil return end
    if not mesma_area() then longe_desde = nil return end
    if local_.hp and local_.hp <= 0 then return end
    local d = distancia_parceiro()
    if d and d > cfg.dist_max then
        longe_desde = longe_desde or agora()
        if agora() - longe_desde > cfg.tempo_max and agora() - ultimo_teleporte > 5 then
            longe_desde = nil
            ir_ate_parceiro(string.format("Voce ficou para tras (%.0f m) e foi levado ate o parceiro.", d))
        end
    else
        longe_desde = nil
    end
end

local function puxar_parceiro()
    if not parceiro_online() then registrar("Parceiro nao esta conectado.") return end
    enviar_evento("puxar")
    registrar("Pedido enviado: o parceiro vai ser trazido ate voce.")
end

---------------------------------------------------------------------------
-- Desenho: nome flutuante, marcador da porta, HUD
---------------------------------------------------------------------------
local COR = {
    branco = 0xFFFFFFFF, sombra = 0xC0000000, amarelo = 0xFF4FD8FF, verde = 0xFF6BDB6B,
    vermelho = 0xFF5A5AF0, cinza = 0xFFB0B0B0, azul = 0xFFFFC266, fundo = 0xB0141414,
}

local function texto_sombra(t, x, y, cor)
    draw.text(t, x + 1, y + 1, COR.sombra)
    draw.text(t, x, y, cor)
end

local function desenhar_marcador(p, rotulo, cor, altura)
    local ok, tela = pcall(draw.world_to_screen, Vector3f.new(p[1], p[2] + (altura or 1.9), p[3]))
    if not ok or not tela then return end
    local d = ""
    if local_.ok then
        local dx, dy, dz = p[1] - local_.x, p[2] - local_.y, p[3] - local_.z
        d = string.format(" (%.0f m)", math.sqrt(dx * dx + dy * dy + dz * dz))
    end
    local t = rotulo .. d
    texto_sombra(t, tela.x - #t * 3.5, tela.y, cor)
end

local function desenhar_mundo()
    if cfg.mostrar_nome and pos_render and parceiro then
        local nome = parceiro.nome or "Parceiro"
        if parceiro.hp and parceiro.hpmax and parceiro.hpmax > 0 then
            nome = string.format("%s  %d%%", nome, math.floor(parceiro.hp / parceiro.hpmax * 100 + 0.5))
        end
        if parceiro.pau then nome = nome .. "  (PAUSADO)" end
        desenhar_marcador(pos_render, nome, COR.amarelo)
    end
    if porta_parceiro and local_.est == porta_parceiro.est then
        desenhar_marcador(porta_parceiro.p, "Porta usada pelo parceiro", COR.azul, 1.2)
    end
    -- Clarao dos disparos do parceiro (brilho na tela, junto com a luz no cenario)
    local vivos = {}
    for _, c in ipairs(claroes_tela) do
        if agora() < c.ate then
            vivos[#vivos + 1] = c
            if c.arma and boca_do_cano_ref then
                local okp, p = pcall(boca_do_cano_ref, c.arma)
                if okp and p then c.p = p end
            end
            local ok, tela = pcall(draw.world_to_screen, Vector3f.new(c.p[1], c.p[2], c.p[3]))
            if ok and tela then
                local d = 5
                if local_.ok then
                    d = math.max(1, math.sqrt((c.p[1] - local_.x) ^ 2 + (c.p[2] - local_.y) ^ 2 + (c.p[3] - local_.z) ^ 2))
                end
                -- Faisca pequena e translucida (cor ABGR); some em ~35 ms
                local f = c.f or 0.3
                local raio = math.max(1.5, 14 / d) * (0.5 + f)
                local alfa = math.floor(40 + 120 * f)
                pcall(draw.filled_circle, tela.x, tela.y, raio, (alfa << 24) | 0x40A8FF, 12)
                pcall(draw.filled_circle, tela.x, tela.y, raio * 0.4, (math.min(255, alfa + 60) << 24) | 0xC8F0FF, 8)
            end
        end
    end
    claroes_tela = vivos
end

local function desenhar_hud()
    if cfg.modo == "parado" then return end
    local x, y = 18, 18
    local linha, cor, erro
    if not ponte_viva() then
        erro = true
        linha, cor = cfg.rede == "steam" and "Co-op: plugin de rede nao carregou (falta re4coopbr_rede.dll)"
            or "Co-op: rede desligada (instale o plugin ou abra Iniciar-Ponte.bat)", COR.vermelho
    elseif parceiro_online() and parceiro.v ~= VERSAO then
        linha = string.format("Co-op: versoes diferentes! Voce v%s, parceiro v%s. Atualizem os dois.", VERSAO, tostring(parceiro.v))
        cor, erro = COR.vermelho, true
    elseif parceiro_online() then
        local d = distancia_parceiro()
        linha = string.format("Co-op: %s  |  %d ms%s", parceiro.nome or "Parceiro", status_ponte.ping or 0,
            (d and mesma_area()) and string.format("  |  %.0f m", d) or (mesma_area() and "" or "  |  outra area"))
        cor = COR.verde
    else
        linha, cor = cfg.modo == "host" and "Co-op: aguardando parceiro..." or "Co-op: conectando...", COR.amarelo
    end
    -- v0.23: a barra normal so aparece se o jogador ligar (F8 > Opcoes); erros aparecem sempre
    if not erro and not cfg.mostrar_hud then
        y = y - 28
    else
        draw.filled_rect(x - 8, y - 5, #linha * 7 + 16, 24, COR.fundo)
        texto_sombra(linha, x, y, cor)
    end
    -- v0.24: com o jogo pausado (maquina de escrever, menu) o aviso espera: os 6 s contam depois de voltar
    if aviso_hud.texto and Sala.pausado and aviso_hud.ate > agora() - 1 then aviso_hud.ate = math.max(aviso_hud.ate, agora() + 6) end
    if aviso_hud.texto and agora() < aviso_hud.ate then
        draw.filled_rect(x - 8, y + 23, #aviso_hud.texto * 7 + 16, 24, COR.fundo)
        texto_sombra(aviso_hud.texto, x, y + 28, COR.branco)
    end
end

---------------------------------------------------------------------------
-- Painel (F8)
---------------------------------------------------------------------------
-- O Lua aceita no maximo 200 variaveis locais no nivel principal do arquivo: o painel fica
-- num bloco proprio e so linha_status/desenhar_painel ficam visiveis para o resto do mod.
local linha_status, desenhar_painel, desenhar_inicio
do
local QUEM_SEGUE = { "Automatico: quem ficou para tras", "Convidado segue o anfitriao", "Anfitriao segue o convidado", "Ninguem (so manual)" }
local texto_chat = ""

local function titulo(t) imgui.text_colored(t, COR.amarelo) end

function linha_status()
    local s = type(status_ponte.steam) == "table" and status_ponte.steam or {}
    if cfg.modo == "parado" then
        imgui.text_colored("Desconectado", COR.cinza)
    elseif not ponte_viva() then
        if cfg.rede == "steam" then
            imgui.text_colored("Plugin de rede NAO carregou.", COR.vermelho)
            imgui.text("Falta reframework\\plugins\\re4coopbr_rede.dll (extraia o pacote de novo e reinicie o jogo).")
        else
            imgui.text_colored("Rede NAO esta rodando.", COR.vermelho)
            imgui.text("Instale o plugin (reframework\\plugins\\re4coopbr_rede.dll) ou abra RE4CoopBR\\Iniciar-Ponte.bat.")
        end
    elseif cfg.rede == "steam" and not s.ok then
        imgui.text_colored("Aguardando a Steam...", COR.amarelo)
    elseif parceiro_online() then
        imgui.text_colored(string.format("Conectado com %s  |  ping %d ms", parceiro.nome or "parceiro",
            status_ponte.ping or 0), COR.verde)
        if parceiro.v ~= VERSAO then
            imgui.text_colored(string.format("ATENCAO: voce esta na v%s e o parceiro na v%s. Atualizem os dois.",
                VERSAO, tostring(parceiro.v)), COR.vermelho)
        end
    elseif cfg.modo == "host" then
        if cfg.rede == "steam" and not s.lobby then imgui.text_colored("Criando a sala na Steam...", COR.amarelo)
        elseif cfg.rede == "steam" then imgui.text_colored("Sala aberta na Steam. Convide o parceiro.", COR.amarelo)
        else imgui.text_colored("Sala aberta, aguardando o parceiro entrar...", COR.amarelo) end
    elseif cfg.rede == "steam" then
        imgui.text_colored(s.lobby and "Na sala do amigo, conectando..." or "Procurando a sala do amigo...", COR.amarelo)
    else
        imgui.text_colored("Conectando em " .. cfg.ip .. ":" .. cfg.porta .. " ...", COR.amarelo)
    end
    if status_ponte.erro and status_ponte.erro ~= "" then imgui.text_colored("Erro: " .. status_ponte.erro, COR.vermelho) end
end

-- Sala Steam + janela "Jogar junto": dentro de uma funcao (os locais dela nao contam no limite de 200)
local aba_conexao = (function()
-- Sala Steam: usada no painel F8 e na janela "Jogar junto" da tela inicial
local function steam() return type(status_ponte.steam) == "table" and status_ponte.steam or {} end
-- "con" muda a cada clique de conexao: o plugin reabre mesmo que o resto do pedido seja igual
local function clique_conexao() Sala.con = tostring(os.time()) end

local function criar_sala_steam()
    cfg.rede, cfg.modo = "steam", "host"; clique_conexao(); salvar_cfg(); enviar_ctl()
end
local function entrar_sala_steam(lobby)
    cfg.rede, cfg.modo, cfg.lobby = "steam", "entrar", lobby; clique_conexao(); salvar_cfg(); enviar_ctl()
end
local function sair_sala()
    cfg.modo = "parado"; Sala.pronto = false; salvar_cfg(); enviar_ctl()
    parceiro = nil; amostras = {}
end

-- Da para o anfitriao iniciar? (parceiro na sala, mesma versao, PRONTO)
local function membros_ok(s)
    local m = type(s.membros) == "table" and s.membros or {}
    if #m < 2 then return false, "Esperando o parceiro entrar na sala." end
    for _, x in ipairs(m) do
        if not x.eu then
            if x.v ~= VERSAO then
                return false, string.format("Versoes diferentes: voce v%s, %s v%s. Atualizem os dois.", VERSAO, tostring(x.nome), tostring(x.v))
            end
            if x.pronto ~= "1" then return false, tostring(x.nome) .. " ainda nao marcou PRONTO." end
        end
    end
    return true
end

local INICIO_TIPOS = { "Novo jogo", "Continuar (save co-op)" }

local function ui_sala_steam()
    local s = steam()
    if not ponte_viva() or not s.ok then linha_status() return end
    imgui.text("Voce na Steam: " .. tostring(s.nome))
    if status_ponte.erro and status_ponte.erro ~= "" then imgui.text_colored(status_ponte.erro, COR.vermelho) end

    if not s.lobby or cfg.modo == "parado" then
        if s.entrando then imgui.text_colored("Entrando na sala...", COR.amarelo) end
        titulo("Criar sala (voce e o anfitriao)")
        if imgui.button("Criar sala e convidar") then criar_sala_steam(); Sala.convidar_apos = true end
        imgui.same_line()
        if imgui.button("So criar a sala") then criar_sala_steam() end
        local privada = cfg.sala == "privada"
        local c
        c, privada = imgui.checkbox("Sala privada (so entra quem voce convidar)", privada)
        if c then cfg.sala = privada and "privada" or "amigos"; salvar_cfg(); enviar_ctl() end
        imgui.spacing()
        titulo("Entrar na sala de um amigo")
        local alguem = false
        for _, a in ipairs(type(s.amigos) == "table" and s.amigos or {}) do
            if type(a.lobby) == "string" and a.lobby ~= "" then
                alguem = true
                if imgui.button("Entrar##" .. tostring(a.id)) then entrar_sala_steam(a.lobby) end
                imgui.same_line()
                imgui.text(tostring(a.nome) .. " esta com a sala aberta")
            end
        end
        if not alguem then
            if type(s.reconectar) == "string" and s.reconectar ~= "" then
                if imgui.button("Voltar para a sala do ultimo anfitriao") then entrar_sala_steam(s.reconectar) end
            end
            imgui.text_colored("Nenhum amigo com sala aberta agora. Aceite o convite da Steam\n(ou clique no amigo na Steam > Entrar no jogo).", COR.cinza)
        end
        return
    end

    -- Dentro da sala
    titulo(s.sou_dono and "Sua sala (voce e o anfitriao)" or "Sala do amigo (voce e o convidado)")
    for _, m in ipairs(type(s.membros) == "table" and s.membros or {}) do
        local estado = m.dono and "anfitriao" or (m.pronto == "1" and "PRONTO" or "ainda nao esta pronto")
        imgui.text_colored(string.format("  %s%s  -  %s  (v%s)", tostring(m.nome), m.eu and " (voce)" or "", estado, tostring(m.v)),
            (m.dono or m.pronto == "1") and COR.verde or COR.amarelo)
        imgui.text_colored("      save co-op: " .. ((m.save and m.save ~= "") and m.save or "nenhum ainda"), COR.cinza)
    end
    imgui.spacing()
    if s.sou_dono then
        if imgui.button("Convidar amigo pela Steam") then Sala.convidar = os.time(); enviar_ctl() end
        imgui.same_line()
        imgui.text_colored("(abre a lista de amigos da Steam)", COR.cinza)
        local idx = Sala.inicio_tipo == "continuar" and 2 or 1
        local c
        c, idx = imgui.combo("Comecar com", idx, INICIO_TIPOS)
        if c then Sala.inicio_tipo = idx == 2 and "continuar" or "novo"; enviar_ctl() end
        if Sala.inicio_tipo == "novo" then
            local nomes, atual = {}, 2
            for i, d in ipairs(Sala.DIFS or {}) do nomes[i] = d[2]; if d[1] == (Sala.inicio_dif or 20) then atual = i end end
            local c2
            c2, atual = imgui.combo("Dificuldade", atual, nomes)
            if c2 and Sala.DIFS[atual] then Sala.inicio_dif = Sala.DIFS[atual][1]; enviar_ctl() end
        else
            imgui.text_colored("Os dois carregam o save co-op (slot 20). Ele e gravado sempre que um de voces salva.", COR.cinza)
        end
        local pode, motivo = membros_ok(s)
        if pode and Sala.inicio_tipo == "continuar" then
            for _, x in ipairs(s.membros or {}) do
                if not x.save or x.save == "" then pode, motivo = false, tostring(x.nome) .. " ainda nao tem save co-op: comecem com Novo jogo." end
            end
        end
        if pode then
            if imgui.button(">>>  INICIAR PARTIDA  <<<") then Sala.inicio = tostring(os.time()); enviar_ctl() end
        else
            imgui.text_colored(motivo, COR.amarelo)
        end
    else
        local c
        c, Sala.pronto = imgui.checkbox("Estou PRONTO", Sala.pronto)
        if c then enviar_ctl() end
        imgui.text_colored(Sala.pronto and "Aguardando o anfitriao iniciar: a partida comeca sozinha." or "Marque PRONTO quando estiver na tela inicial.", COR.cinza)
    end
    if Sala.iniciada and agora() < Sala.iniciada.ate then
        imgui.spacing()
        imgui.text_colored(Sala.iniciada.tipo == "continuar" and "PARTIDA INICIADA! Carregando o save co-op..."
            or "PARTIDA INICIADA! Comecando o jogo novo...", COR.verde)
    end
    imgui.spacing()
    if local_.ok and imgui.button("Salvar ponto co-op agora (nos dois jogos)") then
        if parceiro_online() then enviar_evento("salvar_coop") end
        Sala.salvar_apos = agora()
    end
    if imgui.button("Sair da sala") then sair_sala() end
end

local function aba_conexao()
    linha_status()
    imgui.separator()
    local c
    c, cfg.nome = imgui.input_text("Seu nome", cfg.nome)
    if c then salvar_cfg(); enviar_ctl() end
    local idx = cfg.rede == "ip" and 2 or 1
    c, idx = imgui.combo("Conexao", idx, { "Steam (convite, sem IP)", "IP direto (como antes)" })
    if c then
        cfg.rede = idx == 2 and "ip" or "steam"
        cfg.modo = "parado"; salvar_cfg(); enviar_ctl()
        parceiro = nil; amostras = {}
    end
    -- v0.23: idioma (o nome da opcao fica nos dois idiomas para ninguem se perder)
    local idiomas = { "auto", "pt", "en" }
    local li = 1
    for i, v in ipairs(idiomas) do if v == cfg.idioma then li = i end end
    c, li = imgui.combo("Idioma / Language", li, { "Automatico (idioma do jogo)", "Português (Brasil)", "English" })
    if c then cfg.idioma = idiomas[li]; salvar_cfg(); I18N.carregar() end
    imgui.spacing()
    if cfg.rede == "steam" then
        ui_sala_steam()
        imgui.separator()
        c, cfg.janela_inicio = imgui.checkbox("Mostrar a janela 'Jogar junto' na tela inicial", cfg.janela_inicio)
        if c then salvar_cfg(); Sala.esconder = false end
        c, cfg.menu_jogo = imgui.checkbox("Opcao 'JOGAR JUNTO' no menu principal do jogo (vale ao reabrir o menu)", cfg.menu_jogo)
        if c then salvar_cfg() end
        return
    end

    titulo("Criar sala (anfitriao)")
    imgui.text("Quem cria a sala passa o IP abaixo para o parceiro.")
    if type(status_ponte.ips) == "table" and #status_ponte.ips > 0 then
        for _, ip in ipairs(status_ponte.ips) do imgui.text("  IP: " .. tostring(ip)) end
    end
    if imgui.button(cfg.modo == "host" and "Reabrir sala" or "Criar sala") then
        cfg.modo = "host"; clique_conexao(); salvar_cfg(); enviar_ctl()
    end
    imgui.spacing()

    titulo("Entrar na sala do parceiro")
    c, cfg.ip = imgui.input_text("IP do anfitriao", cfg.ip)
    if c then salvar_cfg() end
    if imgui.button(cfg.modo == "entrar" and "Reconectar" or "Entrar") then
        if cfg.ip == "" then registrar("Digite o IP do anfitriao.") else
            cfg.modo = "entrar"; clique_conexao(); salvar_cfg(); enviar_ctl()
        end
    end
    imgui.spacing()
    if cfg.modo ~= "parado" and imgui.button("Desconectar") then sair_sala() end
    imgui.separator()
    local porta = cfg.porta
    c, porta = imgui.slider_int("Porta UDP", porta, 1024, 65000)
    if c then cfg.porta = porta; salvar_cfg() end
    imgui.text_colored("Mesma casa: use o IP 192.168.x.x. Pela internet: Radmin VPN (IP 26.x.x.x).", COR.cinza)
end

-- Janela "Jogar junto": aparece na tela inicial (fora da partida)
function desenhar_inicio()
    if not cfg.janela_inicio or Sala.esconder or cfg.rede ~= "steam" then return end
    if local_.ok or Sala.no_jogo then return end
    -- Com a opcao "JOGAR JUNTO" no menu do jogo, a aba propria substitui esta janela
    if cfg.menu_jogo then return end
    pcall(imgui.set_next_window_size, Vector2f.new(480, 360), 4)
    -- Primeira vez: no lado direito da tela (o menu do REFramework fica na esquerda)
    local okd, tela = pcall(imgui.get_display_size)
    local largura = okd and tela and tela.x or 1920
    pcall(imgui.set_next_window_pos, Vector2f.new(largura - 540, 120), 4)
    local aberto = imgui.begin_window("RE4 Co-op BR  v" .. VERSAO .. "  -  Jogar junto###re4coopbr_inicio", true, 0)
    imgui.text_colored("Um cria a sala e convida; o outro entra e marca PRONTO.", COR.cinza)
    imgui.separator()
    local ok, err = pcall(ui_sala_steam)
    if not ok then imgui.text_colored(tostring(err), COR.vermelho) end
    imgui.end_window()
    if aberto == false then Sala.esconder = true; Sala.janela_aberta = false end
end

-- Partida: saber quando entra no jogo e quando volta ao titulo
pcall(function()
    local cm = sdk.find_type_definition("chainsaw.CampaignManager")
    local m = cm and cm:get_method("onStartInGame")
    if m then sdk.hook(m, function() Sala.no_jogo = true end, nil) end
    local gm = sdk.find_type_definition("chainsaw.GuiManager")
    local m2 = gm and gm:get_method("onGameStateTitle")
    if m2 then sdk.hook(m2, function() Sala.no_jogo = false end, nil) end
end)

function Sala.tick()
    local s = steam()
    if Sala.tick_save then pcall(Sala.tick_save) end
    -- Recriar o corpo do parceiro quando alguem acabou de carregar (o corpo podia ficar bugado)
    local par_carregado = parceiro_online() and parceiro.p ~= nil
    if (local_.ok and not Sala.ok_antes) or (par_carregado and not Sala.par_antes) then
        Sala.recriar_em = agora() + 4
    end
    Sala.ok_antes, Sala.par_antes = local_.ok, par_carregado
    if Sala.recriar_em and agora() >= Sala.recriar_em then
        Sala.recriar_em = nil
        if cfg.avatar == 1 and par_carregado and local_.ok then
            clone.prox_tentativa = 0
            pcall(destruir_clone)
        end
    end
    -- "Criar sala e convidar": abre o convite assim que a sala existir
    if Sala.convidar_apos and s.lobby and s.sou_dono then
        Sala.convidar_apos = false; Sala.convidar = os.time(); enviar_ctl()
    end
    -- Sem o aviso de "voltou ao titulo": 30 s sem personagem = fora da partida
    if local_.ok then Sala.fora_desde = nil
    elseif Sala.no_jogo then
        Sala.fora_desde = Sala.fora_desde or agora()
        if agora() - Sala.fora_desde > 30 then Sala.no_jogo = false end
    end
    -- Comecaram juntos: quando os dois chegam na partida, o convidado vai ate o anfitriao
    if Sala.iniciada and not Sala.juntou and local_.ok and parceiro_online() and parceiro.p then
        Sala.juntou = true
        if papel() == "convidado" and local_.cap and local_.cap == parceiro.cap then
            ir_ate_parceiro("Voces comecaram juntos! Bom jogo.")
        else
            registrar("Os dois estao na partida. Bom jogo!")
        end
    end
end

-- Aviso grande enquanto um espera o outro carregar
function Sala.desenhar_aviso()
    local ini = Sala.iniciada
    if not ini or Sala.juntou or agora() > ini.ate then return end
    local txt
    if local_.ok then
        txt = "Co-op: aguardando " .. ((parceiro and parceiro.nome) or "o parceiro") .. " entrar na partida..."
    elseif not Sala.no_jogo then
        txt = (Sala.no_menu and not Sala.no_menu()) and "Co-op: o anfitriao iniciou a partida - volte ao menu principal para entrar junto"
            or "Co-op: PARTIDA INICIADA - carregando..."
    end
    if not txt then return end
    draw.filled_rect(30, 70, #txt * 7 + 24, 30, COR.fundo)
    texto_sombra(txt, 42, 77, COR.verde)
end

-- Save co-op (slot 20) e inicio automatico da partida (v0.21)
-- Como o jogo faz (visto com escutas no jogo):
--   salvar:     SaveDataManager.requestStartSaveGameDataFlow(slot, ChainsawGameSaveRequestArgs)
--   carregar:   setPlayLoadData(true, slot) + requestLoadGameData(slot) -> GameStateIngameSetup{Difficulty}
--   novo jogo:  setPlayLoadData(false, 0) -> GameStateIngameSetup{Difficulty, IsDifficultyChanged=true}
Sala.SLOT_COOP = 20
local DIFS = { { 10, "Assistido" }, { 20, "Padrão" }, { 30, "Intenso" }, { 40, "Profissional" } }
local function sdm() return sdk.get_managed_singleton("share.SaveDataManager") end
local function mmm() return sdk.get_managed_singleton("share.MainModeManager") end
local function estado_jogo()
    local ok, t = pcall(function() return mmm():call("get_CurrStateType"):call("get_FullName") end)
    return ok and tostring(t) or "?"
end
local function no_menu()
    local e = estado_jogo()
    return e == "chainsaw.GameStateTitle" or e == "chainsaw.GameStateMainMenu"
end
local function existe_save_coop()
    local s = sdm()
    local ok, r = pcall(s.call, s, "isExistSaveData(System.Int32)", Sala.SLOT_COOP)
    return ok and r == true
end

-- save_coop.json (dificuldade/hora do ultimo save co-op): lido uma vez e guardado (ler arquivo que nao existe enche o log)
local function info_save_json()
    if Sala.save_json == nil then
        local ok, t = pcall(json.load_file, PASTA .. "save_coop.json")
        Sala.save_json = (ok and type(t) == "table") and t or false
    end
    return Sala.save_json or nil
end

-- Resumo do save co-op para mostrar na sala ("PADRAO / CAPITULO 3 - 23/11 20:44")
local function ler_info_save()
    if not existe_save_coop() then return "" end
    local ok, txt = pcall(function()
        local lista = sdm():call("getSaveFileDetailList(System.Int32, System.Int32)", 0, Sala.SLOT_COOP + 1)
        local d = lista:call("get_Item", Sala.SLOT_COOP):get_field("<SaveFileDetail>k__BackingField")
        local sub = tostring(d:call("get_SubTitle"))
        return (sub:gsub("^[^/]*/%s*", ""))
    end)
    local info = info_save_json()
    local quando = info and info.quando or ""
    return (ok and txt or "save co-op") .. (quando ~= "" and (" - " .. quando) or "")
end

function Sala.salvar_coop()
    if not local_.ok then return false end
    local s = sdm()
    if not s then return false end
    local okb, ocupado = pcall(s.call, s, "get_IsBusy")
    if okb and ocupado then Sala.salvar_apos = agora() + 1.5 return false end
    local args = sdk.create_instance("chainsaw.ChainsawGameSaveRequestArgs")
    if not args then return false end
    pcall(args.call, args, ".ctor")
    Sala.salvando_coop = true
    local ok = pcall(s.call, s, "requestStartSaveGameDataFlow(System.Int32, share.GameSaveRequestArgs)", Sala.SLOT_COOP, args)
    Sala.salvando_coop = false
    if ok then
        local cm = sdk.get_managed_singleton("chainsaw.CampaignManager")
        local okd, dif = pcall(cm.call, cm, "get_CurrentDifficulty")
        Sala.save_json = { dif = okd and tonumber(dif) or 20, cap = local_.cap, quando = os.date("%d/%m %H:%M") }
        pcall(json.dump_file, PASTA .. "save_coop.json", Sala.save_json)
        Sala.info_save_em = agora() + 3
        registrar("Ponto de save co-op salvo (slot 20).")
    end
    return ok
end

-- Qualquer save de um dos dois (maquina de escrever ou automatico) grava o slot co-op nos dois jogos
pcall(function()
    local m = sdk.find_type_definition("share.SaveDataManager"):get_method("requestStartSaveGameDataFlow")
    sdk.hook(m, function(args)
        local slot = sdk.to_int64(args[3]) & 0xFFFFFFFF
        if Sala.salvando_coop or cfg.modo == "parado" or not parceiro_online() then return end
        if slot ~= Sala.SLOT_COOP then
            Sala.salvar_apos = agora() + 2          -- depois que o save normal terminar
            enviar_evento("salvar_coop")
        else
            -- v0.26.2: o jogador salvou direto no espaco 20 (o do co-op): o parceiro salva tambem e aparece o aviso
            enviar_evento("salvar_coop")
            registrar("Ponto de save co-op salvo (slot 20).")
        end
    end, nil)
end)

-- Comeca a partida (novo jogo ou save co-op) sem passar pelo menu do jogo
function Sala.iniciar_partida(tipo, dif)
    local s, m = sdm(), mmm()
    if not s or not m then return end
    local arg = sdk.create_instance("chainsaw.GameStateIngameSetup.Argument")
    if not arg then registrar("Nao consegui iniciar a partida (tipo nao encontrado).") return end
    pcall(arg.call, arg, ".ctor")
    pcall(arg.add_ref, arg)
    if tipo == "continuar" then
        if not existe_save_coop() then
            registrar("Voce ainda nao tem save co-op (slot 20). Escolham Novo jogo, ou carreguem o save manualmente.")
            return
        end
        local info = info_save_json()
        dif = info and tonumber(info.dif) or dif
        local la = sdk.create_instance("share.GameLoadRequestArgs")
        pcall(la.call, la, ".ctor")
        s:call("setPlayLoadData(System.Boolean, System.Int32)", true, Sala.SLOT_COOP)
        s:call("requestLoadGameData(System.Int32, share.GameLoadRequestArgs)", Sala.SLOT_COOP, la)
        arg:set_field("Difficulty", dif or 20)
        arg:set_field("IsDifficultyChanged", false)
        arg:set_field("StartFromGameIntent", false)
        Sala.carregando = { arg = arg, ate = agora() + 30 }
        registrar("Carregando o save co-op...")
    else
        -- v0.23: igual ao menu do jogo (visto com escutas): prepara a campanha principal antes.
        -- Sem isto o jogo entra "em jogo" sem capitulo nem jogador (tela cinza).
        -- 1 = chainsaw.CampaignInitialSettingKey.Campaign1001_Master (historia principal do inicio)
        local cm = sdk.get_managed_singleton("chainsaw.CampaignManager")
        if not cm or not pcall(cm.call, cm, "initializeForStartingCampaign(chainsaw.CampaignInitialSettingKey)", 1) then
            registrar("Nao consegui iniciar a partida (tipo nao encontrado).")
            return
        end
        s:call("setPlayLoadData(System.Boolean, System.Int32)", false, 0)
        arg:set_field("Difficulty", dif or 20)
        arg:set_field("IsDifficultyChanged", true)
        arg:set_field("StartFromGameIntent", false)
        m:call("requestToChangeGameState(System.Type, share.GameStateArgument)", sdk.typeof("chainsaw.GameStateIngameSetup"), arg)
        registrar("Comecando um jogo novo...")
    end
end

-- Chamado no Sala.tick: termina o carregamento, salva quando pedido, dispara o inicio
-- So mexe no sistema de save depois que o jogo terminou de iniciar (no comeco, consultar os saves TRAVA o jogo)
local ESTADOS_SEGUROS = { ["chainsaw.GameStateTitle"] = true, ["chainsaw.GameStateMainMenu"] = true, ["chainsaw.GameStateInGame"] = true }
local function jogo_pronto()
    if not ESTADOS_SEGUROS[estado_jogo()] then Sala.seguro_desde = nil return false end
    Sala.seguro_desde = Sala.seguro_desde or agora()
    return agora() - Sala.seguro_desde > 5
end

function Sala.tick_save()
    if not jogo_pronto() then return end
    -- Carregamento do save: espera o arquivo ser lido e entra na partida
    local c = Sala.carregando
    if c then
        local s = sdm()
        local okb, ocupado = pcall(s.call, s, "get_IsBusy")
        if okb and not ocupado then
            Sala.carregando = nil
            mmm():call("requestToChangeGameState(System.Type, share.GameStateArgument)", sdk.typeof("chainsaw.GameStateIngameSetup"), c.arg)
        elseif agora() > c.ate then
            Sala.carregando = nil
            registrar("O save co-op demorou demais para carregar. Tente de novo.")
        end
    end
    if Sala.salvar_apos and agora() >= Sala.salvar_apos then
        Sala.salvar_apos = nil
        pcall(Sala.salvar_coop)
    end
    -- O anfitriao apertou INICIAR: se estiver no menu, comeca sozinho
    local a = Sala.auto
    if a then
        if agora() > a.ate then
            Sala.auto = nil
        elseif no_menu() and not Sala.carregando then
            Sala.auto = nil
            pcall(Sala.iniciar_partida, a.tipo, a.dif)
        end
    end
    -- Resumo do save co-op (vai para a sala)
    if not Sala.info_save_em or agora() >= Sala.info_save_em then
        Sala.info_save_em = agora() + 10
        local ok, txt = pcall(ler_info_save)
        txt = ok and txt or ""
        if txt ~= Sala.info_save then Sala.info_save = txt; enviar_ctl() end
    end
end

Sala.DIFS = DIFS
Sala.no_menu = no_menu

-- "JOGAR JUNTO" dentro do menu principal do jogo (v0.21)
-- O menu tem 10 opcoes prontas e mostra so as disponiveis (isAvliableAction). A opcao "Invalid" (-1)
-- vem logo depois de Extra/Mercenarios: liberada, cai abaixo de HISTORIA PRINCIPAL. Confirmar -1 nao faz
-- nada no jogo; o mod escreve o texto nela a cada quadro e abre a tela da sala quando ela e confirmada.
Sala.ACAO_COOP = -1
local function filho(c, nome)
    local ch = c:call("get_Child")
    while ch do
        if ch:call("get_Name") == nome then return ch end
        ch = ch:call("get_Next")
    end
end
local function escrever_texto(mi)
    local al = mi:get_field("ActualMenuList")
    local sl = mi:get_field("ModeSelectList")
    for i = 0, al:call("get_Count") - 1 do
        if al:call("get_Item", i):get_field("_ActionType") == Sala.ACAO_COOP then
            local it = filho(sl, i == 0 and "si_content" or ("item" .. i))
            local t = it and filho(it, "m_content")
            if t then t:call("set_Message(System.String)", I18N.T("JOGAR JUNTO")) end
            return
        end
    end
end
pcall(function()
    local td = sdk.find_type_definition("chainsaw.MainMenuGuiBehavior")
    sdk.hook(td:get_method("isAvliableAction"), function(args)
        thread.get_hook_storage()["acao"] = sdk.to_int64(args[3]) & 0xFFFFFFFF
    end, function(ret)
        if cfg.menu_jogo and thread.get_hook_storage()["acao"] == 0xFFFFFFFF then return sdk.to_ptr(1) end
        return ret
    end)
    -- v0.24: com a aba aberta, mouse e setas nao chegam ao menu do jogo escondido atras dela
    local function bloquear(args)
        local Aba = Sala.Aba
        if not (cfg.menu_jogo and Aba and Aba.aberta) then return end
        local ok, eh = pcall(function()
            return sdk.to_managed_object(args[2]):get_type_definition():get_full_name() == "chainsaw.MainMenuGuiBehavior"
        end)
        if ok and eh then return sdk.PreHookResult.SKIP_ORIGINAL end
    end
    local base = sdk.find_type_definition("chainsaw.ChainsawGuiBehaviorBase")
    for _, n in ipairs({ "onMouseClick", "onMouseEnter", "onMouseDown", "onMouseRepeat", "onMouseBack",
        "onMouseWheelUp", "onMouseWheelDown", "onMouseWheelClick", "forceChangeSelectItemOnMouseClick" }) do
        local m = base and base:get_method(n)
        if m then pcall(sdk.hook, m, bloquear, nil) end
    end
    -- v0.26.5: onInputCheckEvent devolve bool; pulado, o retorno ficava com lixo (= true) e a lista
    -- escondida andava sozinha a cada quadro (descricao piscando + barulho). Agora responde "false".
    pcall(sdk.hook, td:get_method("onInputCheckEvent"), bloquear, function(ret)
        local Aba = Sala.Aba
        if cfg.menu_jogo and Aba and Aba.aberta then return sdk.to_ptr(0) end
        return ret
    end)
    sdk.hook(td:get_method("lateUpdateOnActive"), function(args)
        thread.get_hook_storage()["mi"] = args[2]
        if not cfg.menu_jogo then return end
        local pular = false
        pcall(function()
            local mi = sdk.to_managed_object(args[2])
            local Aba = Sala.Aba
            if Aba and Aba.aberta then
                -- A aba "JOGAR JUNTO" esta aberta: ela recebe os botoes; o menu do jogo fica escondido e parado
                Aba.menu, Aba.menu_visto = mi, agora()
                local function b(m) local ok, v = pcall(mi.call, mi, m) return ok and v == true end
                local e = Aba.ent or {}
                e.cima = e.cima or b("get__IsTrgMoveUp")
                e.baixo = e.baixo or b("get__IsTrgMoveDown")
                e.esq = e.esq or b("get__IsTrgMoveLeft")
                e.dir = e.dir or b("get__IsTrgMoveRight")
                e.ok = e.ok or b("get__IsTrgDecide")
                e.voltar = e.voltar or b("get__IsTrgCancel")
                Aba.ent = e
                pcall(mi.call, mi, "setVisible(System.Boolean)", false)
                pcall(mi.call, mi, "hideGeneralGuide")   -- a dica do jogo some (a aba tem a dela)
                -- v0.26: a lista escondida nao anda mais com as setas (trocava a descricao e fazia barulho)
                pcall(function()
                    local sl = mi:get_field("ModeSelectList")
                    if Aba.lista_input == nil then
                        Aba.lista_input = sl:call("get_InputType")
                        Aba.lista_som = sl:call("get_UseGUISound")
                    end
                    sl:call("set_InputType", 0)          -- via.gui.InputListType.None
                    sl:call("set_UseGUISound", false)
                end)
                pular = true
                return
            end
            if mi:call("get__IsTrgDecide") or mi:call("get__IsMouseDecide") then
                local idx = mi:get_field("ModeSelectList"):call("get_SelectedIndex")
                local item = mi:get_field("ActualMenuList"):call("get_Item", idx)
                if item and item:get_field("_ActionType") == Sala.ACAO_COOP and Aba then
                    Aba.menu = mi
                    Aba.idx_menu = idx
                    Aba.abrir()
                end
            end
        end)
        if pular then return sdk.PreHookResult.SKIP_ORIGINAL end
    end, function(ret)
        if cfg.menu_jogo then
            pcall(function() escrever_texto(sdk.to_managed_object(thread.get_hook_storage()["mi"])) end)
        end
        return ret
    end)
end)

-- Aba "JOGAR JUNTO" (v0.22): tela propria no estilo do menu do RE4, aberta pela opcao do menu principal.
-- Controle/teclado: lidos do proprio menu do jogo (get__IsTrg*), entao funciona igual ao jogo.
-- Mouse: botoes invisiveis do imgui por cima de cada linha.
local Aba = { aberta = false, sel = 1, menu = nil, menu_visto = 0, tec = {} }
Sala.Aba = Aba

-- v0.27: atualizacao pela propria aba. O plugin (1.3+) baixa do repositorio publico de versoes no GitHub,
-- confere o SHA-256 e troca so os arquivos do mod. Conversa por atualizar.json (pedido) e atualizacao.json (resposta).
Aba.atu = { st = {}, prox = 0, pedido = nil, verificado_em = nil }
function Aba.atu_pedir(acao)
    Aba.atu.pedido = tostring(os.time()) .. "-" .. tostring(math.random(1000, 9999))
    Aba.atu.st = { estado = acao == "instalar" and "baixando" or "verificando" }
    pcall(json.dump_file, PASTA .. "atualizar.json", { id = Aba.atu.pedido, acao = acao })
end
function Aba.atu_ler()
    if agora() < Aba.atu.prox then return end
    Aba.atu.prox = agora() + 0.5
    local ok, t = pcall(json.load_file, PASTA .. "atualizacao.json")
    if ok and type(t) == "table" and t.id == Aba.atu.pedido then Aba.atu.st = t end
end
function Aba.versao_maior(a, b)
    local x, y = {}, {}
    for n in tostring(a):gmatch("%d+") do x[#x + 1] = tonumber(n) end
    for n in tostring(b):gmatch("%d+") do y[#y + 1] = tonumber(n) end
    for i = 1, math.max(#x, #y) do
        local p, q = x[i] or 0, y[i] or 0
        if p ~= q then return p > q end
    end
    return false
end
function Aba.atu_linha(add)
    local st = Aba.atu.st
    local e = st.estado
    if e == "verificado" and Aba.versao_maior(st.remota, VERSAO) then
        add({ txt = "ATUALIZAR PARA V" .. tostring(st.remota), acao = "atualizar",
              desc = "Versão nova disponível: baixa e instala sozinho (só os arquivos do mod)." })
    elseif e == "baixando" or e == "instalando" then
        add({ txt = string.format("BAIXANDO ATUALIZAÇÃO... %d/%d", st.feito or 0, st.total or 0), inativo = true,
              desc = "Não feche o jogo." })
    elseif e == "instalado" then
        add({ txt = "ATUALIZADO PARA V" .. tostring(st.remota), inativo = true,
              desc = st.dll and "Feche e abra o jogo para usar a versão nova."
                  or "Feche e abra o jogo (ou Insert > ScriptRunner > Reset scripts) para usar a versão nova." })
    elseif e == "erro" and Aba.atu.quis_instalar then
        add({ txt = "TENTAR ATUALIZAR DE NOVO", acao = "atualizar", desc = "Erro: " .. tostring(st.msg) })
    end
end

-- Fontes: as do proprio menu do RE4 (Helvetica Neue Condensed, tiradas dos arquivos do jogo e convertidas;
-- vao no pacote): re4coopbr_menu.ttf = MdCn (titulo/opcoes), re4coopbr_texto.ttf = Cn (textos pequenos).
-- Se nao carregarem, usa a Bahnschrift do Windows (re4coopbr.ttf, copiada pelo plugin).
local FONTES = {}
for _, f in ipairs({ { "t1", 44, "menu" }, { "i1", 31, "menu" }, { "p1", 21, "texto" },
                     { "t2", 59, "menu" }, { "i2", 41, "menu" }, { "p2", 28, "texto" } }) do
    local ok, h = pcall(imgui.load_font, "re4coopbr_" .. f[3] .. ".ttf", f[2])
    if not ok or not h then ok, h = pcall(imgui.load_font, "re4coopbr.ttf", f[2]) end
    if ok and h then FONTES[f[1]] = h end
end

local C = {
    branco = 0xFFFFFFFF, cinza = 0xFF9A9A9A, escuro = 0xFF5E5E5E, ambar = 0xFF3FA8E8, verde = 0xFF7AD47A,
    vermelho = 0xFF5A5AF0, sombra = 0xD0000000, painel = 0x90101010, borda = 0x40FFFFFF, faixa = 0x55FFFFFF,
}

local function escala()
    local ok, d = pcall(imgui.get_display_size)
    local w, h = 1920, 1080
    if ok and d and d.x > 0 then w, h = d.x, d.y end
    return h / 1080, w, h
end

local function fonte(tipo, k) return FONTES[tipo .. (k > 1.2 and "2" or "1")] end

-- Texto com sombra numa posicao da tela (dentro da janela de tela cheia)
local function texto(t, x, y, cor, tipo, k)
    local f = fonte(tipo, k)
    if f then imgui.push_font(f) end
    imgui.set_cursor_pos(Vector2f.new(x + 2, y + 2)); imgui.text_colored(t, C.sombra)
    imgui.set_cursor_pos(Vector2f.new(x, y)); imgui.text_colored(t, cor)
    local okc, tam = pcall(imgui.calc_text_size, t)
    if f then imgui.pop_font() end
    return okc and tam and tam.x or (#t * 12 * k)
end

-- Linhas da aba conforme a situacao (fora da sala / anfitriao / convidado)
local function linhas()
    local s = type(status_ponte.steam) == "table" and status_ponte.steam or {}
    local L = {}
    local function add(t) L[#L + 1] = t end
    Aba.atu_linha(add)
    if not ponte_viva() or not s.ok then
        add({ txt = "AGUARDANDO A STEAM...", desc = "O plugin de rede ainda nao conectou na Steam.", inativo = true })
        add({ txt = "VOLTAR", desc = "Voltar ao menu principal.", acao = "voltar" })
        return L, s
    end
    local na_sala = s.lobby and cfg.modo ~= "parado"
    if not na_sala then
        add({ txt = "CRIAR SALA E CONVIDAR", desc = "Você será o anfitrião: cria a sala e abre a lista de amigos da Steam.", acao = "criar" })
        add({ txt = "SALA", valor = cfg.sala == "privada" and "Privada" or "Amigos", acao = "sala",
              desc = "Amigos: seus amigos da Steam veem 'Entrar no jogo'. Privada: só entra quem você convidar." })
        local alguem = false
        for _, a in ipairs(type(s.amigos) == "table" and s.amigos or {}) do
            if type(a.lobby) == "string" and a.lobby ~= "" then
                alguem = true
                add({ txt = "ENTRAR NA SALA DE " .. tostring(a.nome):upper(), desc = tostring(a.nome) .. " está com a sala aberta.",
                      acao = "entrar", lobby = a.lobby })
            end
        end
        if not alguem and type(s.reconectar) == "string" and s.reconectar ~= "" then
            add({ txt = "VOLTAR PARA A SALA DO ÚLTIMO ANFITRIÃO", desc = "O amigo com quem você jogou por último está com a sala aberta.",
                  acao = "entrar", lobby = s.reconectar })
        end
        if not alguem then
            add({ txt = "NENHUM AMIGO COM SALA ABERTA", desc = "Aceite o convite da Steam, ou peça para o amigo criar a sala.", inativo = true })
        end
        add({ txt = "VOLTAR", desc = "Voltar ao menu principal.", acao = "voltar" })
        return L, s
    end
    if s.sou_dono then
        add({ txt = "CONVIDAR AMIGO", desc = "Abre a lista de amigos da Steam para mandar o convite.", acao = "convidar" })
        add({ txt = "COMEÇAR", valor = Sala.inicio_tipo == "continuar" and "Continuar (save co-op)" or "Novo jogo", acao = "tipo",
              desc = Sala.inicio_tipo == "continuar" and "Os dois carregam o save co-op (slot 20), gravado sempre que um de voces salva."
                  or "Os dois começam a história do início, juntos." })
        if Sala.inicio_tipo ~= "continuar" then
            local nome = "Padrão"
            for _, d in ipairs(Sala.DIFS or {}) do if d[1] == (Sala.inicio_dif or 20) then nome = d[2] end end
            add({ txt = "DIFICULDADE", valor = nome, acao = "dif", desc = "Dificuldade do jogo novo (vale para os dois)." })
        end
        local pode, motivo = Sala.membros_ok(s)
        if pode and Sala.inicio_tipo == "continuar" then
            for _, x in ipairs(s.membros or {}) do
                if not x.save or x.save == "" then pode, motivo = false, tostring(x.nome) .. " ainda não tem save co-op: comecem com Novo jogo." end
            end
        end
        add({ txt = "INICIAR PARTIDA", acao = pode and "iniciar" or nil, inativo = not pode,
              desc = pode and "A partida começa sozinha nos dois jogos." or motivo })
    else
        add({ txt = "PRONTO", valor = Sala.pronto and "Sim" or "Não", acao = "pronto",
              desc = Sala.pronto and "Aguardando o anfitrião iniciar: a partida começa sozinha." or "Marque quando estiver pronto para começar." })
    end
    add({ txt = "SAIR DA SALA", desc = "Sai da sala (o parceiro fica sozinho).", acao = "sair" })
    add({ txt = "VOLTAR", desc = "Volta ao menu principal sem sair da sala.", acao = "voltar" })
    return L, s
end

local function executar(l, dir)
    local a = l.acao
    if not a then return end
    if a == "voltar" then Aba.fechar()
    elseif a == "criar" then Sala.criar_sala_steam(); Sala.convidar_apos = true
    elseif a == "sala" then cfg.sala = cfg.sala == "privada" and "amigos" or "privada"; salvar_cfg(); enviar_ctl()
    elseif a == "entrar" then Sala.entrar_sala_steam(l.lobby)
    elseif a == "convidar" then Sala.convidar = os.time(); enviar_ctl()
    elseif a == "tipo" then Sala.inicio_tipo = Sala.inicio_tipo == "continuar" and "novo" or "continuar"; enviar_ctl()
    elseif a == "dif" then
        local d = Sala.DIFS or {}
        local i = 2
        for k, v in ipairs(d) do if v[1] == (Sala.inicio_dif or 20) then i = k end end
        i = i + (dir or 1)
        if i < 1 then i = #d elseif i > #d then i = 1 end
        Sala.inicio_dif = d[i] and d[i][1] or 20; enviar_ctl()
    elseif a == "pronto" then Sala.pronto = not Sala.pronto; enviar_ctl()
    elseif a == "iniciar" then Sala.inicio = tostring(os.time()); enviar_ctl()
    elseif a == "sair" then Sala.sair_sala()
    elseif a == "atualizar" then Aba.atu.quis_instalar = true; Aba.atu_pedir("instalar")
    end
end

function Aba.abrir()
    Aba.aberta = true
    Aba.sel = 1
    Aba.aberta_em = agora()
    Aba.ent = nil
    for _, vk in ipairs({ 0x26, 0x57, 0x28, 0x53, 0x25, 0x41, 0x27, 0x44, 0x0D, 0x20, 0x1B, 0x08 }) do
        local ok, d = pcall(reframework.is_key_down, reframework, vk)
        Aba.tec[vk] = ok and d or false
    end
    Sala.esconder = true          -- a janela flutuante antiga nao precisa aparecer junto
    -- confere se ha versao nova (no maximo a cada 10 min; nao repete durante download/instalacao)
    local e = Aba.atu.st.estado
    if e ~= "baixando" and e ~= "instalando" and e ~= "instalado"
        and (not Aba.atu.verificado_em or agora() - Aba.atu.verificado_em > 600) then
        Aba.atu.verificado_em = agora()
        Aba.atu_pedir("verificar")
    end
end
function Aba.fechar()
    Aba.aberta = false
    local mi = Aba.menu
    if mi then
        pcall(mi.call, mi, "setVisible(System.Boolean)", true)
        pcall(function()
            local sl = mi:get_field("ModeSelectList")
            if Aba.lista_input ~= nil then sl:call("set_InputType", Aba.lista_input) end
            if Aba.lista_som ~= nil then sl:call("set_UseGUISound", Aba.lista_som) end
        end)
        Aba.lista_input, Aba.lista_som = nil, nil
        -- A lista escondida andou junto com as setas: volta para JOGAR JUNTO e refaz a dica do jogo
        if Aba.idx_menu then
            local sl = mi:get_field("ModeSelectList")
            pcall(sl.call, sl, "setCursorIndex(System.Int32, System.Boolean)", Aba.idx_menu, true)
            pcall(sl.call, sl, "setSelectedIndex(System.Int32, System.Boolean)", Aba.idx_menu, true)
        end
        pcall(mi.call, mi, "setMainMenuGuide")
    end
end

-- Entrada: o gancho do menu do jogo preenche Aba.ent a cada quadro; sem menu, teclado direto
local function borda(vk)
    local ok, d = pcall(reframework.is_key_down, reframework, vk)
    d = ok and d or false
    local antes = Aba.tec[vk]
    Aba.tec[vk] = d
    return d and not antes
end
local function entrada()
    if Aba.ent and agora() - Aba.menu_visto < 0.3 then
        local e = Aba.ent
        Aba.ent = nil
        return e
    end
    return {
        cima = borda(0x26) or borda(0x57), baixo = borda(0x28) or borda(0x53),
        esq = borda(0x25) or borda(0x41), dir = borda(0x27) or borda(0x44),
        ok = borda(0x0D) or borda(0x20), voltar = borda(0x1B) or borda(0x08),
    }
end

function Aba.desenhar()
    if not Aba.aberta then return end
    if local_.ok or Sala.no_jogo then Aba.aberta = false return end
    Aba.atu_ler()
    local L, s = linhas()
    if Aba.sel > #L then Aba.sel = #L end
    if Aba.sel < 1 then Aba.sel = 1 end

    -- Navegacao (nos primeiros instantes ignora: o botao que abriu a aba nao pode acionar a 1a opcao)
    local e = entrada()
    if agora() - (Aba.aberta_em or 0) < 0.35 then e = {} end
    if e.cima then Aba.sel = Aba.sel > 1 and Aba.sel - 1 or #L end
    if e.baixo then Aba.sel = Aba.sel < #L and Aba.sel + 1 or 1 end
    local atual = L[Aba.sel]
    if atual and atual.valor and (e.esq or e.dir) then executar(atual, e.esq and -1 or 1) end
    if atual and e.ok and not atual.inativo then executar(atual, 1) end
    if e.voltar then Aba.fechar() return end

    local k, W, H = escala()
    -- Sem fundo escuro: a aba fica por cima do proprio fundo do menu do jogo (so o texto tem sombra)

    imgui.set_next_window_pos(Vector2f.new(0, 0), 1)
    imgui.set_next_window_size(Vector2f.new(W, H), 1)
    imgui.push_style_color(2, 0x00000000)   -- ImGuiCol_WindowBg transparente
    imgui.push_style_color(5, 0x00000000)   -- borda
    local flags = 1 + 2 + 4 + 8 + 32 + 256  -- sem titulo/redimensionar/mover/rolagem/recolher, sem salvar
    imgui.begin_window("##re4coopbr_aba", true, flags)

    local x0 = 158 * k
    texto("JOGAR JUNTO", x0 - 20 * k, 120 * k, C.branco, "t", k)
    local sub
    if s.lobby and cfg.modo ~= "parado" then
        sub = s.sou_dono and "Sua sala na Steam  -  você é o anfitrião" or "Sala do amigo  -  você é o convidado"
    else
        sub = "Co-op para dois jogadores pela Steam  -  RE4 Co-op BR v" .. VERSAO
    end
    texto(sub, x0, 182 * k, C.cinza, "p", k)

    -- Linhas
    local y = 260 * k
    local passo = 58 * k
    local mx, my = 0, 0
    local okm, m = pcall(imgui.get_mouse)
    if okm and m then mx, my = m.x, m.y end
    for i, l in ipairs(L) do
        local sel = i == Aba.sel
        -- mouse: passar por cima seleciona, clicar confirma
        imgui.set_cursor_pos(Vector2f.new(x0 - 30 * k, y - 6 * k))
        if imgui.invisible_button("##linha" .. i, Vector2f.new(760 * k, passo - 8 * k)) then
            Aba.sel = i
            if not l.inativo then executar(l, 1) end
        end
        if mx >= x0 - 30 * k and mx <= x0 + 730 * k and my >= y - 6 * k and my <= y + passo - 14 * k then
            if Aba.mouse_ult_x ~= mx or Aba.mouse_ult_y ~= my then Aba.sel = i; sel = true end
        end
        if sel then
            draw.filled_rect(x0 - 40 * k, y - 4 * k, 760 * k, passo - 12 * k, 0x30FFFFFF)
            draw.filled_rect(x0 - 40 * k, y - 4 * k, 4 * k, passo - 12 * k, C.ambar)
        end
        local cor = l.inativo and C.escuro or (sel and C.branco or C.cinza)
        local xx = sel and x0 - 16 * k or x0
        texto(l.txt, xx, y, cor, "i", k)
        if l.valor then
            local vx = x0 + 330 * k
            texto("<", vx, y, sel and C.ambar or C.escuro, "i", k)
            texto(l.valor, vx + 34 * k, y, sel and C.branco or C.cinza, "i", k)
            local largura = 0
            local f = fonte("i", k)
            if f then imgui.push_font(f) end
            local okc, tam = pcall(imgui.calc_text_size, l.valor)
            if f then imgui.pop_font() end
            largura = okc and tam and tam.x or 100 * k
            texto(">", vx + 50 * k + largura, y, sel and C.ambar or C.escuro, "i", k)
        end
        y = y + passo
    end
    Aba.mouse_ult_x, Aba.mouse_ult_y = mx, my

    -- Cartoes dos jogadores (direita)
    local cx, cw, ch = W - 640 * k, 500 * k, 170 * k
    local membros = type(s.membros) == "table" and s.membros or {}
    local ordem = {}
    for _, mbr in ipairs(membros) do if mbr.dono then table.insert(ordem, 1, mbr) else ordem[#ordem + 1] = mbr end end
    for n = 1, 2 do
        local cy = 250 * k + (n - 1) * (ch + 30 * k)
        draw.filled_rect(cx, cy, cw, ch, C.painel)
        draw.outline_rect(cx, cy, cw, ch, C.borda)
        local mbr = ordem[n]
        local rot = n == 1 and "JOGADOR 1  -  ANFITRIÃO" or "JOGADOR 2  -  CONVIDADO"
        texto(rot, cx + 24 * k, cy + 16 * k, C.ambar, "p", k)
        if mbr then
            draw.filled_rect(cx, cy, 6 * k, ch, (mbr.dono or mbr.pronto == "1") and C.verde or C.ambar)
            texto(tostring(mbr.nome) .. (mbr.eu and "  (você)" or ""), cx + 24 * k, cy + 48 * k, C.branco, "i", k)
            local est = mbr.dono and "Anfitrião" or (mbr.pronto == "1" and "PRONTO" or "Ainda não está pronto")
            texto(est .. "   -   v" .. tostring(mbr.v), cx + 24 * k, cy + 92 * k,
                (mbr.dono or mbr.pronto == "1") and C.verde or C.cinza, "p", k)
            texto("Save co-op: " .. ((mbr.save and mbr.save ~= "") and mbr.save or "nenhum ainda"), cx + 24 * k, cy + 124 * k, C.cinza, "p", k)
        else
            texto(n == 1 and "Sem sala" or "Aguardando parceiro...", cx + 24 * k, cy + 60 * k, C.escuro, "i", k)
            if n == 2 and s.lobby then texto("Use CONVIDAR AMIGO", cx + 24 * k, cy + 108 * k, C.escuro, "p", k) end
        end
    end
    if s.lobby and status_ponte.conectado then
        texto(string.format("Conectado pela Steam  -  ping %d ms", status_ponte.ping or 0), cx, 250 * k + 2 * (ch + 30 * k), C.verde, "p", k)
    end
    if Sala.iniciada and agora() < Sala.iniciada.ate then
        texto(Sala.iniciada.tipo == "continuar" and "PARTIDA INICIADA - carregando o save co-op..." or "PARTIDA INICIADA - começando o jogo novo...",
            cx, 250 * k + 2 * (ch + 30 * k) + 34 * k, C.branco, "i", k)
    end

    -- Descricao da opcao e botoes (embaixo, como no jogo)
    local desc = atual and atual.desc or ""
    local f = fonte("i", k)
    local largura = #desc * 12 * k
    if f then imgui.push_font(f) end
    local okc, tam = pcall(imgui.calc_text_size, desc)
    if f then imgui.pop_font() end
    if okc and tam then largura = tam.x end
    texto(desc, (W - largura) / 2, H - 150 * k, C.branco, "i", k)
    local dicas = atual and atual.valor and "[ Espaço ]  Confirmar        [ <  > ]  Alterar        [ Esc ]  Voltar"
        or "[ Espaço ]  Confirmar        [ Esc ]  Voltar"
    f = fonte("p", k)
    if f then imgui.push_font(f) end
    okc, tam = pcall(imgui.calc_text_size, dicas)
    if f then imgui.pop_font() end
    texto(dicas, (W - (okc and tam and tam.x or 400 * k)) / 2, H - 104 * k, C.cinza, "p", k)

    imgui.end_window()
    imgui.pop_style_color(2)
end

-- Exporta as acoes que a aba usa (estao como locais dentro deste bloco)
Sala.criar_sala_steam = criar_sala_steam
Sala.entrar_sala_steam = entrar_sala_steam
Sala.sair_sala = sair_sala
Sala.membros_ok = membros_ok

return aba_conexao
end)()

local function aba_jogo()
    if not local_.ok then imgui.text_colored("Carregue um save para comecar.", COR.cinza) end
    titulo("Voce")
    imgui.text(string.format("Capitulo %s  |  Area %s", nome_capitulo(local_.cap), nome_estagio(local_.est)))
    if local_.hp then imgui.text(string.format("Vida %d / %d", math.floor(local_.hp), math.floor(local_.hpmax or 0))) end
    imgui.spacing()
    titulo("Parceiro")
    if parceiro_online() then
        imgui.text(string.format("%s  |  Capitulo %s  |  Area %s", parceiro.nome or "?", nome_capitulo(parceiro.cap),
            nome_estagio(parceiro.est)))
        local d = distancia_parceiro()
        if d and mesma_area() then imgui.text(string.format("Distancia: %.1f m", d)) end
        if parceiro.hp then imgui.text(string.format("Vida %d / %d", math.floor(parceiro.hp), math.floor(parceiro.hpmax or 0))) end
        if local_.cap and parceiro.cap and local_.cap ~= parceiro.cap then
            imgui.text_colored("Capitulos diferentes! Carreguem o mesmo save/capitulo.", COR.vermelho)
        elseif not mesma_area() then
            imgui.text_colored("Areas diferentes: siga o marcador da porta ou aperte F5.", COR.amarelo)
        end
    else
        imgui.text_colored("Nao conectado.", COR.cinza)
    end
    imgui.separator()
    if imgui.button("Ir ate o parceiro  [F5]") then ir_ate_parceiro() end
    imgui.same_line()
    if imgui.button("Trazer parceiro ate mim  [F6]") then puxar_parceiro() end
end

local function aba_opcoes()
    local c
    titulo("Anti-preso")
    c, cfg.anti_preso = imgui.checkbox("Puxar automaticamente quem ficou para tras", cfg.anti_preso)
    if c then salvar_cfg() end
    c, cfg.quem_segue = imgui.combo("Quem e puxado", cfg.quem_segue, QUEM_SEGUE)
    if c then salvar_cfg() end
    c, cfg.dist_max = imgui.slider_float("Distancia maxima (m)", cfg.dist_max, 8.0, 60.0, "%.0f")
    if c then salvar_cfg() end
    c, cfg.tempo_max = imgui.slider_float("Tempo longe antes de puxar (s)", cfg.tempo_max, 1.0, 15.0, "%.1f")
    if c then salvar_cfg() end
    imgui.spacing()
    titulo("Parceiro na tela")
    c, cfg.avatar = imgui.combo("Avatar do parceiro", cfg.avatar, AVATARES)
    if c then salvar_cfg() end
    c, cfg.mostrar_nome = imgui.checkbox("Mostrar nome e vida acima do parceiro", cfg.mostrar_nome)
    if c then salvar_cfg() end
    c, cfg.mostrar_hud = imgui.checkbox("Mostrar barra de status no canto", cfg.mostrar_hud)
    if c then salvar_cfg() end
    c, cfg.atraso_ms = imgui.slider_int("Suavizacao (ms)", cfg.atraso_ms, 0, 300)
    if c then salvar_cfg() end
    c, cfg.clarao = imgui.slider_int("Clarao dos tiros do parceiro (%)", cfg.clarao, 0, 100)
    if c then salvar_cfg() end
    imgui.text_colored("Mais suavizacao = movimento mais liso, porem um pouco mais atrasado.", COR.cinza)
    imgui.spacing()
    titulo("Objetos do cenario")
    c, cfg.sync_objetos = imgui.checkbox("Sincronizar portas, alavancas e escadas", cfg.sync_objetos)
    if c then salvar_cfg() end
    c, cfg.sync_chaves = imgui.checkbox("Itens-chave valem para os dois (chaves, itens da historia)", cfg.sync_chaves)
    if c then salvar_cfg() end
    imgui.text(string.format("Objetos vigiados: %d  |  enviados: %d  |  recebidos: %d", #objetos.lista, objetos.enviados, objetos.recebidos))
    imgui.text("Ultimo: " .. objetos.ultimo)
    imgui.spacing()
    titulo("Historia")
    c, cfg.sync_historia = imgui.checkbox("Eventos da historia acontecem para os dois (ex.: torre da vila)", cfg.sync_historia)
    if c then salvar_cfg() end
    imgui.text(string.format("Enviadas: %d  |  recebidas: %d  |  aplicadas: %d  |  esperando: %d",
        Historia.enviadas, Historia.recebidas, Historia.aplicadas, Historia.esperando))
    imgui.text("Ultimo: " .. Historia.ultimo)
    imgui.spacing()
    titulo("Inimigos")
    c, cfg.sync_inimigos = imgui.checkbox("Dano e morte dos inimigos valem para os dois", cfg.sync_inimigos)
    if c then salvar_cfg() end
    c, cfg.inimigos_seguem = imgui.checkbox("Inimigos no mesmo lugar (manda o jogo de quem esta mais perto)", cfg.inimigos_seguem)
    if c then salvar_cfg() end
    c, cfg.inimigos_animacao = imgui.checkbox("Inimigos com a mesma animacao (experimental)", cfg.inimigos_animacao)
    if c then salvar_cfg() end
    imgui.text(string.format("Animados agora: %d  |  trocas de animacao: %d", Inimigos.animados or 0, Inimigos.trocas_anim or 0))
    imgui.text(string.format("Inimigos carregados: %d  |  danos enviados: %d  |  recebidos: %d  |  aguardando: %d",
        Inimigos.vistos, Inimigos.enviados, Inimigos.recebidos, Inimigos.pendentes))
    imgui.text(string.format("Seus (voce manda): %d  |  do parceiro (seguindo): %d  |  entregues: %d  |  recebidos: %d",
        Inimigos.meus or 0, Inimigos.seguidos or 0, Inimigos.entregues or 0, Inimigos.ganhos or 0))
    imgui.text("Ultimo: " .. Inimigos.ultimo)
end

local function aba_chat()
    for i = math.max(1, #mensagens - 14), #mensagens do
        local m = mensagens[i]
        if m.de then
            imgui.text_colored("[" .. m.t .. "] " .. m.de .. ":", COR.azul)
            imgui.same_line()
            imgui.text(m.texto)
        else
            imgui.text_colored("[" .. m.t .. "] " .. m.texto, COR.cinza)
        end
    end
    imgui.separator()
    local c
    c, texto_chat = imgui.input_text("##chat", texto_chat)
    imgui.same_line()
    if imgui.button("Enviar") and texto_chat ~= "" then
        enviar_evento("msg", texto_chat)
        registrar(texto_chat, cfg.nome)
        texto_chat = ""
    end
end

local function aba_diagnostico()
    imgui.text("Versao " .. VERSAO .. "  |  sessao " .. SESSAO)
    imgui.text("Ponte: " .. (ponte_viva() and "rodando" or "parada") .. "  |  modo " .. tostring(status_ponte.modo))
    imgui.text("Remoto: " .. tostring(status_ponte.remoto or "-"))
    imgui.text("Pacotes recebidos: " .. tostring(status_ponte.rx or 0) .. "  |  enviados: " .. tostring(status_ponte.tx or 0))
    imgui.text("Leitor capitulo: " .. (leitores.capitulo and (leitores.capitulo.sing .. "." .. leitores.capitulo.metodo) or "nao encontrado"))
    imgui.text("Leitor area: " .. (leitores.estagio and (leitores.estagio.sing .. "." .. leitores.estagio.metodo) or "nao encontrado"))
    imgui.text("Avatar escolhido: " .. (AVATARES[cfg.avatar] or "?"))
    imgui.text("Corpo do parceiro: " .. clone.status)
    imgui.text("Armas do parceiro: " .. clone.status_armas)
    imgui.text(string.format("Juntas do parceiro recebidas: %d  |  aplicadas no corpo: %d",
        ossos_parceiro.nomes and #ossos_parceiro.nomes or 0, juntas_mapeadas()))
    imgui.text(string.format("Minhas juntas enviadas: %d", #ossos_locais.juntas))
    imgui.text("Ashley/Luis na cena: " .. (go_companheiro() and "sim" or "nao"))
    if imgui.button("Recriar corpo do parceiro") then
        cfg.avatar = 1
        salvar_cfg()
        clone.prox_tentativa = 0
        destruir_clone()
    end
    imgui.text("Eventos pendentes: " .. #eventos_pendentes)
end

local ABAS = {
    { "Conexao", aba_conexao }, { "Jogo", aba_jogo }, { "Opcoes", aba_opcoes },
    { "Chat", aba_chat }, { "Diagnostico", aba_diagnostico },
}

function desenhar_painel()
    if not cfg.painel_aberto then return end
    pcall(imgui.set_next_window_size, Vector2f.new(520, 470), 4) -- ImGuiCond_FirstUseEver
    local aberto = imgui.begin_window("RE4 Co-op BR  v" .. VERSAO .. "###re4coopbr", true, 0)
    if imgui.begin_tab_bar then
        if imgui.begin_tab_bar("abas_coop") then
            for _, aba in ipairs(ABAS) do
                if imgui.begin_tab_item(aba[1]) then
                    pcall(aba[2])
                    imgui.end_tab_item()
                end
            end
            imgui.end_tab_bar()
        end
    else
        for _, aba in ipairs(ABAS) do
            if imgui.collapsing_header(aba[1]) then pcall(aba[2]) end
        end
    end
    imgui.end_window()
    if aberto == false then cfg.painel_aberto = false; salvar_cfg() end
end
end -- bloco do painel

-- Arquivo de diagnostico (RE4CoopBR/diag.json) para depurar sem precisar de print.
-- Tambem num bloco proprio (limite de 200 locais): fora dele so existe rodar_diagnostico.
local rodar_diagnostico
do
local prox_diag = 0
local ultima_sonda = nil
local ultimo_comando = nil
local resultado_comando = nil

-- comando.json: permite pedir "sonda" ou "recriar" de fora do jogo
local function ler_comando()
    local ok, c = pcall(json.load_file, PASTA .. "comando.json")
    if not ok or type(c) ~= "table" or c.id == nil or c.id == ultimo_comando then return end
    ultimo_comando = c.id
    if c.acao == "sonda" then
        local ok2, r = pcall(sondar_personagem)
        ultima_sonda = ok2 and r or { erro = tostring(r) }
    elseif c.acao == "recriar" then
        destruir_clone()
        clone.prox_tentativa = 0
    elseif c.acao == "lua" and type(c.codigo) == "string" and (cfg.modo_dev or json.load_file(PASTA .. "dev.json") ~= nil) then
        -- Depuracao: roda um trecho de Lua com acesso ao estado do mod
        local env = setmetatable({
            clone = clone, visual_local = visual_local, visual_parceiro = visual_parceiro,
            componente = componente, tentar = tentar, chamar = chamar, T_MESH = T_MESH, T_TRANSFORM = T_TRANSFORM,
            go_jogador = go_jogador, amostras = amostras, carregar_holder = carregar_holder, tipo_de = tipo_de,
            armas_do_personagem = armas_do_personagem, nome_go = nome_go, criar_go = criar_go,
            objetos = objetos, atualizar_lista_objetos = atualizar_lista_objetos, bandeira = bandeira,
            Sala = Sala, cfg = cfg, local_ = local_, status_ponte = function() return status_ponte end,
            enviar_ctl = enviar_ctl, salvar_cfg = salvar_cfg,
        }, { __index = _G })
        local f, err = load(c.codigo, "comando", "t", env)
        if not f then
            resultado_comando = { id = c.id, erro = tostring(err) }
        else
            local ok, r = pcall(f)
            if ok and type(r) ~= "table" then r = tostring(r) end
            resultado_comando = { id = c.id, ok = ok, resultado = ok and r or tostring(r) }
        end
    end
end

local function escrever_diag()
    if ultima_sonda == nil and local_.ok then
        local ok, r = pcall(sondar_personagem)
        ultima_sonda = ok and r or { erro = tostring(r) }
    end
    local partes = {}
    for _, p in ipairs(clone.partes) do
        local pos = p.tr and tentar(p.tr, { "get_Position" })
        local ok_d, desenha = pcall(p.go.call, p.go, "get_DrawSelf")
        table.insert(partes, {
            nome = p.nome, valido = valido(p.go), desenha = ok_d and desenha or "?",
            pos = pos and { arred(pos.x, 2), arred(pos.y, 2), arred(pos.z, 2) } or nil,
            juntas_mapeadas = p.mapa and #p.mapa or 0,
        })
    end
    gravar_json(PASTA .. "diag.json", {
        versao = VERSAO, hora = os.date("%H:%M:%S"),
        avatar = cfg.avatar, gancho_late_update = contador_gancho,
        parceiro_online = parceiro_online(), mesma_area = mesma_area(),
        eu = local_.ok and { arred(local_.x, 2), arred(local_.y, 2), arred(local_.z, 2) } or nil,
        parceiro = pos_render and { arred(pos_render[1], 2), arred(pos_render[2], 2), arred(pos_render[3], 2) } or nil,
        cap = local_.cap, cap_parceiro = parceiro and parceiro.cap,
        juntas_parceiro = ossos_parceiro.nomes and #ossos_parceiro.nomes or 0,
        minhas_juntas = #ossos_locais.juntas,
        corpo_status = clone.status, corpo_visivel = clone.visivel, partes = partes,
        armas_status = clone.status_armas,
        armas = (function()
            local t = {}
            local ult = amostras[#amostras]
            for i, a in pairs(clone.armas) do
                local d = ult and ult.pose and ult.pose.armas and ult.pose.armas[i]
                t[#t + 1] = string.format("%d %s visivel_parceiro=%s desenhando=%s", i, tostring(a.nome),
                    tostring(d and d.v), tostring(a.visivel))
            end
            return t
        end)(),
        minhas_armas = (function()
            local t = {}
            for _, a in ipairs(visual_local.armas_obj or {}) do t[#t + 1] = a.nome .. (arma_visivel(a) and " (visivel)" or " (escondida)") end
            return t
        end)(),
        ultima_criacao = diag_clone,
        comando = resultado_comando,
        objetos = { vigiados = #objetos.lista, enviados = objetos.enviados, recebidos = objetos.recebidos,
            acoes_env = objetos.acoes_env, acoes_rec = objetos.acoes_rec,
            ignorados_longe = objetos.ignorados or 0, ultimo = objetos.ultimo },
        inimigos = { carregados = Inimigos.vistos, enviados = Inimigos.enviados, recebidos = Inimigos.recebidos,
            aguardando = Inimigos.pendentes, meus = Inimigos.meus or 0, seguindo = Inimigos.seguidos or 0,
            entregues = Inimigos.entregues or 0, ganhos = Inimigos.ganhos or 0, ultimo = Inimigos.ultimo,
            animados = Inimigos.animados or 0, trocas_anim = Inimigos.trocas_anim or 0, insistencias = Inimigos.insistencias or 0 },
        historia = { enviadas = Historia.enviadas, recebidas = Historia.recebidas, aplicadas = Historia.aplicadas,
            esperando = Historia.esperando, ultimo = Historia.ultimo },
        teste_pose = {
            formato = teste_pose.formato, resultado = teste_pose.resultado,
            -- Depois de um frame inteiro a pose ainda esta la? (se nao, o motor reseta as juntas)
            -- v0.26.2: so le a junta de teste se o boneco ainda existe (a antiga gerava erro no log a cada segundo)
            persistiu_no_frame = clone_valido() and teste_pose.junta and parecido(ler_quat(teste_pose.junta), teste_pose.alvo) or nil,
            mundo_persistiu = clone_valido() and teste_pose.junta_mundo and (function()
                local ok, r = pcall(teste_pose.junta_mundo.call, teste_pose.junta_mundo, "get_Rotation")
                return ok and r and parecido({ r.x, r.y, r.z, r.w }, teste_pose.alvo_mundo) or false
            end)() or nil,
            pacote_modo = "mundo-relativo",
            posicoes_recebidas = (function()
                local ult = amostras[#amostras]
                local n = 0
                for _ in pairs(ult and ult.pose and ult.pose.p or {}) do n = n + 1 end
                return n
            end)(),
            minhas_posicoes_enviadas = ossos_locais.com_posicao and #ossos_locais.com_posicao or 0,
        },
    })
end

function rodar_diagnostico(t)
    if t < prox_diag then return end
    prox_diag = t + 1
    local okc, errc = pcall(ler_comando)
    if not okc then resultado_comando = { erro = "ler_comando: " .. tostring(errc) } end
    local ok, err = pcall(escrever_diag)
    if not ok then log.error("[RE4 Co-op BR] diag: " .. tostring(err)) end
end
end -- bloco do diagnostico

re.on_frame(function()
    local t = agora()
    rodar_diagnostico(t)

    if t >= prox_saida then
        prox_saida = t + 1 / 30
        pcall(ler_estado_local)
        if cfg.modo ~= "parado" then pcall(escrever_saida) end
    end
    if cfg.modo ~= "parado" and t >= prox_entrada then
        prox_entrada = t + 1 / 60
        pcall(ler_ponte)
    end
    if t >= prox_status then
        prox_status = t + 0.25
        pcall(ler_status)
    end

    pcall(anti_preso)
    local okv, errv = pcall(vigiar_objetos)
    if not okv then objetos.ultimo = "erro: " .. tostring(errv) end
    local oki, erri = pcall(Inimigos.tick)
    if not oki then Inimigos.ultimo = "erro: " .. tostring(erri) end
    local okh, errh = pcall(Historia.tick)
    if not okh then Historia.ultimo = "erro: " .. tostring(errh) end
    local okc, errc = pcall(Sala.chaves.tick)
    if not okc then Sala.chaves.erro = tostring(errc) end

    if tecla_apertada(VK.F5) then ir_ate_parceiro() end
    -- v0.26: o parceiro entrou numa cena -> convite no topo; F7 = ir ate ele para ver junto
    -- (cenas que comecam ao entrar num lugar, como as de chefe, comecam sozinhas no seu jogo quando voce chega)
    if parceiro_online() and parceiro.cena and not Sala.cena_parceiro_vista and not Sala.em_cena_agora() then
        Sala.cena_parceiro_vista = true
        Sala.convite_cena = { ate = agora() + 20, id = parceiro.cid }
    elseif parceiro_online() and not parceiro.cena then
        Sala.cena_parceiro_vista = false
    end
    if Sala.convite_cena and (agora() > Sala.convite_cena.ate or Sala.em_cena_agora()) then Sala.convite_cena = nil end
    if tecla_apertada(VK.F7) and Sala.convite_cena then
        local cid = tonumber(Sala.convite_cena.id or parceiro.cid)
        Sala.convite_cena = nil
        if mesma_area() and cid then
            Sala.assistir = { id = cid, apos = agora(), limite = agora() + 600 }
        else
            ir_ate_parceiro("Indo ate o parceiro para ver a cena junto.")
            if cid then Sala.assistir = { id = cid, apos = agora() + 4, limite = agora() + 600 } end
        end
    end
    -- v0.26.3: toca no MEU jogo a mesma cena do parceiro, pelo numero (testado: TimelineEventWork(ID) -> load -> play).
    -- A cena criada aqui nao e de ninguem no jogo: o mod "empurra" (onUpdate) ate ela terminar.
    pcall(function()
        local a = Sala.assistir
        if not a then return end
        if agora() > a.limite then Sala.assistir = nil return end
        if not a.w then
            if agora() < a.apos or not local_.ok then return end
            local w = sdk.create_instance("chainsaw.TimelineEventWork", true)
            if not w then Sala.assistir = nil return end
            w = w:add_ref()
            w:call(".ctor(chainsaw.TimelineEventDefine.ID)", a.id)
            pcall(w.call, w, "requestLoadForPlay")
            pcall(w.call, w, "load")
            a.w = w
            a.criada = agora()
            a.tent = (a.tent or 0) + 1
            if a.tent == 1 then registrar("Assistindo a cena junto com o parceiro.") end
        end
        pcall(a.w.call, a.w, "onUpdate")
        if not a.tocou then
            local okl, carregada = pcall(a.w.call, a.w, "get_IsLoaded")
            -- v0.27.1: as vezes o carregamento trava na fase Loading para sempre (visto com a cena 10154);
            -- uma cena criada de novo carrega em ~2 s. Passou de 6 s: descarta e cria outra (ate 4 vezes).
            if not (okl and carregada) and agora() - (a.criada or agora()) > 6 then
                local fase = nil
                pcall(function() fase = a.w:get_field("_EventPhase") end)
                pcall(a.w.call, a.w, "unload")
                if a.tent < 4 then
                    registrar(string.format("Cena %s ainda carregando (fase %s): tentando de novo (%d).", tostring(a.id), tostring(fase), a.tent))
                    a.w = nil
                else
                    registrar(string.format("Não consegui carregar a cena %s.", tostring(a.id)))
                    Sala.assistir = nil
                end
                return
            end
            if okl and carregada then
                a.tocou = true
                pcall(a.w.call, a.w, "play(via.GameObject, System.Action, System.Action, System.Boolean, System.Boolean)",
                    go_jogador(), nil, nil, false, false)
            end
        else
            local oke, fim = pcall(a.w.call, a.w, "get_IsEnded")
            if oke and fim then Sala.assistir = nil end
        end
    end)
    if tecla_apertada(VK.F6) then puxar_parceiro() end
    if tecla_apertada(VK.F8) then cfg.painel_aberto = not cfg.painel_aberto; salvar_cfg() end

    pcall(Sala.tick)
    pcall(desenhar_mundo)
    pcall(desenhar_hud)
    pcall(function()
        local cv = Sala.convite_cena
        if not cv or not parceiro then return end
        local txt = string.format("%s entrou numa cena  -  aperte F7 para assistir junto  (%d)", parceiro.nome or "Parceiro",
            math.max(0, math.floor(cv.ate - agora())))
        txt = I18N.T(txt)
        local w = imgui.get_display_size and imgui.get_display_size().x or 1920
        local x = math.floor(w / 2 - #txt * 4.5)
        draw.filled_rect(x - 16, 14, #txt * 9 + 32, 34, COR.fundo)
        texto_sombra(txt, x, 22, COR.amarelo)
    end)
    -- v0.23: o aviso grande de "aguardando/iniciou" saiu da tela (pedido dos jogadores)
    pcall(desenhar_inicio)
    if Sala.Aba then
        local oka, erra = pcall(Sala.Aba.desenhar)
        if not oka then log.error("[RE4 Co-op BR] aba: " .. tostring(erra)) end
    end
    local ok, err = pcall(desenhar_painel)
    if not ok then log.error("[RE4 Co-op BR] painel: " .. tostring(err)) end
end)

re.on_draw_ui(function()
    if imgui.tree_node("RE4 Co-op BR") then
        imgui.text("Painel completo: tecla F8")
        if imgui.button(cfg.painel_aberto and "Fechar painel" or "Abrir painel") then
            cfg.painel_aberto = not cfg.painel_aberto; salvar_cfg()
        end
        linha_status()
        imgui.tree_pop()
    end
end)

re.on_script_reset(function()
    pcall(destruir_clone)
    if clarao.go then pcall(clarao.go.call, clarao.go, "destroy(via.GameObject)", clarao.go) end
    -- O plugin espera alguns segundos antes de sair da sala Steam: o Reset de scripts nao derruba o parceiro
    pcall(json.dump_file, ARQ.ctl, { modo = "parado", rede = cfg.rede, sessao = SESSAO, t = agora() })
end)

log.info("[RE4 Co-op BR] v" .. VERSAO .. " carregado")

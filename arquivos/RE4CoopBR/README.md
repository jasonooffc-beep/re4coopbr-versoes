# RE4 Co-op BR

**Two-player online co-op for Resident Evil 4 (2023 Remake) on PC.** Each player runs their own copy of the game (no input lag), and the mod keeps both worlds in sync over Steam.

> 🇧🇷 [Leia em português](#português)

## Features

- **Steam invites.** No IP addresses or port forwarding. Create a lobby, invite a friend from your Steam friends list, and you're in.
- **"PLAY TOGETHER" in the game's main menu.** It opens a lobby screen in the style of RE4, with host and guest cards, a ready check, New game or Continue, and difficulty.
- **Automatic start.** When the host presses START, both games load the same save (or start a new game) by themselves.
- **Shared co-op save (slot 20).** Whenever either player saves, both games write the co-op slot.
- **Your partner in your world.** You see an animated copy of their character, with their outfit, weapons, muzzle flashes and gunshot sounds.
- **Synced enemies.** Damage and deaths count for both players. Each enemy is controlled by whichever player is closer, and its animations are mirrored.
- **Synced story events and world objects.** Story events (e.g. the village tower), doors, levers and ladders are shared.
- **Teleport on demand.** F5 takes you to your partner, F6 brings them to you, and a door marker shows where they went. Automatic pulling is optional.
- **Pause-aware.** When one player pauses, the other takes over the enemies, and the paused player is labelled "(PAUSED)".
- **Shared key items.** When one player picks up a key item (keys, story items), the partner gets it too and it disappears from their map.
- **Language.** Follows the game's language automatically (Portuguese or English); other languages can be added as JSON files.

## Requirements

- Resident Evil 4 (2023) on Steam, **both players**.
- [REFramework](https://github.com/praydog/REFramework-nightly/releases) for RE4 (`dinput8.dll` in the game folder).
- Both players on the **same mod version** (the mod warns you if versions differ).

## Installation

1. Install REFramework (copy `dinput8.dll` into the game folder, next to `re4.exe`).
2. Close the game.
3. Extract the mod zip **into the game folder**, replacing files when asked. You should end up with:
   - `reframework/autorun/re4coop_br.lua`
   - `reframework/plugins/re4coopbr_rede.dll`
   - `reframework/data/RE4CoopBR/lang/en.json`
4. Start the game. Look for **PLAY TOGETHER** below *Main Story* in the main menu.

## How to play

1. **Host:** PLAY TOGETHER → *Create lobby and invite* → pick your friend on Steam.
2. **Guest:** accept the Steam invite (the game opens and joins the lobby), then mark **READY**.
3. **Host:** choose *New game* (and difficulty) or *Continue (co-op save)*, then **START GAME**.

| Key | Action |
|---|---|
| F8 | Open or close the co-op panel (connection, options, chat, diagnostics) |
| F5 | Go to your partner (or to the door they used) |
| F6 | Bring your partner to you |
| F7 | Join your partner's cutscene (when the prompt appears) |

**Language:** F8 → Connection → *Idioma / Language* (Automatic, Português, English).

## Known limitations

- Pausing or opening the inventory can desync for a few seconds.
- Items, drawers, crates and files are **not** shared: each player picks up their own.
- Cutscenes play separately for each player. Watching together is planned.
- Both players play as Leon for now.

Problems? Check F8 → Diagnostics, `reframework/data/RE4CoopBR/rede.log` and `re2_framework_log.txt`, and open an issue.

## Translating

Copy `reframework/data/RE4CoopBR/lang/en.json` to a new file named after the language (for example `es.json`). Then translate the values on the right and leave the Portuguese keys on the left as they are. `textos` holds full texts or templates (`%s`, `%d`, `%.1f`); `trechos` holds sentence pieces the code glues together. Run `python scripts/extrair_textos.py --faltando --lang es` to list missing texts.

## Building (developers)

See [docs/DESENVOLVIMENTO.md](docs/DESENVOLVIMENTO.md).

---

## Português

**Co-op online para 2 jogadores no Resident Evil 4 Remake (PC).** Cada jogador roda o próprio jogo (sem atraso nos controles), e o mod sincroniza os dois mundos pela Steam.

### O que tem

- **Convite pela Steam**, sem IP e sem abrir porta.
- **"JOGAR JUNTO" no menu principal do jogo.** Abre uma sala no estilo do RE4, com cartões de anfitrião e convidado, PRONTO, Novo jogo ou Continuar, e dificuldade.
- **Início automático** nos dois jogos.
- **Save co-op (slot 20)**, gravado nos dois PCs sempre que alguém salva.
- **O parceiro aparece no seu mundo**, com roupa, armas, clarão e som dos tiros.
- **Inimigos sincronizados:** dano, morte, dono por proximidade e animação.
- **Eventos da história e objetos sincronizados:** torre da vila, portas, alavancas, escadas.
- **Anti-preso**, com F5 (ir até o parceiro), F6 (trazer o parceiro) e marcador da porta.
- **Idioma automático:** segue o idioma do jogo (português ou inglês).

### Instalação

1. Instale o [REFramework](https://github.com/praydog/REFramework-nightly/releases) (o `dinput8.dll` vai na pasta do jogo).
2. Feche o jogo.
3. Extraia o zip do mod **dentro da pasta do jogo**, substituindo os arquivos.
4. Abra o jogo: **JOGAR JUNTO** fica logo abaixo de *História principal*.

### Como jogar

1. **Anfitrião:** JOGAR JUNTO → *Criar sala e convidar* → escolha o amigo na Steam.
2. **Convidado:** aceite o convite e marque **PRONTO**.
3. **Anfitrião:** escolha *Novo jogo* ou *Continuar (save co-op)* e aperte **INICIAR PARTIDA**.

Teclas: **F8** abre o painel, **F5** leva você até o parceiro, **F6** traz o parceiro até você. Para trocar o idioma: F8 → Conexão → *Idioma / Language*.

## License

MIT. See [LICENSE](LICENSE). Resident Evil 4 is © CAPCOM; this project is a fan-made mod and is not affiliated with CAPCOM. It ships no game files.

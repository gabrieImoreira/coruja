# coruja

Um app para Mac que **grava suas reuniões e já transcreve em português**,
tudo no seu computador — nada é enviado para a internet. Feito para quem
usa Google Meet ou Microsoft Teams pelo Chrome e quer um registro em texto
de cada conversa, sem depender de um serviço pago.

## O que ele faz

- **Grava** o que você fala e o que a outra pessoa fala, ao mesmo tempo.
- **Transcreve automaticamente** para texto em português, assim que a
  gravação termina.
- **Detecta sozinho** quando você entra numa reunião do Meet ou Teams pelo
  Chrome, e pergunta se quer gravar.
- **Guarda tudo localmente** no seu Mac, em `~/Recordings` — nada sobe pra
  nuvem, nenhum servidor externo envolvido.
- Tem uma janela própria para ver a lista de reuniões gravadas, ler a
  transcrição, ouvir o áudio e apagar gravações que não quiser mais.

Não gera resumo automático (ainda) — só a transcrição, palavra por palavra,
com marcação de quem falou o quê.

## Como instalar

1. Vá em [Releases](https://github.com/gabrieImoreira/coruja/releases) e
   baixe o arquivo `coruja-<versão>-macos.zip` mais recente. É um arquivo
   grande (~1.4 GB) porque já vem com o modelo de transcrição embutido —
   depois de instalado, a coruja transcreve sem precisar baixar nada nem
   depender de internet.
2. Descompacte e arraste o `Coruja.app` para a pasta **Aplicativos**.
3. **Só na primeira vez**: como este app não passou pelo processo pago de
   certificação da Apple, o macOS vai bloquear a abertura com um aviso de
   "não é possível verificar" / "mover para o lixo" — nem clique-direito →
   Abrir resolve mais isso nas versões recentes do macOS (testado). Pra
   liberar, abra o app **Terminal** (Cmd+Espaço, digite "Terminal") e
   cole:
   ```sh
   xattr -cr /Applications/Coruja.app
   ```
   Depois disso, o app abre normalmente com duplo-clique, como qualquer
   outro. (Se preferir tentar sem Terminal: Configurações do Sistema →
   Privacidade e Segurança → role até a seção de segurança → **Abrir
   Mesmo Assim**, se a opção aparecer — mas o comando acima é o único
   caminho confirmado.)
4. Na primeira gravação, o macOS vai pedir permissão de **Microfone** e de
   **Gravação de Áudio do Sistema** — aceite as duas, senão a gravação sai
   muda.

Pronto, é só isso. Se quiser que o app abra sozinho sempre que ligar o Mac:
System Settings → General → Login Items → adicione o `Coruja.app`.

## Como usar

Depois de instalado, a coruja fica rodando discretamente com um ícone na
barra de menu (topo da tela) e outro no Dock.

**Pra gravar uma reunião**, qualquer uma dessas opções funciona:
- Clique no ícone da coruja (barra de menu ou Dock) → **Iniciar gravação**
- Aperte **⌃⌥⌘R** (Control + Option + Command + R) no teclado, de qualquer
  lugar
- Se a reunião for pelo Chrome (Google Meet ou Teams), a coruja identifica
  sozinho e pergunta **"Gravar?"** — é só clicar em **Gravar**

**Pra parar**, é a mesma coisa: clique de novo, ou aperte ⌃⌥⌘R, ou (se a
reunião foi detectada automaticamente) feche a aba do Chrome — a gravação
para sozinha.

Quando a gravação termina, a transcrição começa automaticamente e uma
notificação avisa quando estiver pronta. Para ver, ouvir ou apagar
qualquer gravação, abra a janela da coruja clicando no ícone do Dock.

### Onde ficam os arquivos

Cada gravação vira uma pasta em `~/Recordings/`, nomeada só com a data e
hora (ex: `2026-08-01 21h50`). Dentro dela, dois arquivos que você pode
abrir direto:

| Arquivo | O que é |
|---|---|
| `audio.m4a` | a gravação da reunião, num formato que toca em qualquer player |
| `transcript.md` | a transcrição em texto, com hora e quem falou cada trecho |

(Existem outros arquivos internos na pasta, começando com ponto — o
Finder já esconde eles por padrão. São só apoio técnico do app, não
precisa mexer.)

---

## Detalhes técnicos

*A partir daqui é conteúdo para quem quiser entender ou mexer no código —
não é necessário pra usar o app.*

Fork de [digimata/quill](https://github.com/digimata/quill), trocando o
engine de transcrição padrão para **Whisper (WhisperKit)** — o engine
original do quill (Parakeet) só transcreve inglês.

**Requer:** macOS 15+ (Core Audio process taps para áudio do sistema — sem
driver virtual, sem kernel extension). Apple Silicon recomendado.

### Por que existe um ícone permanente no Dock

O quill original não tem ícone no Dock, só na barra de menu. A coruja
mantém um ícone fixo no Dock por um motivo concreto, descoberto na prática:
o macOS pode descartar silenciosamente o ícone de terceiros na barra de
menu quando ela está cheia — sem aviso, sem seta de "mais ícones" — e
também sobrepõe seu próprio selo de microfone em uso no ícone de apps que
gravam áudio, o que pode parar de repassar cliques pro app por baixo. Os
dois foram observados ao vivo durante o desenvolvimento. O ícone do Dock
não sofre nenhum dos dois problemas.

### ⌃⌥⌘R — iniciar/parar de qualquer lugar

O atalho **⌃⌥⌘R** funciona independente do que está visível na tela, com
notificação confirmando início/fim. Útil quando a barra de menu e o Dock
estão temporariamente fora de alcance (ex: um app em tela cheia).

Na primeira vez, pede permissão de **Input Monitoring** (System Settings →
Privacy & Security → Input Monitoring) — necessária pra qualquer atalho
de teclado global.

### Detecção automática de reunião (Google Meet / Teams no Chrome)

A coruja varre as abas abertas do Chrome a cada 5 segundos procurando uma
URL de reunião do Google Meet ou Microsoft Teams. Ao encontrar, mostra um
aviso no canto superior direito — **Gravar** / **Ignorar**. Se aceitar, a
gravação para sozinha quando aquela aba específica fecha ou muda de URL.

Não existe API pública do macOS para "há uma reunião em andamento", então
isso é uma heurística por padrão de URL — pode disparar na tela de espera
antes de entrar na call, não só numa call já em andamento. Por isso a
detecção só mostra um aviso dispensável, nunca grava sozinha sem
confirmação.

Na primeira detecção, pede permissão de automação **"coruja quer controlar
o Google Chrome"** (System Settings → Privacy & Security → Automation) —
sem ela, a detecção simplesmente não funciona (sem erro, sem travar).

Uma gravação iniciada manualmente (menu, Dock, ou ⌃⌥⌘R) nunca é parada
automaticamente por uma aba do Chrome fechando — só uma gravação iniciada
*pelo aviso de reunião* fica vinculada ao ciclo de vida daquela reunião.

### Build a partir do código

```sh
cd coruja
./scripts/build-app.sh        # -> .build/Coruja.app, .build/coruja-<versão>-macos.zip
```

O script baixa o modelo Whisper (se ainda não estiver em cache) e o
empacota dentro de `Coruja.app/Contents/Resources/whisperkit-model` — por
isso a primeira execução do script pode demorar alguns minutos e o
`.zip` final sai com ~1.4 GB. Rodadas seguintes reusam o modelo já
cacheado em `~/Documents/huggingface`.

Ou, para instalar como binário de linha de comando / LaunchAgent:

```sh
cd coruja
swift build -c release
sudo cp .build/release/coruja /usr/local/bin/coruja
coruja install --launch-at-login   # opcional — roda em segundo plano no login
```

### Estrutura completa da pasta de sessão

Além de `audio.m4a` e `transcript.md` (os dois arquivos visíveis),
cada pasta guarda arquivos ocultos (prefixo `.`) usados internamente:
`.mic.caf`/`.system.caf` (as duas trilhas brutas, mantidas para permitir
re-transcrição), `.meta.json` (timestamps/offsets), `.transcript.json`
(a transcrição em formato de máquina), `.transcribe.log`. Duas trilhas
brutas de propósito: modelos de fala funcionam melhor com áudio de fonte
única, e mic-vs-sistema já dá diarização gratuita — `me` vs `them` sem
nenhum modelo de identificação de locutor (ver Gotchas abaixo pros limites
disso). CAF de propósito nas trilhas brutas: ao contrário de m4a, não
precisa de finalização — se o processo morrer no meio da reunião, tudo já
escrito continua legível; `audio.m4a` é gerado depois, uma vez, durante a
transcrição (ver `AudioMixer.swift`).

### Transcrição

Engine padrão é **Whisper large-v3-turbo** via
[WhisperKit](https://github.com/argmaxinc/argmax-oss-swift), multilíngue,
decodificando em português por padrão (`transcription.language`, padrão
`"pt"`). No `Coruja.app` baixado em [Releases](https://github.com/gabrieImoreira/coruja/releases)
o modelo (~1.5 GB) já vem embutido, sem download nem internet
necessários. Rodando via `swift build` / CLI (sem o `.app`), o modelo
baixa uma vez na primeira transcrição; `coruja doctor` avisa se já está
em cache.

**Parakeet TDT 0.6B v2** (só inglês, via
[FluidAudio](https://github.com/FluidInference/FluidAudio), ~600 MB, mais
rápido) fica disponível como alternativa opcional — `"engine": "parakeet"`
no config.

Cada trilha é transcrita separadamente, ajustada pelo offset de início, e
combinada por timestamp. Fila serial — dá pra gravar de novo enquanto a
última ainda transcreve. Jobs pendentes retomam ao reabrir o app.

O engine fica atrás de um protocolo pequeno (`TranscriptionEngine`), então
adicionar um terceiro é um arquivo independente — ver `WhisperEngine.swift`
/ `ParakeetEngine.swift`.

#### Precisão vs. transcrição em nuvem (ex: coconote)

Whisper local faz uma transcrição **sólida** em português pra áudio limpo
e de fala única — mas é realista esperar mais erros em nomes próprios,
jargão e fala ruidosa/com sotaque do que um serviço em nuvem rodando um
modelo maior e/ou passando por um LLM depois. Em troca: **custo zero por
reunião** e **zero áudio saindo da máquina**.

### Config

Opcional, em `~/.config/coruja/config.json`:

```json
{
  "recordings_dir": "~/Recordings",
  "transcription": { "enabled": true, "engine": "whisper", "language": "pt" },
  "on_stop": "meu-hook"
}
```

- `recordings_dir` — onde as sessões ficam. Ordem: flag `--out` > config >
  `~/Recordings`.
- `transcription.enabled` — `false` pra só gravar, sem transcrever.
- `transcription.engine` — `"whisper"` (padrão, multilíngue) ou
  `"parakeet"` (só inglês, mais rápido/leve).
- `transcription.language` — código ISO-639-1 pro decoder do Whisper.
  Padrão `"pt"`. `"auto"` deixa o Whisper detectar por segmento (útil pra
  reuniões multi-idioma). Ignorado pelo `parakeet`.
- `mic_voice_processing` — cancelamento de eco da Apple no microfone
  (padrão desligado). Ative se gravar reuniões pela caixa de som (não
  fone), pra evitar que o áudio que sai da caixa volte a entrar no
  microfone e seja transcrito duas vezes.
- `on_stop` — comando de shell disparado com a pasta da sessão como
  argumento, depois que a transcrição for escrita.

### CLI

```sh
coruja                        # roda o daemon (^C pra sair)
coruja run --out <pasta>      # raiz de gravações customizada
coruja doctor                 # checa permissões, pasta, modelos
coruja install --launch-at-login
coruja install --uninstall
```

### Stack

- **Swift** — target executável único via SPM
- **Core Audio process tap** (`AudioHardwareCreateProcessTap`, macOS 14.2+)
  — captura de áudio do sistema via aggregate device privado
- **AVAudioEngine** — captura do microfone
- **AVAudioFile** — encode AAC em streaming pra CAF
- **AVFoundation composition/export** — mixagem das duas trilhas em
  `audio.m4a` (`AudioMixer.swift`)
- **WhisperKit / Whisper large-v3-turbo** — transcrição on-device (padrão)
- **FluidAudio / Parakeet** — transcrição on-device (opcional, só inglês)
- **NSStatusItem** — ícone da barra de menu
- **SwiftUI (`NSHostingView`) + AppKit** — a janela de notas
- **AppleScript / osascript** — leitura das abas do Chrome
  (`MeetingDetector.swift`)
- **UserNotifications** — notificações do sistema

### Gotchas

- Um tap global grava *tudo* que o Mac toca — som de notificação, música,
  tudo. Evite tocar música durante reuniões.
- Se as gravações saírem mudas, confira System Settings → Privacy &
  Security → Screen & System Audio Recording.
- **Diarização quebra sem fone de ouvido do lado de "quem fala".** A
  separação mic/sistema só funciona limpa quando seu microfone escuta *só*
  você — na caixa de som (não fone), o áudio tocado vaza acusticamente de
  volta pro mic, e as duas trilhas capturam quase a mesma coisa,
  duplicando o texto uma vez como "me" e outra como "them". Chamadas reais
  de duas pessoas por fone não sofrem disso; testar a coruja tocando um
  vídeo/música na caixa em vez de uma call de verdade mostra esse efeito.
  Correção: use fone, ou ative `mic_voice_processing: true` no config.
- O binário embute seu Info.plist (`__TEXT,__info_plist`) pra que o TCC
  atribua permissões à coruja mesmo rodando como LaunchAgent sem bundle.

### Relação com o upstream

É um fork, não substituto direto — binário, identificador de bundle
(`com.gabrieImoreira.coruja`), caminho de config e engine padrão divergem
do quill pra que os dois coexistam na mesma máquina. Licença MIT, igual ao
upstream (ver `LICENSE`).

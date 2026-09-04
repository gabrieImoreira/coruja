# Ideias do Coconote pra avaliar pra coruja

Levantamento feito navegando o Coconote (coconote.app, by Quizlet) com uma
conta real cheia de reuniões de trabalho. Isso é uma lista de candidatos pra
discutir, **nada aqui foi implementado ou aprovado** — cada item que for pra
frente passa pelo processo normal (brainstorming → design → plano) antes de
qualquer código.

Coconote é uma ferramenta de estudo (Quizlet) esticada pra reuniões — tem
bastante coisa voltada a aluno (quiz, flashcards, jogos de estudo, podcast)
que não faz sentido pro público da coruja (profissional gravando reunião de
trabalho, uso local, "nada sai da máquina" por padrão). A lista abaixo já
filtra por esse critério.

## Vale a pena considerar (bom encaixe com a coruja)

1. **Timestamp clicável na transcrição, pula o áudio pro ponto exato**
   Cada trecho da transcrição no Coconote tem um "▶ 0:03" que toca o áudio
   dali. A coruja já mostra o timestamp como texto (`NotesRootView.
   transcriptParagraph`) e já tem o player (`AudioPlayerModel`) — só falta
   ligar um no outro. Baixo risco, alto valor de usabilidade.

2. **Agrupar trechos consecutivos do mesmo falante num só parágrafo**
   Hoje cada segmento do Whisper vira um parágrafo próprio com o rótulo do
   falante repetido, mesmo quando é a mesma pessoa falando sem interrupção.
   O Coconote junta tudo até trocar de falante. Deixa a leitura muito mais
   limpa. Também baixo risco.

3. **Itens de ação com urgência, não só prazo livre**
   O Coconote classifica e ordena os itens de ação por urgência (ASAP, essa
   semana, próxima reunião) além do responsável. Hoje `SummaryEngine.
   ActionItem` só tem `item/responsavel/prazo` livre. Dá pra evoluir o
   schema e o prompt pra também extrair uma categoria de urgência e ordenar
   por ela.

4. **Upload de áudio já gravado** (não só gravar ao vivo)
   Coconote aceita subir um áudio existente. `TranscriptionCoordinator` já
   processa qualquer arquivo de áudio — o que falta é só a entrada na UI
   (um "Adicionar gravação" que copia o arquivo pra dentro de uma pasta de
   sessão nova e enfileira pra transcrição). Reaproveita quase tudo que já
   existe.

## Merece design antes de codar (não é bounded)

5. **"Chat with this note" — perguntar coisas sobre UMA reunião específica**
   RAG scoped ao transcript de uma reunião ("o que a gente decidiu sobre
   X?"). É uma feature nova de verdade (mais chamadas à OpenAI, um jeito de
   selecionar o trecho relevante do transcript pra mandar no prompt, UI de
   chat). Encaixa bem na filosofia da coruja (só ativa se a chave OpenAI já
   tiver configurada) mas precisa passar pelo brainstorming antes.

6. **Exportar/compartilhar a ata/resumo** (Coconote tem "Share or export")
   Hoje a coruja só tem "Abrir pasta" e "Copiar transcrição". Exportar a
   ata como PDF, ou um link somente-leitura, é maior — precisa decidir
   formato e se envolve qualquer coisa saindo da máquina (o link, se
   existir, contraria o "nada sai da máquina" a menos que seja bem
   sinalizado, igual ao aviso do LLM pass hoje).

## Provavelmente não vale (não combina com o produto)

- Quiz, flashcards, slide deck, jogos de estudo, podcast — feature de
  estudante, não de reunião de trabalho.
- Chat global "pergunte sobre todas as suas notas" — poderoso, mas exige
  um índice/embedding sobre todo o histórico de reuniões; é um projeto
  próprio, não um ajuste.
- "Generate note visual" / mindmap — bonito, mas não ficou claro que valor
  real agrega pra ata de reunião (não explorei a fundo, pode reavaliar).
- Pastas/organização de notas — a coruja hoje é uma lista simples por dia;
  pode fazer sentido pra quem grava muita reunião, mas é baixa prioridade
  até isso doer de verdade.

## O que não deu tempo de explorar

Não cheguei a abrir: Configurações do Coconote, o chat global "Ask
anything about your notes" na tela inicial, o resultado real de "Generate
note visual"/"View mindmap"/"Podcast", nem o fluxo de pastas. Se algum dos
itens acima virar prioridade, vale voltar e olhar com mais calma antes de
desenhar.

# Instagram direto: plugin nativo `InstagramShare`

Decisão do dono (21/10/2026): na tela "Compartilhar pílula", o formato escolhido
leva direto ao Instagram, e a mesma tela ganha a linha "Outros apps" (WhatsApp e o
resto). O site (repo `diariamente`) desenha o PNG; este repo entrega a ponte nativa.

## Por que nativo

O JavaScript do Capacitor não grava as chaves de pasteboard que o Instagram lê, não
salva nas Fotos e só abre a folha do iOS com um toque recente. Por isso existe um
plugin local, sem dependência externa:

| Item | Valor |
|---|---|
| Pasta | `plugins/instagram-share/` |
| Pacote npm | `diariamente-instagram-share` (`file:./plugins/instagram-share` no `package.json`) |
| Pod | `DiariamenteInstagramShare` (nome que o `@capacitor/cli` deriva do pacote) |
| Classe nativa | `InstagramSharePlugin` (`@objc(InstagramSharePlugin)`, vai para o `packageClassList`) |
| Nome no JS | `InstagramShare` (`window.Capacitor.Plugins.InstagramShare`) |
| Disponibilidade | `window.Capacitor.isPluginAvailable('InstagramShare')` |

## Contrato (site e plugin seguem à risca)

| Método | Entrada | Resposta |
|---|---|---|
| `disponivel()` | nada | `{ stories, feed }` (booleanos; `canOpenURL` de `instagram-stories://share` e `instagram://app`) |
| `stories()` | `{ imagem, appId }` | `{ aberto, motivo? }` com `sem_instagram`, `imagem_invalida`, `app_id_invalido`, `falha_ao_abrir` |
| `feed()` | `{ imagem }` | `{ aberto, motivo? }` com `sem_instagram`, `sem_permissao`, `imagem_invalida`, `falha_ao_salvar`, `falha_ao_abrir` |
| `sistema()` | `{ imagem, nomeArquivo, texto? }` | `{ concluido, destino? }` (`destino` = tipo da atividade iOS, só quando concluiu) |

- `imagem` é PNG em base64 sem prefixo `data:` (o prefixo é tolerado). `appId` é o
  Facebook App ID, só dígitos.
- Os casos acima RESOLVEM a Promise. Rejeição só para erro inesperado; hoje isso
  acontece apenas em `sistema`, com estes códigos:
  - `imagem_invalida`: o base64 não abre como imagem.
  - `falha_ao_gravar`: o PNG temporário não foi gravado.
  - `sem_tela`: o app não tem tela para apresentar a folha.
  - `falha_ao_apresentar`: a folha não abriu. O UIKit recusou a apresentação (tela do
    topo fora da janela, ou já apresentando outra) e também recusou a nova tentativa,
    feita 0,4 s depois com o topo recalculado. O PNG temporário é apagado na hora.

  O site trata rejeição como "use o caminho de antes".
- Em `sistema`, `concluido: false` quer dizer só que a pessoa fechou a folha (ou desistiu
  dentro do app escolhido). Uma folha que não abriu nunca responde assim: rejeita com
  `falha_ao_apresentar`. Exceção: um segundo `sistema` com uma folha já na tela responde
  `concluido: false` na hora (toque duplo; a folha aberta responde pela primeira chamada).
- Tudo que mexe em UIKit roda na main thread. Nada de log com conteúdo.

## O que cada caminho faz

- **Stories (oficial da Meta).** Põe o PNG no pasteboard na chave
  `com.instagram.sharedSticker.backgroundImage`, com validade de 5 minutos, e abre
  `instagram-stories://share?source_application=<App ID>`. Sem App ID o Instagram
  mostra erro; por isso o plugin recusa App ID vazio ou com letras.
- **Feed (atalho sem documentação oficial).** Pede a permissão "só adicionar" das
  Fotos, salva o PNG (os bytes que o site desenhou, sem recodificar em JPEG) e abre
  `instagram://library?LocalIdentifier=<id>`. O Instagram nem sempre respeita o
  identificador. Quando ele abre, mas não na foto, a imagem já está nas Fotos e é a
  mais recente da galeria do Instagram. Com `aberto: true` o site não faz mais nada; a
  volta dele vale só para `aberto: false` (cai em `sistema`). Se o atalho falhar com
  frequência, desliga-se `INSTAGRAM_FEED_DIRETO` no site, sem versão nova na loja. A
  imagem fica salva nas Fotos da pessoa (é assim que esse caminho funciona).
- **Folha nativa (`sistema`), usada como queda.** O site chega aqui quando Stories ou
  Feed respondem `aberto: false` ou dão erro, e no Feed com `INSTAGRAM_FEED_DIRETO`
  desligado. Grava o PNG numa pasta temporária com o nome pedido, abre a folha nativa
  do iOS (popover centralizado no iPad) e resolve quando ela fecha de vez. Não depende
  de um toque recente no JavaScript. Com outra tela entrando ou saindo, espera a
  transição acabar antes de apresentar (no meio dela, o UIKit guarda o pedido para
  depois e a folha pareceria recusada). Se o UIKit recusar, tenta de novo uma vez 0,4 s
  depois e, se ainda assim não abrir, rejeita com `falha_ao_apresentar`.
  O arquivo é apagado 60 s depois de a folha fechar; sobras de sessões encerradas são
  apagadas ao abrir o app.
- **Outros apps (só no site).** A última linha da folha do site segue o fluxo de
  sempre: `navigator.share` do WebKit com o cartão 9:16
  (`diariamente-pilula-<id>-story.png`). Não chama o plugin. Esse fluxo depende do
  toque recente, e no app iOS o último recurso dele (o download por `<a download>` com
  `blob:`) não mostra nada: o Capacitor 7 trata o `blob:` como navegação externa. Por
  isso a queda do Instagram é a folha nativa, e não o fluxo de sempre.

## Quando o modo liga

O App ID do app da Meta do Diariamente já está no site (`INSTAGRAM_APP_ID =
'1680166497455471'` em `public/index.html`, repo `diariamente`). O modo Instagram só
aparece em app com o plugin, ou seja, da 1.0.6 em diante: sem ele,
`isPluginAvailable('InstagramShare')` é falso e a folha é a de antes. Por isso publicar
o site antes de a 1.0.6 estar na loja não muda nada para quem usa a 1.0.5.

Como o `server.url` do app é a produção, o TestFlight da 1.0.6 usa o site que estiver
publicado. Antes de publicar o site com o caminho direto, a 1.0.6 se comporta como a
1.0.5; depois, o modo Instagram liga na hora para quem tem a 1.0.6.

Para desligar sem versão nova na loja: esvaziar `INSTAGRAM_APP_ID` no site (desliga tudo)
ou pôr `INSTAGRAM_FEED_DIRETO = false` (só o atalho do Feed, que passa a abrir a folha
nativa). Android (TWA) e navegador ficam como estão.

## Como entra no build

`npm install` cria o link `node_modules/diariamente-instagram-share`, e o `npx cap sync ios`
(os dois já rodam no Codemagic antes do `pod install`) acrescenta ao Podfile
`pod 'DiariamenteInstagramShare', :path => '../../plugins/instagram-share'` e ao
`ios/App/App/capacitor.config.json` a classe `InstagramSharePlugin`. Esses dois
arquivos versionados não são editados à mão, mesmo padrão adotado com o Haptics:
o CI regenera.

Info.plist: `LSApplicationQueriesSchemes` (`instagram-stories`, `instagram`) e
`NSPhotoLibraryAddUsageDescription`. O texto da permissão é neutro, porque o mesmo
pedido aparece quando a pessoa toca "Salvar Imagem" numa folha de compartilhar, onde
o Instagram não tem nada a ver: "O Diariamente salva a imagem da pílula nas suas Fotos
para você publicar ou guardar."

**Pendência para o dono decidir antes da 1.0.6: o pedido de permissão em espanhol.**
Hoje ele existe só em português, e quem usa o app em espanhol vê o aviso das Fotos em
português (a descrição do Feed em espanhol já fala em "Guarda la imagen en tus Fotos").
O binário declara só `pt-BR`/`pt` de propósito (passo "Forcar idioma pt-BR" do
`codemagic.yaml`), e o `pt-BR.lproj/InfoPlist.strings` que esse passo gera nem entra no
`project.pbxproj`. Para ter espanhol:

1. Criar `ios/App/App/es.lproj/InfoPlist.strings` com
   `"NSPhotoLibraryAddUsageDescription" = "Diariamente guarda la imagen de la píldora en tus Fotos para que la publiques o la conserves.";`
   e registrá-lo nos recursos do target App (grupo de variantes `InfoPlist.strings` no
   `project.pbxproj`).
2. Acrescentar `es` ao `knownRegions` do projeto e ao `CFBundleLocalizations` do
   Info.plist e do passo "Forcar idioma" do `codemagic.yaml`, que reescreve essa lista.

Efeito colateral: com `es` declarado, os textos do sistema dentro do app (folha de
compartilhar, alertas, menus de copiar e colar) passam para espanhol nos aparelhos em
espanhol. Por isso é decisão do dono; até lá, fica só em português.

## Roteiro de teste no TestFlight (build 1.0.6)

Rótulos como a pessoa vê na folha do site: "Instagram Stories", "Instagram Feed
(retrato)", "Instagram Feed (quadrado)" e "Outros apps". A folha de antes tem "Stories",
"Feed (retrato)" e "Feed (quadrado)".

**Regressão.**

1. a. *1.0.6 antes de publicar o site com o caminho direto* (se o TestFlight sair antes):
   Compartilhar pílula funciona exatamente como na 1.0.5.
   b. *1.0.5 da loja depois de publicar o site:* a folha de antes, com as 3 linhas, que
   abre a folha do iOS como sempre (a 1.0.5 não tem o plugin).
   c. *1.0.6 sem o Instagram instalado, depois de publicar o site:* a folha mostra as 3
   linhas de antes, sem "Outros apps"; escolher abre a folha do iOS, como na 1.0.5.

**Depois de publicar o site, em iPhone com Instagram logado.**

2. **Instagram Stories.** Abre o editor de Stories do Instagram com a pílula de fundo,
   sem passar pela folha do iOS.
3. **Aviso de colar do iOS.** Na primeira vez o iOS pergunta se o Instagram pode
   colar do Diariamente. "Permitir": a imagem aparece. "Não permitir": anotar o que
   o Instagram mostra e conferir que voltar ao Diariamente não trava a tela.
4. **Instagram Feed (retrato), permissão aceita.** Aparece o pedido "Adicionar às
   Fotos" com o texto em português; aceitar. A imagem vai para as Fotos (em Fotos, o
   painel de informações da imagem mostra PNG) e o Instagram abre no fluxo de nova
   publicação com ela. Se abrir sem a foto, conferir que ela é a primeira da galeria do
   Instagram e anotar a versão do Instagram.
5. **Instagram Feed (quadrado).** Como no passo 4, com a imagem 1:1 (o pedido de
   permissão não aparece de novo).
6. **Outros apps.** É a folha do iOS aberta pelo site (`navigator.share` do WebKit), não
   a do plugin. Vem com o cartão 9:16 e o nome `diariamente-pilula-<id>-story.png`.
   Testar WhatsApp e Mensagens.
7. **Folha nativa do plugin (`sistema`), pela queda.** Ajustes > Diariamente > Fotos >
   Nenhum e escolher "Instagram Feed (retrato)": o Instagram não abre, nada é salvo, e
   abre a folha nativa com o PNG `diariamente-pilula-<id>-feed.png` (o nome com `-feed`
   mostra que é a do plugin). Nela:
   - WhatsApp e Mensagens recebem a imagem;
   - fechar a folha sem escolher: nada mais acontece e a tela não trava;
   - abrir Mail e cancelar dentro dele (se a folha voltar, escolher outro app deve
     funcionar);
   - "Salvar Imagem": com as Fotos em Nenhum o iOS não salva; anotar o que aparece e
     conferir que o app não trava.

   Depois, voltar as Fotos para "Adicionar Fotos". Outro caminho até a folha nativa,
   sem mexer na permissão: `INSTAGRAM_FEED_DIRETO = false` no site publicado (aí o
   "Salvar Imagem" pede a permissão das Fotos com o texto neutro).
8. **iPad.** "Instagram Stories" e os dois "Instagram Feed" como no iPhone. A folha
   nativa do passo 7 abre como popover no centro da tela, sem seta e sem travar;
   repetir nela fechar sem escolher e "Salvar Imagem". "Outros apps" abre a folha do
   WebKit.

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
para você publicar ou guardar." Em espanhol (`es.lproj/InfoPlist.strings`): "Diariamente
guarda la imagen de la píldora en tus Fotos para que la publiques o la conserves."

### Espanhol no binário (decisão do dono, 26/10/2026)

A pendência do pedido de permissão em espanhol foi resolvida junto com um pedido maior
do dono: quem é da América Latina e baixa o app precisa ver as telas iniciais em
espanhol. A maior parte disso é do site (repo `diariamente`: `escolherIdiomaInicial` e
`TZ_PAIS` no `public/index.html`, regra completa no `docs/I18N.md` de lá). Antes do
login, sem idioma salvo e sem `?lang=`, vale o primeiro `es` ou `pt` da lista de idiomas
do navegador. No app iOS só um `es` vale: o WKWebView só reporta um idioma que o app
declara, e diz português com o iPhone em português, em inglês ou em qualquer idioma que
o binário não declara. Sem `es`, decide o fuso do aparelho: país de língua espanhola
(México, Argentina, Chile, Colômbia, Espanha etc.), espanhol; os demais, português. Por
isso, depois do deploy do site, o build 21 (binário só em `pt-BR`/`pt`) já abre as telas
iniciais em espanhol nos fusos da América Latina e da Espanha. O build 22 da 1.0.6
acrescenta o espanhol do próprio iPhone (vale em qualquer fuso) e os textos do sistema:

| Item | Valor |
|---|---|
| Idioma principal | `pt-BR` (`CFBundleDevelopmentRegion` no Info.plist e `developmentRegion` no projeto) |
| `CFBundleLocalizations` | `pt-BR`, `pt` e `es` (inglês continua fora) |
| Textos do Info.plist por idioma | `ios/App/App/pt-BR.lproj/InfoPlist.strings` e `ios/App/App/es.lproj/InfoPlist.strings`, versionados (nome do app e permissão das Fotos) |
| Projeto Xcode | `scripts/add_app_localizations.rb` (gem `xcodeproj`, idempotente): `developmentRegion` pt-BR, `knownRegions` (`pt-BR`, `es`, `Base`) e o grupo de variantes `InfoPlist.strings` em Resources do App. Sem esse grupo as pastas `.lproj` não entram no `.app` |
| CI | o passo "Forcar idioma pt-BR no binario (principal) e declarar espanhol" grava o Info.plist e roda o script; "Conferir idiomas dentro do .ipa" para o build se o `.ipa` sair sem `pt-BR.lproj` ou `es.lproj` |
| Tela sem conexão | `www/error.html` (bundle) segue a regra do site para o iOS (um `es` na lista vale; sem ele, o fuso): "Sin conexión" e "Intentar de nuevo" |

Efeito (com o site publicado):

- iPhone em espanhol (de qualquer país): o app roda em espanhol. O `navigator.language`
  começa com `es`, o site abre as telas iniciais em espanhol, e as folhas do sistema
  (compartilhar, copiar e colar, alertas) e o pedido de permissão das Fotos saem em
  espanhol.
- iPhone em português, ou em qualquer outro idioma sem localização (inglês, francês
  etc.): o binário cai no `pt-BR`, como antes, e as folhas do sistema e o pedido das
  Fotos saem em português. As telas iniciais seguem o fuso do aparelho: no fuso de um
  país de língua espanhola, espanhol; nos demais, português.
- Efeito aceito do fuso: um brasileiro com o iPhone em português que mora no México, na
  Argentina ou na Espanha vê as telas iniciais em espanhol e, se ativar a conta ali, a
  conta nasce em espanhol até ele trocar em Conta. Ver `docs/I18N.md` do repo
  `diariamente`.
- Lista de idiomas do iPhone com um idioma sem localização na frente (por exemplo
  English, Español, Português): o iOS escolhe o primeiro da lista que o app tem, e o app
  abre em espanhol, inclusive as telas iniciais.
- O iOS passa a mostrar Ajustes > Diariamente > Idioma preferido, quando o iPhone tem
  mais de um idioma na lista de Ajustes > Geral > Idioma e Região. Dá para usar o
  Diariamente em espanhol num iPhone em português, e o contrário.
- Depois do login vale o idioma da conta (`users.locale`). O site guarda esse idioma no
  aparelho sempre que a conta abre (login, ativação ou sessão salva), e o guardado vence
  o idioma do iPhone e o fuso até a pessoa sair da conta ou a sessão vencer (aí o login
  segue a regra do aparelho, como as telas iniciais). Uma conta em português num
  iPhone em espanhol mostra o app em português e as folhas do sistema em espanhol (o
  site não muda o idioma do sistema). A tela sem conexão não enxerga o idioma guardado
  (roda em outra origem) e segue a regra do iPhone e do fuso.
- A lista de idiomas da página do app na loja vem do binário: passa a ter português e
  espanhol.

Para acrescentar outro idioma no futuro: criar `ios/App/App/<idioma>.lproj/InfoPlist.strings`
e pôr o idioma em `LOCALES` no script, no `CFBundleLocalizations` (Info.plist e passo do
`codemagic.yaml`) e nos laços `for loc in` dos dois passos de idioma do `codemagic.yaml`.
O site também precisa falar o idioma: hoje ele só tem `pt-BR` e `es`.

## Roteiro de teste no TestFlight (1.0.6)

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
   Fotos" com o texto em português (no iPhone em espanhol, em espanhol: passo 11);
   aceitar. A imagem vai para as Fotos (em Fotos, o painel de informações da imagem
   mostra PNG) e o Instagram abre no fluxo de nova publicação com ela. Se abrir sem a
   foto, conferir que ela é a primeira da galeria do Instagram e anotar a versão do
   Instagram.
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

**Idioma.** Os passos 9 a 13, 15 e 16 pedem o build 22 em diante; o passo 14 vale já no
build 21, com o site publicado. O site guarda o idioma no aparelho quando a pessoa
escolhe um ou a conta abre, e o guardado vence o idioma do iPhone e o fuso. Para ver as
telas iniciais pela regra do aparelho, testar sem conta aberta: instalação nova (apagar o
app e instalar de novo pelo TestFlight) ou depois de sair da conta. O fuso vem de
Ajustes > Geral > Data e Hora: para simular outro país, desligar "Ajustar
Automaticamente" e escolher a cidade em Fuso Horário (no fim, ligar de novo).

9. **iPhone em espanhol.** Ajustes > Geral > Idioma e Região > Español (México) como
   idioma principal do iPhone. Abrir o Diariamente sem conta: as telas iniciais aparecem
   em espanhol, sem tocar em nada. Se der, repetir com Español (España) e com Español
   (Latinoamérica).
10. **Idioma só do Diariamente.** iPhone em português, com Español acrescentado na lista
    de Ajustes > Geral > Idioma e Região (sem trocar o principal; sem um segundo idioma
    na lista o iOS não mostra a opção). Ajustes > Diariamente > Idioma preferido >
    Español e abrir o app: telas iniciais em espanhol. Voltar para Português: telas
    iniciais em português.
11. **Textos do sistema em espanhol.** Com o app em espanhol (passo 9 ou 10), numa
    instalação nova (permissão das Fotos ainda não pedida), entrar na conta e escolher
    "Instagram Feed (retrato)" ("Instagram Feed (vertical)" se a conta for em
    espanhol): o pedido diz "Diariamente guarda la imagen de la píldora en tus Fotos
    para que la publiques o la conserves." Esse texto segue o idioma do iPhone (ou o
    escolhido em Ajustes > Diariamente), não o da conta. A folha de "Outros apps"
    ("Otras apps") e o menu de copiar e colar também aparecem em espanhol.
12. **Conta em português num iPhone em espanhol.** Entrar com uma conta em português:
    depois do login o app segue a conta (português), e as folhas do sistema continuam
    em espanhol. É o esperado.
13. **Outro idioma, no Brasil, cai no português.** iPhone em inglês, no fuso do Brasil
    (Data e Hora no automático, no Brasil), sem conta: telas iniciais, folhas do sistema e
    pedido das Fotos em português, como na 1.0.5.
14. **Fuso do México com o iPhone em português ou inglês (o centro do pedido).** iPhone
    em português, sem conta, Fuso Horário na Cidade do México: as telas iniciais aparecem
    em espanhol, sem tocar em nada. Repetir com o iPhone em inglês: também em espanhol.
    As folhas do sistema e o pedido das Fotos seguem em português (o binário não tem
    inglês). Voltar o fuso para o Brasil, sem conta: telas iniciais em português. Com uma
    conta em português aberta, o fuso não muda nada: o app segue a conta, inclusive depois
    de fechar e abrir o app no fuso do México.
15. **Sem conexão.** iPhone em espanhol, modo avião, abrir o app: aparece "Sin conexión"
    com o botão "Intentar de nuevo"; tirar do modo avião e o app entra sozinho. Repetir
    com o iPhone em português e o fuso da Cidade do México: também "Sin conexión" (a tela
    segue a mesma regra das telas iniciais). No iPhone em português, no fuso do Brasil,
    "Sem conexão" e "Tentar novamente", como antes.
16. **Nome do app.** Na tela de início do iPhone o nome continua "Diariamente" em
    português, espanhol e inglês.

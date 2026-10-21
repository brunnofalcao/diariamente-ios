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
  acontece apenas em `sistema` (códigos `imagem_invalida`, `falha_ao_gravar`,
  `sem_tela`). O site trata rejeição como "use o caminho antigo".
- Tudo que mexe em UIKit roda na main thread. Nada de log com conteúdo.

## O que cada caminho faz

- **Stories (oficial da Meta).** Põe o PNG no pasteboard na chave
  `com.instagram.sharedSticker.backgroundImage`, com validade de 5 minutos, e abre
  `instagram-stories://share?source_application=<App ID>`. Sem App ID o Instagram
  mostra erro; por isso o plugin recusa App ID vazio ou com letras.
- **Feed (atalho sem documentação oficial).** Pede a permissão "só adicionar" das
  Fotos, salva o PNG e abre `instagram://library?LocalIdentifier=<id>`. O Instagram
  nem sempre respeita o identificador: o site oferece a volta segura. A imagem fica
  salva nas Fotos da pessoa (é assim que esse caminho funciona).
- **Outros apps.** Grava o PNG numa pasta temporária com o nome pedido, abre a folha
  nativa do iOS (popover centralizado no iPad) e resolve quando ela fecha de vez. O
  arquivo é apagado 60 s depois; sobras de sessões encerradas são apagadas ao abrir o app.

## Enquanto não existe o App ID

O site tem a constante `INSTAGRAM_APP_ID` vazia por padrão e, vazia, não chama o
plugin: nada muda para ninguém. Um binário 1.0.6 com o plugin se comporta como o
1.0.5 até o site receber o App ID. Android (TWA) e navegador ficam como estão.

## Como entra no build

`npm install` cria o link `node_modules/diariamente-instagram-share`, e o `npx cap sync ios`
(os dois já rodam no Codemagic antes do `pod install`) acrescenta ao Podfile
`pod 'DiariamenteInstagramShare', :path => '../../plugins/instagram-share'` e ao
`ios/App/App/capacitor.config.json` a classe `InstagramSharePlugin`. Esses dois
arquivos versionados não são editados à mão, mesmo padrão adotado com o Haptics:
o CI regenera.

Info.plist: `LSApplicationQueriesSchemes` (`instagram-stories`, `instagram`) e
`NSPhotoLibraryAddUsageDescription` em português. O projeto não tem
`InfoPlist.strings` por idioma e o binário declara só `pt-BR`/`pt`, então o texto
de permissão fica só em português.

## Roteiro de teste no TestFlight (build 1.0.6)

Antes do App ID no site:

1. Compartilhar pílula funciona exatamente como na 1.0.5 (regressão).

Com o App ID no site, em iPhone com Instagram logado:

2. **Stories.** Escolher o formato Story: abre o editor de Stories do Instagram com
   a pílula de fundo, sem passar pela folha do iOS.
3. **Aviso de colar do iOS.** Na primeira vez o iOS pergunta se o Instagram pode
   colar do Diariamente. "Permitir": a imagem aparece. "Não permitir": anotar o que
   o Instagram mostra e conferir que voltar ao Diariamente não trava a tela.
4. **Stories sem Instagram.** Desinstalar o Instagram e repetir: nada externo abre,
   o site mostra a alternativa e o que estava copiado continua copiado.
5. **Feed, permissão aceita.** Escolher Post: aparece o pedido "Adicionar às Fotos"
   com o texto em português; aceitar. A imagem vai para as Fotos e o Instagram abre
   no fluxo de nova publicação com ela (se abrir em outra foto, conferir a volta segura).
6. **Feed, permissão negada.** Ajustes > Diariamente > Fotos > Nenhum, repetir: o
   Instagram não abre, nada é salvo, o site mostra a alternativa.
7. **Outros apps.** Abre a folha do iOS com o PNG (nome de arquivo certo). Testar
   WhatsApp, Salvar Imagem e Mensagens; fechar a folha sem escolher; abrir Mail e
   cancelar dentro dele (se a folha voltar, escolher outro app deve funcionar).
8. **iPad.** Outros apps abre como popover no centro da tela, sem travar; Stories e
   Feed como no iPhone.

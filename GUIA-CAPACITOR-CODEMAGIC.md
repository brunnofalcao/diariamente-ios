# Build do iOS na nuvem — Capacitor + Codemagic (sem Xcode no seu Mac)

Objetivo: gerar um **binário novo, com o SDK do iOS 26** (mata o ITMS-90725) e subir pra App Store, **sem instalar Xcode**. O Codemagic compila num Mac da nuvem.

> Tempo: ~1h na primeira vez (a maior parte é cadastro/credencial). Builds seguintes são 1 clique.
> Os arquivos prontos estão nesta pasta: `package.json`, `capacitor.config.json`, `www/`, `codemagic.yaml`.

---

## Passo 1 — Pôr o projeto num repositório GitHub
O Codemagic builda a partir de um repo. Crie um repo novo (ex.: **`diariamente-ios`**) e suba **o conteúdo desta pasta** (`ios-capacitor/`): `package.json`, `capacitor.config.json`, `codemagic.yaml`, `www/`.

> Pelo GitHub Desktop: File → New Repository → nome `diariamente-ios` → arrasta os arquivos pra pasta → Commit → Publish.
> **Não precisa** subir o `setup-ios.sh` nem a pasta `ios/` — o Codemagic gera o iOS sozinho.

## Passo 2 — Gerar a chave da App Store Connect (pra assinar/enviar)
No App Store Connect (appstoreconnect.apple.com):
1. **Usuários e Acesso** → aba **Integrações** (ou "Chaves") → **App Store Connect API**.
2. **Gerar chave** → nome "Codemagic" → acesso **App Manager** → criar.
3. Baixa o arquivo **`.p8`** e anota o **Key ID** e o **Issuer ID** (ficam na tela).
4. **Não me mande o `.p8`** — é secreto. Vai direto no Codemagic.

## Passo 3 — Codemagic: conta + chave + repo
1. Cria conta em **codemagic.io** (tem plano grátis, ~500 min/mês — sobra).
2. **Teams → Integrations → App Store Connect → Add key**: cole o Key ID, Issuer ID e o arquivo `.p8`. **Dê o nome `AppStoreConnectKey`** (é o nome que o `codemagic.yaml` espera).
3. **Add application** → conecta sua conta GitHub → escolhe o repo `diariamente-ios`.
4. O Codemagic detecta o `codemagic.yaml` automaticamente.

## Passo 4 — Buildar
1. No app dentro do Codemagic → **Start new build** → escolhe o workflow **"Diariamente iOS (Capacitor)"**.
2. Ele vai: instalar deps → gerar o iOS → assinar (com sua chave) → compilar o `.ipa` → **subir pro TestFlight**.
3. Demora ~10–20 min. Acompanha o log.

> **Primeira vez pode dar um erro de versão/config** — é normal em build na nuvem. Se der, me manda o trecho do log que eu ajusto o `codemagic.yaml` (versão do Capacitor, Xcode, etc.).

## Passo 5 — Reenviar pra Apple
Quando o build subir (aparece em **App Store Connect → TestFlight** como Build novo):
1. App Store Connect → seu app → versão **1.0** → em **Build**, seleciona o **build novo** (o que o Codemagic subiu, com SDK 26).
2. Confirma a conta demo no campo de login (`apple-review@diariamente.app` / `Teste@2026`).
3. **Enviar para revisão.**

Como o conteúdo já está aprovado (exclusão de conta + modelo de negócio resolvidos no app ao vivo) e agora o binário é válido, deve passar.

---

## Sobre o push (bônus do Capacitor)
O App ID `club.diariamente.app` já tem **Push Notifications** ligado (você fez). O plugin `@capacitor/push-notifications` já está no `package.json`. Depois que o binário básico passar, a gente liga o registro do token no app (1 trecho) + as variáveis APNs no Railway — e o push do iPhone funciona. **Prioridade agora é o binário válido**; push é o passo seguinte.

---

## Plano B (se travar e seu tempo for curto)
Esse fluxo é técnico. Se emperrar, um **freelancer iOS** faz isso numa tarde com este guia + os arquivos prontos. Pra um CEO, às vezes pagar 2–3h de um dev é o melhor uso do tempo. Mas dá pra você fazer — é mais cadastro do que código.

Me manda o log se a primeira build falhar, que eu corrijo na hora.

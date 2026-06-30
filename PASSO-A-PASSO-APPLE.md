# Publicar na Apple — passo a passo (Diariamente)

Objetivo: transformar o app (que já roda em app.diariamente.club) num app iOS nativo, com push, e publicar na App Store. Eu deixei o projeto pronto nesta pasta; você roda no Mac.

> **Você já tem:** conta Apple Developer ✅ · chave APNs (.p8) ✅ · Bundle ID `club.diariamente.app` ✅ · Mac ✅
> **Falta instalar:** o **Xcode** (grátis na App Store do Mac) — instala enquanto lê isto.

---

## Parte 1 — Rodar o setup (5 min)
1. Copie a pasta `ios-capacitor/` pro seu Mac.
2. Abra o **Terminal** nessa pasta e rode:
   ```bash
   bash setup-ios.sh
   ```
3. Ele instala o Capacitor, cria o projeto iOS e abre o **Xcode** sozinho.

> Se pedir permissão/CocoaPods, aceite. Se travar, me manda o erro.

---

## Parte 2 — Ícone e splash
- No Xcode, painel esquerdo → `App/App/Assets.xcassets` → **AppIcon** → arraste seu ícone **1024×1024** (PNG, sem transparência).
- (Opcional) splash com a cor `#0A0E0E`.

---

## Parte 3 — Assinatura + capabilities (o que faz o push funcionar)
No Xcode, clique no projeto **App** (topo da árvore) → aba **Signing & Capabilities**:
1. **Team:** Science Play Audiobook LTDA (3UD3Q534G6). Deixe "Automatically manage signing" marcado.
2. Confirme **Bundle Identifier = `club.diariamente.app`**.
3. **+ Capability** → **Push Notifications**.
4. **+ Capability** → **Background Modes** → marque **Remote notifications**.

---

## Parte 4 — Registrar o token de push (1 ajuste no app)
Pra o iPhone receber push, o app precisa registrar o token. Esse trecho vai no `index.html` do app principal (eu te passo pronto quando você chegar aqui — é o `registrarPush()` do guia `push-nativo/capacitor-build-ios.md`). Em resumo: ao logar, pede permissão e manda o token pra `app.diariamente.club/api/push/token`.

> Esse passo pode ficar pra depois do primeiro build — o app já roda sem ele. O push entra quando a gente plugar as variáveis APNs no Railway.

---

## Parte 5 — Testar no seu iPhone
1. Conecte o iPhone no Mac por cabo.
2. No Xcode, escolha seu iPhone no topo e clique ▶ (Run).
3. O app abre no telefone. Teste navegar, marcar leitura, etc.

---

## Parte 6 — TestFlight (testar com pessoas reais)
1. No Xcode: menu **Product → Archive**.
2. Quando terminar, na janela do Organizer → **Distribute App** → **App Store Connect** → **Upload**.
3. Vá em [App Store Connect](https://appstoreconnect.apple.com) → seu app → aba **TestFlight** → adicione testadores (e-mails). Eles recebem convite e instalam.

---

## Parte 7 — Enviar pra App Store (review)
No App Store Connect, aba **Distribuição / App Store**, preencha:
- **Screenshots** 6.7" (1290×2796) e 6.5" (1242×2688) — prints reais do app.
- **Descrição, palavras-chave, categoria** (Saúde & Fitness ou Estilo de Vida).
- **Política de privacidade:** já está publicada em app.diariamente.club/privacidade.html — use essa URL.
- **App Privacy (nutrition labels):** declare o que coleta (e-mail, uso). Guia detalhado no pacote Apple (`build-candidato/sprint-5-apple/APP-PRIVACY.md`).
- **Conta demo pro revisor:** crie um usuário de teste e informe login/senha nas notas.
- **Notas pro revisor:** texto pronto em `build-candidato/sprint-5-apple/REVIEWER-NOTES.md` (explica que é app de leitura diária, acesso por e-mail, com push nativo).
- Clique **Enviar para revisão**.

---

## Pontos que JÁ resolvemos (não precisa se preocupar)
- ✅ **Exclusão de conta no app** (Apple exige) — funciona e grava registro anonimizado.
- ✅ **Sem botão "Comprar"** / sem menção a billing externo — app é login-only, linguagem "e-mail de acesso".
- ✅ **Trackers (GA/Pixel) desativados** — evita rejeição por ATT.

## O risco conhecido (e como mitigar)
- **Guideline 4.2 (minimum functionality):** a Apple às vezes implica com app que é "só um site". Mitigação: o app tem **push nativo**, **funciona offline** (service worker) e ícone na tela inicial. Nas notas do revisor, deixamos claro o valor (leitura/reflexão diária com lembretes). Se mesmo assim pedirem mais "nativo", a gente adiciona um recurso nativo simples (ex: widget) — mas normalmente passa.

---

## Resumo do que é SEU e do que é MEU
**Seu (no Mac):** instalar Xcode · rodar `setup-ios.sh` · ícone · assinatura/capabilities · Archive → TestFlight → enviar.
**Meu (quando você chegar lá):** o trecho de registro de push no app · variáveis APNs no Railway · ajustes que o revisor pedir.

Quando rodar o `setup-ios.sh` e o Xcode abrir, me avisa em que passo está que eu te acompanho.

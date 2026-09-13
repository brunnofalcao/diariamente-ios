# Arquitetura de boot do Diariamente — fonte única da verdade

> Se você veio aqui para "arrumar a splash", leia primeiro a seção **Regras que não
> podem ser quebradas**. O bug de splash dupla que existiu até a v1.0.3 voltou a
> aparecer todas as vezes em que uma dessas regras foi violada.

## Os dois repositórios

| Repositório | Papel | O que controla |
|---|---|---|
| `brunnofalcao/diariamente-ios` | Shell nativo (Capacitor). **Gera o binário.** | LaunchScreen, Info.plist, entitlements, Universal Links, assets de ícone/splash, build no Codemagic |
| `brunnofalcao/diariamente` | Aplicação. **É o app.** | `public/index.html` servido em `app.diariamente.club`: BootCoordinator, sessão, rotas, telas |

O shell **não** empacota a aplicação: `capacitor.config.json` aponta
`server.url` para `https://app.diariamente.club`. A WebView carrega o app ao vivo.

Consequência que explica quase tudo: **entre a splash e o primeiro frame existe
uma requisição de rede**. Em rede ruim isso é 1–3 s. Qualquer coisa que descubra a
WebView antes de o app estar pronto expõe esse buraco.

## Quem é dono de cada etapa

| Etapa | Dono | Onde |
|---|---|---|
| Splash visual | Sistema operacional | `ios/App/App/Base.lproj/LaunchScreen.storyboard` |
| Segurar a splash até READY | `@capacitor/splash-screen` (`launchAutoHide:false`) | `capacitor.config.json` |
| Rede de segurança da splash | `AppDelegate` (watchdog de 10 s) | `ios/App/App/AppDelegate.swift` |
| Entrega do deep link | `ApplicationDelegateProxy` → plugin `App` | `ios/App/App/AppDelegate.swift` |
| Intenção de abertura | Caixa de entrada `DiariamenteBoot` | `public/index.html`, bloco BOOT no `<head>` |
| Sessão, rota e primeiro frame | `BootCoordinator` (`bootStart` / `bootRun`) | `public/index.html`, fim do `<script>` |

Nenhuma outra camada desenha splash, restaura sessão ou decide rota.

## Máquina de estados

```
starting → resolving_link → restoring_session → ready
                                             ↘ error (interface real, com "Tentar novamente")
```

`ready` é o **único** estado que esconde a splash, via `Boot.hideSplash()`.

## Linha do tempo

### Abertura direta (ícone)

```
T0  processo inicia
T1  LaunchScreen aparece                      ← única marca visível
T2  bridge Capacitor pronta; plugin segura a LaunchScreen (sem timer)
T3  WebView carrega app.diariamente.club      ← coberto pela splash
T4  bootStart(): getLaunchUrl() → sem link
T5  /api/me + conteúdo + dados do usuário (em paralelo)
T6  READY → SplashScreen.hide(250 ms) → primeiro frame real
```

### Abertura pelo WhatsApp (Universal Link com `?m=<jwt>`)

Idêntica, com dois passos a mais e **nenhuma tela extra**:

```
T4  bootStart() aguarda getLaunchUrl() — resposta autoritativa, não é espera artificial
T4' intenção {magic} entra na caixa (dedup contra o appUrlOpen retido)
T5  token aplicado em memória; URL limpa com replaceState (SEM reload)
T6  READY → primeiro frame já na rota certa
```

## Regras que não podem ser quebradas

1. **Nunca `window.location.href` para rotear um deep link interno.** Recarregar o
   documento reinicia o boot inteiro e pinta a marca de novo. Era a causa da segunda
   splash vinda do WhatsApp. Magic link se resolve em memória.
   A única navegação permitida é para uma rota de *documento* (ex.: `/ativar?token=…`),
   e ela acontece **antes** de READY, com a splash ainda no ar.
2. **Nunca registrar um segundo listener de `appUrlOpen`.** O link seria processado
   duas vezes. A escuta única vive no bloco BOOT do `<head>`.
3. **Nunca `launchAutoHide: true`.** A splash cairia num timer, descobrindo a WebView
   antes de o app existir — tela vazia entre as duas marcas.
4. **Nunca desenhar splash no web layer em plataforma nativa.** É o que
   `html[data-native="1"] #splash-screen { display:none }` garante.
5. **Nunca usar a splash como tela de erro.** Falha vira interface real com saída.
6. **Nenhum timer governa o caminho feliz.** Os únicos temporizadores no boot são
   guardas de falha declaradas: watchdog nativo (10 s) e o teto da bridge (2 s).

## Quando não há rede

O app é carregado ao vivo. Sem rede, a WebView **não chega a abrir o documento** —
nenhum JavaScript roda, então a tela de erro do app web não tem como aparecer.
(Service Worker não cobre esse caso: em WKWebView ele não é confiável sem
`WKAppBoundDomains`, e com `server.url` remoto não dá para contar com ele.)

Quem resolve é o Capacitor: `server.errorPath: "error.html"` carrega
`www/error.html` do bundle quando a navegação falha
(`didFailProvisionalNavigation`). A página é **100% self-contained** — nenhuma
fonte, imagem ou script remoto, porque ela existe justamente para o caso de não
haver rede. Ela também solta a splash nativa por conta própria: o boot nunca vai
chegar a READY ali, e sem isso o usuário ficaria olhando a marca até o watchdog.

Reentrada: botão *Tentar novamente* e o evento `online` do sistema — sem polling.

Camadas, da mais específica para a última linha de defesa:

| Situação | Quem trata | Resultado |
|---|---|---|
| Documento carrega, API falha | `bootIsNetworkFailure` no app web | "Sem conexão", sessão preservada |
| Documento não carrega | `server.errorPath` → `www/error.html` | "Sem conexão", com retry automático |
| Nada acima funcionou | Watchdog de 10 s no `AppDelegate` | Splash liberada; app não fica preso |

## Telemetria

`console.log('[boot] …')` no web (visível no Safari Web Inspector) e `os_log`
subsystem `club.diariamente.app`, categoria `boot`, no nativo (Console.app).

Eventos: `app_process_started`, `native_launch_completed`, `app_boot_started`,
`deep_link_received`, `deep_link_deduped`, `deep_link_resolved`,
`session_restore_started/completed/failed`, `first_content_rendered`,
`app_interactive`, `boot_watchdog_fired`.

Cada um carrega duração, `launch_source` (`direct` | `universal_link` |
`custom_scheme`) e `launch_state` (`cold` | `warm`).
**Nunca** token, sessão, e-mail ou magic link.

`boot_watchdog_fired` no Console significa que o web layer não chegou a READY em
10 s — é sinal de incidente (app fora do ar, DNS, rede), não de splash lenta.

## Android

Não existe projeto Android em nenhum dos dois repositórios hoje. Quando existir:

- `plugins.SplashScreen.launchAutoHide:false` do `capacitor.config.json` já vale para
  Android — nada a duplicar;
- a regra `data-native` do web layer também já cobre Android;
- usar a **SplashScreen API do Android 12+** com o mesmo fundo `#0A0E0E` e o mesmo
  wordmark (ver `SPLASH-DIARIAMENTE-001.md`), sem criar um segundo tema de launch.

## Testes

`test/boot-coordinator.test.js` no repositório `diariamente` (roda com `npm test`)
cobre dedup de deep link, idempotência do `hideSplash`, allowlist de origem e
entrega da intenção de cold start.

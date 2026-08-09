# SPLASH-DIARIAMENTE-001 — especificação oficial da abertura

Especificação **única**. Existe uma arte de abertura no produto; não se cria uma
segunda "para o app web", "para o Android" ou "para o deep link".

## Superfície

| Plataforma | Superfície | Arquivo |
|---|---|---|
| iOS | `LaunchScreen.storyboard` (segurada até READY) | `ios/App/App/Base.lproj/LaunchScreen.storyboard` |
| Navegador / PWA | `#splash-screen` no HTML — **só quando não é nativo** | `public/index.html` (repo `diariamente`) |
| Android | SplashScreen API do Android 12+ (quando o projeto existir) | — |

Em plataforma nativa a splash HTML fica desligada por CSS. As duas nunca coexistem.

## Especificação visual

| Item | Valor |
|---|---|
| Fundo | `#0A0E0E` (opaco, idêntico ao `ios.backgroundColor` da WebView) |
| Marca | Wordmark **DIARIAMENTE** |
| Posição | Centro óptico, eixos X e Y |
| Escala | ~35% da largura visível (≈450 px num canvas de 2732 px) |
| Canvas de origem | 2732×2732 px, `scaleAspectFill` |
| Light / Dark mode | Idêntico — a abertura não segue o tema do sistema |
| Orientação | Retrato (o app trava retrato) |
| Animação | **Nenhuma.** Sem pulsar, brilhar, escalar ou aparecer com fade |
| Spinner | Não |
| Duração | Não existe. Sai quando o app chega a READY |
| Saída | Fade de 250 ms, uma vez, direto para o conteúdo real |

O canvas é quadrado e o iPhone recorta cerca de 1250 px centrais: por isso o
wordmark é pequeno na arte de origem. Aumentá-lo estoura na tela do aparelho.

## Fundo à prova de flash

O `imageView` da LaunchScreen usa `#0A0E0E` explícito, **não** `systemBackgroundColor`.
Com a cor de sistema, o fundo era branco em light mode e qualquer falha ou borda da
imagem virava um flash claro contra um app escuro.

## Geração dos assets

No Codemagic, passo *"Baixar icone oficial e gerar"*:

```
assets/splash.png  ←  https://app.diariamente.club/splash-ios.png
npx @capacitor/assets generate --ios
```

Gera `Assets.xcassets/Splash.imageset` (1x/2x/3x), consumido pela LaunchScreen.
Trocar a arte = trocar `public/splash-ios.png` no repositório `diariamente`.
Não versionar uma segunda arte no repositório iOS.

## O que é proibido

- Segunda animação de marca depois da splash nativa.
- Logo diferente entre a abertura nativa e a web (era o "logo que reaparece":
  wordmark no nativo, ícone redondo com brilho pulsante no web).
- Timer, `launchShowDuration` como forma de "durar mais", fade para mascarar espera.
- Usar a splash como tela de erro ou de carregamento de conteúdo.

## Referência cruzada

Comportamento de boot, ownership e regras invioláveis: `BOOT-ARCHITECTURE.md`.

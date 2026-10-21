# diariamente-instagram-share

Plugin Capacitor 7 local (só iOS) do Diariamente. Leva o PNG da pílula direto ao
Instagram (Stories pelo caminho oficial da Meta, Feed pelo atalho da biblioteca de
Fotos) e abre a folha nativa de compartilhar quando o Instagram não abre. A linha
"Outros apps" do site usa o `navigator.share` do WebKit e não passa pelo plugin.

- JS: `window.Capacitor.Plugins.InstagramShare` com `disponivel`, `stories`, `feed`, `sistema`.
- Nativo: `ios/Sources/InstagramSharePlugin/InstagramSharePlugin.swift`.
- Pod: `DiariamenteInstagramShare` (o nome tem de bater com o que o `@capacitor/cli`
  deriva de `diariamente-instagram-share`).

Contrato, Info.plist e roteiro de teste: [`docs/INSTAGRAM-DIRETO.md`](../../docs/INSTAGRAM-DIRETO.md).

Cuidado ao editar o Swift: o `@capacitor/cli` registra a classe procurando o
primeiro `@objc(Nome)` de cada arquivo `.swift` desta pasta. Não use essa forma
em comentários nem em outras classes.

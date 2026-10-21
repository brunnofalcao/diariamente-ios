import Foundation
import UIKit
import Photos
import Capacitor

// ─────────────────────────────────────────────────────────────────────────────
// INSTAGRAM DIRETO: ponte nativa da tela "Compartilhar pílula"
//
// O site (app.diariamente.club, repo `diariamente`) desenha o PNG da pílula e
// chama este plugin por `window.Capacitor.Plugins.InstagramShare`. O JavaScript
// do Capacitor não grava as chaves de pasteboard que o Instagram lê nem salva
// nas Fotos, por isso esta camada existe. Contrato completo e roteiro de teste:
// docs/INSTAGRAM-DIRETO.md.
//
//   disponivel()                              -> { stories, feed }
//   stories({ imagem, appId })                -> { aberto, motivo? }
//   feed({ imagem })                          -> { aberto, motivo? }
//   sistema({ imagem, nomeArquivo, texto? })  -> { concluido, destino? }
//
// No site, `sistema` é a queda de Stories e Feed (Instagram que não abre, ou o Feed com
// o atalho desligado). A linha "Outros apps" usa o `navigator.share` do WebKit e não
// passa por este plugin.
//
// Regras deste arquivo:
//   • Os casos previstos RESOLVEM a Promise. Rejeição é só para erro inesperado.
//   • Tudo que toca UIKit roda na main thread. O Capacitor chama os métodos numa
//     fila própria em segundo plano, então a decodificação do base64 fica lá.
//   • Nada de log com conteúdo (imagem, App ID, identificador da foto).
// ─────────────────────────────────────────────────────────────────────────────

@objc(InstagramSharePlugin)
public class InstagramSharePlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "InstagramSharePlugin"
    public let jsName = "InstagramShare"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "disponivel", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stories", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "feed", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "sistema", returnType: CAPPluginReturnPromise)
    ]

    override public func load() {
        // Sobra de uma sessão anterior (app encerrado com a folha aberta).
        Apoio.apagar(Apoio.pastaTemporaria)
    }

    // MARK: - disponivel

    /// Diz o que o Instagram instalado aceita. Depende de `LSApplicationQueriesSchemes`
    /// no Info.plist; sem ele o `canOpenURL` responde sempre `false`.
    @objc func disponivel(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            call.resolve([
                "stories": Apoio.podeAbrir(Apoio.enderecoStories),
                "feed": Apoio.podeAbrir(Apoio.enderecoInstagram)
            ])
        }
    }

    // MARK: - stories (caminho oficial da Meta)

    /// Põe o PNG no pasteboard com a chave oficial e abre o editor de Stories.
    /// O App ID do Facebook é obrigatório desde 2023: sem ele o Instagram mostra erro.
    @objc func stories(_ call: CAPPluginCall) {
        guard let url = Apoio.urlStories(appId: call.getString("appId")) else {
            call.resolve(Apoio.falha("app_id_invalido"))
            return
        }
        guard let png = Apoio.decodificarImagem(call.getString("imagem")) else {
            call.resolve(Apoio.falha("imagem_invalida"))
            return
        }

        DispatchQueue.main.async {
            guard UIApplication.shared.canOpenURL(url) else {
                call.resolve(Apoio.falha("sem_instagram"))
                return
            }
            // Só mexe no pasteboard quando o Instagram vai ler, para não trocar à toa
            // o que a pessoa tinha copiado. Validade de 5 minutos, como no exemplo da Meta.
            UIPasteboard.general.setItems(
                [[Apoio.chaveFundoStories: png.dados]],
                options: [.expirationDate: Date().addingTimeInterval(Apoio.validadePasteboard)]
            )
            Apoio.abrir(url, respondendo: call)
        }
    }

    // MARK: - feed (atalho sem documentação oficial)

    /// Salva o PNG nas Fotos (permissão só de adicionar) e abre o Instagram apontando
    /// para a foto criada. O Instagram nem sempre respeita o identificador: quando ele
    /// abre, mas não na foto, a imagem já está nas Fotos e é a mais recente da galeria
    /// dele. Com `aberto: true` o site não faz mais nada; a volta dele vale só para
    /// `aberto: false` (cai em `sistema`). Se o atalho falhar com frequência, o site
    /// desliga `INSTAGRAM_FEED_DIRETO`, sem versão nova na loja.
    @objc func feed(_ call: CAPPluginCall) {
        guard let png = Apoio.decodificarImagem(call.getString("imagem")) else {
            call.resolve(Apoio.falha("imagem_invalida"))
            return
        }

        DispatchQueue.main.async {
            // Confere o Instagram antes de pedir acesso às Fotos: sem o app, a
            // pergunta de permissão seria um incômodo sem propósito.
            guard Apoio.podeAbrir(Apoio.enderecoInstagram) else {
                call.resolve(Apoio.falha("sem_instagram"))
                return
            }
            Apoio.pedirPermissaoParaAdicionar { permitido in
                guard permitido else {
                    call.resolve(Apoio.falha("sem_permissao"))
                    return
                }
                Apoio.salvarNasFotos(png.dados) { identificador in
                    guard let identificador = identificador else {
                        call.resolve(Apoio.falha("falha_ao_salvar"))
                        return
                    }
                    DispatchQueue.main.async {
                        guard let url = Apoio.urlBiblioteca(identificador: identificador) else {
                            call.resolve(Apoio.falha("falha_ao_abrir"))
                            return
                        }
                        Apoio.abrir(url, respondendo: call)
                    }
                }
            }
        }
    }

    // MARK: - sistema (folha nativa, usada como queda)

    /// Abre a folha nativa do iOS com o PNG como arquivo. O site chega aqui quando Stories
    /// ou Feed não abrem o Instagram, ou no Feed com o atalho desligado. Por ser nativa,
    /// não depende de um toque recente no JavaScript (o `navigator.share` depende).
    /// Resolve quando a folha fecha de vez: `concluido` falso quer dizer só que a pessoa
    /// fechou sem concluir. Se o UIKit não deixar a folha aparecer nem na segunda tentativa,
    /// REJEITA com `falha_ao_apresentar`, e o site segue para o caminho de antes.
    @objc func sistema(_ call: CAPPluginCall) {
        guard let png = Apoio.decodificarImagem(call.getString("imagem")) else {
            call.reject("Imagem inválida", "imagem_invalida")
            return
        }

        let pasta = Apoio.pastaTemporaria.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let arquivo = pasta.appendingPathComponent(Apoio.nomeSeguro(call.getString("nomeArquivo")), isDirectory: false)
        do {
            try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true, attributes: nil)
            try png.dados.write(to: arquivo, options: .atomic)
        } catch {
            Apoio.apagar(pasta)
            call.reject("Não foi possível preparar o arquivo", "falha_ao_gravar")
            return
        }
        let texto = call.getString("texto")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let itens: [Any] = texto.isEmpty ? [arquivo] : [arquivo, texto]

        DispatchQueue.main.async { [weak self] in
            let entrega = EntregaDoSistema(call: call, pasta: pasta)
            guard let self = self else {
                entrega.recusar("Tela do app indisponível", "sem_tela")
                return
            }
            let folha = UIActivityViewController(activityItems: itens, applicationActivities: nil)
            folha.completionWithItemsHandler = { [weak folha] tipo, concluido, _, _ in
                if concluido {
                    entrega.finalizar(concluido: true, destino: tipo?.rawValue)
                } else if tipo == nil {
                    // Fechou a folha sem escolher nada.
                    entrega.finalizar(concluido: false, destino: nil)
                } else {
                    // Escolheu um app e desistiu dentro dele. Conforme a versão do iOS a
                    // folha volta à tela esperando outra escolha (e este bloco roda de novo
                    // depois); só encerra se ela de fato saiu.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak folha] in
                        let aindaNaTela = folha.map { $0.presentingViewController != nil && !$0.isBeingDismissed } ?? false
                        if !aindaNaTela {
                            entrega.finalizar(concluido: false, destino: nil)
                        }
                    }
                }
            }
            self.apresentar(folha, entrega: entrega, novasTentativas: 1)
        }
    }

    /// Apresenta a folha sobre a tela do topo e confere, pouco depois, se o UIKit aceitou.
    /// Quando aceita, ele liga `presentingViewController` na hora do `present`, antes de a
    /// animação terminar; quando recusa (topo fora da janela, ou já apresentando outra tela),
    /// não avisa nem chama o completion. Por isso a conferência olha o estado da folha, e não
    /// o fim da animação: uma apresentação lenta (a primeira folha da sessão, aparelho lento)
    /// não é confundida com recusa. Aceita, só o `completionWithItemsHandler` encerra, e o PNG
    /// temporário só começa a contar para ser apagado quando a folha fecha de verdade.
    @MainActor
    private func apresentar(_ folha: UIActivityViewController, entrega: EntregaDoSistema, novasTentativas: Int) {
        guard !entrega.encerrada else { return }
        guard let raiz = bridge?.viewController else {
            entrega.recusar("Tela do app indisponível", "sem_tela")
            return
        }
        // Topo da pilha, sem subir para uma tela que está saindo: apresentar sobre ela falha.
        var topo = raiz
        while let acima = topo.presentedViewController, !acima.isBeingDismissed {
            topo = acima
        }
        if topo is UIActivityViewController {
            // Toque duplo: já existe uma folha aberta, que responde pela primeira chamada.
            entrega.finalizar(concluido: false, destino: nil, apagarJa: true)
            return
        }
        // Uma tela entrando ou saindo: um `present` agora ficaria guardado pelo UIKit até o fim
        // da transição, sem `presentingViewController`, e pareceria recusado. Espera ela acabar;
        // aí o `present` é aceito ou recusado na hora.
        if let transicao = topo.transitionCoordinator {
            transicao.animate(alongsideTransition: nil) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self = self else {
                        entrega.recusar("Tela do app indisponível", "sem_tela")
                        return
                    }
                    self.apresentar(folha, entrega: entrega, novasTentativas: novasTentativas)
                }
            }
            return
        }

        // iPad: a folha vira popover e precisa de âncora; fica no centro, sem seta.
        if let popover = folha.popoverPresentationController {
            popover.sourceView = topo.view
            popover.sourceRect = CGRect(x: topo.view.bounds.midX, y: topo.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        topo.present(folha, animated: true, completion: nil)

        // A folha fica presa aqui (referência forte) até a conferência: se o UIKit recusou,
        // ninguém mais a segura.
        DispatchQueue.main.asyncAfter(deadline: .now() + Apoio.esperaApresentacao) { [weak self] in
            guard !entrega.encerrada else { return }
            if folha.presentingViewController != nil || folha.isBeingPresented {
                return
            }
            if novasTentativas > 0, let self = self {
                // Uma nova tentativa, com o topo recalculado.
                self.apresentar(folha, entrega: entrega, novasTentativas: novasTentativas - 1)
            } else {
                entrega.recusar("A folha do sistema não abriu", "falha_ao_apresentar")
            }
        }
    }
}

// MARK: - Entrega da folha do sistema

/// Garante que `sistema` responda uma única vez, mesmo que o iOS chame o
/// `completionWithItemsHandler` mais de uma vez, e apaga o PNG temporário no fim.
/// Só é usada na main thread.
private final class EntregaDoSistema {
    private let call: CAPPluginCall
    private let pasta: URL
    private(set) var encerrada = false

    init(call: CAPPluginCall, pasta: URL) {
        self.call = call
        self.pasta = pasta
    }

    /// A folha fechou (ou nem precisou abrir, no toque duplo). `apagarJa` para quando o
    /// arquivo não chegou a ser oferecido a nenhum app.
    func finalizar(concluido: Bool, destino: String?, apagarJa: Bool = false) {
        guard !encerrada else { return }
        encerrada = true

        var resultado: [String: Any] = ["concluido": concluido]
        if concluido, let destino = destino, !destino.isEmpty {
            resultado["destino"] = destino
        }
        call.resolve(resultado)
        // Margem para extensões que ainda leem o arquivo logo depois de concluir.
        Apoio.apagar(pasta, depoisDe: apagarJa ? 0 : 60)
    }

    /// A folha não abriu: rejeita (o site volta ao caminho de antes) e apaga o PNG na hora,
    /// porque nenhum app recebeu o arquivo.
    func recusar(_ mensagem: String, _ codigo: String) {
        guard !encerrada else { return }
        encerrada = true

        call.reject(mensagem, codigo)
        Apoio.apagar(pasta)
    }
}

// MARK: - Apoio

/// Os bytes do PNG como o site mandou. O UIKit só confere que abrem como imagem: o que
/// vai para o pasteboard, para o arquivo da folha e para as Fotos é sempre o PNG original.
private struct ImagemRecebida {
    let dados: Data
}

/// Caixa para levar o identificador da foto do bloco de alteração até o fim do salvamento.
private final class FotoCriada {
    var identificador: String?
}

private enum Apoio {
    /// Chave oficial do Instagram (Meta, "Sharing to Stories") para a imagem de fundo.
    static let chaveFundoStories = "com.instagram.sharedSticker.backgroundImage"
    static let validadePasteboard: TimeInterval = 5 * 60
    static let enderecoStories = "instagram-stories://share"
    static let enderecoInstagram = "instagram://app"
    /// Quanto `sistema` espera antes de conferir se o UIKit aceitou a folha (e, se recusou,
    /// antes da nova tentativa).
    static let esperaApresentacao: TimeInterval = 0.4

    /// Onde ficam os PNGs entregues à folha do sistema (uma subpasta por chamada).
    static var pastaTemporaria: URL {
        return FileManager.default.temporaryDirectory.appendingPathComponent("instagram-share", isDirectory: true)
    }

    static func falha(_ motivo: String) -> [String: Any] {
        return ["aberto": false, "motivo": motivo]
    }

    @MainActor
    static func podeAbrir(_ endereco: String) -> Bool {
        guard let url = URL(string: endereco) else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    /// Resolve `{ aberto: true }` ou `falha_ao_abrir` pelo retorno do iOS.
    @MainActor
    static func abrir(_ url: URL, respondendo call: CAPPluginCall) {
        UIApplication.shared.open(url, options: [:]) { aberto in
            let resultado: [String: Any] = aberto ? ["aberto": true] : falha("falha_ao_abrir")
            call.resolve(resultado)
        }
    }

    /// PNG em base64 sem prefixo, como diz o contrato. Um prefixo `data:...;base64,`
    /// é tolerado por segurança. Só aceita o que o UIKit consegue abrir como imagem.
    static func decodificarImagem(_ texto: String?) -> ImagemRecebida? {
        guard var base64 = texto?.trimmingCharacters(in: .whitespacesAndNewlines), !base64.isEmpty else {
            return nil
        }
        if base64.hasPrefix("data:"), let virgula = base64.firstIndex(of: ",") {
            base64 = String(base64[base64.index(after: virgula)...])
        }
        guard let dados = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
              UIImage(data: dados) != nil else {
            return nil
        }
        return ImagemRecebida(dados: dados)
    }

    /// `instagram-stories://share?source_application=<App ID>`, só com App ID de dígitos.
    static func urlStories(appId: String?) -> URL? {
        let limpo = (appId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !limpo.isEmpty, limpo.count <= 32, limpo.allSatisfy({ "0123456789".contains($0) }) else {
            return nil
        }
        return URL(string: "\(enderecoStories)?source_application=\(limpo)")
    }

    /// `instagram://library?LocalIdentifier=<id>`. O identificador (ex.: `UUID/L0/001`)
    /// é codificado para valor de query; barras e hífens continuam legíveis.
    static func urlBiblioteca(identificador: String) -> URL? {
        var permitidos = CharacterSet.urlQueryAllowed
        permitidos.remove(charactersIn: "&=+#?")
        guard let codificado = identificador.addingPercentEncoding(withAllowedCharacters: permitidos) else {
            return nil
        }
        return URL(string: "instagram://library?LocalIdentifier=\(codificado)")
    }

    /// Permissão só de adicionar (iOS 14+): não dá acesso de leitura à galeria.
    /// O iOS só pergunta na primeira vez; depois responde direto com o estado salvo.
    static func pedirPermissaoParaAdicionar(_ concluir: @escaping (Bool) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            concluir(status == .authorized || status == .limited)
        }
    }

    /// Cria a foto e devolve o `localIdentifier` (ou nil se o salvamento falhar).
    /// Grava os bytes do PNG como recurso da foto: criar a partir de uma `UIImage`
    /// recodificaria em JPEG, com artefatos no texto sobre cor lisa do cartão.
    /// Os dois blocos rodam em filas do Photos, fora da main thread.
    static func salvarNasFotos(_ png: Data, _ concluir: @escaping (String?) -> Void) {
        let criada = FotoCriada()
        PHPhotoLibrary.shared().performChanges({
            let pedido = PHAssetCreationRequest.forAsset()
            pedido.addResource(with: .photo, data: png, options: nil)
            criada.identificador = pedido.placeholderForCreatedAsset?.localIdentifier
        }, completionHandler: { sucesso, _ in
            concluir(sucesso ? criada.identificador : nil)
        })
    }

    /// Nome do arquivo que aparece na folha: só o último componente, sem caracteres
    /// de controle nem separadores, sempre terminando em `.png`.
    static func nomeSeguro(_ pedido: String?) -> String {
        let proibidos = CharacterSet(charactersIn: "/\\:").union(.controlCharacters)
        var base = (pedido ?? "").components(separatedBy: proibidos).joined()
        if base.lowercased().hasSuffix(".png") {
            base = String(base.dropLast(4))
        }
        base = base.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines))
        if base.isEmpty {
            base = "Diariamente"
        }
        return String(base.prefix(100)) + ".png"
    }

    /// Apaga a pasta fora da main thread, opcionalmente depois de um intervalo.
    static func apagar(_ pasta: URL, depoisDe atraso: TimeInterval = 0) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + atraso) {
            try? FileManager.default.removeItem(at: pasta)
        }
    }
}

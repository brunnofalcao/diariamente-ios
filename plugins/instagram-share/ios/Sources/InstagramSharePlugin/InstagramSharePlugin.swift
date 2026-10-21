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
    /// para a foto criada. O Instagram nem sempre respeita o identificador; quem
    /// oferece a volta segura é o site, depois que esta chamada responde.
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
                Apoio.salvarNasFotos(png.imagem) { identificador in
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

    // MARK: - sistema ("Outros apps")

    /// Abre a folha nativa do iOS com o PNG como arquivo. Por ser nativa, não depende
    /// de um toque recente no JavaScript (o `navigator.share` depende). Resolve quando
    /// a folha fecha de vez; o arquivo temporário é apagado em seguida.
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
            guard let raiz = self?.bridge?.viewController else {
                Apoio.apagar(pasta)
                call.reject("Tela do app indisponível", "sem_tela")
                return
            }
            var topo = raiz
            while let acima = topo.presentedViewController {
                topo = acima
            }

            let entrega = EntregaDoSistema(call: call, pasta: pasta)
            if topo is UIActivityViewController {
                // Toque duplo: já existe uma folha aberta, que responde pela primeira chamada.
                entrega.finalizar(concluido: false, destino: nil)
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
            // iPad: a folha vira popover e precisa de âncora; fica no centro, sem seta.
            if let popover = folha.popoverPresentationController {
                popover.sourceView = topo.view
                popover.sourceRect = CGRect(x: topo.view.bounds.midX, y: topo.view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            topo.present(folha, animated: true) {
                entrega.apresentada = true
            }
            // Se o UIKit recusar a apresentação (tela em transição), a folha nunca aparece
            // e o bloco acima nunca roda: encerra para a Promise não ficar pendurada.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if !entrega.apresentada {
                    entrega.finalizar(concluido: false, destino: nil)
                }
            }
        }
    }
}

// MARK: - Entrega da folha do sistema

/// Garante que `sistema` resolva uma única vez, mesmo que o iOS chame o
/// `completionWithItemsHandler` mais de uma vez, e apaga o PNG temporário no fim.
private final class EntregaDoSistema {
    private let call: CAPPluginCall
    private let pasta: URL
    private var encerrada = false
    /// Marcado quando a animação de apresentação termina (só na main thread).
    var apresentada = false

    init(call: CAPPluginCall, pasta: URL) {
        self.call = call
        self.pasta = pasta
    }

    func finalizar(concluido: Bool, destino: String?) {
        guard !encerrada else { return }
        encerrada = true

        var resultado: [String: Any] = ["concluido": concluido]
        if concluido, let destino = destino, !destino.isEmpty {
            resultado["destino"] = destino
        }
        call.resolve(resultado)
        // Margem para extensões que ainda leem o arquivo logo depois de concluir.
        Apoio.apagar(pasta, depoisDe: 60)
    }
}

// MARK: - Apoio

private struct ImagemRecebida {
    let dados: Data
    let imagem: UIImage
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
              let imagem = UIImage(data: dados) else {
            return nil
        }
        return ImagemRecebida(dados: dados, imagem: imagem)
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
    /// Os dois blocos rodam em filas do Photos, fora da main thread.
    static func salvarNasFotos(_ imagem: UIImage, _ concluir: @escaping (String?) -> Void) {
        let criada = FotoCriada()
        PHPhotoLibrary.shared().performChanges({
            let pedido = PHAssetChangeRequest.creationRequestForAsset(from: imagem)
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

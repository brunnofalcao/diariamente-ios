//
//  DiariamenteWidget.swift
//  DiariamenteWidget — extensão WidgetKit do app Diariamente (iOS)
//
//  FASE 1 — conteúdo público, sem dados por usuário:
//    símbolo 2a · "Dia N" · provocação do dia · autor · CTA curto.
//  Ritmo do dia, ofensiva e próxima ação ficam para a FASE 2 (App Group + bridge).
//
//  Fonte de dados: GET https://app.diariamente.club/api/widget/today (público, sem login)
//  Resposta: { ok, vazio, data, day_id, dia_ano, pergunta, pergunta_curta, autor, autor_raw }
//
//  Compatibilidade:
//    - Alvo do target: iOS 16 (compila também com alvo 15).
//    - Famílias de Lock Screen (accessory*) só em iOS 16+ (guardadas por #available).
//    - containerBackground / widgetContentMargins só em iOS 17+ (guardados por #available).
//  Sem App Group, sem Intents, sem dependências externas.
//

import Foundation
import WidgetKit
import SwiftUI

// MARK: - Cores da marca (valores exatos do brandbook)

enum DiarCor {
    static let s0     = Color(red: 0x0A / 255.0, green: 0x0E / 255.0, blue: 0x0E / 255.0) // fundo escuro base
    static let s1     = Color(red: 0x11 / 255.0, green: 0x16 / 255.0, blue: 0x16 / 255.0) // superfície escura
    static let n900   = Color(red: 0x13 / 255.0, green: 0x19 / 255.0, blue: 0x18 / 255.0) // texto sobre teal (regra da marca)
    static let n600   = Color(red: 0x37 / 255.0, green: 0x40 / 255.0, blue: 0x3F / 255.0) // texto da citação em cartão claro
    static let n400   = Color(red: 0x6B / 255.0, green: 0x77 / 255.0, blue: 0x77 / 255.0) // texto secundário em cartão claro
    static let teal   = Color(red: 0x27 / 255.0, green: 0xBD / 255.0, blue: 0xBE / 255.0) // P500 — cor-assinatura
    static let ambar  = Color(red: 0xF5 / 255.0, green: 0xB7 / 255.0, blue: 0x31 / 255.0) // reservado à ofensiva (fase 2)
    static let branco = Color.white
}

// MARK: - Fuso de São Paulo (o conteúdo vira à meia-noite de Brasília)

enum FusoSP {
    static let fuso: TimeZone = TimeZone(identifier: "America/Sao_Paulo") ?? TimeZone.current

    static var calendario: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = fuso
        c.locale = Locale(identifier: "pt_BR")
        return c
    }

    /// Próxima meia-noite (00:00) em São Paulo depois da data informada.
    static func proximaMeiaNoite(depoisDe data: Date) -> Date {
        let cal = calendario
        let inicioDoDia = cal.startOfDay(for: data)
        if let proxima = cal.date(byAdding: .day, value: 1, to: inicioDoDia), proxima > data {
            return proxima
        }
        return data.addingTimeInterval(24 * 60 * 60) // fallback defensivo
    }

    /// "Sábado, 12 de setembro" — em pt-BR, no fuso de São Paulo.
    static func dataLonga(_ data: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.timeZone = fuso
        f.dateFormat = "EEEE, d 'de' MMMM"
        return capitalizarInicial(f.string(from: data))
    }

    private static func capitalizarInicial(_ s: String) -> String {
        guard let primeira = s.first else { return s }
        return String(primeira).uppercased() + String(s.dropFirst())
    }
}

// MARK: - Resposta da API (todos os campos opcionais e tolerantes a tipo)

struct WidgetResponse: Decodable {
    let ok: Bool
    let vazio: Bool
    let data: String?          // "YYYY-MM-DD" em São Paulo
    let diaAno: Int?           // dia_ano (1…366)
    let pergunta: String?
    let perguntaCurta: String?
    let autor: String?

    private enum Chaves: String, CodingKey {
        case ok, vazio, data, pergunta, autor
        case diaAno = "dia_ano"
        case perguntaCurta = "pergunta_curta"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Chaves.self)
        ok = (try? c.decodeIfPresent(Bool.self, forKey: .ok)) ?? false
        vazio = (try? c.decodeIfPresent(Bool.self, forKey: .vazio)) ?? true
        data = try? c.decodeIfPresent(String.self, forKey: .data)
        pergunta = try? c.decodeIfPresent(String.self, forKey: .pergunta)
        perguntaCurta = try? c.decodeIfPresent(String.self, forKey: .perguntaCurta)
        autor = try? c.decodeIfPresent(String.self, forKey: .autor)

        // dia_ano pode chegar como Int, Double ou String — nunca derruba o decode.
        if let n = try? c.decodeIfPresent(Int.self, forKey: .diaAno) {
            diaAno = n
        } else if let d = try? c.decodeIfPresent(Double.self, forKey: .diaAno) {
            diaAno = Int(d)
        } else if let s = try? c.decodeIfPresent(String.self, forKey: .diaAno) {
            diaAno = Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            diaAno = nil
        }
    }
}

// MARK: - Cache local (UserDefaults padrão da extensão, sem App Group)

struct ProvocacaoSalva: Codable {
    let data: String?
    let diaAno: Int?
    let pergunta: String
    let perguntaCurta: String
    let autor: String?
    let salvaEm: Date
}

enum CacheProvocacao {
    private static let chave = "club.diariamente.widget.ultimaProvocacao.v1"

    static func salvar(_ item: ProvocacaoSalva) {
        guard let dados = try? JSONEncoder().encode(item) else { return }
        UserDefaults.standard.set(dados, forKey: chave)
    }

    static func ler() -> ProvocacaoSalva? {
        guard let dados = UserDefaults.standard.data(forKey: chave) else { return nil }
        return try? JSONDecoder().decode(ProvocacaoSalva.self, from: dados)
    }
}

// MARK: - Entrada da timeline

struct ProvocacaoEntry: TimelineEntry {
    enum Estado {
        case provocacao   // conteúdo do dia (da rede ou do cache)
        case vazio        // servidor respondeu vazio=true — estado honesto
        case semConexao   // falha de rede e nenhum cache disponível
        case virada       // entrada agendada para a meia-noite (novo dia, ainda sem dados)
    }

    let date: Date
    let estado: Estado
    let diaAno: Int?
    let pergunta: String
    let perguntaCurta: String
    let autor: String?
    let doCache: Bool     // true quando veio do cache por falha de rede

    // Fabricas
    static func exemplo(date: Date) -> ProvocacaoEntry {
        let p = "O que você está adiando que caberia em dez minutos hoje?"
        return ProvocacaoEntry(date: date, estado: .provocacao, diaAno: 128,
                               pergunta: p, perguntaCurta: p, autor: "Diariamente", doCache: false)
    }

    static func deItem(_ item: ProvocacaoSalva, date: Date, doCache: Bool) -> ProvocacaoEntry {
        ProvocacaoEntry(date: date, estado: .provocacao, diaAno: item.diaAno,
                        pergunta: item.pergunta, perguntaCurta: item.perguntaCurta,
                        autor: item.autor, doCache: doCache)
    }

    static func vazio(date: Date) -> ProvocacaoEntry {
        ProvocacaoEntry(date: date, estado: .vazio, diaAno: nil, pergunta: "", perguntaCurta: "", autor: nil, doCache: false)
    }

    static func semConexao(date: Date) -> ProvocacaoEntry {
        ProvocacaoEntry(date: date, estado: .semConexao, diaAno: nil, pergunta: "", perguntaCurta: "", autor: nil, doCache: false)
    }

    static func virada(em date: Date) -> ProvocacaoEntry {
        ProvocacaoEntry(date: date, estado: .virada, diaAno: nil, pergunta: "", perguntaCurta: "", autor: nil, doCache: false)
    }
}

// Textos de apresentação por estado (uma única fonte para todas as famílias).
extension ProvocacaoEntry {
    /// "Dia 128" / "Hoje" / "Sem conexão" / "Novo dia"
    var rotuloDia: String {
        switch estado {
        case .provocacao:
            if let n = diaAno { return "Dia " + String(n) }
            return "Hoje"
        case .vazio:       return "Hoje"
        case .semConexao:  return "Sem conexão"
        case .virada:      return "Novo dia"
        }
    }

    /// Kicker da família média: "Provocação · Dia 128"
    var kicker: String { "Provocação · " + rotuloDia }

    /// Texto principal (citação com aspas tipográficas ou mensagem de estado).
    var textoLongo: String {
        switch estado {
        case .provocacao:  return "\u{201C}" + pergunta + "\u{201D}"
        case .vazio:       return "A provocação de hoje ainda não foi publicada."
        case .semConexao:  return "Não foi possível carregar a provocação de hoje."
        case .virada:      return "Um novo dia começou. A provocação de hoje já está no app."
        }
    }

    /// Versão curta com aspas (família pequena).
    var textoCurtoComAspas: String {
        switch estado {
        case .provocacao:  return "\u{201C}" + perguntaCurta + "\u{201D}"
        default:           return textoLongo
        }
    }

    /// Versão curta sem aspas (Lock Screen).
    var textoCurto: String {
        switch estado {
        case .provocacao:  return perguntaCurta
        case .vazio:       return "Ainda sem provocação hoje."
        case .semConexao:  return "Sem conexão. Abra o app."
        case .virada:      return "A provocação de hoje já está no app."
        }
    }

    /// Linha do autor (só no estado com conteúdo). Marca "offline" quando veio do cache.
    var linhaAutor: String? {
        guard estado == .provocacao, let a = autor, !a.isEmpty else { return nil }
        return doCache ? a + " · offline" : a
    }

    /// CTA por extenso (média/grande).
    var cta: String {
        switch estado {
        case .provocacao:  return "Abrir para concluir o dia"
        case .vazio:       return "Abrir o app"
        case .semConexao:  return "Tentar no app"
        case .virada:      return "Abrir para ler"
        }
    }

    /// CTA curto (pequena).
    var ctaCurto: String { "Abrir" }

    /// Título e subtítulo do bloco do símbolo (família grande).
    var tituloGrande: String {
        switch estado {
        case .provocacao:  return "Provocação de hoje"
        case .vazio:       return "Ainda sem provocação"
        case .semConexao:  return "Sem conexão"
        case .virada:      return "Novo dia"
        }
    }

    var subtituloGrande: String {
        switch estado {
        case .provocacao:  return doCache ? "Sem conexão · mostrando a última salva." : "Leia, reflita e registre uma ação concreta."
        case .vazio:       return "Volte mais tarde ou abra o app."
        case .semConexao:  return "Toque para tentar de novo no app."
        case .virada:      return "O widget atualiza em instantes."
        }
    }

    /// Linha única (accessoryInline).
    var linhaInline: String {
        switch estado {
        case .provocacao:  return rotuloDia + " · " + perguntaCurta
        case .vazio:       return "Diariamente · sem provocação hoje"
        case .semConexao:  return "Diariamente · sem conexão"
        case .virada:      return "Diariamente · novo dia"
        }
    }
}

// MARK: - Rede

enum WidgetAPI {
    enum Resultado {
        case sucesso(WidgetResponse)
        case falha
    }

    static let endpoint = URL(string: "https://app.diariamente.club/api/widget/today")

    static func buscar(_ completion: @escaping (Resultado) -> Void) {
        guard let url = endpoint else { completion(.falha); return }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let tarefa = URLSession.shared.dataTask(with: req) { dados, resposta, erro in
            if erro != nil { completion(.falha); return }
            if let http = resposta as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                completion(.falha); return
            }
            guard let dados = dados,
                  let r = try? JSONDecoder().decode(WidgetResponse.self, from: dados),
                  r.ok else {
                completion(.falha); return
            }
            completion(.sucesso(r))
        }
        tarefa.resume()
    }
}

// Junta rede + cache e devolve sempre UMA entrada (nunca falha).
enum Carregador {
    static func carregar(agora: Date, completion: @escaping (ProvocacaoEntry) -> Void) {
        WidgetAPI.buscar { resultado in
            switch resultado {
            case .sucesso(let r):
                let perguntaLimpa = (r.pergunta ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if r.vazio || perguntaLimpa.isEmpty {
                    // Estado vazio honesto — não usa cache antigo para "preencher".
                    completion(.vazio(date: agora))
                    return
                }
                let curtaLimpa = (r.perguntaCurta ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let autorLimpo = (r.autor ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let item = ProvocacaoSalva(data: r.data,
                                           diaAno: r.diaAno,
                                           pergunta: perguntaLimpa,
                                           perguntaCurta: curtaLimpa.isEmpty ? perguntaLimpa : curtaLimpa,
                                           autor: autorLimpo.isEmpty ? nil : autorLimpo,
                                           salvaEm: agora)
                CacheProvocacao.salvar(item)
                completion(.deItem(item, date: agora, doCache: false))

            case .falha:
                // Erro de rede: último valor em cache, se houver.
                if let item = CacheProvocacao.ler() {
                    completion(.deItem(item, date: agora, doCache: true))
                } else {
                    completion(.semConexao(date: agora))
                }
            }
        }
    }
}

// MARK: - Provider (timeline: agora + próxima meia-noite; recarga em até 6h)

struct ProvocacaoProvider: TimelineProvider {
    typealias Entry = ProvocacaoEntry

    func placeholder(in context: Context) -> ProvocacaoEntry {
        .exemplo(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (ProvocacaoEntry) -> Void) {
        if context.isPreview {
            completion(.exemplo(date: Date()))
            return
        }
        let agora = Date()
        Carregador.carregar(agora: agora) { completion($0) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ProvocacaoEntry>) -> Void) {
        let agora = Date()
        Carregador.carregar(agora: agora) { entradaAgora in
            let meiaNoite = FusoSP.proximaMeiaNoite(depoisDe: agora)
            let entradaVirada = ProvocacaoEntry.virada(em: meiaNoite)
            // Recarrega logo após a meia-noite ou em 6h — o que vier primeiro.
            let seisHoras = agora.addingTimeInterval(6 * 60 * 60)
            let recarga = min(meiaNoite.addingTimeInterval(2 * 60), seisHoras)
            completion(Timeline(entries: [entradaAgora, entradaVirada], policy: .after(recarga)))
        }
    }
}

// MARK: - Símbolo 2a (7 cápsulas, abertura às 6h, gradação horária — NUNCA gira)

struct Simbolo2a: View {
    let size: CGFloat
    let cor: Color

    private struct Capsula {
        let angulo: Double     // graus, sentido horário, 0 = 12h
        let opacidade: Double
    }

    // Grade 100×100: cápsula vertical de y=20 a y=38 (comprimento 18), espessura 8.5,
    // centro da cápsula a 21 do centro. 6h (180°) fica aberta; 100% às 12h.
    private static let capsulas: [Capsula] = [
        Capsula(angulo: 45,  opacidade: 0.30),
        Capsula(angulo: 90,  opacidade: 0.40),
        Capsula(angulo: 135, opacidade: 0.50),
        Capsula(angulo: 225, opacidade: 0.60),
        Capsula(angulo: 270, opacidade: 0.75),
        Capsula(angulo: 315, opacidade: 0.90),
        Capsula(angulo: 0,   opacidade: 1.00)
    ]

    private var escala: CGFloat { size / 100 }

    var body: some View {
        ZStack {
            ForEach(Self.capsulas.indices, id: \.self) { i in
                capsula(Self.capsulas[i])
            }
        }
        .frame(width: size, height: size)
    }

    // Transform estático: offset radial + rotação fixa por cápsula (sem animação).
    private func capsula(_ c: Capsula) -> some View {
        Capsule()
            .fill(cor.opacity(c.opacidade))
            .frame(width: 8.5 * escala, height: 18 * escala)
            .offset(y: -21 * escala)
            .rotationEffect(.degrees(c.angulo))
    }
}

// MARK: - Peças de UI reutilizáveis

/// Kicker em caixa alta, sans, numerais tabulares.
struct Rotulo: View {
    let texto: String
    let cor: Color

    var body: some View {
        Text(verbatim: texto.uppercased())
            .font(.system(size: 10, weight: .bold).monospacedDigit())
            .tracking(0.8)
            .foregroundColor(cor)
            .lineLimit(1)
    }
}

/// Pílula de CTA. Padrão: fundo teal com texto N900 (nunca branco sobre teal).
struct Pilula: View {
    let texto: String
    var fundo: Color = DiarCor.teal
    var corTexto: Color = DiarCor.n900
    var altura: CGFloat = 22

    var body: some View {
        Text(verbatim: texto)
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(corTexto)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: altura)
            .background(Capsule().fill(fundo))
            .layoutPriority(1)
    }
}

// MARK: - Compatibilidade de fundo e margens (iOS 16 vs 17+)

@available(iOS 17.0, *)
fileprivate struct PreenchimentoComMargens: ViewModifier {
    @Environment(\.widgetContentMargins) private var margens
    let alvo: EdgeInsets

    // No iOS 17 o sistema já aplica margens; só completamos a diferença.
    func body(content: Content) -> some View {
        content.padding(EdgeInsets(
            top: max(0, alvo.top - margens.top),
            leading: max(0, alvo.leading - margens.leading),
            bottom: max(0, alvo.bottom - margens.bottom),
            trailing: max(0, alvo.trailing - margens.trailing)
        ))
    }
}

extension View {
    /// Fundo S0 nas famílias de Home: containerBackground (iOS 17+) ou ZStack (iOS 16).
    @ViewBuilder func diarFundoHome() -> some View {
        if #available(iOS 17.0, *) {
            self.containerBackground(for: .widget) { DiarCor.s0 }
        } else {
            ZStack {
                DiarCor.s0
                self
            }
        }
    }

    /// Acessórios de Lock Screen: fundo transparente (o sistema tinge).
    @ViewBuilder func diarFundoAcessorio() -> some View {
        if #available(iOS 17.0, *) {
            self.containerBackground(for: .widget) { Color.clear }
        } else {
            self
        }
    }

    /// Preenchimento interno alvo, descontando as margens do sistema no iOS 17+.
    @ViewBuilder func diarPreenchimento(_ alvo: EdgeInsets) -> some View {
        if #available(iOS 17.0, *) {
            self.modifier(PreenchimentoComMargens(alvo: alvo))
        } else {
            self.padding(alvo)
        }
    }
}

// MARK: - Famílias de Home Screen

/// systemSmall (2×2): símbolo + "Dia N" + citação curta + autor + pílula "Abrir".
struct PequenoView: View {
    let entry: ProvocacaoEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                Simbolo2a(size: 22, cor: DiarCor.teal)
                Spacer(minLength: 4)
                Rotulo(texto: entry.rotuloDia, cor: DiarCor.teal)
            }

            Text(verbatim: entry.textoCurtoComAspas)
                .font(.system(size: 13, weight: .regular, design: .serif))
                .italic()
                .lineSpacing(2)
                .foregroundColor(DiarCor.branco.opacity(0.9))
                .lineLimit(4)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            HStack(alignment: .center) {
                if let autor = entry.linhaAutor {
                    Text(verbatim: autor)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DiarCor.branco.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Pilula(texto: entry.ctaCurto, altura: 22)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .diarPreenchimento(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
    }
}

/// systemMedium (4×2): kicker "Provocação · Dia N" + citação + autor + CTA.
struct MedioView: View {
    let entry: ProvocacaoEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Simbolo2a(size: 18, cor: DiarCor.teal)
                Rotulo(texto: entry.kicker, cor: DiarCor.teal)
                Spacer(minLength: 0)
            }

            Text(verbatim: entry.textoLongo)
                .font(.system(size: 15, weight: .regular, design: .serif))
                .italic()
                .lineSpacing(3)
                .foregroundColor(DiarCor.branco.opacity(0.9))
                .lineLimit(3)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            HStack(alignment: .center) {
                if let autor = entry.linhaAutor {
                    Text(verbatim: autor)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DiarCor.branco.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Pilula(texto: entry.cta, altura: 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .diarPreenchimento(EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 20))
    }
}

/// systemLarge (4×4): data + "Dia N", símbolo grande, cartão branco com a citação, linha de CTA.
struct GrandeView: View {
    let entry: ProvocacaoEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Cabeçalho
            HStack(alignment: .center) {
                Rotulo(texto: FusoSP.dataLonga(entry.date), cor: DiarCor.branco.opacity(0.5))
                Spacer(minLength: 8)
                Rotulo(texto: entry.rotuloDia, cor: DiarCor.teal)
            }

            // Símbolo + título (na fase 2 este bloco recebe o anel de ritmo)
            HStack(alignment: .center, spacing: 14) {
                Simbolo2a(size: 56, cor: DiarCor.teal)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: entry.tituloGrande)
                        .font(.system(size: 19, weight: .regular, design: .serif))
                        .foregroundColor(DiarCor.branco)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text(verbatim: entry.subtituloGrande)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(DiarCor.branco.opacity(0.55))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }

            // Cartão branco com a provocação
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: entry.textoLongo)
                    .font(.system(size: 14, weight: .regular, design: .serif))
                    .italic()
                    .lineSpacing(3)
                    .foregroundColor(DiarCor.n600)
                    .lineLimit(4)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(alignment: .center) {
                    if let autor = entry.linhaAutor {
                        Text(verbatim: autor)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DiarCor.n400)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if entry.estado == .provocacao {
                        Pilula(texto: "Ler", fundo: DiarCor.n900, corTexto: DiarCor.branco, altura: 24)
                    }
                }
            }
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(DiarCor.branco))

            Spacer(minLength: 0)

            // Linha de CTA (na fase 2 vira a próxima ação pendente)
            HStack(alignment: .center, spacing: 12) {
                Simbolo2a(size: 22, cor: DiarCor.teal)
                Text(verbatim: entry.cta)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DiarCor.branco.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(DiarCor.teal)
            }
            .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(DiarCor.s1))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(DiarCor.branco.opacity(0.06), lineWidth: 1))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .diarPreenchimento(EdgeInsets(top: 22, leading: 22, bottom: 22, trailing: 22))
    }
}

/// Roteia as famílias de Home e aplica o fundo S0.
struct HomeView: View {
    let entry: ProvocacaoEntry
    let family: WidgetFamily

    var body: some View {
        Group {
            switch family {
            case .systemMedium:
                MedioView(entry: entry)
            case .systemLarge:
                GrandeView(entry: entry)
            default:
                PequenoView(entry: entry)
            }
        }
        .diarFundoHome()
    }
}

// MARK: - Famílias de Lock Screen (iOS 16+, monocromáticas — o sistema tinge)

@available(iOS 16.0, *)
struct AcessorioView: View {
    let entry: ProvocacaoEntry
    let family: WidgetFamily

    static func ehAcessorio(_ f: WidgetFamily) -> Bool {
        switch f {
        case .accessoryCircular, .accessoryRectangular, .accessoryInline:
            return true
        default:
            return false
        }
    }

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                circular
            case .accessoryInline:
                Text(verbatim: entry.linhaInline)
            default:
                retangular
            }
        }
        .diarFundoAcessorio()
    }

    // Círculo: só o símbolo 2a em branco sobre o fundo padrão do sistema.
    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            Simbolo2a(size: 34, cor: DiarCor.branco)
        }
        .widgetAccentable()
    }

    // Retângulo: símbolo + "Dia N" + provocação curta.
    private var retangular: some View {
        HStack(alignment: .center, spacing: 8) {
            Simbolo2a(size: 26, cor: DiarCor.branco)
                .widgetAccentable()
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: entry.rotuloDia)
                    .font(.system(size: 14, weight: .bold).monospacedDigit())
                    .lineLimit(1)
                Text(verbatim: entry.textoCurto)
                    .font(.system(size: 11, weight: .regular))
                    .opacity(0.8)
                    .lineLimit(3)
                    .minimumScaleFactor(0.9)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - View raiz (decide Home vs Lock Screen)

struct DiariamenteWidgetEntryView: View {
    let entry: ProvocacaoEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if #available(iOS 16.0, *) {
            if AcessorioView.ehAcessorio(family) {
                AcessorioView(entry: entry, family: family)
            } else {
                HomeView(entry: entry, family: family)
            }
        } else {
            HomeView(entry: entry, family: family)
        }
    }
}

// MARK: - Widget + Bundle

struct DiariamenteWidget: Widget {
    let kind: String = "DiariamenteWidget"

    // Acessórios só entram na lista quando o SO suporta (iOS 16+).
    static var familias: [WidgetFamily] {
        var lista: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge]
        if #available(iOS 16.0, *) {
            lista.append(contentsOf: [.accessoryRectangular, .accessoryInline, .accessoryCircular])
        }
        return lista
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ProvocacaoProvider()) { entry in
            DiariamenteWidgetEntryView(entry: entry)
                .widgetURL(URL(string: "https://app.diariamente.club")) // deep link: abre o app
        }
        .configurationDisplayName("Provocação de Hoje")
        .description("O símbolo, o dia e a provocação do Diariamente na sua tela.")
        .supportedFamilies(Self.familias)
    }
}

@main
struct DiariamenteWidgetBundle: WidgetBundle {
    var body: some Widget {
        DiariamenteWidget()
    }
}

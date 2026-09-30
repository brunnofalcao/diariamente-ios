//
//  DiariamenteWidget.swift
//  DiariamenteWidget — extensão WidgetKit do app Diariamente (iOS)
//
//  FASE 1 — conteúdo público, sem dados por usuário:
//    símbolo 2a · "Dia N" · provocação do dia · autor · CTA curto.
//  Ritmo do dia, ofensiva e próxima ação ficam para a FASE 2 (App Group + bridge).
//
//  Fonte de dados: GET https://app.diariamente.club/api/widget/today?lang=<pt-BR|es>
//  (público, sem login)
//  Resposta: { ok, vazio, data, day_id, dia_ano, pergunta, pergunta_curta, autor, autor_raw }
//  Sem conteúdo no idioma pedido: { ok: true, vazio: true, data, pergunta: null, autor: null }
//
//  Idioma: o widget não enxerga a conta (sem App Group), então segue o idioma
//  preferido do APARELHO — espanhol se o primeiro idioma for "es", senão pt-BR.
//  Conteúdo, textos fixos, datas e cache local saem todos nesse mesmo idioma.
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

    /// Só para aritmética de datas (início do dia, +1 dia) — o locale não interfere
    /// nessas contas. O texto por extenso sai em `dataLonga`, no idioma do widget.
    static var calendario: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = fuso
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

    /// "2026-09-22" no fuso de São Paulo — mesmo formato do campo `data` da API.
    static func chaveDoDia(_ data: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = fuso
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: data)
    }

    /// "Sábado, 12 de setembro" / "Sábado, 12 de septiembre" — no idioma do widget,
    /// sempre no fuso de São Paulo (é nele que o conteúdo vira).
    static func dataLonga(_ data: Date, idioma: Idioma) -> String {
        let f = DateFormatter()
        f.locale = idioma.localeDatas
        f.timeZone = fuso
        f.dateFormat = idioma.textos.formatoDataLonga
        return capitalizarInicial(f.string(from: data))
    }

    private static func capitalizarInicial(_ s: String) -> String {
        guard let primeira = s.first else { return s }
        return String(primeira).uppercased() + String(s.dropFirst())
    }
}

// MARK: - Idioma (pt-BR ou es)

enum Idioma: String {
    case pt = "pt-BR"   // rawValue = valor do ?lang= que o servidor aceita
    case es = "es"

    /// "es", "es-MX", "es-419", "es_ES" → .es; "pt", "pt-BR", "pt_PT" → .pt; resto → nil.
    /// Compara o código de idioma inteiro (antes do "-"/"_"), não um prefixo solto.
    init?(codigo: String) {
        let base = codigo.split(whereSeparator: { $0 == "-" || $0 == "_" }).first
        switch base.map({ $0.lowercased() }) {
        case "es": self = .es
        case "pt": self = .pt
        default:   return nil
        }
    }

    /// O widget não tem acesso à conta (sem App Group): vale o primeiro idioma
    /// preferido do aparelho. `Locale.preferredLanguages` e não
    /// `Bundle.main.preferredLocalizations` — a extensão só declara pt-BR, então o
    /// bundle resolveria sempre pt. Qualquer idioma que não seja espanhol fica em
    /// pt-BR, a língua de origem do conteúdo.
    static var doAparelho: Idioma {
        guard let primeiro = Locale.preferredLanguages.first else { return .pt }
        return Idioma(codigo: primeiro) == .es ? .es : .pt
    }

    var localeDatas: Locale { Locale(identifier: self == .es ? "es" : "pt_BR") }

    var textos: TextosWidget { self == .es ? .es : .pt }
}

/// Textos fixos do widget, um conjunto por idioma. Dicionário em código e não
/// Localizable.strings: o alvo é montado por script (add_widget_target.rb, sem
/// pastas .lproj) e o idioma é escolhido pelo próprio widget, não pelo bundle.
/// Struct com `let` em vez de [String: String]: esquecer uma tradução não compila.
struct TextosWidget {
    // Rótulos curtos (kicker, "Dia N", Lock Screen)
    let dia: String
    let hoje: String
    let ultimaSalva: String
    let semConexao: String
    let novoDia: String
    let provocacao: String
    // Texto principal por estado (média/grande) e versão curta (pequena/Lock Screen)
    let longoVazio: String
    let longoSemConexao: String
    let longoVirada: String
    let curtoVazio: String
    let curtoSemConexao: String
    let curtoVirada: String
    // Complemento da linha do autor
    let autorOffline: String
    let autorNaoEHoje: String
    // Chamadas para abrir o app
    let ctaProvocacao: String
    let ctaVazio: String
    let ctaSemConexao: String
    let ctaVirada: String
    let ctaCurto: String
    let ctaLer: String
    // Família grande
    let tituloProvocacao: String
    let tituloVazio: String
    let subtituloProvocacao: String
    let subtituloOffline: String
    let subtituloDesatualizado: String
    let subtituloVazio: String
    let subtituloSemConexao: String
    let subtituloVirada: String
    // Lock Screen em linha única
    let inlineVazio: String
    let inlineSemConexao: String
    let inlineVirada: String
    // Galeria de widgets (nome, descrição e exemplo da prévia)
    let nomeWidget: String
    let descricaoWidget: String
    let exemploPergunta: String
    // Data por extenso do cabeçalho da família grande
    let formatoDataLonga: String

    static let pt = TextosWidget(
        dia: "Dia",
        hoje: "Hoje",
        ultimaSalva: "Última salva",
        semConexao: "Sem conexão",
        novoDia: "Novo dia",
        provocacao: "Provocação",
        longoVazio: "A provocação de hoje ainda não foi publicada.",
        longoSemConexao: "Não foi possível carregar a provocação de hoje.",
        longoVirada: "Um novo dia começou. A provocação de hoje já está no app.",
        curtoVazio: "Ainda sem provocação hoje.",
        curtoSemConexao: "Sem conexão. Abra o app.",
        curtoVirada: "A provocação de hoje já está no app.",
        autorOffline: "offline",
        autorNaoEHoje: "não é a de hoje",
        ctaProvocacao: "Abrir para concluir o dia",
        ctaVazio: "Abrir o app",
        ctaSemConexao: "Tentar no app",
        ctaVirada: "Abrir para ler",
        ctaCurto: "Abrir",
        ctaLer: "Ler",
        tituloProvocacao: "Provocação de hoje",
        tituloVazio: "Ainda sem provocação",
        subtituloProvocacao: "Leia, reflita e registre uma ação concreta.",
        subtituloOffline: "Sem conexão · mostrando a última salva.",
        subtituloDesatualizado: "Sem conexão — esta não é a provocação de hoje.",
        subtituloVazio: "Volte mais tarde ou abra o app.",
        subtituloSemConexao: "Toque para tentar de novo no app.",
        subtituloVirada: "O widget atualiza em instantes.",
        inlineVazio: "Diariamente · sem provocação hoje",
        inlineSemConexao: "Diariamente · sem conexão",
        inlineVirada: "Diariamente · novo dia",
        nomeWidget: "Provocação de Hoje",
        descricaoWidget: "O símbolo, o dia e a provocação do Diariamente na sua tela.",
        exemploPergunta: "O que você está adiando que caberia em dez minutos hoje?",
        formatoDataLonga: "EEEE, d 'de' MMMM"
    )

    // Em espanhol o vazio é o estado normal enquanto não houver provocações em es:
    // ele diz que o conteúdo vem no idioma da pessoa, e nunca cai para o português.
    // Pelo mesmo motivo a virada não promete "já está no app" — pode não estar.
    // Vocabulário alinhado ao app web (public/i18n/es.json, repositório diariamente):
    // "Provocación de hoy", "Día N", "Sin conexión", "la app", "completar".
    static let es = TextosWidget(
        dia: "Día",
        hoje: "Hoy",
        ultimaSalva: "Última guardada",
        semConexao: "Sin conexión",
        novoDia: "Nuevo día",
        provocacao: "Provocación",
        longoVazio: "La provocación del día llega pronto en tu idioma.",
        longoSemConexao: "No se pudo cargar la provocación de hoy.",
        longoVirada: "Empezó un nuevo día.",
        curtoVazio: "Pronto en tu idioma.",
        curtoSemConexao: "Sin conexión. Abre la app.",
        curtoVirada: "Empezó un nuevo día.",
        autorOffline: "sin conexión",
        autorNaoEHoje: "no es la de hoy",
        ctaProvocacao: "Abrir para completar el día",
        ctaVazio: "Abrir la app",
        ctaSemConexao: "Intentar en la app",
        ctaVirada: "Abrir la app",
        ctaCurto: "Abrir",
        ctaLer: "Leer",
        tituloProvocacao: "Provocación de hoy",
        tituloVazio: "Pronto en tu idioma",
        subtituloProvocacao: "Lee, reflexiona y registra una acción concreta.",
        subtituloOffline: "Sin conexión · mostrando la última guardada.",
        subtituloDesatualizado: "Sin conexión — esta no es la provocación de hoy.",
        subtituloVazio: "Vuelve más tarde o abre la app.",
        subtituloSemConexao: "Toca para intentarlo de nuevo en la app.",
        subtituloVirada: "El widget se actualiza en instantes.",
        inlineVazio: "Diariamente · pronto en tu idioma",
        inlineSemConexao: "Diariamente · sin conexión",
        inlineVirada: "Diariamente · nuevo día",
        nomeWidget: "Provocación de Hoy",
        descricaoWidget: "El símbolo, el día y la provocación de Diariamente en tu pantalla.",
        exemploPergunta: "¿Qué estás posponiendo que cabría en diez minutos hoy?",
        formatoDataLonga: "EEEE, d 'de' MMMM"
    )
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
    let lang: String?          // o servidor hoje NÃO devolve; se um dia ecoar, é conferido

    private enum Chaves: String, CodingKey {
        case ok, vazio, data, pergunta, autor, lang
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
        lang = try? c.decodeIfPresent(String.self, forKey: .lang)

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
    let idioma: String?        // rawValue de Idioma; nil = gravado antes do suporte a es (era pt)
}

/// Um cache POR IDIOMA: trocar o idioma do aparelho e ficar sem rede não pode exibir
/// a última provocação do outro idioma. O pt mantém a chave antiga, então quem já
/// tem o widget instalado não perde o cache na atualização (tudo o que foi gravado
/// antes desta versão era pt).
enum CacheProvocacao {
    private static func chave(_ idioma: Idioma) -> String {
        let base = "club.diariamente.widget.ultimaProvocacao.v1"
        return idioma == .pt ? base : base + "." + idioma.rawValue
    }

    static func salvar(_ item: ProvocacaoSalva, idioma: Idioma) {
        guard let dados = try? JSONEncoder().encode(item) else { return }
        UserDefaults.standard.set(dados, forKey: chave(idioma))
    }

    static func ler(idioma: Idioma) -> ProvocacaoSalva? {
        guard let dados = UserDefaults.standard.data(forKey: chave(idioma)),
              let item = try? JSONDecoder().decode(ProvocacaoSalva.self, from: dados) else { return nil }
        // A chave já separa os idiomas; conferir o campo gravado é a segunda trava.
        guard (item.idioma ?? Idioma.pt.rawValue) == idioma.rawValue else { return nil }
        return item
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
    let desatualizado: Bool  // cache de um dia ANTERIOR: não pode se passar pela de hoje
    // Idioma em que o conteúdo foi buscado. As views tiram os textos fixos DAQUI, e
    // não do aparelho no momento do desenho: rótulo e provocação saem sempre na
    // mesma língua, mesmo que o idioma mude entre a busca e a próxima recarga.
    let idioma: Idioma

    var t: TextosWidget { idioma.textos }

    // Fabricas
    static func exemplo(date: Date, idioma: Idioma) -> ProvocacaoEntry {
        let p = idioma.textos.exemploPergunta
        return ProvocacaoEntry(date: date, estado: .provocacao, diaAno: 128,
                               pergunta: p, perguntaCurta: p, autor: "Diariamente",
                               doCache: false, desatualizado: false, idioma: idioma)
    }

    static func deItem(_ item: ProvocacaoSalva, date: Date, idioma: Idioma, doCache: Bool, desatualizado: Bool = false) -> ProvocacaoEntry {
        ProvocacaoEntry(date: date, estado: .provocacao, diaAno: item.diaAno,
                        pergunta: item.pergunta, perguntaCurta: item.perguntaCurta,
                        autor: item.autor, doCache: doCache, desatualizado: desatualizado, idioma: idioma)
    }

    static func vazio(date: Date, idioma: Idioma) -> ProvocacaoEntry {
        ProvocacaoEntry(date: date, estado: .vazio, diaAno: nil, pergunta: "", perguntaCurta: "", autor: nil, doCache: false, desatualizado: false, idioma: idioma)
    }

    static func semConexao(date: Date, idioma: Idioma) -> ProvocacaoEntry {
        ProvocacaoEntry(date: date, estado: .semConexao, diaAno: nil, pergunta: "", perguntaCurta: "", autor: nil, doCache: false, desatualizado: false, idioma: idioma)
    }

    static func virada(em date: Date, idioma: Idioma) -> ProvocacaoEntry {
        ProvocacaoEntry(date: date, estado: .virada, diaAno: nil, pergunta: "", perguntaCurta: "", autor: nil, doCache: false, desatualizado: false, idioma: idioma)
    }
}

// Textos de apresentação por estado (uma única fonte para todas as famílias).
extension ProvocacaoEntry {
    /// "Dia 128" / "Hoje" / "Sem conexão" / "Novo dia" (ou "Día 128" / "Hoy" / … em es)
    var rotuloDia: String {
        switch estado {
        case .provocacao:
            // Um cache de ontem não pode exibir "Dia 128" como se fosse o de hoje.
            if desatualizado { return t.ultimaSalva }
            if let n = diaAno { return t.dia + " " + String(n) }
            return t.hoje
        case .vazio:       return t.hoje
        case .semConexao:  return t.semConexao
        case .virada:      return t.novoDia
        }
    }

    /// Kicker da família média: "Provocação · Dia 128"
    var kicker: String { t.provocacao + " · " + rotuloDia }

    /// Texto principal (citação com aspas tipográficas ou mensagem de estado).
    var textoLongo: String {
        switch estado {
        case .provocacao:  return "\u{201C}" + pergunta + "\u{201D}"
        case .vazio:       return t.longoVazio
        case .semConexao:  return t.longoSemConexao
        case .virada:      return t.longoVirada
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
        case .vazio:       return t.curtoVazio
        case .semConexao:  return t.curtoSemConexao
        case .virada:      return t.curtoVirada
        }
    }

    /// Linha do autor (só no estado com conteúdo). Marca "offline" quando veio do cache.
    var linhaAutor: String? {
        guard estado == .provocacao, let a = autor, !a.isEmpty else { return nil }
        if desatualizado { return a + " · " + t.autorNaoEHoje }
        return doCache ? a + " · " + t.autorOffline : a
    }

    /// CTA por extenso (média/grande).
    var cta: String {
        switch estado {
        case .provocacao:  return t.ctaProvocacao
        case .vazio:       return t.ctaVazio
        case .semConexao:  return t.ctaSemConexao
        case .virada:      return t.ctaVirada
        }
    }

    /// CTA curto (pequena).
    var ctaCurto: String { t.ctaCurto }

    /// Título e subtítulo do bloco do símbolo (família grande).
    var tituloGrande: String {
        switch estado {
        case .provocacao:  return t.tituloProvocacao
        case .vazio:       return t.tituloVazio
        case .semConexao:  return t.semConexao
        case .virada:      return t.novoDia
        }
    }

    var subtituloGrande: String {
        switch estado {
        case .provocacao:
            if desatualizado { return t.subtituloDesatualizado }
            return doCache ? t.subtituloOffline : t.subtituloProvocacao
        case .vazio:       return t.subtituloVazio
        case .semConexao:  return t.subtituloSemConexao
        case .virada:      return t.subtituloVirada
        }
    }

    /// Linha única (accessoryInline).
    var linhaInline: String {
        switch estado {
        case .provocacao:  return rotuloDia + " · " + perguntaCurta
        case .vazio:       return t.inlineVazio
        case .semConexao:  return t.inlineSemConexao
        case .virada:      return t.inlineVirada
        }
    }
}

// MARK: - Rede

enum WidgetAPI {
    enum Resultado {
        case sucesso(WidgetResponse)
        case falha
    }

    /// ?lang= sempre explícito, inclusive em pt: cada idioma tem a própria URL, e o
    /// URLCache do aparelho e a borda do Railway (que guardam por URL) nunca servem a
    /// resposta de um idioma para o outro.
    static func endpoint(_ idioma: Idioma) -> URL? {
        var c = URLComponents(string: "https://app.diariamente.club/api/widget/today")
        c?.queryItems = [URLQueryItem(name: "lang", value: idioma.rawValue)]
        return c?.url
    }

    /// `ignorandoCache` serve para a retentativa: quando o widget está sem o conteúdo
    /// de hoje, consultar o cache local é inútil — é justamente ele que pode estar
    /// segurando a resposta errada.
    static func buscar(idioma: Idioma, ignorandoCache: Bool = false, _ completion: @escaping (Resultado) -> Void) {
        guard let url = endpoint(idioma) else { completion(.falha); return }
        var req = URLRequest(url: url)
        // O servidor expira o Cache-Control exatamente na virada do dia em São Paulo,
        // então honrar o cache local é seguro no caminho normal e evita um round-trip
        // completo a cada recarga.
        req.cachePolicy = ignorandoCache ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy
        // Extensão de widget tem orçamento curto de execução: 15s é tempo demais
        // para ficar pendurado antes de cair no cache.
        req.timeoutInterval = 10
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
    /// A data do corpo bate com hoje em São Paulo? Corpo sem data é tratado como atual
    /// numa resposta ao vivo (é a resposta corrente da API, por definição) e como
    /// suspeito quando vem do cache local, que por natureza pode ser antigo.
    private static func ehDeHoje(_ dataDoCorpo: String?, agora: Date, vindoDoCache: Bool) -> Bool {
        let d = (dataDoCorpo ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if d.isEmpty { return !vindoDoCache }
        return d == FusoSP.chaveDoDia(agora)
    }

    /// O servidor informou um idioma diferente do pedido? Hoje ele não ecoa `lang`
    /// (campo ausente = vale o contrato do ?lang=); se passar a ecoar, uma divergência
    /// vira vazio em vez de exibir conteúdo na língua errada.
    private static func idiomaDivergente(_ lang: String?, pedido: Idioma) -> Bool {
        let l = (lang ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if l.isEmpty { return false }
        return Idioma(codigo: l) != pedido
    }

    static func carregar(agora: Date, idioma: Idioma, ignorandoCache: Bool = false, completion: @escaping (ProvocacaoEntry) -> Void) {
        WidgetAPI.buscar(idioma: idioma, ignorandoCache: ignorandoCache) { resultado in
            switch resultado {
            case .sucesso(let r):
                let perguntaLimpa = (r.pergunta ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if r.vazio || perguntaLimpa.isEmpty || idiomaDivergente(r.lang, pedido: idioma) {
                    // Estado vazio honesto — não usa cache antigo para "preencher", e em
                    // es isso é o normal enquanto não houver provocações em espanhol:
                    // o widget diz "Pronto en tu idioma" e nunca cai para o português.
                    completion(.vazio(date: agora, idioma: idioma))
                    return
                }
                let curtaLimpa = (r.perguntaCurta ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let autorLimpo = (r.autor ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let item = ProvocacaoSalva(data: r.data,
                                           diaAno: r.diaAno,
                                           pergunta: perguntaLimpa,
                                           perguntaCurta: curtaLimpa.isEmpty ? perguntaLimpa : curtaLimpa,
                                           autor: autorLimpo.isEmpty ? nil : autorLimpo,
                                           salvaEm: agora,
                                           idioma: idioma.rawValue)
                CacheProvocacao.salvar(item, idioma: idioma)
                // Um 200 NÃO garante que o corpo é de hoje: o URLCache do aparelho ou a
                // borda do Railway podem devolver uma resposta ainda "fresca" gravada
                // antes da virada. Sem esta conferência o widget exibiria a provocação de
                // ontem sem marca nenhuma — e, como a recarga é diária, ficaria assim até
                // a meia-noite seguinte.
                let doDia = ehDeHoje(r.data, agora: agora, vindoDoCache: false)
                completion(.deItem(item, date: agora, idioma: idioma, doCache: false, desatualizado: !doDia))

            case .falha:
                // Erro de rede: último valor em cache, se houver — mas conferindo a data.
                // Sem esta checagem o widget exibia a provocação de ONTEM com o rótulo
                // "Dia N" de ontem, como se fosse a de hoje. O cache lido é o do idioma
                // atual: sem cache em es, é "Sin conexión", nunca a última salva em pt.
                if let item = CacheProvocacao.ler(idioma: idioma) {
                    let doDia = ehDeHoje(item.data, agora: agora, vindoDoCache: true)
                    completion(.deItem(item, date: agora, idioma: idioma, doCache: true, desatualizado: !doDia))
                } else {
                    completion(.semConexao(date: agora, idioma: idioma))
                }
            }
        }
    }
}

// MARK: - Provider (timeline: agora + próxima meia-noite; UMA recarga por dia)

struct ProvocacaoProvider: TimelineProvider {
    typealias Entry = ProvocacaoEntry

    func placeholder(in context: Context) -> ProvocacaoEntry {
        .exemplo(date: Date(), idioma: .doAparelho)
    }

    func getSnapshot(in context: Context, completion: @escaping (ProvocacaoEntry) -> Void) {
        let idioma = Idioma.doAparelho
        if context.isPreview {
            completion(.exemplo(date: Date(), idioma: idioma))
            return
        }
        let agora = Date()
        Carregador.carregar(agora: agora, idioma: idioma) { completion($0) }
    }

    /// Desvio estável por instalação, sorteado uma única vez e guardado.
    /// Sem ele, todo aparelho com o widget bateria no servidor no mesmo segundo da
    /// virada. Não pode ser sorteado a cada chamada: a timeline tem que ser estável.
    /// Janela curta de propósito: enquanto a recarga não chega, o widget mostra
    /// "Novo dia" SEM conteúdo. Espalhar em 30 min condenaria metade das instalações
    /// a meia hora de widget vazio toda madrugada, para sempre — o desvio é sorteado
    /// uma vez e fica. Três minutos bastam para não bater todo mundo no mesmo segundo.
    private static let janelaDeDesvio = 3 * 60
    private static var desvioDaRecarga: TimeInterval {
        let chave = "club.diariamente.widget.desvioRecarga.v2"
        let d = UserDefaults.standard
        if let v = d.object(forKey: chave) as? Int { return TimeInterval(v) }
        let v = Int.random(in: 0..<janelaDeDesvio)
        d.set(v, forKey: chave)
        return TimeInterval(v)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ProvocacaoEntry>) -> Void) {
        let agora = Date()
        // Lido uma vez por timeline: a entrada de agora e a da virada saem no mesmo idioma.
        let idioma = Idioma.doAparelho
        // Uma recarga pedida logo após a virada tem que atravessar o cache local:
        // ele é justamente quem pode estar segurando a resposta do dia anterior.
        let logoAposAVirada = agora.timeIntervalSince(FusoSP.calendario.startOfDay(for: agora)) < 60 * 60
        Carregador.carregar(agora: agora, idioma: idioma, ignorandoCache: logoAposAVirada) { entradaAgora in
            let meiaNoite = FusoSP.proximaMeiaNoite(depoisDe: agora)
            let entradaVirada = ProvocacaoEntry.virada(em: meiaNoite, idioma: idioma)

            // O conteúdo muda UMA vez por dia, à meia-noite de Brasília. A versão
            // anterior pedia recarga a cada 6h além da virada: 3 chamadas de rede
            // inúteis por dia, por widget instalado. O iOS dá um orçamento limitado
            // de atualizações por widget — gastá-lo à toa é o que faz o widget parar
            // de atualizar e ficar velho ou em branco.
            var recarga = meiaNoite.addingTimeInterval(60 + Self.desvioDaRecarga)

            // Exceção: se esta busca não trouxe o conteúdo de HOJE, não faz sentido
            // esperar até a próxima meia-noite para tentar de novo.
            // A condição é sobre o conteúdo estar certo, não sobre a origem: um cache
            // com a provocação de hoje não precisa de retentativa nenhuma, e uma
            // resposta 200 com o corpo de ontem precisa — era o inverso disso antes.
            if entradaAgora.estado != .provocacao || entradaAgora.desatualizado {
                recarga = min(recarga, agora.addingTimeInterval(30 * 60))
            }

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
                Rotulo(texto: FusoSP.dataLonga(entry.date, idioma: entry.idioma), cor: DiarCor.branco.opacity(0.5))
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
                        Pilula(texto: entry.t.ctaLer, fundo: DiarCor.n900, corTexto: DiarCor.branco, altura: 24)
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

    // Nome e descrição da galeria de widgets no idioma do aparelho. String (e não
    // literal) cai na sobrecarga StringProtocol: o texto vai como está, sem
    // procurar tradução no bundle — quem traduz é o TextosWidget.
    private static var textos: TextosWidget { Idioma.doAparelho.textos }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ProvocacaoProvider()) { entry in
            DiariamenteWidgetEntryView(entry: entry)
                .widgetURL(URL(string: "https://app.diariamente.club")) // deep link: abre o app
        }
        .configurationDisplayName(Self.textos.nomeWidget)
        .description(Self.textos.descricaoWidget)
        .supportedFamilies(Self.familias)
    }
}

@main
struct DiariamenteWidgetBundle: WidgetBundle {
    var body: some Widget {
        DiariamenteWidget()
    }
}

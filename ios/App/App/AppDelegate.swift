import UIKit
import Capacitor
import os.log

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    // ─────────────────────────────────────────────────────────────────────────
    // BOOT — telemetria e rede de segurança
    //
    // Ownership (fonte única da verdade — ver docs/BOOT-ARCHITECTURE.md):
    //   • Sistema operacional ....... LaunchScreen.storyboard (a ÚNICA splash)
    //   • Hold da splash ............ @capacitor/splash-screen com launchAutoHide:false
    //   • Bootstrap / sessão / rota . BootCoordinator no app web (repo `diariamente`)
    //   • Deep links ................ ApplicationDelegateProxy → plugin App (1 entrega)
    //
    // Este arquivo NÃO decide rota, NÃO resolve sessão e NÃO desenha splash.
    // Ele apenas: (a) marca timestamps de boot, (b) impede que uma falha de
    // carregamento do web layer prenda o usuário na splash para sempre.
    // ─────────────────────────────────────────────────────────────────────────

    private static let bootLog = OSLog(subsystem: "club.diariamente.app", category: "boot")

    /// Teto absoluto do hold da splash nativa.
    ///
    /// Em operação normal quem esconde a splash é o web layer (`SplashScreen.hide()`),
    /// no exato momento em que o boot chega a READY — não existe timer no caminho feliz.
    /// Este valor é um GUARDA DE FALHA: se o web layer nunca carregar (offline, DNS,
    /// servidor fora), o usuário não pode ficar preso numa splash eterna.
    /// Não use isto para "acelerar" a splash: o caminho feliz não passa por aqui.
    private static let bootWatchdogSeconds: TimeInterval = 10.0

    private var bootStartedAt = CFAbsoluteTimeGetCurrent()
    private var launchSource = "direct"
    private var launchState = "cold"

    private func bootElapsedMs() -> Int {
        return Int((CFAbsoluteTimeGetCurrent() - bootStartedAt) * 1000)
    }

    /// Marca um evento de boot. Só metadados — nunca token, sessão, e-mail ou magic link.
    private func markBoot(_ event: String) {
        os_log("%{public}@ source=%{public}@ state=%{public}@ t=%{public}dms",
               log: AppDelegate.bootLog, type: .info,
               event, launchSource, launchState, bootElapsedMs())
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        bootStartedAt = CFAbsoluteTimeGetCurrent()

        // Classifica a origem da abertura apenas para telemetria. A ENTREGA do link
        // continua sendo exclusividade do ApplicationDelegateProxy (ver métodos abaixo):
        // classificar aqui não consome nem duplica o evento.
        if launchOptions?[.url] != nil {
            launchSource = "custom_scheme"
        } else if launchOptions?[.userActivityDictionary] != nil {
            launchSource = "universal_link"
        }

        markBoot("app_process_started")
        armBootWatchdog()
        return true
    }

    // MARK: - Rede de segurança da splash

    /// Agenda o encerramento forçado do hold da splash.
    ///
    /// `hide` é idempotente no plugin (`if !isVisible { return }`), então se o
    /// BootCoordinator já tiver chegado a READY esta chamada é um no-op silencioso.
    private func armBootWatchdog() {
        DispatchQueue.main.asyncAfter(deadline: .now() + AppDelegate.bootWatchdogSeconds) { [weak self] in
            self?.forceHideSplash()
        }
    }

    private func forceHideSplash() {
        guard let bridgeVC = window?.rootViewController as? CAPBridgeViewController,
              let plugin = bridgeVC.bridge?.plugin(withName: "SplashScreen") else {
            return
        }

        // Chamada via runtime ObjC: evita acoplar este arquivo ao módulo do pod
        // (CapacitorSplashScreen). Se o plugin sumir/renomear, degrada em no-op
        // em vez de quebrar o build.
        let hideSelector = NSSelectorFromString("hide:")
        guard plugin.responds(to: hideSelector) else { return }

        let call = CAPPluginCall(callbackId: "bootWatchdog",
                                 methodName: "hide",
                                 options: ["fadeOutDuration": 250],
                                 success: { _, _ in },
                                 error: { _ in })
        _ = plugin.perform(hideSelector, with: call)

        os_log("boot_watchdog_fired source=%{public}@ state=%{public}@ t=%{public}dms",
               log: AppDelegate.bootLog, type: .error,
               launchSource, launchState, bootElapsedMs())
    }

    // MARK: - Ciclo de vida

    func applicationWillResignActive(_ application: UIApplication) {
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // A próxima abertura já não é cold start.
        launchState = "warm"
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        markBoot("native_launch_completed")
    }

    func applicationWillTerminate(_ application: UIApplication) {
    }

    // MARK: - Deep links (entrega única)
    //
    // Estes dois métodos são o ÚNICO ponto de entrada de link do app. Ambos apenas
    // repassam para o ApplicationDelegateProxy, que entrega ao plugin App uma vez
    // (`retainUntilConsumed: true` — o evento fica retido até o JS assinar, então
    // não existe corrida de "listener registrou tarde"). Não adicione aqui
    // `getLaunchUrl()`, notificações próprias ou qualquer segunda ponte: isso faria
    // o mesmo link ser processado duas vezes.

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        launchSource = "custom_scheme"
        markBoot("deep_link_received")
        return ApplicationDelegateProxy.shared.application(app, open: url, options: options)
    }

    func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        launchSource = "universal_link"
        markBoot("deep_link_received")
        return ApplicationDelegateProxy.shared.application(application, continue: userActivity, restorationHandler: restorationHandler)
    }

}

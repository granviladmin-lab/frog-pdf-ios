import UIKit

@UIApplicationMain
final class AppDelegate: UIResponder, UIApplicationDelegate {
    /// Used on iOS 12 only; iOS 13+ windows belong to SceneDelegate.
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        if #available(iOS 13.0, *) { return true }
        let window = UIWindow(frame: UIScreen.main.bounds)
        Root.install(in: window)
        self.window = window
        return true
    }

    // iOS 12: "Open in Frog PDF" from another app or Files
    func application(_ app: UIApplication, open url: URL,
                     options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        guard let window = window else { return false }
        Root.open(url, in: window)
        return true
    }

    @available(iOS 13.0, *)
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        return UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
    }
}

@available(iOS 13.0, *)
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        Root.install(in: window)
        self.window = window
        if let url = connectionOptions.urlContexts.first?.url {
            Root.open(url, in: window)
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let window = window, let url = URLContexts.first?.url else { return }
        Root.open(url, in: window)
    }
}

/// Window setup shared by the iOS 12 app delegate and iOS 13+ scenes.
enum Root {
    static func install(in window: UIWindow) {
        let browser = DocumentBrowserViewController()
        window.rootViewController = browser
        window.tintColor = Brand.green
        window.makeKeyAndVisible()
        if !isRunningTests && !PasswordLock.isUnlocked {
            DispatchQueue.main.async {
                let lock = LockViewController()
                lock.modalPresentationStyle = .fullScreen
                if #available(iOS 13.0, *) { lock.isModalInPresentation = true }
                browser.present(lock, animated: false)
            }
        }
    }

    static func open(_ url: URL, in window: UIWindow) {
        guard let browser = window.rootViewController as? DocumentBrowserViewController else { return }
        browser.openExternal(url)
    }
}

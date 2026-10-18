import SwiftUI

@main
struct MunbynEasyPrintApp: App {
    @State private var model: AppModel

    init() {
        #if DEBUG
        if let i = CommandLine.arguments.firstIndex(of: "--render-screenshots") {
            let dir = CommandLine.arguments.dropFirst(i + 1).first ?? "docs/screenshots"
            Screenshots.render(to: URL(fileURLWithPath: dir))
            exit(0)
        }
        #endif
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView().environment(model)
        } label: {
            Image(systemName: model.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environment(model)
        }
    }
}

import SwiftUI

struct WelcomeModules: View {
    @ObservedObject var state: AppState
    @Binding var selection: Set<AuroraModule>

    var body: some View {
        Form {
            Section {
                ForEach(AuroraModule.allCases.filter(\.isToggleable)) { module in
                    Toggle(isOn: Binding(get: { selection.contains(module) }, set: { enabled in
                        if enabled { selection.insert(module) } else { selection.remove(module) }
                    })) {
                        Label(T(module.title), systemImage: module.symbol)
                    }
                    .toggleStyle(.switch)
                    .disabled(module == .trackpad && !state.trackpad.hasHardware)
                }
            } footer: {
                Text(T(state.trackpad.deviceName))
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

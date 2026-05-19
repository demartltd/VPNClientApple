import SwiftUI

struct ServersView: View {
    @Bindable var appState: AppState
    let isActive: Bool
    var snackBar: SnackBarController

    var body: some View {
        Group {
            if isActive {
                List {
                    ForEach(appState.servers) { server in
                        Button {
                            appState.selectServer(server)
                            snackBar.showSuccess("Сервер выбран")
                        } label: {
                            DemarCardRow(
                                leading: {
                                    Image(systemName: appState.selectedServer?.id == server.id
                                        ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(
                                        appState.selectedServer?.id == server.id
                                            ? Color.demarPrimary : Color.demarOnSurfaceVariant
                                    )
                                },
                                title: server.uri,
                                subtitle: "VLESS (test)"
                            )
                        }
                        .buttonStyle(.plain)
                        .demarListRowInsets()
                        .padding(.bottom, 10)
                    }
                }
                .demarListScreen()
            } else {
                Color.clear
            }
        }
    }
}

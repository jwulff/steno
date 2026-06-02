import SwiftUI
import StenoCore

/// The main window: a collapsible topics sidebar beside the live transcript,
/// framed by the status header above and the transport below.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var showSidebar = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $showSidebar) {
            TopicsSidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            VStack(spacing: 0) {
                StatusHeader()
                TranscriptView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                TransportBar()
            }
            .navigationSplitViewColumnWidth(min: 480, ideal: 680)
        }
        .navigationTitle("")
        .background(.background)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) {
            if !model.paused { model.demarcate(); return .handled }
            return .ignored
        }
        .onKeyPress(KeyEquivalent("p")) {
            model.togglePause(); return .handled
        }
    }
}

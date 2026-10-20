import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            SidebarView().frame(width: 280)
            Divider()
            VStack(spacing: 0) {
                TopBarView()
                Divider()
                SpectrumArea()
                ModemPanelView()
                StatusBarView()
            }
        }
        .overlay(alignment: .top) {
            if let banner = model.banner {
                BannerView(banner: banner)
                    .padding(.top, 70)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay {
            if model.quickTuneVisible {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.35).ignoresSafeArea().onTapGesture { model.quickTuneVisible = false }
                    QuickTuneView().padding(.top, 120)
                }
                .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.2), value: model.banner)
        .animation(.snappy(duration: 0.15), value: model.quickTuneVisible)
        .frame(minWidth: 1280, minHeight: 720)
        .onAppear { model.startIfNeeded() }
    }
}

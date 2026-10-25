import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(DialController.self) private var dial

    var body: some View {
        let window = WindowContentLayout(minSize: CGSize(width: 1280, height: 720))
        window {
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
            .overlay(alignment: .topTrailing) {
                if dial.hudVisible && dial.isConnected {
                    DialHUD()
                        .padding(.top, 72)
                        .padding(.trailing, 18)
                        .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .topTrailing)))
                }
            }
            .overlay(alignment: .top) {
                if dial.toastVisible && dial.isConnected {
                    DialConnectedToast()
                        .padding(.top, 140)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
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
            .animation(.easeOut(duration: 0.25), value: dial.hudVisible)
            .animation(.spring(duration: 0.5, bounce: 0.3), value: dial.toastVisible)
        }
        .onAppear { model.startIfNeeded() }
    }
}

/// The window's content at the window's size, with a fixed minimum. The window takes its minimum
/// size from its content and asks for it on every SwiftUI update; with `.frame(minWidth:minHeight:)`
/// answering that measured the whole window, every AppKit-backed control in it included (slow:
/// tens of milliseconds, ten times a second). This reports `minSize` without measuring the content.
private struct WindowContentLayout: Layout {
    let minSize: CGSize

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: max(proposal.width ?? minSize.width, minSize.width),
               height: max(proposal.height ?? minSize.height, minSize.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
        }
    }
}

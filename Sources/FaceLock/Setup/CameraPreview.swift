import AVFoundation
import FaceLockCapture
import SwiftUI

/// The mirrored live preview in a dark well with the viewfinder corners and an oval face guide.
/// The real camera draws through its own preview layer; the demo camera hands over its frames.
struct CameraWell<Overlay: View>: View {
    let session: CameraSession?
    let image: CGImage?
    @ViewBuilder var overlay: Overlay

    var body: some View {
        ZStack {
            Theme.well
            if let session {
                PreviewLayerView(session: session)
            } else if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .scaleEffect(x: -1, y: 1)
            }
            Ellipse()
                .stroke(.white.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [5, 6]))
                .frame(width: 150, height: 196)
            ViewfinderCorners(arm: 26)
                .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                .padding(Space.l)
            overlay
        }
        .aspectRatio(4 / 3, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Radius.well))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Camera preview, mirrored")
    }
}

private struct PreviewLayerView: NSViewRepresentable {
    let session: CameraSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = session.makePreviewLayer()
        layer.videoGravity = .resizeAspectFill
        if let c = layer.connection, c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = true
        }
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

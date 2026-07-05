import SwiftUI

/// Pinch-to-zoom, drag-to-pan crop step shown before a photo actually uploads — profile photos
/// previously went straight from the picker to the server with whatever framing the original
/// image happened to have, no way to fix a bad crop.
struct PhotoCropView: View {
    let image: UIImage
    let onConfirm: (UIImage) -> Void
    @Environment(\.dismiss) var dismiss

    private let aspectRatio: CGFloat = 3.0 / 4.0 // width:height, matches the card's portrait photos
    private let frameWidth: CGFloat = 330

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private var frameHeight: CGFloat { frameWidth / aspectRatio }

    var body: some View {
        ZStack {
            Color.lumenBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                LumenHeader(title: "Adjust Photo", leading: {
                    LumenHeaderTextButton(title: "Cancel") { dismiss() }
                }, trailing: {
                    LumenHeaderTextButton(title: "Use Photo") {
                        onConfirm(renderCroppedImage())
                        dismiss()
                    }
                })

            VStack(spacing: 24) {
                Spacer()

                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: frameWidth, height: frameHeight)
                        .scaleEffect(scale)
                        .offset(offset)
                }
                .frame(width: frameWidth, height: frameHeight)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.white, lineWidth: 2)
                )
                .contentShape(Rectangle())
                .gesture(
                    SimultaneousGesture(
                        MagnificationGesture()
                            .onChanged { value in
                                scale = max(1, lastScale * value)
                            }
                            .onEnded { _ in
                                lastScale = scale
                            },
                        DragGesture()
                            .onChanged { value in
                                offset = CGSize(
                                    width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height
                                )
                            }
                            .onEnded { _ in
                                lastOffset = offset
                            }
                    )
                )

                Text("Pinch to zoom, drag to reposition")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .frame(maxWidth: .infinity)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    @MainActor
    private func renderCroppedImage() -> UIImage {
        let cropView = ZStack {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: frameWidth, height: frameHeight)
                .scaleEffect(scale)
                .offset(offset)
        }
        .frame(width: frameWidth, height: frameHeight)
        .clipped()

        let renderer = ImageRenderer(content: cropView)
        // Render at the source image's own resolution rather than the on-screen point size,
        // so a cropped photo doesn't come out lower-res than the rest of the profile's photos.
        renderer.scale = max(image.size.width, image.size.height) / max(frameWidth, frameHeight)
        return renderer.uiImage ?? image
    }
}

#Preview {
    PhotoCropView(image: UIImage(systemName: "person.fill")!, onConfirm: { _ in })
}

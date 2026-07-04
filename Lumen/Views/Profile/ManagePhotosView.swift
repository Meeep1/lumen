import SwiftUI
import PhotosUI

/// Photo management — reorder (drag), delete, and add (with a crop step first). Backend
/// endpoints for delete/reorder existed already; there was just no UI wired up to them.
struct ManagePhotosView: View {
    @EnvironmentObject var authManager: AuthenticationManager
    @Environment(\.dismiss) var dismiss

    @State private var photos: [Photo] = []
    @State private var pickerItem: PhotosPickerItem?
    @State private var imageToCrop: UIImage?
    @State private var isUploading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(photos) { photo in
                    photoRow(photo)
                }
                .onMove(perform: move)
                .onDelete(perform: delete)

                if photos.count < 6 {
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label(isUploading ? "Uploading…" : "Add Photo", systemImage: "plus.circle.fill")
                            .foregroundColor(.pink)
                    }
                    .disabled(isUploading)
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Manage Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await refresh() }
            .onChange(of: pickerItem) { _, newItem in
                Task {
                    guard let newItem, let data = try? await newItem.loadTransferable(type: Data.self),
                          let uiImage = UIImage(data: data) else { return }
                    imageToCrop = uiImage
                    pickerItem = nil
                }
            }
            .sheet(item: Binding(
                get: { imageToCrop.map { IdentifiableImage(image: $0) } },
                set: { imageToCrop = $0?.image }
            )) { wrapped in
                PhotoCropView(image: wrapped.image) { cropped in
                    Task { await upload(cropped) }
                }
            }
            .customAlert(
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }),
                title: "Couldn't Update Photos",
                message: errorMessage ?? ""
            )
        }
    }

    private func photoRow(_ photo: Photo) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: APIService.shared.imageURL(for: photo.url)) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(Color(uiColor: .systemGray5))
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text(photo.order == 0 ? "Main Photo" : "Photo \(photo.order + 1)")
                    .font(.subheadline.weight(.medium))

                statusBadge(for: photo.moderationStatus)
            }

            Spacer()

            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func statusBadge(for status: String?) -> some View {
        switch status {
        case "pending":
            Label("Under review", systemImage: "clock.fill")
                .font(.caption2.weight(.medium))
                .foregroundColor(.orange)
        case "rejected":
            Label("Not approved", systemImage: "xmark.seal.fill")
                .font(.caption2.weight(.medium))
                .foregroundColor(.red)
        default:
            EmptyView()
        }
    }

    private func loadPhotos() {
        photos = authManager.currentUser?.photos ?? []
    }

    /// Pulls the current photo list fresh from the server rather than trusting whatever's
    /// cached in `authManager.currentUser` — that cache can go stale behind this app's back
    /// (e.g. an admin rejecting a photo from the admin site deletes it server-side with no way
    /// to notify this device), and a stale list here was exactly why a photo that no longer
    /// existed kept showing up and failing to delete with "Photo not found".
    private func refresh() async {
        await authManager.loadCurrentUser()
        loadPhotos()
    }

    private func move(from source: IndexSet, to destination: Int) {
        photos.move(fromOffsets: source, toOffset: destination)
        Task { await persistOrder() }
    }

    private func delete(at offsets: IndexSet) {
        // Dropping to zero photos makes `User.needsOnboarding` true again (it checks
        // photos.isEmpty), which bounces you straight back into the onboarding flow — jarring
        // for someone who's just tidying up their existing photos, not a new signup. Simplest
        // fix: a profile always keeps at least one photo; swap it instead of removing it if
        // this was the last one.
        guard photos.count - offsets.count >= 1 else {
            errorMessage = "You need at least one photo — add a replacement before removing this one."
            return
        }

        let removed = offsets.map { photos[$0] }
        photos.remove(atOffsets: offsets)
        Task {
            for photo in removed {
                await deletePhoto(photo)
            }
        }
    }

    private func deletePhoto(_ photo: Photo) async {
        do {
            try await APIService.shared.deletePhoto(photoId: photo.id)
            await refresh()
        } catch APIError.serverError(let message) where message.localizedCaseInsensitiveContains("not found") {
            // It's already gone server-side (e.g. an admin removed it) — that matches what the
            // user was trying to do anyway, so this isn't really a failure worth alarming them
            // over. Just resync so our list stops showing a photo that doesn't exist anymore.
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
            await refresh() // resync with the server's actual state — our optimistic removal may not match it
        }
    }

    private func persistOrder() async {
        do {
            try await APIService.shared.reorderPhotos(photoIds: photos.map(\.id))
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
            await refresh()
        }
    }

    private func upload(_ image: UIImage) async {
        guard let jpegData = image.jpegData(compressionQuality: 0.85) else { return }

        isUploading = true
        defer { isUploading = false }

        do {
            _ = try await APIService.shared.uploadPhoto(imageData: jpegData)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct IdentifiableImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

#Preview {
    ManagePhotosView()
        .environmentObject(AuthenticationManager.shared)
}

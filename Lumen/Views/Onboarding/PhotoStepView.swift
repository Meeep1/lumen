import SwiftUI
import PhotosUI

struct PhotoStepView: View {
    let onContinue: () -> Void

    @State private var pickerItem: PhotosPickerItem?
    @State private var previewImage: Image?
    @State private var isUploading = false
    @State private var uploadedPhoto: Photo?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("Add a photo")
                .font(.title.bold())

            Text("At least one photo is required so people can actually see who they're matching with.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)

            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(uiColor: .systemGray6))
                    .frame(width: 220, height: 280)

                if let previewImage {
                    previewImage
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 220, height: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                } else {
                    Image(systemName: "person.fill")
                        .resizable()
                        .frame(width: 60, height: 60)
                        .foregroundStyle(.secondary)
                }

                if isUploading {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.black.opacity(0.4))
                        .frame(width: 220, height: 280)
                    ProgressView().tint(.white)
                }

                if uploadedPhoto != nil {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .background(Circle().fill(.white))
                                .padding(8)
                        }
                        Spacer()
                    }
                    .frame(width: 220, height: 280)
                }
            }

            PhotosPicker(selection: $pickerItem, matching: .images) {
                Text(uploadedPhoto == nil ? "Choose Photo" : "Choose Different Photo")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.pink)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()

            Button {
                onContinue()
            } label: {
                Text("Continue")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
            }
            .background(uploadedPhoto != nil ? Color.pink.gradient : Color.gray.gradient)
            .cornerRadius(16)
            .padding(.horizontal, 32)
            .disabled(uploadedPhoto == nil)
            .padding(.bottom, 32)
        }
        .onChange(of: pickerItem) { _, newItem in
            Task { await load(newItem) }
        }
    }

    private func load(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        errorMessage = nil

        guard let data = try? await item.loadTransferable(type: Data.self),
              let uiImage = UIImage(data: data) else {
            errorMessage = "Couldn't load that photo. Try another one."
            return
        }

        previewImage = Image(uiImage: uiImage)

        guard let jpegData = uiImage.jpegData(compressionQuality: 0.85) else {
            errorMessage = "Couldn't process that photo. Try another one."
            return
        }

        isUploading = true
        defer { isUploading = false }

        do {
            uploadedPhoto = try await APIService.shared.uploadPhoto(imageData: jpegData)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    PhotoStepView(onContinue: {})
}

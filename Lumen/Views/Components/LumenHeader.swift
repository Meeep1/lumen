import SwiftUI

/// Replaces `NavigationStack`'s system nav bar (`.navigationTitle`/`.toolbar`) everywhere in the
/// app — that bar picks up this SDK's default "Liquid Glass" styling (system material, system
/// button capsules) which reads as generic iOS chrome rather than this app's own look. Screens
/// keep `NavigationStack` itself for push/pop mechanics and the interactive swipe-back gesture
/// (both keep working with the bar hidden — the gesture isn't tied to the bar's visibility); they
/// just hide the system bar with `.toolbar(.hidden, for: .navigationBar)` and put one of these at
/// the top of their own content instead.
struct LumenHeader<Leading: View, Trailing: View>: View {
    let title: String
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        ZStack {
            Text(title)
                .font(.headline)

            HStack {
                leading()
                Spacer()
                trailing()
            }
        }
        // Without this, a ZStack whose only non-title content is `HStack { EmptyView(); Spacer();
        // EmptyView() }` (i.e. no leading/trailing given) sizes itself to hug just the title
        // text instead of spanning the screen — the Spacer doesn't reliably force full width when
        // both its neighbors are EmptyView. That left every title-only header (Discover, Matches,
        // Likes You) as a narrow box around the title with the surrounding strip unpainted,
        // showing the window's default white instead of this app's background.
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .frame(height: 44)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(Color.lumenBackground)
    }
}

extension LumenHeader where Leading == EmptyView {
    init(title: String, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.leading = { EmptyView() }
        self.trailing = trailing
    }
}

extension LumenHeader where Trailing == EmptyView {
    init(title: String, @ViewBuilder leading: @escaping () -> Leading) {
        self.title = title
        self.leading = leading
        self.trailing = { EmptyView() }
    }
}

extension LumenHeader where Leading == EmptyView, Trailing == EmptyView {
    init(title: String) {
        self.title = title
        self.leading = { EmptyView() }
        self.trailing = { EmptyView() }
    }
}

/// Standalone circular chevron-back / X-close button — the one leading control most headers need.
/// Defaults to the environment's `dismiss()`, matching what a system back button would do, but
/// callers can override (e.g. a custom "go to previous onboarding step" action).
struct LumenBackButton: View {
    var systemImage: String = "chevron.left"
    var action: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button {
            if let action { action() } else { dismiss() }
        } label: {
            Image(systemName: systemImage)
        }
        .buttonStyle(LumenIconButtonStyle())
    }
}

/// Plain text trailing action (e.g. "Done", "Save", "Cancel") styled consistently instead of each
/// screen inventing its own toolbar-button text weight/color.
struct LumenHeaderTextButton: View {
    let title: String
    var isDestructive: Bool = false
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(isDisabled ? .secondary : (isDestructive ? .red : .pink))
        }
        .buttonStyle(LumenPressableStyle())
        .disabled(isDisabled)
    }
}

// MARK: - Custom single-select sheet (replaces `.pickerStyle(.menu)`)

/// On-brand replacement for a dropdown `Picker(.menu)` — presents a full custom sheet with a
/// checkmarked list instead of popping Apple's system `UIMenu`.
struct LumenSelectSheet<T: Hashable>: View {
    let title: String
    let options: [T]
    let label: (T) -> String
    @Binding var selection: T
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            LumenHeader(title: title, leading: {
                LumenBackButton(systemImage: "xmark")
            })

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                        if index > 0 {
                            Divider().padding(.leading, 16)
                        }
                        Button {
                            selection = option
                            dismiss()
                        } label: {
                            HStack {
                                Text(label(option))
                                    .font(.subheadline)
                                    .foregroundColor(.primary)
                                Spacer()
                                if option == selection {
                                    Image(systemName: "checkmark")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundColor(.pink)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(LumenPressableStyle(scale: 0.99))
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .background(Color.lumenBackground)
    }
}

/// Button that looks like the rest of this app's form fields (label + chevron) and opens a
/// `LumenSelectSheet` — the on-brand stand-in for whatever `Picker(.menu)` used to render as a
/// system dropdown.
struct LumenSelectField<T: Hashable>: View {
    let title: String
    let options: [T]
    let label: (T) -> String
    @Binding var selection: T
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack {
                Text(label(selection))
                    .font(.subheadline)
                    .foregroundColor(.primary)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.lumenSurface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small))
        }
        .buttonStyle(LumenPressableStyle(scale: 0.98))
        .sheet(isPresented: $isPresented) {
            LumenSelectSheet(title: title, options: options, label: label, selection: $selection)
                .presentationDetents([.medium, .large])
        }
    }
}

/// Custom text field chrome (replaces `.textFieldStyle(.roundedBorder)`, which draws a thin
/// system-gray outline that doesn't match this app's filled-surface look used everywhere else).
struct LumenTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.lumenSurface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small))
    }
}

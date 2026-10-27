import AppKit
import SwiftUI

@MainActor
struct AboutPane: View {
    let updater: UpdaterProviding
    @Bindable var selection: PreferencesSelection
    @State private var iconHover = false

    private var buildTimestamp: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "CodexBuildTimestamp") as? String else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        guard let date = parser.date(from: raw) else { return raw }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = .current
        return formatter.string(from: date)
    }

    var body: some View {
        if self.selection.destination.aboutRoute == .acknowledgements {
            AcknowledgementsView(acknowledgements: Acknowledgement.load())
        } else {
            self.form
        }
    }

    private var form: some View {
        Form {
            Section {
                self.hero
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }

            self.updatesSection

            Section {
                AboutLinkRow(
                    icon: "chevron.left.slash.chevron.right",
                    title: L("link_github"),
                    url: "https://github.com/sirrayi/bars")
                Button {
                    self.selection.showAcknowledgements()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "heart.text.square")
                            .frame(width: 18)
                            .foregroundStyle(.secondary)
                        Text(L("link_acknowledgements"))
                        Spacer()
                        Image(systemName: "chevron.forward")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("link_acknowledgements"))
            } header: {
                Text(L("section_links"))
            } footer: {
                Text(L("copyright"))
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .scrollContentBackground(.hidden)
    }

    private var updatesSection: some View {
        Section {
            LabeledContent(String(format: L("version_format"), AppVersion.displayString)) {
                EmptyView()
            }
            AboutUpdatesUnavailableView(reason: self.updater.unavailableReason ?? L("updates_unavailable"))
        } header: {
            Text(L("section_updates"))
        }
    }

    private var hero: some View {
        VStack(spacing: 10) {
            if let image = NSApplication.shared.applicationIconImage {
                Button(action: self.openProjectHome) {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: 92, height: 92)
                        .cornerRadius(16)
                        .scaleEffect(self.iconHover ? 1.05 : 1.0)
                        .shadow(color: self.iconHover ? .accentColor.opacity(0.25) : .clear, radius: 6)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .onHover { hovering in
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                        self.iconHover = hovering
                    }
                }
            }

            VStack(spacing: 2) {
                Text("bars")
                    .font(.title3).bold()
                Text(String(format: L("version_format"), AppVersion.displayString))
                    .foregroundStyle(.secondary)
                if let buildTimestamp {
                    Text(String(format: L("built_format"), buildTimestamp))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text(L("about_tagline"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private func openProjectHome() {
        guard let url = URL(string: "https://github.com/sirrayi/bars") else { return }
        NSWorkspace.shared.open(url)
    }
}

enum AboutRoute: Hashable {
    case acknowledgements
}

@MainActor
struct AboutUpdatesUnavailableView: View {
    typealias CopyAction = @MainActor @Sendable (String, @escaping @MainActor @Sendable (Bool) -> Void) -> Void

    let reason: String
    let command: String?
    let copyAction: CopyAction
    @State private var didCopy = false

    init(
        reason: String,
        command: String? = nil,
        copyAction: @escaping CopyAction = Self.copyCommand)
    {
        self.reason = reason
        self.command = command
        self.copyAction = copyAction
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(self.reason)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let command {
                HStack(spacing: 12) {
                    Text(command)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        self.copyAction(command) { self.didCopy = $0 }
                    } label: {
                        Label(
                            self.didCopy ? L("Copied") : L("Copy update command"),
                            systemImage: self.didCopy ? "checkmark" : "doc.on.doc")
                            .labelStyle(.iconOnly)
                    }
                    .controlSize(.small)
                    .frame(width: 28)
                    .help(self.didCopy ? L("Copied") : L("Copy update command"))
                    .accessibilityIdentifier("about-copy-update-command")
                }
                .environment(\.layoutDirection, .leftToRight)
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.primary.opacity(0.08))
                }
            }
        }
        .task(id: self.didCopy) {
            guard self.didCopy else { return }
            do {
                try await Task.sleep(for: .seconds(2))
                self.didCopy = false
            } catch {}
        }
    }

    private static func copyCommand(_ text: String, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        MenuPasteboardCopy.perform(text, writer: { text in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            completion(pasteboard.setString(text, forType: .string))
        })
    }
}

@MainActor
struct AboutLinkRow: View {
    let icon: String
    let title: String
    let url: String
    @State private var hovering = false

    var body: some View {
        Button {
            if let url = URL(string: self.url) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: self.icon)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                Text(self.title)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(self.hovering ? Color.accentColor : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { self.hovering = $0 }
    }
}

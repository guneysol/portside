import AppKit
import ServiceManagement
import SwiftUI

struct MenuContent: View {
    let store: Store
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Portside").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(store.visible.isEmpty ? "Idle" : "\(store.visible.count) running")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().opacity(0.6)

            if store.groups.isEmpty {
                EmptyState()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(store.groups) { GroupSection(group: $0, store: store) }
                    }
                    .padding(6)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .scrollIndicators(.never)
                .frame(height: min(max(contentHeight, 1), 480))
            }

            Divider().opacity(0.6)
            Footer(store: store)
        }
        .frame(width: 360)
    }
}

private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text("Nothing running").font(.system(size: 13, weight: .medium))
            Text("Dev servers and local services show up here.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

private struct GroupSection: View {
    let group: ProcessGroup
    let store: Store
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Image(systemName: group.project == nil ? "square.stack.3d.up"
                      : group.project!.isWorktree ? "arrow.triangle.branch" : "folder")
                    .font(.system(size: 10, weight: .semibold))
                Text(group.title).font(.system(size: 11, weight: .semibold))
                if let branch = group.project?.branch {
                    Text(branch)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if hovering, group.processes.filter(\.isOwned).count > 1 {
                    Button("Stop all") { store.stop(group.processes.filter(\.isOwned)) }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.red.opacity(0.9))
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .help(group.project.map { Format.abbreviatingHome($0.root) } ?? "Processes outside a project folder")

            ForEach(group.processes) { ProcessRow(process: $0, store: store) }
        }
        // Without this, the empty gap before "Stop all" isn't part of the hover
        // area, so the button vanished while the pointer crossed it.
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

private struct ProcessRow: View {
    let process: DevProcess
    let store: Store
    @State private var hovering = false

    private var tint: Color {
        switch process.kind {
        case .web: .blue
        case .database: .orange
        case .service: .purple
        case .runtime: .gray
        }
    }

    private var detail: String {
        [process.summary, process.origin.map { "via \($0)" }].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: process.kind.symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(process.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    ForEach(process.ports, id: \.number) { PortChip(port: $0, kind: process.kind) }
                }
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            if store.stopping.contains(process.pid) {
                ProgressView().controlSize(.small)
            } else if hovering, process.isOwned {
                StopButton { store.stop([process]) }
            } else if hovering {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .help("Owned by another user — stop it with sudo")
            } else {
                Text(Format.uptime(Date().timeIntervalSince(process.started)))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(hovering ? Color.primary.opacity(0.06) : .clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(process.command)
        .contextMenu { menu }
    }

    @ViewBuilder private var menu: some View {
        if process.kind == .web {
            ForEach(process.ports, id: \.number) { port in
                Button(String("Open localhost:\(port.number)")) { Actions.open(port) }
            }
            Divider()
        }
        if !process.cwd.isEmpty {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: process.cwd)])
            }
            Button("Copy Path") { Actions.copy(process.cwd) }
        }
        Button("Copy Command") { Actions.copy(process.command) }
        Button("Copy PID") { Actions.copy("\(process.pid)") }
        if process.isOwned {
            Divider()
            Button("Stop") { store.stop([process]) }
            Button("Force Quit") { store.stop([process], force: true) }
        }
    }
}

private struct PortChip: View {
    let port: ListenPort
    let kind: Kind
    @State private var copied = false

    var body: some View {
        Button {
            if kind == .web { Actions.open(port) } else {
                Actions.copy("localhost:\(port.number)")
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
            }
        } label: {
            Text(verbatim: copied ? "copied" : ":\(port.number)")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .help((kind == .web ? "Open in browser" : "Copy address")
              + (port.exposed ? " — listening on all interfaces" : ""))
    }
}

private struct StopButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "stop.circle.fill")
                .font(.system(size: 16))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(hovering ? Color.red : Color.secondary)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Stop")
    }
}

private struct Footer: View {
    @Bindable var store: Store
    @State private var confirming = false

    var body: some View {
        HStack(spacing: 10) {
            let stoppable = store.visible.filter(\.isOwned)
            if confirming {
                Text("Stop all \(stoppable.count)?")
                    .foregroundStyle(.primary)
                Button("Cancel") { confirming = false }
                    .buttonStyle(.plain)
                Button("Stop") {
                    store.stop(stoppable)
                    confirming = false
                }
                .buttonStyle(.plain)
                .fontWeight(.semibold)
                .foregroundStyle(.red)
            } else if !stoppable.isEmpty {
                Button {
                    confirming = true
                    Task { try? await Task.sleep(for: .seconds(4)); confirming = false }
                } label: {
                    Label("Stop All", systemImage: "stop.circle")
                }
                .buttonStyle(.plain)
                .help("Stop every process listed here")
            }
            Spacer()
            if store.hiddenCount > 0, !store.showSystem {
                Text("\(store.hiddenCount) hidden")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .help("System daemons and GUI apps — show them from the ⋯ menu")
            }
            Button { Task { await store.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh")

            Menu {
                Toggle("Show System & App Listeners", isOn: $store.showSystem)
                Toggle("Launch at Login", isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { try? $0 ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
                ))
                Divider()
                Button("Quit Portside") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

enum Actions {
    static func open(_ port: ListenPort) {
        if let url = URL(string: "http://localhost:\(port.number)") { NSWorkspace.shared.open(url) }
    }

    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

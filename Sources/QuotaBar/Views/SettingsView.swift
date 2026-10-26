import ServiceManagement
import SwiftUI

/// Settings: a sidebar of four panes. Every change saves as it is made; secrets save from
/// their own Save button so a half-typed key is never stored.
struct SettingsView: View {
    var snapshotMode = false
    @State private var pane: Pane = .subscriptions

    enum Pane: String, CaseIterable, Identifiable {
        case general, subscriptions, api, security
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: "General"
            case .subscriptions: "Subscriptions"
            case .api: "API Accounts"
            case .security: "Security"
            }
        }
        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .subscriptions: "person.2.crop.square.stack"
            case .api: "key.horizontal"
            case .security: "touchid"
            }
        }
        var subtitle: String {
            switch self {
            case .general: "Menu bar, refresh and notifications"
            case .subscriptions: "Claude profiles, ChatGPT and GLM plans"
            case .api: "Keys for Cursor and scripts, with spend and credit"
            case .security: "Touch ID lock and how keys are stored"
            }
        }
    }

    init(snapshotMode: Bool = false, pane: Pane = .subscriptions) {
        self.snapshotMode = snapshotMode
        _pane = State(initialValue: pane)
    }

    var body: some View {
        LockGate(enabled: !snapshotMode) {
            HStack(spacing: 0) {
                sidebar
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(pane.title).font(.system(size: 20, weight: .semibold))
                        Text(pane.subtitle).font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 14)
                    Group {
                        if snapshotMode { paneContent.padding(.horizontal, 28).padding(.bottom, 24) }
                        else { ScrollView { paneContent.padding(.horizontal, 28).padding(.bottom, 24) } }
                    }
                    .id(pane)
                    .transition(.opacity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(.background)
            }
            .animation(.smooth(duration: 0.2), value: pane)
        }
        .frame(minWidth: 820, idealWidth: 880, minHeight: 600, idealHeight: 680)
    }

    @ViewBuilder private var paneContent: some View {
        switch pane {
        case .general: GeneralPane()
        case .subscriptions: SubscriptionsPane()
        case .api: APIAccountsPane()
        case .security: SecurityPane()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.system(size: 18, weight: .semibold)).foregroundStyle(.tint)
                Text("QuotaBar").font(.system(size: 15, weight: .semibold))
            }
            .padding(.horizontal, 10).padding(.top, 18).padding(.bottom, 14)
            ForEach(Pane.allCases) { p in
                Button { pane = p } label: {
                    HStack(spacing: 10) {
                        Image(systemName: p.symbol).frame(width: 18)
                        Text(p.title)
                        Spacer()
                    }
                    .font(.system(size: 13, weight: pane == p ? .semibold : .regular))
                    .foregroundStyle(pane == p ? Color.primary : .secondary)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 7).fill(pane == p ? Color.accentColor.opacity(0.16) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("Version 1.0").font(.caption2).foregroundStyle(.tertiary).padding(10)
        }
        .padding(.horizontal, 10)
        .frame(width: 210)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.quaternary.opacity(0.35))
    }
}

// MARK: - Building blocks

private struct SettingsCard<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.7).foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.08)))
            if let footer {
                Text(footer).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 18)
    }
}

/// A labelled row: title and help text on the left, the control on the right.
private struct Row<Control: View>: View {
    let title: String
    var detail: String? = nil
    var divider = true
    @ViewBuilder var control: Control

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13))
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 12)
                control
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            if divider { Divider().padding(.leading, 14) }
        }
    }
}

private struct StatusPill: View {
    enum Kind { case ok, warn, error, idle }
    let kind: Kind
    let text: String

    var body: some View {
        let color: Color = switch kind {
        case .ok: .green
        case .warn: .orange
        case .error: .red
        case .idle: .secondary
        }
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.caption.weight(.medium)).lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
        .foregroundStyle(kind == .idle ? .secondary : color)
    }
}

/// A secret that is sealed with the Secure Enclave on Save and never displayed again.
private struct SecretInput: View {
    @EnvironmentObject private var store: UsageStore
    let name: String
    let placeholder: String
    @State private var editing = false
    @State private var text = ""
    @State private var error: String?
    @State private var version = 0

    var body: some View {
        let saved = Vault.has(name) && version >= 0
        VStack(alignment: .trailing, spacing: 4) {
            if saved && !editing {
                HStack(spacing: 8) {
                    Label("Saved · encrypted", systemImage: "lock.fill").font(.callout).foregroundStyle(.secondary)
                    Button("Replace") { editing = true }
                    Button("Remove", role: .destructive) { commit(nil) }
                }
            } else {
                HStack(spacing: 8) {
                    SecureField(placeholder, text: $text)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 240)
                        .onSubmit { commit(text) }
                    Button("Save") { commit(text) }
                        .buttonStyle(.borderedProminent)
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                    if saved { Button("Cancel") { editing = false; text = "" } }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }

    private func commit(_ value: String?) {
        do {
            try store.storeSecret(name, value)
            error = nil
            editing = false
            text = ""
            version += 1
            store.refreshSoon()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - General

private struct GeneralPane: View {
    @EnvironmentObject private var store: UsageStore
    @AppStorage(Prefs.refreshMinutes) private var refreshMinutes = 5
    @AppStorage(Prefs.menuBarStyle) private var style = MenuBarStyle.bars.rawValue
    @AppStorage(Prefs.menuBarAll) private var menuBarAll = false
    @AppStorage(Prefs.notify) private var notify = true
    @AppStorage(Prefs.notifyRanking) private var notifyRanking = true
    @AppStorage(Prefs.showInDock) private var showInDock = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsCard(title: "Menu bar") {
                HStack {
                    Spacer()
                    MenuBarGlyph(items: store.menuBarItems, style: MenuBarStyle(rawValue: style) ?? .bars, color: .primary)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.primary.opacity(0.06)))
                    Spacer()
                }
                .padding(.vertical, 14)
                Divider().padding(.leading, 14)
                Row(title: "Show") {
                    Picker("", selection: $style) {
                        ForEach(MenuBarStyle.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 300)
                }
                Row(title: "Accounts shown", detail: "Best per service keeps the menu bar narrow: the top-ranked Claude profile, Codex and GLM.", divider: false) {
                    Picker("", selection: $menuBarAll) {
                        Text("Best per service").tag(false)
                        Text("Every account").tag(true)
                    }
                    .labelsHidden().frame(width: 170)
                }
            }
            SettingsCard(title: "App") {
                Row(title: "Show in Dock and app switcher", detail: "Click the Dock icon to open the Dashboard; ⌘-Tab switches to it. Off keeps QuotaBar in the menu bar only.", divider: false) {
                    Toggle("", isOn: $showInDock).toggleStyle(.switch).labelsHidden()
                }
            }
            SettingsCard(title: "Updates") {
                Row(title: "Refresh every") {
                    Picker("", selection: $refreshMinutes) {
                        ForEach([2, 5, 10, 15, 30], id: \.self) { Text("\($0) minutes").tag($0) }
                    }
                    .labelsHidden().frame(width: 140)
                    .onChange(of: refreshMinutes) { store.startLoop() }
                }
                Row(title: "Notifications", detail: "Alert when any limit passes 80% and 95% or is on pace to run out before it resets, and when a limit reset becomes available.") {
                    Toggle("", isOn: $notify).toggleStyle(.switch).labelsHidden()
                }
                Row(title: "Recommendation changes", detail: "Alert when the account to use next changes, or one hits its cap or comes back.") {
                    Toggle("", isOn: $notifyRanking).toggleStyle(.switch).labelsHidden()
                }
                Row(title: "Launch at login", detail: "Needs QuotaBar in Applications (scripts/build-app.sh --install).", divider: false) {
                    Toggle("", isOn: $launchAtLogin).toggleStyle(.switch).labelsHidden()
                        .onChange(of: launchAtLogin) { _, on in
                            do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                            catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                        }
                }
            }
        }
    }
}

// MARK: - Subscriptions

private struct SubscriptionsPane: View {
    @EnvironmentObject private var store: UsageStore
    @AppStorage(Prefs.enabled(.claude)) private var claude = true
    @AppStorage(Prefs.enabled(.codex)) private var codex = true
    @AppStorage(Prefs.enabled(.zai)) private var zai = true
    @AppStorage(Prefs.zaiChina) private var zaiChina = false
    @AppStorage(Prefs.enabled(.kimi)) private var kimi = false
    @AppStorage(Prefs.kimiInternational) private var kimiIntl = false
    @AppStorage(Prefs.enabled(.minimax)) private var minimax = false
    @AppStorage(Prefs.minimaxChina) private var minimaxChina = false
    @AppStorage(Prefs.enabled(.cursor)) private var cursor = false
    @AppStorage(Prefs.enabled(.grok)) private var grok = false

    var body: some View {
        let claudeAccounts = store.accounts.filter { $0.kind == .claude }
        VStack(alignment: .leading, spacing: 0) {
            SettingsCard(title: "Claude", footer: "Found automatically: every ~/.claude* folder with a Claude Code login. Names come from the claude-title-prefix wrappers in ~/.zshrc. A profile you haven't used for ~8 hours shows its last reading until you run it again.") {
                Row(title: "Track Claude", detail: "\(claudeAccounts.count) profile\(claudeAccounts.count == 1 ? "" : "s") on this Mac", divider: claude && !claudeAccounts.isEmpty) {
                    Toggle("", isOn: $claude).toggleStyle(.switch).labelsHidden()
                }
                if claude {
                    ForEach(Array(claudeAccounts.enumerated()), id: \.element.id) { i, a in
                        AccountRow(account: a, divider: i < claudeAccounts.count - 1)
                    }
                }
            }
            SettingsCard(title: "ChatGPT · Codex", footer: "Uses the Codex CLI login in ~/.codex. Run `codex login` to switch accounts.") {
                Row(title: "Track Codex", divider: codex) {
                    Toggle("", isOn: $codex).toggleStyle(.switch).labelsHidden()
                }
                if codex { AccountRow(account: .codex, showToggle: false, divider: false) }
            }
            SettingsCard(title: "GLM · Z.ai Coding Plan", footer: "Create the key at z.ai → API Keys (or open.bigmodel.cn for the China region). It is encrypted by the Secure Enclave.") {
                Row(title: "Track GLM", divider: zai) {
                    Toggle("", isOn: $zai).toggleStyle(.switch).labelsHidden()
                }
                if zai {
                    Row(title: "Status") { AccountStatus(state: store.states[Account.zai.id]) }
                    Row(title: "API key") { SecretInput(name: Prefs.zaiKey, placeholder: "Z.ai API key") }
                    Row(title: "Region", divider: false) {
                        Picker("", selection: $zaiChina) {
                            Text("Global · api.z.ai").tag(false)
                            Text("China · bigmodel.cn").tag(true)
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 300)
                        .onChange(of: zaiChina) { store.refreshSoon() }
                    }
                }
            }
            SettingsCard(title: "Kimi Code", footer: "Create the key in the Kimi Code console (kimi.com/code/console, or kimi.ai for the international service). It is encrypted by the Secure Enclave.") {
                Row(title: "Track Kimi", divider: kimi) {
                    Toggle("", isOn: $kimi).toggleStyle(.switch).labelsHidden()
                }
                if kimi {
                    Row(title: "Status") { AccountStatus(state: store.states[Account.kimi.id]) }
                    Row(title: "API key") { SecretInput(name: Prefs.kimiKey, placeholder: "Kimi Code API key") }
                    Row(title: "Region", divider: false) {
                        Picker("", selection: $kimiIntl) {
                            Text("China · kimi.com").tag(false)
                            Text("International · kimi.ai").tag(true)
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 300)
                        .onChange(of: kimiIntl) { store.refreshSoon() }
                    }
                }
            }
            SettingsCard(title: "MiniMax Coding Plan", footer: "Use the Coding Plan key (sk-cp-…) from the MiniMax platform's Coding Plan page; a regular API key won't show plan quota. It is encrypted by the Secure Enclave.") {
                Row(title: "Track MiniMax", divider: minimax) {
                    Toggle("", isOn: $minimax).toggleStyle(.switch).labelsHidden()
                }
                if minimax {
                    Row(title: "Status") { AccountStatus(state: store.states[Account.minimax.id]) }
                    Row(title: "API key") { SecretInput(name: Prefs.minimaxKey, placeholder: "MiniMax Coding Plan key") }
                    Row(title: "Region", divider: false) {
                        Picker("", selection: $minimaxChina) {
                            Text("Global · minimax.io").tag(false)
                            Text("China · minimaxi.com").tag(true)
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 300)
                        .onChange(of: minimaxChina) { store.refreshSoon() }
                    }
                }
            }
            SettingsCard(title: "Cursor", footer: "Uses the Cursor app's own login on this Mac, read-only. Sign in or switch accounts in Cursor.") {
                Row(title: "Track Cursor", divider: cursor) {
                    Toggle("", isOn: $cursor).toggleStyle(.switch).labelsHidden()
                }
                if cursor { Row(title: "Status", divider: false) { AccountStatus(state: store.states[Account.cursor.id]) } }
            }
            SettingsCard(title: "Grok · SuperGrok", footer: "Uses the login from xAI's grok CLI in ~/.grok. Run `grok login` to sign in or switch accounts.") {
                Row(title: "Track Grok", divider: grok) {
                    Toggle("", isOn: $grok).toggleStyle(.switch).labelsHidden()
                }
                if grok { Row(title: "Status", divider: false) { AccountStatus(state: store.states[Account.grok.id]) } }
            }
        }
        .onChange(of: claude) { store.refreshSoon() }
        .onChange(of: codex) { store.refreshSoon() }
        .onChange(of: zai) { store.refreshSoon() }
        .onChange(of: kimi) { store.refreshSoon() }
        .onChange(of: minimax) { store.refreshSoon() }
        .onChange(of: cursor) { store.refreshSoon() }
        .onChange(of: grok) { store.refreshSoon() }
    }
}

private struct AccountStatus: View {
    let state: ProviderState?
    var body: some View {
        switch state {
        case .ok(let s)? where s.staleReason != nil: StatusPill(kind: .warn, text: "Saved reading").help(s.staleReason ?? "")
        case .ok(let s)?: StatusPill(kind: .ok, text: s.plan.map { "Connected · \($0)" } ?? "Connected")
        case .failed(let msg)?: StatusPill(kind: .error, text: msg).help(msg)
        case .loading?: StatusPill(kind: .idle, text: "Loading…")
        case .disabled?, nil: StatusPill(kind: .idle, text: "Off")
        }
    }
}

private struct AccountRow: View {
    @EnvironmentObject private var store: UsageStore
    let account: Account
    var showToggle = true
    var divider = true
    @State private var on = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: account.kind.symbol).foregroundStyle(account.kind.tint).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.kind == .claude ? account.label : account.kind.shortName).font(.system(size: 13, weight: .medium))
                    Text(account.detail ?? store.states[account.id]?.snapshot?.account.detail ?? account.configDir ?? "")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                AccountStatus(state: store.states[account.id]).frame(maxWidth: 260, alignment: .trailing)
                if showToggle {
                    Toggle("", isOn: $on).toggleStyle(.switch).labelsHidden().controlSize(.small)
                        .onChange(of: on) { _, v in
                            UserDefaults.standard.set(v, forKey: Prefs.enabled(account.id))
                            store.refreshSoon()
                        }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .padding(.leading, showToggle ? 12 : 0)
            if divider { Divider().padding(.leading, 44) }
        }
        .onAppear { on = UserDefaults.standard.object(forKey: Prefs.enabled(account.id)) as? Bool ?? true }
    }
}

// MARK: - API accounts

private struct APIAccountsPane: View {
    @EnvironmentObject private var store: UsageStore
    @State private var accounts: [APIAccount] = []
    @State private var selection: String?
    @State private var confirmDelete = false

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                VStack(spacing: 2) {
                    ForEach(accounts) { a in listRow(a) }
                    if accounts.isEmpty {
                        Text("No API accounts yet").font(.callout).foregroundStyle(.secondary).padding(14)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.08)))
                Button(action: add) { Label("Add account", systemImage: "plus") }
                    .buttonStyle(.borderless)
            }
            .frame(width: 200)

            if let i = accounts.firstIndex(where: { $0.id == selection }) {
                APIAccountEditor(account: $accounts[i], spend: store.spends[accounts[i].id], onChange: save) {
                    confirmDelete = true
                }
                .id(accounts[i].id)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "key.horizontal").font(.system(size: 30)).foregroundStyle(.tertiary)
                    Text("Add an API account to keep its key under Touch ID and track its spend and credit.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button(action: add) { Label("Add API account", systemImage: "plus") }
                        .buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 6)
                }
                .frame(maxWidth: .infinity).padding(.top, 60)
            }
        }
        .onAppear {
            accounts = store.apiAccounts
            selection = selection ?? accounts.first?.id
        }
        .confirmationDialog("Delete this API account?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { deleteSelected() }
        } message: {
            Text("Its encrypted API key and admin key are removed from this Mac.")
        }
    }

    private func listRow(_ a: APIAccount) -> some View {
        let dot: Color = switch store.spends[a.id] {
        case .ok?: .green
        case .failed?: .red
        case nil: .secondary.opacity(0.5)
        }
        return Button { selection = a.id } label: {
            HStack(spacing: 9) {
                Circle().fill(dot).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(a.name.isEmpty ? "Unnamed" : a.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(a.keyHint ?? a.vendor.name).font(.system(size: 10.5, design: a.keyHint == nil ? .default : .monospaced))
                        .foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(selection == a.id ? Color.accentColor.opacity(0.16) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func add() {
        let a = APIAccount(name: "New account", creditAsOf: .now)
        accounts.append(a)
        selection = a.id
        save()
    }

    private func save() {
        store.saveAPIAccounts(accounts)
        store.refreshSoon()
    }

    private func deleteSelected() {
        guard let i = accounts.firstIndex(where: { $0.id == selection }) else { return }
        let a = accounts.remove(at: i)
        Vault.remove(a.vaultName)
        try? store.storeSecret(a.keychainKey, nil)
        selection = accounts.first?.id
        save()
    }
}

private struct APIAccountEditor: View {
    @Binding var account: APIAccount
    let spend: SpendState?
    let onChange: () -> Void
    let onDelete: () -> Void
    @State private var newKey = ""
    @State private var keyError: String?
    @State private var topUp: Double?
    @State private var showTopUp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsCard(title: "Account") {
                Row(title: "Name") {
                    TextField("e.g. GG Console", text: $account.name).textFieldStyle(.roundedBorder).frame(width: 240)
                }
                Row(title: "Provider", divider: false) {
                    Picker("", selection: $account.vendor) {
                        ForEach(APIVendor.allCases) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                }
            }

            SettingsCard(title: "API key", footer: "The key you paste into Cursor. It is sealed by this Mac's Secure Enclave; copying it back asks for Touch ID and the clipboard clears after 90 seconds.") {
                if let hint = account.keyHint {
                    Row(title: hint, detail: keyUsageText, divider: false) {
                        HStack(spacing: 8) {
                            KeyCopyButton(account: account)
                            Button("Remove", role: .destructive) {
                                Vault.remove(account.vaultName)
                                account.keyHint = nil
                            }
                        }
                    }
                } else {
                    Row(title: "Key", detail: account.vendor == .anthropic ? "Starts with sk-ant-api…" : nil, divider: false) {
                        HStack(spacing: 8) {
                            SecureField("Paste API key", text: $newKey).textFieldStyle(.roundedBorder).frame(width: 220)
                                .onSubmit(sealKey)
                            Button("Save", action: sealKey).buttonStyle(.borderedProminent)
                                .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                if let keyError { Text(keyError).font(.caption).foregroundStyle(.red).padding(.horizontal, 14).padding(.bottom, 8) }
            }

            SettingsCard(title: "Spend tracking", footer: "Anthropic and OpenAI only report cost to an organisation admin key (Console → Settings → Admin keys). It refreshes in the background, so it is unlocked once per launch.") {
                Row(title: "Status") { spendStatus }
                Row(title: "Admin key", divider: false) {
                    SecretInput(name: account.keychainKey, placeholder: account.vendor == .anthropic ? "sk-ant-admin…" : "Admin key")
                }
            }

            SettingsCard(title: "Credit & limit", footer: creditFooter) {
                Row(title: "Credit type") {
                    Picker("", selection: $account.creditMode) {
                        ForEach(APIAccount.CreditMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 280)
                }
                Row(title: account.creditMode == .monthly ? "Allowance per month" : "Balance",
                    detail: account.creditMode == .prepaid ? "As shown in the console on the date below." : nil) {
                    HStack(spacing: 8) {
                        MoneyField(value: $account.credit)
                        if account.creditMode == .prepaid {
                            Button("Top up…") { showTopUp = true }
                                .popover(isPresented: $showTopUp, arrowEdge: .bottom) { topUpPopover }
                        }
                    }
                }
                if account.creditMode == .prepaid {
                    Row(title: "Balance as of") {
                        DatePicker("", selection: Binding(get: { account.creditAsOf ?? .now }, set: { account.creditAsOf = $0 }),
                                   displayedComponents: .date)
                            .labelsHidden()
                    }
                    Row(title: "Expires", detail: "Prepaid Anthropic credit lapses a year after purchase.") {
                        HStack(spacing: 8) {
                            if account.creditExpires != nil {
                                DatePicker("", selection: Binding(get: { account.creditExpires ?? .now }, set: { account.creditExpires = $0 }),
                                           displayedComponents: .date)
                                    .labelsHidden()
                                Button("Clear") { account.creditExpires = nil }.buttonStyle(.borderless)
                            } else {
                                Button("Set date") {
                                    account.creditExpires = Calendar.current.date(byAdding: .year, value: 1, to: account.creditAsOf ?? .now)
                                }
                            }
                        }
                    }
                } else {
                    Row(title: "Resets on day") {
                        Picker("", selection: Binding(get: { account.resetDay ?? 1 }, set: { account.resetDay = $0 })) {
                            ForEach(1...28, id: \.self) { Text(ordinal($0)).tag($0) }
                        }
                        .labelsHidden().frame(width: 90)
                    }
                }
                Row(title: "Monthly spend limit", detail: "Copy it from Console → Limits. Spend is shown against it each calendar month.", divider: false) {
                    MoneyField(value: $account.budget)
                }
            }

            HStack {
                Spacer()
                Button("Delete account…", role: .destructive, action: onDelete)
            }
        }
        .onChange(of: account) { onChange() }
    }

    private var keyUsageText: String? {
        guard case .ok(let s)? = spend else { return nil }
        if let k = s.key { return "\(k.name) · \(Fmt.tokens(k.inputTokens)) in / \(Fmt.tokens(k.outputTokens)) out this month" }
        return s.keyError
    }

    @ViewBuilder private var spendStatus: some View {
        switch spend {
        case .ok(let s)?:
            let left = s.remainingCredit.map { " · \(Fmt.money(max(0, $0))) credit left" } ?? ""
            StatusPill(kind: .ok, text: "\(Fmt.money(s.monthToDate)) this month\(left)")
        case .failed(let msg)?: StatusPill(kind: .error, text: msg).help(msg)
        case nil: StatusPill(kind: .idle, text: Vault.has(account.keychainKey) ? "Loading…" : "Add an admin key")
        }
    }

    private var creditFooter: String {
        var parts: [String] = []
        if let reset = account.creditResets() {
            let verb = account.creditMode == .monthly ? "Next reset" : "Expires"
            parts.append("\(verb): \(reset.formatted(date: .abbreviated, time: .omitted)) (in \(Fmt.duration(max(0, reset.timeIntervalSinceNow)))).")
        }
        parts.append(account.creditMode == .monthly
            ? "QuotaBar subtracts spend since the last reset from the allowance."
            : "QuotaBar subtracts spend since the balance date; use Top up when you add credit.")
        return parts.joined(separator: " ")
    }

    private var topUpPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add credit").font(.headline)
            MoneyField(value: $topUp)
            Text("Adds to what's left now and restarts tracking from today.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { showTopUp = false; topUp = nil }
                Button("Add") {
                    var left = account.credit ?? 0
                    if case .ok(let s)? = spend, let r = s.remainingCredit { left = max(0, r) }
                    account.credit = left + (topUp ?? 0)
                    account.creditAsOf = .now
                    topUp = nil
                    showTopUp = false
                }
                .buttonStyle(.borderedProminent)
                .disabled((topUp ?? 0) <= 0)
            }
        }
        .padding(16)
        .frame(width: 260)
    }

    private func sealKey() {
        let key = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try Vault.seal(key, as: account.vaultName)
            account.keyHint = KeyHint.make(key)
            newKey = ""
            keyError = nil
        } catch {
            keyError = "Couldn't encrypt the key: \(error.localizedDescription)"
        }
    }

    private func ordinal(_ n: Int) -> String {
        let suffix = (11...13).contains(n % 100) ? "th" : [1: "st", 2: "nd", 3: "rd"][n % 10] ?? "th"
        return "\(n)\(suffix)"
    }
}

private struct MoneyField: View {
    @Binding var value: Double?
    var body: some View {
        HStack(spacing: 4) {
            Text("$").foregroundStyle(.secondary)
            TextField("0", value: $value, format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 100)
        }
    }
}

// MARK: - Security

private struct SecurityPane: View {
    @EnvironmentObject private var store: UsageStore
    @AppStorage(Prefs.relockMinutes) private var relock = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsCard(title: "Lock") {
                Row(title: "Lock after", detail: "QuotaBar also locks when the Mac sleeps or the screen locks.") {
                    Picker("", selection: $relock) {
                        Text("5 minutes").tag(5)
                        Text("15 minutes").tag(15)
                        Text("30 minutes").tag(30)
                        Text("1 hour").tag(60)
                        Text("Only on sleep").tag(0)
                    }
                    .labelsHidden().frame(width: 150)
                }
                Row(title: "Lock now", divider: false) {
                    Button { store.lock() } label: { Label("Lock", systemImage: "lock.fill") }
                }
            }
            SettingsCard(title: "How keys are stored", footer: "The menu bar bars stay visible while locked; they show usage percentages only.") {
                Row(title: "Secure Enclave", detail: "Each key is encrypted to a key that lives in this Mac's Secure Enclave and can only be used after Touch ID (your login password is the fallback). The encrypted file is useless on any other Mac.") {
                    Image(systemName: "cpu").font(.title2).foregroundStyle(.secondary)
                }
                Row(title: "API keys", detail: "Touch ID every time you copy one.") {
                    Image(systemName: "touchid").font(.title2).foregroundStyle(.secondary)
                }
                Row(title: "Admin and Z.ai keys", detail: "Unlocked once per launch so spend can refresh in the background; held only in memory.", divider: false) {
                    Image(systemName: "memorychip").font(.title2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

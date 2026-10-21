import SekishoCore
import SwiftUI

/// Shows the oldest held request or response; closes itself when none are left.
struct BreakpointWindow: View {
    @Environment(Store.self) private var store
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let held = store.pending.first {
                BreakpointSheet(held: held, waiting: store.pending.count - 1).id(held.id)
            } else {
                Text("Nothing is held at a breakpoint.").foregroundStyle(.secondary).padding(40)
            }
        }
        .onChange(of: store.pending.isEmpty) { _, empty in if empty { dismissWindow(id: "breakpoint") } }
        // Closing the window lets everything still held go on unchanged, rather than hang the apps waiting on it.
        .onDisappear { store.releaseAll() }
    }
}

/// A request or response stopped at a breakpoint. Edit anything, then Execute or Abort.
struct BreakpointSheet: View {
    @Environment(Store.self) private var store
    let held: PendingBreakpoint
    let waiting: Int

    @State private var method = ""
    @State private var url = ""
    @State private var status = ""
    @State private var headers = ""
    @State private var bodyText = ""
    @State private var bodyIsText = true
    @State private var problem: String?

    private var isRequest: Bool { held.stage == .request }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: Intervention.hold.symbol).foregroundStyle(Color.holdRed).font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isRequest ? "Request held" : "Response held").font(.title3.weight(.semibold))
                    Text(held.flow.url).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                Spacer()
                if waiting > 0 { Text("\(waiting) more waiting").foregroundStyle(.secondary) }
            }
            if isRequest {
                HStack {
                    TextField("Method", text: $method).frame(width: 90)
                    TextField("URL", text: $url)
                }
                .font(.system(.body, design: .monospaced))
            } else {
                HStack {
                    Text("Status")
                    TextField("200", text: $status).frame(width: 70).font(.system(.body, design: .monospaced))
                    Text(held.flow.reason).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            FieldLabel("Headers")
            Editor(text: $headers, placeholder: "Name: value").frame(minHeight: 110)
            HStack {
                FieldLabel("Body")
                Spacer()
                if bodyIsText { FormatJSONButton(text: $bodyText) }
            }
            if bodyIsText {
                Editor(text: $bodyText, placeholder: "No body").frame(minHeight: 160, maxHeight: .infinity)
            } else {
                Text("Binary body (\(Formats.bytes((isRequest ? held.flow.requestBody : held.flow.responseBody).count))), sent unchanged.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .background(Color.ground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            if let problem { Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.holdRed) }
            HStack {
                Button { store.resolve(held.id, with: nil) } label: { Label("Abort", systemImage: "xmark.octagon") }
                    .foregroundStyle(Color.holdRed)
                    .help("Stop it here; the client gets 502")
                Spacer()
                Button("Execute") { execute() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .tint(.brassFill)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
        .frame(minWidth: 520, idealWidth: 760, minHeight: 480)
        .interactiveDismissDisabled()
        .onAppear(perform: load)
    }

    private func load() {
        let f = held.flow
        method = f.method
        url = f.url
        status = f.status.map(String.init) ?? "200"
        headers = Flow.headerText(isRequest ? f.requestHeaders : f.responseHeaders)
        let data = (isRequest ? f.decodedRequestBody : f.decodedResponseBody) ?? Data()
        if let text = String(data: data, encoding: .utf8) { bodyText = text } else { bodyIsText = false }
    }

    private func execute() {
        var f = held.flow
        if isRequest {
            guard f.setURL(url) else { problem = "That URL is not http:// or https://."; return }
            f.method = method.trimmingCharacters(in: .whitespaces).uppercased()
            guard !f.method.isEmpty else { problem = "The method is empty."; return }
            f.requestHeaders = Flow.parseHeaders(headers)
            if bodyIsText, bodyText != String(decoding: f.decodedRequestBody ?? Data(), as: UTF8.self) { f.setRequestBodyText(bodyText) }
        } else {
            guard let code = Int(status.trimmingCharacters(in: .whitespaces)), (100...599).contains(code) else {
                problem = "The status must be a number from 100 to 599."; return
            }
            if code != f.status { f.reason = HTTPStatusText.reason(code) }
            f.status = code
            f.responseHeaders = Flow.parseHeaders(headers)
            if bodyIsText, bodyText != String(decoding: f.decodedResponseBody ?? Data(), as: UTF8.self) { f.setResponseBodyText(bodyText) }
        }
        store.resolve(held.id, with: f)
    }
}

/// A small caption above an editor.
struct FieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary) }
}

/// Pretty-prints the editor's JSON in place, keeping key order and number spelling.
struct FormatJSONButton: View {
    @Binding var text: String
    var body: some View {
        // Checked live only for bodies small enough to parse on every keystroke.
        let small = text.utf8.count < 256 << 10
        let pretty = small ? BodyText.prettyJSON(Data(text.utf8)) : nil
        Button("Format JSON", systemImage: "curlybraces") { if let p = pretty ?? BodyText.prettyJSON(Data(text.utf8)) { text = p } }
            .controlSize(.small)
            .disabled(small && (pretty == nil || pretty == text))
            .help(small && pretty == nil ? "The body is not JSON" : "Indent the JSON")
    }
}

enum HTTPStatusText {
    static func reason(_ code: Int) -> String {
        HTTPURLResponse.localizedString(forStatusCode: code).capitalized
    }
}

/// Build a request (or edit a recorded one) and send it.
struct ComposeSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: Flow
    var onSent: ((Int) -> Void)?

    @State private var method = "GET"
    @State private var url = ""
    @State private var headers = ""
    @State private var bodyText = ""
    @State private var problem: String?

    private let methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(request.id == 0 ? "Compose" : "Edit and Repeat").font(.title3.weight(.semibold))
                Spacer()
                Button("Paste cURL") {
                    guard let text = NSPasteboard.general.string(forType: .string), let f = Import.curl(text) else {
                        problem = "The clipboard does not hold a curl command."
                        return
                    }
                    load(f)
                    problem = nil
                }
                .help("Fill this in from a curl command on the clipboard")
                Menu("History") {
                    if store.composeHistory.isEmpty { Text("Nothing sent yet") }
                    ForEach(Array(store.composeHistory.enumerated()), id: \.offset) { _, f in
                        Button("\(f.method) \(f.url)") { load(f) }
                    }
                }
                .fixedSize()
            }
            HStack {
                Picker("", selection: $method) {
                    ForEach(methods + (methods.contains(method) ? [] : [method]), id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 110)
                TextField("https://api.example.com/v1/items", text: $url)
                    .font(.system(.body, design: .monospaced))
            }
            FieldLabel("Headers")
            Editor(text: $headers, placeholder: "Name: value").frame(minHeight: 110)
            HStack {
                FieldLabel("Body")
                Spacer()
                FormatJSONButton(text: $bodyText)
            }
            Editor(text: $bodyText, placeholder: "No body").frame(minHeight: 140, maxHeight: .infinity)
            if let problem { Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.holdRed) }
            HStack {
                Text("Sent straight to the server; tool rules do not apply.").foregroundStyle(.secondary).font(.callout)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Send") { send() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .tint(.brassFill)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
        .frame(minWidth: 520, idealWidth: 720, minHeight: 460)
        .onAppear { load(request) }
    }

    private func load(_ f: Flow) {
        method = f.method
        url = f.url
        headers = Flow.headerText(f.requestHeaders.filter { $0.name.caseInsensitiveCompare("Content-Length") != .orderedSame })
        bodyText = String(data: f.decodedRequestBody ?? f.requestBody, encoding: .utf8) ?? ""
    }

    private func send() {
        var f = request
        guard f.setURL(url) else { problem = "Enter an http:// or https:// URL."; return }
        f.method = method
        f.requestHeaders = Flow.parseHeaders(headers)
        f.requestHeaders.removeAll { $0.name.caseInsensitiveCompare("Host") == .orderedSame }
        f.setRequestBodyText(bodyText)
        if let id = store.send(f) { onSent?(id) }
        dismiss()
    }
}

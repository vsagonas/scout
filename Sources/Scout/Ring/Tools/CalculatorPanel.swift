import AppKit
import SwiftUI

@MainActor
enum CalculatorPanel {
    static func show() {
        ToolPanels.show("calculator", size: CGSize(width: 340, height: 420), minSize: CGSize(width: 300, height: 320), resizable: true) {
            CalculatorView(expression: ToolMemory.string(ToolMemory.calcExpression) ?? "")
        }
    }
}

struct CalcHistoryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var expression: String
    var result: String
}

struct CalculatorView: View {
    @State private var expression: String
    @State private var history: [CalcHistoryEntry] = CalculatorView.loadHistory()
    @AppStorage("calc.degrees") private var degrees = false
    @FocusState private var focused: Bool

    init(expression: String = "") { _expression = State(initialValue: expression) }

    private var outcome: (text: String, isError: Bool, value: Double?, incomplete: Bool)? {
        let trimmed = expression.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        do {
            let v = try CalcParser.evaluate(trimmed, degrees: degrees)
            return (CalcParser.format(v), false, v, false)
        } catch let e as CalcParser.CalcError {
            // While typing, "Incomplete" is noise: show it only softly.
            return (CalcParser.message(for: e), true, nil, e == .syntax)
        } catch { return (String(localized: "Error"), true, nil, false) }
    }

    var body: some View {
        ToolPanelFrame("Calculator", symbol: "plus.forwardslash.minus", accessory: {
            Picker("", selection: $degrees) {
                Text("RAD").tag(false)
                Text("DEG").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 92).controlSize(.small)
        }) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Type a sum, like 12 * (3 + 4)", text: $expression)
                        .textFieldStyle(.plain)
                        .font(.system(size: 20, weight: .regular, design: .rounded)).monospacedDigit()
                        .focused($focused)
                        .onSubmit(commit)
                    Divider()
                    resultLine
                }
                .padding(.horizontal, 16).padding(.top, 4)

                if history.isEmpty {
                    ToolEmptyState(symbol: "clock.arrow.circlepath", message: String(localized: "Results you copy stay here."))
                } else {
                    HStack {
                        Text("History").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear") { history = []; Self.saveHistory([]) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(history) { entry in
                                HStack {
                                    Text(entry.expression).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text("= " + entry.result).font(.system(size: 13, weight: .medium, design: .rounded)).monospacedDigit()
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
                                .contentShape(Rectangle())
                                .onTapGesture { expression = entry.expression; focused = true }
                                .contextMenu { Button("Copy result") { copy(entry.result) } }
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                }
            }
            .padding(.bottom, 10)
        }
        .onAppear { focused = true }
        .onChange(of: expression) { _, new in ToolMemory.set(new, ToolMemory.calcExpression) }
    }

    @ViewBuilder private var resultLine: some View {
        HStack(alignment: .firstTextBaseline) {
            if let outcome {
                if outcome.isError {
                    Text(verbatim: outcome.incomplete ? "…" : outcome.text).font(.system(size: 13)).foregroundStyle(outcome.incomplete ? Color.secondary : Color.orange)
                } else {
                    Text("= " + outcome.text)
                        .font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(Theme.accent).lineLimit(1).minimumScaleFactor(0.5)
                }
            } else {
                Text("Press Return to copy the result").font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .frame(minHeight: 36)
    }

    private func commit() {
        guard let outcome, !outcome.isError else { return }
        copy(outcome.text)
        let entry = CalcHistoryEntry(expression: expression.trimmingCharacters(in: .whitespaces), result: outcome.text)
        history.removeAll { $0.expression == entry.expression && $0.result == entry.result }
        history.insert(entry, at: 0)
        history = Array(history.prefix(40))
        Self.saveHistory(history)
    }

    private func copy(_ text: String) {
        if !ScoutRuntime.isScripted {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        Toast.show("Copied \(text)", symbol: "plus.forwardslash.minus")
    }

    static func loadHistory() -> [CalcHistoryEntry] {
        if ScoutRuntime.isGallery {
            return [CalcHistoryEntry(expression: "1299 * 0.85", result: "1104.15"),
                    CalcHistoryEntry(expression: "sqrt(144) + 2^5", result: "44"),
                    CalcHistoryEntry(expression: "250 + 18%", result: "295"),
                    CalcHistoryEntry(expression: "(72 - 32) / 1.8", result: "22.2222222222")]
        }
        guard let data = UserDefaults.standard.data(forKey: "calc.history"),
              let list = try? JSONDecoder().decode([CalcHistoryEntry].self, from: data) else { return [] }
        return list
    }

    static func saveHistory(_ list: [CalcHistoryEntry]) {
        guard !ScoutRuntime.isScripted, let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: "calc.history")
    }
}

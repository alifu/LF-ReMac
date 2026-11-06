import RemoteCore
import SwiftUI
import UIKit

/// Invisible view that shows the iOS keyboard and forwards what is typed.
struct KeyboardHost: UIViewRepresentable {
    @Binding var isActive: Bool
    let keyboard: KeyboardController

    func makeUIView(context: Context) -> KeyboardInputView {
        KeyboardInputView(keyboard: keyboard)
    }

    func updateUIView(_ uiView: KeyboardInputView, context: Context) {
        if isActive, !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if !isActive, uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }
}

final class KeyboardInputView: UIView, UIKeyInput {
    private static let accessoryHeight: CGFloat = 48

    private let keyboard: KeyboardController
    private let accessory: UIInputView
    private let accessoryController: UIHostingController<ModifierBar>

    // UITextInputTraits: raw key presses only, no iOS text "help".
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .asciiCapable

    init(keyboard: KeyboardController) {
        self.keyboard = keyboard
        accessoryController = UIHostingController(
            rootView: ModifierBar(modifiers: keyboard.modifiers) { keyboard.press($0) }
        )
        accessory = UIInputView(
            frame: CGRect(x: 0, y: 0, width: 0, height: Self.accessoryHeight),
            inputViewStyle: .keyboard
        )
        super.init(frame: .zero)
        accessoryController.view.backgroundColor = .clear
        accessoryController.view.frame = accessory.bounds
        accessoryController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        accessory.addSubview(accessoryController.view)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var canBecomeFirstResponder: Bool { true }
    override var inputAccessoryView: UIView? { accessory }

    // UIKeyInput
    var hasText: Bool { true }  // always true so the keyboard keeps sending deleteBackward

    func insertText(_ text: String) {
        keyboard.insert(text)
    }

    func deleteBackward() {
        keyboard.deleteBackward()
    }
}

/// Modifier latches and special keys the iOS keyboard lacks.
struct ModifierBar: View {
    let modifiers: ModifierState
    let onKey: (RemoteKey) -> Void

    private static let modifierButtons: [(label: String, name: String, value: KeyModifiers)] = [
        ("⌘", "Command", .command), ("⌥", "Option", .option), ("⌃", "Control", .control), ("⇧", "Shift", .shift)
    ]
    private static let keyButtons: [(label: String, name: String, key: RemoteKey)] = [
        ("esc", "Escape", .escape), ("⇥", "Tab", .tab),
        ("←", "Left arrow", .arrowLeft), ("↓", "Down arrow", .arrowDown),
        ("↑", "Up arrow", .arrowUp), ("→", "Right arrow", .arrowRight)
    ]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Self.modifierButtons, id: \.name) { item in
                let isOn = modifiers.latched.contains(item.value)
                Button(item.label) { modifiers.toggle(item.value) }
                    .buttonStyle(.borderedProminent)
                    .tint(isOn ? .accentColor : .gray)
                    .accessibilityLabel(item.name)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
            }
            Divider().frame(height: 24)
            ForEach(Self.keyButtons, id: \.name) { item in
                Button(item.label) { onKey(item.key) }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(item.name)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
    }
}

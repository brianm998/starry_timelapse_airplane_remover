import SwiftUI

/// A generic “tap to edit” numeric editor supporting Int or Double.
struct EditableNumberView<Value>: View
where Value: Numeric & Comparable & LosslessStringConvertible {
    /// The bound numeric value we’re editing
    @Binding var value: Value
    /// Inclusive lower bound for valid inputs
    let minValue: Value
    /// Inclusive upper bound for valid inputs
    let maxValue: Value
    /// Should decimal points be allowed (for Double)?
    let allowDecimal: Bool
    /// How to render the full-text when not editing
    let fullTextProvider: (Value) -> String
    /// Optional prefix inside the HStack during editing
    let prefixText: String?
    /// Suffix (after the TextField) during editing
    let suffixTextProvider: (Value) -> String
    /// Color for text
    let textColor: Color
    /// Focus state binding and the specific field case
    let focusedField: FocusState<FocusedField?>.Binding
    let focusField: FocusedField
    let alwaysOpen: Bool
    /// Extra action upon commit
    let commitAction: (Value) -> Void
    
    @State private var isEditing: Bool 
    @State private var editText: String

    init(value: Binding<Value>,
         minValue: Value = .zero,
         maxValue: Value,
         allowDecimal: Bool = false,
         fullTextProvider: @escaping (Value) -> String,
         prefixText: String? = nil,
         suffixTextProvider: @escaping (Value) -> String,
         textColor: Color,
         focusedField: FocusState<FocusedField?>.Binding,
         focusField: FocusedField,
         alwaysOpen: Bool = false,
         commitAction: @escaping (Value) -> Void = { _ in })
    {
        self._value = value
        self.minValue = minValue
        self.maxValue = maxValue
        self.allowDecimal = allowDecimal
        self.fullTextProvider = fullTextProvider
        self.prefixText = prefixText
        self.suffixTextProvider = suffixTextProvider
        self.textColor = textColor
        self.focusedField = focusedField
        self.focusField = focusField
        self.alwaysOpen = alwaysOpen
        self.commitAction = commitAction
        _isEditing = State(initialValue: alwaysOpen)
        if alwaysOpen {
            _editText = State(initialValue: String(value.wrappedValue))
        } else {
            _editText = State(initialValue: "")
        }
    }

    var body: some View {
        let currentString = String(value)

        if isEditing || alwaysOpen {
            HStack {
                if let prefix = prefixText {
                    Text(prefix)
                        .foregroundColor(textColor)
                }

                TextField(currentString, text: $editText)
                  .focused(focusedField, equals: focusField)
                  .frame(maxWidth: 60)
                  .cursor(.arrow)
                  .onSubmit {
                      commitIfValid()
                  }
                  // Esc puts the old value back
                  .onExitCommand {
                      revert()
                  }
                  .onChange(of: focusedField.wrappedValue) {
                      guard isEditing || alwaysOpen else { return }
                      if focusedField.wrappedValue != focusField {
                          // Lost focus: what was typed is the user's answer, as much as Return is.  Reverting here
                          // dropped a number typed into a settings sheet that was then closed without Return.
                          commitIfValid()
                      }
                  }
                  // A field that goes away while its text is still being typed (a sheet closed on it) keeps it too
                  .onDisappear {
                      if isEditing { commitIfValid() }
                  }

                Text(suffixTextProvider(value))
                  .foregroundColor(textColor)
            }
        } else {
            Text(fullTextProvider(value))
              .foregroundColor(textColor)
              .cursor(.iBeam)
              .onTapGesture {
                  // Begin editing
                  editText = currentString
                  focusedField.wrappedValue = focusField
                  isEditing = true
              }
        }
    }

    /// Validates and commits the edited text, then exits edit mode.  A value that is not valid is put back, and one that
    /// is the value already there changes nothing (and so does not run `commitAction`, which can create an override).
    private func commitIfValid() {
        let allowedChars: CharacterSet = allowDecimal
            ? CharacterSet(charactersIn: "0123456789.")
            : CharacterSet.decimalDigits
        let filtered = String(editText.unicodeScalars
                                .filter { allowedChars.contains($0) })
        if let newVal = Value(filtered),
           newVal >= minValue,
           newVal <= maxValue,
           newVal != value {
            value = newVal
            commitAction(newVal)
        }
        finishEditing()
    }

    /// Esc: leave the field with the value it had.
    private func revert() {
        finishEditing()
    }

    /// Exit edit mode, showing the value now in force, and give the keyboard back: a field that kept focus after its
    /// commit swallowed the digits and arrow keys meant for the frame.
    private func finishEditing() {
        isEditing = false
        editText = alwaysOpen ? String(value) : ""
        if focusedField.wrappedValue == focusField {
            focusedField.wrappedValue = nil
        }
    }
}

import SwiftUI

/// A generic “tap to edit” numeric editor supporting Int or Double.
struct EditableNumberView<Value>: View
where Value: Numeric & Comparable & LosslessStringConvertible {
    /// The bound numeric value we’re editing
    @Binding var value: Value
    /// Inclusive lower bound for valid inputs
    let minValue: Value
    /// Exclusive upper bound for valid inputs
    let maxValue: Value
    /// Should decimal points be allowed (for Double)?
    let allowDecimal: Bool
    /// How to render the full-text when not editing
    let fullTextProvider: (Value) -> String
    /// Optional prefix inside the HStack during editing
    let prefixText: String?
    /// Suffix (after the TextField) during editing
    let suffixTextProvider: (Value) -> String
    /// Focus state binding and the specific field case
    let focusedField: FocusState<RightPanel.FocusedField?>.Binding
    let focusField: RightPanel.FocusedField
    /// Extra action upon commit
    let commitAction: (Value) -> Void

    @State private var isEditing = false
    @State private var editText = ""

    init(value: Binding<Value>,
         minValue: Value = .zero,
         maxValue: Value,
         allowDecimal: Bool = false,
         fullTextProvider: @escaping (Value) -> String,
         prefixText: String? = nil,
         suffixTextProvider: @escaping (Value) -> String,
         focusedField: FocusState<RightPanel.FocusedField?>.Binding,
         focusField: RightPanel.FocusedField,
         commitAction: @escaping (Value) -> Void = { _ in })
    {
        self._value = value
        self.minValue = minValue
        self.maxValue = maxValue
        self.allowDecimal = allowDecimal
        self.fullTextProvider = fullTextProvider
        self.prefixText = prefixText
        self.suffixTextProvider = suffixTextProvider
        self.focusedField = focusedField
        self.focusField = focusField
        self.commitAction = commitAction
    }

    var body: some View {
        let currentString = String(value)

        if isEditing {
            HStack {
                if let prefix = prefixText {
                    Text(prefix)
                        .foregroundColor(.white)
                }

                TextField(currentString, text: $editText)
                  .focused(focusedField, equals: focusField)
                  .frame(maxWidth: 60)
                  .cursor(.arrow)
                  .onSubmit {
                      commitIfValid()
                  }
                  .onChange(of: focusedField.wrappedValue) {
                      guard isEditing else { return }
                      if focusedField.wrappedValue != focusField {
                          // Lost focus: cancel editing and revert
                          isEditing = false
                          editText = ""
                      }
                  }

                Text(suffixTextProvider(value))
                  .foregroundColor(.white)
            }
        } else {
            Text(fullTextProvider(value))
              .foregroundColor(.white)
              .cursor(.iBeam)
              .onTapGesture {
                  // Begin editing
                  editText = currentString
                  focusedField.wrappedValue = focusField
                  isEditing = true
              }
        }
    }

    /// Validates and commits the edited text, then exits edit mode.
    private func commitIfValid() {
        let allowedChars: CharacterSet = allowDecimal
            ? CharacterSet(charactersIn: "0123456789.")
            : CharacterSet.decimalDigits
        let filtered = String(editText.unicodeScalars
                                .filter { allowedChars.contains($0) })
        if let newVal = Value(filtered),
           newVal >= minValue,
           newVal < maxValue {
            value = newVal
            commitAction(newVal)
        }
        // Exit editing mode in all cases (commit or revert)
        isEditing = false
        editText = ""
    }
}

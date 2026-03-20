import SwiftUI

struct ClipboardConfirmationView: View {
    let contents: String
    let request: ClipboardRequest
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?

    var body: some View {
        VStack {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
                    .font(.system(size: 42))
                    .padding()
                    .frame(alignment: .center)

                Text(request.descriptionText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }

            TextEditor(text: .constant(contents))
                .focusable(false)
                .font(.system(.body, design: .monospaced))

            HStack {
                Spacer()
                Button(request.cancelButtonTitle) {
                    onCancel?()
                }
                .keyboardShortcut(.cancelAction)
                Button(request.confirmButtonTitle) {
                    onConfirm?()
                }
                .keyboardShortcut(.defaultAction)
                Spacer()
            }
            .padding(.bottom)
        }
    }
}

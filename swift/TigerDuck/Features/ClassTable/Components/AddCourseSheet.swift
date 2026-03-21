import SwiftUI

struct AddCourseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var courseCode: String = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("例如：EC1013701", text: $courseCode)

                Button("查詢並新增") {
                    // TODO: look up course by code and add
                    dismiss()
                }
                .disabled(courseCode.isEmpty)
            }
            .navigationTitle("新增課程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
            }
        }
    }
}

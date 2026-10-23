import SwiftUI

struct SubmodulesView: View {
    let buildDetails: BuildDetails

    var body: some View {
        List {
            Section(header: Text("Trio")) {
                KeyValueRow(key: buildDetails.trioBranch, value: buildDetails.trioCommitSHA)
            }
            Section(header: Text("Submodules")) {
                ForEach(buildDetails.submodules.sorted(by: { $0.key < $1.key }), id: \.key) { name, info in
                    KeyValueRow(key: name, value: info.commitSHA)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Submodules")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct KeyValueRow: View {
    let key: String
    let value: String

    var body: some View {
        HStack {
            Text(key)
                .foregroundColor(.primary)
                .textSelection(.enabled)
            Spacer()
            Text(value)
                .foregroundColor(Color(red: 224.0 / 255, green: 224.0 / 255, blue: 224.0 / 255))
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

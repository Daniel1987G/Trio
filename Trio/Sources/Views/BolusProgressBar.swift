import SwiftUI

struct BolusProgressBar: View {
    let progress: Decimal

    var body: some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 15)
                .frame(height: 6)
                .foregroundColor(.clear)
                .background(
                    LinearGradient(colors: [Color(red: 0.8, green: 0.8, blue: 0.8)], startPoint: .leading, endPoint: .trailing)
                        .mask(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 15)
                                .frame(width: geo.size.width * CGFloat(progress))
                                .animation(.easeInOut(duration: 0.25), value: progress)
                        }
                )
        }
        .frame(height: 6)
    }
}

import Foundation
import Observation
import SwiftUI
import UIKit

@Observable class AppState {
    func trioCardBackgroundColor() -> Color {
        Color(red: 48.0 / 255, green: 48.0 / 255, blue: 48.0 / 255)
    }

    func trioBackgroundColor(for _: ColorScheme) -> LinearGradient {
        LinearGradient(
            colors: [.black, .black],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

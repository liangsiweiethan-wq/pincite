import WidgetKit
import SwiftUI

@main
struct LiteratureSearchWidgetBundle: WidgetBundle {
    var body: some Widget {
        RecentSearchesWidget()
        DailyQuoteWidget()
    }
}

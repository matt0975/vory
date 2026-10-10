import SwiftUI

extension View {
    /// Hands the app's model to what a sheet, a full-screen cover or a popover shows, in so
    /// many words, instead of trusting the presentation to carry it over from the view that
    /// presented it.
    ///
    /// A presentation is meant to inherit its presenter's environment, and on the phone it
    /// does. The iPhone app running on a Mac crashed as a sheet came up (1.3 (5): SwiftUI's
    /// "No Observable object of type AppModel found", inside the sheet's own hosting
    /// controller): the sheet's content read the model and the environment it was given had
    /// none. With the model put in at the presentation itself, nothing the content reads
    /// depends on what the presenter's environment held at that moment. Every presentation
    /// in the app's views does this; a unit test reads the sources and holds them to it.
    func withAppModel() -> some View {
        environment(AppModel.shared)
    }
}

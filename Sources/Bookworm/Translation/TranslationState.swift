import Foundation

/// Per-source-string lifecycle state for translation requests. Shared
/// between the on-image hover overlay (`TranslateOverlayView`) and the
/// side translation panel (`TranslationPanelView`), both of which key
/// their displayed text on this enum.
enum TranslationState: Equatable {
    case loading
    case loaded(String)
    case failed(String)
}

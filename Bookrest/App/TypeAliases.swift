import ABSClient

// SwiftUI transitively imports DeveloperToolsSupport, which declares its own
// `LibraryItem` for the Xcode library browser. Without this module-local alias
// every mention in the app is ambiguous, and qualifying each one reads badly.
typealias LibraryItem = ABSClient.LibraryItem

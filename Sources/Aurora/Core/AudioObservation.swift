import CoreAudio
import Foundation

/// 保留注册时的回调，移除监听时必须传入同一个 block。
final class AudioObservation {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let callback: AudioObjectPropertyListenerBlock

    init?(object: AudioObjectID, selector: AudioObjectPropertySelector,
          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
          element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
          onChange: @escaping () -> Void) {
        self.object = object
        address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        callback = { _, _ in onChange() }
        guard AudioObjectHasProperty(object, &address),
              AudioObjectAddPropertyListenerBlock(object, &address, .main, callback) == noErr else { return nil }
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(object, &address, .main, callback)
    }
}

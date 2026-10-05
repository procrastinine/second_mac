import Foundation
import Virtualization

enum SecondMacAudio {
  static func device(audio: Bool, suspendable: Bool) -> VZVirtioSoundDeviceConfiguration {
    let environment = ProcessInfo.processInfo.environment
    let inputEnabled = !suspendable && (environment["SECOND_MAC_MICROPHONE"].map { $0 == "1" } ?? audio)
    let outputEnabled = !suspendable && (environment["SECOND_MAC_AUDIO_OUTPUT"].map { $0 == "1" } ?? audio)
    let device = VZVirtioSoundDeviceConfiguration()
    // Keep Tart's silent output when playback is disabled. An output-only VM
    // never creates a host input source or exposes an input stream to the guest.
    let output = VZVirtioSoundDeviceOutputStreamConfiguration()
    if outputEnabled { output.sink = VZHostAudioOutputStreamSink() }
    if inputEnabled {
      let input = VZVirtioSoundDeviceInputStreamConfiguration()
      input.source = VZHostAudioInputStreamSource()
      device.streams = [input, output]
    } else {
      device.streams = [output]
    }
    return device
  }
}

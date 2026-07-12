## 0.1.4

* **UPDATED:** Bumped `flutter_webrtc` to `^1.5.2`, raised the Flutter baseline to `>=1.22.0`, and verified compatibility with its current RTP types.
* **DOCUMENTED:** Added installation, compatibility, signaling, transport setup, upgrade guidance, and a clear path from low-level mediasoup primitives to the full MediaSFU Flutter SDK.
* **METADATA:** Added focused pub.dev topics and dedicated homepage, documentation, repository, and issue-tracker links.

## 0.1.3

* **FIXED:** `RtpEncodingParameters` type mismatch with `RTCRtpEncoding` base class for `priority` and `networkPriority` fields (#6).
* **UPDATED:** Bumped `flutter_webrtc` dependency to `^1.3.0` for proper `RTCPriorityType` support.

## 0.1.2

* **FIXED:** VP9 codec negotiation bug fix, particularly for macOS.

## 0.1.1

* **FIXED:** VP9 codec negotiation bug fix.
* **ENHANCED:** Updated `flutter_webrtc` dependency.

## 0.1.0

* **COMPLETED:** Chrome M140 WebRTC compatibility support for video and audio.

## 0.0.9

* **BREAKING:** Chrome M140 WebRTC compatibility support in progress.
* **NEW:** Added PCMU (G.711 mu-law) and PCMA (G.711 A-law) audio codec support.
* **NEW:** Added `pcmuPtime` and `pcmaPtime` options to `ProducerCodecOptions` for G.711 codec configuration.
* **ENHANCED:** Improved SDP parameter handling for PCMU/PCMA codecs with proper ptime configuration.
* **ENHANCED:** Enhanced `CommonUtils.applyCodecParameters()` to support PCMU and PCMA audio codecs.
* **ENHANCED WORK IN PROGRESS:** Chrome M140 parameter synchronization system with RTX apt parameter fixing.

## 0.0.8

* Added support for current WebRTC.

## 0.0.7

* Fixed CNAME static-pass issues.

## 0.0.6

* Added support for current WebRTC.

## 0.0.5

* Added support for current WebRTC.

## 0.0.4

* Fixed `getRemoteStreams()` behavior.

## 0.0.3

* Updated support for current WebRTC.

## 0.0.2

* Cleaned up minor warnings for static analysis.
* Updated documentation.

## 0.0.1

* Initial release.
* Modified version of `mediasoup-client-flutter`.
* Added support for current WebRTC.
* Fixed simulcast RID errors.

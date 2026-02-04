## 0.1.3
* **FIXED:** `RtpEncodingParameters` type mismatch with `RTCRtpEncoding` base class for `priority` and `networkPriority` fields (#6)
* **UPDATED:** Bumped `flutter_webrtc` dependency to `^1.3.0` for proper `RTCPriorityType` support

## 0.1.2
* **FIXED:** VP9 codec negotiation bug fix; particularly for MacOS.

## 0.1.1
* **FIXED:** VP9 codec negotiation bug fix.
* **ENHANCED:** Updated `flutter_webrtc` dependency.

## 0.1.0
* **COMPLETED:** Chrome M140 WebRTC compatibility support for Video and Audio

## 0.0.9
* **BREAKING:** Chrome M140 WebRTC compatibility support in progress
* **NEW:** Added PCMU (G.711 μ-law) and PCMA (G.711 A-law) audio codec support
* **NEW:** Added `pcmuPtime` and `pcmaPtime` options to `ProducerCodecOptions` for G.711 codec configuration
* **ENHANCED:** Improved SDP parameter handling for PCMU/PCMA codecs with proper ptime configuration
* **ENHANCED:** Enhanced `CommonUtils.applyCodecParameters()` to support PCMU and PCMA audio codecs
* **ENHANCED WORK IN PROGRESS:** Chrome M140 parameter synchronization system with RTX apt parameter fixing

## 0.0.8
* Added support for current WebRTC.

## 0.0.7
* Cname static pass issues fix.

## 0.0.6
* Added support for current WebRTC.

## 0.0.5
* Added support for current WebRTC.

## 0.0.4
* Bug fix for getRemoteStreams() method.

## 0.0.3
* Updated support for current WebRTC.

## 0.0.2

* Minor warnings cleanup to pass static analysis
* Updated documentation 

## 0.0.1

* Initial release.
* Modified version of mediasoup-client-flutter.
* Added support for current WebRTC.
* Fixed simulcast RID errors.
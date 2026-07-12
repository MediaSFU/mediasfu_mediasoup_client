<p align="center">
  <a href="https://www.mediasfu.com/">
    <img src="https://www.mediasfu.com/logo192.png" width="88" alt="MediaSFU">
  </a>
</p>

<h1 align="center">MediaSFU mediasoup client for Flutter</h1>

<p align="center">
  A maintained, low-level mediasoup client for building custom real-time media experiences on Flutter.
</p>

<p align="center">
  <a href="https://pub.dev/packages/mediasfu_mediasoup_client"><img src="https://img.shields.io/pub/v/mediasfu_mediasoup_client?logo=dart" alt="Pub version"></a>
  <a href="https://pub.dev/packages/mediasfu_mediasoup_client/score"><img src="https://img.shields.io/pub/points/mediasfu_mediasoup_client" alt="Pub points"></a>
  <a href="https://github.com/MediaSFU/mediasfu_mediasoup_client/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-0f766e" alt="MIT license"></a>
  <a href="https://github.com/MediaSFU/mediasfu_mediasoup_client"><img src="https://img.shields.io/github/stars/MediaSFU/mediasfu_mediasoup_client?style=flat" alt="GitHub stars"></a>
</p>

Use mediasoup primitives such as `Device`, `Transport`, `Producer`, `Consumer`, `DataProducer`, and `DataConsumer` while keeping full control of your signaling and application UI. Version `0.1.4` is aligned with `flutter_webrtc ^1.5.2` and supports Unified Plan, simulcast, data channels, and Opus/PCMU/PCMA audio negotiation.

## Choose the right Flutter path

| You need | Start with |
| --- | --- |
| Custom signaling, custom UI, and direct control of mediasoup transports | **This package** |
| Complete rooms, signaling, participant state, and ready-to-use Flutter components | [`mediasfu_sdk`](https://pub.dev/packages/mediasfu_sdk) |
| A self-hosted MediaSFU backend | [MediaSFU Open](https://github.com/MediaSFU/MediaSFUOpen) |
| Managed recording, SIP/telephony, translation, AI notes, and production infrastructure | [MediaSFU](https://www.mediasfu.com/) |

## Install

```sh
flutter pub add mediasfu_mediasoup_client
```

```dart
import 'package:mediasfu_mediasoup_client/mediasfu_mediasoup_client.dart';
```

### Compatibility

| Component | Supported baseline |
| --- | --- |
| Dart | `>=3.3.3 <4.0.0` |`r`n| Flutter | `>=1.22.0` |
| Flutter WebRTC | `^1.5.2` |
| Platforms | Android, iOS, Linux, macOS, Windows |

This package currently targets native Flutter platforms. For browser applications, use a MediaSFU web SDK or the JavaScript mediasoup client.

## How it fits together

This library owns the **client-side WebRTC and mediasoup negotiation**. Your application still provides the signaling channel and a mediasoup-compatible server.

1. Request the router RTP capabilities from your server.
2. Load a `Device` with those capabilities.
3. Ask your server to create send and receive WebRTC transports.
4. Create local transports from the server response.
5. Exchange DTLS and producer parameters through your signaling channel.
6. Produce local tracks and consume remote producers.

## Integration skeleton

The example below shows the key client flow. The `signaling` calls represent your WebSocket or HTTP implementation.

```dart
import 'package:mediasfu_mediasoup_client/mediasfu_mediasoup_client.dart';

final device = Device();

Future<Transport> createSendTransport(SignalingClient signaling) async {
  final routerCapabilities = await signaling.getRouterRtpCapabilities();

  await device.load(
    routerRtpCapabilities: RtpCapabilities.fromMap(routerCapabilities),
  );

  final transportOptions = await signaling.createWebRtcTransport(
    direction: 'send',
    sctpCapabilities: device.sctpCapabilities.toMap(),
  );

  final transport = device.createSendTransportFromMap(transportOptions);

  transport.on('connect', (data) async {
    try {
      await signaling.connectWebRtcTransport(
        transportId: transport.id,
        dtlsParameters: data['dtlsParameters'].toMap(),
      );
      data['callback']();
    } catch (error) {
      data['errback'](error);
    }
  });

  transport.on('produce', (data) async {
    try {
      final producerId = await signaling.produce(
        transportId: transport.id,
        kind: data['kind'],
        rtpParameters: data['rtpParameters'].toMap(),
        appData: data['appData'],
      );
      data['callback'](producerId);
    } catch (error) {
      data['errback'](error);
    }
  });

  return transport;
}
```

After acquiring media with `navigator.mediaDevices.getUserMedia`, publish a track through the send transport:

```dart
final stream = await navigator.mediaDevices.getUserMedia({
  'audio': true,
  'video': true,
});

final videoTrack = stream.getVideoTracks().first;

sendTransport.produce(
  track: videoTrack,
  stream: stream,
  source: 'webcam',
  appData: {'mediaTag': 'camera'},
);
```

Use `producerCallback` when creating the send transport, or listen to `transport.observer`, to retain the resulting `Producer` in your application state.

> The signaling method names above are illustrative. Your server contract determines endpoint names and response shapes. Transport data must include mediasoup `id`, `iceParameters`, `iceCandidates`, and `dtlsParameters`; SCTP parameters are optional.

## Why this package

- **Maintained WebRTC alignment:** tracks current `flutter_webrtc` APIs instead of leaving applications pinned to an old native WebRTC layer.
- **Low-level control:** design your own signaling, state model, media controls, and interface.
- **Media and data:** supports producers, consumers, SCTP data producers, and data consumers.
- **Codec coverage:** includes Opus and G.711 PCMU/PCMA handling for real-time and telephony-oriented media flows.
- **Clear growth path:** move to the full MediaSFU Flutter SDK when you no longer want to maintain room orchestration yourself.

## From primitives to a complete product

Building directly on mediasoup is ideal when the transport layer is part of your product differentiation. It also means your team owns signaling reliability, room lifecycle, reconnection, permissions, recording orchestration, and production operations.

When you want those pieces already integrated, add the MediaSFU Flutter SDK:

```sh
flutter pub add mediasfu_sdk
```

The full SDK adds higher-level room workflows and components while connecting to the broader MediaSFU platform for recording, streaming, SIP/telephony, translation, AI features, and managed or self-hosted deployment options.

- [MediaSFU Flutter SDK on pub.dev](https://pub.dev/packages/mediasfu_sdk)
- [MediaSFU documentation](https://www.mediasfu.com/documentation)
- [Interactive API sandbox](https://www.mediasfu.com/sandbox)
- [Community forum](https://www.mediasfu.com/forums)

## Upgrading `flutter_webrtc`

WebRTC dependency updates can change native binaries and RTP types even when your Dart code is unchanged. When upgrading this package:

1. Run `flutter clean` if an older native WebRTC artifact remains cached.
2. Run `flutter pub get`.
3. Rebuild each platform you ship; do not rely on hot reload for native dependency changes.
4. Exercise camera, microphone, screen sharing, reconnect, and Bluetooth/audio-route flows on real devices.
5. Verify server codec and RTP capability negotiation before rollout.

## Contributing

Issues and focused pull requests are welcome at [MediaSFU/mediasfu_mediasoup_client](https://github.com/MediaSFU/mediasfu_mediasoup_client). Include the Flutter version, platform, device and OS version, `flutter_webrtc` version, and a minimal reproduction for media negotiation issues.

## Credits

This package is based on [mediasoup-client-flutter](https://github.com/Blancduman/mediasoup-client-flutter) and is maintained by [MediaSFU](https://www.mediasfu.com/).

## License

MIT. See [LICENSE](https://github.com/MediaSFU/mediasfu_mediasoup_client/blob/main/LICENSE).

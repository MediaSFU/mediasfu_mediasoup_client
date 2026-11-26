import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mediasfu_mediasoup_client/mediasfu_mediasoup_client.dart';
import 'package:mediasfu_mediasoup_client/src/handlers/handler_interface.dart';
import 'package:mediasfu_mediasoup_client/src/handlers/plan_b.dart';
import 'package:mediasfu_mediasoup_client/src/handlers/unified_plan.dart';
import 'package:mediasfu_mediasoup_client/src/ortc.dart';

const methodChannel = MethodChannel('FlutterWebRTC.Method');
const audio = RTCRtpMediaType.RTCRtpMediaTypeAudio;
const fingerprint = '00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF';
Map<String, dynamic> trackMap(String id) =>
    {'id': id, 'kind': 'audio', 'label': id, 'enabled': true};
const nativeRtp = {
  'codecs': [],
  'encodings': [],
  'headerExtensions': [],
  'rtcp': {'reducedSize': true}
};

class PeerBoundary {
  final calls = <String>[];
  final unnegotiatedSenders = <String>[];
  String? remoteOffer;
  Completer<void>? allowClose;

  Future<dynamic> dispatch(MethodCall call) async {
    calls.add(call.method);
    switch (call.method) {
      case 'initialize':
        return null;
      case 'peerConnectionClose':
        await allowClose?.future;
        return null;
      case 'createPeerConnection':
        return {'peerConnectionId': 'pr12-test'};
      case 'addTransceiver':
        final track = (call.arguments as Map)['trackId'] as String;
        unnegotiatedSenders.add(track);
        return transceiver(track, '');
      case 'setRemoteDescription':
        final description = (call.arguments as Map)['description'] as Map;
        remoteOffer = description['sdp'] as String;
        return null;
      case 'getTransceivers':
        return {
          'transceivers': [
            transceiver('unrelated', 'other-mid'),
            transceiver('remote', 'wanted-mid')
          ]
        };
      case 'createOffer':
        throw PlatformException(
            code: 'test-terminal', message: 'stop test at createOffer');
      case 'createAnswer':
        throw PlatformException(
            code: 'test-terminal', message: 'stop test at createAnswer');
      case 'removeTrack':
      case 'rtpSenderReplaceTrack':
      case 'rtpTransceiverStop':
        fail('Mock needs to model cleanup method ' + call.method);
      default:
        fail('Unexpected native call ' + call.method);
    }
  }

  Map<String, dynamic> transceiver(String track, String mid) => {
        'mid': mid,
        'direction': mid.isEmpty ? 'sendonly' : 'recvonly',
        'transceiverId': 'transceiver-' + track,
        'sender': {
          'senderId': 'sender-' + track,
          'track': trackMap(track),
          'rtpParameters': nativeRtp,
          'ownsTrack': false
        },
        'receiver': {
          'receiverId': 'receiver-' + track,
          'track': trackMap(track),
          'rtpParameters': nativeRtp
        },
      };
}

class TestTrack extends Fake implements MediaStreamTrack {
  TestTrack(this.id);
  @override
  final String id;
  @override
  String get kind => 'audio';
}

class TestStream extends Fake implements MediaStream {
  @override
  String get id => 'local-stream';
}

HandlerRunOptions runOptions(Direction direction) => HandlerRunOptions(
      direction: direction,
      iceParameters: IceParameters(
          usernameFragment: 'test',
          password: 'password-for-tests-only',
          iceLite: true),
      iceCandidates: [],
      dtlsParameters: DtlsParameters(role: DtlsRole.auto, fingerprints: [
        DtlsFingerprint(algorithm: 'sha-256', value: fingerprint)
      ]),
      iceServers: [],
      additionalSettings: <String, dynamic>{},
      proprietaryConstraints: {},
      extendedRtpCapabilities: ExtendedRtpCapabilities(codecs: [
        ExtendedRtpCodec(
            kind: audio,
            mimeType: 'audio/opus',
            clockRate: 48000,
            channels: 2,
            localPayloadType: 111,
            remotePayloadType: 111,
            localParameters: {},
            remoteParameters: {}),
      ]),
    );

HandlerSendOptions sendOptions(String id, [OnRtpSender? hook]) =>
    HandlerSendOptions(
        track: TestTrack(id), stream: TestStream(), onRtpSender: hook);
HandlerReceiveOptions receiveOptions(String mid, [OnRtpReceiver? hook]) =>
    HandlerReceiveOptions(
      trackId: 'consumer-' + mid,
      kind: audio,
      rtpParameters: RtpParameters(mid: mid, codecs: [
        RtpCodecParameters(
            mimeType: 'audio/opus',
            payloadType: 111,
            clockRate: 48000,
            channels: 2),
      ], encodings: [
        RtpEncodingParameters(ssrc: mid == 'wanted-mid' ? 1234 : 5678)
      ]),
      onRtpReceiver: hook,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late PeerBoundary peer;
  late UnifiedPlan handler;
  setUp(() {
    peer = PeerBoundary();
    handler = UnifiedPlan();
    messenger.setMockMethodCallHandler(methodChannel, peer.dispatch);
  });
  tearDown(() async {
    await handler.close();
    messenger.setMockMethodCallHandler(methodChannel, null);
  });

  test('send waits for asynchronous setup before creating the offer', () async {
    (handler as dynamic).run(options: runOptions(Direction.send));
    await Future<void>.delayed(Duration.zero);
    final entered = Completer<void>();
    final ready = Completer<void>();
    final result = handler.send(sendOptions('local', (sender) {
      expect(sender.senderId, 'sender-local');
      entered.complete();
      return ready.future;
    }));
    final expected =
        expectLater(result, throwsA(contains('stop test at createOffer')));
    await entered.future.timeout(const Duration(seconds: 2));
    expect(peer.calls, contains('addTransceiver'));
    expect(peer.calls, isNot(contains('createOffer')));
    ready.complete();
    await expected;
  });

  test('receive picks the requested MID and waits before creating the answer',
      () async {
    (handler as dynamic).run(options: runOptions(Direction.recv));
    await Future<void>.delayed(Duration.zero);
    final entered = Completer<void>();
    final ready = Completer<void>();
    final result = handler.receive(receiveOptions('wanted-mid', (receiver) {
      expect(receiver.receiverId, 'receiver-remote');
      entered.complete();
      return ready.future;
    }));
    final expected =
        expectLater(result, throwsA(contains('stop test at createAnswer')));
    await entered.future.timeout(const Duration(seconds: 2));
    expect(peer.calls,
        containsAllInOrder(['setRemoteDescription', 'getTransceivers']));
    expect(peer.calls, isNot(contains('createAnswer')));
    ready.complete();
    await expected;
  });

  for (final direction in Direction.values) {
    test('failed $direction RTP setup closes before the next queued operation',
        () async {
      final options = runOptions(direction);
      final transport = Transport(
        direction: direction,
        id: 'transport',
        iceParameters: options.iceParameters,
        iceCandidates: options.iceCandidates,
        dtlsParameters: options.dtlsParameters,
        extendedRtpCapabilities: options.extendedRtpCapabilities,
        canProduceByKind: CanProduceByKind(audio: true, video: false),
      );
      addTearDown(transport.close);
      final closeGate = Completer<void>();
      peer.allowClose = closeGate;
      final setupError = StateError('cryptor setup failed');
      final failure = Completer<Map>();
      final setupEntered = Completer<void>();
      final finishSetup = Completer<void>();

      transport.on('connect', (Map data) => fail('Unexpected connect'));
      transport.on('produce', (Map data) => fail('Unexpected producer'));
      transport.on('rtpsetuperror', (Map data) => failure.complete(data));

      Future<void> setup() {
        setupEntered.complete();
        return finishSetup.future;
      }

      await Future<void>.delayed(Duration.zero);
      if (direction == Direction.send) {
        transport.produce(
            track: TestTrack('failed-track'),
            stream: TestStream(),
            source: 'microphone',
            stopTracks: false,
            onRtpSender: (_) => setup());
        transport.produce(
            track: TestTrack('queued-track'),
            stream: TestStream(),
            source: 'microphone',
            stopTracks: false);
        transport.restartIce(options.iceParameters);
      } else {
        transport.consume(
            id: 'first',
            producerId: 'p1',
            peerId: 'peer',
            kind: audio,
            rtpParameters: receiveOptions('wanted-mid').rtpParameters,
            onRtpReceiver: (_) => setup());
        transport.consume(
            id: 'second',
            producerId: 'p2',
            peerId: 'peer',
            kind: audio,
            rtpParameters: receiveOptions('next-mid').rtpParameters);
      }
      await setupEntered.future.timeout(const Duration(seconds: 2));
      finishSetup.completeError(setupError);
      await Future<void>.delayed(Duration.zero);
      expect(transport.closed, isTrue);
      expect(failure.isCompleted, isFalse);
      expect(peer.calls, contains('peerConnectionClose'));
      closeGate.complete();

      final event = await failure.future.timeout(const Duration(seconds: 2));
      expect(event['error'], same(setupError));
      expect(event['direction'], direction);
      await Future<void>.delayed(Duration.zero);
      expect(peer.calls, isNot(contains('createOffer')));
      expect(peer.calls, isNot(contains('createAnswer')));
      if (direction == Direction.send) {
        expect(peer.unnegotiatedSenders, ['failed-track']);
        expect(
            () => transport.produce(
                track: TestTrack('late-track'),
                stream: TestStream(),
                source: 'microphone'),
            throwsA('closed'));
      } else {
        expect(peer.calls.where((call) => call == 'setRemoteDescription'),
            hasLength(1));
        expect(peer.remoteOffer, isNot(contains('a=mid:next-mid')));
      }
    });
  }

  test('Plan B rejects hooks before touching negotiation', () async {
    final send = PlanB();
    final recv = PlanB();
    (send as dynamic).run(options: runOptions(Direction.send));
    await Future<void>.delayed(Duration.zero);
    (recv as dynamic).run(options: runOptions(Direction.recv));
    await Future<void>.delayed(Duration.zero);
    await expectLater(
        send.send(sendOptions('local', (_) {})), throwsUnsupportedError);
    await expectLater(recv.receive(receiveOptions('wanted-mid', (_) {})),
        throwsUnsupportedError);
    expect(peer.calls, isNot(contains('addTransceiver')));
    expect(peer.calls, isNot(contains('setRemoteDescription')));
    await send.close();
    await recv.close();
  });
}

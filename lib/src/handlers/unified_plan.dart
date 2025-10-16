// ignore_for_file: cast_from_null_always_fails, empty_catches

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:sdp_transform/sdp_transform.dart';
import 'package:mediasfu_mediasoup_client/src/ortc.dart';
import 'package:mediasfu_mediasoup_client/src/scalability_modes.dart';
import 'package:mediasfu_mediasoup_client/src/sdp_object.dart';
import 'package:mediasfu_mediasoup_client/src/transport.dart';
import 'package:mediasfu_mediasoup_client/src/sctp_parameters.dart';
import 'package:mediasfu_mediasoup_client/src/rtp_parameters.dart';
import 'package:mediasfu_mediasoup_client/src/handlers/handler_interface.dart';
import 'package:mediasfu_mediasoup_client/src/handlers/sdp/common_utils.dart';
import 'package:mediasfu_mediasoup_client/src/handlers/sdp/media_section.dart';
import 'package:mediasfu_mediasoup_client/src/handlers/sdp/remote_sdp.dart';
import 'package:mediasfu_mediasoup_client/src/handlers/sdp/unified_plan_utils.dart';

class UnifiedPlan extends HandlerInterface {
  // Handler direction.
  late Direction _direction;

  /// Helper method to find the first element in an iterable that satisfies a condition,
  /// or return null if no element is found.
  T? _firstWhereOrNull<T>(Iterable<T> iterable, bool Function(T) test) {
    try {
      return iterable.firstWhere(test);
    } catch (e) {
      return null;
    }
  }

  // Remote SDP handler.
  late RemoteSdp _remoteSdp;
  // Extended RTP capabilities for Chrome M140+ compatibility.
  late ExtendedRtpCapabilities _extendedRtpCapabilities;
  // Generic sending RTP parameters for audio and video.
  late Map<RTCRtpMediaType, RtpParameters> _sendingRtpParametersByKind;
  // Generic sending RTP parameters for audio and video suitable for the SDP
  // remote answer.
  late Map<RTCRtpMediaType, RtpParameters> _sendingRemoteRtpParametersByKind;
  // Initial server side DTLS role. If not 'auto', it will force the opposite
  // value in client side.
  DtlsRole? _forcedLocalDtlsRole;
  // RTCPeerConnection instance.
  RTCPeerConnection? _pc;
  // Map of RTCTransceivers indexed by MID.
  final Map<String, RTCRtpTransceiver> _mapMidTransceiver = {};
  // Whether a DataChannel m=application section has been created.
  bool _hasDataChannelMediaSection = false;
  // Sending DataChannel id value counter. Incremented for each new DataChannel.
  int _nextSendSctpStreamId = 0;
  // Got transport local and remote parameters.
  bool _transportReady = false;

  UnifiedPlan() : super();

  Future<void> _setupTransport({
    required DtlsRole localDtlsRole,
    SdpObject? localSdpObject,
  }) async {
    localSdpObject ??=
        SdpObject.fromMap(parse((await _pc!.getLocalDescription())!.sdp!));

    // Get our local DTLS parameters.
    DtlsParameters dtlsParameters =
        CommonUtils.extractDtlsParameters(localSdpObject);

    // Set our DTLS role.
    dtlsParameters.role = localDtlsRole;

    // Update the remote DTLC role in the SDP.
    _remoteSdp.updateDtlsRole(
      localDtlsRole == DtlsRole.client ? DtlsRole.server : DtlsRole.client,
    );

    // Need to tell the remote transport about our parameters.
    await safeEmitAsFuture('@connect', {
      'dtlsParameters': dtlsParameters,
    });

    _transportReady = true;
  }

  void _assertSendRirection() {
    if (_direction != Direction.send) {
      throw ('method can just be called for handlers with "send" direction');
    }
  }

  void _assertRecvDirection() {
    if (_direction != Direction.recv) {
      throw ('method can just be called for handlers with "recv" direction');
    }
  }

  @override
  Future<void> close() async {
    // Close RTCPeerConnection.
    if (_pc != null) {
      try {
        await _pc!.close();
      } catch (error) {}
    }
  }

  @override
  Future<RtpCapabilities> getNativeRtpCapabilities() async {
    RTCPeerConnection pc = await createPeerConnection({
      'iceServers': [],
      'iceTransportPolicy': 'all',
      'bundlePolicy': 'max-bundle',
      'rtcpMuxPolicy': 'require',
      'sdpSemantics': 'unified-plan',
    }, {
      'optional': [
        {'DtlsSrtpKeyAgreement': true},
      ],
    });

    try {
      await pc.addTransceiver(kind: RTCRtpMediaType.RTCRtpMediaTypeAudio);
      await pc.addTransceiver(kind: RTCRtpMediaType.RTCRtpMediaTypeVideo);

      RTCSessionDescription offer = await pc.createOffer({});
      final parsedOffer = parse(offer.sdp!);
      SdpObject sdpObject = SdpObject.fromMap(parsedOffer);

      RtpCapabilities nativeRtpCapabilities =
          CommonUtils.extractRtpCapabilities(sdpObject);

      Ortc.validateAndNormalizeRtpCapabilities(nativeRtpCapabilities);

      return nativeRtpCapabilities;
    } catch (error) {
      try {
        await pc.close();
      } catch (error2) {}

      rethrow;
    }
  }

  @override
  SctpCapabilities getNativeSctpCapabilities() {
    return SctpCapabilities(
        numStreams: NumSctpStreams(
      mis: SCTP_NUM_STREAMS.MIS,
      os: SCTP_NUM_STREAMS.OS,
    ));
  }

  @override
  Future<List<StatsReport>> getReceiverStats(String localId) async {
    _assertRecvDirection();

    RTCRtpTransceiver? transceiver = _mapMidTransceiver[localId];

    if (transceiver == null) {
      throw ('associated RTCRtpTransceiver not found');
    }

    return await transceiver.receiver.getStats();
  }

  @override
  Future<List<StatsReport>> getSenderStats(String localId) async {
    _assertSendRirection();

    RTCRtpTransceiver? transceiver = _mapMidTransceiver[localId];

    if (transceiver == null) {
      throw ('associated RTCRtpTransceiver not found');
    }

    return await transceiver.sender.getStats();
  }

  @override
  Future<List<StatsReport>> getTransportStats() async {
    return await _pc!.getStats();
  }

  @override
  String get name => 'Unified plan handler';

  @override
  Future<HandlerReceiveResult> receive(HandlerReceiveOptions options) async {
    if (_pc == null) {
      await Future.delayed(const Duration(milliseconds: 1500));
    }
    _assertRecvDirection();

    // 'receive() [trackId:${options.trackId}, kind:${RTCRtpMediaTypeExtension.value(options.kind)}]');

    String localId =
        options.rtpParameters.mid ?? _mapMidTransceiver.length.toString();

    _remoteSdp.receive(
      mid: localId,
      kind: options.kind,
      offerRtpParameters: options.rtpParameters,
      streamId: options.rtpParameters.rtcp?.cname ?? 'default_cname',
      trackId: options.trackId,
    );

    RTCSessionDescription offer = RTCSessionDescription(
      _remoteSdp.getSdp(),
      'offer',
    );

    // // 'receive() | calling pc.setRemoteDescription() [offer:${offer.toMap()}]');

    await _pc!.setRemoteDescription(offer);

    RTCSessionDescription answer = await _pc!.createAnswer({});

    SdpObject localSdpObject = SdpObject.fromMap(parse(answer.sdp!));

    MediaObject answerMediaObject = localSdpObject.media.firstWhere(
      (MediaObject m) => m.mid == localId,
      orElse: () => null as MediaObject,
    );

    // May need to modify codec parameters in the answer based on codec
    // parameters in the offer.
    CommonUtils.applyCodecParameters(options.rtpParameters, answerMediaObject);

    answer = RTCSessionDescription(
      write(localSdpObject.toMap(), null),
      'answer',
    );

    if (!_transportReady) {
      await _setupTransport(
        localDtlsRole: DtlsRole.client,
        localSdpObject: localSdpObject,
      );
    }

    // // 'receive() | calling pc.setLocalDescription() [answer:${answer.toMap()}]');

    await _pc!.setLocalDescription(answer);

    final transceivers = await _pc!.getTransceivers();

    RTCRtpTransceiver? transceiver = _firstWhereOrNull(
      transceivers,
      (RTCRtpTransceiver t) => t.mid == localId,
      // orElse: () => null,
    );

    if (transceiver == null) {
      throw ('new RTCRtpTransceiver not found');
    }

    // Store in the map.
    _mapMidTransceiver[localId] = transceiver;

    MediaStream? stream;

    try {
      // Attempt to retrieve the remote stream
      stream = _firstWhereOrNull(
          _pc!.getRemoteStreams().where((e) => e != null).cast<MediaStream>(),
          (e) => e.id == options.rtpParameters.rtcp?.cname);
    } catch (e) {
      // Log the error
      // _logger.error('Error in getRemoteStreams: $e');

      // Attempt fallback mechanism
      final MediaStreamTrack? track = _firstWhereOrNull(
          (await _pc!.getReceivers()),
          (receiver) => receiver.track?.id == options.trackId)?.track;

      if (track == null) {
        throw Exception('Track not found for trackId: ${options.trackId}');
      }

      // Create a new local media stream and add the track
      stream = await createLocalMediaStream(
          options.rtpParameters.rtcp?.cname ?? 'default_cname');
      stream.addTrack(track);
    }

    if (stream == null) {
      throw ('Stream not found');
    }

    return HandlerReceiveResult(
      localId: localId,
      track: transceiver.receiver.track!,
      rtpReceiver: transceiver.receiver,
      stream: stream,
    );
  }

  @override
  Future<HandlerReceiveDataChannelResult> receiveDataChannel(
      HandlerReceiveDataChannelOptions options) async {
    _assertRecvDirection();

    RTCDataChannelInit initOptions = RTCDataChannelInit();
    initOptions.negotiated = true;
    initOptions.id = options.sctpStreamParameters.streamId;
    initOptions.ordered =
        options.sctpStreamParameters.ordered ?? initOptions.ordered;
    initOptions.maxRetransmitTime =
        options.sctpStreamParameters.maxPacketLifeTime ??
            initOptions.maxRetransmitTime;
    initOptions.maxRetransmits = options.sctpStreamParameters.maxRetransmits ??
        initOptions.maxRetransmits;
    initOptions.protocol = options.protocol;

    RTCDataChannel dataChannel =
        await _pc!.createDataChannel(options.label, initOptions);

    // If this is the first DataChannel we need to create the SDP offer with
    // m=application section.
    if (!_hasDataChannelMediaSection) {
      _remoteSdp.receiveSctpAssociation();

      RTCSessionDescription offer =
          RTCSessionDescription(_remoteSdp.getSdp(), 'offer');

      // // 'receiveDataChannel() | calling pc.setRemoteDescription() [offer:${offer.toMap()}]');

      await _pc!.setRemoteDescription(offer);

      RTCSessionDescription answer = await _pc!.createAnswer({});

      if (!_transportReady) {
        SdpObject localSdpObject = SdpObject.fromMap(parse(answer.sdp!));

        await _setupTransport(
          localDtlsRole: _forcedLocalDtlsRole ?? DtlsRole.client,
          localSdpObject: localSdpObject,
        );
      }

      // 'receiveDataChannel() | calling pc.setRemoteDescription() [answer: ${answer.toMap()}');

      await _pc!.setLocalDescription(answer);

      _hasDataChannelMediaSection = true;
    }

    return HandlerReceiveDataChannelResult(dataChannel: dataChannel);
  }

  @override
  Future<void> replaceTrack(ReplaceTrackOptions options) async {
    _assertSendRirection();

    RTCRtpTransceiver? transceiver = _mapMidTransceiver[options.localId];

    if (transceiver == null) {
      throw ('associated RTCRtpTransceiver not found');
    }

    await transceiver.sender.replaceTrack(options.track);
    _mapMidTransceiver.remove(options.localId);
  }

  @override
  Future<void> restartIce(IceParameters iceParameters) async {
    // Provide the remote SDP handler with new remote Ice parameters.
    _remoteSdp.updateIceParameters(iceParameters);

    if (!_transportReady) {
      return;
    }

    if (_direction == Direction.send) {
      RTCSessionDescription offer =
          await _pc!.createOffer({'iceRestart': true});

      // // 'restartIce() | calling pc.setLocalDescription() [offer:${offer.toMap()}]');

      await _pc!.setLocalDescription(offer);

      RTCSessionDescription answer =
          RTCSessionDescription(_remoteSdp.getSdp(), 'answer');

      // // 'restartIce() | calling pc.setRemoteDescription() [answer:${answer.toMap()}]');

      await _pc!.setRemoteDescription(answer);
    } else {
      RTCSessionDescription offer =
          RTCSessionDescription(_remoteSdp.getSdp(), 'offer');

      // // 'restartIce() | calling pc.setRemoteDescription() [offer:${offer.toMap()}]');

      await _pc!.setRemoteDescription(offer);

      RTCSessionDescription answer = await _pc!.createAnswer({});

      // // 'restartIce() | calling pc.setLocalDescription() [answer:${answer.toMap()}]');

      await _pc!.setLocalDescription(answer);
    }
  }

  @override
  void run({required HandlerRunOptions options}) async {
    _direction = options.direction;

    // Store extended RTP capabilities for Chrome M140+ compatibility
    _extendedRtpCapabilities = options.extendedRtpCapabilities;

    _remoteSdp = RemoteSdp(
      iceParameters: options.iceParameters,
      iceCandidates: options.iceCandidates,
      dtlsParameters: options.dtlsParameters,
      sctpParameters: options.sctpParameters,
    );

    _sendingRtpParametersByKind = {
      RTCRtpMediaType.RTCRtpMediaTypeAudio: Ortc.getSendingRtpParameters(
        RTCRtpMediaType.RTCRtpMediaTypeAudio,
        options.extendedRtpCapabilities,
      ),
      RTCRtpMediaType.RTCRtpMediaTypeVideo: Ortc.getSendingRtpParameters(
        RTCRtpMediaType.RTCRtpMediaTypeVideo,
        options.extendedRtpCapabilities,
      ),
    };

    _sendingRemoteRtpParametersByKind = {
      RTCRtpMediaType.RTCRtpMediaTypeAudio: Ortc.getSendingRemoteRtpParameters(
        RTCRtpMediaType.RTCRtpMediaTypeAudio,
        options.extendedRtpCapabilities,
      ),
      RTCRtpMediaType.RTCRtpMediaTypeVideo: Ortc.getSendingRemoteRtpParameters(
        RTCRtpMediaType.RTCRtpMediaTypeVideo,
        options.extendedRtpCapabilities,
      ),
    };

    if (options.dtlsParameters.role != DtlsRole.auto) {
      _forcedLocalDtlsRole = options.dtlsParameters.role == DtlsRole.server
          ? DtlsRole.client
          : DtlsRole.server;
    }

    final constrains = options.proprietaryConstraints.isEmpty
        ? <String, dynamic>{
            'mandatory': {},
            'optional': [
              {'DtlsSrtpKeyAgreement': true},
            ],
          }
        : options.proprietaryConstraints;

    constrains['optional'] = [
      ...constrains['optional'],
      {'DtlsSrtpKeyAgreement': true}
    ];

    _pc = await createPeerConnection(
      {
        'iceServers':
            options.iceServers.map((RTCIceServer i) => i.toMap()).toList(),
        'iceTransportPolicy': options.iceTransportPolicy?.value ?? 'all',
        'bundlePolicy': 'max-bundle',
        'rtcpMuxPolicy': 'require',
        'sdpSemantics': 'unified-plan',
        ...options.additionalSettings,
      },
      constrains,
    );

    // Handle RTCPeerConnection connection status.
    _pc!.onIceConnectionState = (RTCIceConnectionState state) {
      switch (_pc!.iceConnectionState) {
        case RTCIceConnectionState.RTCIceConnectionStateChecking:
          {
            emit('@connectionstatechange', {'state': 'connecting'});
            break;
          }
        case RTCIceConnectionState.RTCIceConnectionStateConnected:
        case RTCIceConnectionState.RTCIceConnectionStateCompleted:
          {
            emit('@connectionstatechange', {'state': 'connected'});
            break;
          }
        case RTCIceConnectionState.RTCIceConnectionStateFailed:
          {
            emit('@connectionstatechange', {'state': 'failed'});
            break;
          }
        case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
          {
            emit('@connectionstatechange', {'state': 'disconnected'});
            break;
          }
        case RTCIceConnectionState.RTCIceConnectionStateClosed:
          {
            emit('@connectionstatechange', {'state': 'closed'});
            break;
          }

        default:
          break;
      }
    };
  }

  @override
  Future<HandlerSendResult> send(HandlerSendOptions options) async {
    _assertSendRirection();

    if (options.encodings.length > 1) {
      int idx = 0;
      for (var encoding in options.encodings) {
        encoding.rid = 'r${idx++}';
      }
    }

    RtpParameters sendingRtpParameters = RtpParameters.copy(
        _sendingRtpParametersByKind[
            RTCRtpMediaTypeExtension.fromString(options.track.kind!)]!);

    // This may throw.
    sendingRtpParameters.codecs =
        Ortc.reduceCodecs(sendingRtpParameters.codecs, options.codec);

    RtpParameters sendingRemoteRtpParameters = RtpParameters.copy(
        _sendingRemoteRtpParametersByKind[
            RTCRtpMediaTypeExtension.fromString(options.track.kind!)]!);

    // This may throw.
    sendingRemoteRtpParameters.codecs =
        Ortc.reduceCodecs(sendingRemoteRtpParameters.codecs, options.codec);

    MediaSectionIdx mediaSectionIdx = _remoteSdp.getNextMediaSectionIdx();

    RTCRtpTransceiver transceiver = await _pc!.addTransceiver(
      track: options.track,
      kind: RTCRtpMediaTypeExtension.fromString(options.track.kind!),
      init: RTCRtpTransceiverInit(
        direction: TransceiverDirection.SendOnly,
        streams: [options.stream],
        sendEncodings: options.encodings,
      ),
    );

    RTCSessionDescription offer = await _pc!.createOffer({});
    SdpObject localSdpObject = SdpObject.fromMap(parse(offer.sdp!));
    MediaObject offerMediaObject;

    if (!_transportReady) {
      await _setupTransport(
        localDtlsRole: DtlsRole.server,
        localSdpObject: localSdpObject,
      );
    }

    // Speacial case for VP9 with SVC.
    bool hackVp9Svc = false;

    ScalabilityMode layers = ScalabilityMode.parse((options.encodings.isNotEmpty
            ? options.encodings
            : [RtpEncodingParameters(scalabilityMode: '')])
        .first
        .scalabilityMode!);

    if (options.encodings.length == 1 &&
        layers.spatialLayers > 1 &&
        sendingRtpParameters.codecs.first.mimeType.toLowerCase() ==
            'video/vp9') {
      hackVp9Svc = true;
      localSdpObject = SdpObject.fromMap(parse(offer.sdp!));
      offerMediaObject = localSdpObject.media[mediaSectionIdx.idx];

      UnifiedPlanUtils.addLegacySimulcast(
        offerMediaObject,
        layers.spatialLayers,
      );

      offer =
          RTCSessionDescription(write(localSdpObject.toMap(), null), 'offer');
    }

    await _pc!.setLocalDescription(offer);

    if (!kIsWeb) {
      final transceivers = await _pc!.getTransceivers();
      transceiver = transceivers.firstWhere(
        (transceiver) =>
            transceiver.sender.track?.id == options.track.id &&
            transceiver.sender.track?.kind == options.track.kind,
        orElse: () => throw 'No transceiver found',
      );
    }

    // We can now get the transceiver.mid.
    String localId = transceiver.mid;

    // Set MID.
    sendingRtpParameters.mid = localId;

    // Get the latest local SDP after setLocalDescription
    localSdpObject =
        SdpObject.fromMap(parse((await _pc!.getLocalDescription())!.sdp!));
    offerMediaObject = localSdpObject.media[mediaSectionIdx.idx];

    // Chrome M140+ compatibility: Extract RTP parameters directly from actual SDP
    // Chrome M140+ assigns different payload types and extension IDs depending on
    // the order transceivers are added. We must extract parameters from the actual
    // SDP offer that Chrome just generated, not compute from static capabilities.

    // Chrome M140+ Fix: Extract parameters directly from SDP for compatibility
    try {
      // Extract local parameters from local SDP (what Chrome offered)
      sendingRtpParameters = CommonUtils.extractSendingRtpParameters(
        localSdpObject,
        mediaSectionIdx.idx,
        RTCRtpMediaTypeExtension.fromString(options.track.kind!),
        sendingRtpParameters,
      );

      // Apply codec reduction if specified
      if (options.codec != null) {
        sendingRtpParameters.codecs =
            Ortc.reduceCodecs(sendingRtpParameters.codecs, options.codec);
      }

      // Set MID since we regenerated the parameters
      sendingRtpParameters.mid = localId;

      // CRITICAL: The answer must mirror Chrome's offer payload types and extension IDs
      // Clone local parameters to use as answer parameters for Chrome
      sendingRemoteRtpParameters = RtpParameters.copy(sendingRtpParameters);

      // The answer parameters must match the offer exactly for Chrome to accept them
      // We previously tried to sync them but the issue is that we need to use
      // Chrome's exact payload types and extension IDs in the answer
    } catch (e) {
      // Fallback to capability-based recomputation if SDP extraction fails
      try {
        // Extract fresh RTP capabilities from the current SDP offer
        RtpCapabilities currentLocalRtpCapabilities =
            CommonUtils.extractRtpCapabilities(localSdpObject);

        // Get the remote capabilities from our stored extended capabilities
        // The extended capabilities contain both local and remote codec/extension info
        RtpCapabilities remoteRtpCapabilities = RtpCapabilities(
          codecs: _extendedRtpCapabilities.codecs
              .map((codec) => RtpCodecCapability(
                    kind: codec.kind,
                    mimeType: codec.mimeType,
                    preferredPayloadType: codec.remotePayloadType,
                    clockRate: codec.clockRate,
                    channels: codec.channels,
                    parameters: codec.remoteParameters,
                    rtcpFeedback: codec.rtcpFeedback,
                  ))
              .toList(),
          headerExtensions: _extendedRtpCapabilities.headerExtensions
              .map((ext) => RtpHeaderExtension(
                    kind: ext.kind,
                    uri: ext.uri,
                    preferredId: ext.recvId,
                  ))
              .toList(),
        );

        // Compute extended capabilities with the fresh local capabilities
        ExtendedRtpCapabilities currentExtendedCapabilities =
            Ortc.getExtendedRtpCapabilities(
          currentLocalRtpCapabilities,
          remoteRtpCapabilities,
        );

        // Generate completely fresh sending parameters with Chrome's actual dynamic values
        RTCRtpMediaType mediaType =
            RTCRtpMediaTypeExtension.fromString(options.track.kind!);
        sendingRtpParameters = Ortc.getSendingRtpParameters(
          mediaType,
          currentExtendedCapabilities,
        );

        // Apply codec reduction if specified
        if (options.codec != null) {
          sendingRtpParameters.codecs =
              Ortc.reduceCodecs(sendingRtpParameters.codecs, options.codec);
        }

        // Set MID since we regenerated the parameters
        sendingRtpParameters.mid = localId;

        // Clone local parameters as answer parameters to match Chrome's offer
        sendingRemoteRtpParameters = RtpParameters.copy(sendingRtpParameters);
      } catch (e2) {
        // Continue with original parameters
      }
    }

    // Set RTCP CNAME.
    sendingRtpParameters.rtcp!.cname = CommonUtils.getCname(offerMediaObject);

    // Set RTP encdoings by parsing the SDP offer if no encoding are given.
    if (options.encodings.isEmpty) {
      sendingRtpParameters.encodings =
          UnifiedPlanUtils.getRtpEncodings(offerMediaObject);
    }
    // Set RTP encodings by parsing the SDP offer and complete them with given
    // one if just a single encoding has been given.
    else if (options.encodings.length == 1) {
      List<RtpEncodingParameters> newEncodings =
          UnifiedPlanUtils.getRtpEncodings(offerMediaObject);

      newEncodings[0] =
          RtpEncodingParameters.assign(newEncodings[0], options.encodings[0]);

      // Hack for VP9 SVC.
      if (hackVp9Svc) {
        newEncodings = [newEncodings[0]];
      }

      sendingRtpParameters.encodings = newEncodings;
    }
    // Otherwise if more than 1 encoding are given use them verbatim.
    else {
      sendingRtpParameters.encodings = options.encodings;
    }

    // If VP8 or H264 and there is effective simulcast, add scalabilityMode to
    // each encoding.
    if (sendingRtpParameters.encodings.length > 1 &&
        (sendingRtpParameters.codecs[0].mimeType.toLowerCase() == 'video/vp8' ||
            sendingRtpParameters.codecs[0].mimeType.toLowerCase() ==
                'video/h264')) {
      for (RtpEncodingParameters encoding in sendingRtpParameters.encodings) {
        encoding.scalabilityMode = 'S1T3';
      }
    }

    _remoteSdp.send(
      offerMediaObject: offerMediaObject,
      reuseMid: mediaSectionIdx.reuseMid,
      offerRtpParameters: sendingRtpParameters,
      answerRtpParameters:
          sendingRemoteRtpParameters, // Must match Chrome's offer exactly
      codecOptions: options.codecOptions,
      extmapAllowMixed: true,
    );

    RTCSessionDescription answer =
        RTCSessionDescription(_remoteSdp.getSdp(), 'answer');

    try {
      await _pc!.setRemoteDescription(answer);
    } catch (e) {
      // Fallback to capability-based recomputation if setRemoteDescription fails
      sendingRtpParameters = Ortc.getSendingRtpParameters(
          RTCRtpMediaTypeExtension.fromString(options.track.kind!),
          _extendedRtpCapabilities);

      sendingRemoteRtpParameters = Ortc.getSendingRemoteRtpParameters(
          RTCRtpMediaTypeExtension.fromString(options.track.kind!),
          _extendedRtpCapabilities);

      // Apply codec reduction if specified
      if (options.codec != null) {
        sendingRtpParameters.codecs =
            Ortc.reduceCodecs(sendingRtpParameters.codecs, options.codec);
        sendingRemoteRtpParameters.codecs =
            Ortc.reduceCodecs(sendingRemoteRtpParameters.codecs, options.codec);
      }

      // This may throw.
      Ortc.validateAndNormalizeRtpParameters(sendingRtpParameters);

      _remoteSdp.send(
        offerMediaObject: offerMediaObject,
        reuseMid: null,
        offerRtpParameters: sendingRtpParameters,
        answerRtpParameters: sendingRemoteRtpParameters,
        codecOptions: options.codecOptions,
        extmapAllowMixed: true,
      );

      answer = RTCSessionDescription(_remoteSdp.getSdp(), 'answer');
      await _pc!.setRemoteDescription(answer);
    }

    // Store in the map.
    _mapMidTransceiver[localId] = transceiver;

    return HandlerSendResult(
      localId: localId,
      rtpParameters: sendingRtpParameters,
      rtpSender: transceiver.sender,
    );
  }

  @override
  Future<HandlerSendDataChannelResult> sendDataChannel(
      SendDataChannelArguments options) async {
    _assertSendRirection();

    RTCDataChannelInit initOptions = RTCDataChannelInit();
    initOptions.negotiated = true;
    initOptions.id = _nextSendSctpStreamId;
    initOptions.ordered = options.ordered ?? initOptions.ordered;
    initOptions.maxRetransmitTime =
        options.maxPacketLifeTime ?? initOptions.maxRetransmitTime;
    initOptions.maxRetransmits =
        options.maxRetransmits ?? initOptions.maxRetransmits;
    initOptions.protocol = options.protocol ?? initOptions.protocol;
    // initOptions.priority = options.priority;

    RTCDataChannel dataChannel =
        await _pc!.createDataChannel(options.label!, initOptions);

    // Increase next id.
    _nextSendSctpStreamId = ++_nextSendSctpStreamId % SCTP_NUM_STREAMS.MIS;

    // If this is the first DataChannel we need to create the SDP answer with
    // m=application section.
    if (!_hasDataChannelMediaSection) {
      RTCSessionDescription offer = await _pc!.createOffer({});
      SdpObject localSdpObject = SdpObject.fromMap(parse(offer.sdp!));
      MediaObject? offerMediaObject = _firstWhereOrNull(
          localSdpObject.media, (MediaObject m) => m.type == 'application');

      if (!_transportReady) {
        await _setupTransport(
          localDtlsRole: _forcedLocalDtlsRole ?? DtlsRole.client,
          localSdpObject: localSdpObject,
        );
      }

      // 'sendDataChannel() | calling pc.setLocalDescription() [offer:${offer.toMap()}');

      await _pc!.setLocalDescription(offer);

      _remoteSdp.sendSctpAssociation(offerMediaObject!);

      RTCSessionDescription answer =
          RTCSessionDescription(_remoteSdp.getSdp(), 'answer');

      // // 'sendDataChannel() | calling pc.setRemoteDescription() [answer:${answer.toMap()}]');

      await _pc!.setRemoteDescription(answer);

      _hasDataChannelMediaSection = true;
    }

    SctpStreamParameters sctpStreamParameters = SctpStreamParameters(
      streamId: initOptions.id,
      ordered: initOptions.ordered,
      maxPacketLifeTime: initOptions.maxRetransmitTime,
      maxRetransmits: initOptions.maxRetransmits,
    );

    return HandlerSendDataChannelResult(
      dataChannel: dataChannel,
      sctpStreamParameters: sctpStreamParameters,
    );
  }

  @override
  Future<void> setMaxSpatialLayer(SetMaxSpatialLayerOptions options) async {
    _assertSendRirection();

    RTCRtpTransceiver? transceiver = _mapMidTransceiver[options.localId];

    if (transceiver == null) {
      throw ('associated RTCRtpTransceiver not found');
    }

    RTCRtpParameters parameters = transceiver.sender.parameters;

    int idx = 0;
    for (var encoding in parameters.encodings!) {
      if (idx <= options.spatialLayer) {
        encoding.active = true;
      } else {
        encoding.active = false;
      }
      idx++;
    }

    await transceiver.sender.setParameters(parameters);
  }

  @override
  Future<void> setRtpEncodingParameters(
      SetRtpEncodingParametersOptions options) async {
    _assertSendRirection();

    // 'setRtpEncodingParameters() [localId:${options.localId}, params:${options.params}]');

    RTCRtpTransceiver? transceiver = _mapMidTransceiver[options.localId];

    if (transceiver == null) {
      throw ('associated RTCRtpTransceiver not found');
    }

    RTCRtpParameters parameters = transceiver.sender.parameters;

    int idx = 0;
    for (var encoding in parameters.encodings!) {
      parameters.encodings![idx] = RTCRtpEncoding(
        active: options.params.active,
        maxBitrate: options.params.maxBitrate ?? encoding.maxBitrate,
        maxFramerate: options.params.maxFramerate ?? encoding.maxFramerate,
        minBitrate: options.params.minBitrate ?? encoding.minBitrate,
        numTemporalLayers:
            options.params.numTemporalLayers ?? encoding.numTemporalLayers,
        rid: options.params.rid ?? encoding.rid,
        scaleResolutionDownBy: options.params.scaleResolutionDownBy ??
            encoding.scaleResolutionDownBy,
        ssrc: options.params.ssrc ?? encoding.ssrc,
      );
      idx++;
    }

    await transceiver.sender.setParameters(parameters);
  }

  @override
  Future<void> stopReceiving(String localId) async {
    _assertRecvDirection();

    RTCRtpTransceiver? transceiver = _mapMidTransceiver[localId];

    if (transceiver == null) {
      throw ('associated RTCRtpTransceiveer not found');
    }

    _remoteSdp.closeMediaSection(transceiver.mid);

    RTCSessionDescription offer =
        RTCSessionDescription(_remoteSdp.getSdp(), 'offer');

    // 'stopReceiving() | calling pc.setRemoteDescription() [offer:${offer.toMap()}');

    await _pc!.setRemoteDescription(offer);

    RTCSessionDescription answer = await _pc!.createAnswer({});

    // 'stopReceiving() | calling pc.setLocalDescription() [answer:${answer.toMap()}');

    await _pc!.setLocalDescription(answer);
    _mapMidTransceiver.remove(localId);
  }

  @override
  Future<void> stopSending(String localId) async {
    _assertSendRirection();

    RTCRtpTransceiver? transceiver = _mapMidTransceiver[localId];

    if (transceiver == null) {
      throw ('associated RTCRtpTransceiver not found');
    }

    // await transceiver.sender.replaceTrack(null);
    await _pc!.removeTrack(transceiver.sender);
    _remoteSdp.closeMediaSection(transceiver.mid);

    RTCSessionDescription offer = await _pc!.createOffer({});

    // 'stopSending() | calling pc.setLocalDescription() [offer:${offer.toMap()}');

    await _pc!.setLocalDescription(offer);

    RTCSessionDescription answer =
        RTCSessionDescription(_remoteSdp.getSdp(), 'answer');

    // 'stopSending() | calling pc.setRemoteDescription() [answer:${answer.toMap()}');

    await _pc!.setRemoteDescription(answer);
    _mapMidTransceiver.remove(localId);
  }

  @override
  Future<void> updateIceServers(List<RTCIceServer> iceServers) async {
    Map<String, dynamic> configuration = _pc!.getConfiguration;

    configuration['iceServers'] =
        iceServers.map((RTCIceServer ice) => ice.toMap()).toList();

    await _pc!.setConfiguration(configuration);
  }
}

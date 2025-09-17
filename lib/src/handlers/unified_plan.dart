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
      // Extract local parameters from local SDP
      sendingRtpParameters = CommonUtils.extractSendingRtpParameters(
        localSdpObject,
        mediaSectionIdx.idx,
        RTCRtpMediaTypeExtension.fromString(options.track.kind!),
        sendingRtpParameters,
      );

      // Extract remote parameters from answer SDP with fallback
      SdpObject answerSdpObject = SdpObject.fromMap(parse(_remoteSdp.getSdp()));
      try {
        sendingRemoteRtpParameters = CommonUtils.extractSendingRtpParameters(
          answerSdpObject,
          mediaSectionIdx.idx,
          RTCRtpMediaTypeExtension.fromString(options.track.kind!),
          sendingRemoteRtpParameters,
        );
      } catch (e) {
        // Use original remote parameters as fallback
      }

      // Apply codec reduction if specified
      if (options.codec != null) {
        sendingRtpParameters.codecs =
            Ortc.reduceCodecs(sendingRtpParameters.codecs, options.codec);
        sendingRemoteRtpParameters.codecs =
            Ortc.reduceCodecs(sendingRemoteRtpParameters.codecs, options.codec);
      }

      // Set MID since we regenerated the parameters
      sendingRtpParameters.mid = localId;

      // Synchronize remote parameters with local parameters
      _synchronizeRemoteParametersWithLocal(
          sendingRtpParameters, sendingRemoteRtpParameters);
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

        sendingRemoteRtpParameters = Ortc.getSendingRemoteRtpParameters(
          mediaType,
          currentExtendedCapabilities,
        );

        // Apply codec reduction if specified
        if (options.codec != null) {
          sendingRtpParameters.codecs =
              Ortc.reduceCodecs(sendingRtpParameters.codecs, options.codec);
          sendingRemoteRtpParameters.codecs = Ortc.reduceCodecs(
              sendingRemoteRtpParameters.codecs, options.codec);
        }

        // Set MID since we regenerated the parameters
        sendingRtpParameters.mid = localId;

        // CRITICAL Chrome M140+ Fix: Ensure remote parameters match local parameters
        _synchronizeRemoteParametersWithLocal(
            sendingRtpParameters, sendingRemoteRtpParameters);
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
          sendingRemoteRtpParameters, // Use properly synchronized remote params
      codecOptions: options.codecOptions,
      extmapAllowMixed: true,
    );

    RTCSessionDescription answer =
        RTCSessionDescription(_remoteSdp.getSdp(), 'answer');

    // Chrome M140+ Additional Fix: Ensure the generated answer SDP also matches Chrome's expectations
    try {
      // Get the current local description to compare with our answer
      RTCSessionDescription? currentLocalDesc =
          await _pc!.getLocalDescription();
      if (currentLocalDesc?.sdp != null) {
        answer = _ensureAnswerCompatibilityWithLocal(
            answer, currentLocalDesc!, localId, options.track.kind!);
      }
    } catch (e) {
      // Continue with original answer if synchronization fails
    }

    // CRITICAL Chrome M140+ Fix: Apply H.264 parameter and payload synchronization
    try {
      RTCSessionDescription? currentLocalDesc =
          await _pc!.getLocalDescription();
      if (currentLocalDesc?.sdp != null) {
        Map<String, String> localH264Params =
            _extractH264Parameters(currentLocalDesc!.sdp!, localId);
        Map<String, String> answerH264Params =
            _extractH264Parameters(answer.sdp!, localId);

        // Check for H.264 parameter mismatches and apply fixes
        for (String key in localH264Params.keys) {
          if (answerH264Params[key] != localH264Params[key]) {
            answer =
                _fixH264ParameterMismatch(answer, currentLocalDesc, localId);
            break;
          }
        }

        // Apply direct SDP payload synchronization as last resort
        answer = _directSdpPayloadSync(answer, currentLocalDesc, localId);
      }
    } catch (e) {
      // Direct SDP sync failed, continue
    }

    try {
      await _pc!.setRemoteDescription(answer);
    } catch (e) {
      // Fallback to capability-based recomputation if SDP extraction fails
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
      Ortc.validateRtpParameters(sendingRtpParameters);

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

  /// Chrome M140+ Fix: Synchronize remote parameters with local parameters
  /// This ensures Chrome accepts the remote description by matching payload types and extension IDs
  void _synchronizeRemoteParametersWithLocal(
      RtpParameters localParams, RtpParameters remoteParams) {
    try {
      // Synchronize codec payload types
      Map<String, int> localPayloadTypes = {};
      for (RtpCodecParameters codec in localParams.codecs) {
        localPayloadTypes[codec.mimeType.toLowerCase()] = codec.payloadType;
      }

      // Update remote codec payload types to match local
      for (RtpCodecParameters remoteCodec in remoteParams.codecs) {
        String mimeType = remoteCodec.mimeType.toLowerCase();
        if (localPayloadTypes.containsKey(mimeType)) {
          int localPayloadType = localPayloadTypes[mimeType]!;
          // 'send() | Updating remote codec ${remoteCodec.mimeType} payload: ${remoteCodec.payloadType} -> $localPayloadType');
          remoteCodec.payloadType = localPayloadType;
        }
      }

      // Synchronize RTX codec apt parameters
      for (RtpCodecParameters remoteCodec in remoteParams.codecs) {
        if (remoteCodec.mimeType.toLowerCase().endsWith('/rtx')) {
          // Find the corresponding main codec in remote params
          int? oldApt = remoteCodec.parameters['apt'];
          if (oldApt != null) {
            // Find what this apt should point to in the local params
            for (RtpCodecParameters localCodec in localParams.codecs) {
              if (!localCodec.mimeType.toLowerCase().endsWith('/rtx')) {
                // Check if there's a remote codec with the same mime type
                RtpCodecParameters? correspondingRemoteMainCodec;
                try {
                  correspondingRemoteMainCodec = remoteParams.codecs.firstWhere(
                    (c) =>
                        c.mimeType.toLowerCase() ==
                            localCodec.mimeType.toLowerCase() &&
                        !c.mimeType.toLowerCase().endsWith('/rtx'),
                  );
                } catch (e) {
                  continue;
                }

                if (correspondingRemoteMainCodec.payloadType == oldApt) {
                  // Update the RTX apt to point to the local codec's payload type
                  remoteCodec.parameters['apt'] = localCodec.payloadType;
                  break;
                }
              }
            }
          }
        }
      }

      // Synchronize header extension IDs
      Map<String, int> localExtensionIds = {};
      for (RtpHeaderExtensionParameters ext in localParams.headerExtensions) {
        if (ext.uri != null && ext.id != null) {
          localExtensionIds[ext.uri!] = ext.id!;
        }
      }

      // Update remote extension IDs to match local
      for (RtpHeaderExtensionParameters remoteExt
          in remoteParams.headerExtensions) {
        if (remoteExt.uri != null &&
            localExtensionIds.containsKey(remoteExt.uri!)) {
          int localId = localExtensionIds[remoteExt.uri!]!;
          if (remoteExt.id != localId) {
            // 'send() | Updating remote extension ${remoteExt.uri} ID: ${remoteExt.id} -> $localId');
            // Create new extension with updated ID since id might be final
            int index = remoteParams.headerExtensions.indexOf(remoteExt);
            remoteParams.headerExtensions[index] = RtpHeaderExtensionParameters(
              uri: remoteExt.uri,
              id: localId,
              encrypt: remoteExt.encrypt,
              parameters: remoteExt.parameters,
            );
          }
        }
      }

      // 'send() | Remote parameter synchronization completed successfully');
    } catch (e) {}
  }

  /// Chrome M140+ Fix: Ensure answer SDP is compatible with local offer SDP
  /// This addresses cases where parameter synchronization alone isn't enough
  RTCSessionDescription _ensureAnswerCompatibilityWithLocal(
      RTCSessionDescription answer,
      RTCSessionDescription localOffer,
      String mid,
      String trackKind) {
    try {
      // 'send() | Checking answer SDP compatibility for mid: $mid, kind: $trackKind');

      SdpObject answerSdp = SdpObject.fromMap(parse(answer.sdp!));
      SdpObject localSdp = SdpObject.fromMap(parse(localOffer.sdp!));

      // Find the media sections for this MID
      MediaObject? answerMedia;
      MediaObject? localMedia;

      for (MediaObject media in answerSdp.media) {
        if (media.mid != null && media.mid.toString() == mid) {
          answerMedia = media;
          break;
        }
      }

      for (MediaObject media in localSdp.media) {
        if (media.mid != null && media.mid.toString() == mid) {
          localMedia = media;
          break;
        }
      }

      if (answerMedia != null && localMedia != null) {
        bool modified = false;

        // Ensure codec payload types in answer match what's in the local offer
        if (localMedia.rtp != null && answerMedia.rtp != null) {
          Map<String, int> localPayloadTypes = {};
          for (Rtp rtp in localMedia.rtp!) {
            String codecKey = rtp.codec.toLowerCase();
            localPayloadTypes[codecKey] = rtp.payload;
          }

          for (int i = 0; i < answerMedia.rtp!.length; i++) {
            Rtp answerRtp = answerMedia.rtp![i];
            String codecKey = answerRtp.codec.toLowerCase();
            if (localPayloadTypes.containsKey(codecKey)) {
              int expectedPayload = localPayloadTypes[codecKey]!;
              if (answerRtp.payload != expectedPayload) {
                // 'send() | Correcting answer payload type for $codecKey: ${answerRtp.payload} -> $expectedPayload');

                // Create new Rtp object with corrected payload type
                answerMedia.rtp![i] = Rtp(
                  payload: expectedPayload,
                  codec: answerRtp.codec,
                  rate: answerRtp.rate,
                  encoding: answerRtp.encoding,
                );
                modified = true;
              }
            }
          }
        }

        // Ensure extension IDs in answer match local offer
        if (localMedia.ext != null && answerMedia.ext != null) {
          Map<String, int> localExtIds = {};
          for (Ext ext in localMedia.ext!) {
            if (ext.uri != null && ext.value != null) {
              localExtIds[ext.uri!] = ext.value!;
            }
          }

          for (int i = 0; i < answerMedia.ext!.length; i++) {
            Ext answerExt = answerMedia.ext![i];
            if (answerExt.uri != null &&
                localExtIds.containsKey(answerExt.uri!)) {
              int expectedId = localExtIds[answerExt.uri!]!;
              if (answerExt.value != expectedId) {
                // 'send() | Correcting answer extension ID for ${answerExt.uri}: ${answerExt.value} -> $expectedId');

                // Create new Ext object with corrected ID
                answerMedia.ext![i] = Ext(
                  value: expectedId,
                  uri: answerExt.uri,
                );
                modified = true;
              }
            }
          }
        }

        if (modified) {
          // 'send() | Answer SDP was modified for Chrome M140+ compatibility');
          String correctedSdp = write(answerSdp.toMap(), null);
          return RTCSessionDescription(correctedSdp, 'answer');
        }
      }

      // 'send() | Answer SDP is already compatible, no changes needed');
      return answer;
    } catch (e) {
      return answer; // Return original if correction fails
    }
  }

  /// Chrome M140+ Last Resort Fix: Direct SDP text manipulation for payload synchronization
  /// This is the most aggressive approach to ensure payload types match exactly
  RTCSessionDescription _directSdpPayloadSync(RTCSessionDescription answer,
      RTCSessionDescription localOffer, String targetMid) {
    try {
      // 'send() | Direct SDP payload sync - examining local offer and answer for mid: $targetMid');

      String localSdp = localOffer.sdp!;
      String answerSdp = answer.sdp!;

      // Parse both SDPs to extract payload mappings for the target MID
      Map<String, int> localPayloadTypes =
          _extractPayloadTypesFromSdp(localSdp, targetMid);
      Map<String, int> answerPayloadTypes =
          _extractPayloadTypesFromSdp(answerSdp, targetMid);

      // 'send() | Local offer payload types for mid $targetMid: $localPayloadTypes');
      // 'send() | Answer payload types for mid $targetMid: $answerPayloadTypes');

      // Check if there are any mismatches
      bool needsSync = false;
      Map<int, int> payloadMapping = {}; // old -> new

      for (String codec in localPayloadTypes.keys) {
        int localPt = localPayloadTypes[codec]!;
        int? answerPt = answerPayloadTypes[codec];

        if (answerPt != null && answerPt != localPt) {
          needsSync = true;
          payloadMapping[answerPt] = localPt;
          // 'send() | Payload mismatch for $codec: answer=$answerPt, local=$localPt');
        }
      }

      if (needsSync) {
        // 'send() | Applying direct SDP payload synchronization with mapping: $payloadMapping');

        String syncedSdp =
            _applySdpPayloadMapping(answerSdp, targetMid, payloadMapping);

        // 'send() | Direct SDP sync completed - payload types synchronized');

        return RTCSessionDescription(syncedSdp, 'answer');
      } else {
        // 'send() | No payload type mismatches found, answer SDP is already correct');
        return answer;
      }
    } catch (e) {
      return answer;
    }
  }

  /// Extract payload type mappings from SDP for a specific MID
  Map<String, int> _extractPayloadTypesFromSdp(String sdp, String targetMid) {
    Map<String, int> payloadTypes = {};

    try {
      List<String> lines = sdp.split('\n');
      bool inTargetMedia = false;

      for (String line in lines) {
        line = line.trim();

        // Check if we're entering a media section
        if (line.startsWith('m=')) {
          inTargetMedia = false; // Reset for new media section
        }

        // Check if this media section has our target MID
        if (line.startsWith('a=mid:$targetMid')) {
          inTargetMedia = true;
          continue;
        }

        // If we're in the target media section, extract payload types
        if (inTargetMedia && line.startsWith('a=rtpmap:')) {
          // Format: a=rtpmap:96 VP8/90000
          RegExp rtpmapRegex = RegExp(r'a=rtpmap:(\d+)\s+([^/\s]+)');
          Match? match = rtpmapRegex.firstMatch(line);

          if (match != null) {
            int payloadType = int.parse(match.group(1)!);
            String codecName = match.group(2)!.toLowerCase();
            payloadTypes[codecName] = payloadType;
          }
        }
      }
    } catch (e) {}

    return payloadTypes;
  }

  /// Apply payload type mapping to SDP text for a specific MID
  String _applySdpPayloadMapping(
      String sdp, String targetMid, Map<int, int> payloadMapping) {
    try {
      List<String> lines = sdp.split('\n');
      List<String> modifiedLines = [];
      bool inTargetMedia = false;

      for (String line in lines) {
        String trimmedLine = line.trim();

        // Check if we're entering a media section
        if (trimmedLine.startsWith('m=')) {
          inTargetMedia = false; // Reset for new media section
        }

        // Check if this media section has our target MID
        if (trimmedLine.startsWith('a=mid:$targetMid')) {
          inTargetMedia = true;
          modifiedLines.add(line);
          continue;
        }

        // If we're in the target media section, apply payload mapping
        if (inTargetMedia) {
          String modifiedLine = line;

          // Update payload types in various SDP attributes
          for (int oldPt in payloadMapping.keys) {
            int newPt = payloadMapping[oldPt]!;

            // Update rtpmap lines: a=rtpmap:96 VP8/90000
            modifiedLine = modifiedLine.replaceAll(
                RegExp(r'a=rtpmap:' + oldPt.toString() + r'\s+'),
                'a=rtpmap:$newPt ');

            // Update fmtp lines: a=fmtp:96 max-fs=12288
            modifiedLine = modifiedLine.replaceAll(
                RegExp(r'a=fmtp:' + oldPt.toString() + r'\s+'),
                'a=fmtp:$newPt ');

            // Update rtcp-fb lines: a=rtcp-fb:96 nack
            modifiedLine = modifiedLine.replaceAll(
                RegExp(r'a=rtcp-fb:' + oldPt.toString() + r'\s+'),
                'a=rtcp-fb:$newPt ');

            // Update m= line payload types
            if (modifiedLine.startsWith('m=')) {
              // For m= lines, we need to be more careful to only replace payload numbers
              // Format: m=video 9 UDP/TLS/RTP/SAVPF 96 97 98 99 100 101 102 122 127
              List<String> parts = modifiedLine.split(' ');
              for (int i = 3; i < parts.length; i++) {
                // Skip protocol info
                try {
                  int payloadType = int.parse(parts[i]);
                  if (payloadMapping.containsKey(payloadType)) {
                    parts[i] = payloadMapping[payloadType].toString();
                    // // 'send() | Updated m= line payload: $payloadType -> ${payloadMapping[payloadType]}');
                  }
                } catch (e) {
                  // Skip non-numeric parts
                  continue;
                }
              }
              modifiedLine = parts.join(' ');
            }

            // Also update any apt parameters in fmtp lines for RTX codecs
            if (modifiedLine.contains('a=fmtp:') &&
                modifiedLine.contains('apt=')) {
              RegExp aptRegex = RegExp(r'apt=(\d+)');
              modifiedLine = modifiedLine.replaceAllMapped(aptRegex, (match) {
                int aptValue = int.parse(match.group(1)!);
                if (payloadMapping.containsKey(aptValue)) {
                  // return 'apt=${payloadMapping[aptValue]}';
                }
                return match.group(0)!;
              });
            }
          }

          modifiedLines.add(modifiedLine);
        } else {
          modifiedLines.add(line);
        }
      }

      return modifiedLines.join('\n');
    } catch (e) {
      return sdp; // Return original if mapping fails
    }
  }

  /// Extract H.264 specific parameters for comparison
  Map<String, String> _extractH264Parameters(String sdp, String targetMid) {
    Map<String, String> params = {};

    try {
      List<String> lines = sdp.split('\n');

      // First, find the media section with our target MID
      int mediaStartIndex = -1;
      int mediaEndIndex = lines.length;

      for (int i = 0; i < lines.length; i++) {
        String trimmedLine = lines[i].trim();

        // Look for the media section that contains our target MID
        if (trimmedLine.startsWith('m=')) {
          // Check if this media section contains our target MID
          bool foundTargetMid = false;
          for (int j = i + 1; j < lines.length; j++) {
            String nextLine = lines[j].trim();
            if (nextLine.startsWith('m=')) {
              // Hit next media section without finding our MID
              break;
            }
            if (nextLine == 'a=mid:$targetMid') {
              foundTargetMid = true;
              mediaStartIndex = i;
              // Find the end of this media section
              for (int k = j + 1; k < lines.length; k++) {
                if (lines[k].trim().startsWith('m=')) {
                  mediaEndIndex = k;
                  break;
                }
              }
              break;
            }
          }
          if (foundTargetMid) break;
        }
      }

      if (mediaStartIndex == -1) {
        return params;
      }

      // Now extract H.264 parameters from this media section
      String? h264PayloadType;

      for (int i = mediaStartIndex; i < mediaEndIndex; i++) {
        String trimmedLine = lines[i].trim();

        // Find H.264 payload type: a=rtpmap:119 H264/90000
        if (trimmedLine.contains('H264/90000')) {
          RegExp rtpmapRegex = RegExp(r'a=rtpmap:(\d+)\s+H264');
          Match? match = rtpmapRegex.firstMatch(trimmedLine);
          if (match != null) {
            h264PayloadType = match.group(1);
            params['payload_type'] = h264PayloadType!;
          }
        }

        // Find H.264 fmtp parameters: a=fmtp:119 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f
        if (h264PayloadType != null &&
            trimmedLine.startsWith('a=fmtp:$h264PayloadType ')) {
          String fmtpParams =
              trimmedLine.substring('a=fmtp:$h264PayloadType '.length);
          List<String> paramPairs = fmtpParams.split(';');

          for (String pair in paramPairs) {
            List<String> keyValue = pair.split('=');
            if (keyValue.length == 2) {
              String key = keyValue[0].trim();
              String value = keyValue[1].trim();
              params[key] = value;
            }
          }
        }
      }
    } catch (e) {
      params['error'] = e.toString();
    }

    return params;
  }

  /// Fix H.264 parameter mismatches between local offer and answer
  RTCSessionDescription _fixH264ParameterMismatch(RTCSessionDescription answer,
      RTCSessionDescription localOffer, String targetMid) {
    try {
      String answerSdp = answer.sdp!;
      String localSdp = localOffer.sdp!;

      // Extract H.264 parameters from local offer
      Map<String, String> localH264Params =
          _extractH264Parameters(localSdp, targetMid);
      String? localPayloadType = localH264Params['payload_type'];
      String? localProfileLevelId = localH264Params['profile-level-id'];

      if (localPayloadType == null || localProfileLevelId == null) {
        return answer;
      }

      // Fix the answer SDP
      List<String> lines = answerSdp.split('\n');
      List<String> fixedLines = [];
      bool inTargetMedia = false;

      for (String line in lines) {
        String trimmedLine = line.trim();
        String fixedLine = line;

        // Check if we're entering a new media section
        if (trimmedLine.startsWith('m=')) {
          inTargetMedia = false;
        }

        // Check if this media section has our target MID
        if (trimmedLine.startsWith('a=mid:$targetMid')) {
          inTargetMedia = true;
        }

        if (inTargetMedia) {
          // Fix H.264 fmtp line to match local profile-level-id
          if (trimmedLine.startsWith('a=fmtp:$localPayloadType ')) {
            // Extract existing fmtp parameters
            String fmtpParams =
                trimmedLine.substring('a=fmtp:$localPayloadType '.length);
            Map<String, String> params = {};

            List<String> paramPairs = fmtpParams.split(';');
            for (String pair in paramPairs) {
              List<String> keyValue = pair.split('=');
              if (keyValue.length == 2) {
                params[keyValue[0].trim()] = keyValue[1].trim();
              }
            }

            // Update critical H.264 parameters from local offer
            params['profile-level-id'] = localProfileLevelId;
            params['level-asymmetry-allowed'] =
                localH264Params['level-asymmetry-allowed'] ?? '1';
            params['packetization-mode'] =
                localH264Params['packetization-mode'] ?? '1';

            // Rebuild fmtp line
            List<String> paramStrings = [];
            for (String key in params.keys) {
              paramStrings.add('$key=${params[key]}');
            }

            fixedLine = 'a=fmtp:$localPayloadType ${paramStrings.join(';')}';
          }

          // Fix RTX apt parameter to point to correct H.264 payload type
          else if (trimmedLine.contains('apt=') &&
              trimmedLine.startsWith('a=fmtp:')) {
            // Extract the RTX payload type from this fmtp line
            // Handle both formats: "a=fmtp:124 apt=109" and "a=fmtp:124apt=109"
            RegExp fmtpRegex = RegExp(r'a=fmtp:(\d+)\s*apt=(\d+)');
            Match? match = fmtpRegex.firstMatch(trimmedLine);
            if (match != null) {
              String currentApt = match.group(2)!;

              // Check if we need to fix the apt parameter
              if (currentApt != localPayloadType) {
                fixedLine = trimmedLine.replaceAll(
                    'apt=$currentApt', 'apt=$localPayloadType');
              }
            }
          }
        }

        fixedLines.add(fixedLine);
      }

      String fixedSdp = fixedLines.join('\n');
      return RTCSessionDescription(fixedSdp, 'answer');
    } catch (e) {
      return answer;
    }
  }
}

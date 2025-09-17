// ignore_for_file: unused_local_variable, cast_from_null_always_fails
import 'package:sdp_transform/sdp_transform.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:mediasfu_mediasoup_client/src/rtp_parameters.dart';
import 'package:mediasfu_mediasoup_client/src/sdp_object.dart';
import 'package:mediasfu_mediasoup_client/src/handlers/sdp/media_section.dart';
import 'package:mediasfu_mediasoup_client/src/transport.dart';

class CommonUtils {
  static RtpCapabilities extractRtpCapabilities(SdpObject sdpObject) {
    // Map of RtpCodecParameters indexed by payload type.
    Map<int, RtpCodecCapability> codecsMap = <int, RtpCodecCapability>{};
    // Map of RtpHeaderExtensions indexed by URI to avoid duplicates.
    Map<String, RtpHeaderExtension> headerExtensionsMap =
        <String, RtpHeaderExtension>{};
    // Whether a m=audio/video section has been already found.
    bool gotAudio = false;
    bool gotVideo = false;
    for (MediaObject m in sdpObject.media) {
      String kind = m.type!;
      switch (kind) {
        case 'audio':
          {
            if (gotAudio) {
              continue;
            }
            gotAudio = true;
            break;
          }
        case 'video':
          {
            if (gotVideo) {
              continue;
            }
            gotVideo = true;
            break;
          }
        default:
          {
            continue;
          }
      }
      // Get codecs.
      for (Rtp rtp in m.rtp!) {
        RtpCodecCapability codec = RtpCodecCapability(
          kind: RTCRtpMediaTypeExtension.fromString(kind),
          mimeType: '$kind/${rtp.codec}',
          preferredPayloadType: rtp.payload,
          clockRate: rtp.rate,
          channels: rtp.encoding,
          parameters: {},
          rtcpFeedback: [],
        );
        codecsMap[codec.preferredPayloadType!] = codec;
      }
      // Get codec parameters.
      for (Fmtp fmtp in m.fmtp ?? []) {
        final Map<dynamic, dynamic> parameters = parseParams(fmtp.config);
        final RtpCodecCapability? codec = codecsMap[fmtp.payload];
        if (codec == null) {
          continue;
        }
        // Specials case to convert parameter value to string.
        if (parameters['profile-level-id'] != null) {
          parameters['profile-level-id'] = '${parameters['profile-level-id']}';
        }
        codec.parameters = parameters;
      }
      // Get RTCP feedback for each codec.
      for (RtcpFb fb in m.rtcpFb ?? []) {
        RtpCodecCapability? codec = codecsMap[fb.payload];
        if (codec == null) {
          continue;
        }
        RtcpFeedback feedback = RtcpFeedback(
          type: fb.type,
          parameter: fb.subtype,
        );
        // if (feedback.parameter == null || feedback.parameter.isEmpty) {
        //   feedback.parameter = null;
        // }
        codec.rtcpFeedback.add(feedback);
      }
      // Get RTP header extensions.
      for (Ext ext in m.ext ?? []) {
        // Ignore encrypted extensions (not yet supported in mediasoup).
        if (ext.encryptUri != null && ext.encryptUri!.isNotEmpty) {
          continue;
        }
        // Use URI as key to avoid duplicates across different media sections
        String? uri = ext.uri;
        if (uri != null && !headerExtensionsMap.containsKey(uri)) {
          RtpHeaderExtension headerExtension = RtpHeaderExtension(
            kind: RTCRtpMediaTypeExtension.fromString(kind),
            uri: uri,
            // Chrome M140+: Use the actual extension ID from SDP to allow Chrome
            // to assign it dynamically during negotiation
            preferredId: ext.value,
          );
          headerExtensionsMap[uri] = headerExtension;
        }
      }
    }
    RtpCapabilities rtpCapabilities = RtpCapabilities(
      codecs: List<RtpCodecCapability>.of(codecsMap.values),
      headerExtensions: List<RtpHeaderExtension>.of(headerExtensionsMap.values),
    );
    return rtpCapabilities;
  }

  /// Extract sending RTP parameters from the actual SDP offer for a specific media section.
  /// This is used to get the dynamic payload types and extension IDs that Chrome M140+ assigns.
  static RtpParameters extractSendingRtpParameters(
    SdpObject sdpObject,
    int mediaSectionIdx,
    RTCRtpMediaType kind,
    RtpParameters templateParameters,
  ) {
    if (mediaSectionIdx >= sdpObject.media.length) {
      throw Exception(
          'Invalid media section index: $mediaSectionIdx >= ${sdpObject.media.length}');
    }
    MediaObject mediaObject = sdpObject.media[mediaSectionIdx];
    // Verify we have the right media type
    if (mediaObject.type != RTCRtpMediaTypeExtension.value(kind)) {
      throw Exception(
          'Media type mismatch: expected ${RTCRtpMediaTypeExtension.value(kind)}, got ${mediaObject.type}');
    }
    // Clone the template parameters to preserve structure
    RtpParameters rtpParameters = RtpParameters.copy(templateParameters);
    // Update payload types from actual SDP - this is crucial for Chrome M140+
    Map<String, RtpCodecParameters> codecsByMimeType = {};
    for (RtpCodecParameters codec in rtpParameters.codecs) {
      codecsByMimeType[codec.mimeType.toLowerCase()] = codec;
    }
    // Extract actual payload types assigned by Chrome
    for (Rtp rtp in mediaObject.rtp ?? []) {
      String mimeType = '${mediaObject.type}/${rtp.codec}';
      RtpCodecParameters? codec = codecsByMimeType[mimeType.toLowerCase()];
      if (codec != null) {
        // Update with Chrome's dynamically assigned payload type
        codec.payloadType = rtp.payload;
      }
    }
    // Handle RTX codecs - update their payload types and apt parameters

    // First, build a mapping of old payload types to new payload types from the SDP
    Map<int, int> payloadTypeMapping = {};
    for (Rtp rtp in mediaObject.rtp ?? []) {
      String mimeType = '${mediaObject.type}/${rtp.codec}';
      RtpCodecParameters? templateCodec =
          codecsByMimeType[mimeType.toLowerCase()];
      if (templateCodec != null && templateCodec.payloadType != rtp.payload) {
        payloadTypeMapping[templateCodec.payloadType] = rtp.payload;
      }
    }

    // Now process RTX codecs
    for (RtpCodecParameters codec in rtpParameters.codecs) {
      if (codec.mimeType.toLowerCase().endsWith('/rtx')) {
        int? currentApt = codec.parameters['apt'];

        if (currentApt != null) {
          // Check if we have a mapping for this apt value
          int? newApt = payloadTypeMapping[currentApt];
          if (newApt != null) {
            codec.parameters['apt'] = newApt;
          } else {
            // Try to find the main codec directly in the current parameters
            RtpCodecParameters? mainCodec;
            try {
              mainCodec = rtpParameters.codecs.firstWhere(
                (c) =>
                    !c.mimeType.toLowerCase().endsWith('/rtx') &&
                    c.payloadType == currentApt,
              );
            } catch (e) {
              mainCodec = null;
            }
          }

          // Find the correct RTX payload type from the SDP
          for (Rtp rtp in mediaObject.rtp ?? []) {
            if (rtp.codec.toLowerCase() == 'rtx') {
              Fmtp? rtxFmtp;
              try {
                rtxFmtp = (mediaObject.fmtp ?? []).firstWhere(
                  (f) => f.payload == rtp.payload,
                );
              } catch (e) {
                rtxFmtp = null;
              }

              if (rtxFmtp != null) {
                Map<dynamic, dynamic> params = parseParams(rtxFmtp.config);
                int? fmtpApt = params['apt'];
                int? codecApt = codec.parameters['apt'];

                if (fmtpApt == codecApt) {
                  codec.payloadType = rtp.payload;
                  break;
                }
              }
            }
          }
        }
      }
    }
    // Map of header extensions by URI to match with actual IDs
    Map<String, RtpHeaderExtensionParameters> extensionsByUri = {};
    for (RtpHeaderExtensionParameters ext in rtpParameters.headerExtensions) {
      if (ext.uri != null) {
        extensionsByUri[ext.uri!] = ext;
      }
    }
    // CRITICAL: Clear existing extensions and rebuild from SDP to avoid ID conflicts
    // Chrome M140+ may assign different IDs than what we cached
    rtpParameters.headerExtensions.clear();
    // Rebuild extension list with Chrome's actual assigned IDs
    for (Ext ext in mediaObject.ext ?? []) {
      if (ext.uri != null && ext.value != null) {
        RtpHeaderExtensionParameters? templateExtension =
            extensionsByUri[ext.uri!];
        if (templateExtension != null) {
          // Create new extension with Chrome's assigned ID
          RtpHeaderExtensionParameters actualExtension =
              RtpHeaderExtensionParameters(
            uri: templateExtension.uri,
            id: ext.value!, // Use Chrome's actual assigned ID
            encrypt: templateExtension.encrypt,
            parameters: templateExtension.parameters,
          );
          rtpParameters.headerExtensions.add(actualExtension);
        }
      }
    }
    return rtpParameters;
  }

  static DtlsParameters extractDtlsParameters(SdpObject sdpObject) {
    MediaObject? mediaObject = sdpObject.media.firstWhere(
      (m) =>
          m.iceUfrag != null &&
          m.iceUfrag!.isNotEmpty &&
          m.port != null &&
          m.port != 0,
      orElse: () => null as MediaObject,
    );
    Fingerprint fingerprint =
        (mediaObject.fingerprint ?? sdpObject.fingerprint)!;
    DtlsRole role = DtlsRole.auto;
    switch (mediaObject.setup) {
      case 'active':
        role = DtlsRole.client;
        break;
      case 'passive':
        role = DtlsRole.server;
        break;
      case 'actpass':
        role = DtlsRole.auto;
        break;
    }
    DtlsParameters dtlsParameters = DtlsParameters(
      role: role,
      fingerprints: [
        DtlsFingerprint(
          algorithm: fingerprint.type,
          value: fingerprint.hash,
        ),
      ],
    );
    return dtlsParameters;
  }

  static String getCname(MediaObject offerMediaObject) {
    Ssrc ssrcCnameLine = (offerMediaObject.ssrcs ?? []).firstWhere(
      (Ssrc ssrc) => ssrc.attribute == 'cname',
      orElse: () => Ssrc(value: ''),
    );
    return ssrcCnameLine.value;
  }

  /// Apply codec parameters in the given SDP m= section answer based on the
  /// given RTP parameters of an offer.
  static void applyCodecParameters(
    RtpParameters offerRtpParameters,
    MediaObject? answerMediaObject,
  ) {
    for (RtpCodecParameters codec in offerRtpParameters.codecs) {
      String mimeType = codec.mimeType.toLowerCase();
      // Handle supported audio codecs: Opus, PCMU, and PCMA
      if (mimeType != 'audio/opus' &&
          mimeType != 'audio/pcmu' &&
          mimeType != 'audio/pcma') {
        continue;
      }
      Rtp? rtp = (answerMediaObject?.rtp ?? []).firstWhere(
        (Rtp r) => r.payload == codec.payloadType,
        orElse: () => null as Rtp,
      );
      // Just in case.. ?
      answerMediaObject!.fmtp = answerMediaObject.fmtp ?? [];
      Fmtp? fmtp;
      try {
        fmtp = (answerMediaObject.fmtp ?? []).firstWhere(
          (Fmtp f) => f.payload == codec.payloadType,
        );
      } catch (e) {
        fmtp = null;
      }
      Map<dynamic, dynamic> parameters = fmtp != null ? parseParams(fmtp.config) : <dynamic, dynamic>{};
      switch (mimeType) {
        case 'audio/opus':
          {
            final int? spropStereo = codec.parameters['sprop-stereo'];
            if (spropStereo != null) {
              parameters['stereo'] = spropStereo > 0 ? 1 : 0;
            }
            break;
          }
        case 'audio/pcmu':
          {
            // PCMU (G.711 μ-law) parameters - typically no special fmtp parameters needed
            // but we preserve any that might be present
            break;
          }
        case 'audio/pcma':
          {
            // PCMA (G.711 A-law) parameters - typically no special fmtp parameters needed
            // but we preserve any that might be present
            break;
          }
        default:
          break;
      }
      
      // Write the codec fmtp.config back.
      if (parameters.isNotEmpty) {
        // If we have parameters to write back, ensure we have an fmtp entry
        if (fmtp == null) {
          // Create a new fmtp entry for this codec
          fmtp = Fmtp(payload: codec.payloadType, config: '');
          answerMediaObject.fmtp!.add(fmtp);
        }
        
        fmtp.config = '';
        for (String key in parameters.keys) {
          if (fmtp.config.isNotEmpty) {
            fmtp.config += ';';
          }
          fmtp.config += '$key=${parameters[key]}';
        }
      }
    }
  }
}

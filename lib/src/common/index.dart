// ignore_for_file: constant_identifier_names

import 'package:flutter_webrtc/flutter_webrtc.dart';

enum Priority {
  VeryLow,
  Low,
  Medium,
  High,
}

extension PriorityExtension on Priority {
  static const Map<String, Priority> types = {
    'very-low': Priority.VeryLow,
    'low': Priority.Low,
    'medium': Priority.Medium,
    'high': Priority.High,
  };

  static const Map<Priority, String> values = {
    Priority.VeryLow: 'very-low',
    Priority.Low: 'low',
    Priority.Medium: 'medium',
    Priority.High: 'high',
  };

  static Priority fromString(String i) => types[i]!;
  String get value => values[this]!;
}

extension RTCPriorityTypeExtension on RTCPriorityType {
  static const Map<String, RTCPriorityType> types = {
    'very-low': RTCPriorityType.veryLow,
    'low': RTCPriorityType.low,
    'medium': RTCPriorityType.medium,
    'high': RTCPriorityType.high,
  };

  static const Map<RTCPriorityType, String> values = {
    RTCPriorityType.veryLow: 'very-low',
    RTCPriorityType.low: 'low',
    RTCPriorityType.medium: 'medium',
    RTCPriorityType.high: 'high',
  };

  static RTCPriorityType fromString(String i) =>
      types[i] ?? RTCPriorityType.low;
  String get priorityValue => values[this]!;
}

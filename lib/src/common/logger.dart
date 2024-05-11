// ignore_for_file: constant_identifier_names

import 'package:flutter/foundation.dart';

const String APP_NAME = 'mediasoup-client';

typedef LoggerDebug = void Function(dynamic message);

class Logger {
  final String? _prefix;

  late LoggerDebug debug;
  late LoggerDebug warn;
  late LoggerDebug error;

  Logger(this._prefix) {
    if (_prefix != null) {
      debug = (dynamic message) {
        // print('$APP_NAME:$_prefix $message');
      };
      warn = (dynamic message) {
        // print('$APP_NAME:WARN:$_prefix $message');
      };
      error = (dynamic message) {
        if (kDebugMode) {
          print('$APP_NAME:ERROR:$_prefix $message');
        }
      };
    } else {
      debug = (dynamic message) {
        // print('$APP_NAME $message');
      };
      warn = (dynamic message) {
        // print('$APP_NAME:WARN $message');
      };
      error = (dynamic message) {
        if (kDebugMode) {
          print('$APP_NAME:ERROR $message');
        }
      };
    }
  }
}

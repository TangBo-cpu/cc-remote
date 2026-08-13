import 'package:flutter/services.dart';

enum CameraPermissionState { granted, denied, permanentlyDenied, restricted }

abstract interface class CameraPermissionService {
  Future<CameraPermissionState> status();

  Future<CameraPermissionState> request();

  Future<bool> shouldRequestOnLaunch();

  Future<bool> openSettings();
}

class SystemCameraPermissionService implements CameraPermissionService {
  const SystemCameraPermissionService();

  static const _channel = MethodChannel('cc_remote/camera_permission');

  @override
  Future<CameraPermissionState> status() async {
    return _stateFromWire(await _channel.invokeMethod<String>('status'));
  }

  @override
  Future<CameraPermissionState> request() async {
    return _stateFromWire(await _channel.invokeMethod<String>('request'));
  }

  @override
  Future<bool> shouldRequestOnLaunch() async {
    return await _channel.invokeMethod<bool>('shouldRequestOnLaunch') ?? true;
  }

  @override
  Future<bool> openSettings() async {
    return await _channel.invokeMethod<bool>('openSettings') ?? false;
  }
}

CameraPermissionState _stateFromWire(String? value) {
  return switch (value) {
    'granted' => CameraPermissionState.granted,
    'permanentlyDenied' => CameraPermissionState.permanentlyDenied,
    'restricted' => CameraPermissionState.restricted,
    _ => CameraPermissionState.denied,
  };
}

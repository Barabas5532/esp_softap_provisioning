import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'proto/dart/constants.pbenum.dart';
import 'proto/dart/wifi_config.pb.dart';
import 'proto/dart/wifi_scan.pb.dart';
import 'proto/dart/session.pb.dart';
import 'security.dart';

import 'package:esp_softap_provisioning/src/connection_models.dart';

import 'transport.dart';

/// Espressif WiFi provisioning
///
/// https://docs.espressif.com/projects/esp-idf/en/v4.4.1/esp32/api-reference/provisioning/wifi_provisioning.html
class Provisioning {
  Transport transport;
  Security security;

  Provisioning({required this.transport, required this.security});

  /// Connect to device and estabilish the secure protocomm session
  ///
  /// Return true on success, false on failure
  Future<bool> establishSession() async {
    try {
      SessionData? responseData;
      await transport.connect();
      while (true) {
        var request = await security.securitySession(responseData);
        if (request == null) {
          return true;
        }
        var response = await transport.sendReceive(
            'prov-session', request.writeToBuffer());
        if (response.isEmpty) {
          throw Exception('Empty response');
        }
        responseData = SessionData.fromBuffer(response);
      }
    } catch (e, stacktrace) {
      print('EstablishSession error $e $stacktrace');
      return false;
    }
  }

  Future<void> dispose() async {
    return transport.disconnect();
  }

  /// Scan for WiFi access points
  ///
  /// Returns list of access points or null on failure
  ///
  /// TODO give example of the output map to show what keys are used
  Future<List<Map<String, dynamic>>?> startScanWiFi() async {
    return await _scan();
  }

  Future<WiFiScanPayload> _startScanResponse(Uint8List data) async {
    var respPayload = WiFiScanPayload.fromBuffer((await security.decrypt(data))!);
    if (respPayload.msg != WiFiScanMsgType.TypeRespScanStart) {
      throw Exception('Invalid expected message type $respPayload');
    }
    return respPayload;
  }

  Future<WiFiScanPayload> _startScanRequest(
      {bool blocking = true,
      bool passive = false,
      int groupChannels = 5,
      int periodMs = 0}) async {
    WiFiScanPayload payload = WiFiScanPayload();
    payload.msg = WiFiScanMsgType.TypeCmdScanStart;

    CmdScanStart scanStart = CmdScanStart();
    scanStart.blocking = blocking;
    scanStart.passive = passive;
    scanStart.groupChannels = groupChannels;
    scanStart.periodMs = periodMs;
    payload.cmdScanStart = scanStart;
    var reqData = (await security.encrypt(payload.writeToBuffer()))!;
    var respData = await transport.sendReceive('prov-scan', reqData);
    return _startScanResponse(respData);
  }

  Future<WiFiScanPayload> _scanStatusResponse(Uint8List data) async {
    var respPayload = WiFiScanPayload.fromBuffer((await security.decrypt(data))!);
    if (respPayload.msg != WiFiScanMsgType.TypeRespScanStatus) {
      throw Exception('Invalid expected message type $respPayload');
    }
    return respPayload;
  }

  Future<WiFiScanPayload> _scanStatusRequest() async {
    print('scanStatusRequest started');
    WiFiScanPayload payload = WiFiScanPayload();
    payload.msg = WiFiScanMsgType.TypeCmdScanStatus;
    print('before encrypt');
    var reqData = (await security.encrypt(payload.writeToBuffer()))!;
    print('after encrypt');
    print('before sendreceive');

    var respData = await transport.sendReceive('prov-scan', reqData);
    print('after sendreceive');
    print('before scanStatusResponse');

    return _scanStatusResponse(respData);
  }

  Future<List<Map<String, dynamic>>> _scanResultRequest(
      {int startIndex = 0, int count = 0}) async {
    WiFiScanPayload payload = WiFiScanPayload();
    payload.msg = WiFiScanMsgType.TypeCmdScanResult;

    CmdScanResult cmdScanResult = new CmdScanResult();
    cmdScanResult.startIndex = startIndex;
    cmdScanResult.count = count;

    payload.cmdScanResult = cmdScanResult;
    print('++++ aaaa ++++');
    var reqData = (await security.encrypt(payload.writeToBuffer()))!;
    print('++++ xxxx ++++');
    var respData = await transport.sendReceive('prov-scan', reqData);
    print('++++ yyyyy ++++');
    return _scanResultResponse(respData);
  }

  Future<List<Map<String, dynamic>>> _scanResultResponse(Uint8List data) async {
    var respPayload = WiFiScanPayload.fromBuffer((await security.decrypt(data))!);
    if (respPayload.msg != WiFiScanMsgType.TypeRespScanResult) {
      throw Exception('Invalid expected message type $respPayload');
    }
    List<Map<String, dynamic>> ret = [];
    for (var entry in respPayload.respScanResult.entries) {
      ret.add({
        'ssid': utf8.decode(entry.ssid),
        'channel': entry.channel,
        'rssi': entry.rssi,
        'bssid': entry.bssid,
        'auth': entry.auth.toString(),
      });
    }
    return ret;
  }

  Future<List<Map<String, dynamic>>?> _scan(

      {bool blocking = true,
      bool passive = false,
      int groupChannels = 5,
      int periodMs = 0}) async {
    try {
      print('Scan Started');
      await _startScanRequest(
          blocking: blocking,
          passive: passive,
          groupChannels: groupChannels,
          periodMs: periodMs);
      var status = await _scanStatusRequest();
      var resultCount = status.respScanStatus.resultCount;
      List<Map<String, dynamic>> ret = [];
      if (resultCount > 0) {
        var index = 0;
        var remaining = resultCount;
        while (remaining > 0) {
          var count = remaining > 4 ? 4 : remaining;
          var data = await _scanResultRequest(startIndex: index, count: count);
          ret.addAll(data);
          remaining -= count;
          index += count;
        }
      }
      return ret;
    } catch (e, stacktrace) {
      print('Error scan wifi $e $stacktrace');
    }
    return null;
  }

  /// Configure WiFi credentials on device
  ///
  /// Return true on success, false on failure
  Future<bool> sendWifiConfig({String? ssid, String? password}) async {
    var payload = WiFiConfigPayload();
    payload.msg = WiFiConfigMsgType.TypeCmdSetConfig;

    var cmdSetConfig = CmdSetConfig();
    cmdSetConfig.ssid = utf8.encode(ssid ?? '');
    cmdSetConfig.passphrase = utf8.encode(password ?? '');
    payload.cmdSetConfig = cmdSetConfig;
    var reqData = (await security.encrypt(payload.writeToBuffer()))!;
    var respData = await transport.sendReceive('prov-config', reqData);
    var respRaw = (await security.decrypt(respData))!;
    var respPayload = WiFiConfigPayload.fromBuffer(respRaw);
    return (respPayload.respSetConfig.status == Status.Success);
  }

  /// Try to use credentials passed to [sendWifiConfig] to connect to an access
  /// point
  ///
  /// Return true on success, false on failure
  Future<bool> applyWifiConfig() async {
    var payload = WiFiConfigPayload();
    payload.msg = WiFiConfigMsgType.TypeCmdApplyConfig;
    var reqData = (await security.encrypt(payload.writeToBuffer()))!;
    var respData = await transport.sendReceive('prov-config', reqData);
    var respRaw = (await security.decrypt(respData))!;
    var respPayload = WiFiConfigPayload.fromBuffer(respRaw);
    return (respPayload.respApplyConfig.status == Status.Success);
  }

  /// Get the status of connection after testing configured credentials with [applyWifiConfig]
  Future<ConnectionStatus?> getStatus() async {
    var payload = WiFiConfigPayload();
    payload.msg = WiFiConfigMsgType.TypeCmdGetStatus;

    var cmdGetStatus = CmdGetStatus();
    payload.cmdGetStatus = cmdGetStatus;

    var reqData = (await security.encrypt(payload.writeToBuffer()))!;
    var respData = await transport.sendReceive('prov-config', reqData);
    var respRaw = (await security.decrypt(respData))!;
    var respPayload = WiFiConfigPayload.fromBuffer(respRaw);

    if (respPayload.respGetStatus.staState.value == 0) {
      return ConnectionStatus(
          state: WifiConnectionState.Connected,
          ip: respPayload.respGetStatus.connected.ip4Addr);
    } else if (respPayload.respGetStatus.staState.value == 1) {
      return ConnectionStatus(state: WifiConnectionState.Connecting);
    } else if (respPayload.respGetStatus.staState.value == 2) {
      return ConnectionStatus(state: WifiConnectionState.Disconnected);
    } else if (respPayload.respGetStatus.staState.value == 3) {
      if (respPayload.respGetStatus.failReason.value == 0) {
        return ConnectionStatus(
          state: WifiConnectionState.ConnectionFailed,
          failedReason: WifiConnectFailedReason.AuthError,
        );
      } else if (respPayload.respGetStatus.failReason.value == 1) {
        return ConnectionStatus(
          state: WifiConnectionState.ConnectionFailed,
          failedReason: WifiConnectFailedReason.NetworkNotFound,
        );
      }
      return ConnectionStatus(state: WifiConnectionState.ConnectionFailed);
    }

    return null;
  }

  /// Send data to the `custom-data` endpoint configured in the esp-idf WiFi
  /// provisioning example
  Future<Uint8List> sendReceiveCustomData(Uint8List data, {int packageSize = 256}) async {
    var i = data.length;
    var offset = 0;
    List<int> ret = [];
    while (i > 0) {
      var needToSend = data.sublist(offset, i < packageSize ? i : packageSize);
      var encrypted = (await security.encrypt(needToSend))!;
      var newData = await transport.sendReceive('custom-data', encrypted);

      if (newData.length > 0) {
        var decrypted = (await security.decrypt(newData))!;
        ret += List.from(decrypted);
      }
      i -= packageSize;
    }
    return Uint8List.fromList(ret);
  }
}

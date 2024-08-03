import 'dart:async';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

class Cryptor {
  late Uint8List _iv;
  late Uint8List _key;

  int byte_counter = 0;

  final algorithm = AesCtr.with256bits(
    macAlgorithm: MacAlgorithm.empty,
  );

  Future<bool> init(Uint8List key, Uint8List iv) async {
    _iv = iv;
    _key = key;
    byte_counter = 0;

    // TODO what should we return for success? it is ignored for now
    return true;
  }

  Future<Uint8List> crypt(Uint8List data) async {
    final secretBox = await algorithm.encrypt(
      data,
      secretKey: await algorithm.newSecretKeyFromBytes(_key),
      nonce: _iv,
      keyStreamIndex: byte_counter,
    );

    byte_counter += data.length;

    return Uint8List.fromList(secretBox.cipherText);
  }
}

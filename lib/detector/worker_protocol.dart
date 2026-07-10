import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const workerProtocolVersion = 1;
const maxWorkerHeaderBytes = 64 * 1024;
const maxWorkerImageBytes = 512 * 1024 * 1024;
const maxWorkerResponseBytes = 1024 * 1024;

class WorkerProtocolException implements Exception {
  WorkerProtocolException(this.message);

  final String message;

  @override
  String toString() => 'WorkerProtocolException: $message';
}

class WorkerMessage {
  const WorkerMessage(this.json);

  final Map<String, Object?> json;

  String get type => json['type'] as String? ?? '';
  String? get requestId => json['requestId']?.toString();
}

class WorkerByteReader {
  WorkerByteReader(Stream<List<int>> source)
    : _iterator = StreamIterator<List<int>>(source);

  final StreamIterator<List<int>> _iterator;
  List<int> _chunk = const [];
  int _offset = 0;

  Future<Uint8List> readExactly(int count) async {
    final result = Uint8List(count);
    var written = 0;

    while (written < count) {
      if (_offset == _chunk.length) {
        if (!await _iterator.moveNext()) {
          throw WorkerProtocolException(
            'truncated worker message: expected $count bytes, received $written',
          );
        }
        _chunk = _iterator.current;
        _offset = 0;
        if (_chunk.isEmpty) {
          continue;
        }
      }

      final available = _chunk.length - _offset;
      final remaining = count - written;
      final copied = available < remaining ? available : remaining;
      result.setRange(written, written + copied, _chunk, _offset);
      written += copied;
      _offset += copied;
    }

    return result;
  }
}

Future<void> writeWorkerRequest(
  IOSink sink,
  Map<String, Object?> header,
  int payloadLength,
  Stream<List<int>> payload,
) async {
  if (payloadLength < 0 || payloadLength > maxWorkerImageBytes) {
    throw WorkerProtocolException(
      'payload length $payloadLength is outside the supported range '
      'of 0 to $maxWorkerImageBytes bytes',
    );
  }

  final headerBytes = utf8.encode(jsonEncode(header));
  if (headerBytes.length > maxWorkerHeaderBytes) {
    throw WorkerProtocolException(
      'request header exceeds the $maxWorkerHeaderBytes byte limit',
    );
  }
  sink.add(_uint32Bytes(headerBytes.length));
  sink.add(headerBytes);
  sink.add(_uint64Bytes(payloadLength));
  await sink.addStream(payload);
  await sink.flush();
}

Future<WorkerMessage> readWorkerMessage(WorkerByteReader reader) async {
  final lengthBytes = await reader.readExactly(4);
  final length = ByteData.sublistView(lengthBytes).getUint32(0, Endian.big);
  if (length > maxWorkerResponseBytes) {
    throw WorkerProtocolException(
      'response exceeds the $maxWorkerResponseBytes byte limit',
    );
  }
  final jsonBytes = await reader.readExactly(length);
  late final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(jsonBytes));
  } on FormatException {
    throw WorkerProtocolException('worker response is not valid UTF-8 JSON');
  }
  if (decoded is! Map<String, Object?>) {
    throw WorkerProtocolException('worker response must be a JSON object');
  }
  final version = decoded['version'];
  if (version is! int || version != workerProtocolVersion) {
    throw WorkerProtocolException('unsupported protocol version: $version');
  }
  final type = decoded['type'];
  if (type is! String || type.isEmpty) {
    throw WorkerProtocolException('worker response type must be a string');
  }
  final requestId = decoded['requestId'];
  if (requestId != null && requestId is! String) {
    throw WorkerProtocolException('worker response requestId must be a string');
  }
  return WorkerMessage(decoded);
}

Uint8List _uint32Bytes(int value) {
  final data = ByteData(4)..setUint32(0, value, Endian.big);
  return data.buffer.asUint8List();
}

Uint8List _uint64Bytes(int value) {
  final data = ByteData(8)..setUint64(0, value, Endian.big);
  return data.buffer.asUint8List();
}

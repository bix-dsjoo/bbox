import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bbox_labeler/detector/worker_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reads a response split across arbitrary chunks', () async {
    final jsonBytes = utf8.encode('{"version":2,"type":"ready"}');
    final frame = BytesBuilder()
      ..add(uint32Bytes(jsonBytes.length))
      ..add(jsonBytes);
    final bytes = frame.takeBytes();
    final reader = WorkerByteReader(
      Stream<List<int>>.fromIterable([
        bytes.sublist(0, 2),
        bytes.sublist(2, 7),
        bytes.sublist(7),
      ]),
    );

    final message = await readWorkerMessage(reader);

    expect(message.type, 'ready');
  });

  test('writes utf8 header and streams payload unchanged', () async {
    final chunks = <List<int>>[];
    final controller = StreamController<List<int>>();
    final subscription = controller.stream.listen(chunks.add);
    final completed = subscription.asFuture<void>();
    final sink = IOSink(controller.sink);
    await writeWorkerRequest(
      sink,
      const {
        'version': 2,
        'type': 'detect',
        'requestId': '7',
        'fileName': '한글.png',
      },
      5,
      Stream<List<int>>.fromIterable(const [
        [1, 2],
        [3, 4, 5],
      ]),
    );
    await sink.close();
    await completed;

    expect(decodeRecordedPayload(chunks.expand((chunk) => chunk).toList()), [
      1,
      2,
      3,
      4,
      5,
    ]);
  });

  test('rejects response larger than one MiB', () async {
    Stream<List<int>> oversizedResponse() async* {
      yield uint32Bytes(maxWorkerResponseBytes + 1);
      throw StateError('response body must not be read');
    }

    final reader = WorkerByteReader(oversizedResponse());

    await expectLater(
      readWorkerMessage(reader),
      throwsA(isA<WorkerProtocolException>()),
    );
  });

  test('rejects unsupported protocol version', () async {
    final jsonBytes = utf8.encode('{"version":1,"type":"ready"}');
    final frame = BytesBuilder()
      ..add(uint32Bytes(jsonBytes.length))
      ..add(jsonBytes);
    final reader = WorkerByteReader(Stream<List<int>>.value(frame.takeBytes()));

    await expectLater(
      readWorkerMessage(reader),
      throwsA(
        isA<WorkerProtocolException>().having(
          (error) => error.message,
          'message',
          contains('version'),
        ),
      ),
    );
  });

  for (final malformed in <String, List<int>>{
    'invalid utf8': const [0xC3, 0x28],
    'invalid json': utf8.encode('{"version":2'),
    'non-object top level': utf8.encode('[1,2,3]'),
    'wrong-type message field': utf8.encode(
      '{"version":2,"type":{"unexpected":true}}',
    ),
  }.entries) {
    test('${malformed.key} is a worker protocol exception', () async {
      final reader = WorkerByteReader(
        Stream<List<int>>.value(
          (BytesBuilder()
                ..add(uint32Bytes(malformed.value.length))
                ..add(malformed.value))
              .takeBytes(),
        ),
      );

      await expectLater(
        readWorkerMessage(reader),
        throwsA(isA<WorkerProtocolException>()),
      );
    });
  }

  test('throws on truncated response body', () async {
    final frame = BytesBuilder()
      ..add(uint32Bytes(10))
      ..add(const [1, 2, 3]);
    final reader = WorkerByteReader(Stream<List<int>>.value(frame.takeBytes()));

    await expectLater(
      readWorkerMessage(reader),
      throwsA(
        isA<WorkerProtocolException>().having(
          (error) => error.message,
          'message',
          contains('truncated'),
        ),
      ),
    );
  });

  test('rejects payload larger than 64 MiB before writing', () async {
    expect(maxWorkerImageBytes, 64 * 1024 * 1024);
    final chunks = <List<int>>[];
    final controller = StreamController<List<int>>();
    final subscription = controller.stream.listen(chunks.add);
    final completed = subscription.asFuture<void>();
    final sink = IOSink(controller.sink);
    Object? error;

    try {
      await writeWorkerRequest(
        sink,
        const {'version': 2, 'type': 'detect', 'requestId': '7'},
        maxWorkerImageBytes + 1,
        const Stream<List<int>>.empty(),
      );
    } catch (caught) {
      error = caught;
    }
    await sink.close();
    await completed;

    expect(error, isA<WorkerProtocolException>());
    expect(chunks.expand((chunk) => chunk), isEmpty);
  });
}

Uint8List uint32Bytes(int value) {
  final data = ByteData(4)..setUint32(0, value, Endian.big);
  return data.buffer.asUint8List();
}

List<int> decodeRecordedPayload(List<int> bytes) {
  final headerLength = ByteData.sublistView(
    Uint8List.fromList(bytes),
    0,
    4,
  ).getUint32(0, Endian.big);
  final headerEnd = 4 + headerLength;
  final header = jsonDecode(utf8.decode(bytes.sublist(4, headerEnd)));
  expect(header['fileName'], '한글.png');

  final payloadLength = ByteData.sublistView(
    Uint8List.fromList(bytes),
    headerEnd,
    headerEnd + 8,
  ).getUint64(0, Endian.big);
  final payload = bytes.sublist(headerEnd + 8);
  expect(payload, hasLength(payloadLength));
  return payload;
}

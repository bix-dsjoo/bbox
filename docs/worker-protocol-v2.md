# Bread worker protocol v2

The bread worker is a persistent stdin/stdout process. Standard output is reserved
for framed protocol messages; model diagnostics go to standard error. All image
coordinates are original-image pixels.

## Framing

Every request is one byte frame in this order:

1. unsigned 32-bit big-endian JSON header length;
2. that many bytes of UTF-8 JSON header;
3. unsigned 64-bit big-endian payload length;
4. that many opaque image bytes.

The maximum header is 65,536 bytes and the maximum image payload is 512 MiB. An
EOF inside a declared field is fatal. A response is an unsigned 32-bit big-endian
length followed by one UTF-8 JSON object, with a maximum encoded size of 1 MiB.
Response JSON is compact, has lexicographically sorted object keys, and is encoded
with `allow_nan=false`; NaN and infinities are never valid wire values.

When both declared lengths are within their limits, the worker reads the complete
frame before parsing or validating its header. A malformed or semantically invalid
header therefore does not leave the stream positioned inside that frame. A header
or payload whose declared length exceeds its limit is fatal immediately because
the frame cannot be trusted or buffered safely.

## Ready message

After the manifest is validated and its selected models are constructed, the worker
emits exactly this shape:

```json
{
  "version": 2,
  "type": "ready",
  "detectorName": "bread-yolo-boxes",
  "capabilities": {
    "detect": true,
    "classify": true,
    "autoLabel": true,
    "verifier": false
  }
}
```

`capabilities.verifier` is `false` when the validated manifest selects verifier
kind `none`; otherwise it is `true`.

## Requests

Every header requires `version`, `type`, and `requestId`. `version` must be the JSON
integer `2` (not a Boolean, string, or floating-point value). `type` must be exactly
`detect`, `classify`, or `shutdown`. `requestId` must be a non-empty string and is
copied unchanged into the response.

### Detect

```json
{
  "version": 2,
  "type": "detect",
  "requestId": "auto-box-1",
  "fileName": "tray.png",
  "maxProposals": 50
}
```

The payload is the encoded source image. `fileName` is diagnostic metadata.
`maxProposals` is optional; when present it limits the detector result for this
request without reloading the models.

### Classify

```json
{
  "version": 2,
  "type": "classify",
  "requestId": "classify-1",
  "boxes": [
    {"id": "manual-1", "x": 10, "y": 20, "width": 100, "height": 80}
  ]
}
```

The payload is the encoded source image. `boxes` is required and contains at most
100 boxes. Each box ID is a non-empty string. Coordinates describe the
supplied box in original-image pixels. Finite overrun is clamped to the decoded
image and marked for review; non-finite or non-positive boxes are discarded. The
detector is not invoked for a classify request.

### Shutdown

```json
{"version":2,"type":"shutdown","requestId":"stop"}
```

The payload is normally empty. The worker exits successfully without running an
inference stage and does not emit a result for shutdown.

## Result

Both detect and classify return the same exact top-level contract:

```json
{
  "version": 2,
  "type": "result",
  "requestId": "auto-box-1",
  "pipelineVersion": "bread-pipeline-v1",
  "policyVersion": "bread-label-policy-v2",
  "detectorName": "bread-yolo-boxes",
  "modelHashes": {
    "detector": "e84163ef40dfa829bf37444980eebda2571645a1f1a048d9e35abbcbf6cdd0b1",
    "classifier": "ec95587bca5c4a2873a12faf180a78bdf59ced648dafca37bba5086d5697fa02",
    "verifier": null
  },
  "image": {
    "width": 1920,
    "height": 1080,
    "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  },
  "boxes": [
    {
      "id": "b1",
      "x": 10.0,
      "y": 20.0,
      "width": 100.0,
      "height": 80.0,
      "confidence": 0.98,
      "label": {
        "state": "review",
        "labelId": null,
        "suggestedLabelId": 3,
        "candidates": [{"labelId": 3, "score": 0.72}],
        "reviewReasons": ["classifier_ambiguous"],
        "embeddingUsed": false
      }
    }
  ],
  "stageErrors": []
}
```

The image SHA-256 is calculated from the exact request payload. Pipeline version,
policy version, and model hashes come from the already validated manifest; they are
not recalculated per request. With verifier kind `none`, `modelHashes.verifier` is
`null`. Box confidence is `null` when no valid detector confidence is available.

Label state is `accepted`, `review`, or `unavailable`. An accepted label has a
non-null `labelId`. A review label has a non-null `suggestedLabelId` when a
classifier suggestion exists and contains the stable ordered `reviewReasons`.
An unavailable label keeps the box, uses null label IDs, and may add a short
`message`. `candidates` contains objects with `labelId` and `score`.

`stageErrors` contains recoverable stage failures as
`{"stage":"classifier","message":"..."}`. A classifier failure preserves boxes
with unavailable labels. A verifier failure leaves only the affected ambiguous
boxes in review.

## Errors and restart behavior

Image decode failures and inference exceptions are request-level errors. They are
framed as `{version: 2, type: "error", requestId, code, message}` with code
`decode_failed` or `inference_failed`, and the worker continues with the next frame.

Malformed JSON, non-object headers, version mismatch, an unknown request type,
invalid request or box IDs and more than 100 supplied
boxes are protocol errors. They raise a fatal protocol exception after the current
bounded frame has been consumed. The client applies its existing one-restart policy
and must resend work only after receiving a new ready message. Truncated fields and
oversized declared lengths are also fatal. No partial result is emitted for a fatal
protocol error.

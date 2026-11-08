# Changelog

## 0.2.0

- Multipart uploads ([Files](https://videxo.io/docs/files#multipart-uploads)): `uploads.upload` and
  `uploads.create(forFile:)` make one for a file past 100 MB, or any with `multipart: true` and an
  optional `partSizeBytes`. `VidexoUpload().send(file:upload:)` and `start(file:upload:)` send its
  parts from the file's ranges, three at a time, each again after a lost connection, a timeout, a
  `429` or a `502` to `504`; they read the parts received first, so sending again resumes; cancelling
  aborts the upload.
- `BackgroundUploader.start(file:upload:tag:)` sends a multipart upload as one background task per
  part, completes it in a background task too, and picks it up after a relaunch. New constructor
  options `partsAtOnce` and `maxRetries`.
- `Upload` is `Codable`, with `multipart`, `init(json:)` and `json()`. New `MultipartPlan`,
  `MultipartUploadStatus`, `UploadPart` and `singleUploadMaxBytes`.
- Breaking: `CompletedUpload.sha256` is optional, nil for a multipart upload.

## 0.1.0

The first release: `VidexoClient` for client tokens (uploads, jobs, the token, and refresh through
`getToken`), `VidexoUpload` for sending a file to a one-time upload URL with progress, pause and
resume, `BackgroundUploader` for background sessions, retries with `Retry-After` and idempotency
keys, and `VidexoError` for every failure.

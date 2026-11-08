# Videxo for Swift

The iOS and macOS client of the [Videxo](https://videxo.io) API: hosted FFmpeg jobs over HTTP. An
app uploads a file straight to Videxo, in the foreground or in a background session, and follows the
job your backend created. iOS 16 and macOS 13 or newer, no dependencies.

The app never holds an API key. It uses a [client token](https://videxo.io/docs/client-tokens) your
backend mints, or a one-time upload URL your backend made. Jobs are always created by your backend.

```swift
// Package.swift
.package(url: "https://github.com/videxo-io/videxo-swift", from: "0.2.0")
// and in your target's dependencies:
.product(name: "Videxo", package: "videxo-swift")
```

## Upload with a client token

```swift
import Videxo

let videxo = try VidexoClient(token: minted.token, tokenId: minted.id)
let completed = try await videxo.uploads.upload(file: fileURL) { progress in
    print(progress.fraction)
}
// Send completed.inputURL to your backend, which creates the job with its API key.
```

## Upload with a URL from your backend

```swift
let completed = try await VidexoUpload().send(file: fileURL, to: uploadURL, contentType: "video/mp4")
```

The upload URL takes one PUT within one hour, so nothing retries it. After a failed PUT, create a
new upload.

## Multipart uploads

A file past 100 MB, or any with `multipart: true`, goes as a multipart upload: in parts copied from
the file's ranges, three at a time, each sent again after a lost connection, then completed. Sending
it again reads the parts received and sends only the others, also after a relaunch. Cancelling
aborts it.

```swift
let upload = try await videxo.uploads.create(forFile: fileURL, multipart: true)
let completed = try await VidexoUpload().send(file: fileURL, upload: upload)
// From your backend: let upload = try Upload(json: answerFromYourBackend)
```

Keep the `Upload` (it is `Codable`) to resume: its URLs work for 6 hours and need no API key.

## Upload in the background

```swift
let uploader = BackgroundUploader(identifier: "com.example.app.uploads") { event in
    if case let .finished(upload, result) = event { save(upload, result) }
}
let upload = try await videxo.uploads.create(forFile: fileInYourContainer)
try await uploader.start(file: fileInYourContainer, upload: upload, tag: upload.inputURL)
```

Make the uploader once, early in the app's launch, and pass the system's completion handler from
`application(_:handleEventsForBackgroundURLSession:completionHandler:)` to `handleEvents`. A file
from a picker is outside your container: copy it first, and keep it until `finished`. A multipart
upload is one task per part; its part files and its state stay in Application Support until
`finished`.

Background upload has not yet been tested on a device: so far it has only run on macOS while the
process stays alive, not after an app is suspended or relaunched. A multipart upload's background
tasks have run in tests on a plain session, and its pick-up after a relaunch with a second uploader
in the same process.

## Follow a job

```swift
let follower = try VidexoClient(token: following.token, tokenId: following.id) { request in
    // Ask your backend for a continuation of request.tokenId ("continues").
    try await myBackend.refresh(tokenId: request.tokenId)
}
let job = try await follower.jobs.wait(jobId)
for output in job.outputs { print(output.filename, output.downloadURL as Any) }
```

## Errors

Every failure is a `VidexoError`: `status`, `code`, `reason`, `title`, `detail`, `type`, `retryable`,
`requestId`, `retryAfter`, `errors` and `body`. Programs branch on `code` and `reason`; `detail` is
for people. The SDK's own codes, with `status` nil, are `network_error`, `timeout`, `aborted`,
`wait_timeout`, `http_error`, `invalid_response` and `invalid_argument`. See the
[Errors](https://videxo.io/docs/errors) page.

The guide is at [videxo.io/docs/sdk/swift](https://videxo.io/docs/sdk/swift).

## License

MIT, see [LICENSE](LICENSE).

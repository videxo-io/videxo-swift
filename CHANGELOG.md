# Changelog

## 0.1.0

The first release: `VidexoClient` for client tokens (uploads, jobs, the token, and refresh through
`getToken`), `VidexoUpload` for sending a file to a one-time upload URL with progress, pause and
resume, `BackgroundUploader` for background sessions, retries with `Retry-After` and idempotency
keys, and `VidexoError` for every failure.

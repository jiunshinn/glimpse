# Glimpse peer protocol

The contract between Glimpse on the Mac (`Sources/Glimpse/Peer/`) and Glimpse for Android (`android/`).
The design notes are in [docs/android-companion/protocol.md](../docs/android-companion/protocol.md).

| File | Purpose |
| --- | --- |
| `openapi.yaml` | Every endpoint of version 1 and its JSON shapes. `x-status: planned` marks an endpoint that no app serves yet. |
| `fixtures/` | Sample messages. The Android unit tests decode them (`ProtocolFixturesTest`). |

## Rules

- Change `openapi.yaml`, the fixtures and both apps in the same pull request.
- A new optional field does not change the version. A client ignores fields it does not know.
- A removed or changed field needs a new version (`/v2/`).

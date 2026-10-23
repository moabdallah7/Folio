# Activate Folio iCloud sync

Folio includes optional CloudKit sync, but the default build runs locally without iCloud. Enabling CloudKit requires an eligible Apple Developer Program team and provisioning. Live CloudKit round trips remain unverified; the test suite uses a fake transport.

## Build with your eligible Apple team

1. Enroll your Apple account in the Apple Developer Program, or add an existing eligible team in **Xcode → Settings → Apple Accounts**. Enrollment and any payment must be completed by the account holder.
2. Open `Folio.xcodeproj` and select the shared **Folio iCloud** scheme and **My Mac** destination.
3. Select the **Folio** target, then **Signing & Capabilities**. For the **Cloud Debug** and **Cloud Release** configurations, select your eligible team and keep automatic signing enabled. No signing team is committed; select your own team.
4. Enable the **iCloud → CloudKit** capability for those cloud configurations. Register/select **iCloud.com.folio.writing**. If that identifier is unavailable, choose a unique identifier and set the `FOLIO_CLOUD_CONTAINER` build setting to the same identifier. The Info.plist and entitlements both read that setting. Keep the existing app bundle identifier if possible so the current local library remains in its existing container. If changing it is necessary, export a Folio library backup first, then import it into the newly signed app.
5. Run with Command-R. Xcode must successfully create an iCloud-enabled provisioning profile. On the Mac, sign into the intended iCloud account in System Settings.
6. In **Folio → Settings → iCloud**, turn on **Sync this library**, then choose **Sync Now**. Wait for **Up to date in iCloud**. Errors stay visible and local saves remain available.
7. Build/run the same app and cloud container on another Mac with the same iCloud account, and enable sync there. Development CloudKit data is separate from production data.

## What syncs

Sheets, plain text, rich text formatting, Markdown mode, notebooks (including empty ones), favorites, writing goals, and Trash. Versions, recovery backups, editor appearance, selection, and window layout remain local to each Mac.

Folio checks for changes on launch, when becoming active, and every 30 seconds while open. Manual **Sync Now** bypasses the polling wait. Failed operations retry while open with backoff and respect CloudKit's retry delay. Closing the app before an upload completes is safe: pending changes are computed from the durable local library on the next launch. The app does not promise background sync while quit.

Conflicting edits preserve a separately named **Conflict copy**. Editing a sheet on one Mac while another permanently deletes it preserves the edited manuscript as a new sheet. Permanent removals retain small tombstone records in CloudKit to prevent an offline Mac from bringing deleted documents back.

Switching iCloud accounts pauses synchronization. Sign back into the library's original account to resume. Turning sync off keeps both local writing and existing iCloud data; it does not erase either. Do not manually delete records or the record zone in CloudKit Console: Folio will pause if it detects external removal, rather than silently recreate or discard data. Account migration and cloud resets are not automated in this release.

## Required live verification after provisioning

The automated suite uses a simulated CloudKit transport. These real-service checks are still required because the current Personal Team cannot provision CloudKit:

- On Mac A create a sheet, apply bold/italic, set a goal, favorite it, and put it in a new notebook. Sync and verify the same values on Mac B.
- Disconnect Mac B, edit on both Macs, reconnect, and verify both manuscripts remain with a conflict copy.
- On one Mac trash/restore a sheet, then permanently remove a disposable sheet. Verify changes on the other Mac and after restart.
- Quit with changes waiting; relaunch and verify they upload.
- Check signing into no iCloud account and switching accounts: local writing stays available, uploads stop.

## Distribution

The cloud configurations currently target CloudKit's **Development** environment. Before distributing, deploy the `FolioItem` record type (`payload`: Asset) from development to production in CloudKit Console, use production entitlements/provisioning for the distribution build, and perform the live verification again in that environment. Do not switch existing users between development and production libraries without a migration plan. App Store submission or Developer ID signing/notarization is separate from the local developer build.

## Implementation

`CloudSync.swift` contains a CloudKit private-database transport and a testable merge engine. Each document or notebook is a separate record in the `FolioLibrary` custom zone. Record changes are fetched using zone change tokens; all pages are decoded before a merge and cursor are committed atomically with the local library. Writes use `ifServerRecordUnchanged`, retaining CloudKit system fields. Large rich-text payloads use CKAsset files. An upload acknowledges only the exact sent version, so typing while a request is in flight stays queued.

The normal **Folio** scheme builds without iCloud entitlements and cannot instantiate a CloudKit container. The **Folio iCloud** scheme enables the compile-time `FOLIO_CLOUD` condition and cloud entitlements. Both build from the same sources; neither embeds server secrets.

Apple references: [Configuring iCloud services](https://developer.apple.com/documentation/xcode/configuring-icloud-services), [macOS supported capabilities](https://developer.apple.com/help/account/reference/supported-capabilities-macos), [CloudKit record save policy](https://developer.apple.com/documentation/cloudkit/ckmodifyrecordsoperation/savepolicy).

<p align="center">
  <img src="Resources/AppIcon-source.png" width="128" alt="OpenNTFS icon">
</p>

<h1 align="center">OpenNTFS</h1>
<p align="center">An NTFS file manager for Macs with Apple silicon</p>
<p align="center">macOS 13+ | Apple silicon | English and Russian</p>

Read and write NTFS files from a standalone app. OpenNTFS supports file and folder copying, renaming, folder creation, Quick Look, progress reporting and cancellation. No system driver or persistent service installation is required.

## Download and install

1. Open this repository's **Releases** section.
2. Download `OpenNTFS-<version>-arm64.dmg` from **Assets**.
3. Open the DMG and drag OpenNTFS to **Applications**.
4. Select a drive and click **Open Volume**. Approve the system access prompt if it appears.

Builds use a local ad-hoc signature without Apple Developer ID signing or Apple notarization. macOS may require you to allow the first launch in **System Settings > Privacy & Security**.

To verify your download, place the DMG and its matching `.sha256` file in the same folder and run:

```sh
shasum -a 256 -c OpenNTFS-0.3.0-arm64.dmg.sha256
```

## Using a drive

- Copy files with the app's controls or drag them from Finder.
- Use **Show in Finder** to return the volume to macOS. NTFS writing remains available inside OpenNTFS, not Finder.
- Before disconnecting a drive, click **Eject** and wait for the operation to finish.
- Formatting is available in the volume menu and erases the selected partition's data.

This is an experimental build. Keep a backup of valuable data. Internal and APFS partitions are protected from writes. Writing is blocked when the volume has its dirty bit set, has unsupported NTFS flags or contains a Windows hibernation file. Existing files are not overwritten. Links, reparse points and EFS file export are not supported.

To uninstall, quit the app and delete `OpenNTFS.app`. Language and interface preferences are stored using standard macOS preferences.

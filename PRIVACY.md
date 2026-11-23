# Star Privacy Policy

*Last updated: November 2026*

Star ("the app") is a tool that removes airplane and satellite trails from nighttime timelapse image sequences. This policy explains what data the app accesses, how it is processed, and your rights under applicable privacy laws including the EU General Data Protection Regulation (GDPR).

## Summary

- **No telemetry or third-party tracking** — No analytics, crash reporters, advertising, or external SDKs.
- **Your data stays local** — Your images and results are read from and written to your own device. Star never uploads them.
- **No accounts** — Star has no sign-in and the developer collects no data about you.
- **Fully transparent** — All processing happens on your device.

## Personal Data We Process

Star processes the following data, entirely on your device:

### Image Files & Metadata
- The image sequences you open (which may contain identifiable individuals or places)
- Technical metadata read from the images: dimensions, bit depth, color space, capture timestamps, exposure settings, camera and lens model
- **Sensitive metadata**: GPS coordinates and location data, if embedded in your images

### User-Created Data
- App preferences and settings
- Processing configuration, outlier group decisions and per-frame results stored alongside your sequence
- Output images and videos you ask Star to create

## Network Access

Star does not upload your images, metadata, or any other personal data. The only network request the app makes is an anonymous check of GitHub's public releases page (`api.github.com`) to see whether a newer version of Star is available. This request carries no information about you, your images, or your settings, and is subject to GitHub's own privacy practices.

## How We Use Data

- **Processing**: Reading your images to detect and remove airplane and satellite trails and to build output sequences.
- **Persistence**: Saving your preferences and processing results locally so work can be resumed.

## Data Retention

- **Preferences and processing results**: Stored on your device until you delete them.
- **Output images and videos**: Written where you choose and kept until you delete them.
- **Temporary files**: Intermediate files created while processing are cleaned up automatically.

The developer retains no data of yours.

## Legal Basis (GDPR)

Because all data is processed on your device and the developer receives none of it, the developer is not a controller or processor of your personal data. To the extent processing occurs, it is based on your own action of opening and processing your files.

## Your Rights

Under GDPR and similar privacy laws you have rights of access, deletion, portability, and withdrawal of consent. Since the developer holds none of your data, you exercise these directly:

- **Access / portability**: All data is in ordinary files on your device (images, JSON configuration and results).
- **Deletion**: Delete the files, or the app and its preferences, from your device.

For any question or request, contact us as described below.

## Security

Your data is protected by your device's own file system and OS-level access controls. Star does not transmit it anywhere, so there is no server-side storage to secure.

## Third Parties

Star does not share your data with third parties. Open-source libraries used for image processing run locally and do not receive your data outside your device. The release check described above contacts GitHub.

## Children's Privacy

Star does not collect any personal information from anyone, including children.

## Policy Changes

We may update this policy as Star evolves. The latest version is always available in this repository, with the date above updated.

## Contact & Requests

For privacy questions:
- Open an issue at https://github.com/brianm998/starry_timelapse_airplane_remover/issues
- Email: brian@preffect.com

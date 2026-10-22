//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import AVFoundation
import VideoToolbox

enum PlaybackCapabilities {

    /// This property is true if an HDR display is available and the device is capable of playing HDR content from an appropriate AVAsset,
    /// false otherwise.
    static var isDeviceHDRCapable: Bool {
        AVPlayer.eligibleForHDRPlayback
    }

    /// Should Swiftfin handle Dolby Vision content (false) or should it be tone mapped by the server (true)?
    static var dvEnabled: Bool {
        !StoredValues[.User.forceDVTranscode]
    }

    /// Should Swiftfin handle HDR content (false) or should it be tone mapped by the server (true)?
    static var hdrEnabled: Bool {
        !StoredValues[.User.forceHDRTranscode]
    }

    static var gpuName: String {
        MTLCreateSystemDefaultDevice()?.name ?? L10n.unknown
    }

    // MARK: - Hardware Limits

    /// The model identifier of the device, for example `AppleTV5,3`.
    static var modelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { buffer in
            String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    /// The most demanding H.264 stream a device can decode in hardware.
    struct H264Limits {

        let width: Int
        let height: Int
        /// In the units Jellyfin uses for `VideoLevel`, so level 4.2 is 42.
        let level: Int
        let framerate: Int
    }

    /// The H.264 limits of devices that decode less than the profile allows by default.
    /// Anything above them is left to the server to transcode. Returns nil for unlisted models.
    static var h264Limits: H264Limits? {
        switch modelIdentifier {
        case "AppleTV5,3": // Apple TV HD (A8)
            return H264Limits(width: 1920, height: 1080, level: 42, framerate: 60)
        default:
            return nil
        }
    }

    // MARK: - Hardware Decode

    // MARK: MPEG / ITU-T

    /// Returns true if the device supports hardware-accelerated H.264/AVC decoding.
    static var supportsH264: Bool {
        VTIsHardwareDecodeSupported(kCMVideoCodecType_H264)
    }

    /// Returns true if the device supports hardware-accelerated H.265/HEVC decoding.
    static var supportsHEVC: Bool {
        VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
    }

    // MARK: Alliance for Open Media

    /// Returns true if the device supports hardware-accelerated AV1 decoding.
    /// Requires A17 Pro / M3 or newer.
    static var supportsAV1: Bool {
        VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
    }

    // MARK: Google

    /// Returns true if the device supports hardware-accelerated VP9 decoding.
    /// Note: VP9 hardware decode is not available on iOS/tvOS.
    static var supportsVP9: Bool {
        VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9)
    }

    // MARK: - HDR

    /// Returns true if the device can play HDR10 content.
    /// Requires HEVC hardware decode AND HDR-capable display.
    /// Note: HDR10 is a transfer function, not a codec—the underlying codec is HEVC.
    static var supportsHDR10: Bool {
        supportsHEVC && hdrEnabled
    }

    /// Returns true if the device can play HLG content.
    /// Requires HEVC hardware decode AND HDR-capable display.
    /// Note: HLG is a transfer function, not a codec—the underlying codec is HEVC.
    static var supportsHLG: Bool {
        supportsHEVC && hdrEnabled
    }

    /// Returns true if the device supports hardware-accelerated Dolby Vision HEVC decoding.
    /// This correctly distinguishes A10 (no DV) from A10X (DV support).
    static var supportsDolbyVision: Bool {
        VTIsHardwareDecodeSupported(kCMVideoCodecType_DolbyVisionHEVC) && dvEnabled
    }
}

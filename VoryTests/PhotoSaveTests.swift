#if os(iOS)
import Foundation
import Photos
import Testing
@testable import Vory

/// What the image viewer says when Save to Photos did not work (the Mac saves to Downloads).
@Suite struct PhotoSaveTests {
    @Test func photosAccessRefusedOrRestrictedSaysSoAndOffersSettings() {
        for code in [PHPhotosError.Code.accessUserDenied, .accessRestricted] {
            // Don't Allow in the prompt: the save throws Photos' own access error.
            let failure = PhotoSaveFailure(PHPhotosError(code), addOnly: .notDetermined)
            #expect(failure.accessOff)
            #expect(failure.message == PhotoSaveFailure.accessOffMessage)
            // The same error as an NSError, as it can arrive.
            #expect(PhotoSaveFailure(NSError(domain: PHPhotosErrorDomain, code: code.rawValue), addOnly: .authorized).accessOff)
        }
    }

    @Test func anyErrorWithAccessOffSaysAccessIsOff() {
        // Photos does not always answer a refusal with its access error; the access itself says.
        let other = NSError(domain: PHPhotosErrorDomain, code: -1)
        for status in [PHAuthorizationStatus.denied, .restricted] {
            #expect(PhotoSaveFailure(other, addOnly: status) == PhotoSaveFailure(message: PhotoSaveFailure.accessOffMessage, accessOff: true))
        }
    }

    @Test func anotherFailureSaysWhatWentWrongWithNoWayToSettings() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError,
                            userInfo: [NSLocalizedDescriptionKey: "The file is gone."])
        for status in [PHAuthorizationStatus.authorized, .limited, .notDetermined] {
            let failure = PhotoSaveFailure(error, addOnly: status)
            #expect(!failure.accessOff)
            #expect(failure.message == "Photos did not take the picture: The file is gone.")
        }
        // Another Photos error is not taken for the access being off.
        #expect(!PhotoSaveFailure(PHPhotosError(.invalidResource), addOnly: .authorized).accessOff)
    }
}
#endif

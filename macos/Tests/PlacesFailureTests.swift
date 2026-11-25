import Foundation
import MapKit
import Testing

@testable import Latchkey

/// Problem reports 2026-11-24/25 (a run geotagging photo after photo): maps_find answered
/// "Apple Maps found nothing" for every error MapKit gave, also when Apple Maps only limited the
/// Mac's searches for a while or failed, so Claude was told a place doesn't exist when it was
/// never searched. Only MapKit's own "not found" says nothing was found.
@Suite struct PlacesFailureTests {
    func mapKit(_ code: MKError.Code) -> NSError {
        NSError(domain: MKErrorDomain, code: Int(code.rawValue), userInfo: [NSLocalizedDescriptionKey: "x"])
    }

    @Test func onlyNotFoundIsNothingFound() {
        #expect(AppleMapsBackend.failure(mapKit(.placemarkNotFound), for: "mall") == .nothingFound("mall"))
        #expect(AppleMapsBackend.failure(mapKit(.directionsNotFound), for: "a") == .nothingFound("a"))
    }

    @Test func aLimitedSearchSaysSoAndIsNotNothingFound() async {
        #expect(AppleMapsBackend.failure(mapKit(.loadingThrottled), for: "Times Square") == .busy)
        let said = await LocationCapability.run { throw PlacesFailure.busy }.plainText
        #expect(said.contains("limiting") && said.contains("try again") && !said.contains("found nothing"), "\(said)")
    }

    @Test func otherErrorsSayWhatHappened() {
        #expect(AppleMapsBackend.failure(mapKit(.serverFailure), for: "a") == .failed("x"))
        let offline = NSError(
            domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
            userInfo: [NSLocalizedDescriptionKey: "offline"])
        #expect(AppleMapsBackend.failure(offline, for: "a") == .failed("offline"))
    }
}

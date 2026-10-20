import Foundation

enum NotificationOrigin {
    static let userInfoKey = "calyxOriginSurfaceID"

    static func userInfo(surfaceID: UUID) -> [AnyHashable: Any] {
        [userInfoKey: surfaceID.uuidString]
    }

    static func surfaceID(in userInfo: [AnyHashable: Any]) -> UUID? {
        guard let string = userInfo[userInfoKey] as? String else { return nil }
        return UUID(uuidString: string)
    }
}

import Foundation
public struct CustomEndpointUsageDay: Codable, Equatable, Sendable {
    public let day: String
    public let totalTokens: Int

    public init(day: String, totalTokens: Int) {
        self.day = day
        self.totalTokens = totalTokens
    }
}

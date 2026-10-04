import Foundation

public struct ToolParameters: Sendable {
    public var start: Double = 0
    public var end: Double = 5
    public var speed: Double = 1.5
    public var targetMegabytes: Double = 10
    public var channels: Int = 1
    public var width: Int = 1280
    public var height: Int = 720
    public var x: Int = 0
    public var y: Int = 0
    public var columns: Int = 2
    public var padding: Int = 16
    public var pages: String = "1"
    public init() {}
}

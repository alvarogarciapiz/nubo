import Foundation
import os

public enum NuboLog {
    public static let networking = Logger(subsystem: "com.lvrpiz.nubo", category: "networking")
    public static let video = Logger(subsystem: "com.lvrpiz.nubo", category: "video")
    public static let input = Logger(subsystem: "com.lvrpiz.nubo", category: "input")
    public static let lifecycle = Logger(subsystem: "com.lvrpiz.nubo", category: "lifecycle")
}

public enum NuboSignpost {
    public static let video = OSSignposter(subsystem: "com.lvrpiz.nubo", category: "video-pipeline")
    public static let input = OSSignposter(subsystem: "com.lvrpiz.nubo", category: "input-pipeline")
}

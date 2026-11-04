import Foundation

/// 视频人脸采样：短片段按最小间隔；长视频自适应放大间隔，保证不超过 maxFrames。
public enum FaceVideoSampling {
    public static func frameTimes(durationMs: Int, minIntervalMs: Int = 2_000,
                                  maxFrames: Int = 60) -> [Int] {
        guard durationMs > 0, minIntervalMs > 0, maxFrames > 0 else { return [] }
        let interval = max(minIntervalMs, Int(ceil(Double(durationMs) / Double(maxFrames))))
        var times: [Int] = []
        var time = 0
        while time < durationMs, times.count < maxFrames {
            times.append(time)
            time += interval
        }
        return times
    }
}

import AppKit
import QuartzCore

extension DS {
    public enum Motion {
        public enum Duration {
            public static let press: TimeInterval = 0.10
            public static let fast: TimeInterval = 0.15
            public static let base: TimeInterval = 0.20
            public static let slow: TimeInterval = 0.30
        }

        public enum Curve {
            public static let easeOut = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            public static let easeInOut = CAMediaTimingFunction(controlPoints: 0.77, 0, 0.175, 1)
        }

        public static let pressScale: CGFloat = 0.96
        public static let enterScale: CGFloat = 0.96

        public static var isReduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    }
}

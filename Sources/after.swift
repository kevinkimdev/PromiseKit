import struct Foundation.TimeInterval
import Dispatch

/**
 - Returns: A new promise that fulfills after the specified duration.
*/
@available(*, deprecated: 4.3, message: "Use after(seconds:)")
public func after(interval: TimeInterval) -> Promise<Void> {
    return after(seconds: interval)
}

/**
 - Returns: A new promise that fulfills after the specified duration.
*/
public func after(seconds: TimeInterval) -> Promise<Void> {
    return Promise { fulfill, _ in
        let when = DispatchTime.now() + seconds
        DispatchQueue.global().asyncAfter(deadline: when, execute: fulfill)
    }
}

/**
 - Returns: A new promise that fulfills after the specified duration.
*/
public func after(interval: DispatchTimeInterval) -> Promise<Void> {
    return Promise { fulfill, _ in
        let when = DispatchTime.now() + interval
        DispatchQueue.global().asyncAfter(deadline: when, execute: fulfill)
    }
}

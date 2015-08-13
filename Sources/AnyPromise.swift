import Foundation.NSError


private func unbox(resolution: Resolution<AnyObject?>) -> AnyObject? {
    switch resolution {
    case .Fulfilled(let value):
        return value
    case .Rejected(let error):
        return error as NSError
    }
}

public typealias AnyPromise = PMKPromise

@objc(PMKAnyPromise) public class AnyPromise: NSObject {
    private var state: State

    private typealias Resolution = PromiseKit.Resolution<AnyObject?>
    private typealias State = UnsealedState<AnyObject?>

    /**
     - Returns: A new AnyPromise bound to a Promise<T?>.
     The two promises represent the same task, any changes to either will instantly reflect on both.
    */
    public init<T: AnyObject>(bound: Promise<T>) {
        //WARNING copy pasta from below. FIXME how?
        var resolve: ((Resolution) -> Void)!
        state = State(resolver: &resolve)

        //TODO eventually we should be able to just do: bound.pipe(resolve)
        bound.pipe { resolution in
            switch resolution {
            case .Fulfilled(let value):
                resolve(.Fulfilled(value))
            case .Rejected(let error):
                unconsume(error)
                resolve(.Rejected(error))
            }
        }
    }

    public init<T: AnyObject>(bound: Promise<T?>) {
        //WARNING copy pasta from above. FIXME how?
        var resolve: ((Resolution) -> Void)!
        state = State(resolver: &resolve)
        bound.pipe { resolution in
            switch resolution {
            case .Fulfilled(let value):
                resolve(.Fulfilled(value))
            case .Rejected(let error):
                unconsume(error)
                resolve(.Rejected(error))
            }
        }
    }

    /**
     - Returns: A new `AnyPromise` bound to a `Promise<[T]>`.
     The two promises represent the same task, any changes to either will instantly reflect on both.
     The value is converted to an NSArray so Objective-C can use it.
    */
    public init<T: AnyObject>(bound: Promise<[T]>) {
        //WARNING copy pasta from above. FIXME how?
        var resolve: ((Resolution) -> Void)!
        state = State(resolver: &resolve)
        bound.pipe { resolution in
            switch resolution {
            case .Fulfilled(let value):
                resolve(.Fulfilled(value as NSArray))
            case .Rejected(let error):
                unconsume(error)
                resolve(.Rejected(error))
            }
        }
    }

    /**
     - Returns: A new AnyPromise bound to a `Promise<[T:U]>`.
     The two promises represent the same task, any changes to either will instantly reflect on both.
     The value is converted to an NSDictionary so Objective-C can use it.
    */
    public init<T: AnyObject, U: AnyObject>(bound: Promise<[T:U]>) {
        //WARNING copy pasta from above. FIXME how?
        var resolve: ((Resolution) -> Void)!
        state = State(resolver: &resolve)
        bound.pipe { resolution in
            switch resolution {
            case .Fulfilled(let value):
                resolve(.Fulfilled(value as NSDictionary))
            case .Rejected(let error):
                unconsume(error)
                resolve(.Rejected(error))
            }
        }
    }

    /**
     - Returns: A new AnyPromise bound to a `Promise<Int>`.
     The two promises represent the same task, any changes to either will instantly reflect on both.
     The value is converted to an NSNumber so Objective-C can use it.
    */
    convenience public init(bound: Promise<Int>) {
        self.init(bound: bound.then(on: zalgo) { NSNumber(integer: $0) })
    }

    /**
     - Returns: A new AnyPromise bound to a `Promise<Void>`.
     The two promises represent the same task, any changes to either will instantly reflect on both.
    */
    convenience public init(bound: Promise<Void>) {
        self.init(bound: bound.then(on: zalgo) { _ -> AnyObject? in return nil })
    }

    @objc init(@noescape bridge: ((AnyObject?) -> Void) -> Void) {
        var resolve: ((Resolution) -> Void)!
        state = State(resolver: &resolve)
        bridge { result in
            func preresolve(obj: AnyObject?) {
                if let error = obj as? NSError {
                    unconsume(error)
                    resolve(.Rejected(error))
                } else {
                    resolve(.Fulfilled(obj))
                }
            }
            if let next = result as? AnyPromise {
                next.pipe(preresolve)
            } else {
                preresolve(result)
            }
        }
    }

    @objc func pipe(anybody: (AnyObject?) -> Void) {
        state.get { seal in
            func body(resolution: Resolution) {
                anybody(unbox(resolution))
            }
            switch seal {
            case .Pending(let handlers):
                handlers.append(body)
            case .Resolved(let resolution):
                body(resolution)
            }
        }
    }

    @objc var __value: AnyObject? {
        if let resolution = state.get() {
            return unbox(resolution)
        } else {
            return nil
        }
    }

    /**
     A promise starts pending and eventually resolves.
     - Returns: `true` if the promise has not yet resolved.
    */
    @objc public var pending: Bool {
        return state.get() == nil
    }

    /**
     A promise starts pending and eventually resolves.
     - Returns: `true` if the promise has resolved.
    */
    @objc public var resolved: Bool {
        return !pending
    }

    /**
     A fulfilled promise has resolved successfully.
     - Returns: `true` if the promise was fulfilled.
    */
    @objc public var fulfilled: Bool {
        switch state.get() {
        case .Some(.Fulfilled):
            return true
        default:
            return false
        }
    }

    /**
     A rejected promise has resolved without success.
     - Returns: `true` if the promise was rejected.
    */
    @objc public var rejected: Bool {
        switch state.get() {
        case .Some(.Rejected):
            return true
        default:
            return false
        }
    }


    // because you can’t access top-level Swift functions in objc
    @objc class func setUnhandledErrorHandler(body: (NSError) -> Void) -> (NSError) -> Void {

        //FIXME these conversions are hardly ideal, if you set and reset
        // the same handler you'd be adding one to the call stack everytime!
        // Swift 2 won't handle the conversion in place for us :(

        let oldHandler = PMKUnhandledErrorHandler
        PMKUnhandledErrorHandler = { body($0 as NSError) }
        return { oldHandler($0) }
    }

    /**
     Continue a Promise<T> chain from an AnyPromise.
    */
    public func then<T>(on q: dispatch_queue_t = dispatch_get_main_queue(), body: (AnyObject?) -> T) -> Promise<T> {
        return Promise { fulfill, reject in
            pipe { object in
                if let error = object as? NSError {
                    reject(error)
                } else {
                    contain_zalgo(q) {
                        fulfill(body(self.valueForKey("value")))
                    }
                }
            }
        }
    }

    /**
     Continue a Promise<T> chain from an AnyPromise.
    */
    public func then(on q: dispatch_queue_t = dispatch_get_main_queue(), body: (AnyObject?) -> AnyPromise) -> Promise<AnyObject?> {
        return Promise { fulfill, reject in
            pipe { object in
                if let error = object as? NSError {
                    reject(error)
                } else {
                    contain_zalgo(q) {
                        body(object).pipe { object in
                            if let error = object as? NSError {
                                reject(error)
                            } else {
                                fulfill(object)
                            }
                        }
                    }
                }
            }
        }
    }

    /**
     Continue a Promise<T> chain from an AnyPromise.
    */
    public func then<T>(on q: dispatch_queue_t = dispatch_get_main_queue(), body: (AnyObject?) -> Promise<T>) -> Promise<T> {
        return Promise(passthru: { resolve in
            pipe { object in
                if let error = object as? NSError {
                    resolve(.Rejected(error))
                } else {
                    contain_zalgo(q) {
                        body(object).pipe(resolve)
                    }
                }
            }
        })
    }
}


extension AnyPromise {
    override public var description: String {
        return "AnyPromise: \(state)"
    }
}

#import "assert.h"
@import Dispatch.introspection;
@import Foundation.NSDictionary;
@import Foundation.NSException;
@import Foundation.NSKeyValueCoding;
@import Foundation.NSMethodSignature;
@import Foundation.NSPointerArray;
#import "Private/NSMethodSignatureForBlock.m"
#import "PromiseKit/Promise.h"
#import "PromiseKit/Deferred.h"

#define NSErrorWithThrown(e) [NSError errorWithDomain:PMKErrorDomain code:PMKErrorCodeThrown userInfo:@{PMKThrown: e}]
#define IsPromise(o) ([o isKindOfClass:[Promise class]])
#define IsPending(o) (((Promise *)o)->result == nil)
#define PMKE(txt) [NSException exceptionWithName:@"PromiseKit" reason:@"PromiseKit: " txt userInfo:nil]

static const id PMKNull = @"PMKNull";

static void RejectRecursively(Promise *);
static void ResolveRecursively(Promise *);

/**
 `then` and `catch` are method-signature tolerant, this function calls
 the block correctly and normalizes the return value to `id`.
 */
static id safely_call_block(id frock, id result) {
    if (!frock)
        @throw PMKE(@"Internal error");

    if (result == PMKNull)
        result = nil;

    @try {
        NSMethodSignature *sig = NSMethodSignatureForBlock(frock);
        const NSUInteger nargs = sig.numberOfArguments;
        const char rtype = sig.methodReturnType[0];

        if (nargs == 2 && rtype == 'v') {
            void (^block)(id) = frock;
            block(result);
            return PMKNull;
        }
        if (nargs == 1 && rtype == 'v') {
            void (^block)(void) = frock;
            block();
            return PMKNull;
        }
        if (nargs == 2) {
            id (^block)(id) = frock;
            return block(result) ?: PMKNull;
        }
        else {
            id (^block)(void) = frock;
            return block() ?: PMKNull;
        }
    } @catch (id e) {
        return [e isKindOfClass:[NSError class]] ? e : NSErrorWithThrown(e);
    }
}



/**
 We have public instance variables so Deferred, ResolveRecursively and
 RejectRecursively can fulfill promises. Think of it like the C++
 `friend` keyword.
 */
@implementation Promise {
@public
    NSMutableArray *pendingPromises;
    NSMutableArray *thens;
    NSMutableArray *fails;
    id result;
}

- (instancetype)init {
    thens = [NSMutableArray new];
    fails = [NSMutableArray new];
    pendingPromises = [NSMutableArray new];
    return self;
}

- (Promise *(^)(id))then {
    if ([result isKindOfClass:[Promise class]])
        return ((Promise *)result).then;

    if ([result isKindOfClass:[NSError class]])
        return ^(id block) {
            return [Promise promiseWithValue:result];
        };

    if (result) return ^id(id block) {
        id rv = safely_call_block(block, result);
        if ([rv isKindOfClass:[Promise class]])
            return rv;
        return [Promise promiseWithValue:rv];
    };

    return ^(id block) {
        Promise *next = [Promise new];
        [pendingPromises addObject:next];
        // avoiding retain cycle by passing self->result as block parameter
        [thens addObject:^(id selfDotResult){
            next->result = safely_call_block(block, selfDotResult);
            return next;
        }];
        return next;
    };
}

- (Promise *(^)(id))catch {
    if ([result isKindOfClass:[Promise class]])
        return ((Promise *)result).catch;

    if (result && ![result isKindOfClass:[NSError class]])
        return ^(id block){
            return [Promise promiseWithValue:result];
        };

    if (result) return ^id(id block){
        id rv = safely_call_block(block, result);
        return [rv isKindOfClass:[Promise class]]
             ? rv
             : [Promise promiseWithValue:rv];
    };

    return ^(id block) {
        Promise *next = [Promise new];
        [pendingPromises addObject:next];
        // avoiding retain cycle by passing self->result as block parameter
        [fails addObject:^(id selfDotResult){
            next->result = safely_call_block(block, selfDotResult);
            return next;
        }];
        return next;
    };
}

+ (Promise *)when:(NSArray *)promises {
    BOOL const wasarray = [promises isKindOfClass:[NSArray class]];
    if ([promises isKindOfClass:[Promise class]])
        promises = @[promises];
    if (![promises isKindOfClass:[NSArray class]])
        return [Promise promiseWithValue:promises];

    NSPointerArray *results = [NSPointerArray strongObjectsPointerArray];
    results.count = promises.count;
    Deferred *deferred = [Deferred new];

    __block int x = 0;
    __block BOOL failed = NO;
    void (^both)(NSUInteger, id) = ^(NSUInteger ii, id o){
        [results replacePointerAtIndex:ii withPointer:(__bridge void *)(o ?: PMKNull)];

        if (++x != promises.count)
            return;

        NSArray *objs = results.allObjects;
        id passme = wasarray ? objs : objs[0];

        if (failed) {
            [deferred reject:passme];
        } else {
            [deferred resolve:passme];
        }
    };
    [promises enumerateObjectsUsingBlock:^(Promise *promise, NSUInteger ii, BOOL *stop) {
        promise.catch(^(id o){
            failed = YES;
            both(ii, o);
        });
        promise.then(^(id o){
            both(ii, o);
        });
    }];
    
    return deferred.promise;
}

+ (Promise *)until:(id (^)(void))blockReturningPromises catch:(id)failHandler {
    Deferred *deferred = [Deferred new];

  #pragma clang diagnostic push
  #pragma clang diagnostic ignored "-Warc-retain-cycles"

    __block void (^block)() = ^{
        id promises = blockReturningPromises();
        [self when:promises].then(^(id o){
            [deferred resolve:o];
            block = nil;  // break retain cycle
        }).catch(^(id e){
            Promise *rv = safely_call_block(failHandler, e);
            if ([rv isKindOfClass:[Promise class]])
                rv.then(block);
            else if (![rv isKindOfClass:[NSError class]])
                block();
        });
    };
    block();

  #pragma clang diagnostic pop

    return deferred.promise;
}

+ (Promise *)promiseWithValue:(id)value {
    Promise *p = [Promise new];
    p->result = value;
    return p;
}

@end


/**
 Static C functions rather that methods on Promise to enforce strict
 encapsulation and immutability on Promise objects. This may seem strict,
 but it fits well with the ideals of the Promise pattern. You can be
 completely certain that third-party libraries and end-users of your
 Promise based API did not modify your Promises.
 */
static void ResolveRecursively(Promise *promise) {
    assert(promise->result);
    assert(![promise->result isKindOfClass:[NSError class]]);

    for (id (^then)(id) in promise->thens) {
        Promise *next = then(promise->result);
        [promise->pendingPromises removeObject:next];

        // next was resolved in the then block

        if ([next->result isKindOfClass:[NSError class]])
            RejectRecursively(next);
        else if (IsPromise(next->result) && IsPending(next->result)) {
            Promise *rsvp = next->result;
            [rsvp->thens addObject:^(id o){
                next->result = o;
                return next;
            }];
            [rsvp->pendingPromises addObject:next];
        }
        else if (IsPromise(next->result) && !IsPending(next->result)) {
            next->result = ((Promise *)next->result)->result;
            ResolveRecursively(next);
        } else
            ResolveRecursively(next);
    }

    // search through fails for thens
    for (Promise *pending in promise->pendingPromises) {
        pending->result = promise->result;
        ResolveRecursively(pending);
    }

    promise->thens = promise->fails = promise->pendingPromises = nil;
}

static void RejectRecursively(Promise *promise) {
    assert(promise->result);
    assert([promise->result isKindOfClass:[NSError class]]);

    for (id (^fail)(id) in promise->fails) {
        Promise *next = fail(promise->result);
        [promise->pendingPromises removeObject:next];

        // next was resolved in the catch block

        if (IsPromise(next->result) && IsPending(next->result)) {
            Promise *rsvp = next->result;
            [rsvp->thens addObject:^(id o){
                next->result = o;
                return next;
            }];
            [rsvp->pendingPromises addObject:next];
            continue;
        }
        if (IsPromise(next->result) && !IsPending(next->result))
            next->result = ((Promise *)next->result)->result;

        if (next->result == PMKNull)
            // we're done
            continue;
        if ([next->result isKindOfClass:[NSError class]])
            // bubble again!
            RejectRecursively(next);
        else
            ResolveRecursively(next);
    }

    // search through thens for fails
    for (Promise *pending in promise->pendingPromises) {
        pending->result = promise->result;
        RejectRecursively(pending);
    }

    promise->thens = promise->fails = promise->pendingPromises = nil;
}



@implementation Deferred

- (instancetype)init {
    promise = [Promise new];
    return self;
}

- (void)resolve:(id)value {
    if (promise->result)
        @throw PMKE(@"Deferred already resolved");
    if ([value isKindOfClass:[Promise class]])
        @throw PMKE(@"You may not pass a Promise to [Deferred resolve:]");
    if ([value isKindOfClass:[NSError class]])
        @throw PMKE(@"You may not pass an NSError to [Deferred resolve:]");
    if (!value)
        value = PMKNull;

    promise->result = value;
    ResolveRecursively(promise);
}

- (void)reject:(id)error {
    if (promise->result)
        @throw PMKE(@"Deferred already resolved");
    if ([error isKindOfClass:[Promise class]])
        @throw PMKE(@"You may not pass a Promise to [Deferred reject:]");
    if (!error)
        error = [NSError errorWithDomain:PMKErrorDomain code:PMKErrorCodeUnknown userInfo:nil];
    if (![error isKindOfClass:[NSError class]])
        error = NSErrorWithThrown(error);

    promise->result = error;
    RejectRecursively(promise);
}

@synthesize promise;
@end



Promise *dispatch_promise(id block) {
    return dispatch_promise_on(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), block);
}

Promise *dispatch_promise_on(dispatch_queue_t queue, id block) {
    Deferred *deferred = [Deferred new];
    dispatch_async(queue, ^{
        __block id result = safely_call_block(block, nil);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (IsPromise(result)) {
                Promise *rsvp = (Promise *)result;
                Promise *next = deferred.promise;
                if (IsPending(rsvp)) {
                    [rsvp->thens addObject:^(id o){
                        next->result = o;
                        return next;
                    }];
                    [rsvp->pendingPromises addObject:next];
                    return;
                } else
                    result = rsvp->result;
            }
            if ([result isKindOfClass:[NSError class]])
                [deferred reject:result];
            else
                [deferred resolve:result];            
        });
    });
    return deferred.promise;
}

#import "assert.h"
@import Dispatch.introspection;
@import Foundation.NSDictionary;
@import Foundation.NSError;
@import Foundation.NSException;
@import Foundation.NSKeyValueCoding;
@import Foundation.NSMethodSignature;
@import Foundation.NSPointerArray;
#import "Private/NSMethodSignatureForBlock.m"
#import "PromiseKit/Promise.h"

#define NSErrorWithThrown(e) [NSError errorWithDomain:PMKErrorDomain code:PMKErrorCodeThrown userInfo:@{PMKThrown: e}]
#define IsPromise(o) ([o isKindOfClass:[Promise class]])
#define IsPending(o) (((Promise *)o)->result == nil)
#define PMKE(txt) [NSException exceptionWithName:@"PromiseKit" reason:@"PromiseKit: " txt userInfo:nil]

static const id PMKNull = @"PMKNull";

static void RejectRecursively(Promise *);
static void FulfillRecursively(Promise *);

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

        #define call_block_with_rtype(type) @(nargs > 1 \
            ? ((type (^)(id))frock)(result) \
            : ((type (^)(void))frock)())

        switch (rtype) {
            case 'v':
                if (nargs > 1) {
                    void (^block)(id) = frock;
                    block(result);
                } else {
                    void (^block)(void) = frock;
                    block();
                }
                return PMKNull;
            case '@':
                return (nargs > 1
                    ? ((id (^)(id))frock)(result)
                    : ((id (^)(void))frock)())
                ?: PMKNull;
            case '*': {
                char *str = nargs > 1
                    ? ((char *(^)(id))frock)(result)
                    : ((char *(^)(void))frock)();
                return str ? @(str) : PMKNull;
            }
            case 'c': return call_block_with_rtype(char);
            case 'i': return call_block_with_rtype(int);
            case 's': return call_block_with_rtype(short);
            case 'l': return call_block_with_rtype(long);
            case 'q': return call_block_with_rtype(long long);
            case 'C': return call_block_with_rtype(unsigned char);
            case 'I': return call_block_with_rtype(unsigned int);
            case 'S': return call_block_with_rtype(unsigned short);
            case 'L': return call_block_with_rtype(unsigned long);
            case 'Q': return call_block_with_rtype(unsigned long long);
            case 'f': return call_block_with_rtype(float);
            case 'd': return call_block_with_rtype(double);
            case 'B': return call_block_with_rtype(_Bool);
            case '^':
                if (strcmp(sig.methodReturnType, "^v") == 0)
                    return PMKNull;
                // else fall through!
            default:
                @throw PMKE(@"Unsupported method signature… Why not fork and fix?");
        }
    } @catch (id e) {
        return [e isKindOfClass:[NSError class]] ? e : NSErrorWithThrown(e);
    }
}



/**
 We have public @implementation instance variables so ResolveRecursively
 and RejectRecursively can fulfill promises. It’s like the C++ `friend`
 keyword.
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

    return [Promise new:^(void(^fulfiller)(id), void(^rejecter)(id)){
        __block NSUInteger x = 0;
        __block BOOL failed = NO;
        void (^both)(NSUInteger, id) = ^(NSUInteger ii, id o){
            [results replacePointerAtIndex:ii withPointer:(__bridge void *)(o ?: PMKNull)];

            if (++x != promises.count)
                return;

            id passme = wasarray ? ({
                for (NSUInteger x = 0; x < results.count; ++x)
                    if ([results pointerAtIndex:x] == (__bridge void *)PMKNull)
                        [results replacePointerAtIndex:x withPointer:kCFNull];
                results.allObjects;
            }) : results.allObjects[0];

            if (failed) {
                rejecter(passme);
            } else
                fulfiller(passme);
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
    }];
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-retain-cycles"
+ (Promise *)until:(id (^)(void))blockReturningPromises catch:(id)failHandler
{
    return [Promise new:^(void(^fulfiller)(id), id rejecter){
        __block void (^block)() = ^{
            id promises = blockReturningPromises();
            [self when:promises].then(^(id o){
                fulfiller(o);
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
    }];
}
#pragma clang diagnostic pop

+ (Promise *)promiseWithValue:(id)value {
    Promise *p = [Promise new];
    p->result = value ?: PMKNull;
    return p;
}

+ (Promise *)new:(void(^)(PromiseResolver, PromiseResolver))block {
    Promise *promise = [Promise new];

    id fulfiller = ^(id value){
        if (promise->result)
            @throw PMKE(@"Promise already fulfilled/rejected");
        if ([value isKindOfClass:[NSError class]])
            @throw PMKE(@"You may not fulfill a Promise with an NSError");
        if (!value)
            value = PMKNull;

        if (IsPromise(value)) {
            Promise *rsvp = (Promise *)value;
            Promise *next = promise;
            if (IsPending(rsvp)) {
                [rsvp->thens addObject:^(id o){
                    next->result = o;
                    return next;
                }];
                [rsvp->pendingPromises addObject:next];
                return;
            } else
                promise->result = rsvp->result;
        } else
            promise->result = value;

        FulfillRecursively(promise);
    };
    id rejecter = ^(id error){
        if (promise->result)
            @throw PMKE(@"Promise already fulfilled/rejected");
        if ([error isKindOfClass:[Promise class]])
            @throw PMKE(@"You may not reject a Promise");
        if (!error)
            error = [NSError errorWithDomain:PMKErrorDomain code:PMKErrorCodeUnknown userInfo:nil];
        if (![error isKindOfClass:[NSError class]])
            error = NSErrorWithThrown(error);

        promise->result = error;
        RejectRecursively(promise);
    };

    @try {
        block(fulfiller, rejecter);
    } @catch (id e) {
        promise->result = NSErrorWithThrown(e);
    }

    return promise;
}

@end


/**
 Static C functions rather that methods on Promise to enforce strict
 encapsulation and immutability on Promise objects. This may seem strict,
 but it fits well with the ideals of the Promise pattern. You can be
 completely certain that third-party libraries and end-users of your
 Promise based API did not modify your Promises.
 */
static void FulfillRecursively(Promise *promise) {
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
            FulfillRecursively(next);
        } else
            FulfillRecursively(next);
    }

    // search through fails for thens
    for (Promise *pending in promise->pendingPromises) {
        pending->result = promise->result;
        FulfillRecursively(pending);
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
            FulfillRecursively(next);
    }

    // search through thens for fails
    for (Promise *pending in promise->pendingPromises) {
        pending->result = promise->result;
        RejectRecursively(pending);
    }

    promise->thens = promise->fails = promise->pendingPromises = nil;
}



Promise *dispatch_promise(id block) {
    return dispatch_promise_on(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), block);
}

Promise *dispatch_promise_on(dispatch_queue_t queue, id block) {
    return [Promise new:^(void(^fulfiller)(id), void(^rejecter)(id)){
        dispatch_async(queue, ^{
            __block id result = safely_call_block(block, nil);
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([result isKindOfClass:[NSError class]])
                    rejecter(result);
                else
                    fulfiller(result);
            });
        });
    }];
}
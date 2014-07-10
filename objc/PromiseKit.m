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

#define IsPromise(o) ([o isKindOfClass:[PMKPromise class]])
#define IsError(o) ([o isKindOfClass:[NSError class]])
#define PMKE(txt) [NSException exceptionWithName:@"PromiseKit" reason:@"PromiseKit: " txt userInfo:nil]

static const id PMKNull = @"PMKNull";

@interface PMKArray : NSObject
@end

// deprecated
NSString const*const PMKThrown = PMKUnderlyingExceptionKey;



static inline NSError *NSErrorWithThrown(id e) {
    id userInfo = [NSMutableDictionary new];
    userInfo[PMKUnderlyingExceptionKey] = e;
    if ([e isKindOfClass:[NSException class]])
        userInfo[NSLocalizedDescriptionKey] = [e reason];
    else
        userInfo[NSLocalizedDescriptionKey] = [e description];
    return [NSError errorWithDomain:PMKErrorDomain code:PMKErrorCodeThrown userInfo:userInfo];
}



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

        #define call_block_with_rtype(type) ({^type{ \
            switch (nargs) { \
                default:  @throw PMKE(@"Invalid argument count for handler block"); \
                case 1:   return ((type(^)(void))frock)(); \
                case 2: { \
                    type (^block)(id) = frock; \
                    return [result class] == [PMKArray class] \
                        ? block(result[0]) \
                        : block(result); \
                } \
                case 3: { \
                    type (^block)(id, id) = frock; \
                    return [result class] == [PMKArray class] \
                        ? block(result[0], result[1]) \
                        : block(result, nil); \
                } \
                case 4: { \
                    type (^block)(id, id, id) = frock; \
                    return [result class] == [PMKArray class] \
                        ? block(result[0], result[1], result[2]) \
                        : block(result, nil, nil); \
                } \
            }}();})

        switch (rtype) {
            case 'v':
                call_block_with_rtype(void);
                return PMKNull;
            case '@':
                return call_block_with_rtype(id) ?: PMKNull;
            case '*': {
                char *str = call_block_with_rtype(char *);
                return str ? @(str) : PMKNull;
            }
            case 'c': return @(call_block_with_rtype(char));
            case 'i': return @(call_block_with_rtype(int));
            case 's': return @(call_block_with_rtype(short));
            case 'l': return @(call_block_with_rtype(long));
            case 'q': return @(call_block_with_rtype(long long));
            case 'C': return @(call_block_with_rtype(unsigned char));
            case 'I': return @(call_block_with_rtype(unsigned int));
            case 'S': return @(call_block_with_rtype(unsigned short));
            case 'L': return @(call_block_with_rtype(unsigned long));
            case 'Q': return @(call_block_with_rtype(unsigned long long));
            case 'f': return @(call_block_with_rtype(float));
            case 'd': return @(call_block_with_rtype(double));
            case 'B': return @(call_block_with_rtype(_Bool));
            case '^':
                if (strcmp(sig.methodReturnType, "^v") == 0) {
                    call_block_with_rtype(void);
                    return PMKNull;
                }
                // else fall through!
            default:
                @throw PMKE(@"Unsupported method signature… Why not fork and fix?");
        }
    } @catch (id e) {
      #ifdef PMK_RETHROW_LIKE_A_MOFO
        if ([e isKindOfClass:[NSException class]] && (
            [e name] == NSGenericException ||
            [e name] == NSRangeException ||
            [e name] == NSInvalidArgumentException ||
            [e name] == NSInternalInconsistencyException ||
            [e name] == NSObjectInaccessibleException ||
            [e name] == NSObjectNotAvailableException ||
            [e name] == NSDestinationInvalidException ||
            [e name] == NSPortTimeoutException ||
            [e name] == NSInvalidSendPortException ||
            [e name] == NSInvalidReceivePortException ||
            [e name] == NSPortSendException ||
            [e name] == NSPortReceiveException))
                @throw e;
      #endif
        return IsError(e) ? e : NSErrorWithThrown(e);
    }
}



@implementation PMKPromise {
/**
 We have public @implementation instance variables so PMKResolve
 can fulfill promises. Our usage is like the C++ `friend` keyword.
 */
@public
    NSMutableArray *_handlers;
    id _result;
}

- (instancetype)init {
    @throw PMKE(@"init is not a valid initializer for PMKPromise");
    return nil;
}

- (void)dealloc {
    if (!_result && _handlers.count)
        NSLog(@"PromiseKit: Promise about to be deallocated before it has been resolved! This is likely a bug and you are likely to crash. @see https://github.com/mxcl/PromiseKit/issues/50");
}

- (PMKPromise *(^)(id))then {
    return ^(id block){
        return self.thenOn(dispatch_get_main_queue(), block);
    };
}

- (PMKPromise *(^)(dispatch_queue_t, id))thenOn {
    if (IsPromise(_result))
        return ((PMKPromise *)_result).thenOn;

    if (IsError(_result))
        return ^(dispatch_queue_t q, id b){
            return [PMKPromise promiseWithValue:_result];
        };

    if (_result) return ^(dispatch_queue_t q, id block) {
        return dispatch_promise_on(q, ^{   // don’t release Zalgo
            return safely_call_block(block, _result);
        });
    };

    return ^(dispatch_queue_t q, id block){
        __block PMKPromiseFulfiller fulfiller;
        __block PMKPromiseRejecter rejecter;
        PMKPromise *next = [PMKPromise new:^(PMKPromiseFulfiller fluff, PMKPromiseRejecter rejunk) {
            fulfiller = fluff;
            rejecter = rejunk;
        }];
        [_handlers addObject:^(id selfDotResult){
            if (IsError(selfDotResult)) {
                next->_result = selfDotResult;
                PMKResolve(next);
            }
            else dispatch_async(q, ^{
                id rv = safely_call_block(block, selfDotResult);
                if (IsError(rv))
                    rejecter(rv);
                else
                    fulfiller(rv);
            });
        }];
        return next;
    };
}

- (PMKPromise *(^)(id))catch {
    if (IsPromise(_result))
        return ((PMKPromise *)_result).catch;

    if (IsError(_result)) return ^(id block) {
        return dispatch_promise_on(dispatch_get_main_queue(), ^{   // don’t release Zalgo
            return safely_call_block(block, _result);
        });
    };

    if (_result) return ^id(id block){
        return [PMKPromise promiseWithValue:_result];
    };

    return ^(id block){
        __block PMKPromiseFulfiller fulfiller;
        __block PMKPromiseRejecter rejecter;
        PMKPromise *next = [PMKPromise new:^(PMKPromiseFulfiller fluff, PMKPromiseRejecter rejunk) {
            fulfiller = fluff;
            rejecter = rejunk;
        }];
        [_handlers addObject:^(id selfDotResult){
            if (IsError(selfDotResult)) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    id rv = safely_call_block(block, selfDotResult);
                    if (IsError(rv))
                        rejecter(rv);
                    else if (rv)
                        fulfiller(rv);
                });
            } else {
                next->_result = selfDotResult;
                PMKResolve(next);
            }
        }];
        return next;
    };
}

- (PMKPromise *(^)(void(^)(void)))finally {
    if (IsPromise(_result))
        return ((PMKPromise *)_result).finally;

    if (_result) return ^(void (^block)(void)) {
        return dispatch_promise_on(dispatch_get_main_queue(), ^{
            block();
            return _result;
        });
    };

    return ^(void (^block)(void)){
        __block PMKPromiseFulfiller fulfiller;
        __block PMKPromiseRejecter rejecter;
        PMKPromise *next = [PMKPromise new:^(PMKPromiseFulfiller fluff, PMKPromiseRejecter rejunk) {
            fulfiller = fluff;
            rejecter = rejunk;
        }];
        [_handlers addObject:^(id passthru){
            dispatch_async(dispatch_get_main_queue(), ^{
                block();
                if (IsError(passthru))
                    rejecter(passthru);
                else
                    fulfiller(passthru);
            });
        }];
        return next;
    };
}

+ (PMKPromise *)all:(id<NSFastEnumeration, NSObject>)promises {
    __block NSUInteger count = [(id)promises count];  // FIXME
    
    if (count == 0)
        return [PMKPromise promiseWithValue:@[]];

    #define rejecter(key) ^(NSError *err){ \
        id userInfo = err.userInfo.mutableCopy; \
        userInfo[PMKFailingPromiseIndexKey] = key; \
        err = [NSError errorWithDomain:err.domain code:err.code userInfo:userInfo]; \
        rejecter(err); \
    }

    if ([promises isKindOfClass:[NSDictionary class]])
        return [PMKPromise new:^(PMKPromiseFulfiller fulfiller, PMKPromiseRejecter rejecter){
            NSMutableDictionary *results = [NSMutableDictionary new];
            for (id key in promises) {
                PMKPromise *promise = promises[key];
                if (!IsPromise(promise))
                    promise = [PMKPromise promiseWithValue:promise];
                promise.catch(rejecter(key));
                promise.then(^(id o){
                    if (o)
                        results[key] = o;
                    if (--count == 0)
                        fulfiller(results);
                });
            }
        }];

    return [PMKPromise new:^(PMKPromiseFulfiller fulfiller, PMKPromiseRejecter rejecter){
        NSPointerArray *results = [NSPointerArray strongObjectsPointerArray];
        results.count = count;

        NSUInteger ii = 0;

        for (__strong PMKPromise *promise in promises) {
            if (!IsPromise(promise))
                promise = [PMKPromise promiseWithValue:promise];
            promise.catch(rejecter(@(ii)));
            promise.then(^(id o){
                [results replacePointerAtIndex:ii withPointer:(__bridge void *)(o ?: [NSNull null])];
                if (--count == 0)
                    fulfiller(results.allObjects);
            });
            ii++;
        }
    }];

    #undef rejecter
}

+ (PMKPromise *)when:(id)promises {
    if ([promises conformsToProtocol:@protocol(NSFastEnumeration)]) {
        return [self all:promises];
    } else {
        return [self all:@[promises]].then(^(NSArray *values){
            return values[0];
        });
    }
}

+ (PMKPromise *)until:(id (^)(void))blockReturningPromises catch:(id)failHandler
{
  #pragma clang diagnostic push
  #pragma clang diagnostic ignored "-Warc-retain-cycles"

    return [PMKPromise new:^(void(^fulfiller)(id), id rejecter){
        __block void (^block)() = ^{
            id promises = blockReturningPromises();
            [self when:promises].then(^(id o){
                fulfiller(o);
                block = nil;  // break retain cycle
            }).catch(^(id e){
                PMKPromise *rv = safely_call_block(failHandler, e);
                if (IsPromise(rv))
                    rv.then(block);
                else if (!IsError(rv))
                    block();
            });
        };
        block();
    }];

  #pragma clang diagnostic pop
}


+ (PMKPromise *)promiseWithValue:(id)value {
    PMKPromise *p = [PMKPromise alloc];
    p->_result = value ?: PMKNull;
    return p;
}


static void PMKResolve(PMKPromise *this) {
    id const value = ({
        PMKPromise *rv = this->_result;
        if (IsPromise(rv) && !rv.pending)
            rv = rv.value ?: PMKNull;
        rv;
    });

    if (IsPromise(value)) {
        PMKPromise *rsvp = (PMKPromise *)value;
        [rsvp->_handlers addObject:^(id o){
            this->_result = o;
            PMKResolve(this);
        }];
    } else {
        for (void (^handler)(id) in this->_handlers)
            handler(value);
        this->_handlers = nil;
    }
}


+ (PMKPromise *)new:(void(^)(PMKPromiseFulfiller, PMKPromiseRejecter))block {
    PMKPromise *this = [PMKPromise alloc];
    this->_handlers = [NSMutableArray new];

    id fulfiller = ^(id value){
        if (this->_result)
            return NSLog(@"PromiseKit: Promise already resolved");
        if (IsError(value))
            @throw PMKE(@"You may not fulfill a Promise with an NSError");
        if (!value)
            value = PMKNull;

        this->_result = value;
        PMKResolve(this);
    };

    id rejecter = ^(id error){
        if (this->_result)
            return NSLog(@"PromiseKit: Promise already resolved");
        if (IsPromise(error)) {
            if ([error rejected]) {
                error = ((PMKPromise *)error).value;
            } else
                @throw PMKE(@"You may not reject a Promise with a Promise");
        }
        if (!error)
            error = [NSError errorWithDomain:PMKErrorDomain code:PMKErrorCodeUnknown userInfo:nil];
        if (!IsError(error)) {
            NSLog(@"PromiseKit: Warning, you should reject with proper NSError objects!");
            error = [NSError errorWithDomain:PMKErrorDomain code:PMKErrorCodeInvalidUsage userInfo:@{
                NSLocalizedDescriptionKey: [error description]
            }];
        }

        this->_result = error;
        PMKResolve(this);
    };

    @try {
        block(fulfiller, rejecter);
    } @catch (id e) {
        this->_result = IsError(e) ? e : NSErrorWithThrown(e);
    }

    return this;
}

- (BOOL)pending {
	id result = _result;
    if (IsPromise(result)) {
        return [result pending];
    } else
        return result == nil;
}

- (BOOL)resolved {
    return _result != nil;
}

- (BOOL)fulfilled {
	id result = _result;
    return result != nil && !IsError(result);
}

- (BOOL)rejected {
	id result = _result;
    return result != nil && IsError(result);
}

- (id)value {
	id result = _result;
    if (IsPromise(result))
        return [(PMKPromise*)result value];
    if (result == PMKNull)
        return nil;
    else
        return result;
}

- (NSString *)description {
    if (self.pending)
        return [NSString stringWithFormat:@"Promise: %lu pending handlers", (unsigned long)_handlers.count];
    if (self.rejected)
        return [NSString stringWithFormat:@"Promise: rejected: %@", _result];

    assert(self.fulfilled);

    return [NSString stringWithFormat:@"Promise: fulfilled: %@", _result];
}

@end



PMKPromise *dispatch_promise(id block) {
    return dispatch_promise_on(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), block);
}

PMKPromise *dispatch_promise_on(dispatch_queue_t queue, id block) {
    return [PMKPromise new:^(void(^fulfiller)(id), void(^rejecter)(id)){
        dispatch_async(queue, ^{
            id result = safely_call_block(block, nil);
            if (IsError(result))
                rejecter(result);
            else
                fulfiller(result);
        });
    }];
}



@implementation PMKArray
{ @public NSArray *objs; }

- (id)objectAtIndexedSubscript:(NSUInteger)idx {
    return objs.count >= idx+1 ? objs[idx] : nil;
}

@end



#undef PMKManifold

id PMKManifold(NSArray *args) {
    PMKArray *aa = [PMKArray new];
    aa->objs = args;
    return aa;
}

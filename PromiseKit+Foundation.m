#import "Chuzzle.h"
@import CoreFoundation.CFString;
@import CoreFoundation.CFURL;
@import Foundation.NSError;
@import Foundation.NSJSONSerialization;
@import Foundation.NSOperation;
@import Foundation.NSSortDescriptor;
@import Foundation.NSURL;
@import Foundation.NSURLError;
@import Foundation.NSURLResponse;
#import "PromiseKit+Foundation.h"
#import "PromiseKit/Promise.h"


static inline NSString *enc(NSString *in) {
	return (__bridge_transfer  NSString *) CFURLCreateStringByAddingPercentEscapes(
            kCFAllocatorDefault,
            (__bridge CFStringRef)in.description,
            CFSTR("[]."),
            CFSTR(":/?&=;+!@#$()',*"),
            kCFStringEncodingUTF8);
}

static BOOL NSHTTPURLResponseIsJSON(NSHTTPURLResponse *rsp) {
    NSString *type = rsp.allHeaderFields[@"Content-Type"];
    NSArray *bits = [type componentsSeparatedByString:@";"];
    return [bits.chuzzle containsObject:@"application/json"];
}

#ifdef UIKIT_EXTERN
static BOOL NSHTTPURLResponseIsImage(NSHTTPURLResponse *rsp) {
    NSString *type = rsp.allHeaderFields[@"Content-Type"];
    NSArray *bits = [type componentsSeparatedByString:@";"];
    for (NSString *bit in bits) {
        if ([bit isEqualToString:@"image/jpeg"]) return YES;
        if ([bit isEqualToString:@"image/png"]) return YES;
    };
    return NO;
}
#endif

static NSDictionary *NSDictionaryExtend(NSDictionary *add, NSDictionary *base) {
    base = base.mutableCopy;
    [(id)base addEntriesFromDictionary:add];
    return base;
}

static NSArray *DoQueryMagic(NSString *key, id value) {
    NSMutableArray *parts = [NSMutableArray new];

    // Sort dictionary keys to ensure consistent ordering in query string,
    // which is important when deserializing potentially ambiguous sequences,
    // such as an array of dictionaries
    #define sortDescriptor [NSSortDescriptor sortDescriptorWithKey:@"description" ascending:YES selector:@selector(compare:)]

    if ([value isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dictionary = value;
        for (id nestedKey in [dictionary.allKeys sortedArrayUsingDescriptors:@[sortDescriptor]]) {
            id recursiveKey = key ? [NSString stringWithFormat:@"%@[%@]", key, nestedKey] : nestedKey;
            [parts addObjectsFromArray:DoQueryMagic(recursiveKey, dictionary[nestedKey])];
        }
    } else if ([value isKindOfClass:[NSArray class]]) {
        for (id nestedValue in value)
            [parts addObjectsFromArray:DoQueryMagic([NSString stringWithFormat:@"%@[]", key], nestedValue)];
    } else if ([value isKindOfClass:[NSSet class]]) {
        for (id obj in [value sortedArrayUsingDescriptors:@[sortDescriptor]])
            [parts addObjectsFromArray:DoQueryMagic(key, obj)];
    } else
        [parts addObjectsFromArray:@[key, value]];

    return parts;

    #undef sortDescriptor
}

NSString *NSDictionaryToURLQueryString(NSDictionary *params) {
    if (!params.chuzzle)
        return nil;
    NSMutableString *s = [NSMutableString new];
    NSEnumerator *e = DoQueryMagic(nil, params).objectEnumerator;
    for (;;) {
        id obj = e.nextObject;
        if (!obj) break;
        [s appendFormat:@"%@=%@&", enc(obj), enc(e.nextObject)];
    }
    [s deleteCharactersInRange:NSMakeRange(s.length-1, 1)];
    return s;
}



@implementation NSURLConnection (PromiseKit)

+ (Promise *)GET:(id)urlFormat, ... {
    if (!urlFormat)
        return [Promise promiseWithValue:[NSError errorWithDomain:PMKErrorDomain code:PMKErrorCodeInvalidUsage userInfo:nil]];

    if ([urlFormat isKindOfClass:[NSURL class]])
        return [self GET:urlFormat query:nil];
    va_list arguments;
    va_start(arguments, urlFormat);
    urlFormat = [[NSString alloc] initWithFormat:urlFormat arguments:arguments];
    va_end(arguments);
    return [self GET:urlFormat query:nil];
}

+ (Promise *)GET:(id)url query:(NSDictionary *)params {
    if (params.chuzzle) {
        if ([url isKindOfClass:[NSURL class]])
            url = [url absoluteString];
        id query = NSDictionaryToURLQueryString(params);
        url = [NSString stringWithFormat:@"%@?%@", url, query];
    }
    if ([url isKindOfClass:[NSString class]])
        url = [NSURL URLWithString:url];
        
    return [self promise:[NSURLRequest requestWithURL:url]];
}

+ (Promise *)POST:(id)url formURLEncodedParameters:(NSDictionary *)params {
    if ([url isKindOfClass:[NSString class]])
        url = [NSURL URLWithString:url];

    NSMutableURLRequest *rq = [[NSMutableURLRequest alloc] initWithURL:url];

    if (params.chuzzle) {
        [rq addValue:@"application/x-www-form-urlencoded; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
        rq.HTTPBody = [NSDictionaryToURLQueryString(params) dataUsingEncoding:NSUTF8StringEncoding];
    }

    return [self promise:rq];
}

+ (Promise *)promise:(NSURLRequest *)rq {
    id q = [NSOperationQueue currentQueue] ?: [NSOperationQueue mainQueue];

    #define NSURLError(x, desc) [NSError errorWithDomain:NSURLErrorDomain code:x userInfo:NSDictionaryExtend(@{PMKURLErrorFailingURLResponse: rsp, NSLocalizedDescriptionKey: desc}, error.userInfo)]

    return [Promise new:^(void(^fulfiller)(id), void(^rejecter)(id)){
        [NSURLConnection sendAsynchronousRequest:rq queue:q completionHandler:^(id rsp, id data, NSError *error) {
            if (error) {
                if (rsp) {
                    id dict = NSDictionaryExtend(@{PMKURLErrorFailingURLResponse: rsp}, error.userInfo);
                    error = [NSError errorWithDomain:error.domain code:error.code userInfo:dict];
                }
                rejecter(error);
            } else if ([rsp statusCode] != 200) {
                id err = NSURLError(NSURLErrorBadServerResponse, @"bad HTTP response code");
                rejecter(err);
            } else if (NSHTTPURLResponseIsJSON(rsp)) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    id error = nil;
                    id json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingAllowFragments error:&error];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (error)
                            rejecter(error);
                        else
                            fulfiller(json);
                    });
                });
          #ifdef UIKIT_EXTERN
            } else if (NSHTTPURLResponseIsImage(rsp)) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    UIImage *image = [[UIImage alloc] initWithData:data];
                    image = [[UIImage alloc] initWithCGImage:[image CGImage] scale:image.scale orientation:image.imageOrientation];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (image)
                            fulfiller(image);
                        else {
                            id err = NSURLError(NSURLErrorBadServerResponse, @"invalid image data");
                            rejecter(err);
                        }
                    });
                });
          #endif
            } else
                fulfiller(data);
        }];
    }];
}

@end

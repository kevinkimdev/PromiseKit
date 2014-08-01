#import <Foundation/NSDictionary.h>
#import <Foundation/NSURLCache.h>
#import <Foundation/NSURLConnection.h>
#import <Foundation/NSURLRequest.h>
#import "PromiseKit/fwd.h"

#define PMKURLErrorFailingURLResponseKey @"PMKURLErrorFailingURLResponseKey"
#define PMKURLErrorFailingDataKey @"PMKURLErrorFailingDataKey"
#define PMKURLErrorFailingStringKey @"PMKURLErrorFailingStringKey"

extern NSString const*const PMKURLErrorFailingURLResponse __attribute__((deprecated("Use PMKURLErrorFailingURLResponseKey")));
extern NSString const*const PMKURLErrorFailingData __attribute__((deprecated("Use PMKURLErrorFailingDataKey")));



@interface NSURLConnection (PromiseKit)

/**
 We depend on OMGHTTPURLRQ a NSURLRequest additions library that provides
 all the common REST style verbs and parameter encoders. Thus if you need
 eg. a multipartFormData POST, check out OMGHTTPURLRQ (which CocoaPods
 already pulled in for you).
*/
+ (PMKPromise *)GET:(id)stringFormatOrNSURL, ...;
+ (PMKPromise *)GET:(id)stringOrURL query:(NSDictionary *)parameters;
+ (PMKPromise *)POST:(id)stringOrURL formURLEncodedParameters:(NSDictionary *)parameters;
+ (PMKPromise *)PUT:(id)url formURLEncodedParameters:(NSDictionary *)params;
+ (PMKPromise *)DELETE:(id)url formURLEncodedParameters:(NSDictionary *)params;
+ (PMKPromise *)promise:(NSURLRequest *)rq;
@end



@interface NSNotificationCenter (PromiseKit)
/**
 Fires once for the named notification.
 
 thens the NSNotification object and the NSNotification’s userInfo as the second argument.
*/
+ (PMKPromise *)once:(NSString *)notificationName;
@end

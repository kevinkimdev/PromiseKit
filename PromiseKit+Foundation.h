@import Foundation.NSDictionary;
@import Foundation.NSURLCache;
@import Foundation.NSURLConnection;
@import Foundation.NSURLRequest;
@class Promise;

#define PMKURLErrorFailingURLResponse @"PMKURLErrorFailingURLResponse"



@interface NSURLConnection (PromiseKit)
+ (Promise *)GET:(id)stringFormatOrNSURL, ...;
+ (Promise *)GET:(id)stringOrURL query:(NSDictionary *)parameters;
+ (Promise *)POST:(id)stringOrURL formURLEncodedParameters:(NSDictionary *)parameters;
+ (Promise *)promise:(NSURLRequest *)rq;
@end



// ideally this would be from a pod, but I looked and all the pods imposed
// too much symbol overhead or used catgeories
NSString *NSDictionaryToURLQueryString(NSDictionary *parameters);

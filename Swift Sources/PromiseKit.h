@import Foundation;

FOUNDATION_EXPORT double PromiseKitVersionNumber;
FOUNDATION_EXPORT const unsigned char PromiseKitVersionString[];

#if !TARGET_OS_MAC
// FIXME
@import AssetsLibrary;
#endif

// for convenience and better error messages if you don’t
// have OMGHTTPURLRQ available and to hand
@import OMGHTTPURLRQ;

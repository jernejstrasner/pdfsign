// Pure Objective-C interface so Swift can call it via the bridging header.
// All PoDoFo (C++) usage stays in the .mm — keep this header C++-free.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Security/Security.h>

NS_ASSUME_NONNULL_BEGIN

@interface PDFSigningEngine : NSObject

/// Sign the PDF at @c inputURL, writing the signed copy to @c outputURL.
///
/// @param pageIndex   zero-based page the visible signature goes on
/// @param rect        widget rectangle in PDF page points, origin bottom-left
/// @param identity    Keychain identity; its private key never leaves the Keychain
///                    (signing is delegated to SecKeyCreateSignature)
/// Returns NO and sets @c error on failure. Imported into Swift as a throwing call.
+ (BOOL)signPDFAtURL:(NSURL *)inputURL
           outputURL:(NSURL *)outputURL
           pageIndex:(NSInteger)pageIndex
                rect:(CGRect)rect
            identity:(SecIdentityRef)identity
          signerName:(nullable NSString *)signerName
              reason:(nullable NSString *)reason
            location:(nullable NSString *)location
               error:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END

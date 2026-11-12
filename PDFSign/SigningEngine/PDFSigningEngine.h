// Pure Objective-C interface so Swift can call it via the bridging header.
// All PoDoFo (C++) usage stays in the .mm — keep this header C++-free.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Security/Security.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, PDFSignFieldKind) {
    /// Visible signature stamp (image/badge + signer name + optional date/text).
    PDFSignFieldKindSignature = 0,
    /// A single line of plain text (date fields arrive here already formatted).
    PDFSignFieldKindText = 1,
};

/// One visible element to stamp onto the document as part of the signed revision.
@interface PDFSignField : NSObject
@property (nonatomic) PDFSignFieldKind kind;
/// zero-based page index
@property (nonatomic) NSInteger pageIndex;
/// rectangle in unrotated PDF page space (points, origin bottom-left of the raw page —
/// what PDFKit uses); the engine rotates the content to read upright on /Rotate pages
@property (nonatomic) CGRect rect;
/// text for PDFSignFieldKindText; ignored for signatures
@property (nonatomic, copy, nullable) NSString *text;
/// Signatures only: full name of an existing, unsigned signature field to fill in place
/// (its own widget rect wins over @c rect).
@property (nonatomic, copy, nullable) NSString *formFieldName;

- (instancetype)initWithKind:(PDFSignFieldKind)kind
                   pageIndex:(NSInteger)pageIndex
                        rect:(CGRect)rect
                        text:(nullable NSString *)text
               formFieldName:(nullable NSString *)formFieldName;
@end

/// A signature form field found in a document (one entry per field, first widget).
@interface PDFSignatureFieldInfo : NSObject
/// fully qualified field name ("parent.child")
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, readonly) NSInteger pageIndex;
/// unrotated page space, like PDFSignField.rect
@property (nonatomic, readonly) CGRect rect;
/// already carries a signature value
@property (nonatomic, readonly) BOOL isSigned;
@end

@interface PDFSigningEngine : NSObject

/// Sign the PDF at @c inputURL, writing the signed copy to @c outputURL.
///
/// One signature field carries the cryptographic signature: the field with a
/// @c formFieldName if any, else the first signature field. Further signature stamps
/// become additional widgets of that same field; dates and text are drawn into the page
/// content of the same incremental update, so the one signature covers all of them.
///
/// @param fields      at least one field must be PDFSignFieldKindSignature
/// @param identity    Keychain identity; its private key never leaves the Keychain
///                    (signing is delegated to SecKeyCreateSignature)
/// @param signatureImagePNG  optional PNG of the user's drawn/imported signature,
///                    stamped in place of the default seal badge
/// @param includeDate whether signature stamps show the signing date (UTC)
/// @param customText  optional free-text line shown under the signer name
/// Returns NO and sets @c error on failure. Imported into Swift as a throwing call.
+ (BOOL)signPDFAtURL:(NSURL *)inputURL
           outputURL:(NSURL *)outputURL
              fields:(NSArray<PDFSignField *> *)fields
            identity:(SecIdentityRef)identity
          signerName:(nullable NSString *)signerName
              reason:(nullable NSString *)reason
            location:(nullable NSString *)location
  signatureImagePNG:(nullable NSData *)signatureImagePNG
         includeDate:(BOOL)includeDate
          customText:(nullable NSString *)customText
               error:(NSError *_Nullable *_Nullable)error;

/// Signature fields in the document, read with the same lookup @c signPDFAtURL uses to
/// fill one (so anything listed unsigned here can be targeted by name).
+ (nullable NSArray<PDFSignatureFieldInfo *> *)signatureFieldsInPDFAtURL:(NSURL *)url
                                                                   error:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END

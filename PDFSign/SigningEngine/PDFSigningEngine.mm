#import "PDFSigningEngine.h"
#import <AppKit/AppKit.h>

#include <podofo/podofo.h>

#include <algorithm>
#include <cstring>
#include <memory>
#include <stdexcept>
#include <string>

using namespace PoDoFo;

static NSString *const kEngineErrorDomain = @"PDFSigningEngine";

static NSError *MakeError(NSString *message) {
    return [NSError errorWithDomain:kEngineErrorDomain
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"Unknown error"}];
}

// Pick the SecKey signing algorithm (SHA-256) matching the key type in the cert.
static SecKeyAlgorithm AlgorithmForKey(SecKeyRef key) {
    SecKeyAlgorithm algo = kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA256;
    if (CFDictionaryRef attrs = SecKeyCopyAttributes(key)) {
        CFStringRef keyType = (CFStringRef)CFDictionaryGetValue(attrs, kSecAttrKeyType);
        if (keyType != NULL && CFEqual(keyType, kSecAttrKeyTypeECSECPrimeRandom))
            algo = kSecKeyAlgorithmECDSASignatureDigestX962SHA256;
        CFRelease(attrs);
    }
    return algo;
}

// Render the checkmark.seal.fill SF Symbol, tinted green, to PNG bytes for embedding.
static NSData *SealBadgePNG(CGFloat px) {
    NSImage *base = [NSImage imageWithSystemSymbolName:@"checkmark.seal.fill"
                              accessibilityDescription:nil];
    if (base == nil) return nil;
    NSImageSymbolConfiguration *sizeCfg =
        [NSImageSymbolConfiguration configurationWithPointSize:px * 0.9
                                                        weight:NSFontWeightSemibold
                                                         scale:NSImageSymbolScaleLarge];
    NSImageSymbolConfiguration *colorCfg = [NSImageSymbolConfiguration
        configurationWithHierarchicalColor:[NSColor colorWithSRGBRed:0.20 green:0.65 blue:0.33 alpha:1.0]];
    NSImage *img = [base imageWithSymbolConfiguration:
                        [sizeCfg configurationByApplyingConfiguration:colorCfg]];
    if (img == nil) return nil;

    NSInteger side = (NSInteger)ceil(px);
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:side pixelsHigh:side
                   bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                  colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    if (rep == nil) return nil;
    NSGraphicsContext *gctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = gctx;
    NSSize s = img.size;
    CGFloat scale = (s.width > 0 && s.height > 0) ? MIN(side / s.width, side / s.height) : 1.0;
    NSRect r = NSMakeRect((side - s.width * scale) / 2.0, (side - s.height * scale) / 2.0,
                          s.width * scale, s.height * scale);
    [img drawInRect:r fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
    [NSGraphicsContext restoreGraphicsState];
    return [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}

@implementation PDFSigningEngine

+ (BOOL)signPDFAtURL:(NSURL *)inputURL
           outputURL:(NSURL *)outputURL
           pageIndex:(NSInteger)pageIndex
                rect:(CGRect)rect
            identity:(SecIdentityRef)identity
          signerName:(NSString *)signerName
              reason:(NSString *)reason
            location:(NSString *)location
               error:(NSError *_Nullable *_Nullable)error {
    // --- 1. Pull the certificate (DER) and private key out of the identity. ---
    SecCertificateRef certRef = NULL;
    if (SecIdentityCopyCertificate(identity, &certRef) != errSecSuccess || certRef == NULL) {
        if (error) *error = MakeError(@"Could not read the certificate from the identity.");
        return NO;
    }
    SecKeyRef privKey = NULL;
    if (SecIdentityCopyPrivateKey(identity, &privKey) != errSecSuccess || privKey == NULL) {
        CFRelease(certRef);
        if (error) *error = MakeError(@"Could not access the private key for this identity.");
        return NO;
    }

    CFDataRef certData = SecCertificateCopyData(certRef);
    std::string certDer((const char *)CFDataGetBytePtr(certData), (size_t)CFDataGetLength(certData));
    CFRelease(certData);
    CFRelease(certRef);

    const SecKeyAlgorithm algo = AlgorithmForKey(privKey);

    // --- 2. Copy input -> output, then sign the output in place (incremental update). ---
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm removeItemAtURL:outputURL error:nil];
    NSError *copyErr = nil;
    if (![fm copyItemAtURL:inputURL toURL:outputURL error:&copyErr]) {
        CFRelease(privKey);
        if (error) *error = copyErr ?: MakeError(@"Could not create the output file.");
        return NO;
    }

    std::string outputPath(outputURL.path.UTF8String);

    // Visible-stamp text + metadata, all stamped at one instant.
    NSDate *now = [NSDate date];
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    df.dateFormat = @"yyyy-MM-dd HH:mm";
    NSString *dateStr = [df stringFromDate:now];
    NSDateFormatter *pf = [[NSDateFormatter alloc] init];
    pf.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    pf.dateFormat = @"'D:'yyyyMMddHHmmss'Z'";  // PDF date syntax for the annotation /M

    NSString *l1 = signerName.length ? [NSString stringWithFormat:@"Signed by %@", signerName]
                                     : @"Digitally signed";
    NSString *l2 = [dateStr stringByAppendingString:@" UTC"];
    NSString *l3 = reason.length ? [NSString stringWithFormat:@"Reason: %@", reason] : nil;
    NSString *contentsNS = l3 ? [NSString stringWithFormat:@"%@ · %@ · %@", l1, l2, l3]
                              : [NSString stringWithFormat:@"%@ · %@", l1, l2];

    std::string line1(l1.UTF8String);
    std::string line2(l2.UTF8String);
    std::string line3(l3 ? l3.UTF8String : "");
    std::string pdfDate([pf stringFromDate:now].UTF8String);
    std::string contents(contentsNS.UTF8String);
    NSData *badgePNG = SealBadgePNG(128.0);

    BOOL ok = NO;
    NSString *failMsg = nil;

    try {
        auto stream = std::make_shared<FileStreamDevice>(outputPath, FileMode::Open);
        PdfMemDocument doc(stream);

        if (pageIndex < 0 || (unsigned)pageIndex >= doc.GetPages().GetCount())
            throw std::runtime_error("Page index out of range.");

        auto &page = doc.GetPages().GetPageAt((unsigned)pageIndex);

        // AcroForm /SigFlags = 3 (signatures exist + append-only) — keeps viewers happy.
        auto &acro = doc.GetOrCreateAcroForm();
        auto &acroDict = acro.GetDictionary();
        if (acroDict.HasKey("SigFlags")) acroDict.RemoveKey("SigFlags");
        acroDict.AddKey("SigFlags", static_cast<int64_t>(3));

        const double w = rect.size.width;
        const double h = rect.size.height;
        // Fully qualified: macOS MacTypes.h also declares a global `Rect`.
        PoDoFo::Rect annotRect(rect.origin.x, rect.origin.y, w, h);

        auto &signature = page.CreateField<PdfSignature>(PdfString("Signature"), annotRect);
        signature.MustGetWidget().SetFlags(PdfAnnotationFlags::Print);

        // Visible appearance: check badge + signer/date/reason text in an XObject form.
        auto xobj = doc.CreateXObjectForm(PoDoFo::Rect(0.0, 0.0, w, h));
        {
            PdfPainter painter;
            painter.SetCanvas(*xobj);
            // Workaround for Adobe "Expected a dict object." on single-op streams.
            painter.Save();
            painter.Restore();

            const double pad = 6.0;

            // Subtle rounded border.
            painter.GraphicsState.SetStrokingColor(PdfColor(0.72, 0.74, 0.78));
            painter.GraphicsState.SetLineWidth(0.8);
            PdfPainterPath border;
            border.AddRectangle(0.6, 0.6, std::max(1.0, w - 1.2), std::max(1.0, h - 1.2), 4.0, 4.0);
            painter.DrawPath(border, PdfPathDrawMode::Stroke);

            // Seal badge on the left — the checkmark.seal.fill SF Symbol, with a vector fallback.
            const double iconSize = std::clamp(h - 2.0 * pad, 16.0, 40.0);
            const double iconX = pad;
            const double iconY = (h - iconSize) / 2.0;
            bool drewBadge = false;
            if (badgePNG != nil && badgePNG.length > 0) {
                try {
                    auto badge = doc.CreateImage();
                    badge->LoadFromBuffer(bufferview((const char *)badgePNG.bytes,
                                                     (size_t)badgePNG.length));
                    const double sc = iconSize / 128.0;
                    painter.DrawImage(*badge, iconX, iconY, sc, sc);
                    drewBadge = true;
                } catch (...) {
                    drewBadge = false;
                }
            }
            if (!drewBadge) {  // fallback: green disc + white check
                const double r = iconSize / 2.0, cx = iconX + r, cy = h / 2.0;
                painter.GraphicsState.SetNonStrokingColor(PdfColor(0.20, 0.65, 0.33));
                painter.DrawCircle(cx, cy, r, PdfPathDrawMode::Fill);
                painter.GraphicsState.SetStrokingColor(PdfColor(1.0, 1.0, 1.0));
                painter.GraphicsState.SetLineWidth(std::max(1.4, r * 0.22));
                painter.GraphicsState.SetLineCapStyle(PdfLineCapStyle::Round);
                painter.GraphicsState.SetLineJoinStyle(PdfLineJoinStyle::Round);
                PdfPainterPath check;
                check.MoveTo(cx - r * 0.45, cy + r * 0.05);
                check.AddLineTo(cx - r * 0.08, cy - r * 0.32);
                check.AddLineTo(cx + r * 0.48, cy + r * 0.42);
                painter.DrawPath(check, PdfPathDrawMode::Stroke);
            }

            // Text block, vertically centered next to the badge.
            const double tx = iconX + iconSize + pad;
            auto &bold = doc.GetFonts().GetStandard14Font(PdfStandard14FontType::HelveticaBold);
            auto &reg = doc.GetFonts().GetStandard14Font(PdfStandard14FontType::Helvetica);
            const double fs1 = std::clamp(h * 0.20, 7.0, 11.0);
            const double fs2 = std::clamp(h * 0.165, 6.0, 9.0);
            const double gap = 4.0;
            const bool hasL3 = !line3.empty();
            const double a1 = fs1 * 0.72, a2 = fs2 * 0.72;  // visual cap heights
            const double blockH = a1 + (gap + a2) + (hasL3 ? (gap + a2) : 0.0);
            double y = (h + blockH) / 2.0 - a1;             // baseline of line 1

            painter.GraphicsState.SetNonStrokingColor(PdfColor(0.10, 0.10, 0.12));
            painter.TextState.SetFont(bold, fs1);
            painter.DrawText(line1, tx, y);

            painter.GraphicsState.SetNonStrokingColor(PdfColor(0.34, 0.36, 0.40));
            painter.TextState.SetFont(reg, fs2);
            y -= (gap + a2);
            painter.DrawText(line2, tx, y);
            if (hasL3) {
                y -= (gap + a2);
                painter.DrawText(line3, tx, y);
            }

            painter.FinishDrawing();
        }

        auto &widget = signature.MustGetWidget();
        widget.SetAppearanceStream(*xobj);
        // Best-effort metadata so viewers can show a tooltip / date for the annotation.
        widget.SetContents(PdfString(contents));
        widget.GetDictionary().AddKey("M", PdfString(pdfDate));

        if (signerName.length) signature.SetSignerName(PdfString(std::string(signerName.UTF8String)));
        if (reason.length) signature.SetSignatureReason(PdfString(std::string(reason.UTF8String)));
        if (location.length) signature.SetSignatureLocation(PdfString(std::string(location.UTF8String)));
        signature.SetSignatureDate(PdfDate::UtcNow());  // PdfDate() defaults to the epoch

        // CMS signer: PoDoFo builds the container, the Keychain key does the raw signature.
        PdfSignerCmsParams params;
        // Stamp the CMS signing-time attribute (otherwise it defaults to the epoch).
        params.SigningTimeUTC = std::chrono::seconds(
            (long long)[[NSDate date] timeIntervalSince1970]);
        params.SigningService = [privKey, algo](bufferview hashToSign, bool /*dryrun*/, charbuff &signedHash) {
            CFDataRef digest = CFDataCreate(NULL, (const UInt8 *)hashToSign.data(), (CFIndex)hashToSign.size());
            CFErrorRef cfErr = NULL;
            CFDataRef sig = SecKeyCreateSignature(privKey, algo, digest, &cfErr);
            if (digest) CFRelease(digest);
            if (sig == NULL) {
                std::string m = "Keychain signing failed";
                if (cfErr) {
                    if (CFStringRef d = CFErrorCopyDescription(cfErr)) {
                        char buf[256];
                        if (CFStringGetCString(d, buf, sizeof(buf), kCFStringEncodingUTF8)) {
                            m += ": ";
                            m += buf;
                        }
                        CFRelease(d);
                    }
                    CFRelease(cfErr);
                }
                throw std::runtime_error(m);
            }
            const CFIndex len = CFDataGetLength(sig);
            signedHash.resize((size_t)len);
            std::memcpy(signedHash.data(), CFDataGetBytePtr(sig), (size_t)len);
            CFRelease(sig);
        };

        PdfSignerCms signer(certDer, params);
        PoDoFo::SignDocument(doc, *stream, signer, signature, PdfSaveOptions::NoMetadataUpdate);
        ok = YES;
    } catch (const PdfError &e) {
        failMsg = [NSString stringWithUTF8String:e.what()];
    } catch (const std::exception &e) {
        failMsg = [NSString stringWithUTF8String:e.what()];
    } catch (...) {
        failMsg = @"Unknown signing error.";
    }

    CFRelease(privKey);

    if (!ok) {
        [fm removeItemAtURL:outputURL error:nil];
        if (error) *error = MakeError(failMsg ?: @"Signing failed.");
        return NO;
    }
    return YES;
}

@end

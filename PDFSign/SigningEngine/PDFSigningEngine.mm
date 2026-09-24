#import "PDFSigningEngine.h"
#import <AppKit/AppKit.h>

#include <podofo/podofo.h>

#include <algorithm>
#include <cstring>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

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
  signatureImagePNG:(NSData *)signatureImagePNG
         includeDate:(BOOL)includeDate
          customText:(NSString *)customText
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

    // Stamp text: signer name, optional date, optional free-text line.
    NSString *l1 = signerName.length ? [NSString stringWithFormat:@"Signed by %@", signerName]
                                     : @"Digitally signed";
    NSString *l2 = includeDate ? [dateStr stringByAppendingString:@" UTC"] : nil;
    NSString *l3 = customText.length ? customText : nil;
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithObject:l1];
    if (l2) [parts addObject:l2];
    if (l3) [parts addObject:l3];
    NSString *contentsNS = [parts componentsJoinedByString:@" · "];

    std::string line1(l1.UTF8String);
    std::string line2(l2 ? l2.UTF8String : "");
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

            // --- Adaptive stamp layout ---
            // Wide box: graphic left, text right. Tall box: graphic on top, text
            // below, centered. Fonts shrink to fit the available width so the
            // content never clips the box.
            auto &bold = doc.GetFonts().GetStandard14Font(PdfStandard14FontType::HelveticaBold);
            auto &reg = doc.GetFonts().GetStandard14Font(PdfStandard14FontType::Helvetica);

            std::vector<std::string> sub;                   // lines under the signer name
            if (!line2.empty()) sub.push_back(line2);
            if (!line3.empty()) sub.push_back(line3);

            auto widthOf = [](PdfFont &f, const std::string &s, double fs) {
                PdfTextState st;
                st.Font = &f;
                st.FontSize = fs;
                double len = 0.0;
                f.TryGetStringLength(s, st, len);   // partial result, never throws
                return len;
            };

            // Load the signature image up front — layout needs its aspect ratio.
            std::unique_ptr<PdfImage> sigImg;
            double sigAspect = 0.0;
            if (signatureImagePNG != nil && signatureImagePNG.length > 0) {
                try {
                    sigImg = doc.CreateImage();
                    sigImg->LoadFromBuffer(bufferview((const char *)signatureImagePNG.bytes,
                                                      (size_t)signatureImagePNG.length));
                    if (sigImg->GetWidth() > 0 && sigImg->GetHeight() > 0)
                        sigAspect = (double)sigImg->GetWidth() / (double)sigImg->GetHeight();
                    else
                        sigImg = nullptr;
                } catch (...) {
                    sigImg = nullptr;
                }
            }

            const bool horizontal = w >= h * 1.5;
            double fs1 = std::clamp(h * 0.20, 5.0, 11.0);
            double fs2 = std::clamp(h * 0.165, 4.5, 9.0);
            double imgX = pad, imgY = 0.0, imgW = 0.0, imgH = 0.0;
            double tx = pad, availW = w - 2.0 * pad;
            double textRegionY = 0.0, textRegionH = h;

            if (horizontal) {
                if (sigImg) {
                    imgH = std::max(8.0, h - 2.0 * pad);
                    imgW = imgH * sigAspect;
                    const double maxW = std::max(8.0, w * 0.45);  // leave room for text
                    if (imgW > maxW) { imgW = maxW; imgH = imgW / sigAspect; }
                } else {
                    imgH = imgW = std::clamp(h - 2.0 * pad, 16.0, 40.0);  // badge slot
                }
                imgY = (h - imgH) / 2.0;
                tx = pad + imgW + pad;
                availW = w - tx - pad;
            } else {
                imgH = sigImg ? std::min(h * 0.45, (w - 2.0 * pad) / sigAspect)
                              : std::clamp(std::min(h * 0.45, w - 2.0 * pad), 12.0, 40.0);
                imgW = sigImg ? imgH * sigAspect : imgH;
                imgX = (w - imgW) / 2.0;
                imgY = h - pad - imgH;                      // graphic hugs the top
                textRegionY = pad;
                textRegionH = std::max(0.0, imgY - pad - pad);
                fs1 = std::clamp(textRegionH * 0.34, 5.0, 11.0);
                fs2 = std::clamp(fs1 * 0.82, 4.5, 9.0);
            }

            // Shrink fonts if the longest line would overflow the available width.
            double maxLineW = widthOf(bold, line1, fs1);
            for (const auto &s : sub) maxLineW = std::max(maxLineW, widthOf(reg, s, fs2));
            if (maxLineW > availW && maxLineW > 0.0) {
                const double scale = availW / maxLineW;
                fs1 = std::max(3.0, fs1 * scale);  // past ~3pt it clips at the border
                fs2 = std::max(3.0, fs2 * scale);
            }

            // Graphic: signature image, or the seal badge (SF Symbol, vector fallback).
            if (sigImg) {
                painter.DrawImage(*sigImg, imgX, imgY,
                                  imgW / (double)sigImg->GetWidth(),
                                  imgH / (double)sigImg->GetHeight());
            } else {
                const double iconSize = imgH;
                bool drewBadge = false;
                if (badgePNG != nil && badgePNG.length > 0) {
                    try {
                        auto badge = doc.CreateImage();
                        badge->LoadFromBuffer(bufferview((const char *)badgePNG.bytes,
                                                         (size_t)badgePNG.length));
                        const double sc = iconSize / 128.0;
                        painter.DrawImage(*badge, imgX, imgY, sc, sc);
                        drewBadge = true;
                    } catch (...) {
                        drewBadge = false;
                    }
                }
                if (!drewBadge) {  // fallback: green disc + white check
                    const double r = iconSize / 2.0, cx = imgX + r, cy = imgY + r;
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
            }

            // Text block, centered in its region (whole box when horizontal, below
            // the graphic when vertical).
            const double a1 = fs1 * 0.72, a2 = fs2 * 0.72;  // visual cap heights
            const double gap = 4.0;
            const double blockH = a1 + (double)sub.size() * (gap + a2);
            double y = textRegionY + (textRegionH + blockH) / 2.0 - a1;  // baseline of line 1

            auto drawLine = [&](PdfFont &f, const std::string &s, double fs, double baseline) {
                double x = tx;
                if (!horizontal) x = (w - widthOf(f, s, fs)) / 2.0;  // centered
                painter.TextState.SetFont(f, fs);
                painter.DrawText(s, x, baseline);
            };

            painter.GraphicsState.SetNonStrokingColor(PdfColor(0.10, 0.10, 0.12));
            drawLine(bold, line1, fs1, y);

            painter.GraphicsState.SetNonStrokingColor(PdfColor(0.34, 0.36, 0.40));
            for (const auto &s : sub) {
                y -= (gap + a2);
                drawLine(reg, s, fs2, y);
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

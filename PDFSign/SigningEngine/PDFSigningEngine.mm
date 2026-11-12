#import "PDFSigningEngine.h"
#import <AppKit/AppKit.h>

#include <podofo/podofo.h>

#include <algorithm>
#include <cstring>
#include <map>
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

static double WidthOf(PdfFont &f, const std::string &s, double fs) {
    PdfTextState st;
    st.Font = &f;
    st.FontSize = fs;
    double len = 0.0;
    f.TryGetStringLength(s, st, len);   // partial result, never throws
    return len;
}

/// Font selection shared by every element of one signing run. Standard-14 Helvetica
/// needs no embedding but only covers WinAnsi; for anything else (č, ő, Cyrillic…)
/// fall back to an embedded, subsetted Arial — metric-compatible with Helvetica, so
/// layout and the on-screen preview stay the same.
class FontPicker {
public:
    explicit FontPicker(PdfMemDocument &doc) : m_doc(doc) {}

    PdfFont &For(const std::string &s, bool bold) {
        PdfFont &std14 = m_doc.GetFonts().GetStandard14Font(
            bold ? PdfStandard14FontType::HelveticaBold : PdfStandard14FontType::Helvetica);
        PdfTextState st;
        st.Font = &std14;
        st.FontSize = 10;
        double len = 0.0;
        if (std14.TryGetStringLength(s, st, len)) return std14;

        PdfFont *&cached = bold ? m_arialBold : m_arial;
        if (cached == nullptr) {
            const char *path = bold ? "/System/Library/Fonts/Supplemental/Arial Bold.ttf"
                                    : "/System/Library/Fonts/Supplemental/Arial.ttf";
            try {
                cached = &m_doc.GetFonts().GetOrCreateFont(path);
            } catch (...) {
                return std14;  // unencodable glyphs get dropped, but we still sign
            }
        }
        return *cached;
    }

private:
    PdfMemDocument &m_doc;
    PdfFont *m_arial = nullptr;
    PdfFont *m_arialBold = nullptr;
};

/// What goes into each signature stamp. Images are loaded once per document and the
/// same XObjects get referenced by every stamp, so N stamps don't mean N image copies.
struct StampContent {
    std::string line1;            // "Signed by …"
    std::vector<std::string> sub; // date, custom text
    PdfImage *sigImage = nullptr; // drawn/imported signature
    double sigAspect = 0.0;
    PdfImage *badge = nullptr;    // fallback seal when no signature image
};

// Workaround for Adobe "Expected a dict object." on single-op streams.
static void BeginCanvas(PdfPainter &painter, PdfCanvas &canvas) {
    painter.SetCanvas(canvas);
    painter.Save();
    painter.Restore();
}

// TODO: tiny boxes (initials) hit the 3 pt font floor and clip the text; an image-only
// stamp variant would read better there.
/// Signature stamp appearance: adaptive layout (wide → graphic left/text right, tall →
/// graphic top/text below). Mirrored by FieldRenderer.drawStamp in the Swift preview.
static std::unique_ptr<PdfXObjectForm> MakeStampXObject(PdfMemDocument &doc, FontPicker &fonts,
                                                         double w, double h, const StampContent &c) {
    auto xobj = doc.CreateXObjectForm(PoDoFo::Rect(0.0, 0.0, w, h));
    PdfPainter painter;
    BeginCanvas(painter, *xobj);

    const double pad = 6.0;

    // Subtle rounded border.
    painter.GraphicsState.SetStrokingColor(PdfColor(0.72, 0.74, 0.78));
    painter.GraphicsState.SetLineWidth(0.8);
    PdfPainterPath border;
    border.AddRectangle(0.6, 0.6, std::max(1.0, w - 1.2), std::max(1.0, h - 1.2), 4.0, 4.0);
    painter.DrawPath(border, PdfPathDrawMode::Stroke);

    PdfFont &bold = fonts.For(c.line1, true);
    std::vector<PdfFont *> subFonts;
    for (const auto &s : c.sub) subFonts.push_back(&fonts.For(s, false));

    const bool hasImage = c.sigImage != nullptr && c.sigAspect > 0.0;
    const bool horizontal = w >= h * 1.5;
    double fs1 = std::clamp(h * 0.20, 5.0, 11.0);
    double fs2 = std::clamp(h * 0.165, 4.5, 9.0);
    double imgX = pad, imgY = 0.0, imgW = 0.0, imgH = 0.0;
    double tx = pad, availW = w - 2.0 * pad;
    double textRegionY = 0.0, textRegionH = h;

    if (horizontal) {
        if (hasImage) {
            imgH = std::max(8.0, h - 2.0 * pad);
            imgW = imgH * c.sigAspect;
            const double maxW = std::max(8.0, w * 0.45);  // leave room for text
            if (imgW > maxW) { imgW = maxW; imgH = imgW / c.sigAspect; }
        } else {
            imgH = imgW = std::clamp(h - 2.0 * pad, 16.0, 40.0);  // badge slot
        }
        imgY = (h - imgH) / 2.0;
        tx = pad + imgW + pad;
        availW = w - tx - pad;
    } else {
        imgH = hasImage ? std::min(h * 0.45, (w - 2.0 * pad) / c.sigAspect)
                        : std::clamp(std::min(h * 0.45, w - 2.0 * pad), 12.0, 40.0);
        imgW = hasImage ? imgH * c.sigAspect : imgH;
        imgX = (w - imgW) / 2.0;
        imgY = h - pad - imgH;                      // graphic hugs the top
        textRegionY = pad;
        textRegionH = std::max(0.0, imgY - pad - pad);
        fs1 = std::clamp(textRegionH * 0.34, 5.0, 11.0);
        fs2 = std::clamp(fs1 * 0.82, 4.5, 9.0);
    }

    // Shrink fonts if the longest line would overflow the available width.
    double maxLineW = WidthOf(bold, c.line1, fs1);
    for (size_t i = 0; i < c.sub.size(); i++)
        maxLineW = std::max(maxLineW, WidthOf(*subFonts[i], c.sub[i], fs2));
    if (maxLineW > availW && maxLineW > 0.0) {
        const double scale = availW / maxLineW;
        fs1 = std::max(3.0, fs1 * scale);  // past ~3pt it clips at the border
        fs2 = std::max(3.0, fs2 * scale);
    }

    // Graphic: signature image, or the seal badge (SF Symbol, vector fallback).
    if (hasImage) {
        painter.DrawImage(*c.sigImage, imgX, imgY,
                          imgW / (double)c.sigImage->GetWidth(),
                          imgH / (double)c.sigImage->GetHeight());
    } else if (c.badge != nullptr) {
        const double sc = imgH / (double)c.badge->GetWidth();
        painter.DrawImage(*c.badge, imgX, imgY, sc, sc);
    } else {  // fallback: green disc + white check
        const double r = imgH / 2.0, cx = imgX + r, cy = imgY + r;
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

    // Text block, centered in its region (whole box when horizontal, below the
    // graphic when vertical).
    const double a1 = fs1 * 0.72, a2 = fs2 * 0.72;  // visual cap heights
    const double gap = 4.0;
    const double blockH = a1 + (double)c.sub.size() * (gap + a2);
    double y = textRegionY + (textRegionH + blockH) / 2.0 - a1;  // baseline of line 1

    auto drawLine = [&](PdfFont &f, const std::string &s, double fs, double baseline) {
        double x = tx;
        if (!horizontal) x = (w - WidthOf(f, s, fs)) / 2.0;  // centered
        painter.TextState.SetFont(f, fs);
        painter.DrawText(s, x, baseline);
    };

    painter.GraphicsState.SetNonStrokingColor(PdfColor(0.10, 0.10, 0.12));
    drawLine(bold, c.line1, fs1, y);

    painter.GraphicsState.SetNonStrokingColor(PdfColor(0.34, 0.36, 0.40));
    for (size_t i = 0; i < c.sub.size(); i++) {
        y -= (gap + a2);
        drawLine(*subFonts[i], c.sub[i], fs2, y);
    }

    painter.FinishDrawing();
    return xobj;
}

/// Plain single-line text (date / free text fields): sized to the box height, shrunk to
/// fit the width, vertically centered, left-aligned. Mirrored by FieldRenderer.drawText.
static std::unique_ptr<PdfXObjectForm> MakeTextXObject(PdfMemDocument &doc, FontPicker &fonts,
                                                        double w, double h, const std::string &text) {
    auto xobj = doc.CreateXObjectForm(PoDoFo::Rect(0.0, 0.0, w, h));
    PdfPainter painter;
    BeginCanvas(painter, *xobj);

    PdfFont &font = fonts.For(text, false);
    const double pad = std::min(2.0, w * 0.05);
    double fs = std::max(3.0, h * 0.62);
    const double tw = WidthOf(font, text, fs);
    if (tw > w - 2.0 * pad && tw > 0.0) fs = std::max(3.0, fs * (w - 2.0 * pad) / tw);
    const double baseline = (h - fs * 0.72) / 2.0;

    painter.GraphicsState.SetNonStrokingColor(PdfColor(0.08, 0.08, 0.10));
    painter.TextState.SetFont(font, fs);
    painter.DrawText(text, pad, baseline);
    painter.FinishDrawing();
    return xobj;
}

static std::unique_ptr<PdfImage> LoadImage(PdfMemDocument &doc, NSData *png) {
    if (png == nil || png.length == 0) return nullptr;
    try {
        auto img = doc.CreateImage();
        img->LoadFromBuffer(bufferview((const char *)png.bytes, (size_t)png.length));
        if (img->GetWidth() > 0 && img->GetHeight() > 0) return img;
    } catch (...) {
    }
    return nullptr;
}

/// How to put a box of content upright on a possibly /Rotate'd page. Content is laid out
/// at its displayed size; @c matrix (the form's /Matrix) turns it against the page
/// rotation, and (@c x, @c y) is where a flattened draw must anchor it so the rotated
/// content lands exactly on @c rect. Everything here is raw (unrotated) page space —
/// PoDoFo's own rotation-aware Rect helpers are bypassed on purpose so widgets and
/// flattened content share one convention with PDFKit.
struct Placement {
    double w, h;     // displayed size = XObject BBox
    Matrix matrix;
    double x, y;     // DrawXObject origin for flattened content
};

static Placement PlacementFor(const PdfPage &page, const CGRect &r) {
    const double minX = CGRectGetMinX(r), minY = CGRectGetMinY(r);
    const double maxX = CGRectGetMaxX(r), maxY = CGRectGetMaxY(r);
    const double W = r.size.width, H = r.size.height;
    // /Rotate turns the page clockwise for display, so content turns counter-clockwise.
    switch (page.GetRotation()) {
        case 90:  return {H, W, Matrix(0, 1, -1, 0, 0, 0), maxX, minY};
        case 180: return {W, H, Matrix(-1, 0, 0, -1, 0, 0), maxX, maxY};
        case 270: return {H, W, Matrix(0, -1, 1, 0, 0, 0), minX, maxY};
        default:  return {W, H, Matrix(), minX, minY};
    }
}

static void ApplyPlacement(PdfXObjectForm &xobj, const Placement &p) {
    if (p.matrix != Matrix()) xobj.SetMatrix(p.matrix);
}

/// Put a stamp on a widget: raw rect + raw appearance, so PoDoFo doesn't re-rotate it.
static void DressWidget(PdfAnnotationWidget &widget, PdfXObjectForm &xobj, const CGRect &r,
                        const std::string &contents, const std::string &pdfDate) {
    widget.SetRectRaw(Corners(CGRectGetMinX(r), CGRectGetMinY(r), CGRectGetMaxX(r), CGRectGetMaxY(r)));
    widget.SetFlags(PdfAnnotationFlags::Print);
    widget.SetAppearanceStreamRaw(xobj);
    // Best-effort metadata so viewers can show a tooltip / date for the annotation.
    widget.SetContents(PdfString(contents));
    widget.GetDictionary().AddKey("M", PdfString(pdfDate));
}

static CGRect RawRect(const PdfAnnotation &a) {
    const PoDoFo::Rect r = PoDoFo::Rect::FromCorners(a.GetRectRaw());  // MacTypes.h has a Rect too
    return CGRectMake(r.X, r.Y, r.Width, r.Height);
}

// MARK: Existing signature fields

struct SigWidget {
    PdfAnnotationWidget *widget;
    unsigned pageIndex;
};

/// One signature field and its widgets. The field is the widget itself when they're
/// merged (the common, Acrobat-made case), else the widgets' /Parent.
struct SigFieldEntry {
    std::string name;
    PdfObject *field;
    std::vector<SigWidget> widgets;
    bool isSigned;
};

static std::string FullFieldName(const PdfObject *obj) {
    std::string name;
    for (int depth = 0; obj != nullptr && depth < 32; depth++) {  // guard against /Parent cycles
        const auto &d = obj->GetDictionary();
        auto t = d.FindKey("T");
        if (t != nullptr && t->IsString()) {
            std::string part(t->GetString().GetString());
            name = name.empty() ? part : part + "." + name;
        }
        obj = d.FindKey("Parent");
    }
    return name;
}

/// Walks the pages' widgets rather than /AcroForm /Fields: real-world PDFs often leave
/// fields out of (or have no) AcroForm, and viewers still show and sign them.
static std::vector<SigFieldEntry> CollectSignatureFields(PdfMemDocument &doc) {
    std::vector<SigFieldEntry> out;
    auto &pages = doc.GetPages();
    for (unsigned i = 0; i < pages.GetCount(); i++) {
        auto &annots = pages.GetPageAt(i).GetAnnotations();
        for (unsigned j = 0; j < annots.GetCount(); j++) {
            PdfAnnotation *a = nullptr;
            try { a = &annots.GetAnnotAt(j); } catch (...) { continue; }  // invalid entries
            if (a->GetType() != PdfAnnotationType::Widget) continue;
            auto &obj = a->GetObject();
            auto &d = obj.GetDictionary();
            auto ft = d.FindKeyParent("FT");
            if (ft == nullptr || !ft->IsName() || ft->GetName() != "Sig") continue;

            PdfObject *field = &obj;
            if (!d.HasKey("T")) {
                if (auto parent = d.FindKey("Parent")) field = parent;
            }
            auto it = std::find_if(out.begin(), out.end(), [&](const SigFieldEntry &e) { return e.field == field; });
            if (it == out.end()) {
                out.push_back({FullFieldName(field), field, {}, field->GetDictionary().HasKey("V")});
                it = out.end() - 1;
            }
            it->widgets.push_back({static_cast<PdfAnnotationWidget *>(a), i});
        }
    }
    return out;
}

/// Viewers only treat fields reachable from /AcroForm /Fields as form fields.
static void EnsureInAcroForm(PdfAcroForm &acro, PdfObject &field) {
    PdfObject *top = &field;
    for (int depth = 0; depth < 32; depth++) {
        auto parent = top->GetDictionary().FindKey("Parent");
        if (parent == nullptr) break;
        top = parent;
    }
    auto &dict = acro.GetDictionary();
    auto fields = dict.FindKey("Fields");
    if (fields == nullptr || !fields->IsArray()) fields = &dict.AddKey("Fields", PdfArray());
    auto &arr = fields->GetArray();
    const auto ref = top->GetIndirectReference();
    for (size_t i = 0; i < arr.size(); i++) {
        if (arr[i].IsReference() && arr[i].GetReference() == ref) return;
    }
    arr.Add(PdfObject(ref));
}

@implementation PDFSignField

- (instancetype)initWithKind:(PDFSignFieldKind)kind
                   pageIndex:(NSInteger)pageIndex
                        rect:(CGRect)rect
                        text:(NSString *)text
               formFieldName:(NSString *)formFieldName {
    if ((self = [super init])) {
        _kind = kind;
        _pageIndex = pageIndex;
        _rect = rect;
        _text = [text copy];
        _formFieldName = [formFieldName copy];
    }
    return self;
}

@end

@interface PDFSignatureFieldInfo ()
- (instancetype)initWithName:(NSString *)name pageIndex:(NSInteger)pageIndex rect:(CGRect)rect isSigned:(BOOL)isSigned;
@end

@implementation PDFSignatureFieldInfo

- (instancetype)initWithName:(NSString *)name pageIndex:(NSInteger)pageIndex rect:(CGRect)rect isSigned:(BOOL)isSigned {
    if ((self = [super init])) {
        _name = [name copy];
        _pageIndex = pageIndex;
        _rect = rect;
        _isSigned = isSigned;
    }
    return self;
}

@end

@implementation PDFSigningEngine

+ (BOOL)signPDFAtURL:(NSURL *)inputURL
           outputURL:(NSURL *)outputURL
              fields:(NSArray<PDFSignField *> *)fields
            identity:(SecIdentityRef)identity
          signerName:(NSString *)signerName
              reason:(NSString *)reason
            location:(NSString *)location
  signatureImagePNG:(NSData *)signatureImagePNG
         includeDate:(BOOL)includeDate
          customText:(NSString *)customText
               error:(NSError *_Nullable *_Nullable)error {
    // One signature field carries the cryptographic signature: the existing form field
    // being filled, else the first one. Validate before touching the keychain or disk.
    PDFSignField *primary = nil;
    NSUInteger targeted = 0;
    for (PDFSignField *f in fields) {
        if (f.kind != PDFSignFieldKindSignature) continue;
        if (f.formFieldName.length) {
            targeted++;
            primary = f;
        } else if (primary == nil) {
            primary = f;
        }
    }
    if (primary == nil) {
        if (error) *error = MakeError(@"Place at least one signature field.");
        return NO;
    }
    if (targeted > 1) {
        // Each form signature field is a separate signature (often another signer's).
        if (error) *error = MakeError(@"Only one existing signature field can be signed at a time.");
        return NO;
    }

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
    NSDateFormatter *nf = [[NSDateFormatter alloc] init];
    nf.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    nf.dateFormat = @"yyyyMMdd-HHmmss";        // unique-ish field name suffix

    // Stamp text: signer name, optional date, optional free-text line.
    NSString *l1 = signerName.length ? [NSString stringWithFormat:@"Signed by %@", signerName]
                                     : @"Digitally signed";
    NSString *l2 = includeDate ? [dateStr stringByAppendingString:@" UTC"] : nil;
    NSString *l3 = customText.length ? customText : nil;
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithObject:l1];
    if (l2) [parts addObject:l2];
    if (l3) [parts addObject:l3];
    NSString *contentsNS = [parts componentsJoinedByString:@" · "];

    std::string pdfDate([pf stringFromDate:now].UTF8String);
    std::string contents(contentsNS.UTF8String);
    // A fixed name like "Signature" collides when re-signing a PDFSign output.
    std::string fieldName(([@"PDFSign-" stringByAppendingString:[nf stringFromDate:now]]).UTF8String);
    NSData *badgePNG = SealBadgePNG(128.0);

    BOOL ok = NO;
    NSString *failMsg = nil;

    try {
        auto stream = std::make_shared<FileStreamDevice>(outputPath, FileMode::Open);
        PdfMemDocument doc(stream);
        const unsigned pageCount = doc.GetPages().GetCount();

        for (PDFSignField *f in fields) {
            if (f.pageIndex < 0 || (unsigned)f.pageIndex >= pageCount)
                throw std::runtime_error("Field page index out of range.");
            if (f.rect.size.width < 1.0 || f.rect.size.height < 1.0)
                throw std::runtime_error("Field rectangle is empty.");
        }

        FontPicker fonts(doc);

        auto sigImg = LoadImage(doc, signatureImagePNG);
        auto badge = sigImg ? nullptr : LoadImage(doc, badgePNG);
        StampContent stamp;
        stamp.line1 = l1.UTF8String;
        if (l2) stamp.sub.push_back(l2.UTF8String);
        if (l3) stamp.sub.push_back(l3.UTF8String);
        stamp.sigImage = sigImg.get();
        stamp.sigAspect = sigImg ? (double)sigImg->GetWidth() / (double)sigImg->GetHeight() : 0.0;
        stamp.badge = badge.get();

        // AcroForm /SigFlags = 3 (signatures exist + append-only) — keeps viewers happy.
        auto &acro = doc.GetOrCreateAcroForm();
        auto &acroDict = acro.GetDictionary();
        if (acroDict.HasKey("SigFlags")) acroDict.RemoveKey("SigFlags");
        acroDict.AddKey("SigFlags", static_cast<int64_t>(3));

        // Stamp XObject laid out at the box's displayed size, turned upright for the page.
        auto stampFor = [&](const PdfPage &page, const CGRect &r) {
            const Placement p = PlacementFor(page, r);
            auto xobj = MakeStampXObject(doc, fonts, p.w, p.h, stamp);
            ApplyPlacement(*xobj, p);
            return xobj;
        };

        // --- The signature field: an existing empty one, or a new widget-less field
        // whose stamps are all its widgets (so every stamp opens the signature panel). ---
        PdfSignature *signature = nullptr;
        bool canAddWidgets = true;
        if (primary.formFieldName.length) {
            const std::string wanted(primary.formFieldName.UTF8String);
            auto entries = CollectSignatureFields(doc);
            auto it = std::find_if(entries.begin(), entries.end(),
                                   [&](const SigFieldEntry &e) { return e.name == wanted; });
            if (it == entries.end()) {
                std::string available;
                for (auto &e : entries) {
                    if (e.isSigned) continue;
                    available += (available.empty() ? "" : ", ") + ("\"" + e.name + "\"");
                }
                throw std::runtime_error("No signature field named \"" + wanted + "\"" +
                    (available.empty() ? " (the document has no empty signature fields)."
                                       : ". Empty signature fields: " + available + "."));
            }
            if (it->isSigned) throw std::runtime_error("The signature field \"" + wanted + "\" is already signed.");

            EnsureInAcroForm(acro, *it->field);
            auto &first = *it->widgets.front().widget;
            if (it->field == &first.GetObject()) {
                // Merged field/widget: PoDoFo can't hang more widgets off it.
                // TODO: split the merged dict into field + kid widget so extra stamps can
                // join this field too; until then they're flattened into the page.
                auto &field = first.GetField();
                if (field.GetType() != PdfFieldType::Signature)
                    throw std::runtime_error("\"" + wanted + "\" is not a signature field.");
                signature = &static_cast<PdfSignature &>(field);
                canAddWidgets = false;
            } else {
                if (it->field->GetDictionary().HasKey("Parent"))
                    // TODO: nested non-terminal signature fields — PoDoFo only resolves a
                    // widget-less signature through the top level of /AcroForm /Fields.
                    throw std::runtime_error("The signature field \"" + wanted +
                                             "\" is nested in a way PDFSign can't sign yet.");
                signature = &static_cast<PdfSignature &>(acro.GetField(it->field->GetIndirectReference()));
            }
            // The form decides where this one goes; stamp each of its widgets.
            for (auto &w : it->widgets) {
                auto &page = doc.GetPages().GetPageAt(w.pageIndex);
                const CGRect r = RawRect(*w.widget);
                auto xobj = stampFor(page, r);
                DressWidget(*w.widget, *xobj, r, contents, pdfDate);
            }
        } else {
            signature = &acro.CreateField<PdfSignature>(fieldName);
        }

        // --- Secondary elements. Signature stamps become more widgets of the one field;
        // dates/text (and stamps that can't be widgets) are flattened into page content. ---
        std::map<NSInteger, std::vector<std::tuple<std::unique_ptr<PdfXObjectForm>, double, double>>> flat;
        for (PDFSignField *f in fields) {
            if (f == primary && primary.formFieldName.length) continue;  // already stamped above
            auto &page = doc.GetPages().GetPageAt((unsigned)f.pageIndex);
            const Placement p = PlacementFor(page, f.rect);
            std::unique_ptr<PdfXObjectForm> xobj;
            if (f.kind == PDFSignFieldKindSignature) {
                xobj = stampFor(page, f.rect);
                if (canAddWidgets) {
                    // TODO: multi-widget signatures check out in pdfsig/poppler/PDFKit; confirm
                    // Acrobat shows every widget as signed before relying on it for clients.
                    auto &child = signature->GetChildren().CreateChild(page, PoDoFo::Rect(0, 0, 1, 1));
                    DressWidget(child.MustGetWidget(), *xobj, f.rect, contents, pdfDate);
                    continue;
                }
            } else {
                if (f.text.length == 0) continue;
                xobj = MakeTextXObject(doc, fonts, p.w, p.h, std::string(f.text.UTF8String));
                ApplyPlacement(*xobj, p);
            }
            flat[f.pageIndex].emplace_back(std::move(xobj), p.x, p.y);
        }
        for (auto &[pageIndex, items] : flat) {
            PdfPainter painter;
            painter.SetCanvas(doc.GetPages().GetPageAt((unsigned)pageIndex));  // wraps prior content in q/Q
            for (auto &[xobj, x, y] : items) painter.DrawXObject(*xobj, x, y);  // Do applies the /Matrix
            painter.FinishDrawing();
        }

        if (signerName.length) signature->SetSignerName(PdfString(std::string(signerName.UTF8String)));
        if (reason.length) signature->SetSignatureReason(PdfString(std::string(reason.UTF8String)));
        if (location.length) signature->SetSignatureLocation(PdfString(std::string(location.UTF8String)));
        signature->SetSignatureDate(PdfDate::UtcNow());  // PdfDate() defaults to the epoch

        // CMS signer: PoDoFo builds the container, the Keychain key does the raw signature.
        PdfSignerCmsParams params;
        // Stamp the CMS signing-time attribute (otherwise it defaults to the epoch).
        params.SigningTimeUTC = std::chrono::seconds((long long)[now timeIntervalSince1970]);
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
        PoDoFo::SignDocument(doc, *stream, signer, *signature, PdfSaveOptions::NoMetadataUpdate);
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

+ (NSArray<PDFSignatureFieldInfo *> *)signatureFieldsInPDFAtURL:(NSURL *)url error:(NSError **)error {
    try {
        PdfMemDocument doc;
        doc.Load(std::string(url.path.UTF8String));
        NSMutableArray<PDFSignatureFieldInfo *> *out = [NSMutableArray array];
        for (auto &e : CollectSignatureFields(doc)) {
            const auto &w = e.widgets.front();
            [out addObject:[[PDFSignatureFieldInfo alloc] initWithName:([NSString stringWithUTF8String:e.name.c_str()] ?: @"")
                                                             pageIndex:(NSInteger)w.pageIndex
                                                                  rect:RawRect(*w.widget)
                                                              isSigned:e.isSigned]];
        }
        return out;
    } catch (const std::exception &e) {
        if (error) *error = MakeError([NSString stringWithUTF8String:e.what()]);
    } catch (...) {
        if (error) *error = MakeError(@"Could not read the document's form fields.");
    }
    return nil;
}

@end

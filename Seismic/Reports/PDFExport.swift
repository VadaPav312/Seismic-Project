import Foundation
import SwiftUI
import UIKit
import SeismicCore

/// Renders a report as a real PDF.
///
/// Drawn with Core Text rather than snapshotted from the screen, for three
/// reasons that all matter for a document somebody may hand to an insurer: the
/// text stays selectable and searchable, it paginates properly instead of being
/// cut mid-line, and it prints black-on-white rather than reproducing a dark
/// interface as a page of ink.
enum PDFExport {

    static let pageSize = CGSize(width: 595.2, height: 841.8)   // A4 at 72 dpi
    static let margin: CGFloat = 56

    // MARK: Type

    private enum Style {
        static let title = UIFont.systemFont(ofSize: 22, weight: .semibold)
        static let heading = UIFont.systemFont(ofSize: 13, weight: .semibold)
        static let body = UIFont.systemFont(ofSize: 10.5, weight: .regular)
        static let mono = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        static let caption = UIFont.systemFont(ofSize: 8.5, weight: .regular)

        static let ink = UIColor(white: 0.10, alpha: 1)
        static let inkSecondary = UIColor(white: 0.35, alpha: 1)
        static let rule = UIColor(white: 0.80, alpha: 1)
    }

    /// The verdict block is the one thing on the page that keeps its colour,
    /// because the colour is load-bearing information and the placard is the
    /// reason the document exists. Everything else prints as ink.
    private static func verdictColour(_ verdict: SafetyVerdict) -> UIColor {
        switch verdict {
        case .green: UIColor(red: 0.16, green: 0.55, blue: 0.30, alpha: 1)
        case .amber: UIColor(red: 0.72, green: 0.50, blue: 0.06, alpha: 1)
        case .red: UIColor(red: 0.72, green: 0.16, blue: 0.14, alpha: 1)
        case .needsInspection: UIColor(white: 0.35, alpha: 1)
        }
    }

    // MARK: Rendering

    static func render(assessment: Assessment, building: BuildingModel,
                       format: ReportPreviewSheet.ReportFormat) -> Data {
        let pages = ReportBuilder.pages(assessment: assessment, building: building,
                                        format: format)
        let metadata: [String: Any] = [
            kCGPDFContextTitle as String: "Seismic assessment — \(building.name)",
            kCGPDFContextAuthor as String: "Seismic",
            kCGPDFContextCreator as String: "Seismic for iOS",
            kCGPDFContextSubject as String: assessment.verdict.placard,
        ]
        let renderFormat = UIGraphicsPDFRendererFormat()
        renderFormat.documentInfo = metadata

        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize),
                                             format: renderFormat)

        return renderer.pdfData { context in
            var pageNumber = 0

            func newPage() -> CGFloat {
                context.beginPage()
                pageNumber += 1
                return drawPageFurniture(building: building, assessment: assessment,
                                         pageNumber: pageNumber)
            }

            var y = newPage()
            y = drawVerdictBlock(assessment: assessment, building: building, at: y)

            for page in pages {
                if y > pageSize.height - 200 { y = newPage() }

                y = draw(page.title, font: Style.title, colour: Style.ink, at: y, spacingAfter: 4)
                y = drawRule(at: y)

                for section in page.sections {
                    // A heading orphaned at the foot of a page is the classic
                    // generated-PDF tell, so it moves with its first lines.
                    if y > pageSize.height - 140 { y = newPage() }

                    y = draw(section.heading, font: Style.heading, colour: Style.ink,
                             at: y, spacingAfter: 3)

                    if !section.body.isEmpty {
                        y = drawWrapped(section.body, font: Style.body, colour: Style.inkSecondary,
                                        at: y, newPage: { y = newPage(); return y })
                    }

                    for (label, value) in section.rows {
                        if y > pageSize.height - margin - 20 { y = newPage() }
                        y = drawRow(label: label, value: value, at: y)
                    }
                    y += 14
                }
            }

            // The footer that makes the document honest about what it is.
            if y > pageSize.height - 120 { y = newPage() }
            y += 8
            y = drawRule(at: y)
            _ = drawWrapped(Assessment.disclaimer, font: Style.caption,
                            colour: Style.inkSecondary, at: y,
                            newPage: { y = newPage(); return y })
        }
    }

    // MARK: Drawing primitives

    private static func drawPageFurniture(building: BuildingModel, assessment: Assessment,
                                          pageNumber: Int) -> CGFloat {
        let header = "SEISMIC · \(building.name)"
        header.draw(at: CGPoint(x: margin, y: 28),
                    withAttributes: [.font: Style.caption, .foregroundColor: Style.inkSecondary])

        let stamp = assessment.createdAt.formatted(date: .abbreviated, time: .shortened)
        let stampSize = stamp.size(withAttributes: [.font: Style.caption])
        stamp.draw(at: CGPoint(x: pageSize.width - margin - stampSize.width, y: 28),
                   withAttributes: [.font: Style.caption, .foregroundColor: Style.inkSecondary])

        let footer = "Page \(pageNumber)"
        let footerSize = footer.size(withAttributes: [.font: Style.caption])
        footer.draw(at: CGPoint(x: (pageSize.width - footerSize.width) / 2,
                                y: pageSize.height - 34),
                    withAttributes: [.font: Style.caption, .foregroundColor: Style.inkSecondary])

        return 56
    }

    /// The placard, reproduced at the top of page one at a size that survives a
    /// photocopy and a glance across a room.
    private static func drawVerdictBlock(assessment: Assessment, building: BuildingModel,
                                         at y: CGFloat) -> CGFloat {
        let colour = verdictColour(assessment.verdict)
        let rect = CGRect(x: margin, y: y, width: pageSize.width - margin * 2, height: 64)
        let path = UIBezierPath(roundedRect: rect, cornerRadius: 6)
        colour.withAlphaComponent(0.10).setFill()
        path.fill()
        colour.setStroke()
        path.lineWidth = 2
        path.stroke()

        let placard = assessment.verdict.placard
        placard.draw(at: CGPoint(x: margin + 16, y: y + 12),
                     withAttributes: [.font: UIFont.systemFont(ofSize: 20, weight: .bold),
                                      .foregroundColor: colour])

        let probability = Int((assessment.damageProbability * 100).rounded())
        let low = Int(assessment.confidenceInterval.lowerBound * 100)
        let high = Int(assessment.confidenceInterval.upperBound * 100)
        let detail = "Probability of structural change \(probability)% "
                   + "(plausible range \(low)–\(high)%)"
        detail.draw(at: CGPoint(x: margin + 16, y: y + 40),
                    withAttributes: [.font: Style.body, .foregroundColor: Style.inkSecondary])

        return y + 84
    }

    @discardableResult
    private static func draw(_ text: String, font: UIFont, colour: UIColor,
                             at y: CGFloat, spacingAfter: CGFloat = 6) -> CGFloat {
        text.draw(at: CGPoint(x: margin, y: y),
                  withAttributes: [.font: font, .foregroundColor: colour])
        return y + font.lineHeight + spacingAfter
    }

    private static func drawRule(at y: CGFloat) -> CGFloat {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: margin, y: y))
        path.addLine(to: CGPoint(x: pageSize.width - margin, y: y))
        Style.rule.setStroke()
        path.lineWidth = 0.5
        path.stroke()
        return y + 10
    }

    /// Wraps a paragraph to the text column, breaking across pages where it
    /// has to rather than running off the bottom.
    private static func drawWrapped(_ text: String, font: UIFont, colour: UIColor,
                                    at y: CGFloat,
                                    newPage: () -> CGFloat) -> CGFloat {
        let width = pageSize.width - margin * 2
        var cursor = y
        var remaining = text[...]

        while !remaining.isEmpty {
            let available = pageSize.height - margin - 20 - cursor
            if available < font.lineHeight * 2 {
                cursor = newPage()
                continue
            }

            let attributed = NSAttributedString(
                string: String(remaining),
                attributes: [.font: font, .foregroundColor: colour])
            let framesetter = CTFramesetterCreateWithAttributedString(attributed)
            let constraint = CGSize(width: width, height: available)
            var fitRange = CFRange()
            _ = CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter, CFRange(location: 0, length: 0), nil, constraint, &fitRange)

            let drawnLength = max(Int(fitRange.length), 1)
            let endIndex = remaining.index(remaining.startIndex, offsetBy: drawnLength,
                                           limitedBy: remaining.endIndex) ?? remaining.endIndex
            let chunk = String(remaining[remaining.startIndex..<endIndex])

            let rect = CGRect(x: margin, y: cursor, width: width, height: available)
            (chunk as NSString).draw(
                in: rect,
                withAttributes: [.font: font, .foregroundColor: colour])

            let used = (chunk as NSString).boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font], context: nil).height

            cursor += used + 8
            remaining = remaining[endIndex...]
            if endIndex == remaining.endIndex { break }
        }
        return cursor
    }

    /// A label-and-value row, dot-led so the eye can track across the page.
    private static func drawRow(label: String, value: String, at y: CGFloat) -> CGFloat {
        label.draw(at: CGPoint(x: margin + 8, y: y),
                   withAttributes: [.font: Style.body, .foregroundColor: Style.inkSecondary])

        let attributes: [NSAttributedString.Key: Any] = [.font: Style.mono,
                                                         .foregroundColor: Style.ink]
        let size = value.size(withAttributes: attributes)
        value.draw(at: CGPoint(x: pageSize.width - margin - size.width, y: y),
                   withAttributes: attributes)

        return y + Style.body.lineHeight + 3
    }

    // MARK: File output

    /// Writes the PDF to a temporary file so it can be shared, printed or saved
    /// with a real filename rather than "Document.pdf".
    static func writeToTemporaryFile(assessment: Assessment, building: BuildingModel,
                                     format: ReportPreviewSheet.ReportFormat) -> URL? {
        let data = render(assessment: assessment, building: building, format: format)
        let safeName = building.name
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let stamp = assessment.createdAt.formatted(.iso8601.year().month().day())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Seismic-\(safeName)-\(stamp).pdf")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

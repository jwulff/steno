import Foundation

/// Exports transcript sessions to Markdown format.
public enum MarkdownExport {
    /// Export errors.
    public enum ExportError: Error {
        case sessionNotFound
    }

    /// Export a session with its segments and summaries to Markdown.
    ///
    /// - Parameters:
    ///   - session: The session to export.
    ///   - segments: The transcript segments.
    ///   - summaries: Any generated summaries.
    /// - Returns: A formatted Markdown string.
    public static func export(
        session: Session,
        segments: [StoredSegment],
        summaries: [Summary]
    ) -> String {
        var markdown = "# \(session.title ?? "Transcript")\n\n"
        markdown += "**Date:** \(formatDate(session.startedAt))\n"

        if let endedAt = session.endedAt {
            markdown += "**Duration:** \(formatDuration(from: session.startedAt, to: endedAt))\n"
        }
        markdown += "\n"

        if let latestSummary = summaries.last {
            markdown += "## Summary\n\n"
            markdown += latestSummary.content
            markdown += "\n\n"
        }

        markdown += "## Transcript\n\n"

        for segment in segments {
            let timestamp = formatTimestamp(segment.startedAt, relativeTo: session.startedAt)
            markdown += "**[\(timestamp)]** \(segment.text)\n\n"
        }

        return markdown
    }

    // MARK: - Private Helpers

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func formatDuration(from start: Date, to end: Date) -> String {
        let interval = end.timeIntervalSince(start)
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private static func formatTimestamp(_ date: Date, relativeTo start: Date) -> String {
        let interval = date.timeIntervalSince(start)
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

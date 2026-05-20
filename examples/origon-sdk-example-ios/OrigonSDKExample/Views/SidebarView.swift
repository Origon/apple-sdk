import SwiftUI
import OrigonSDK

// Sidebar drawer hosted by RootChatView. Shows the wordmark at the top,
// the session history grouped by day, and a footer with a "Change
// Endpoint" action that pops back to EndpointView.

struct SidebarView: View {
    @EnvironmentObject var sdk: SDKManager

    @Binding var selectedSessionId: String?
    let onSessionPicked: (String) -> Void
    let onChangeEndpoint: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image("OrigonWordmark")
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 28)
                    .foregroundColor(Origon.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 36)

            // Session list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(groupedSessions, id: \.title) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.title)
                                .font(.caption.weight(.semibold))
                                .foregroundColor(Origon.textTertiary)
                                .padding(.horizontal, 12)
                                .padding(.bottom, 4)

                            ForEach(group.sessions, id: \.sessionId) { session in
                                sessionRow(session)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }

            Spacer(minLength: 0)

            footer
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func sessionRow(_ session: SessionSummary) -> some View {
        let isSelected = session.sessionId == selectedSessionId
        Button {
            onSessionPicked(session.sessionId)
        } label: {
            Text(session.subject.isEmpty ? "Untitled" : session.subject)
                .font(.body)
                .foregroundColor(Origon.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
                .background(isSelected ? Origon.surface : Color.clear)
                .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Footer

    private var footer: some View {
        Menu {
            Button(role: .destructive) {
                onChangeEndpoint()
            } label: {
                Label("Change Endpoint", systemImage: "rectangle.portrait.and.arrow.right")
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "ellipsis.circle")
                    .font(.body)
                Text("Options")
                    .font(.body.weight(.medium))
                Spacer()
            }
            .foregroundColor(Origon.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    // MARK: - Grouping

    private struct SessionGroup {
        let title: String
        let sessions: [SessionSummary]
    }

    private var groupedSessions: [SessionGroup] {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        var todayBucket: [SessionSummary] = []
        var yesterdayBucket: [SessionSummary] = []
        var earlierByDay: [(day: Date, sessions: [SessionSummary])] = []

        for session in sdk.sessions {
            guard let date = parseISO(session.updatedAt) else { continue }
            let day = calendar.startOfDay(for: date)
            if day == today {
                todayBucket.append(session)
            } else if day == yesterday {
                yesterdayBucket.append(session)
            } else {
                if let idx = earlierByDay.firstIndex(where: { $0.day == day }) {
                    earlierByDay[idx].sessions.append(session)
                } else {
                    earlierByDay.append((day, [session]))
                }
            }
        }

        var groups: [SessionGroup] = []
        if !todayBucket.isEmpty { groups.append(SessionGroup(title: "TODAY", sessions: todayBucket)) }
        if !yesterdayBucket.isEmpty { groups.append(SessionGroup(title: "YESTERDAY", sessions: yesterdayBucket)) }

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "MMM d"
        for entry in earlierByDay.sorted(by: { $0.day > $1.day }) {
            groups.append(SessionGroup(
                title: dayFormatter.string(from: entry.day).uppercased(),
                sessions: entry.sessions
            ))
        }
        return groups
    }

    private func parseISO(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = formatter.date(from: string) { return d }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

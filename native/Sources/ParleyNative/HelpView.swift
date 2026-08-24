import ParleyCore
import SwiftUI

struct HelpView: View {
    @ObservedObject var model: AppModel
    @State private var query = ""
    @State private var selectedTopicID: String? = ParleyHelpGuide.topics.first?.id

    private var topics: [ParleyHelpTopic] {
        ParleyHelpGuide.matching(query)
    }

    private var selectedTopic: ParleyHelpTopic? {
        if let selectedTopicID,
           let selected = topics.first(where: { $0.id == selectedTopicID }) {
            return selected
        }
        return topics.first
    }

    var body: some View {
        VStack(spacing: 0) {
            RuntimeBanner(runtime: model.runtime)
            if model.runtime.visibleMarker != nil { Divider() }
            NavigationSplitView {
                List(topics, selection: $selectedTopicID) { topic in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(topic.title)
                            .font(.system(size: 12, weight: .medium))
                        Text(topic.summary)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                } icon: {
                    Image(systemName: topic.symbol)
                        .foregroundStyle(Color.accentColor)
                }
                .tag(topic.id)
                .padding(.vertical, 3)
            }
            .navigationTitle("Parley Help")
            .navigationSplitViewColumnWidth(min: 230, ideal: 275, max: 340)
            .searchable(text: $query, placement: .sidebar, prompt: "Search help")
                .overlay {
                    if topics.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                }
            } detail: {
                if let topic = selectedTopic {
                    HelpTopicView(topic: topic)
                        .id(topic.id)
                } else {
                    ContentUnavailableView(
                        "No matching help",
                        systemImage: "questionmark.circle",
                        description: Text("Try a command name such as Ask, recipe, permission or workspace.")
                    )
                }
            }
        }
        .frame(minWidth: 820, minHeight: 590)
        .onAppear { selectRequestedTopic() }
        .onChange(of: model.requestedHelpTopicID) { _, _ in selectRequestedTopic() }
        .onChange(of: query) { _, _ in
            if let selectedTopicID,
               topics.contains(where: { $0.id == selectedTopicID }) {
                return
            }
            selectedTopicID = topics.first?.id
        }
    }

    private func selectRequestedTopic() {
        guard let requested = model.requestedHelpTopicID,
              ParleyHelpGuide.topics.contains(where: { $0.id == requested }) else { return }
        query = ""
        selectedTopicID = requested
    }
}

private struct HelpTopicView: View {
    let topic: ParleyHelpTopic

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                ForEach(topic.sections) { section in
                    HelpSectionView(section: section)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 34)
            .padding(.vertical, 30)
        }
        .navigationTitle(topic.title)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: topic.symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(topic.title)
                    .font(.system(size: 23, weight: .semibold))
                Text(topic.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct HelpSectionView: View {
    let section: ParleyHelpSection

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(section.title)
                .font(.system(size: 15, weight: .semibold))
                .accessibilityAddTraits(.isHeader)

            ForEach(Array(section.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if !section.items.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("•")
                                .foregroundStyle(Color.accentColor)
                                .accessibilityHidden(true)
                            Text(item)
                                .font(.system(size: 12))
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            ForEach(Array(section.commands.enumerated()), id: \.offset) { _, command in
                VStack(alignment: .leading, spacing: 6) {
                    Text(command.command)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .overlay {
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                        }
                    Text(command.explanation)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .contain)
            }
        }
    }
}

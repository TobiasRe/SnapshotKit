import AppKit
import Foundation
import Observation
import SnapshotKitCore

/// The CI jobs the sidebar lists, and how they group: read-only, from what the model has loaded and detected.
extension ProjectModel {
    /// A pipeline loaded by its URL, with its failed jobs.
    struct CIPipeline: Equatable {
        var project: GitLabLink
        var id: Int
        var failedJobs: [GitLabJob]
    }

    /// The branch's failed jobs not loaded yet.
    var offeredCIJobs: [GitLabJob] { (ciDetection?.failedJobs ?? []).filter { failureSets[.ciJob($0.id)] == nil } }

    /// A CI job the sidebar lists: one of the branch's failed jobs, or one loaded.
    func ciJob(_ id: Int) -> GitLabJob? {
        failureSets[.ciJob(id)]?.job ?? ciDetection?.failedJobs.first { $0.id == id }
            ?? ciPipelines.lazy.flatMap(\.failedJobs).first { $0.id == id }
    }

    /// The jobs of one merge request or pipeline, under its label in the sidebar's CI section.
    struct CIJobGroup: Identifiable {
        var mergeRequest: GitLabMergeRequest?
        /// A pipeline loaded by its URL, for its jobs.
        var pipeline: Int?
        var jobs: [GitLabJob]
        /// "!12 · Checkout redesign", "Pipeline #89", or "Other Jobs" for jobs loaded without either.
        var title: String {
            mergeRequest.map { "!\($0.iid) · \($0.title)" } ?? pipeline.map { "Pipeline #\($0)" } ?? "Other Jobs"
        }
        var id: String { mergeRequest.map { "!\($0.iid)" } ?? pipeline.map { "#\($0)" } ?? "" }
    }

    /// The branch's merge request with its failed jobs and any loaded since; then jobs loaded for
    /// other merge requests, each under its own.
    var ciJobGroups: [CIJobGroup] {
        let loaded = failureSets.values.compactMap { set in set.job.map { (job: $0, mergeRequest: set.mergeRequest) } }
            .sorted { $0.job.id < $1.job.id }
        var groups: [CIJobGroup] = []
        var others = loaded
        if let detection = ciDetection {
            let iid = detection.mergeRequest.iid, failed = Set(detection.failedJobs.map(\.id))
            let extra = loaded.filter { $0.mergeRequest?.iid == iid && !failed.contains($0.job.id) }
            // The branch's jobs are listed here only, whatever their load said of their merge request.
            others.removeAll { $0.mergeRequest?.iid == iid || failed.contains($0.job.id) }
            let jobs = detection.failedJobs + extra.map(\.job)
            if !jobs.isEmpty { groups.append(CIJobGroup(mergeRequest: detection.mergeRequest, jobs: jobs)) }
        }
        // Pipelines loaded by their URL, each with its jobs, loaded or not; one the branch's request lists is there already.
        for pipeline in ciPipelines {
            let listed = Set(groups.flatMap(\.jobs).map(\.id))
            let jobs = pipeline.failedJobs.filter { !listed.contains($0.id) }
            others.removeAll { loaded in pipeline.failedJobs.contains { $0.id == loaded.job.id } }
            if !jobs.isEmpty { groups.append(CIJobGroup(pipeline: pipeline.id, jobs: jobs)) }
        }
        let byRequest = Dictionary(grouping: others) { $0.mergeRequest?.iid }
        for iid in byRequest.keys.sorted(by: { ($0 ?? .max) < ($1 ?? .max) }) {
            let jobs = byRequest[iid] ?? []
            groups.append(CIJobGroup(mergeRequest: jobs.first?.mergeRequest, jobs: jobs.map(\.job)))
        }
        return groups
    }

    /// A CI login a loaded job suggests instead of the one set, and the job: its runner refused the login, or the
    /// login can't read the images, which are another user's.
    var suggestedCILogin: (login: String, job: GitLabJob)? {
        for set in failureSets.values.sorted(by: { ($0.job?.id ?? 0) > ($1.job?.id ?? 0) }) {
            guard let job = set.job else { continue }
            for fix in set.source?.fixes ?? [] {
                if case .useLogin(let login) = fix, login != settings.ciLogin { return (login, job) }
            }
        }
        return nil
    }
}

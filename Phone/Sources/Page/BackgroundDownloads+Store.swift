import Foundation

extension BackgroundDownloads {
    /// Yab's one background session, filling the shared store. Made at launch
    /// (YabPhoneApp) and when iOS launches Yab for the session's events, a
    /// window or not.
    static let shared: BackgroundDownloads = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("yab-background-downloads", isDirectory: true)
        return BackgroundDownloads(configuration: configuration(),
                                   ledger: support.appendingPathComponent("yab-background-downloads.json"),
                                   staging: staging, sink: DownloadStore.shared.backgroundSink)
    }()
}

extension DownloadStore {
    /// The rows of the system's transfers, which are never private.
    var backgroundSink: BackgroundDownloads.Sink {
        BackgroundDownloads.Sink(
            begin: { [weak self] record, stop in
                self?.begin(record.id, name: PageDownload.filename(record.name), host: record.host, total: record.total,
                            isPrivate: false, control: .init(stop: stop, retry: nil))
            },
            progress: { [weak self] id, received, total in self?.progress(id, received: received, total: total) },
            finish: { [weak self] record, file in
                guard let self else { return false }
                self.ensure(record)
                let moved = self.finish(record.id, from: file)
                Haptics.play(moved ? .success : .error, reason: moved ? Haptics.Reason.downloadReady : Haptics.Reason.downloadFailed)
                return moved
            },
            fail: { [weak self] record, retry in
                guard let self else { return }
                self.ensure(record)
                Haptics.play(.error, reason: Haptics.Reason.downloadFailed)
                self.fail(record.id, retry: retry)
            },
            drop: { [weak self] id in self?.drop(id) })
    }

    /// A transfer that ended while Yab was gone has no row yet.
    private func ensure(_ record: BackgroundTransfer.Record) {
        guard entry(record.id) == nil else { return }
        begin(record.id, name: PageDownload.filename(record.name), host: record.host, total: record.total,
              isPrivate: false, control: .init())
    }
}

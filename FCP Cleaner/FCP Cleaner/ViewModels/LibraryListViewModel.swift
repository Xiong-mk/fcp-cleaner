// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Steve

import Foundation
import Observation

nonisolated struct CleanupConfirmation: Identifiable, Sendable {
    let id = UUID()
    let previewID: UUID
    let folderID: UUID
    let parentURL: URL
    let requests: [CleanupRequest]
    let estimatedBytes: Int64
}

@MainActor
@Observable
final class LibraryListViewModel {
    private(set) var scanResults: [UUID: ParentScanResult] = [:]
    private(set) var isScanning = false
    private(set) var hasScanned = false
    private(set) var scanLogURL: URL?
    private(set) var scanLogError: String?
    private(set) var isPreparingPreview = false
    var cleanupPreview: CleanupPreview?
    var cleanupConfirmation: CleanupConfirmation?
    private(set) var isPreparingCleanup = false
    private(set) var isCleaning = false
    private(set) var isRescanningAfterCleanup = false
    private(set) var cleanupEntries: [CleanupLogEntry] = []
    private(set) var cleanupReport: CleanupReport?
    let folderStore: AuthorizedFolderStore
    private let chooseFolder: @MainActor () -> URL?
    private let scanner: any LibraryScanning
    private let dryRunCleaner: any DryRunCleaning
    private let finalCut: any FinalCutChecking
    private let executor: any CleanupExecuting
    private let scanLogger: any ScanDiagnosticLogging
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanGeneration = UUID()
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var previewGeneration = UUID()
    @ObservationIgnored private var previewFolderID: UUID?
    @ObservationIgnored private var preparationTask: Task<Void, Never>?
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?
    var notice: Notice?

    var libraries: [Library] {
        folderStore.folders.flatMap { scanResults[$0.id]?.libraries ?? [] }
    }

    var hasScanIssues: Bool { scanResults.values.contains(where: \.hasIssues) }

    init(
        folderStore: AuthorizedFolderStore? = nil,
        chooseFolder: @escaping @MainActor () -> URL? = FolderPicker.chooseLibraryParentFolder,
        scanner: any LibraryScanning = LibraryScanner(),
        dryRunCleaner: any DryRunCleaning = DryRunCleaner(),
        finalCut: any FinalCutChecking = SystemFinalCutChecker(),
        executor: (any CleanupExecuting)? = nil,
        scanLogger: (any ScanDiagnosticLogging)? = nil
    ) {
        self.folderStore = folderStore ?? AuthorizedFolderStore()
        self.chooseFolder = chooseFolder
        self.scanner = scanner
        self.dryRunCleaner = dryRunCleaner
        self.finalCut = finalCut
        self.executor = executor ?? CleanupExecutor(finalCut: finalCut)
        self.scanLogger = scanLogger ?? JSONScanDiagnosticLogger()
    }

    func addLibrary() {
        selectFolder(replacing: nil)
    }

    func reauthorizeFolder(id: UUID) {
        selectFolder(replacing: id)
    }

    private func selectFolder(replacing id: UUID?) {
        guard !isCleaning else { return }
        guard let folderURL = chooseFolder() else {
            // 取消时不修改已有选择、资源库列表或提示状态。
            return
        }

        do {
            if try folderStore.add(folderURL, replacing: id) == .duplicate {
                notice = Notice(title: "文件夹已添加", message: "该真实路径已有授权记录，无需重复添加。")
            } else {
                rescan()
            }
        } catch {
            notice = Notice(
                title: "文件夹授权失败",
                message: "未保存此次选择：\(error.localizedDescription)\n请检查目录或磁盘是否可用，然后重新选择。"
            )
        }
    }

    func removeFolder(id: UUID) {
        guard !isCleaning else { return }
        do {
            try folderStore.remove(id: id)
            rescan()
        } catch {
            notice = Notice(title: "移除授权失败", message: "授权记录已保留：\(error.localizedDescription)")
        }
    }

    func rescan() {
        guard !isCleaning else { return }
        scanAuthorizedFolders()
    }

    private func scanAuthorizedFolders() {
        let startedAt = Date()
        cancelPreview()
        scanTask?.cancel()
        let generation = UUID()
        scanGeneration = generation
        scanResults = [:]
        hasScanned = false
        var accesses: [UUID: FolderScanAccess] = [:]
        var initialResults: [UUID: ParentScanResult] = [:]
        for folder in folderStore.folders {
            do {
                accesses[folder.id] = try folderStore.makeScanAccess(for: folder.id)
            } catch {
                initialResults[folder.id] = ParentScanResult(libraries: [], issues: [
                    ScanIssue(url: URL(fileURLWithPath: folder.path), reason: folder.url == nil ? .unavailable : .permission,
                              detail: folder.accessError ?? error.localizedDescription)
                ])
            }
        }
        scanResults = initialResults
        isScanning = !accesses.isEmpty
        guard !accesses.isEmpty else {
            hasScanned = true
            scanTask = nil
            writeScanLog(startedAt: startedAt)
            return
        }
        let inputs = accesses.map { (id: $0.key, url: $0.value.url) }
        let scanner = scanner
        // 只有 URL 和只读扫描器进入后台任务；授权租约留在主 actor，直到后台真正退出。
        scanTask = Task { [weak self, accesses, initialResults] in
            defer { for access in accesses.values { access.close() } }
            let worker = Task.detached(priority: .utility) {
                var results = initialResults
                for input in inputs {
                    try Task.checkCancellation()
                    do {
                        results[input.id] = try scanner.scanParent(input.url)
                    } catch {
                        if error is CancellationError { throw error }
                        results[input.id] = ParentScanResult(libraries: [], issues: [.reading(input.url, error: error)])
                    }
                }
                return results
            }
            let result = await withTaskCancellationHandler {
                await worker.result
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, let self, self.scanGeneration == generation else { return }
            switch result {
            case .success(let results):
                self.scanResults = results
            case .failure(let error):
                // 扫描器异常退出也必须留下失败状态，不能落到空结果。
                for input in inputs {
                    self.scanResults[input.id] = ParentScanResult(libraries: [], issues: [.reading(input.url, error: error)])
                }
            }
            self.isScanning = false
            self.hasScanned = true
            self.writeScanLog(startedAt: startedAt)
            self.scanTask = nil
        }
    }

    private func writeScanLog(startedAt: Date) {
        do {
            scanLogURL = try scanLogger.write(
                results: scanResults,
                folderPaths: Dictionary(uniqueKeysWithValues: folderStore.folders.map { ($0.id, $0.path) }),
                startedAt: startedAt
            )
            scanLogError = nil
        } catch {
            // 诊断写入失败不能把只读扫描结果改成失败或伪造日志成功。
            scanLogURL = nil
            scanLogError = "扫描日志写入失败：\(error.localizedDescription)"
        }
    }

    func startScanningIfNeeded() {
        guard !didStart else { return }
        didStart = true
        rescan()
    }

    func retryFolderAccess() {
        guard !isCleaning else { return }
        folderStore.restore()
        rescan()
    }

    func cancelScan() {
        guard !isCleaning else { return }
        cancelPreview()
        scanTask?.cancel()
        scanGeneration = UUID()
        isScanning = false
    }

    func waitForScan() async {
        await scanTask?.value
    }

    func previewCleanup(libraryID: String, folderID: UUID) {
        guard !isScanning, !isCleaning, let library = scanResults[folderID]?.libraries.first(where: { $0.id == libraryID }) else { return }
        cancelPreview()
        let requests = library.measurements.flatMap { measurement in
            measurement.candidates.map { CleanupRequest(libraryURL: library.url, kind: measurement.kind, candidate: $0) }
        }
        guard !requests.isEmpty else { return }
        let access: FolderScanAccess
        do {
            // 每次预览额外开启 scope；移除授权后仍等后台真正退出才释放。
            access = try folderStore.makeScanAccess(for: folderID)
        } catch {
            notice = Notice(title: "无法生成清理预览", message: "授权或磁盘不可访问，请重新授权并扫描。\n\(error.localizedDescription)")
            return
        }
        let generation = UUID()
        previewGeneration = generation
        isPreparingPreview = true
        let cleaner = dryRunCleaner
        let parent = access.url
        previewTask = Task { [weak self, access] in
            defer { access.close() }
            let worker = Task.detached(priority: .utility) {
                try cleaner.preview(requests, authorizedParent: parent)
            }
            let result = await withTaskCancellationHandler {
                await worker.result
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, let self, self.previewGeneration == generation else { return }
            switch result {
            case .success(let preview):
                self.previewFolderID = folderID
                self.cleanupPreview = preview
            case .failure(let error):
                self.notice = Notice(title: "清理预览失败", message: error.localizedDescription)
            }
            self.isPreparingPreview = false
            self.previewTask = nil
        }
    }

    func cancelPreview() {
        guard !isCleaning else { return }
        preparationTask?.cancel()
        preparationTask = nil
        isPreparingCleanup = false
        cleanupConfirmation = nil
        previewFolderID = nil
        previewTask?.cancel()
        previewTask = nil
        previewGeneration = UUID()
        isPreparingPreview = false
        cleanupPreview = nil
    }

    func waitForPreview() async {
        await previewTask?.value
    }

    /// 勾选之后先完整重读并对照原扫描快照，再生成只能由二次确认按钮提交的计划。
    func prepareCleanup(selection: Set<String>, previewID: UUID) {
        guard !isCleaning, !isPreparingCleanup, !isScanning,
              let preview = cleanupPreview, preview.id == previewID, let folderID = previewFolderID,
              !selection.isEmpty, let bytes = preview.estimatedBytes(for: selection) else { return }
        let selected = preview.items.filter { selection.contains($0.id) && $0.isEligible }.map(\.request)
        guard selected.count == selection.count else {
            notice = Notice(title: "无法准备清理", message: CleanupExecutionError.invalidSelection.localizedDescription)
            return
        }
        let access: FolderScanAccess
        do {
            try finalCut.requireClosed()
            access = try folderStore.makeScanAccess(for: folderID)
        } catch {
            notice = Notice(title: "无法准备清理", message: error.localizedDescription)
            return
        }
        isPreparingCleanup = true
        let cleaner = dryRunCleaner
        let parent = access.url
        preparationTask = Task { [weak self, access] in
            defer { access.close() }
            let worker = Task.detached(priority: .utility) { try cleaner.preview(selected, authorizedParent: parent) }
            let result = await withTaskCancellationHandler { await worker.result } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self, self.cleanupPreview?.id == previewID else { return }
            self.isPreparingCleanup = false
            self.preparationTask = nil
            do {
                let checked = try result.get()
                guard checked.eligibleCount == selected.count else {
                    throw NSError(domain: "FCPCleaner.Cleanup", code: 1, userInfo: [NSLocalizedDescriptionKey:
                        checked.items.compactMap(\.blockedReason).joined(separator: "\n")])
                }
                try self.finalCut.requireClosed()
                self.cleanupConfirmation = CleanupConfirmation(previewID: previewID, folderID: folderID,
                    parentURL: parent, requests: selected, estimatedBytes: bytes)
            } catch {
                self.notice = Notice(title: "清理前复验失败", message: error.localizedDescription + "\n请重新扫描后选择。")
            }
        }
    }

    func confirmCleanup(id: UUID, editingTasksEnded: Bool) {
        guard editingTasksEnded, !isCleaning, !isScanning,
              let confirmation = cleanupConfirmation, confirmation.id == id,
              cleanupPreview?.id == confirmation.previewID else { return }
        let access: FolderScanAccess
        do {
            try finalCut.requireClosed()
            access = try folderStore.makeScanAccess(for: confirmation.folderID)
            guard access.url == confirmation.parentURL else {
                access.close()
                throw CleanupExecutionError.authorizationChanged
            }
        } catch {
            cleanupConfirmation = nil
            notice = Notice(title: "未执行清理", message: error.localizedDescription)
            return
        }
        isCleaning = true
        cleanupEntries = []
        cleanupReport = nil
        cleanupConfirmation = nil
        cleanupPreview = nil
        let executor = executor
        let parent = access.url
        cleanupTask = Task { [self, access] in
            // 持有 scope 和模型直到所有 API 返回；关闭预览或取消不会提前释放访问。
            defer { access.close() }
            let worker = Task.detached(priority: .utility) { [self] in
                await executor.execute(confirmation.requests, authorizedParent: parent, permit: { [self] in
                    try await self.requireCleanupAuthorization(folderID: confirmation.folderID, parent: parent)
                }, progress: { [self] entry in
                    await self.updateCleanupProgress(entry)
                })
            }
            let report = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            isRescanningAfterCleanup = true
            // 不根据已移动容量扣减数字；等文件系统的全新扫描完成后再展示最终报告。
            scanAuthorizedFolders()
            await waitForScan()
            cleanupReport = report
            isRescanningAfterCleanup = false
            isCleaning = false
            cleanupTask = nil
        }
    }

    private func requireCleanupAuthorization(folderID: UUID, parent: URL) throws {
        guard folderStore.folders.contains(where: { $0.id == folderID && $0.url == parent }) else {
            throw CleanupExecutionError.authorizationChanged
        }
        // 每项重新确认 access 可开启，避免只依赖最早的授权状态。
        let access = try folderStore.makeScanAccess(for: folderID)
        access.close()
    }

    private func updateCleanupProgress(_ entry: CleanupLogEntry) {
        if let index = cleanupEntries.firstIndex(where: { $0.id == entry.id }) { cleanupEntries[index] = entry }
        else { cleanupEntries.append(entry) }
    }

    func cancelCleanup() {
        guard isCleaning, !isRescanningAfterCleanup else { return }
        cleanupTask?.cancel()
    }

    func waitForCleanupPreparation() async { await preparationTask?.value }
    func waitForCleanup() async { await cleanupTask?.value }

    struct Notice: Identifiable {
        let title: String
        let message: String

        var id: String { title }
    }
}

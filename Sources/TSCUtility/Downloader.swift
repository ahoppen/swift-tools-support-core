/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2014 - 2019 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import TSCBasic
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Error enumeration that can be returned by a `Downloader` conforming type.
public enum DownloaderError: Error {

    /// Error thrown when the downloader fails to establish a connection to the server.
    case clientError(_ error: Error)

    /// Error thrown when the downloader received an invalid status code from the server.
    case serverError(statusCode: Int)

    /// Error thrown during the file system move operation.
    case fileSystemError(_ error: Error)
}

/// The `Downloader` protocol abstract away the download of a file with a progress report.
public protocol Downloader {

    /// Downloads a file and keeps the caller updated on the progress and completion.
    ///
    /// - Parameters:
    ///   - url: The `URL` to the file to download.
    ///   - destination: The `AbsolutePath` to download the file to.
    ///   - progress: A closure to receive the download's progress as a fractional value between `0.0` and `1.0`.
    ///   - completion: A closure to be notifed of the completion of the download as a `Result` type containing the
    ///   `DownloaderError` encountered on failure.
    func downloadFile(
        at url: Foundation.URL,
        to destination: AbsolutePath,
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<Void, DownloaderError>) -> Void
    )
}

/// A `Downloader` conformance that uses Foundation's `URLSession`.
public final class FoundationDownloader: NSObject, Downloader {

    /// The integer identifier of a `URLSessionTask`.
    private typealias TaskIdentifier = Int

    /// A private structure to keep track of a download.
    fileprivate struct Download {
        let task: URLSessionDownloadTask
        let destination: AbsolutePath
        let progress: (Double) -> Void
        let completion: (Result<Void, DownloaderError>) -> Void
    }

    /// The `URLSession` used for all downloads.
    private var session: URLSession!

    /// The collection from `TaskIdentifier` to `Download` to keep track of ongoing downloads.
    private var downloads: [TaskIdentifier: Download] = [:]

    /// The operation queue used to synchronize access to the class properties.
    private let queue = OperationQueue()

    /// The `FileSystem` to move the file when download is complete.
    private let fileSystem: FileSystem

    /// Creates a `FoundationDownloader` with an optional `URLSessionConfiguration`.
    ///
    /// - Parameters:
    ///   - configuration: The `URLSessionConfiguration` to setup the `URLSession` used for downloading. If left out, it
    ///   will default to a `default` configuration.
    ///   - fileSystem: The `FileSystem` implementation to use to move the downloaded file to on completion.
    public init(configuration: URLSessionConfiguration = .default, fileSystem: FileSystem = localFileSystem) {
        self.fileSystem = fileSystem
        super.init()
        queue.name = "org.swift.swiftpm.basic.foundation-downloader"
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    public func downloadFile(
        at url: Foundation.URL,
        to destination: AbsolutePath,
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<Void, DownloaderError>) -> Void
    ) {
        queue.addOperation {
            let task = self.session.downloadTask(with: url)
            let download = Download(
                task: task,
                destination: destination,
                progress: progress,
                completion: completion)
            self.downloads[task.taskIdentifier] = download
            task.resume()
        }
    }
}

extension FoundationDownloader: URLSessionDownloadDelegate {
    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let download = self.download(for: downloadTask)
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        download.notifyProgress(progress)
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: Foundation.URL
    ) {
        let download = self.download(for: downloadTask)
        let response = downloadTask.response as! HTTPURLResponse

        guard (200..<300).contains(response.statusCode) else {
            download.notifyError(.serverError(statusCode: response.statusCode))
            return
        }

        do {
            try fileSystem.move(from: AbsolutePath(location.path), to: download.destination)
            download.notifySuccess()
        } catch {
            download.notifyError(.fileSystemError(error))
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            let download = self.download(for: task)
            download.notifyError(.clientError(error))
        }
    }
}

extension FoundationDownloader {

    /// Returns the download data structure associated with a task and fails if none is found as this should never
    /// happen.
    /// - Note: This function should be called from a thread-safe function. `URLSessionDownloadDelegate` functions are
    /// thread-safe because they are called from the same serial `OperationQueue`.
    private func download(for task: URLSessionTask) -> Download {
        guard let download = downloads[task.taskIdentifier] else {
            fatalError("download not found")
        }
        return download
    }
}

extension FoundationDownloader.Download {
    func notifyProgress(_ progress: Double) {
        DispatchQueue.global().async {
            self.progress(progress)
        }
    }

    func notifySuccess() {
        DispatchQueue.global().async {
            self.completion(.success(()))
        }
    }

    func notifyError(_ error: DownloaderError) {
        DispatchQueue.global().async {
            self.completion(.failure(error))
        }
    }
}
